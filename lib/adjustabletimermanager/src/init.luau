local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Janitor = require(script.Parent.Janitor)
local Promise = require(script.Parent.Promise)
local Signal = require(script.Parent.Signal)
local AdjustableTimer = require(script.Parent.AdjustableTimer)

local RemoteEvent: RemoteEvent = script.Parent.AdjustableTimerActionRemoteEvent

local IS_SERVER = RunService:IsServer()

--// Types //--
type Janitor = Janitor.Janitor
type Promise = typeof(Promise.new(function() end))
type ActionType = AdjustableTimer.ActionType | "Initialize" | "Disconnect" | "Sync"
export type AdjustableTimer = AdjustableTimer.AdjustableTimer

--[=[
	@within AdjustableTimerManager
	@type TimerId string
	A unique identifier for the replication of an AdjustableTimer.
]=]
type TimerId = string

--[=[
	@within AdjustableTimerManager
	@type Tags { [any]: any }
	Represents a dictionary of tags associated with a timer. Tags can be used to categorize or filter timers based on specific attributes.
	```lua
	local tags = { Category = "Game", Level = 5 }
	```
]=]
type Tags = { [any]: any }

--[=[
	@within AdjustableTimerManager
	@type TagMatchType "exact" | "any" | "superset" | "subset"
	Defines the type of matching to perform when comparing tags.

	- `"exact"`: All key-value pairs in the tags must match exactly.
	- `"any"`: At least one key-value pair in the tags must match.
	- `"superset"`: The timer's tags must contain all key-value pairs of the given tags.
	- `"subset"`: The timer's tags must be contained within the key-value pairs of the given tags.
]=]
type TagMatchType = "exact" | "any" | "superset" | "subset"

--// Volatiles //--
local TimerToId: { [AdjustableTimer]: TimerId } = {}
local IdToTimer: { [TimerId]: AdjustableTimer } = {}
local TimerActionConnection: { [TimerId]: () -> () } = {}
local TimerTags: { [TimerId]: Tags } = {}

local ConnectedClients: { Player } = {}

local NEXT_ID = 1

local TimerRegisteredSignal = Signal.new()
local TimerDisconnectedSignal = Signal.new()
local TimerSyncedSignal = Signal.new()

--------------------------------------------------------------------------------
--// Private Functions //--
--------------------------------------------------------------------------------

local function never(x: never): never
	error("This function should never be called: " .. tostring(x))
end

-- @server
local function generateId(): TimerId
	local id = tostring(NEXT_ID)
	NEXT_ID += 1
	return id
end

local function disconnectTimer(timer: AdjustableTimer)
	local id = TimerToId[timer]
	if not id then
		warn("Timer not found for disconnect:", timer)
		return
	end

	-- Disconnect the action connection
	if TimerActionConnection[id] then
		TimerActionConnection[id]()
		TimerActionConnection[id] = nil
	end

	-- Remove from all mappings
	IdToTimer[id] = nil
	TimerToId[timer] = nil
	TimerTags[id] = nil

	-- Fire the disconnected signal
	TimerDisconnectedSignal:Fire(timer, id)
end

-- @server
local function replicateAction(id: TimerId, actionType: ActionType, ...)
	assert(IS_SERVER, "ReplicateAction can only be called on the server")
	for _, player in ipairs(ConnectedClients) do
		RemoteEvent:FireAllClients(id, actionType, ...)
	end
end

-- @client
local function handleRemoteAction(id: TimerId, actionType: ActionType, ...)
	local timer = IdToTimer[id]
	if actionType == "Initialize" then
		local snapshot, tags = ...
		if not timer then
			timer = AdjustableTimer.Unserialize(snapshot)
			TimerToId[timer] = id
			IdToTimer[id] = timer
			TimerTags[id] = tags or {}
			TimerRegisteredSignal:Fire(timer, id)
		else
			warn("Timer already exists for ID:", id)
		end
	elseif actionType == "Pause" then
		timer:Pause(...)
	elseif actionType == "Resume" then
		timer:Resume(...)
	elseif actionType == "ChangeProgressRate" then
		local newRate, serverTime = ...
		timer:SetTimeScale(newRate, serverTime)
	elseif actionType == "ChangeStartTime" then
		local newStartTime = ...
		timer:SetStartTime(newStartTime)
	elseif actionType == "Sync" then
		local snapshot = ...
		if not timer then
			warn("Timer not found for ID:", id)
			return
		end
		for key, value in pairs(snapshot) do
			timer[key] = value
		end
		TimerSyncedSignal:Fire(id, snapshot)
	elseif actionType == "Disconnect" then
		if not timer then
			warn("Unable to disconnect; Timer not found for ID:", id)
			return
		end
		disconnectTimer(timer)
	else
		never(actionType)
	end
end

-- @server
local function replicateAllToPlayer(player: Player)
	assert(not table.find(ConnectedClients, player), "Player already connected")
	for id, timer in pairs(IdToTimer) do
		local snapshot = timer:Serialize()
		RemoteEvent:FireClient(player, id, "Initialize", snapshot)
	end
	table.insert(ConnectedClients, player)
end

-- Shared function for tag matching
local function doesTagsMatch(tags, tagsToMatch, matchType)
	if matchType == "exact" then
		for key, value in pairs(tagsToMatch) do
			if tags[key] ~= value then
				return false
			end
		end
		for key, value in pairs(tags) do
			if tagsToMatch[key] ~= value then
				return false
			end
		end
		return true
	elseif matchType == "any" then
		for key, value in pairs(tagsToMatch) do
			if tags[key] == value then
				return true
			end
		end
	elseif matchType == "superset" then
		for key, value in pairs(tagsToMatch) do
			if tags[key] ~= value then
				return false
			end
		end
		return true
	elseif matchType == "subset" then
		for key, value in pairs(tags) do
			if tagsToMatch[key] ~= value then
				return false
			end
		end
		return true
	end
	return false
end

--------------------------------------------------------------------------------
--// Class //--
--------------------------------------------------------------------------------

--[=[
	@class AdjustableTimerManager
	The AdjustableTimerManager class manages multiple AdjustableTimer instances, providing functionality for replication, tag-based filtering, and client-server synchronization. It is designed to work in both server and client environments.

	### Example Usage
	```lua
	-- @SERVER
	local manager = require(AdjustableTimerManager)
	local timer = AdjustableTimer.new():Resume()
	manager:ReplicateTimer(timer)
	```
	```lua
	-- @CLIENT
	local manager = require(AdjustableTimerManager)
	local function watchTimer(timer)
		-- do something with the timer
	end

	for _, timer in manager:GetAllReplicatedTimers() do
		task.spawn(watchTimer, timer)
	end
	manager.TimerRegistered:Connect(function(timer, id)
		watchTimer(timer)
	end)
	```
]=]
local AdjustableTimerManager = {}
AdjustableTimerManager.ClassName = "AdjustableTimerManager"

--[=[
	@within AdjustableTimerManager
	@prop TimerRegistered Signal<AdjustableTimer, TimerId>
	Signal that fires when a timer is registered with the manager.
	```lua
	local connection = AdjustableTimerManager.TimerRegistered:Connect(function(timer, id)
		print("Timer registered:", timer, id)
	end)
	```
]=]
AdjustableTimerManager.TimerRegistered = TimerRegisteredSignal

--[=[
	@within AdjustableTimerManager
	@prop TimerDisconnected Signal<AdjustableTimer, TimerId>
	Signal that fires when a timer is disconnected from the manager.
	```lua
	local connection = AdjustableTimerManager.TimerDisconnected:Connect(function(timer, id)
		print("Timer disconnected:", timer, id)
	end)
	```
]=]
AdjustableTimerManager.TimerDisconnected = TimerDisconnectedSignal


--[=[
	@private
	Initializes the manager and sets up replication for timers.
	```lua
	AdjustableTimerManager:Start()
	```
]=]
function AdjustableTimerManager:Start()
	if not RunService:IsRunning() then
		warn("AdjustableTimerManager:Start will not be called when not running")
		return AdjustableTimerManager
	end

	if self._Started then
		return AdjustableTimerManager
	end
	self._Started = true

	if RunService:IsServer() then
		Players.PlayerAdded:Connect(function(player)
			replicateAllToPlayer(player)
		end)
		for _, player in ipairs(Players:GetPlayers()) do
			replicateAllToPlayer(player)
		end

		RemoteEvent.OnServerEvent:Connect(function(player, id: TimerId, actionType: ActionType, ...)
			if not table.find(ConnectedClients, player) then
				warn("Player not connected:", player)
				return
			end
			if actionType == "Sync" then
				-- Sync request from client
				AdjustableTimerManager:SyncTimer(id, player)
			else
				warn("Received unsupported action type from client:", actionType, player)
			end
		end)
	else
		RemoteEvent.OnClientEvent:Connect(function(id: TimerId, actionType: ActionType, ...)
			handleRemoteAction(id, actionType, ...)
		end)
	end

	return AdjustableTimerManager
end

--[=[
	@server
	Replicates a timer to all clients.
	@param timer AdjustableTimer -- The timer to replicate.
	@param tags Tags? -- Optional tags to associate with the timer.
	@return TimerId -- The ID of the replicated timer.
	```lua
	local id = AdjustableTimerManager:ReplicateTimer(timer, { Tag = "Example" })
	```
	:::caution Memory Leaks
	Ensure to call `AdjustableTimerManager:DisconnectTimer(timer)` when the timer is no longer needed to prevent memory leaks.
	:::
]=]
function AdjustableTimerManager:ReplicateTimer(timer: AdjustableTimer, tags: Tags?): TimerId
	assert(IS_SERVER, "ReplicateTimer can only be called on the server")
	if TimerToId[timer] then
		warn("Timer already replicated")
		return TimerToId[timer]
	end

	local id = generateId()
	IdToTimer[id] = timer
	TimerToId[timer] = id
	TimerTags[id] = tags or {}
	TimerActionConnection[id] = timer:OnChanged(function(actionType: ActionType, ...)
		replicateAction(id, actionType, ...)
	end)

	local snapshot = timer:Serialize()

	replicateAction(id, "Initialize", snapshot, TimerTags[id])
	TimerRegisteredSignal:Fire(timer, id)
	return id
end

--[=[
	@server
	Disconnects a timer from the manager and stops replicating it to clients.
	@param timer AdjustableTimer -- The timer to disconnect.
	```lua
	AdjustableTimerManager:DisconnectTimer(timer)
	```
]=]
function AdjustableTimerManager:DisconnectTimer(timer: AdjustableTimer)
	assert(IS_SERVER, "DisconnectTimer can only be called on the server")
	disconnectTimer(timer)
end

--[=[
	Returns the timer associated with the given ID, or nil if it doesn't exist.
	```lua
	local timer = AdjustableTimerManager:GetTimerFromId(timerId)
	```
]=]
function AdjustableTimerManager:GetTimerFromId(id: TimerId): AdjustableTimer?
	return IdToTimer[id]
end

--[=[
	Returns the ID of the timer if it is registered, otherwise returns nil.
	```lua
	local id = AdjustableTimerManager:GetTimerId(timer)
	```
]=]
function AdjustableTimerManager:GetTimerId(timer: AdjustableTimer): TimerId?
	return TimerToId[timer]
end

--[=[
	Returns the tags associated with the given timer or timer ID.
	Tags are defined on the server when initially replicating the timer.
	@param timer AdjustableTimer | TimerId -- The timer or timer ID to get tags for.
	@return Tags? -- The tags associated with the timer.
	```lua
	local tags = AdjustableTimerManager:GetTimerTags(timer)
	```
]=]
function AdjustableTimerManager:GetTimerTags(timer: AdjustableTimer | TimerId): Tags?
	local id = if typeof(timer) == "table" then TimerToId[timer] else timer
	if not id then
		warn("Timer not found")
		return nil
	end
	return TimerTags[id]
end

--[=[
	Returns an array of timers that match the given tags.
	@param tagsToMatch Tags -- The tags to match against.
	@param matchType TagMatchType? -- The type of tag matching to perform. Defaults to "exact".
	@return { AdjustableTimer } -- An array of timers that satisfy the tag match.
	```lua
	local timers = AdjustableTimerManager:GetTimersWithTags({ Tag = "Example" })
	```
]=]
function AdjustableTimerManager:GetTimersWithTags(tagsToMatch: Tags, matchType: TagMatchType?): { AdjustableTimer }
	matchType = matchType or "exact"
	local timers = {}

	for id, tags in pairs(TimerTags) do
		if doesTagsMatch(tags, tagsToMatch, matchType) then
			table.insert(timers, IdToTimer[id])
		end
	end

	return timers
end

--[=[
	Returns a promise that resolves with the first timer that matches the given tags.
	If no timer is found, it will wait for a timer to be registered that matches the tags.
	@param tagsToMatch Tags -- The tags to match against.
	@param matchType TagMatchType? -- The type of tag matching to perform. Defaults to "exact".
	@return Promise<AdjustableTimer> -- A promise that resolves with the first matching timer.
	```lua
	AdjustableTimerManager:PromiseFirstTimerWithTags({ Tag = "Example" }):andThen(function(timer)
		print(timer)
	end)
	```
]=]
function AdjustableTimerManager:PromiseFirstTimerWithTags(tagsToMatch: Tags, matchType: TagMatchType?): Promise
	matchType = matchType or "exact"
	return Promise.new(function(resolve, reject, onCancel)
		local timers = self:GetTimersWithTags(tagsToMatch, matchType)
		if #timers > 0 then
			resolve(timers[1])
			return
		end

		local conn
		conn = TimerRegisteredSignal:Connect(function(timer, id)
			local tags = TimerTags[id]
			if tags and doesTagsMatch(tags, tagsToMatch, matchType) then
				conn:Disconnect()
				resolve(timer)
			end
		end)

		onCancel(function()
			conn:Disconnect()
		end)
	end)
end

--[=[
	Returns a promise that resolves with the timer associated with the given ID.
	@param id TimerId -- The ID of the timer to find.
	@return Promise<AdjustableTimer> -- A promise that resolves with the timer.

	**Example Code**
	```lua
	AdjustableTimerManager:PromiseTimerWithId(someTimerId):andThen(function(timer)
		print(timer)
	end)
	```
]=]
function AdjustableTimerManager:PromiseTimerWithId(id: TimerId): Promise
	return Promise.new(function(resolve, reject, onCancel)
		local timer = IdToTimer[id]
		if timer then
			resolve(timer)
			return
		end

		local conn
		conn = TimerRegisteredSignal:Connect(function(registeredTimer, registeredId)
			if registeredId == id then
				conn:Disconnect()
				resolve(registeredTimer)
			end
		end)

		onCancel(function()
			conn:Disconnect()
		end)
	end)
end

--[=[
	Returns an array of all replicated timers.
	@return { AdjustableTimer }
	```lua
	local timers = AdjustableTimerManager:GetAllReplicatedTimers()
	```
]=]
function AdjustableTimerManager:GetAllReplicatedTimers(): { AdjustableTimer }
	local timers = {}
	for _, timer in pairs(IdToTimer) do
		table.insert(timers, timer)
	end
	return timers
end

--[=[
	@within AdjustableTimerManager
	@method SyncTimer
	@param timer TimerId | AdjustableTimer -- The timer or ID of the timer to sync.
	@param player Player? -- Optional player to sync the timer with. If not provided, syncs with all clients. (SERVER ONLY)
	@return Promise<TimerId, SerializedAdjustableTimer> -- A promise that resolves with the timer ID and its serialized state.

	If called on the client, it will request the server to sync the timer so that their states match.

	If called on the server, it will sync the timer with all clients or a specific player.

	This method should only need to be used if you perform some manual changes to the timer on the client side, such
	as pausing it. You will need to call this to resync the timer state with the server.

	```lua
	AdjustableTimerManager:SyncTimer(timerId):andThen(function(timerId, snapshot)
		print("Timer synced:", timerId, snapshot)
	end)
	```
]=]
function AdjustableTimerManager:SyncTimer(timer: TimerId | AdjustableTimer, player: Player?)
	local timerId = if typeof(timer) == "table" then TimerToId[timer] else timer
	if IS_SERVER then
		local snapshot = IdToTimer[timerId]:Serialize()
		if player then
			local players = if typeof(player) == "table" then player else { player }
			for _, p in players do
				RemoteEvent:FireClient(player, timerId, "Sync", snapshot)
			end
		else
			replicateAction(timerId, "Sync", snapshot)
		end
		TimerSyncedSignal:Fire(timerId, snapshot)
		return Promise.resolve(timerId, snapshot)
	else
		assert(not player, "Player parameter is not supported on the client")
		RemoteEvent:FireServer(timerId, "Sync")
		return Promise.fromEvent(TimerSyncedSignal, function(id, _)
			return id == timerId
		end)
	end
end

AdjustableTimerManager:Start()
return AdjustableTimerManager

-- RemoteProperty.luau
-- Simple replicated property system for client-server synchronization

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

--// Imports //--
local Packages = script.Parent.Parent.Parent
local Promise = require(Packages.Promise)

--// Types //--
type Promise = typeof(Promise.new(
	function(resolve, reject: (...any) -> (), onCancel: (abortHandler: (() -> ())?) -> boolean) end
))

export type RemoteProperty<T> = {
	_remote: RemoteEvent,
	_value: T,
	_playerValues: { [Player]: T },
	_playerRemovingConn: RBXScriptConnection?,
	_name: string,
	_observers: { (T) -> () }?,
	_initialized: boolean?,
	_readyCallbacks: { () -> () }?,
	Set: (self: RemoteProperty<T>, value: T) -> (),
	SetFor: (self: RemoteProperty<T>, player: Player, value: T) -> (),
	Get: (self: RemoteProperty<T>) -> T,
	GetFor: (self: RemoteProperty<T>, player: Player) -> T,
	ClearFor: (self: RemoteProperty<T>, player: Player) -> (),
	Observe: (self: RemoteProperty<T>, callback: (T) -> ()) -> () -> (),
	IsReady: (self: RemoteProperty<T>) -> boolean,
	OnReady: (self: RemoteProperty<T>) -> Promise,
	Destroy: (self: RemoteProperty<T>) -> (),
}

local IS_SERVER = RunService:IsServer()

local function getFolder()
	return script
end

local RemoteProperty = {}
RemoteProperty.__index = RemoteProperty

--[=[
	Creates a new RemoteProperty (Server-side only)
	@param name string -- Name of the property
	@param initialValue any -- Initial value
	@return RemoteProperty
]=]
function RemoteProperty.new<T>(name: string, initialValue: T): RemoteProperty<T>
	assert(IS_SERVER, "RemoteProperty.new can only be called on the server")

	local self = setmetatable({}, RemoteProperty)

	-- Create RemoteEvent for property updates
	local folder = getFolder()
	assert(not folder:FindFirstChild(name), "RemoteProperty with name '" .. name .. "' already exists")
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = folder

	self._remote = remote
	self._value = initialValue
	self._playerValues = {}
	self._name = name

	-- Respond to each client's initial-value request with their personal value,
	-- falling back to the shared default for players with no per-player override.
	remote.OnServerEvent:Connect(function(player)
		remote:FireClient(player, self:GetFor(player))
	end)

	-- Automatically remove stale per-player entries when a player leaves so this
	-- object never holds a reference to a departed Player instance.
	self._playerRemovingConn = Players.PlayerRemoving:Connect(function(player)
		self._playerValues[player] = nil
	end)

	return self
end

--[=[
	Connects to an existing RemoteProperty from the server (Client-side only)
	@param name string -- Name of the property
	@return RemoteProperty
]=]
function RemoteProperty.fromServer(name: string)
	assert(not IS_SERVER, "RemoteProperty.fromServer can only be called on the client")

	local self = setmetatable({}, RemoteProperty)

	local folder = getFolder()
	local remote = folder:WaitForChild(name, 10)

	if not remote then
		error("RemoteProperty " .. name .. " not found on server")
	end

	self._remote = remote
	self._name = name
	self._observers = {}
	self._value = nil
	self._initialized = false
	self._readyCallbacks = {}

	-- Listen for updates from server
	remote.OnClientEvent:Connect(function(newValue)
		self._value = newValue
		local wasInitialized = self._initialized
		self._initialized = true

		-- Fire observers
		for _, callback in self._observers do
			task.spawn(callback, newValue)
		end

		-- Fire ready callbacks (promise resolvers) if this is the first value received
		if not wasInitialized then
			for _, resolve in self._readyCallbacks do
				task.spawn(resolve)
			end
			self._readyCallbacks = {} -- Clear callbacks after firing
		end
	end)

	-- Request initial value from server
	remote:FireServer()

	return self
end

--[=[
	Sets the value of the property (Server-side only)
	@param value any -- New value
]=]
function RemoteProperty:Set(value: any)
	assert(IS_SERVER, "RemoteProperty:Set can only be called on the server")

	self._value = value

	-- Fire to all clients
	self._remote:FireAllClients(value)
end

--[=[
	Fires a value to a specific client only (Server-side only).
	Does not update the shared default value seen by other clients.
	@param player Player -- The player to send the value to
	@param value any -- Value to send
]=]
function RemoteProperty:SetFor(player: Player, value: any)
	assert(IS_SERVER, "RemoteProperty:SetFor can only be called on the server")
	self._playerValues[player] = value
	self._remote:FireClient(player, value)
end

--[=[
	Returns the last value sent to a specific player (Server-side only).
	Falls back to the shared default value if no per-player value has been set.
	@param player Player -- The player to query
	@return any
]=]
function RemoteProperty:GetFor(player: Player)
	assert(IS_SERVER, "RemoteProperty:GetFor can only be called on the server")
	local playerValue = self._playerValues[player]
	return if playerValue ~= nil then playerValue else self._value
end

--[=[
	Clears the per-player value for a specific player (Server-side only).
	After this call, GetFor will return the shared default value for that player.
	Does not notify the client; call SetFor or Set separately if needed.
	@param player Player -- The player whose override should be cleared
]=]
function RemoteProperty:ClearFor(player: Player)
	assert(IS_SERVER, "RemoteProperty:ClearFor can only be called on the server")
	self._playerValues[player] = nil
end

--[=[
	Gets the current value of the property
	@return any
]=]
function RemoteProperty:Get()
	return self._value
end

--[=[
	Observes changes to the property (Client-side only)
	Will wait for the initial value from the server before calling the callback.
	@param callback function -- Called when value changes
	@return function -- Disconnect function
]=]
function RemoteProperty:Observe(callback: (any) -> ())
	assert(not IS_SERVER, "RemoteProperty:Observe can only be called on the client")

	if not self._observers then
		self._observers = {}
	end

	table.insert(self._observers, callback)

	-- Only call immediately if we've received the initial value
	if self._initialized then
		task.spawn(callback, self._value)
	end

	-- Return disconnect function
	return function()
		local index = table.find(self._observers, callback)
		if index then
			table.remove(self._observers, index)
		end
	end
end

--[=[
	Checks if the property has received its initial value from the server (Client-side only)
	@return boolean -- True if the initial value has been received
]=]
function RemoteProperty:IsReady(): boolean
	assert(not IS_SERVER, "RemoteProperty:IsReady can only be called on the client")
	return self._initialized or false
end

--[=[
	Returns a promise that resolves when the property receives its initial value (Client-side only)
	If already ready, the promise resolves immediately.
	@return Promise -- Promise that resolves when ready
]=]
function RemoteProperty:OnReady(): Promise
	assert(not IS_SERVER, "RemoteProperty:OnReady can only be called on the client")

	-- If already initialized, return a resolved promise
	if self._initialized then
		return Promise.resolve()
	end

	-- Otherwise, return a promise that resolves when ready
	return Promise.new(function(resolve)
		if not self._readyCallbacks then
			self._readyCallbacks = {}
		end

		table.insert(self._readyCallbacks, resolve)
	end)
end

--[=[
	Destroys this RemoteProperty, disconnecting all internal connections and
	removing the underlying RemoteEvent. Should be called when the property
	is no longer needed to prevent memory leaks. (Server-side only)
]=]
function RemoteProperty:Destroy()
	assert(IS_SERVER, "RemoteProperty:Destroy can only be called on the server")
	if self._playerRemovingConn then
		self._playerRemovingConn:Disconnect()
		self._playerRemovingConn = nil
	end
	table.clear(self._playerValues)
	self._remote:Destroy()
end

return RemoteProperty

-- May 05, 2025
--[=[
	@class PartyService
]=]

--// Roblox Services //--
local MessagingService = game:GetService("MessagingService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

--// Imports //--
local Types = require("@Shared/Types")
local Promise = require("@Packages/Promise")
local RailUtil = require("@Packages/RailUtil")
local Signal = require("@Packages/Signal")
local T = require("@Packages/T")

--// Type Definitions //--
type PartyId = string

type PartyData = {
	owner: number,
	private: boolean,
	maxSize: number,
	members: { number },
	invites: { number },
	joinRequests: { number },
}

type InviteMessageAction = "invite" | "request"
type MemberMessageAction = "create" | "join" | "leave" | "disband"

type Promise = typeof(Promise.new(function() end))

--// Constants //--
local PARTY_STORE_NAME = "PartyStore"
local PLAYER_PARTY_MAP_NAME = "PlayerPartyMap"
local PARTY_INVITE_TOPIC = "PartyInvites"
local PARTY_MEMBER_TOPIC = "PartyMembers"

local DEFAULT_EXPIRATION = 60 * 60 * 24 -- 24 hours

--// MemoryStore HashMaps //--
local partyStore = MemoryStoreService:GetHashMap(PARTY_STORE_NAME)
local playerPartyMap = MemoryStoreService:GetHashMap(PLAYER_PARTY_MAP_NAME)

--------------------------------------------------------------------------------
--// Class //--
--------------------------------------------------------------------------------
local PartyService = {}

--------------------------------------------------------------------------------
--// Private Functions //--
--------------------------------------------------------------------------------

local function BroadcastMessage(
	topic,
	action: InviteMessageAction | MemberMessageAction,
	partyId: PartyId,
	playerId: number?
): Promise
	return Promise.retry(function()
		return Promise.new(function(resolve, reject)
			local ok, err = pcall(function()
				MessagingService:PublishAsync(topic, { action, partyId, playerId })
			end)
			if not ok then
				reject(err)
			else
				resolve()
			end
		end)
	end, 5)
end

local function disbandParty(partyId: PartyId)
	partyStore:RemoveAsync(partyId)
	BroadcastMessage(PARTY_MEMBER_TOPIC, "disband", partyId):await()
end

local function removePlayerFromParty(player: Player, partyId: PartyId)
	local shouldDisband = false

	partyStore:UpdateAsync(partyId, function(partyData: PartyData)
		if not partyData then
			return nil
		end

		local members = partyData.members
		for i, userId in ipairs(members) do
			if userId == player.UserId then
				table.remove(members, i)
				break
			end
		end

		if #members == 0 then
			shouldDisband = true
		end

		if partyData.owner == player.UserId then
			partyData.owner = members[1]
		end

		return partyData
	end, DEFAULT_EXPIRATION)

	BroadcastMessage(PARTY_MEMBER_TOPIC, "leave", partyId, player.UserId)
	playerPartyMap:RemoveAsync(player.UserId)

	if shouldDisband then
		disbandParty(partyId)
	end

	return
end

--------------------------------------------------------------------------------
--// Public Methods //--
--------------------------------------------------------------------------------

--[=[
	@method CreateParty
	@within PartyService
	@param player Player -- The player creating the party.
	@param private boolean? -- Whether the party is private (default: false).
	@param maxSize number? -- The maximum size of the party (default: 10).
	@return Promise -- Resolves with the created party ID.
	Creates a new party with the specified parameters.
]=]
function PartyService:CreateParty(player: Player, private: boolean?, maxSize: number?): Promise
	assert(T.tuple(T.instance("Player"), T.optional(T.boolean), T.optional(T.number))(player, private, maxSize))
	return Promise.new(function(resolve, reject)
		local partyId = tostring(HttpService:GenerateGUID(false))
		partyId = partyId:gsub("-", "") -- Remove dashes for a smaller ID

		-- Create small party id and grow it if needed
		local i, clampedPartyId = 5, ""
		repeat
			i += 1
			clampedPartyId = partyId:sub(1, i)
		until not partyStore:GetAsync(clampedPartyId)
		partyId = clampedPartyId

		local partyData: PartyData = {
			owner = player.UserId,
			private = private or false,
			maxSize = maxSize or 10,
			members = { player.UserId },
			invites = {},
			joinRequests = {},
		}

		partyStore:SetAsync(partyId, partyData, DEFAULT_EXPIRATION)
		playerPartyMap:SetAsync(player.UserId, partyId, DEFAULT_EXPIRATION)
		BroadcastMessage(PARTY_MEMBER_TOPIC, "create", partyId, player.UserId):await()
		resolve(partyId)
	end)
end

--[=[
	@method GetPartyId
	@within PartyService
	@param player Player -- The player whose party ID is being retrieved.
	@return Promise -- Resolves with the party ID or nil if the player is not in a party.
	Retrieves the party ID of the specified player.
]=]
function PartyService:GetPartyId(player: Player): Promise
	return Promise.new(function(resolve, reject)
		local partyId = playerPartyMap:GetAsync(player.UserId)
		resolve(partyId)
	end)
end

--[=[
	@method LeaveParty
	@within PartyService
	@param player Player -- The player leaving the party.
	@return Promise -- Resolves with the party ID the player left, or nil if they were not in a party.
	Removes the player from their current party.
]=]
function PartyService:LeaveParty(player: Player): Promise
	return Promise.new(function(resolve, reject)
		local partyId = playerPartyMap:GetAsync(player.UserId)
		if partyId then
			removePlayerFromParty(player, partyId)
		end
		resolve(partyId)
	end)
end

--[=[
	@method AcceptPartyInvite
	@within PartyService
	@param player Player -- The player accepting the invite.
	@param partyId PartyId -- The ID of the party the player is joining.
	@return Promise -- Resolves when the player successfully joins the party.
	Allows a player to accept an invite and join the specified party.
]=]
function PartyService:AcceptPartyInvite(player: Player, partyId: PartyId): Promise
	return Promise.new(function(resolve, reject)
		partyStore:UpdateAsync(partyId, function(partyData: PartyData)
			if not partyData then
				return nil
			end

			if #partyData.members >= partyData.maxSize then
				reject("Party is full")
				return nil
			end

			local idx = table.find(partyData.invites, player.UserId)
			if not idx then
				reject("No invite found for player")
				return nil
			end
			table.remove(partyData.invites, idx)

			if not table.find(partyData.members, player.UserId) then
				table.insert(partyData.members, player.UserId)
				playerPartyMap:SetAsync(player.UserId, partyId)
				BroadcastMessage(PARTY_MEMBER_TOPIC, "join", partyId, player.UserId):await()
			else
				reject("Player is already a member of the party")
				return nil
			end

			return partyData
		end, DEFAULT_EXPIRATION)
		resolve()
	end)
end

--[=[
	@method SendPartyInvite
	@within PartyService
	@param partyId PartyId -- The ID of the party sending the invite.
	@param playerId number -- The ID of the player being invited.
	@return Promise -- Resolves when the invite is successfully sent.
	Sends an invite to a player to join the specified party.
]=]
function PartyService:SendPartyInvite(partyId: PartyId, playerId: number): Promise
	return Promise.new(function(resolve, reject)
		partyStore:UpdateAsync(partyId, function(partyData: PartyData)
			if not partyData then
				reject("Party not found")
				return nil
			end

			if partyData.private and #partyData.members >= partyData.maxSize then
				reject("Party is full")
				return nil
			end

			if table.find(partyData.members, playerId) then
				reject("Player is already a member of the party")
				return nil
			end

			if not table.find(partyData.invites, playerId) then
				table.insert(partyData.invites, playerId)
				MessagingService:PublishAsync(PARTY_INVITE_TOPIC, "invite", partyId, playerId)
			end

			return partyData
		end, DEFAULT_EXPIRATION)
		resolve()
	end)
end

--[=[
	@method RequestToJoinParty
	@within PartyService
	@param player Player -- The player requesting to join the party.
	@param partyId PartyId -- The ID of the party the player wants to join.
	@return Promise -- Resolves when the request is successfully sent or the player joins directly.
	Allows a player to request to join a party or join directly if the party is not private.
]=]
function PartyService:RequestToJoinParty(player: Player, partyId: PartyId): Promise
	return Promise.new(function(resolve, reject)
		partyStore:UpdateAsync(partyId, function(partyData: PartyData)
			if not partyData then
				return nil
			end

			if not partyData.private then
				self:AcceptPartyInvite(player, partyId):andThen(resolve):catch(reject)
				return partyData
			end

			if table.find(partyData.invites, player.UserId) then
				self:AcceptPartyInvite(player, partyId):andThen(resolve):catch(reject)
				return partyData
			end

			if not table.find(partyData.joinRequests, player.UserId) then
				table.insert(partyData.joinRequests, player.UserId)
				BroadcastMessage(PARTY_INVITE_TOPIC, "request", partyId, player.UserId)
			end

			return partyData
		end, DEFAULT_EXPIRATION)
		resolve()
	end)
end

--[=[
	@method UpdatePartySize
	@within PartyService
	@param partyId PartyId -- The ID of the party to update.
	@param newSize number -- The new maximum size of the party.
	@return Promise -- Resolves when the party size is successfully updated.
	Updates the maximum size of the specified party.
]=]
function PartyService:UpdatePartySize(partyId: PartyId, newSize: number): Promise
	return Promise.new(function(resolve, reject)
		local partyData = partyStore:GetAsync(partyId)
		if not partyData then
			return reject("Party not found")
		end

		partyData.maxSize = newSize
		partyStore:SetAsync(partyId, partyData)
		resolve()
	end)
end

--[=[
	@method UpdatePrivacyStatus
	@within PartyService
	@param partyId PartyId -- The ID of the party to update.
	@param isPrivate boolean -- The new privacy status of the party.
	@return Promise -- Resolves when the privacy status is successfully updated.
	Updates the privacy status of the specified party.
]=]
function PartyService:UpdatePrivacyStatus(partyId: PartyId, isPrivate: boolean): Promise
	return Promise.new(function(resolve, reject)
		local partyData = partyStore:GetAsync(partyId)
		if not partyData then
			return reject("Party not found")
		end

		partyData.private = isPrivate
		partyStore:SetAsync(partyId, partyData)
		resolve()
	end)
end

--------------------------------------------------------------------------------
--// Initialization //--
--------------------------------------------------------------------------------

local function Init()
	assert(RunService:IsServer(), "PartyService should only be initialized on the server")

	--// Cleanup on Player Leave //--
	Players.PlayerRemoving:Connect(function(player)
		local partyId = playerPartyMap:GetAsync(player.UserId)
		if partyId then
			removePlayerFromParty(player, partyId)
		end
	end)

	--// MessagingService Listeners //--
	MessagingService:SubscribeAsync(PARTY_INVITE_TOPIC, function(message)
		local action: InviteMessageAction = message.Data[1]
		local partyId: PartyId = message.Data[2]
		local playerId: number? = message.Data[3]

		print("Received party invite message:", action, partyId, playerId)
	end)

	MessagingService:SubscribeAsync(PARTY_MEMBER_TOPIC, function(message)
		local action: MemberMessageAction = message.Data[1]
		local partyId: PartyId = message.Data[2]
		local playerId: number? = message.Data[3]

		print("Received party member message:", action, partyId, playerId)
	end)

	print("Initialized PartyService")

	local RailUtil = require("@Packages/RailUtil")
	RailUtil.Player.forEachPlayer(function(player)
		local success, partyId = PartyService:CreateParty(player):await()
	end)
end

task.defer(Init)

return PartyService

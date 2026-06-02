--!strict
--[=[
	@ignore
	Example integration of TradeManager with PlayerProfileManager.

	This shows how to implement the TradeCallbacks to work with PPM's profile system.
]=]

local TradeManager = require(script.Parent.TradeManager)
local Types = require(script.Parent.TradeTypes)

type TradeCallbacks = Types.TradeCallbacks
type TradeOfferContext = Types.TradeOfferContext
type TradeRollbackContext = Types.TradeRollbackContext

--[=[
	Example: Creating TradeManager callbacks for PlayerProfileManager integration.

	This factory function creates a TradeCallbacks table that integrates with PPM.
	Customize ValidateItem, RemoveItem, and AddItem for your specific inventory system.
]=]
local function CreatePPMCallbacks(ppm: any, config: {
	ValidateItem: (profile: any, itemData: any) -> (boolean, string?),
	RemoveItem: (profile: any, itemData: any) -> (),
	AddItem: (profile: any, itemData: any) -> (),
}): TradeCallbacks
	return {
		-- Validate that the item exists and can be traded
		ValidateOffer = function(context: TradeOfferContext): (boolean, string?)
			local profile = ppm:GetProfile(context.Player)
			if not profile then
				return false, "Profile not loaded"
			end

			-- Validate against LastSavedData for safety
			local lastSaved = profile.LastSavedData
			if not lastSaved then
				return false, "No saved data available"
			end

			return config.ValidateItem(profile, context.IdentifyingData)
		end,

		-- Move item from inventory to escrow (Data.Trade.outgoing)
		MoveOfferToEscrow = function(context: TradeOfferContext)
			local profile = ppm:GetProfile(context.Player)
			if not profile then
				error("Profile not loaded")
			end

			-- Initialize escrow if needed
			profile.Data.Trade = profile.Data.Trade or {}
			local escrow = profile.Data.Trade

			-- Remove from inventory, store in escrow
			config.RemoveItem(profile, context.IdentifyingData)
			escrow.outgoing = context.IdentifyingData
			escrow.tradeId = context.Session:GetSessionId()
			escrow.executionStart = os.time()

			-- Trigger save (async, doesn't wait)
			profile:Save()
		end,

		-- Complete trade or rollback
		MoveOfferToData = function(context: TradeOfferContext, rollback: TradeRollbackContext)
			local profile = ppm:GetProfile(context.Player)
			if not profile then
				error("Profile not loaded")
			end

			local escrow = profile.Data.Trade
			if not escrow then
				warn("No escrow data found during MoveOfferToData")
				return
			end

			if rollback.Reason then
				-- ROLLBACK: Return outgoing item to inventory
				if escrow.outgoing then
					config.AddItem(profile, escrow.outgoing)
				end
			else
				-- COMPLETE: Add incoming item to inventory
				-- Note: context.IdentifyingData is the item from the OTHER player
				config.AddItem(profile, context.IdentifyingData)
			end

			-- Clear escrow
			profile.Data.Trade = nil
			profile:Save()
		end,

		-- Profile utilities
		GetProfile = function(player: Player): any?
			return ppm:GetProfile(player)
		end,

		TriggerSave = function(player: Player)
			local profile = ppm:GetProfile(player)
			if profile then
				profile:Save()
			end
		end,

		RegisterSaveCallback = function(player: Player, callback: () -> ()): any
			-- Returns a connection that can be disconnected
			return ppm:OnSave(player, callback)
		end,
	}
end

--[=[
	Example usage:
]=]
local function ExampleUsage(ppm: any)
	local callbacks = CreatePPMCallbacks(ppm, {
		ValidateItem = function(profile, itemId: string)
			-- Check if item exists in inventory
			if not profile.Data.Inventory[itemId] then
				return false, "Item not found in inventory"
			end
			-- Check if item is tradeable
			if profile.Data.Inventory[itemId].Locked then
				return false, "Item is locked and cannot be traded"
			end
			return true
		end,

		RemoveItem = function(profile, itemId: string)
			profile.Data.Inventory[itemId] = nil
		end,

		AddItem = function(profile, itemId: string)
			profile.Data.Inventory[itemId] = { Locked = false }
		end,
	})

	local tradeManager = TradeManager.new({
		Callbacks = callbacks,
		RequestExpirySeconds = 60,
		CountdownSeconds = 5,
	})

	return tradeManager
end

return {
	CreatePPMCallbacks = CreatePPMCallbacks,
	ExampleUsage = ExampleUsage,
}

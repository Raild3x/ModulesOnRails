--!strict
--[=[
	@ignore
	Example integration of TradeManager with PlayerProfileManager (PPM).

	This shows how to implement the TradeCallbacks against PPM's profile system.
	The package owns all escrow state (profile.Data[TradeDataKey]) — these
	callbacks only move items between the consumer's inventory and the contexts
	the package hands them.
]=]

local TradeManager = require(script.Parent)
local Types = require(script.Parent.TradeTypes)

type TradeCallbacks = Types.TradeCallbacks
type TradeOfferContext = Types.TradeOfferContext
type TradeFinalizeContext = Types.TradeFinalizeContext
type TradeRollbackContext = Types.TradeRollbackContext

--[=[
	Example: Creating TradeManager callbacks for PlayerProfileManager integration.

	This factory function creates a TradeCallbacks table that integrates with PPM.
	Customize ValidateItem, RemoveItem, and AddItem for your specific inventory system.
]=]
local function CreatePPMCallbacks(
	ppm: any,
	config: {
		ValidateItem: (profile: any, itemData: any) -> (boolean, string?),
		RemoveItem: (profile: any, itemData: any) -> (),
		AddItem: (profile: any, itemData: any) -> (),
	}
): TradeCallbacks
	return {
		-- Validate that the item exists and can be traded
		ValidateOffer = function(context: TradeOfferContext): (boolean, string?)
			local profile = ppm:GetProfile(context.Player)
			if not profile then
				return false, "Profile not loaded"
			end
			return config.ValidateItem(profile, context.IdentifyingData)
		end,

		-- Phase 1: remove the item from inventory and accumulate it into the
		-- escrow table the package hands us (context.Trade). Do NOT save here —
		-- the package commits and confirms the save itself.
		MoveOfferToEscrow = function(context: TradeOfferContext)
			local profile = ppm:GetProfile(context.Player)
			if not profile then
				error("Profile not loaded")
			end
			config.RemoveItem(profile, context.IdentifyingData)

			local trade = context.Trade :: { [string]: any }
			trade.outgoing = trade.outgoing or {}
			table.insert(trade.outgoing, context.IdentifyingData)
		end,

		-- Phase 4: add the received items to the player's inventory.
		FinalizeOffer = function(context: TradeFinalizeContext)
			local profile = ppm:GetProfile(context.Player)
			if not profile then
				error("Profile not loaded")
			end
			if context.Incoming ~= nil then
				for _, itemData in context.Incoming :: { any } do
					config.AddItem(profile, itemData)
				end
			end
		end,

		-- Rollback/recovery: return the escrowed items to the player's inventory.
		RollbackOffer = function(context: TradeRollbackContext)
			local profile = ppm:GetProfile(context.Player)
			if not profile then
				error("Profile not loaded")
			end
			if context.Outgoing ~= nil then
				for _, itemData in context.Outgoing :: { any } do
					config.AddItem(profile, itemData)
				end
			end
		end,

		-- Profile utilities
		GetProfile = function(player: Player): any?
			return ppm:GetProfile(player)
		end,

		-- Save-and-confirm. PPM's PromiseSave resolves once a persisted snapshot
		-- satisfies the package's predicate (i.e. the escrow write actually landed).
		CommitProfile = function(player: Player, isPersisted: ((lastSavedData: { [any]: any }) -> boolean)?): any
			return ppm:PromiseSave(player, isPersisted)
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

	local tradeManager = TradeManager.new {
		Callbacks = callbacks,
		RequestExpirySeconds = 60,
		CountdownSeconds = 5,
	}

	-- Run recovery whenever a profile finishes loading, before the player can act.
	ppm.PlayerProfileLoadSuccess:Connect(function(userId: number)
		local player = game:GetService("Players"):GetPlayerByUserId(userId)
		local profile = ppm:GetProfile(userId)
		if player and profile then
			tradeManager:RecoverPlayerAsync(player, profile)
		end
	end)

	return tradeManager
end

return {
	CreatePPMCallbacks = CreatePPMCallbacks,
	ExampleUsage = ExampleUsage,
}

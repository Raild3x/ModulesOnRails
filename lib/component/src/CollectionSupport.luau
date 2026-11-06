--!strict
-- Capability probe for the engine-native Collection API
-- (`CollectionService:CreateCollection`). The API is dark-launched: the
-- function EXISTS on gated engines and throws "Collections are not enabled",
-- so a `typeof` check is insufficient — availability must be proven by a
-- functional create+destroy pcall. Probed once and cached; the gate cannot
-- flip within a running VM.
--
-- Fallback paths (tag signals, descendant watchers) are PERMANENT, not
-- transitional: production servers remain gated even where Studio's beta is
-- enabled, so shipped experiences must run fully without this returning true.
-- Authors: Logan Hunt [Raildex]

const CollectionService = game:GetService("CollectionService")

const Support = {}

local probed: boolean? = nil

--[=[
	@within Component
	@function HasNativeCollections
	@return boolean

	Whether `CollectionService:CreateCollection` is functional in this VM.
]=]
function Support.hasNativeCollections(): boolean
	if probed == nil then
		probed = pcall(function()
			-- Rooted at this ModuleScript: a zero-descendant scope with no
			-- Workspace side effects; destroyed immediately.
			const collection = (CollectionService :: any):CreateCollection("Folder", script)
			collection:Destroy()
		end)
	end
	return probed :: boolean
end

return Support

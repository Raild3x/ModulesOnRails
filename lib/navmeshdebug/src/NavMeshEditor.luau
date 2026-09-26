--!strict
-- Authors: Logan Hunt (Raildex)
-- September 25, 2026
--[=[
	@class NavMeshEditor

	In-game mouse editor for NavMesh / CDT descriptions. Implemented in ticket 21
	(`docs/plans/navmesh/tickets/21-editor.md`); this module is its placeholder home.

	The editor reads mouse input through UserInputService, which is why this package runs
	on the Studio pipeline (better-signal also touches Roblox APIs at require time).
]=]

local UserInputService = game:GetService("UserInputService")

local NavMeshEditor = {}

-- Placeholder until ticket 21: keeps the input service referenced from its real home.
NavMeshEditor._InputService = UserInputService

return NavMeshEditor

--!strict
-- Authors: Logan Hunt (Raildex)
-- September 25, 2026
--[=[
	@class NavMeshFixtures
	@private

	Shared NavMesh scenarios (`{ Name, Desc }`) for specs, the render script and benchmarks.
	Plain data only. Lives in `src/` on purpose so the debug packages can reach it through
	their dependency. Scenarios arrive with the tickets that need them (single-tile Build
	onwards); every scenario defined here is listed in `All` automatically.
]=]

--[=[
	@within NavMeshFixtures
	@interface Scenario
	.Name string
	.Desc any -- a NavMeshDesc (typed once the NavMesh API lands)
]=]
export type Scenario = {
	Name: string,
	Desc: any,
}

local Fixtures = {}

-- Every scenario defined above, sorted by name, so a new fixture can never be left out.
local all: { Scenario } = {}
for _, value in Fixtures :: { [string]: any } do
	if type(value) == "table" and value.Desc ~= nil then
		table.insert(all, value :: Scenario)
	end
end
table.sort(all, function(a: Scenario, b: Scenario): boolean
	return a.Name < b.Name
end)

--[=[
	@within NavMeshFixtures
	@prop All { Scenario }
	Every scenario, sorted by `Name` (built automatically).
]=]
Fixtures.All = all

return Fixtures

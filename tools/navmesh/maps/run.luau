-- Runs every map's scenarios (or the named maps) and prints one table per map. Exits 1 if any
-- scenario fails. Run from the repo root:
--   lune run tools/navmesh/maps/run.luau [MapName ...]
local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox") :: any
local NavMesh = require("../../../lib/navmesh/src/NavMesh")
local Adapter = require("../../../lib/navmeshadapter/src/NavMeshAdapter")
local Harness = require("./Harness")

local names = table.clone(process.args)
if #names == 0 then
	for _, file in fs.readDir("tools/navmesh/maps/Maps") do
		local name = file:match("^(.+)%.luau$")
		if name then
			table.insert(names, name)
		end
	end
	table.sort(names)
end

local dynRequire: any = require
local ok = true
for _, name in names do
	local report = Harness.Run(dynRequire("./Maps/" .. name), NavMesh, Adapter, roblox)
	print(Harness.Format(report))
	ok = ok and report.Pass
end
print(if ok then "ALL MAPS PASS" else "MAPS FAIL")
process.exit(if ok then 0 else 1)

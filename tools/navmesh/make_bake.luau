--!strict
-- Makes the frozen bake for NavMesh.Serialize.spec (SR9): prints base64 to paste as FROZEN_V<n>, for the
-- format version Serialize writes now (v1 on 2026-09-27, v2 on 2026-09-28).
-- Run once per format version; the bake must never be regenerated for an existing version.
--   lune run tools/navmesh/make_bake.luau
local NavMesh = require("../../lib/navmesh/src/NavMesh")

local desc: any = table.clone(NavMesh.Fixtures.ThreeFloorStairs.Desc)
desc.Floors = table.clone(desc.Floors)
desc.Floors.Upper = { Walkable = desc.Floors.Upper.Walkable, Area = 3 }
desc.Links =
	{ { From = vector.create(38, 5, 18), To = vector.create(38, 0, 18), Bidirectional = false, Label = "Drop" } }
local mesh = NavMesh.Build(desc)
NavMesh.AddObstacle(mesh, "Ground", {
	vector.create(4, 0, 12),
	vector.create(7, 0, 12),
	vector.create(7, 0, 15),
	vector.create(4, 0, 15),
})
NavMesh.Update(mesh)
local data = buffer.tostring(NavMesh.Serialize(mesh))

local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local out = {}
for i = 1, #data, 3 do
	local a, b, c = string.byte(data, i, i + 2)
	local n = a * 65536 + (b or 0) * 256 + (c or 0)
	local chars = {}
	for k = 3, 0, -1 do
		local index = bit32.band(bit32.rshift(n, 6 * k), 63) + 1
		table.insert(chars, string.sub(alphabet, index, index))
	end
	if c == nil then
		chars[4] = "="
	end
	if b == nil then
		chars[3] = "="
	end
	table.insert(out, table.concat(chars))
end
print(table.concat(out))

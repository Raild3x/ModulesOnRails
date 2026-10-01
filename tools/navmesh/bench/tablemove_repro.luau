--!strict
-- Ticket 31 repro: appending with table.move past a table's array part is quadratic in Luau,
-- while an index append is linear. Storage.SetFloorSources appends every authored ring this way
-- (also InsertSeam, InsertObstacleRecord), so Deserialize of the 4 km open bake (42k rings)
-- spends 520 of its 731 ms there (deserialize_profile.luau), against 4 ms at 2 km.
--   lune run tools/navmesh/bench/tablemove_repro.luau
print("| rings of 4 | table.move append ms | index append ms |")
print("|---|---|---|")
for _, rings in { 10000, 20000, 40000, 80000 } do
	local ring = { 1, 2, 3, 4 }
	local a, b = {}, {}
	local t0 = os.clock()
	for _ = 1, rings do
		table.move(ring, 1, 4, #a + 1, a)
	end
	local moved = (os.clock() - t0) * 1000
	t0 = os.clock()
	for _ = 1, rings do
		for i = 1, 4 do
			b[#b + 1] = ring[i]
		end
	end
	print(string.format("| %d | %.1f | %.1f |", rings, moved, (os.clock() - t0) * 1000))
end

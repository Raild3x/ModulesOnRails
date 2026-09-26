--!strict
--[=[
	Prototype for ticket 18: can `Update` re-snap only its dirty tiles?
	- **Setup:** the 256-stud benchmark floor (TileSize 32) is snap-rounded as Build does it.
	  A door-sized box obstacle is then dropped across a tile line.
	- **A (global):** re-snap the whole floor with the obstacle added.
	- **B (local):** re-snap only the dirty tiles. The dirty tiles are those whose rectangle,
	  expanded by one grid pixel, overlaps the obstacle's bounds (SR13). The input is their
	  already-snapped fragments, the obstacle's edges and the dirty tile rectangles.
	- **Checks** on B:
	  1. its fragments never cross (exact `Orient2D`);
	  2. its vertices on the dirty region's outer border are exactly the baseline's, so the
	     clean neighbours need no change;
	  3. removing the obstacle again (a local re-snap without it) reproduces the baseline
	     dirty-tile fragments exactly (SR14: add then remove equals a fresh Build).
	  A and B are also timed. `SnapRound` is the grid variant (Cell 1024) for both, so only
	  the scope differs.
]=]

return function(env: any)
	local Orient2D = env.CDT.Orient2D
	local snap = env.Variants.SnapRound(Orient2D, { Cell = 1024, Crossings = "grid" })
	local captured
	local original = env.Quantize.SnapRound
	env.Quantize.SnapRound = function(coords, edges)
		captured = { coords, edges }
		return original(coords, edges)
	end
	local desc = env.TileSize.Map(256, 7)
	desc.TileSize = 32
	env.NavMesh.Build(desc)
	env.Quantize.SnapRound = original
	local S = 32 * 256 -- tile size in grid units

	local baseCoords, baseEdges = snap(captured[1], captured[2])

	-- A 3 x 1.5-stud door across the tile line x = 128 studs, rotated slightly.
	local door = {}
	for _, p in { { -1.5, -0.75 }, { 1.5, -0.75 }, { 1.5, 0.75 }, { -1.5, 0.75 } } do
		local a = 0.1
		local x, z = 128 + p[1] * math.cos(a) - p[2] * math.sin(a), 100.3 + p[1] * math.sin(a) + p[2] * math.cos(a)
		table.insert(door, math.round(x * 256))
		table.insert(door, math.round(z * 256))
	end
	local dx0, dz0, dx1, dz1 = math.huge, math.huge, -math.huge, -math.huge
	for i = 1, #door, 2 do
		dx0, dx1 = math.min(dx0, door[i]), math.max(dx1, door[i])
		dz0, dz1 = math.min(dz0, door[i + 1]), math.max(dz1, door[i + 1])
	end
	-- Dirty tiles: rectangle expanded by one pixel overlaps the door bounds.
	local ti0, ti1 = (dx0 - 1) // S, (dx1 + 1) // S
	if env.NarrowRegion then
		ti1 = ti0 -- negative control: ignore that the door crosses into the next tile
	end
	local tj0, tj1 = (dz0 - 1) // S, (dz1 + 1) // S
	local rx0, rz0, rx1, rz1 = ti0 * S, tj0 * S, (ti1 + 1) * S, (tj1 + 1) * S
	local function inRegion(x: number, z: number): boolean
		return x >= rx0 and x <= rx1 and z >= rz0 and z <= rz1
	end
	local function onOuterBorder(x: number, z: number): boolean
		return inRegion(x, z) and (x == rx0 or x == rx1 or z == rz0 or z == rz1)
	end

	-- Baseline fragments inside the dirty region (a fragment never crosses a tile line).
	local function regionFragments(coords: { number }, edges: { number }): ({ number }, { number })
		local c, e = {}, {}
		local index: { [string]: number } = {}
		local function id(v: number): number
			local key = `{coords[2 * v - 1]},{coords[2 * v]}`
			if index[key] == nil then
				table.insert(c, coords[2 * v - 1])
				table.insert(c, coords[2 * v])
				index[key] = #c // 2
			end
			return index[key]
		end
		for f = 1, #edges // 2 do
			local a, b = edges[2 * f - 1], edges[2 * f]
			local mx, mz = (coords[2 * a - 1] + coords[2 * b - 1]) / 2, (coords[2 * a] + coords[2 * b]) / 2
			if inRegion(mx, mz) then
				table.insert(e, id(a))
				table.insert(e, id(b))
			end
		end
		return c, e
	end
	local regionCoords, regionEdges = regionFragments(baseCoords, baseEdges)

	local function withDoor(coords: { number }, edges: { number }, addDoor: boolean): ({ number }, { number })
		local c, e = table.clone(coords), table.clone(edges)
		local function ring(xz: { number })
			local offset = #c // 2
			for i = 1, #xz do
				table.insert(c, xz[i])
			end
			local n = #xz // 2
			for i = 1, n do
				table.insert(e, offset + i)
				table.insert(e, offset + i % n + 1)
			end
		end
		if addDoor then
			ring(door)
		end
		-- Every tile line inside the region (the tile grid stays a constraint).
		for x = rx0, rx1, S do
			ring { x, rz0, x, rz1 }
		end
		for z = rz0, rz1, S do
			ring { rx0, z, rx1, z }
		end
		return c, e
	end

	local function sortedEdges(coords: { number }, edges: { number }): string
		local keys = {}
		for f = 1, #edges // 2 do
			local a, b = edges[2 * f - 1], edges[2 * f]
			local ka, kb = `{coords[2 * a - 1]},{coords[2 * a]}`, `{coords[2 * b - 1]},{coords[2 * b]}`
			if ka ~= kb then
				table.insert(keys, if ka < kb then `{ka}-{kb}` else `{kb}-{ka}`)
			end
		end
		table.sort(keys)
		-- Deduplicate (tile lines were added twice for shared borders).
		local unique = {}
		for i, k in keys do
			if k ~= keys[i - 1] then
				table.insert(unique, k)
			end
		end
		return table.concat(unique, ";")
	end
	local function outerBorderVertices(coords: { number }, edges: { number }): string
		local set, list = {}, {}
		for _, v in edges do
			local x, z = coords[2 * v - 1], coords[2 * v]
			local key = `{x},{z}`
			if onOuterBorder(x, z) and not set[key] then
				set[key] = true
				table.insert(list, key)
			end
		end
		table.sort(list)
		return table.concat(list, ";")
	end

	-- Timing: best of 5.
	local function best(fn: () -> ()): number
		local b = math.huge
		for _ = 1, 5 do
			local t0 = env.Clock()
			fn()
			b = math.min(b, env.Clock() - t0)
		end
		return b * 1000
	end
	local globalIn = table.clone(captured[1])
	local globalEdges = table.clone(captured[2])
	do
		local offset = #globalIn // 2
		for i = 1, #door do
			table.insert(globalIn, door[i])
		end
		for i = 1, 4 do
			table.insert(globalEdges, offset + i)
			table.insert(globalEdges, offset + i % 4 + 1)
		end
	end
	local aMs = best(function()
		snap(globalIn, globalEdges)
	end)
	local lc, le = withDoor(regionCoords, regionEdges, true)
	local bCoords, bEdges
	local bMs = best(function()
		bCoords, bEdges = snap(lc, le)
	end)

	-- Check 1: no crossings among B's fragments.
	local crossings = 0
	for i = 1, #bEdges // 2 do
		local a, b = bEdges[2 * i - 1], bEdges[2 * i]
		local ax, ay, bx, by = bCoords[2 * a - 1], bCoords[2 * a], bCoords[2 * b - 1], bCoords[2 * b]
		for j = i + 1, #bEdges // 2 do
			local c, d = bEdges[2 * j - 1], bEdges[2 * j]
			local cx, cy, dx, dy = bCoords[2 * c - 1], bCoords[2 * c], bCoords[2 * d - 1], bCoords[2 * d]
			if
				Orient2D(ax, ay, bx, by, cx, cy) * Orient2D(ax, ay, bx, by, dx, dy) < 0
				and Orient2D(cx, cy, dx, dy, ax, ay) * Orient2D(cx, cy, dx, dy, bx, by) < 0
			then
				crossings += 1
			end
		end
	end
	-- Check 2: the outer border is unchanged.
	local borderSame = outerBorderVertices(bCoords, bEdges) == outerBorderVertices(regionCoords, regionEdges)
	-- Check 3: removing the door (a local re-snap without it) restores the baseline exactly.
	local rc, re = withDoor(regionCoords, regionEdges, false)
	local restoredCoords, restoredEdges = snap(rc, re)
	local restored = sortedEdges(restoredCoords, restoredEdges) == sortedEdges(regionCoords, regionEdges)
	-- Informational: does B agree with A inside the region?
	local aCoords, aEdges = snap(globalIn, globalEdges)
	local aRegionCoords, aRegionEdges = regionFragments(aCoords, aEdges)
	local agrees = sortedEdges(aRegionCoords, aRegionEdges) == sortedEdges(regionFragments(bCoords, bEdges))

	print(
		string.format(
			"dirty tiles %d x %d; baseline region fragments %d; B fragments %d",
			ti1 - ti0 + 1,
			tj1 - tj0 + 1,
			#regionEdges // 2,
			#bEdges // 2
		)
	)
	print(string.format("A global re-snap %.2f ms; B local re-snap %.3f ms (%.0fx)", aMs, bMs, aMs / bMs))
	print(`check 1, no crossings in B: {crossings == 0} ({crossings})`)
	print(`check 2, outer border vertices unchanged: {borderSame}`)
	print(`check 3, remove restores the baseline exactly: {restored}`)
	print(`info, B equals A inside the dirty region: {agrees}`)
end

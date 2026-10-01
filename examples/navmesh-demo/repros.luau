--!strict
-- Minimal repros for the bugs and surprises in REPORT.md. Each prints what it measured.
-- Run: lune run examples/navmesh-demo/repros.luau
local NavMesh = require("../../lib/navmesh/src/NavMesh")

local v = vector.create
local function rect(y: number, x0: number, z0: number, x1: number, z1: number): { any }
	return { v(x0, y, z0), v(x1, y, z0), v(x1, y, z1), v(x0, y, z1) }
end
local function f(p: any): string
	return if p then string.format("(%.2f, %.2f, %.2f)", p.X, p.Y, p.Z) else "nil"
end

-- The smallest wall distance along a path, walking the surface in 0.05-stud steps.
local function clearance(mesh: any, path: any): (number, any)
	local worst, at = math.huge, nil
	local w = path.Waypoints
	for i = 1, #w - 1 do
		if w[i].Label then
			continue -- a link segment is not on the surface
		end
		local a, b = w[i].Position, w[i + 1].Position
		local n = math.max(1, math.ceil(vector.magnitude(b - a) / 0.05))
		local p = a
		for s = 0, n do
			p = NavMesh.MoveAlongSurface(mesh, p, a + (b - a) * (s / n)).Position
			local d = NavMesh.FindDistanceToWall(mesh, p, 10)
			if d < worst then
				worst, at = d, p
			end
		end
	end
	return worst, at
end

local function report(title: string, mesh: any, from: any, to: any, radius: number)
	local path = NavMesh.FindPath(mesh, from, to, { AgentRadius = radius })
	local d, at = clearance(mesh, path)
	local points, length = {}, 0
	for i, w in path.Waypoints do
		table.insert(points, f(w.Position))
		if i > 1 then
			length += vector.magnitude(w.Position - path.Waypoints[i - 1].Position)
		end
	end
	print(
		string.format(
			"%s\n  r=%.2f %s, length %.2f, min wall distance %.2f at %s\n  waypoints %s",
			title,
			radius,
			path.Status,
			length,
			d,
			f(at),
			table.concat(points, " ")
		)
	)
end

print("== 1. AgentRadius is not kept where a path crosses a seam at a wall corner")
do
	-- A ramp rises east from the Ground; its footprint is cut out of Ground. The wall along the
	-- ramp's south side starts at the seam's corner (10, 0, 8).
	local mesh = NavMesh.Build({
		Floors = {
			Ground = { Walkable = { rect(0, 0, 0, 30, 20) }, Obstacles = { rect(0, 10, 8, 20, 12) } },
			Ramp = { Walkable = { { v(10, 0, 8), v(20, 5, 8), v(20, 5, 12), v(10, 0, 12) } } },
			Top = { Walkable = { rect(5, 20, 8, 30, 12) } },
		},
		Seams = {
			{ FloorA = "Ground", FloorB = "Ramp", From = v(10, 0, 8), To = v(10, 0, 12) },
			{ FloorA = "Ramp", FloorB = "Top", From = v(20, 5, 8), To = v(20, 5, 12) },
		},
	} :: any)
	report("ground -> top of the ramp", mesh, v(2, 0, 2), v(25, 5, 10), 1.5)
	report("same, smaller agent", mesh, v(2, 0, 2), v(25, 5, 10), 0.5)
	-- Control: the same corner with no seam (a flat crate), same bend.
	local flat = NavMesh.Build(
		{ Floors = { Ground = { Walkable = { rect(0, 0, 0, 30, 20) }, Obstacles = { rect(0, 10, 8, 20, 12) } } } } :: any
	)
	report("control: flat crate corner, similar bend", flat, v(2, 0, 2), v(25, 0, 14), 1.5)
end

print("\n== 2. MoveAlongSurface lets an agent through a gap narrower than its AgentRadius")
do
	local mesh = NavMesh.Build({
		Floors = {
			Ground = {
				Walkable = { rect(0, 0, 0, 20, 20) },
				Obstacles = { rect(0, 8, 0, 12, 9), rect(0, 8, 11, 12, 20) },
			},
		},
	} :: any)
	local path = NavMesh.FindPath(mesh, v(4, 0, 10), v(16, 0, 10), { AgentRadius = 1.5 })
	local moved = NavMesh.MoveAlongSurface(mesh, v(4, 0, 10), v(16, 0, 10), { AgentRadius = 1.5 })
	print(`  FindPath r=1.5 through a 2-stud gap: {path.Status} (the two sides are not connected for this radius)`)
	print(`  MoveAlongSurface r=1.5 from (4,0,10) to (16,0,10): ends at {f(moved.Position)}`)
end

print("\n== 3. FindRandomPoint honours QueryFilter.AgentRadius (ticket 24)")
do
	local mesh = NavMesh.Build({ Floors = { Ground = { Walkable = { rect(0, 0, 0, 10, 10) } } } } :: any)
	local close = 0
	local seed = 1
	local function lcg(): number
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end
	for _ = 1, 1000 do
		local p = assert(NavMesh.FindRandomPoint(mesh, { Filter = { AgentRadius = 2 }, Rng = lcg }))
		if NavMesh.FindDistanceToWall(mesh, p.Position, 5) < 2 then
			close += 1
		end
	end
	print(
		`  {close} / 1000 points are closer than the radius (2) to a wall (64% of a 10x10 square is within 2 of its edge)`
	)
	local p = NavMesh.FindPath(mesh, v(5, 0, 5), v(0.2, 0, 0.2), { AgentRadius = 2 })
	print(`  FindPath r=2 to such a point: {p.Status}, ends at {f(p.Waypoints[#p.Waypoints].Position)}`)
end

print("\n== 4. With every area cost 1, a path bends at an area boundary it does not need to")
do
	local mesh = NavMesh.Build({
		Floors = {
			Ground = {
				Walkable = { rect(0, 0, 0, 40, 40) },
				Areas = { { Polygon = rect(0, 0, 18, 30, 26), Area = 2 } },
			},
		},
	} :: any)
	report("start on the patch edge, no AreaCosts", mesh, v(30, 0, 20), v(19, 0, 33), 0)
	report("start just outside the patch, no AreaCosts", mesh, v(31, 0, 20), v(19, 0, 33), 0)
	report(
		"same without the area",
		NavMesh.Build({ Floors = { Ground = { Walkable = { rect(0, 0, 0, 40, 40) } } } } :: any),
		v(31, 0, 20),
		v(19, 0, 33),
		0
	)
end

print("\n== 5. A door that closes on an agent: one off-mesh policy (ticket 24)")
do
	local mesh = NavMesh.Build({ Floors = { Ground = { Walkable = { rect(0, 0, 0, 20, 20) } } } } :: any)
	NavMesh.AddObstacle(mesh, "Ground", rect(0, 9, 0, 11, 20))
	NavMesh.Update(mesh)
	local inDoor = v(10, 0, 10)
	print(`  FindPath from inside the door: {NavMesh.FindPath(mesh, inDoor, v(2, 0, 2)).Status}`)
	print(
		`  FindNearestPoint: {NavMesh.FindNearestPoint(mesh, inDoor) and "a point" or "nil"} (default SnapExtents X/Z half-size 0.5)`
	)
	local blocked, stop = NavMesh.Raycast(mesh, inDoor, v(2, 0, 2))
	print(`  Raycast: blocked={blocked}, stop={f(stop)}`)
	print(`  FindDistanceToWall: {NavMesh.FindDistanceToWall(mesh, inDoor, 5)}`)
	local ok, moved = pcall(NavMesh.MoveAlongSurface, mesh, inDoor, v(2, 0, 2))
	print(`  MoveAlongSurface: {if ok then `Status {moved.Status}, Position {f(moved.Position)}` else moved}`)
	local rescue = NavMesh.FindNearestPoint(mesh, inDoor, nil, 2)
	print(`  FindNearestPoint with searchRadius 2: {f(rescue and rescue.Position)}`)
	local fallback = NavMesh.FindPath(mesh, v(2, 0, 10), v(10.5, 0, 10), { GoalFallback = true })
	print(
		`  FindPath to a goal inside the door, GoalFallback: {fallback.Status}, ends at {f(
			fallback.Waypoints[#fallback.Waypoints].Position
		)}`
	)
end

print("\n== 6. On a small level every Update invalidates every path (one tile per floor)")
do
	local Level = require("./Level")
	local mesh = NavMesh.Build(Level.Desc)
	local tiles = 0
	for _, primitive in NavMesh.ToDrawList(mesh, { Triangles = false, Tiles = true }) do
		if primitive.Layer == "Tiles" then
			tiles += 1
		end
	end
	local far = NavMesh.FindPath(mesh, v(2, 0, 2), v(8, 0, 2)) -- 38 studs from the door
	NavMesh.AddObstacle(mesh, "Ground", Level.DOOR)
	NavMesh.Update(mesh)
	print(
		`  {tiles // 4} tiles in the demo level; a 6-stud path 38 studs from the door is valid after the door closes: {NavMesh.IsPathValid(
			mesh,
			far
		)}`
	)
end

print("\n== 7. Waypoints skip slope changes: lerping Y between them lands on the floor below")
do
	local mesh = NavMesh.Build({
		Floors = {
			-- Ground runs on under Top (an overhang); only the ramp's footprint is solid.
			Ground = { Walkable = { rect(0, 0, 0, 50, 20) }, Obstacles = { rect(0, 10, 0, 20, 20) } },
			Ramp = { Walkable = { { v(10, 0, 0), v(20, 5, 0), v(20, 5, 20), v(10, 0, 20) } } },
			Top = { Walkable = { rect(5, 20, 0, 50, 20) } },
		},
		Seams = {
			{ FloorA = "Ground", FloorB = "Ramp", From = v(10, 0, 0), To = v(10, 0, 20) },
			{ FloorA = "Ramp", FloorB = "Top", From = v(20, 5, 0), To = v(20, 5, 20) },
		},
	} :: any)
	local path = NavMesh.FindPath(mesh, v(2, 0, 10), v(48, 5, 10))
	local points = {}
	for _, w in path.Waypoints do
		table.insert(points, `{f(w.Position)} {w.Floor}`)
	end
	print(`  {path.Status}: {table.concat(points, " -> ")}`)
	local a, b = path.Waypoints[1].Position, path.Waypoints[#path.Waypoints].Position
	local mid = a + (b - a) * ((19.8 - a.X) / (b.X - a.X)) -- where the path is about to top the ramp
	local snapped = NavMesh.FindNearestPoint(mesh, mid)
	print(
		`  straight 3D segment at x 19.8 = {f(mid)}; the ramp surface there is y 4.9; FindNearestPoint puts it at {f(
			snapped and snapped.Position
		)} on {snapped and snapped.Floor or "nil"}`
	)
end

print("\n== 8. Removed obstacles are never freed: a door toggling all day slows Update and grows the bake")
do
	local mesh = NavMesh.Build({ Floors = { Ground = { Walkable = { rect(0, 0, 0, 20, 20) } } } } :: any)
	local door: number? = nil
	local function toggle(): number
		if door then
			NavMesh.RemoveObstacle(mesh, door)
			door = nil
		else
			door = NavMesh.AddObstacle(mesh, "Ground", rect(0, 9, 5, 11, 15))
		end
		local t0 = os.clock()
		NavMesh.Update(mesh)
		return (os.clock() - t0) * 1000
	end
	local done = 0
	for _, n in { 10, 1000, 4000 } do
		while done < n do
			toggle()
			done += 1
		end
		local total = 0
		for _ = 1, 20 do
			total += toggle()
		end
		done += 20
		print(
			string.format(
				"  after %4d toggles: Update %.3f ms, Serialize %d bytes",
				n,
				total / 20,
				buffer.len(NavMesh.Serialize(mesh))
			)
		)
	end
end

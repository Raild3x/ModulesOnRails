--!strict
-- Minimal repros for REPORT.md's pain points. Each prints what it shows.
--   lune run examples/navmesh-demo2/repros.luau
local fs = require("@lune/fs")
local roblox = require("@lune/roblox") :: any
local NavMesh = require("../../lib/navmesh/src/NavMesh")
local Adapter = require("../../lib/navmeshadapter/src/NavMeshAdapter")
local BakeText = require("./BakeText")

local v = vector.create
local function rect(y: number, x0: number, z0: number, x1: number, z1: number): { vector }
	return { v(x0, y, z0), v(x1, y, z0), v(x1, y, z1), v(x0, y, z1) }
end
local function f(p: any): string
	return if p then string.format("(%.1f, %.1f, %.1f)", p.X, p.Y, p.Z) else "nil"
end
local function box(r: any): string
	return string.format(
		"%s (%.0f, %.0f)-(%.0f, %.0f), %.0f x %.0f studs",
		r.Floor,
		r.Min.X,
		r.Min.Z,
		r.Max.X,
		r.Max.Z,
		r.Max.X - r.Min.X,
		r.Max.Z - r.Min.Z
	)
end
local function same(a: any, b: any): boolean
	if #a.Waypoints ~= #b.Waypoints then
		return false
	end
	for i, w in a.Waypoints do
		if vector.magnitude(w.Position - b.Waypoints[i].Position) > 1e-6 then
			return false
		end
	end
	return true
end
local function warehouse(): any
	return NavMesh.Deserialize(BakeText.Load { fs.readFile("examples/navmesh-demo2/NavMeshBake/1.txt") })
end

print("== 1. A ChangedRegion is the whole rebuilt tile: a 4x4 crate reports a 128 x 128 box")
do
	local mesh = warehouse()
	local from, to, filter = v(150, 0, 100), v(250, 0, 100), { AgentRadius = 1 }
	local before = NavMesh.FindPath(mesh, from, to, filter)
	NavMesh.AddObstacle(mesh, "Ground", rect(0, 198, 18, 202, 22))
	local regions = NavMesh.Update(mesh)
	for _, r in regions do
		print("  region " .. box(r))
	end
	local after = NavMesh.FindPath(mesh, from, to, filter)
	print(
		string.format(
			"  a path along z = 100, 78 studs from the crate, lies in that box; FindPath after the Update returns the same path: %s",
			tostring(same(before, after))
		)
	)
	print("  the crate's own footprint grown by MaxAgentRadius 2 would be 8 x 8 studs (256 times smaller)")
end

print("\n== 2. A ChangedRegion does not say whether it opened or blocked: add and remove give the same box")
do
	local mesh = warehouse()
	local id = NavMesh.AddObstacle(mesh, "Ground", rect(0, 198, 18, 202, 22))
	print("  add:    " .. box(NavMesh.Update(mesh)[1]))
	NavMesh.RemoveObstacle(mesh, id)
	print("  remove: " .. box(NavMesh.Update(mesh)[1]))
	print("  so an agent on a Partial path cannot tell whether to retry; a crate hop (remove + add) is both")
end

-- Two 20 x 20 rooms joined by a 4-stud doorway in a wall at x 20.
local function rooms(): any
	return NavMesh.Build {
		Floors = {
			Ground = {
				Walkable = { rect(0, 0, 0, 40, 20) },
				Obstacles = { rect(0, 19, 0, 21, 8), rect(0, 19, 12, 21, 20) },
			},
		},
		MaxAgentRadius = 2,
	}
end

print("\n== 3. FindRandomPoint returns points the agent cannot reach (behind a shut door)")
do
	local mesh = rooms()
	NavMesh.AddObstacle(mesh, "Ground", rect(0, 19, 8, 21, 12)) -- the door shuts
	NavMesh.Update(mesh)
	local state = 7
	local function rng(): number
		state = (state * 1103515245 + 12345) % 2147483648
		return state / 2147483648
	end
	local filter = { AgentRadius = 0.5 }
	local partial = 0
	for _ = 1, 200 do
		local p = NavMesh.FindRandomPoint(mesh, { Filter = filter, Center = v(10, 0, 10), Radius = 30, Rng = rng })
		local path = NavMesh.FindPath(mesh, v(10, 0, 10), (p :: any).Position, filter)
		partial += if path.Status == "Partial" then 1 else 0
	end
	print(
		string.format(
			"  200 wander goals from (10, 0, 10), radius 30: %d give a Partial path (the other room)",
			partial
		)
	)
end

print("\n== 4. An obstacle landing on an agent: FindPath says NoStart even with GoalFallback")
do
	local mesh = rooms()
	local feet, filter = v(10, 0, 10), { AgentRadius = 0.5, GoalFallback = true }
	NavMesh.AddObstacle(mesh, "Ground", rect(0, 8, 8, 12, 12)) -- a crate lands on it
	NavMesh.Update(mesh)
	print("  FindPath:         " .. NavMesh.FindPath(mesh, feet, v(30, 0, 10), filter).Status)
	print("  MoveAlongSurface: " .. NavMesh.MoveAlongSurface(mesh, feet, v(30, 0, 10), filter).Status)
	local back = NavMesh.FindNearestPoint(mesh, feet, filter, 6)
	print("  FindNearestPoint(searchRadius 6): " .. f(back and back.Position))
	print("  every FindPath call site needs that rescue; the goal has GoalFallback, the start has nothing")
end

print("\n== 5. AddObstacle takes a floor name and no height: a crate on the deck added to Ground cuts the ground")
do
	-- A deck 10 studs above the ground, over x 10..30.
	local mesh = NavMesh.Build {
		Floors = {
			Ground = { Walkable = { rect(0, 0, 0, 40, 20) } },
			Deck = { Walkable = { rect(10, 10, 0, 30, 20) } },
		},
		MaxAgentRadius = 2,
	}
	NavMesh.AddObstacle(mesh, "Ground", rect(10, 18, 0, 22, 20)) -- meant for Deck: no error
	NavMesh.Update(mesh)
	print("  ground under the deck: " .. NavMesh.FindPath(mesh, v(2, 0, 10), v(38, 0, 10)).Status .. " (blocked)")
	print(
		"  deck through the crate: "
			.. NavMesh.FindPath(mesh, v(12, 10, 10), v(28, 10, 10)).Status
			.. " (walks through it)"
	)
	local on = NavMesh.FindNearestPoint(mesh, v(20, 10, 10))
	print(
		"  the game has to find the floor itself, e.g. FindNearestPoint at the crate's base: "
			.. (on and on.Floor or "nil")
	)
end

print("\n== 6. The Part adapter converts a level once; one Part's footprint for AddObstacle is up to the game")
do
	local keys = {}
	for key in Adapter do
		table.insert(keys, key)
	end
	print("  NavMeshAdapter exports: " .. table.concat(keys, ", "))
	local ground = roblox.Instance.new("Part")
	ground.Name = "Ground"
	ground.Size, ground.CFrame = roblox.Vector3.new(40, 1, 20), roblox.CFrame.new(20, -0.5, 10)
	local door = roblox.Instance.new("Part")
	door.Size = roblox.Vector3.new(1, 10, 4)
	door.CFrame = roblox.CFrame.new(20, 5, 10) * roblox.CFrame.Angles(0, math.rad(30), 0)
	local t0 = os.clock()
	local ring = Adapter.FromParts({ ground }, { door }).Floors.Ground.Obstacles[1]
	print(
		string.format(
			"  workaround: FromParts({ floorPart }, { door }) cuts the door's ring (%d points, %.2f ms), but needs the floor's Part",
			#ring,
			(os.clock() - t0) * 1000
		)
	)
end

print("\n== 7. (KNOWN, ticket 25) A path up a ramp has no waypoint at the ramp's foot or top")
do
	local path = NavMesh.FindPath(warehouse(), v(100, 0, 116), v(210, 10, 120), { AgentRadius = 1 })
	for _, w in path.Waypoints do
		print(`  {f(w.Position)} {w.Floor}`)
	end
	local a, b = path.Waypoints[1].Position, path.Waypoints[2].Position
	local y = a.Y + (b.Y - a.Y) * (170 - a.X) / (b.X - a.X)
	print(string.format("  interpolated at the ramp top (x 170): y %.1f, but the surface there is at y 10", y))
end

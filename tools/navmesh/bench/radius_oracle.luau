--!strict
-- Ticket 27 oracle: every FindPath Success -> Partial flip (the old build vs this one) over
-- random radius queries must be a real block: the two ends disconnected in the liberal grid
-- flood of Tests/Helpers/Flood.luau (a proof they are parted). If the flood connects them, the
-- flip is refuted. Half the ends are aimed near wall corners; half the queries are fair (both
-- ends clear of every wall by r), the rest may start touching a wall, as the ticket's repro does.
--   lune run tools/navmesh/bench/radius_oracle.luau [queries per config] [max flips] [seed offset]
-- The old build is lib/navmesh/src_old: a copy of the sources before the change, e.g.
--   git archive <base> lib/navmesh/src | tar -x -C <tmp>, then move it there.
local process = require("@lune/process")
local NavMesh = require("../../../lib/navmesh/src/NavMesh")
local Storage = require("../../../lib/navmesh/src/Storage")
local Flood = require("../../../lib/navmesh/src/Tests/Helpers/Flood")
local Old = require("../../../lib/navmesh/src_old/NavMesh")
local Scenes = require("./Scenes")

local perScene = tonumber(process.args[1]) or 150
local maxFlips = tonumber(process.args[2]) or math.huge -- stop early (negative-control runs)
local seedOffset = tonumber(process.args[3]) or 0
-- Luau's seeded PCG: a float LCG over 2^31 loses bits above 2^53 and cycles in a few thousand.
local function makeRng(seed: number): (number, number) -> number
	math.randomseed(seed)
	return function(lo: number, hi: number): number
		return lo + math.random() * (hi - lo)
	end
end

-- The ticket 27 repro, many times: slabs standing on the bottom wall of a long room, each
-- stopping 0.5-2 studs short of the top wall, in one big tile (slivers along the top wall).
local notches = {
	Name = "notches",
	Side = 64,
	Make = function()
		local rng = makeRng(27)
		local obstacles = {}
		local x = 2
		while x < 60 do
			local w, gap = rng(0.5, 2), rng(0.5, 2)
			table.insert(obstacles, {
				vector.create(x, 0, -1),
				vector.create(x + w, 0, -1),
				vector.create(x + w, 0, 10 - gap),
				vector.create(x, 0, 10 - gap),
			})
			x += w + rng(2, 6)
		end
		local walkable =
			{ vector.create(0, 0, 0), vector.create(64, 0, 0), vector.create(64, 0, 10), vector.create(0, 0, 10) }
		return { Floors = { Ground = { Walkable = { walkable }, Obstacles = obstacles } } }
	end,
}
local scenes = { notches }
for _, scene in Scenes do
	if scene.Name ~= "terrain" then -- huge open map: no slivers near walls worth the flood time
		table.insert(scenes, scene)
	end
end

local totals = { queries = 0, flips = 0, fair = 0, confirmed = 0, refuted = 0, gained = 0 }
for _, scene in scenes do
	for _, tileSize in { 64, 16 } do
		local desc = scene.Make()
		desc.TileSize = tileSize
		local mesh, old = NavMesh.Build(desc), Old.Build(desc)
		local oracle = Flood.New(mesh)
		local clearance = oracle.Clearance
		local function onMesh(_, x: number, z: number): boolean
			return Flood.OnMesh(oracle, x, z)
		end
		local rng = makeRng(tileSize * 7 + #scene.Name + seedOffset * 1000)
		-- Wall vertices, to aim half the queries near corners, where the gaps are.
		local corners = {}
		for v = 1, Storage.VertexCount(mesh) do
			if Storage.IsWallVertex(mesh, v) then
				table.insert(corners, Storage.GetVertex(mesh, v))
			end
		end
		local function near(r: number): vector
			local c = corners[math.floor(rng(1, #corners + 1))]
			local angle, d = rng(0, 2 * math.pi), rng(r, 3 * r)
			return vector.create(c.X + d * math.cos(angle), 0, c.Z + d * math.sin(angle))
		end
		local n = 0
		while n < perScene do
			local r = if scene.Name == "notches" then rng(0.2, 1.1) else rng(0.3, 2)
			local a = if n % 2 == 0 then near(r) else vector.create(rng(0, scene.Side), 0, rng(0, scene.Side))
			local b = if n % 4 < 2 then near(r) else vector.create(rng(0, scene.Side), 0, rng(0, scene.Side))
			-- Both ends on the mesh. Fair queries (every other one) also have both clear of every
			-- wall by r, so the agent fits where it stands; the rest may start touching a wall, as
			-- the ticket's repro does (the flood then starts from the end's own cell).
			local fair = n % 8 < 4
			if
				not onMesh(mesh, a.X, a.Z)
				or not onMesh(mesh, b.X, b.Z)
				or (fair and (clearance(a.X, a.Z, r + 0.1) < r or clearance(b.X, b.Z, r + 0.1) < r))
			then
				continue
			end
			n += 1
			local filter = { AgentRadius = r }
			local before = Old.FindPath(old, a, b, filter).Status
			local after = NavMesh.FindPath(mesh, a, b, filter).Status
			if before == "Success" and after == "Partial" then
				if totals.flips >= maxFlips then
					continue
				end
				totals.flips += 1
				if fair then
					totals.fair += 1
				end
				if Flood.Connected(oracle, r, a, b) then
					totals.refuted += 1
					print(
						string.format(
							"REFUTED %s ts=%d r=%.3f (%.3f, %.3f) -> (%.3f, %.3f) fair=%s",
							scene.Name,
							tileSize,
							r,
							a.X,
							a.Z,
							b.X,
							b.Z,
							tostring(fair)
						)
					)
				else
					totals.confirmed += 1
				end
			elseif before ~= after then
				totals.gained += 1
				print(string.format("CHANGED %s ts=%d %s -> %s r=%.3f", scene.Name, tileSize, before, after, r))
			end
		end
		totals.queries += n
	end
end
print(
	string.format(
		"ORACLE queries %d flips %d (fair %d) confirmed %d refuted %d other changes %d",
		totals.queries,
		totals.flips,
		totals.fair,
		totals.confirmed,
		totals.refuted,
		totals.gained
	)
)

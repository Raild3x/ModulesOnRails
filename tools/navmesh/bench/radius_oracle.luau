--!strict
-- Ticket 27 oracle: every FindPath Success -> Partial flip (the old build vs this one) over
-- random radius queries must be a real block: the two ends disconnected in the liberal grid
-- flood of Tests/Helpers/Flood.luau (a proof they are parted). If the flood connects them, the
-- flip is refuted. Half the ends are aimed near wall corners; half the queries are fair (both
-- ends clear of every wall by r), the rest may start touching a wall, as the ticket's repro does.
--   lune run tools/navmesh/bench/radius_oracle.luau [queries per config] [max flips] [seed offset] [links]
-- With `links` (E3) it runs the link and seam scenes instead (see withLinks below).
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

-- E3: the same scenes with links (`count` of them, half one-way, half their ends near wall
-- corners where the slivers are), and props split into two floors joined by a seam down
-- x = 32. The flood takes links (Flood.luau) and sees the two side-by-side floors as one plane.
local function withLinks(scene: any, count: number): any
	return {
		Name = scene.Name .. "+links",
		Side = scene.Side,
		Make = function()
			local desc = scene.Make()
			desc.TileSize = 64
			local base = NavMesh.Build(desc)
			local oracle = Flood.New(base)
			local corners = {}
			for v = 1, Storage.VertexCount(base) do
				if Storage.IsWallVertex(base, v) then
					table.insert(corners, Storage.GetVertex(base, v))
				end
			end
			local rng = makeRng(count * 31 + #scene.Name)
			local function point(nearCorner: boolean): vector
				while true do
					local p
					if nearCorner then
						local c = corners[math.floor(rng(1, #corners + 1))]
						local angle, d = rng(0, 2 * math.pi), rng(0.1, 2)
						p = vector.create(c.X + d * math.cos(angle), 0, c.Z + d * math.sin(angle))
					else
						p = vector.create(rng(0, scene.Side), 0, rng(0, scene.Side))
					end
					if Flood.OnMesh(oracle, p.X, p.Z) then
						return p
					end
				end
			end
			local links = {}
			for i = 1, count do
				table.insert(links, { From = point(i % 2 == 0), To = point(i % 4 < 2), Bidirectional = i % 3 ~= 0 })
			end
			desc.Links = links
			return desc
		end,
	}
end
local seamed = {
	Name = "props+seam",
	Side = 64,
	Make = function()
		local desc = Scenes[1].Make()
		local west, east = {}, {}
		for _, ring in desc.Floors.Ground.Obstacles do
			local lo, hi = math.huge, -math.huge
			for _, p in ring do
				lo, hi = math.min(lo, p.X), math.max(hi, p.X)
			end
			if hi < 32 then
				table.insert(west, ring)
			elseif lo > 32 then
				table.insert(east, ring)
			end
		end
		local function half(x0: number, x1: number): { vector }
			return {
				vector.create(x0, 0, 0),
				vector.create(x1, 0, 0),
				vector.create(x1, 0, 64),
				vector.create(x0, 0, 64),
			}
		end
		return {
			Floors = {
				West = { Walkable = { half(0, 32) }, Obstacles = west },
				East = { Walkable = { half(32, 64) }, Obstacles = east },
			},
			Seams = {
				{ FloorA = "West", FloorB = "East", From = vector.create(32, 0, 0), To = vector.create(32, 0, 64) },
			},
		}
	end,
}
if process.args[4] == "links" then
	scenes = { withLinks(notches, 12), withLinks(Scenes[1], 40), withLinks(Scenes[4], 60), seamed }
	table.insert(scenes, withLinks(Scenes[2], 60))
end

local totals =
	{ queries = 0, flips = 0, fair = 0, confirmed = 0, refuted = 0, gained = 0, unsound = 0, unstandable = 0 }
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
		-- And at link ends, as often as at all the corners (E3: landings in end triangles).
		local wallCorners = #corners
		for _ = 1, if Storage.LinkCount(mesh) > 0 then wallCorners // (2 * Storage.LinkCount(mesh)) + 1 else 0 do
			for id = 1, Storage.LinkCount(mesh) do
				local _, from, _, to = Storage.GetLink(mesh, id)
				table.insert(corners, from)
				table.insert(corners, to)
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
				-- A new Success the flood proves impossible would be unsound (E3's extra nodes let a
				-- path back into a triangle), unless the path stops at a point the agent can't
				-- stand at (an end or a link end in a corner): the search then takes it as cut off
				-- from nothing, as ticket 27 does, while the flood can't leave it.
				local proven = ""
				if after == "Success" and not Flood.Connected(oracle, r, a, b) then
					local standsAll = true
					for _, w in NavMesh.FindPath(mesh, a, b, filter).Waypoints do
						local p = w.Position :: any
						local d, qx, qz = oracle.Nearest(p.X, p.Z, r)
						if d < r * (1 - 1e-6) then
							local ok = qx ~= nil and qz ~= nil and d > 0
							if ok then
								local x, z = qx + (p.X - qx) * r / d, qz + (p.Z - qz) * r / d
								ok = clearance(x, z, r) >= r * (1 - 1e-9)
							end
							standsAll = standsAll and ok
						end
					end
					if standsAll then
						totals.unsound += 1
						proven = " UNSOUND"
					else
						totals.unstandable += 1
						proven = " (flood stuck at a point that can't stand)"
					end
				end
				print(
					string.format(
						"CHANGED %s ts=%d %s -> %s r=%.3f (%.3f, %.3f) -> (%.3f, %.3f)%s",
						scene.Name,
						tileSize,
						before,
						after,
						r,
						a.X,
						a.Z,
						b.X,
						b.Z,
						proven
					)
				)
			end
		end
		totals.queries += n
	end
end
print(
	string.format(
		"ORACLE queries %d flips %d (fair %d) confirmed %d refuted %d other changes %d (unsound %d, flood stuck %d)",
		totals.queries,
		totals.flips,
		totals.fair,
		totals.confirmed,
		totals.refuted,
		totals.gained,
		totals.unsound,
		totals.unstandable
	)
)

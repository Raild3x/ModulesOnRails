-- Authors: Logan Hunt (Raildex)
-- October 1, 2026
-- Track E, E3: ticket 27's radius barriers at link and seam entries. A link's landing, and a
-- link's start in the start triangle, are points the agent must reach inside their triangles;
-- a triangle entered across a seam is left by the corner width from the seam edge.

return function(t: tiniest)
	local Flood = require("./Helpers/Flood")
	local NavMesh = require("../NavMesh")
	local Snap = require("../Snap")

	local describe = t.describe
	local expect = t.expect
	local test = t.test

	local function v(x: number, y: number, z: number): any
		return vector.create(x, y, z)
	end

	local function fmt(p: any): string
		return string.format("%.4f,%.4f,%.4f", p.X, p.Y, p.Z)
	end

	local function flat(y: number, xz: { number }): any
		local ring = {}
		for i = 1, #xz, 2 do
			table.insert(ring, vector.create(xz[i], y, xz[i + 1]))
		end
		return ring
	end

	local function status(mesh: any, a: any, b: any, r: number): string
		return NavMesh.FindPath(mesh, a, b, { AgentRadius = r }).Status
	end

	-- Ticket 27's room: 20 x 10, one tile, a slab from the south wall (or from z = slabFrom,
	-- floating, with the room reaching z = south) to z = 9, so a 1-stud gap over it. The sliver
	-- (0, 10) (10, 9) (20, 10) spans the gap: (9.6, 9.5) is west of it, (12, 9.45) east. An
	-- island (30..40, 0..10) is reachable only by link.
	local west, east, island = v(9.6, 0, 9.5), v(12, 0, 9.45), v(35, 0, 5)
	local function room(links: { any }, south: number?, slabFrom: number?): any
		return NavMesh.Build {
			TileSize = 64,
			Floors = {
				Ground = {
					Walkable = {
						flat(0, { 0, south or 0, 20, south or 0, 20, 10, 0, 10 }),
						flat(0, { 30, 0, 40, 0, 40, 10, 30, 10 }),
					},
					Obstacles = { flat(0, { 10, slabFrom or -1, 11, slabFrom or -1, 11, 9, 10, 9 }) },
				},
			},
			Links = links,
		}
	end
	local function link(from: any, to: any, label: string?, cost: number?): any
		return { From = from, To = to, Bidirectional = false, Label = label, Cost = cost }
	end
	local extents = vector.create(0.5, 4, 0.5)

	-- Two floors side by side, joined by a seam on A's slanted edge (0, 10)-(10, 9). B's
	-- triangle on the seam is (0, 10) (10, 9) (20, 10): leaving it for the rest of B passes
	-- between the wall corner (10, 9) and B's north wall, 1 stud apart (its corner width), while
	-- both its other edges' portal widths are above 1.7.
	local function seamed(): any
		return NavMesh.Build {
			TileSize = 64,
			Floors = {
				A = { Walkable = { flat(0, { 0, 0, 10, 0, 10, 9, 0, 10 }) } },
				B = { Walkable = { flat(0, { 0, 10, 10, 9, 20, 0, 20, 10 }) } },
			},
			Seams = { { FloorA = "A", FloorB = "B", From = v(0, 0, 10), To = v(10, 0, 9) } },
		}
	end

	describe("FindPath radius at link and seam entries (E3)", function()
		test("a link landing in the goal triangle behind a gap narrower than 2r doesn't reach the goal", function()
			local mesh = room { link(v(3, 0, 3), west) }
			expect(Snap.Snap(mesh, west, extents, {})).is(Snap.Snap(mesh, east, extents, {}))
			expect(status(mesh, v(5, 0, 5), east, 0.51)).is("Partial")
			expect(status(mesh, v(5, 0, 5), east, 0.49)).is("Success")
			-- The flood agrees: the landing and the goal are parted at 0.51.
			expect(Flood.Connected(Flood.New(mesh), 0.51, v(5, 0, 5), east)).is(false)
		end)

		test("a link starting in the start triangle past a gap is out of reach, until the way round", function()
			local closed = room { link(east, island) }
			expect(status(closed, west, island, 0.51)).is("Partial")
			expect(status(closed, west, island, 0.49)).is("Success")
			expect(status(closed, v(12.5, 0, 9.45), island, 0.51)).is("Success")
			-- A floating slab: the start leaves its triangle, goes under the slab and comes back
			-- into it (the start-again node) to take the link.
			local open = room({ link(east, island) }, -6, -3)
			expect(Snap.Snap(open, west, extents, {})).is(Snap.Snap(open, east, extents, {}))
			local round = NavMesh.FindPath(open, west, island, { AgentRadius = 0.51 })
			expect(round.Status).is("Success")
			local lowest = math.huge
			for _, w in round.Waypoints do
				lowest = math.min(lowest, (w.Position :: any).Z)
			end
			expect(lowest < -3).with_context(tostring(lowest)).is_true()
			expect(#NavMesh.FindPath(open, west, island, { AgentRadius = 0.49 }).Waypoints).is(3)
		end)

		test("a link start against a wall, standing just outside its triangle, is a step from the start", function()
			-- (15, 9.95) pushed off the north wall stands under the sliver: from east of the gap the
			-- agent walks there. Read as parted, the link would need a way back into the sliver.
			local mesh = room { link(v(15, 0, 9.95), island) }
			expect(Snap.Snap(mesh, v(15, 0, 9.95), extents, {})).is(Snap.Snap(mesh, east, extents, {}))
			expect(status(mesh, east, island, 0.51)).is("Success")
			expect(Flood.Connected(Flood.New(mesh), 0.51, east, island)).is(true)
			-- From west of the gap it is out of reach.
			expect(status(mesh, west, island, 0.51)).is("Partial")
		end)

		test("leaving a link's landing triangle needs the landing to reach the exit edge", function()
			local mesh = room { link(island, west) }
			local path = NavMesh.FindPath(mesh, island, v(15, 0, 5), { AgentRadius = 0.51 })
			expect(path.Status).is("Partial")
			-- The Partial end stays on the landing's side of the gap.
			local last = path.Waypoints[#path.Waypoints].Position :: any
			expect(last.X <= 10).with_context(fmt(last)).is_true()
			expect(status(mesh, island, v(15, 0, 5), 0.49)).is("Success")
			expect(status(mesh, island, v(5, 0, 5), 0.51)).is("Success")
			-- The flood takes the link one way only, and not past the gap.
			local oracle = Flood.New(mesh)
			expect(Flood.Connected(oracle, 0.51, island, v(5, 0, 5))).is(true)
			expect(Flood.Connected(oracle, 0.51, v(5, 0, 5), island)).is(false)
			expect(Flood.Connected(oracle, 0.51, island, v(15, 0, 5))).is(false)
		end)

		test("a seam on the edge just crossed is taken with a radius (ground running on under a ramp)", function()
			-- ThreeFloorStairs: the Ground seam edge at x = 10 keeps its Ground neighbour, so from
			-- under the ramp a path crosses that edge west, then takes the seam on it onto the
			-- ramp. That step reads the edge's own width (a corner index 6 - 2e names no corner).
			local mesh = NavMesh.Build(NavMesh.Fixtures.ThreeFloorStairs.Desc)
			for _, r in { 0, 0.45, 1.1 } do
				expect(status(mesh, v(15, 0, 2), v(30, 5, 2), r)).with_context(`r {r}`).is("Success")
			end
		end)

		test("a triangle a link lands in is still entered by its edges, and left by another link", function()
			-- A cheap link lands west of the gap, where the second link's start (east of it) is out
			-- of reach. The way that works walks into the sliver from the east room: that entry
			-- must not be dropped because the landing entered the sliver first.
			local mesh = room { link(v(15, 0, 2), west, "L1", 0.1), link(east, island, "L2", 0.1) }
			local path = NavMesh.FindPath(mesh, v(15, 0, 1), island, { AgentRadius = 0.51 })
			expect(path.Status).is("Success")
			local labels = {}
			for _, w in path.Waypoints do
				if w.Label then
					table.insert(labels, w.Label)
				end
			end
			expect(table.concat(labels, " ")).is("L2")
			-- A narrow agent takes the cheap link and walks through the gap.
			local narrow = NavMesh.FindPath(mesh, v(15, 0, 1), island, { AgentRadius = 0.49 })
			expect(narrow.Waypoints[2].Label).is("L1")
		end)

		test("a link's landing must reach a seam it leaves by", function()
			-- The sliver (0, 10) (10, 9) (20, 10) on floor B, its east edge a seam to floor A
			-- (portal width 1.82). A link from B's island lands west of the 1-stud pinch at (10, 9),
			-- cut off from the seam edge.
			local mesh = NavMesh.Build {
				TileSize = 64,
				Floors = {
					A = { Walkable = { flat(0, { 10, 9, 20, 0, 20, 10 }) } },
					B = {
						Walkable = {
							flat(0, { 0, 0, 10, 0, 10, 9, 20, 10, 0, 10 }),
							flat(0, { 30, 0, 40, 0, 40, 10, 30, 10 }),
						},
					},
				},
				Seams = { { FloorA = "A", FloorB = "B", From = v(10, 0, 9), To = v(20, 0, 10) } },
				Links = { link(island, west) },
			}
			expect(status(mesh, island, v(17, 0, 7), 0.51)).is("Partial")
			expect(status(mesh, island, v(17, 0, 7), 0.49)).is("Success")
			expect(Flood.Connected(Flood.New(mesh), 0.51, island, v(17, 0, 7))).is(false)
		end)

		test("a Partial end in a triangle reached only by a link is judged from the landing", function()
			-- A one-triangle pad between the island and an unreachable goal, reached by a link: its
			-- point nearest the goal is the best end, and the landing reaches it.
			local mesh = NavMesh.Build {
				TileSize = 64,
				Floors = {
					Ground = {
						Walkable = {
							flat(0, { 0, 0, 20, 0, 20, 10, 0, 10 }),
							flat(0, { 22, 4, 24, 5, 22, 6 }),
							flat(0, { 30, 0, 40, 0, 40, 10, 30, 10 }),
						},
					},
				},
				Links = { link(v(33, 0, 5), v(23, 0, 5)) },
			}
			local path = NavMesh.FindPath(mesh, island, v(15, 0, 5), { AgentRadius = 0.4 })
			expect(path.Status).is("Partial")
			local last = path.Waypoints[#path.Waypoints].Position :: any
			expect(last.X > 22 and last.X < 24).with_context(fmt(last)).is_true()
		end)

		test("a triangle entered across a seam is left by the corner width from the seam edge", function()
			local mesh = seamed()
			expect(status(mesh, v(5, 0, 5), v(17, 0, 7), 0.51)).is("Partial")
			expect(status(mesh, v(17, 0, 7), v(5, 0, 5), 0.51)).is("Partial")
			expect(status(mesh, v(5, 0, 5), v(17, 0, 7), 0.49)).is("Success")
			expect(Flood.Connected(Flood.New(mesh), 0.51, v(5, 0, 5), v(17, 0, 7))).is(false)
		end)

		test("a seam entry doesn't U-turn back over its seam to dodge a corner width", function()
			-- The bench `props` room (512 props, tools/navmesh/bench/Scenes.luau) split into two
			-- floors at x = 32, joined by a seam the whole way. A triangle on the seam, entered by
			-- an edge whose corner width onward is too narrow, could otherwise step over the seam
			-- and straight back, then leave with the seam edge as its entry edge. The flood (both
			-- floors are one plane to it) proves the way blocked. Found by radius_oracle.luau.
			local state = 3
			local function rng(lo: number, hi: number): number
				state = (state * 1103515245 + 12345) % 2147483648
				return lo + (state / 2147483648) * (hi - lo)
			end
			local west, east = {}, {}
			for _ = 1, 512 do
				local cx, cz, w, d, angle = rng(0, 64), rng(0, 64), rng(0.3, 2), rng(0.3, 2), rng(0, math.pi)
				local c, s = math.cos(angle), math.sin(angle)
				local ring, lo, hi = {}, math.huge, -math.huge
				for _, k in { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } } do
					local x, z = k[1] * w / 2, k[2] * d / 2
					local p = v(cx + x * c - z * s, 0, cz + x * s + z * c)
					table.insert(ring, p)
					lo, hi = math.min(lo, p.X), math.max(hi, p.X)
				end
				if hi < 32 then
					table.insert(west, ring)
				elseif lo > 32 then
					table.insert(east, ring)
				end
			end
			local mesh = NavMesh.Build {
				TileSize = 16,
				Floors = {
					West = { Walkable = { flat(0, { 0, 0, 32, 0, 32, 64, 0, 64 }) }, Obstacles = west },
					East = { Walkable = { flat(0, { 32, 0, 64, 0, 64, 64, 32, 64 }) }, Obstacles = east },
				},
				Seams = { { FloorA = "West", FloorB = "East", From = v(32, 0, 0), To = v(32, 0, 64) } },
			}
			local a, b = v(37.252, 0, 50.675), v(32.587, 0, 59.598)
			expect(status(mesh, a, b, 1.905)).is("Partial")
			expect(Flood.Connected(Flood.New(mesh), 1.905, a, b)).is(false)
		end)

		test("at radius 0 nothing changes: every link and seam above is used", function()
			local function cost(mesh: any, a: any, b: any): string
				local path = NavMesh.FindPath(mesh, a, b)
				return string.format("%s %.4f", path.Status, path.Cost)
			end
			-- Walk to the link, pay its 3D length, walk on.
			expect(cost(room { link(v(3, 0, 3), west) }, v(3, 0, 3), west)).is(
				string.format("Success %.4f", vector.magnitude(west - v(3, 0, 3)))
			)
			expect(cost(room { link(east, island) }, west, island)).is(
				string.format("Success %.4f", vector.magnitude(east - west) + vector.magnitude(island - east))
			)
			expect(cost(room { link(island, west) }, island, west)).is(
				string.format("Success %.4f", vector.magnitude(west - island))
			)
			local both = room { link(v(15, 0, 2), west, "L1", 0.1), link(east, island, "L2", 0.1) }
			expect(NavMesh.FindPath(both, v(15, 0, 1), island).Waypoints[2].Label).is("L1")
			-- Round the corner (10, 9), through the seam.
			local seam = NavMesh.FindPath(seamed(), v(5, 0, 5), v(17, 0, 7))
			expect(seam.Status).is("Success")
			expect(fmt(seam.Waypoints[2].Position)).is("10.0000,0.0000,9.0000")
		end)
	end)
end

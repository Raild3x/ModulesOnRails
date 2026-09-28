-- Authors: Logan Hunt (Raildex)
-- September 27, 2026
-- Floors, seams and links (ticket 16): seam portals between floors (ruling: overlap portals),
-- link labels, one-way links, link costs in the heuristic (SR7), toggles and IsPathValid (SR5).

return function(t: tiniest)
	local NavMesh = require("../NavMesh")
	local Storage = require("../Storage")

	local describe = t.describe
	local expect = t.expect
	local test = t.test

	local Fixtures = NavMesh.Fixtures

	local function v(x: number, y: number, z: number): any
		return vector.create(x, y, z)
	end

	local function flat(y: number, xz: { number }): any
		local ring = {}
		for i = 1, #xz, 2 do
			table.insert(ring, vector.create(xz[i], y, xz[i + 1]))
		end
		return ring
	end

	local function floors(path: NavMesh.PathResult): string
		local names = {}
		for _, w in path.Waypoints do
			if names[#names] ~= w.Floor then
				table.insert(names, w.Floor)
			end
		end
		return table.concat(names, ">")
	end

	local function labels(path: NavMesh.PathResult): string
		local found = {}
		for i, w in path.Waypoints do
			if w.Label then
				table.insert(found, `{i}:{w.Label}`)
			end
		end
		return table.concat(found, ",")
	end

	describe("Seams", function()
		test("a path climbs from Ground over the Stairs onto Upper, and back", function()
			local mesh = NavMesh.Build(Fixtures.ThreeFloorStairs.Desc)
			local up = NavMesh.FindPath(mesh, v(2, 0, 2), v(30, 5, 10))
			expect(up.Status).is("Success")
			local first, last = up.Waypoints[1], up.Waypoints[#up.Waypoints]
			expect(first.Floor).is("Ground")
			expect(last.Floor).is("Upper")
			expect(last.Position.Y).is(5)
			expect(NavMesh.IsPathValid(mesh, up)).is_true()
			local down = NavMesh.FindPath(mesh, v(30, 5, 10), v(2, 0, 2))
			expect(down.Status).is("Success")
			expect(down.Waypoints[#down.Waypoints].Floor).is("Ground")
		end)

		test("Ground runs on under the ramp: a seam edge can lead onto either floor", function()
			local mesh = NavMesh.Build(Fixtures.ThreeFloorStairs.Desc)
			-- Under the ramp, and far along Ground under the mezzanine.
			expect(floors(NavMesh.FindPath(mesh, v(15, 0, 2), v(2, 0, 18)))).is("Ground")
			expect(floors(NavMesh.FindPath(mesh, v(2, 0, 2), v(30, 0, 10)))).is("Ground")
		end)

		test("seam edges are open, not walls, so agents fit across them", function()
			local mesh = NavMesh.Build(Fixtures.ThreeFloorStairs.Desc)
			local open = 0
			for tri = 1, Storage.TriangleCount(mesh) do
				for e = 1, 3 do
					if Storage.IsEdgeOpen(mesh, tri, e) then
						open += 1
						expect(Storage.IsWallEdge(mesh, tri, e)).is(false)
					end
				end
			end
			-- The ramp's two ends and Upper's edge. Ground's seam edge keeps a Ground neighbour on both sides.
			expect(open).is(3)
			-- The ramp is 4 wide.
			expect(NavMesh.FindPath(mesh, v(2, 0, 2), v(30, 5, 10), { AgentRadius = 1.5 }).Status).is("Success")
			expect(NavMesh.FindPath(mesh, v(2, 0, 2), v(30, 5, 10), { AgentRadius = 2.5 }).Status).is("Partial")
		end)

		test("an excluded area on the stairs cuts the floors apart", function()
			local desc: any = table.clone(Fixtures.ThreeFloorStairs.Desc)
			desc.Floors = table.clone(desc.Floors)
			desc.Floors.Stairs = { Walkable = desc.Floors.Stairs.Walkable, Area = 2 }
			local mesh = NavMesh.Build(desc)
			local path = NavMesh.FindPath(mesh, v(2, 0, 2), v(30, 5, 10), { AreaCosts = { [2] = math.huge } })
			expect(path.Status).is("Partial")
		end)
	end)

	describe("Links", function()
		test("a link's label rides on the waypoint where it starts, both ways", function()
			local mesh = NavMesh.Build(Fixtures.LinkJump.Desc)
			local there = NavMesh.FindPath(mesh, v(2, 0, 2), v(22, 0, 8))
			expect(there.Status).is("Success")
			expect(labels(there)).is("2:Jump")
			expect(there.Waypoints[2].Position.X).is(9)
			expect(there.Waypoints[3].Position.X).is(15)
			local back = NavMesh.FindPath(mesh, v(22, 0, 8), v(2, 0, 2))
			expect(back.Status).is("Success")
			expect(labels(back)).is("2:Jump")
			expect(back.Waypoints[2].Position.X).is(15)
		end)

		test("a one-way link only goes one way", function()
			local mesh = NavMesh.Build(Fixtures.OneWayLink.Desc)
			local drop = NavMesh.FindPath(mesh, v(2, 4, 2), v(20, 0, 8))
			expect(drop.Status).is("Success")
			expect(floors(drop)).is("Ledge>Ground")
			expect(labels(drop)).is("2:Drop")
			expect(NavMesh.FindPath(mesh, v(20, 0, 8), v(2, 4, 2)).Status).is("Partial")
		end)

		test("a cheap link wins over a long walk, a dear one doesn't (SR7)", function()
			local corridor = { Walkable = { flat(0, { 0, 0, 40, 0, 40, 4, 0, 4 }) } }
			local function via(cost: number): NavMesh.PathResult
				local mesh = NavMesh.Build {
					Floors = { Ground = corridor },
					Links = { { From = v(1, 0, 2), To = v(39, 0, 2), Cost = cost, Label = "Warp" } },
				}
				return NavMesh.FindPath(mesh, v(1, 0, 2), v(39, 0, 2))
			end
			local cheap = via(1)
			expect(labels(cheap)).is("1:Warp")
			expect(cheap.Cost).is(1)
			local dear = via(100)
			expect(labels(dear)).is("")
			expect(math.abs(dear.Cost - 38) < 1e-6).is_true()
			-- A free link makes the heuristic 0 (Dijkstra) and is still taken.
			expect(via(0).Cost).is(0)
		end)

		test("a link's area is filtered like a surface area", function()
			local mesh = NavMesh.Build {
				Floors = { Ground = { Walkable = { flat(0, { 0, 0, 40, 0, 40, 4, 0, 4 }) } } },
				Links = { { From = v(1, 0, 2), To = v(39, 0, 2), Cost = 1, Area = 5 } },
			}
			expect(NavMesh.FindPath(mesh, v(1, 0, 2), v(39, 0, 2)).Cost).is(1)
			local walked = NavMesh.FindPath(mesh, v(1, 0, 2), v(39, 0, 2), { AreaCosts = { [5] = math.huge } })
			expect(math.abs(walked.Cost - 38) < 1e-6).is_true()
			-- Its multiplier scales its cost.
			expect(NavMesh.FindPath(mesh, v(1, 0, 2), v(39, 0, 2), { AreaCosts = { [5] = 3 } }).Cost).is(3)
		end)

		test("toggling a link invalidates paths through its tiles, and nothing else (SR5)", function()
			local desc: any = table.clone(Fixtures.LinkJump.Desc)
			desc.TileSize = 4
			local mesh = NavMesh.Build(desc)
			local jump = NavMesh.FindPath(mesh, v(2, 0, 2), v(22, 0, 8))
			local elsewhere = NavMesh.FindPath(mesh, v(20, 0, 1), v(23, 0, 1))
			expect(NavMesh.IsPathValid(mesh, jump)).is_true()
			NavMesh.SetLinkEnabled(mesh, 1, false)
			expect(NavMesh.IsPathValid(mesh, jump)).is(false)
			expect(NavMesh.IsPathValid(mesh, elsewhere)).is_true()
			expect(NavMesh.FindPath(mesh, v(2, 0, 2), v(22, 0, 8)).Status).is("Partial")
			-- Enabling invalidates too (conservative both ways).
			local stuck = NavMesh.FindPath(mesh, v(8, 0, 5), v(9, 0, 6))
			NavMesh.SetLinkEnabled(mesh, 1, true)
			expect(NavMesh.IsPathValid(mesh, stuck)).is(false)
			expect(NavMesh.FindPath(mesh, v(2, 0, 2), v(22, 0, 8)).Status).is("Success")
			expect(function()
				NavMesh.SetLinkEnabled(mesh, 2, true)
			end).fails_with("no link 2")
			expect(function()
				NavMesh.SetLinkEnabled(mesh, 1, "yes" :: any)
			end).fails_with("must be a boolean")
		end)
	end)

	describe("Seam and link Build errors", function()
		local ground = { Walkable = { flat(0, { 0, 0, 10, 0, 10, 10, 0, 10 }) } }
		local cases = {
			{
				"a seam off a floor",
				{
					Floors = { A = ground, B = { Walkable = { flat(0, { 10, 0, 20, 0, 20, 10, 10, 10 }) } } },
					Seams = { { FloorA = "A", FloorB = "B", From = v(30, 0, 0), To = v(30, 0, 5) } },
				},
				"seam 1: does not lie on floor",
			},
			{
				"floors on the same side of a seam",
				{
					Floors = { A = ground, B = { Walkable = { flat(0, { 5, 0, 10, 0, 10, 10, 5, 10 }) } } },
					Seams = { { FloorA = "A", FloorB = "B", From = v(10, 0, 0), To = v(10, 0, 5) } },
				},
				"don't meet across it",
			},
			{
				"floors at different heights along a seam",
				{
					Floors = { A = ground, B = { Walkable = { flat(3, { 10, 0, 20, 0, 20, 10, 10, 10 }) } } },
					Seams = { { FloorA = "A", FloorB = "B", From = v(10, 0, 0), To = v(10, 0, 5) } },
				},
				"at different heights along it",
			},
			{
				"a seam joining a floor to itself",
				{
					Floors = { A = ground },
					Seams = { { FloorA = "A", FloorB = "A", From = v(0, 0, 0), To = v(5, 0, 0) } },
				},
				"joins a floor to itself",
			},
			{
				"a zero-length seam",
				{
					Floors = { A = ground, B = ground },
					Seams = { { FloorA = "A", FloorB = "B", From = v(1, 0, 1), To = v(1.001, 0, 1) } },
				},
				"zero length",
			},
			{
				"a link off the mesh",
				{ Floors = { A = ground }, Links = { { From = v(1, 0, 1), To = v(50, 0, 1) } } },
				"link 1: To %(50",
			},
			{
				"a negative link cost",
				{ Floors = { A = ground }, Links = { { From = v(1, 0, 1), To = v(5, 0, 1), Cost = -1 } } },
				"Cost must be",
			},
			{
				"a bad link label",
				{ Floors = { A = ground }, Links = { { From = v(1, 0, 1), To = v(5, 0, 1), Label = 3 } } },
				"Label must be a string",
			},
		}
		for _, case in cases do
			test(`errors on {case[1]}`, function()
				expect(function()
					NavMesh.Build(case[2] :: any)
				end).fails_with(case[3])
			end)
		end
	end)

	describe("Drawing", function()
		test("seams and links draw on their own layers", function()
			local count = function(list: any, layer: string): number
				local n = 0
				for _, primitive in list do
					if primitive.Layer == layer then
						n += 1
					end
				end
				return n
			end
			local stairs = NavMesh.ToDrawList(NavMesh.Build(Fixtures.ThreeFloorStairs.Desc), { Seams = true })
			expect(count(stairs, "Seams") >= 2).is_true()
			local jump = NavMesh.ToDrawList(NavMesh.Build(Fixtures.LinkJump.Desc), { Links = true })
			expect(count(jump, "Links")).is(2) -- two-way: an arrow each way
			local drop = NavMesh.ToDrawList(NavMesh.Build(Fixtures.OneWayLink.Desc), { Links = true })
			expect(count(drop, "Links")).is(1)
		end)
	end)
end

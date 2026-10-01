-- Authors: Logan Hunt (Raildex)
-- October 1, 2026
-- Ticket 28: FirstAffectedSegment, which segment of a path the regions an Update returned
-- reach. Plain data in, a segment index out: the radius fattening, the per-floor rule, link
-- segments and the bounding-box prefilter, then ticket 22's contract over random adds.

return function(t: tiniest)
	local NavMesh = require("../NavMesh")

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

	-- A PathResult from { x, y, z, floor, label? } rows.
	local function path(rows: { { any } }): any
		local waypoints = {}
		for _, row in rows do
			table.insert(waypoints, { Position = v(row[1], row[2], row[3]), Floor = row[4], Label = row[5] })
		end
		return { Status = "Success", Waypoints = waypoints, Cost = 0, Length = 0, TileStamps = {} }
	end

	local function box(floor: string, x0: number, z0: number, x1: number, z1: number): any
		return { Floor = floor, Min = v(x0, 0, z0), Max = v(x1, 0, z1) }
	end

	-- An L: (0, 0) -> (10, 0) -> (10, 10) on Ground.
	local ell = path { { 0, 0, 0, "Ground" }, { 10, 0, 0, "Ground" }, { 10, 0, 10, "Ground" } }

	describe("FirstAffectedSegment", function()
		test("returns the first segment that meets a box, at or after fromSegment", function()
			expect(NavMesh.FirstAffectedSegment(ell, {}, 0)).is(nil)
			expect(NavMesh.FirstAffectedSegment(ell, { box("Ground", 4, -1, 6, 1) }, 0)).is(1)
			expect(NavMesh.FirstAffectedSegment(ell, { box("Ground", 9, 4, 11, 6) }, 0)).is(2)
			-- Both boxes: the earlier segment wins, whatever the list order.
			local both = { box("Ground", 9, 4, 11, 6), box("Ground", 4, -1, 6, 1) }
			expect(NavMesh.FirstAffectedSegment(ell, both, 0)).is(1)
			-- From segment 2 on, the box on segment 1 is behind the agent.
			expect(NavMesh.FirstAffectedSegment(ell, { box("Ground", 4, -1, 6, 1) }, 0, 2)).is(nil)
			expect(NavMesh.FirstAffectedSegment(ell, both, 0, 2)).is(2)
			-- Past the last segment there is nothing left to block.
			expect(NavMesh.FirstAffectedSegment(ell, both, 0, 3)).is(nil)
			-- The box is closed: touching the segment counts, from either side.
			expect(NavMesh.FirstAffectedSegment(ell, { box("Ground", 3, 0, 4, 1) }, 0)).is(1)
			expect(NavMesh.FirstAffectedSegment(ell, { box("Ground", 9, 4, 10, 6) }, 0)).is(2)
			-- A box over a segment's far end only, either way along the axis.
			expect(NavMesh.FirstAffectedSegment(ell, { box("Ground", 9.5, -1, 12, 1) }, 0)).is(1)
			local back = path { { 10, 0, 0, "Ground" }, { 0, 0, 0, "Ground" } }
			expect(NavMesh.FirstAffectedSegment(back, { box("Ground", -1, -1, 1, 1) }, 0)).is(1)
			-- A box at the last waypoint, from past the last segment.
			expect(NavMesh.FirstAffectedSegment(ell, { box("Ground", 9.5, 9.5, 10.5, 10.5) }, 0, 3)).is(nil)
			-- A segment exactly one stud long in X.
			local short = path { { 0, 0, 0, "Ground" }, { 1, 0, 0, "Ground" } }
			expect(NavMesh.FirstAffectedSegment(short, { box("Ground", 0.9, -0.1, 1.1, 0.1) }, 0)).is(1)
		end)

		test("fattens the segments by the radius", function()
			-- A box 0.5 off segment 1's side (and off segment 2's end).
			local regions = { box("Ground", 4, 0.5, 6, 2) }
			expect(NavMesh.FirstAffectedSegment(ell, regions, 0.4)).is(nil)
			expect(NavMesh.FirstAffectedSegment(ell, regions, 0.6)).is(1)
		end)

		test("the prefilter's bounds are grown by the radius", function()
			-- A box past the path's far end, within the radius of it but outside its bounds.
			local regions = { box("Ground", 10.3, 10.3, 12, 12) }
			expect(NavMesh.FirstAffectedSegment(ell, regions, 0.2)).is(nil)
			expect(NavMesh.FirstAffectedSegment(ell, regions, 0.6)).is(2)
			-- Touching the grown bounds counts.
			expect(NavMesh.FirstAffectedSegment(ell, { box("Ground", 10.5, 4, 11, 6) }, 0.5)).is(2)
			-- From segment 2 on, a box beside segment 1 is behind the agent.
			local behind = { box("Ground", -2, -2, -0.5, -0.5) }
			expect(NavMesh.FirstAffectedSegment(ell, behind, 1)).is(1)
			expect(NavMesh.FirstAffectedSegment(ell, behind, 1, 2)).is(nil)
		end)

		test("a box only counts on the floors of the segment's ends", function()
			-- A path on the Upper floor, over the Ground floor (ThreeFloorStairs): a change below it
			-- leaves it alone.
			local upper = path { { 22, 5, 2 }, { 38, 5, 18 } }
			for _, w in upper.Waypoints do
				w.Floor = "Upper"
			end
			expect(NavMesh.FirstAffectedSegment(upper, { box("Ground", 29, 9, 31, 11) }, 0)).is(nil)
			expect(NavMesh.FirstAffectedSegment(upper, { box("Upper", 29, 9, 31, 11) }, 0)).is(1)
			-- A segment that crosses a seam is tested against both floors' boxes.
			local seam = path { { 5, 0, 2, "Ground" }, { 15, 2.5, 2, "Stairs" } }
			expect(NavMesh.FirstAffectedSegment(seam, { box("Stairs", 12, 1, 13, 3) }, 0)).is(1)
			expect(NavMesh.FirstAffectedSegment(seam, { box("Ground", 6, 1, 7, 3) }, 0)).is(1)
			expect(NavMesh.FirstAffectedSegment(seam, { box("Upper", 6, 1, 7, 3) }, 0)).is(nil)
		end)

		test("a link segment is tested at its ends only", function()
			local mesh = NavMesh.Build(Fixtures.LinkJump.Desc)
			local jump = NavMesh.FindPath(mesh, v(5, 0, 5), v(20, 0, 5))
			expect(jump.Status).is("Success")
			local link = 0
			for i, w in jump.Waypoints do
				if w.Label == "Jump" then
					link = i
				end
			end
			expect(link > 0).is_true()
			-- A change in the gap the link jumps over doesn't touch it.
			expect(NavMesh.FirstAffectedSegment(jump, { box("Ground", 11, 3, 13, 7) }, 0.5)).is(nil)
			-- A change at the landing does.
			expect(NavMesh.FirstAffectedSegment(jump, { box("Ground", 15.2, 4, 16, 6) }, 0.5)).is(link)
		end)

		test("a one-waypoint path is its point", function()
			local still = path { { 5, 0, 5, "Ground" } }
			expect(NavMesh.FirstAffectedSegment(still, { box("Ground", 5.5, 5.5, 6, 6) }, 0)).is(nil)
			expect(NavMesh.FirstAffectedSegment(still, { box("Ground", 5.5, 5.5, 6, 6) }, 0.6)).is(1)
			expect(NavMesh.FirstAffectedSegment(path {}, { box("Ground", 0, 0, 1, 1) }, 1)).is(nil)
		end)

		test("errors on bad arguments", function()
			for _, case in
				{
					{ "path must be a PathResult", { 5 }, {}, 0 },
					{ "regions must be a list", ell, nil, 0 },
					{ "radius must be a number of studs >= 0", ell, {}, -1 },
					{ "radius must be a number of studs >= 0", ell, {}, 0 / 0 },
					{ "radius must be a number of studs >= 0", ell, {}, math.huge },
					{ "fromSegment must be a whole number >= 1", ell, {}, 0, 0 },
					{ "fromSegment must be a whole number >= 1", ell, {}, 0, 1.5 },
				}
			do
				local ok, err = pcall(function()
					NavMesh.FirstAffectedSegment(case[2], case[3], case[4], case[5])
				end)
				expect(ok).is(false)
				expect(string.find(tostring(err), case[1], 1, true) ~= nil).with_context(tostring(err)).is_true()
				-- Blamed on the caller's line.
				expect(string.find(tostring(err), "Affected.spec", 1, true) ~= nil)
					.with_context(tostring(err))
					.is_true()
			end
		end)

		test("Update also returns the footprint of each obstacle it added", function()
			local mesh = NavMesh.Build(Fixtures.ThreeFloorStairs.Desc)
			local crate = NavMesh.AddObstacle(mesh, "Upper", flat(5, { 30.2, 4.1, 32.7, 4.3, 32.5, 6.6, 30.1, 6.4 }))
			local regions, added = NavMesh.Update(mesh)
			expect(#regions > 0).is_true()
			expect(#added).is(1)
			local box = added[1]
			expect(box.Floor).is("Upper")
			-- The ring's bounds on the 1/256 grid, grown by one pixel.
			expect(box.Min.X).is(math.round(30.1 * 256) / 256 - 1 / 256)
			expect(box.Max.Z).is(math.round(6.6 * 256) / 256 + 1 / 256)
			expect(box.Min.Y <= 5 and box.Max.Y >= 5).with_context(`{box.Min.Y}, {box.Max.Y}`).is_true()
			-- A removal adds nothing, and nor does an add taken back before the Update.
			NavMesh.RemoveObstacle(mesh, crate)
			NavMesh.RemoveObstacle(mesh, NavMesh.AddObstacle(mesh, "Ground", flat(0, { 2, 2, 3, 2, 3, 3, 2, 3 })))
			local _, none = NavMesh.Update(mesh)
			expect(#none).is(0)
			expect(#select(2, NavMesh.Update(mesh))).is(0)
		end)

		test("a path clear of every added footprint is still walked to the end", function()
			-- Random paths on a floor of props, then random crates added, one Update at a time.
			-- The follower walks each path the footprints leave alone on the updated mesh.
			math.randomseed(29)
			local function rnd(lo: number, hi: number): number
				return lo + math.random() * (hi - lo)
			end
			local mesh = NavMesh.Build {
				TileSize = 8,
				MaxAgentRadius = 1,
				Floors = { Ground = { Walkable = { flat(0, { 0, 0, 40, 0, 40, 24, 0, 24 }) } } },
			}
			local walked, flagged = 0, 0
			for step = 1, 5 do
				local paths = {}
				for _ = 1, 24 do
					local radius = if #paths % 2 == 0 then 0.3 else 0.8
					local found = NavMesh.FindPath(
						mesh,
						v(rnd(1, 39), 0, rnd(1, 23)),
						v(rnd(1, 39), 0, rnd(1, 23)),
						{ AgentRadius = radius }
					)
					if found.Status == "Success" and #found.Waypoints >= 2 then
						table.insert(paths, { Path = found, Radius = radius })
					end
				end
				local cx, cz = rnd(4, 36), rnd(4, 20)
				local w, d = rnd(2, 6), rnd(2, 6)
				NavMesh.AddObstacle(mesh, "Ground", flat(0, { cx, cz, cx + w, cz, cx + w, cz + d, cx, cz + d }))
				local _, added = NavMesh.Update(mesh)
				for _, q in paths do
					if NavMesh.FirstAffectedSegment(q.Path, added, q.Radius) then
						flagged += 1
						continue
					end
					walked += 1
					local filter = { AgentRadius = q.Radius }
					local follower = NavMesh.NewFollower(q.Path)
					local at, event = q.Path.Waypoints[1].Position, nil
					for _ = 1, 2000 do
						at, _, event = NavMesh.Advance(mesh, follower, at, 0.5, filter)
						if event then
							break
						end
					end
					expect(event).with_context(`step {step}`).is("Arrived")
				end
			end
			expect(walked > 40).with_context(`{walked} walked`).is_true()
			expect(flagged > 10).with_context(`{flagged} flagged`).is_true()
		end)

		test("a path it calls unaffected is what FindPath returns again after adds (ticket 22)", function()
			-- Random paths over two floors joined by a ramp, then random crates added on either
			-- floor, one Update at a time. Adds only: a removal can open a better route through a
			-- box, which the contract excludes.
			math.randomseed(28)
			local function rnd(lo: number, hi: number): number
				return lo + math.random() * (hi - lo)
			end
			local desc: any = {
				TileSize = 8,
				MaxAgentRadius = 1,
				Floors = {
					Ground = { Walkable = { flat(0, { 0, 0, 40, 0, 40, 24, 0, 24 }) } },
					Ramp = { Walkable = { { v(10, 0, 0), v(20, 5, 0), v(20, 5, 4), v(10, 0, 4) } } },
					Upper = { Walkable = { flat(5, { 20, 0, 40, 0, 40, 10, 20, 10 }) } },
				},
				Seams = {
					{ FloorA = "Ground", FloorB = "Ramp", From = v(10, 0, 0), To = v(10, 0, 4) },
					{ FloorA = "Ramp", FloorB = "Upper", From = v(20, 5, 0), To = v(20, 5, 4) },
				},
			}
			desc.Floors.Ground.Obstacles = { flat(0, { 10, 0, 20, 0, 20, 4, 10, 4 }) }
			local mesh = NavMesh.Build(desc)
			local function randomPoint(): any
				if math.random() < 0.3 then
					return v(rnd(20.5, 39.5), 5, rnd(0.5, 9.5))
				end
				return v(rnd(0.5, 39.5), 0, rnd(4.5, 23.5))
			end
			local checked, affected = 0, 0
			for step = 1, 6 do
				local queries = {}
				for _ = 1, 40 do
					local from, to = randomPoint(), randomPoint()
					local radius = if #queries % 2 == 0 then 0 else 0.4
					local found = NavMesh.FindPath(mesh, from, to, { AgentRadius = radius })
					if found.Status == "Success" then
						table.insert(queries, { From = from, To = to, Radius = radius, Path = found })
					end
				end
				local onUpper = step % 3 == 0
				local cx, cz = rnd(2, 38), rnd(6, 22)
				if onUpper then
					cx, cz = rnd(22, 38), rnd(1.5, 8.5)
				end
				local crate =
					flat(0, { cx - 0.8, cz - 0.7, cx + 0.9, cz - 0.6, cx + 0.8, cz + 0.8, cx - 0.7, cz + 0.7 })
				NavMesh.AddObstacle(mesh, if onUpper then "Upper" else "Ground", crate)
				local regions = NavMesh.Update(mesh)
				for _, q in queries do
					if NavMesh.FirstAffectedSegment(q.Path, regions, q.Radius) then
						affected += 1
						continue
					end
					checked += 1
					local again = NavMesh.FindPath(mesh, q.From, q.To, { AgentRadius = q.Radius })
					expect(again.Status).with_context(`step {step}`).is(q.Path.Status)
					expect(#again.Waypoints).with_context(`step {step}`).is(#q.Path.Waypoints)
					for i, w in again.Waypoints do
						expect(vector.magnitude(w.Position - q.Path.Waypoints[i].Position) <= 1e-9)
							.with_context(`step {step}, waypoint {i}`)
							.is_true()
					end
				end
			end
			-- Not vacuous either way.
			expect(checked > 60).with_context(`{checked} checked`).is_true()
			expect(affected > 10).with_context(`{affected} affected`).is_true()
		end)
	end)
end

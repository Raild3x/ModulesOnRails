-- Authors: Logan Hunt (Raildex)
-- October 1, 2026
-- GenerateLinks (ticket 30, part 2): drop and jump links read off a built mesh. Walled edges and
-- links a walk already serves are rejected, runs are deduplicated, and the output is
-- deterministic.

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

	local function copy(value: any): any
		if type(value) ~= "table" then
			return value
		end
		local out = {}
		for key, item in value do
			out[key] = copy(item)
		end
		return out
	end

	-- `desc` rebuilt with `links`: generated links must build.
	local function withLinks(desc: any, links: { NavMesh.LinkDesc }): NavMesh.NavMeshData
		local d = copy(desc)
		d.Links = links
		return NavMesh.Build(d)
	end

	local function floorOf(mesh: NavMesh.NavMeshData, p: Vector3): string?
		local at = NavMesh.FindNearestPoint(mesh, p, { SnapExtents = v(0.1, 0.1, 0.1) })
		return at and at.Floor
	end

	local function text(links: { NavMesh.LinkDesc }): string
		local lines = {}
		for _, l in links do
			table.insert(
				lines,
				string.format(
					"%s %s (%.3f %.3f %.3f) (%.3f %.3f %.3f) %d",
					tostring(l.Label),
					tostring(l.Bidirectional),
					l.From.X,
					l.From.Y,
					l.From.Z,
					l.To.X,
					l.To.Y,
					l.To.Z,
					l.Area or 1
				)
			)
		end
		return table.concat(lines, "\n")
	end

	local function labels(path: NavMesh.PathResult): string
		local found = {}
		for _, w in path.Waypoints do
			if w.Label then
				table.insert(found, w.Label)
			end
		end
		return table.concat(found, ",")
	end

	-- Two pads on one floor with a gap of `gap` studs along X; the far one `rise` studs higher.
	-- Both at height `base` (default 0) plus that.
	local function gap(width: number, rise: number?, base: number?): any
		local x, y = 10 + width, base or 0
		return {
			Floors = {
				Ground = {
					Walkable = {
						flat(y, { 0, 0, 10, 0, 10, 10, 0, 10 }),
						flat(y + (rise or 0), { x, 0, x + 10, 0, x + 10, 10, x, 10 }),
					},
				},
			},
		}
	end

	-- A balcony (y = 5, x = 10..30, z = 10..20) over Ground (y = 0, 40 x 30), which runs on under
	-- it, with no way up or down.
	local BALCONY = {
		Floors = {
			Ground = { Walkable = { flat(0, { 0, 0, 40, 0, 40, 30, 0, 30 }) } },
			Balcony = { Walkable = { flat(5, { 10, 10, 30, 10, 30, 20, 10, 20 }) } },
		},
	}

	-- The balcony with a railing (four obstacle strips, 0.5 thick on the balcony) round its edge.
	local function walledBalcony(): any
		local desc = copy(BALCONY)
		desc.Floors.Balcony.Obstacles = {
			flat(5, { 9, 9, 31, 9, 31, 10.5, 9, 10.5 }),
			flat(5, { 9, 19.5, 31, 19.5, 31, 21, 9, 21 }),
			flat(5, { 9, 9, 10.5, 9, 10.5, 21, 9, 21 }),
			flat(5, { 29.5, 9, 31, 9, 31, 21, 29.5, 21 }),
		}
		return desc
	end

	-- Pads A and B with a 3-stud gap, joined by a 3-wide Bridge floor (z = 0..3) through seams.
	local BRIDGE = {
		Floors = {
			A = { Walkable = { flat(0, { 0, 0, 10, 0, 10, 12, 0, 12 }) } },
			B = { Walkable = { flat(0, { 13, 0, 23, 0, 23, 12, 13, 12 }) } },
			Bridge = { Walkable = { flat(0, { 10, 0, 13, 0, 13, 3, 10, 3 }) } },
		},
		Seams = {
			{ FloorA = "A", FloorB = "Bridge", From = v(10, 0, 0), To = v(10, 0, 3) },
			{ FloorA = "Bridge", FloorB = "B", From = v(13, 0, 0), To = v(13, 0, 3) },
		},
	}

	describe("GenerateLinks", function()
		test("a balcony gets one-way drops to the floor below, and none back up", function()
			local desc = BALCONY
			local mesh = NavMesh.Build(desc)
			local links = NavMesh.GenerateLinks(mesh)
			expect(#links >= 8).with_context(text(links)).is_true()
			for _, l in links do
				expect(l.Label).is("Drop")
				expect(l.Bidirectional).is(false)
				expect(floorOf(mesh, l.From)).is("Balcony")
				expect(floorOf(mesh, l.To)).is("Ground")
				-- Both ends admit the default clearance (1 stud), and the landing is off the balcony.
				expect(NavMesh.FindDistanceToWall(mesh, l.From, 1) >= 1 - 1e-3).with_context(text { l }).is_true()
				local x, z = l.To.X, l.To.Z
				expect(x <= 9 + 1e-3 or x >= 31 - 1e-3 or z <= 9 + 1e-3 or z >= 21 - 1e-3)
					.with_context(text { l })
					.is_true()
			end
			local linked = withLinks(desc, links)
			local down = NavMesh.FindPath(linked, v(20, 5, 15), v(2, 0, 2), { AgentRadius = 1 })
			expect(down.Status).is("Success")
			expect(labels(down)).is("Drop")
			expect(NavMesh.FindPath(linked, v(2, 0, 2), v(20, 5, 15)).Status).is("Partial")
		end)

		test("a walled balcony gets none: the probe meets the railing, not the floor below", function()
			local mesh = NavMesh.Build(walledBalcony())
			expect(#NavMesh.GenerateLinks(mesh)).is(0)
		end)

		test("an interior wall gets none, though a floor lies below it", function()
			-- A wall strip across the balcony (an obstacle of its floor) over Ground: no drop through it.
			local desc = copy(BALCONY)
			desc.Floors.Balcony.Obstacles = { flat(5, { 19.75, 10, 20.25, 10, 20.25, 20, 19.75, 20 }) }
			local mesh = NavMesh.Build(desc)
			local links = NavMesh.GenerateLinks(mesh)
			expect(#links >= 8).is_true()
			for _, l in links do
				-- Every landing is off the balcony's plan, none under it beside the wall.
				local x, z = l.To.X, l.To.Z
				expect(x <= 9 + 1e-3 or x >= 31 - 1e-3 or z <= 9 + 1e-3 or z >= 21 - 1e-3)
					.with_context(text { l })
					.is_true()
			end
		end)

		test("a 3-stud gap gets two-way jumps; a 20-stud gap gets none", function()
			local desc = gap(3)
			local links = NavMesh.GenerateLinks(NavMesh.Build(desc))
			expect(#links >= 1).is_true()
			for _, l in links do
				expect(l.Label).is("Jump")
				expect(l.Bidirectional).is(true)
				expect(l.From.X < 10 and l.To.X > 13 or l.From.X > 13 and l.To.X < 10)
					.with_context(text { l })
					.is_true()
			end
			local linked = withLinks(desc, links)
			expect(labels(NavMesh.FindPath(linked, v(2, 0, 5), v(21, 0, 5)))).is("Jump")
			expect(labels(NavMesh.FindPath(linked, v(21, 0, 5), v(2, 0, 5)))).is("Jump")
			expect(#NavMesh.GenerateLinks(NavMesh.Build(gap(20)))).is(0)
			expect(#NavMesh.GenerateLinks(NavMesh.Build(gap(20)), { MaxJumpDistance = 21 }) >= 1).is_true()
		end)

		test("a jump is one-way when the way back climbs more than MaxJumpUp", function()
			local links = NavMesh.GenerateLinks(NavMesh.Build(gap(3, 5)), { MaxJumpUp = 3 })
			expect(#links >= 1).is_true()
			for _, l in links do
				expect(l.Label).is("Jump")
				expect(l.Bidirectional).is(false)
				expect(l.From.Y).is(5)
				expect(l.To.Y).is(0)
			end
			-- Within reach both ways: two-way.
			for _, l in NavMesh.GenerateLinks(NavMesh.Build(gap(3, 2))) do
				expect(l.Bidirectional).is(true)
			end
			-- Too deep to drop or climb: nothing.
			expect(#NavMesh.GenerateLinks(NavMesh.Build(gap(3, 5)), { MaxJumpUp = 3, MaxDrop = 4 })).is(0)
		end)

		test("AreaCosts on the links' area turns them off in FindPath", function()
			local desc = gap(3)
			local links = NavMesh.GenerateLinks(NavMesh.Build(desc), { Area = 9 })
			expect(#links >= 1).is_true()
			for _, l in links do
				expect(l.Area).is(9)
			end
			local linked = withLinks(desc, links)
			expect(NavMesh.FindPath(linked, v(2, 0, 5), v(21, 0, 5)).Status).is("Success")
			local grounded = NavMesh.FindPath(linked, v(2, 0, 5), v(21, 0, 5), { AreaCosts = { [9] = math.huge } })
			expect(grounded.Status).is("Partial")
		end)

		test("is deterministic: the same mesh gives the same links in the same order", function()
			local desc = copy(Fixtures.ThreeFloorStairs.Desc)
			local first = text(NavMesh.GenerateLinks(NavMesh.Build(desc)))
			expect(#first > 0).is_true()
			expect(text(NavMesh.GenerateLinks(NavMesh.Build(desc)))).is(first)
			expect(text(NavMesh.GenerateLinks(NavMesh.Deserialize(NavMesh.Serialize(NavMesh.Build(desc)))))).is(first)
		end)

		test("deduplicates a long ledge into one link per Spacing", function()
			-- A 40-stud ledge (y = 4) beside the ground.
			local desc = {
				Floors = {
					Ledge = { Walkable = { flat(4, { 0, 0, 40, 0, 40, 6, 0, 6 }) } },
					Ground = { Walkable = { flat(0, { 0, 6, 40, 6, 40, 20, 0, 20 }) } },
				},
			}
			local mesh = NavMesh.Build(desc)
			local links = NavMesh.GenerateLinks(mesh, { Spacing = 4 })
			-- Along z = 6 only (the other sides drop onto nothing).
			expect(#links >= 5 and #links <= 11).with_context(text(links)).is_true()
			for i, a in links do
				expect(a.Label).is("Drop")
				for j = i + 1, #links do
					local b = links[j]
					expect(vector.magnitude((a.From :: any) - (b.From :: any)) >= 4 - 1e-6)
						.with_context(text { a, b })
						.is_true()
				end
			end
			-- A wider spacing, fewer links.
			expect(#NavMesh.GenerateLinks(mesh, { Spacing = 10 }) < #links).is_true()
			withLinks(desc, links)
		end)

		test("rejects a link a walk already serves: jumps only where the bridge is far", function()
			local mesh = NavMesh.Build(BRIDGE)
			local links = NavMesh.GenerateLinks(mesh)
			expect(#links >= 1).is_true()
			for _, l in links do
				-- Next to the 3-wide bridge (z = 0..3), walking over it is under twice the jump.
				expect(l.From.Z > 5 and l.To.Z > 5).with_context(text(links)).is_true()
			end
			-- With no detour test (factor 0) the links by the bridge come back.
			local near = 0
			for _, l in NavMesh.GenerateLinks(mesh, { DetourFactor = 0 }) do
				if l.From.Z < 5 then
					near += 1
				end
			end
			expect(near >= 1).is_true()
			withLinks(BRIDGE, links)
		end)

		test("both ends must admit Clearance", function()
			-- The far pad is a 1-stud strip: too narrow for a 1-stud radius, fine for 0.25.
			local desc = {
				Floors = {
					Ground = {
						Walkable = {
							flat(0, { 0, 0, 10, 0, 10, 10, 0, 10 }),
							flat(0, { 13, 0, 14, 0, 14, 10, 13, 10 }),
						},
					},
				},
			}
			local mesh = NavMesh.Build(desc)
			expect(#NavMesh.GenerateLinks(mesh, { Clearance = 1 })).is(0)
			local thin = NavMesh.GenerateLinks(mesh, { Clearance = 0.25 })
			expect(#thin >= 1).is_true()
			withLinks(desc, thin)
			-- Clearance 0: the ends sit on the walls.
			expect(#NavMesh.GenerateLinks(mesh, { Clearance = 0 }) >= 1).is_true()
		end)

		test("Labels renames the links", function()
			local drops = NavMesh.GenerateLinks(NavMesh.Build(BALCONY), { Labels = { Drop = "Fall" } })
			expect(drops[1].Label).is("Fall")
			local jumps = NavMesh.GenerateLinks(NavMesh.Build(gap(3)), { Labels = { Jump = "Hop" } })
			expect(jumps[1].Label).is("Hop")
		end)

		test("validates options at the call", function()
			local mesh = NavMesh.Build(gap(3))
			local capped = copy(gap(3))
			capped.MaxAgentRadius = 0.5
			local cappedMesh = NavMesh.Build(capped)
			for _, case in
				{
					{
						{ Clearance = 0.75 },
						"NavMesh.GenerateLinks: Clearance 0.75 is above the mesh's MaxAgentRadius 0.5",
					},
					{ { Bogus = 1 }, "unknown option 'Bogus'" },
					{ { Spacing = 0 }, "Spacing must be a number > 0" },
					{ { Spacing = -1 }, "Spacing must be a number >= 0" },
					{ { MaxDrop = math.huge }, "MaxDrop must be" },
					{ { MaxJumpDistance = "far" }, "MaxJumpDistance must be" },
					{ { MaxJumpUp = -1 }, "MaxJumpUp must be" },
					{ { Clearance = 0 / 0 }, "Clearance must be" },
					{ { DetourFactor = -2 }, "DetourFactor must be" },
					{ { Area = 0 }, "Area must be a number >= 1" },
					{ { Area = 1.5 }, "Area must be a whole number" },
					{ { Labels = "Jump" }, "Labels must be a table" },
					{ { Labels = { Drop = 1 } }, "Labels must be a table" },
					{ { Labels = { Jump = false } }, "Labels must be a table" },
					{ "fast", "options must be a table" },
				}
			do
				-- Each names the caller's line.
				local target = if case[1] == "fast" or case[1].Clearance ~= 0.75 then mesh else cappedMesh
				local ok, err = pcall(function()
					NavMesh.GenerateLinks(target, case[1] :: any)
				end)
				expect(ok).is(false)
				local message = tostring(err)
				expect(string.find(message, case[2], 1, true) ~= nil).with_context(message).is_true()
				expect(string.find(message, "Generate.spec", 1, true) ~= nil).with_context(message).is_true()
			end
			expect(#NavMesh.GenerateLinks(cappedMesh, { Clearance = 0.5 }) >= 1).is_true()
			expect(#NavMesh.GenerateLinks(mesh, { Clearance = 3 }) >= 1).is_true()
		end)

		test("reach limits are inclusive: MaxJumpDistance, MaxDrop and MaxJumpUp", function()
			-- The 3-stud gap is crossed at MaxJumpDistance 3, not 2.5.
			expect(#NavMesh.GenerateLinks(NavMesh.Build(gap(3)), { MaxJumpDistance = 3 }) >= 1).is_true()
			expect(#NavMesh.GenerateLinks(NavMesh.Build(gap(3)), { MaxJumpDistance = 2.5 })).is(0)
			-- Down exactly MaxDrop (5): one-way; up exactly MaxJumpUp (5): two-way.
			local down = NavMesh.GenerateLinks(NavMesh.Build(gap(3, 5)), { MaxDrop = 5, MaxJumpUp = 0 })
			expect(#down >= 1).is_true()
			expect(down[1].Bidirectional).is(false)
			expect(#NavMesh.GenerateLinks(NavMesh.Build(gap(3, 5)), { MaxDrop = 4.9, MaxJumpUp = 0 })).is(0)
			local up = NavMesh.GenerateLinks(NavMesh.Build(gap(3, 5)), { MaxDrop = 5, MaxJumpUp = 5 })
			expect(#up >= 1).is_true()
			expect(up[1].Bidirectional).is(true)
			-- A climb is measured from the ledge: pads at 10 and 12 are 2 apart, within 3 both ways.
			local high = NavMesh.GenerateLinks(NavMesh.Build(gap(3, 2, 10)))
			expect(#high >= 1).is_true()
			for _, l in high do
				expect(l.Bidirectional).with_context(text { l }).is(true)
			end
		end)

		test("a drop lands Clearance out from the ledge; a cliff foot within Clearance is still a Drop", function()
			local links = NavMesh.GenerateLinks(NavMesh.Build(BALCONY), { Clearance = 0.5 })
			expect(#links >= 1).is_true()
			for _, l in links do
				-- Off the balcony's plan by 0.5 plus the 0.05 probe.
				local x, z = l.To.X, l.To.Z
				local off = math.max(10 - x, x - 30, 10 - z, z - 20)
				expect(off > 0.5 and off < 0.6).with_context(text { l }).is_true()
			end
			-- A ledge (y = 4) whose ground starts 1 stud out: a drop at Clearance 1, a jump at 0.5.
			local cliff = {
				Floors = {
					Ledge = { Walkable = { flat(4, { 0, 0, 10, 0, 10, 10, 0, 10 }) } },
					Ground = { Walkable = { flat(0, { 11, 0, 21, 0, 21, 10, 11, 10 }) } },
				},
			}
			local mesh = NavMesh.Build(cliff)
			expect(NavMesh.GenerateLinks(mesh)[1].Label).is("Drop")
			expect(NavMesh.GenerateLinks(mesh, { Clearance = 0.5 })[1].Label).is("Jump")
		end)

		test("a level hop within Clearance is a two-way Jump, not a Drop", function()
			local links = NavMesh.GenerateLinks(NavMesh.Build(gap(0.5)))
			expect(#links >= 1).is_true()
			for _, l in links do
				expect(l.Label).is("Jump")
				expect(l.Bidirectional).is(true)
			end
		end)

		test("samples each wall edge evenly: one sample, mid-edge, when Spacing is long", function()
			-- The pads' facing edges (z = 0..10) are single edges: one sample each, at z = 5.
			local links = NavMesh.GenerateLinks(NavMesh.Build(gap(3)), { Spacing = 100 })
			expect(#links).is(1)
			expect(links[1].From.Z).is(5)
			expect(links[1].To.Z).is(5)
		end)

		test("a wall added at runtime (AddObstacle) is a wall too", function()
			local mesh = NavMesh.Build(BALCONY)
			NavMesh.AddObstacle(mesh, "Balcony", flat(5, { 19.75, 10, 20.25, 10, 20.25, 20, 19.75, 20 }))
			NavMesh.Update(mesh)
			local links = NavMesh.GenerateLinks(mesh)
			expect(#links >= 8).is_true()
			for _, l in links do
				local x, z = l.To.X, l.To.Z
				expect(x <= 9 + 1e-3 or x >= 31 - 1e-3 or z <= 9 + 1e-3 or z >= 21 - 1e-3)
					.with_context(text { l })
					.is_true()
			end
		end)

		test("an interior wall on a slanted balcony gets none", function()
			-- A diamond balcony (y = 5) centred on (20, 20) over Ground, with a wall strip across it.
			local desc = {
				Floors = {
					Ground = { Walkable = { flat(0, { 0, 0, 40, 0, 40, 40, 0, 40 }) } },
					Balcony = {
						Walkable = { flat(5, { 20, 8, 32, 20, 20, 32, 8, 20 }) },
						Obstacles = { flat(5, { 19.75, 12, 20.25, 12, 20.25, 28, 19.75, 28 }) },
					},
				},
			}
			local links = NavMesh.GenerateLinks(NavMesh.Build(desc))
			expect(#links >= 8).is_true()
			for _, l in links do
				-- Every landing is off the diamond (|x - 20| + |z - 20| > 12).
				expect(math.abs(l.To.X - 20) + math.abs(l.To.Z - 20) > 12).with_context(text { l }).is_true()
			end
		end)

		test("is pure: the mesh is unchanged", function()
			local mesh = NavMesh.Build(Fixtures.ThreeFloorStairs.Desc)
			local before = buffer.tostring(NavMesh.Serialize(mesh))
			NavMesh.GenerateLinks(mesh)
			expect(buffer.tostring(NavMesh.Serialize(mesh)) == before).is_true()
		end)
	end)
end

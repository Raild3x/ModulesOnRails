-- Ticket 30 part 1 and ticket 25's link items: runtime links (AddLink / RemoveLink, pending
-- until Update like obstacles), sparse ids never reused, records freed, stamps and changed
-- regions at link ends, the bake round trip, names, and the link id on waypoints.
return function(t: tiniest)
	local NavMesh = require("../NavMesh")
	local Search = require("../Search")
	local Storage = require("../Storage")

	local describe = t.describe
	local expect = t.expect
	local test = t.test

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

	-- Two pads with a 4-stud gap; `links` as given.
	local function pads(links: { any }?, tileSize: number?): NavMesh.NavMeshData
		return NavMesh.Build {
			Floors = {
				Ground = {
					Walkable = { flat(0, { 0, 0, 10, 0, 10, 10, 0, 10 }), flat(0, { 14, 0, 24, 0, 24, 10, 14, 10 }) },
				},
			},
			Links = links,
			TileSize = tileSize,
		}
	end
	local JUMP = { From = v(9, 0, 5), To = v(15, 0, 5), Label = "Jump" }

	local function status(mesh: NavMesh.NavMeshData): string
		return NavMesh.FindPath(mesh, v(2, 0, 2), v(22, 0, 8)).Status
	end

	describe("Runtime links", function()
		test("AddLink waits for Update; ids carry on from the description's", function()
			local mesh = pads { JUMP }
			NavMesh.RemoveLink(mesh, 1)
			NavMesh.Update(mesh)
			expect(status(mesh)).is("Partial")
			local id = NavMesh.AddLink(mesh, JUMP)
			expect(id).is(2) -- 1 was the description's, and is never reused
			expect(NavMesh.HasPendingChanges(mesh)).is_true()
			expect(status(mesh)).is("Partial") -- pending: queries don't see it yet
			NavMesh.Update(mesh)
			expect(NavMesh.HasPendingChanges(mesh)).is(false)
			local path = NavMesh.FindPath(mesh, v(2, 0, 2), v(22, 0, 8))
			expect(path.Status).is("Success")
			-- Snapped at Update as Build snaps: the default cost is the snapped ends' distance.
			expect(math.abs(select(5, Storage.GetLink(mesh :: any, 1)) - 6) < 1e-9).is_true()
		end)

		test("RemoveLink waits for Update, frees the record, and the id stays used", function()
			local mesh = pads { JUMP, { From = v(9, 0, 8), To = v(15, 0, 8) } }
			NavMesh.RemoveLink(mesh, 1)
			NavMesh.RemoveLink(mesh, 2)
			expect(status(mesh)).is("Success") -- still there until Update
			expect(NavMesh.HasPendingChanges(mesh)).is_true()
			NavMesh.Update(mesh)
			expect(status(mesh)).is("Partial")
			expect(Storage.LinkCount(mesh :: any)).is(0)
			expect(function()
				NavMesh.RemoveLink(mesh, 1)
			end).fails_with("link 1 is already removed")
			expect(function()
				NavMesh.SetLinkEnabled(mesh, 1, true)
			end).fails_with("no link 1")
			expect(NavMesh.AddLink(mesh, JUMP)).is(3)
		end)

		test("a pending add removed before Update goes at once; a toggled link keeps one record", function()
			local mesh = pads()
			for _ = 1, 50 do
				local id = NavMesh.AddLink(mesh, JUMP)
				NavMesh.RemoveLink(mesh, id)
			end
			expect(Storage.LinkCount(mesh :: any)).is(0)
			expect(NavMesh.HasPendingChanges(mesh)).is(false)
			for _ = 1, 20 do
				local id = NavMesh.AddLink(mesh, JUMP)
				NavMesh.Update(mesh)
				NavMesh.RemoveLink(mesh, id)
				NavMesh.Update(mesh)
			end
			expect(Storage.LinkCount(mesh :: any)).is(0)
			expect(Storage.GetLinkNextId(mesh :: any)).is(71)
		end)

		test("RemoveLink of a removal already pending errors, and so do bad ids", function()
			local mesh = pads { JUMP }
			NavMesh.RemoveLink(mesh, 1)
			expect(function()
				NavMesh.RemoveLink(mesh, 1)
			end).fails_with("NavMesh.RemoveLink: link 1 is already removed")
			for _, id in { 0, 2, 1.5, "1" } do
				expect(function()
						NavMesh.RemoveLink(mesh, id :: any)
					end)
					.with_context(tostring(id))
					.fails_with(`NavMesh.RemoveLink: no link {id}`)
			end
		end)

		test("AddLink checks the description at the call, as Build does", function()
			local mesh = pads()
			for _, case in
				{
					{ 5, "must be a table" },
					{ { From = 1, To = v(15, 0, 5) }, "From must be a Vector3" },
					{ { From = v(9, 0, 5), To = v(15, 0, 5), Cost = -1 }, "Cost must be a finite number" },
					{ { From = v(9, 0, 5), To = v(15, 0, 5), Label = 3 }, "Label must be a string" },
					{ { From = v(9, 0, 5), To = v(15, 0, 5), Name = 3 }, "Name must be a string" },
					{ { From = v(9, 0, 5), To = v(15, 0, 5), Bidirectional = 1 }, "Bidirectional must be a boolean" },
				}
			do
				local ok, err = pcall(NavMesh.AddLink, mesh, case[1] :: any)
				expect(ok).with_context(case[2]).is(false)
				expect(tostring(err):find("NavMesh.AddLink: link: " .. case[2], 1, true) ~= nil)
					.with_context(tostring(err))
					.is_true()
			end
			expect(Storage.LinkCount(mesh :: any)).is(0)
			expect(NavMesh.HasPendingChanges(mesh)).is(false)
		end)

		test("an end that doesn't snap fails the whole Update and rolls it back", function()
			local mesh = pads { JUMP }
			local crate = NavMesh.AddObstacle(mesh, "Ground", { v(1, 0, 1), v(3, 0, 1), v(3, 0, 3), v(1, 0, 3) })
			NavMesh.RemoveLink(mesh, 1)
			local bad = NavMesh.AddLink(mesh, { From = v(9, 0, 5), To = v(12, 0, 5) }) -- To is in the gap
			local ok, err = pcall(NavMesh.Update, mesh)
			expect(ok).is(false)
			expect(tostring(err)).is(`NavMesh.Update: link {bad}: To (12.000, 0.000, 5.000) is not on the mesh`)
			-- Everything pending is undone: the pending add is gone, the removal and the crate too.
			expect(NavMesh.HasPendingChanges(mesh)).is(false)
			expect(Storage.LinkCount(mesh :: any)).is(1)
			expect(status(mesh)).is("Success")
			expect(function()
				NavMesh.RemoveObstacle(mesh, crate)
			end).fails_with("already removed")
			expect(NavMesh.AddLink(mesh, JUMP)).is(bad + 1)
		end)

		test("adding and removing a link bumps its end tiles and reports them as changed regions", function()
			local mesh = pads(nil, 4)
			local elsewhere = NavMesh.FindPath(mesh, v(1, 0, 1), v(3, 0, 1))
			local near = NavMesh.FindPath(mesh, v(8, 0, 5), v(9.5, 0, 5))
			local id = NavMesh.AddLink(mesh, JUMP)
			local regions = NavMesh.Update(mesh)
			expect(NavMesh.IsPathValid(mesh, elsewhere)).is_true()
			expect(NavMesh.IsPathValid(mesh, near)).is(false)
			local function covers(rs: { NavMesh.ChangedRegion }, p: vector): boolean
				for _, r in rs do
					if p.X >= r.Min.X and p.X <= r.Max.X and p.Z >= r.Min.Z and p.Z <= r.Max.Z then
						return true
					end
				end
				return false
			end
			expect(#regions).is(2) -- the two end tiles (4 studs apart, not touching)
			expect(covers(regions, v(9, 0, 5)) and covers(regions, v(15, 0, 5))).is_true()
			expect(covers(regions, v(2, 0, 2))).is(false)
			local jump = NavMesh.FindPath(mesh, v(2, 0, 2), v(22, 0, 8))
			expect(NavMesh.FirstAffectedSegment(jump, regions, 0)).never_is(nil)
			NavMesh.RemoveLink(mesh, id)
			local removed = NavMesh.Update(mesh)
			expect(NavMesh.IsPathValid(mesh, jump)).is(false)
			expect(covers(removed, v(9, 0, 5)) and covers(removed, v(15, 0, 5))).is_true()
			expect(NavMesh.FirstAffectedSegment(jump, removed, 0)).never_is(nil)
			-- No change pending: nothing to report.
			expect(#NavMesh.Update(mesh)).is(0)
		end)

		test("link errors point at the caller's line", function()
			local mesh = pads { JUMP }
			NavMesh.RemoveLink(mesh, 1)
			local calls = {
				function()
					NavMesh.AddLink(mesh, { From = 1 } :: any)
				end,
				function()
					NavMesh.RemoveLink(mesh, 9)
				end,
				function()
					NavMesh.RemoveLink(mesh, 1)
				end,
				function()
					NavMesh.SetLinkEnabled(mesh, "nope", true)
				end,
				function()
					NavMesh.SetLinkEnabled(mesh, 9, true)
				end,
			}
			for i, call in calls do
				local ok, err = pcall(call)
				expect(ok).is(false)
				expect(tostring(err):find("Links.spec", 1, true) ~= nil).with_context(`call {i}: {err}`).is_true()
			end
		end)

		test("an explicit Cost is kept at Update, even 0", function()
			local mesh = pads()
			for _, cost in { 0, 0.5, 2 } do
				local id = NavMesh.AddLink(mesh, { From = v(9, 0, 5), To = v(15, 0, 5), Cost = cost })
				NavMesh.Update(mesh)
				local slot = Storage.FindLink(mesh :: any, id)
				expect(select(5, Storage.GetLink(mesh :: any, slot))).with_context(tostring(cost)).is(cost)
			end
		end)

		test("links and obstacles in one Update: every rebuilt tile and link end is a region", function()
			-- A long floor and a radius cap, so the obstacle's clearance stays far from the links.
			local mesh = NavMesh.Build {
				Floors = {
					Ground = {
						Walkable = {
							flat(0, { 0, 0, 40, 0, 40, 10, 0, 10 }),
							flat(0, { 44, 0, 54, 0, 54, 10, 44, 10 }),
						},
					},
				},
				TileSize = 4,
				MaxAgentRadius = 1,
			}
			NavMesh.AddObstacle(mesh, "Ground", { v(1, 0, 1), v(2, 0, 1), v(2, 0, 2), v(1, 0, 2) })
			NavMesh.AddLink(mesh, { From = v(39, 0, 9), To = v(45, 0, 9) })
			NavMesh.AddLink(mesh, { From = v(39, 0, 1), To = v(53, 0, 1) })
			local regions = NavMesh.Update(mesh)
			expect(#regions).is(5) -- the obstacle's tile and four link-end tiles, none touching
			for _, p in { v(1.5, 0, 1.5), v(39, 0, 9), v(45, 0, 9), v(39, 0, 1), v(53, 0, 1) } do
				local hit = false
				for _, r in regions do
					hit = hit or (p.X >= r.Min.X and p.X <= r.Max.X and p.Z >= r.Min.Z and p.Z <= r.Max.Z)
				end
				expect(hit).with_context(`{p}`).is_true()
			end
		end)

		test("a link-only Update leaves the triangles as they were", function()
			local mesh = pads()
			local before = Storage.TriangleCount(mesh :: any)
			local tiles = {}
			for tile = 1, Storage.TileCount(mesh :: any) do
				tiles[tile] = { Storage.GetTileRange(mesh :: any, tile) }
			end
			NavMesh.AddLink(mesh, JUMP)
			NavMesh.Update(mesh)
			expect(Storage.TriangleCount(mesh :: any)).is(before)
			for tile, range in tiles do
				local first, count = Storage.GetTileRange(mesh :: any, tile)
				expect(`{first},{count}`).is(`{range[1]},{range[2]}`)
			end
		end)
	end)

	describe("Link names and ids (ticket 25)", function()
		test("SetLinkEnabled by name toggles every link with that name", function()
			local mesh = pads {
				{ From = v(9, 0, 5), To = v(15, 0, 5), Name = "bridge" },
				{ From = v(9, 0, 8), To = v(15, 0, 8), Name = "bridge" },
				{ From = v(9, 0, 2), To = v(15, 0, 2), Name = "other" },
			}
			NavMesh.SetLinkEnabled(mesh, "bridge", false)
			local enabled = {}
			for slot = 1, 3 do
				table.insert(enabled, tostring(select(9, Storage.GetLink(mesh :: any, slot))))
			end
			expect(table.concat(enabled, ",")).is("false,false,true")
			NavMesh.SetLinkEnabled(mesh, "other", false)
			expect(status(mesh)).is("Partial")
			NavMesh.SetLinkEnabled(mesh, "bridge", true)
			expect(status(mesh)).is("Success")
			expect(function()
				NavMesh.SetLinkEnabled(mesh, "nope", true)
			end).fails_with("no link named 'nope'")
			-- Names come with AddLink too, and a link waiting for Update can be toggled.
			local id = NavMesh.AddLink(mesh, { From = v(9, 0, 3), To = v(15, 0, 3), Name = "late" })
			NavMesh.SetLinkEnabled(mesh, "late", false)
			NavMesh.Update(mesh)
			expect(select(9, Storage.GetLink(mesh :: any, Storage.FindLink(mesh :: any, id)))).is(false)
		end)

		test("SetLinkEnabled by id finds a sparse id", function()
			local mesh = pads { JUMP, { From = v(9, 0, 8), To = v(15, 0, 8) } }
			NavMesh.RemoveLink(mesh, 1)
			NavMesh.Update(mesh)
			NavMesh.SetLinkEnabled(mesh, 2, false)
			expect(status(mesh)).is("Partial")
			NavMesh.SetLinkEnabled(mesh, 2, true)
			expect(status(mesh)).is("Success")
		end)

		test("a link's start waypoint carries its id; an unlabelled link stops the follower too", function()
			local mesh = pads { JUMP, { From = v(9, 0, 8), To = v(15, 0, 8), Cost = 0 } }
			local path = NavMesh.FindPath(mesh, v(8, 0, 8), v(16, 0, 8))
			expect(path.Status).is("Success")
			expect(#path.Waypoints).is(4)
			local w = path.Waypoints
			expect(`{w[1].LinkId},{w[2].LinkId},{w[2].Label},{w[3].LinkId}`).is("nil,2,nil,nil")
			local follower = NavMesh.NewFollower(path)
			local _, _, event = NavMesh.Advance(mesh, follower, w[1].Position, 5)
			expect(event).is(nil)
			local _, _, linkEvent = NavMesh.Advance(mesh, follower, w[2].Position, 5)
			expect(linkEvent).is("Link")
			local link = follower.Link :: NavMesh.FollowerLink
			expect(`{link.Id},{link.Label}`).is("2,")
			expect(link.To == w[3].Position).is_true()
			-- A labelled link keeps its label beside the id.
			local jump = NavMesh.FindPath(pads { JUMP }, v(8, 0, 5), v(16, 0, 5))
			expect(`{jump.Waypoints[2].LinkId},{jump.Waypoints[2].Label}`).is("1,Jump")
		end)

		test("an unlabelled link's hop is tested at its ends only by FirstAffectedSegment", function()
			local mesh = pads { { From = v(9, 0, 5), To = v(15, 0, 5), Cost = 0 } }
			local path = NavMesh.FindPath(mesh, v(8, 0, 5), v(16, 0, 5))
			expect(path.Waypoints[2].LinkId).is(1)
			-- A box over the gap, between the hop's ends, touches no walked segment.
			local gap = { { Floor = "Ground", Min = v(11, -1, 0), Max = v(13, 1, 10) } }
			expect(NavMesh.FirstAffectedSegment(path, gap :: any, 0)).is(nil)
		end)
	end)

	describe("Heuristic scale with link changes", function()
		test("the cached link prices follow adds, removals and toggles", function()
			local mesh = pads()
			expect(Search.HeuristicScale(mesh :: any, {})).is(1)
			local id = NavMesh.AddLink(mesh, { From = v(9, 0, 5), To = v(15, 0, 5), Cost = 1.5, Area = 3 })
			expect(Search.HeuristicScale(mesh :: any, {})).is(1) -- pending: no triangles yet
			NavMesh.Update(mesh)
			expect(Search.HeuristicScale(mesh :: any, {})).is(0.25) -- 1.5 over 6 studs
			expect(Search.HeuristicScale(mesh :: any, { [3] = 2 })).is(0.5)
			expect(Search.HeuristicScale(mesh :: any, { [3] = math.huge })).is(1)
			NavMesh.SetLinkEnabled(mesh, id, false)
			expect(Search.HeuristicScale(mesh :: any, {})).is(1)
			NavMesh.SetLinkEnabled(mesh, id, true)
			expect(Search.HeuristicScale(mesh :: any, {})).is(0.25)
			NavMesh.RemoveLink(mesh, id)
			NavMesh.Update(mesh)
			expect(Search.HeuristicScale(mesh :: any, {})).is(1)
		end)

		test("a free zero-length link makes the scale 0; a dear one bounds nothing", function()
			local mesh = pads { { From = v(5, 0, 5), To = v(5, 0, 5), Cost = 3 } }
			expect(Search.HeuristicScale(mesh :: any, {})).is(1)
			local free = pads { { From = v(5, 0, 5), To = v(5, 0, 5), Cost = 0 } }
			expect(Search.HeuristicScale(free :: any, {})).is(0)
			-- A short link is priced by its length like any other.
			local short = pads { { From = v(5, 0, 5), To = v(5.5, 0, 5), Cost = 0.25 } }
			expect(Search.HeuristicScale(short :: any, {})).is(0.5)
		end)
	end)

	describe("Links in the bake", function()
		test("sparse ids, the next id, pending changes and names survive Serialize", function()
			local mesh = pads { JUMP, { From = v(9, 0, 8), To = v(15, 0, 8), Name = "low" } }
			NavMesh.RemoveLink(mesh, 1)
			NavMesh.Update(mesh)
			local added = NavMesh.AddLink(mesh, { From = v(9, 0, 2), To = v(15, 0, 2), Name = "new", Label = "Hop" })
			NavMesh.RemoveLink(mesh, 2)
			local loaded = NavMesh.Deserialize(NavMesh.Serialize(mesh))
			expect(Storage.LinkCount(loaded :: any)).is(2)
			expect(Storage.GetLinkNextId(loaded :: any)).is(4)
			expect(Storage.GetLinkId(loaded :: any, 1)).is(2)
			expect(Storage.GetLinkState(loaded :: any, 1)).is(Storage.OBSTACLE_PENDING_REMOVE)
			expect(Storage.GetLinkState(loaded :: any, 2)).is(Storage.OBSTACLE_PENDING_ADD)
			expect(`{Storage.GetLinkName(loaded :: any, 1)},{Storage.GetLinkName(loaded :: any, 2)}`).is("low,new")
			expect(NavMesh.HasPendingChanges(loaded)).is_true()
			expect(status(loaded)).is("Success") -- link 2 until Update
			NavMesh.Update(loaded)
			local path = NavMesh.FindPath(loaded, v(2, 0, 2), v(22, 0, 8))
			expect(path.Status).is("Success")
			expect(path.Waypoints[2].LinkId).is(added)
			expect(path.Waypoints[2].Label).is("Hop")
			expect(NavMesh.AddLink(loaded, JUMP)).is(4)
			NavMesh.SetLinkEnabled(loaded, "new", false)
			expect(status(loaded)).is("Partial")
		end)

		test("a mesh with no link names writes no names section", function()
			local plain = NavMesh.Serialize(pads { JUMP })
			local named = NavMesh.Serialize(pads { { From = v(9, 0, 5), To = v(15, 0, 5), Name = "n" } })
			-- Tag 0x0001 comes first, right after the magic and the version.
			expect(buffer.readu16(plain, 6)).never_is(0x0001)
			expect(buffer.readu16(named, 6)).is(0x0001)
		end)

		test("damaged link records and names are rejected", function()
			local mesh = pads { JUMP, { From = v(9, 0, 8), To = v(15, 0, 8), Name = "n" } }
			local data = NavMesh.Serialize(mesh)
			-- Find the links section and its first record's id (after the next id and count).
			local at = 6
			local links, names = nil, nil
			while at < buffer.len(data) do
				local tag, length = buffer.readu16(data, at), buffer.readu32(data, at + 2)
				if tag == 0x8007 then
					links = at + 6
				elseif tag == 0x0001 then
					names = at + 6
				end
				at += 6 + length
			end
			assert(links and names)
			local function damaged(offset: number, value: number): boolean
				local copy = buffer.create(buffer.len(data))
				buffer.copy(copy, 0, data)
				buffer.writeu32(copy, offset, value)
				local ok, err = pcall(NavMesh.Deserialize, copy)
				return not ok and tostring(err) == "NavMesh.Deserialize: the buffer is truncated or corrupt"
			end
			expect(damaged(links + 8, 3)).is_true() -- first id at the next id
			expect(damaged(links + 8, 0)).is_true() -- ids start at 1
			expect(damaged(names + 4, 7)).is_true() -- a name for no link
			expect(damaged(links + 8, 1)).is(false) -- control: the id as it was
		end)
	end)
end

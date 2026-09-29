-- Authors: Logan Hunt (Raildex)
-- September 27, 2026
-- Serialize and Deserialize (ticket 19, SR9): byte-identical round trips, loaded meshes that
-- still update, a frozen v3 bake with its own frozen snapshot, the v1 and v2 bakes rejected,
-- v3's tagged sections, and every load error.

return function(t: tiniest)
	local NavMesh = require("../NavMesh")
	local Storage = require("../Storage")

	local describe = t.describe
	local expect = t.expect
	local test = t.test
	local snapshot = t.snapshot

	local Fixtures = NavMesh.Fixtures

	-- Made once by tools/navmesh/make_bake.luau with format v1: the three-floor fixture with an
	-- area on Upper, a one-way "Drop" link, and a committed obstacle on Ground. Never regenerate
	-- it. Since v2 (2026-09-28) it must be rejected with a message to rebuild the bake.
	local FROZEN_V1 =
		"TlZNUwEAAAAAAAAAAAADAAAABgBHcm91bmQAAAAAAADQQAEAAAAAAAAAAQAAAAQAAAAAAAAAACgAAAAoAAAAAAAABAAAAAAAAAAAAAAAABQAAAAUAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGAFN0YWlycwAAAAAAALBAAQAAAAAAAAABAAAABAAAAAAKAAAAFAAAABQAAAAKAAAEAAAAAAAAAAAAAAAABAAAAAQAAAQAAAAAAAAAAAAAAAAAAAAAABRAAAAAAAAAFEAAAAAAAAAAAAUAVXBwZXIAAAAAAADQQAMAAAAAAAAAAQAAAAQAAAAAFAAAACgAAAAoAAAAFAAABAAAAAAAAAAAAAAAABQAAAAUAAAEAAAAAAAAAAAAFEAAAAAAAAAUQAAAAAAAABRAAAAAAAAAFEAEAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABQQAAAAAAAAFBAAQAAAC4AAAAAAAAAAAAAAAAKAAAAAAAAACgAAAAAAAAAKAAAABQAAAAAAAAAFAAAAAoAAAAAAAAACgAAAAQAAAAAAAAAAAAAAEAAAAAAAAAAQAAAAEAAAAAAAAAAQAAAAAAAAAAAAAAAKAAAAAAAAAAAAAAAFAAAAAoAAAAAAAAAAAAAAAAAAAAAAAAAQAAAAEAAAAAAAAAAQAAAAEAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAEAAAABAAAAAQAAAFAAAAAEAAAACAAAAAgAAAAMAAAADAAAABAAAAAQAAAAFAAAABQAAAAEAAAAGAAAABwAAAAgAAAAJAAAACQAAAAoAAAAKAAAACwAAAAsAAAAIAAAACgAAAAEAAAABAAAAAQAAAAEAAAABAAAAAAAAAAMAAAADAAAAAwAAAAMAAAAKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAMEAAAAAAAAAwQAAAAAAmAAAAAAoAAAAAAAAAEAAAAAAAAAAQAAAABAAAAAoAAAAEAAAACgAAAAAAAAAKAAAABAAAAAAAAAAAAAAAEAAAAAAAAAAQAAAAEAAAAAAAAAAQAAAACgAAAAAAAAAKAAAAAAAAAAAAAAAAAAAAAAAAABAAAAAQAAAAAAAAABAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAABAAAAAEAAASAAAAAQAAAAIAAAACAAAAAwAAAAMAAAAEAAAABAAAAAEAAAAFAAAABgAAAAcAAAAIAAAACAAAAAkAAAAJAAAACgAAAAoAAAAHAAAACQAAAAEAAAABAAAAAQAAAAEAAAAAAAAAAwAAAAMAAAADAAAAAwAAAAkAAAAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAACAAAAAAAAAAAAMEAAAAAAAAAAAAAAAAAAAEBAAAAAAAAAMEAAAAAAJgAAAAAQAAAAAAAAABQAAAAAAAAAFAAAAAQAAAAQAAAABAAAABQAAAAAAAAAFAAAAAQAAAAQAAAAAAAAACAAAAAAAAAAIAAAABAAAAAQAAAAEAAAABQAAAAAAAAAFAAAAAAAAAAQAAAAAAAAABAAAAAQAAAAIAAAAAAAAAAgAAAAEAAAACAAAAAAAAAAIAAAABAAAAAQAAAABAAAEgAAAAEAAAACAAAAAgAAAAMAAAADAAAABAAAAAQAAAABAAAABQAAAAYAAAAHAAAACAAAAAgAAAAJAAAACQAAAAoAAAAKAAAABwAAAAkAAAABAAAAAQAAAAEAAAABAAAAAAAAAAMAAAADAAAAAwAAAAMAAAAJAAAAAAAAAAAAAAAAAAAAAAAAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABQQAAAAAAAAFBAAQAAACwAAAAAFAAAAAAAAAAoAAAAAAAAACgAAAAUAAAAFAAAABQAAAAUAAAABAAAABQAAAAAAAAAFAAAAAQAAAAAAAAAAAAAAEAAAAAAAAAAQAAAAEAAAAAAAAAAQAAAABQAAAAAAAAAKAAAAAAAAAAUAAAAAAAAAAAAAAAAAAAAAAAAAEAAAABAAAAAAAAAAEAAAABAAAAAAAAAAAAAAABAAAAAAAAAAAAAAABAAAAAQAAAAEAAABQAAAABAAAAAgAAAAIAAAADAAAAAwAAAAQAAAAEAAAABQAAAAUAAAABAAAABgAAAAcAAAAIAAAACQAAAAkAAAAKAAAACgAAAAsAAAALAAAACAAAAAoAAAABAAAAAQAAAAEAAAABAAAAAQAAAAAAAAADAAAAAwAAAAMAAAADAAAACgAAAAAAAAAAAAAAAAAA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"

	-- Made once by tools/navmesh/make_bake.luau with format v2 (sparse obstacle records and the
	-- next obstacle id): the same scene as FROZEN_V1. Never regenerate it. Since v3 (2026-09-28)
	-- it must be rejected with a message to rebuild the bake.
	local FROZEN_V2 =
		"TlZNUwIAAAAAAAAAAAADAAAABgBHcm91bmQAAAAAAADQQAEAAAAAAAAAAQAAAAQAAAAAAAAAACgAAAAoAAAAAAAABAAAAAAAAAAAAAAAABQAAAAUAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGAFN0YWlycwAAAAAAALBAAQAAAAAAAAABAAAABAAAAAAKAAAAFAAAABQAAAAKAAAEAAAAAAAAAAAAAAAABAAAAAQAAAQAAAAAAAAAAAAAAAAAAAAAABRAAAAAAAAAFEAAAAAAAAAAAAUAVXBwZXIAAAAAAADQQAMAAAAAAAAAAQAAAAQAAAAAFAAAACgAAAAoAAAAFAAABAAAAAAAAAAAAAAAABQAAAAUAAAEAAAAAAAAAAAAFEAAAAAAAAAUQAAAAAAAABRAAAAAAAAAFEAEAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABQQAAAAAAAAFBAAQAAAC4AAAAAAAAAAAAAAAAKAAAAAAAAACgAAAAAAAAAKAAAABQAAAAAAAAAFAAAAAoAAAAAAAAACgAAAAQAAAAAAAAAAAAAAEAAAAAAAAAAQAAAAEAAAAAAAAAAQAAAAAAAAAAAAAAAKAAAAAAAAAAAAAAAFAAAAAoAAAAAAAAAAAAAAAAAAAAAAAAAQAAAAEAAAAAAAAAAQAAAAEAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAEAAAABAAAAAQAAAFAAAAAEAAAACAAAAAgAAAAMAAAADAAAABAAAAAQAAAAFAAAABQAAAAEAAAAGAAAABwAAAAgAAAAJAAAACQAAAAoAAAAKAAAACwAAAAsAAAAIAAAACgAAAAEAAAABAAAAAQAAAAEAAAABAAAAAAAAAAMAAAADAAAAAwAAAAMAAAAKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAMEAAAAAAAAAwQAAAAAAmAAAAAAoAAAAAAAAAEAAAAAAAAAAQAAAABAAAAAoAAAAEAAAACgAAAAAAAAAKAAAABAAAAAAAAAAAAAAAEAAAAAAAAAAQAAAAEAAAAAAAAAAQAAAACgAAAAAAAAAKAAAAAAAAAAAAAAAAAAAAAAAAABAAAAAQAAAAAAAAABAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAABAAAAAEAAASAAAAAQAAAAIAAAACAAAAAwAAAAMAAAAEAAAABAAAAAEAAAAFAAAABgAAAAcAAAAIAAAACAAAAAkAAAAJAAAACgAAAAoAAAAHAAAACQAAAAEAAAABAAAAAQAAAAEAAAAAAAAAAwAAAAMAAAADAAAAAwAAAAkAAAAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAACAAAAAAAAAAAAMEAAAAAAAAAAAAAAAAAAAEBAAAAAAAAAMEAAAAAAJgAAAAAQAAAAAAAAABQAAAAAAAAAFAAAAAQAAAAQAAAABAAAABQAAAAAAAAAFAAAAAQAAAAQAAAAAAAAACAAAAAAAAAAIAAAABAAAAAQAAAAEAAAABQAAAAAAAAAFAAAAAAAAAAQAAAAAAAAABAAAAAQAAAAIAAAAAAAAAAgAAAAEAAAACAAAAAAAAAAIAAAABAAAAAQAAAABAAAEgAAAAEAAAACAAAAAgAAAAMAAAADAAAABAAAAAQAAAABAAAABQAAAAYAAAAHAAAACAAAAAgAAAAJAAAACQAAAAoAAAAKAAAABwAAAAkAAAABAAAAAQAAAAEAAAABAAAAAAAAAAMAAAADAAAAAwAAAAMAAAAJAAAAAAAAAAAAAAAAAAAAAAAAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABQQAAAAAAAAFBAAQAAACwAAAAAFAAAAAAAAAAoAAAAAAAAACgAAAAUAAAAFAAAABQAAAAUAAAABAAAABQAAAAAAAAAFAAAAAQAAAAAAAAAAAAAAEAAAAAAAAAAQAAAAEAAAAAAAAAAQAAAABQAAAAAAAAAKAAAAAAAAAAUAAAAAAAAAAAAAAAAAAAAAAAAAEAAAABAAAAAAAAAAEAAAABAAAAAAAAAAAAAAABAAAAAAAAAAAAAAABAAAAAQAAAAEAAABQAAAABAAAAAgAAAAIAAAADAAAAAwAAAAQAAAAEAAAABQAAAAUAAAABAAAABgAAAAcAAAAIAAAACQAAAAkAAAAKAAAACgAAAAsAAAALAAAACAAAAAoAAAABAAAAAQAAAAEAAAABAAAAAQAAAAAAAAADAAAAAwAAAAMAAAADAAAACgAAAAAAAAAAAAAAAAAA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"

	-- Made once by tools/navmesh/make_bake.luau with format v3 (tagged sections; authored rings
	-- instead of per-tile triangulation input): the same scene. Never regenerate it; a later
	-- format adds its own bake, and this one is then expected to be rejected or still read.
	local FROZEN_V3 =
		"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"

	local function fromBase64(text: string): buffer
		local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
		local value = {}
		for i = 1, #alphabet do
			value[string.sub(alphabet, i, i)] = i - 1
		end
		local bytes = {}
		for i = 1, #text, 4 do
			local chunk = string.sub(text, i, i + 3)
			local n = 0
			for k = 1, 4 do
				n = n * 64 + (value[string.sub(chunk, k, k)] or 0)
			end
			table.insert(bytes, string.char(bit32.rshift(n, 16) % 256))
			if string.sub(chunk, 3, 3) ~= "=" then
				table.insert(bytes, string.char(bit32.rshift(n, 8) % 256))
			end
			if string.sub(chunk, 4, 4) ~= "=" then
				table.insert(bytes, string.char(n % 256))
			end
		end
		return buffer.fromstring(table.concat(bytes))
	end

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

	local function canonical(mesh: any): string
		local rows = {}
		for _, primitive in NavMesh.ToDrawList(mesh, { Tiles = true, Areas = true, Seams = true, Links = true }) do
			local numbers = {}
			for _, x in primitive.Points do
				table.insert(numbers, string.format("%.4f", x))
			end
			table.insert(rows, `{primitive.Kind}|{primitive.Layer}|{primitive.Color}|{table.concat(numbers, ",")}`)
		end
		table.sort(rows)
		return table.concat(rows, "\n")
	end

	describe("Serialize", function()
		test("every fixture round-trips byte for byte, and draws and paths the same", function()
			for _, scenario in Fixtures.All do
				local mesh = NavMesh.Build(scenario.Desc)
				local data = NavMesh.Serialize(mesh)
				local loaded = NavMesh.Deserialize(data)
				expect(buffer.tostring(NavMesh.Serialize(loaded)) == buffer.tostring(data))
					.with_context(scenario.Name)
					.is_true()
				expect(canonical(loaded)).with_context(scenario.Name).is(canonical(mesh))
				expect(Storage.TriangleCount(loaded)).is(Storage.TriangleCount(mesh))
			end
			local stairs = NavMesh.Deserialize(NavMesh.Serialize(NavMesh.Build(Fixtures.ThreeFloorStairs.Desc)))
			expect(NavMesh.FindPath(stairs, v(2, 0, 2), v(30, 5, 10)).Status).is("Success")
			local jump = NavMesh.Deserialize(NavMesh.Serialize(NavMesh.Build(Fixtures.LinkJump.Desc)))
			expect(NavMesh.FindPath(jump, v(2, 0, 2), v(22, 0, 8)).Waypoints[2].Label).is("Jump")
		end)

		test("a loaded mesh keeps its obstacles, stamps and toggles, and still updates", function()
			local desc: any = table.clone(Fixtures.Courtyard.Desc)
			desc.TileSize = 4
			local mesh = NavMesh.Build(desc)
			local crate = NavMesh.AddObstacle(mesh, "Ground", flat(0, { 20.3, 1.2, 22.8, 1.4, 22.5, 3.7, 20.1, 3.3 }))
			NavMesh.Update(mesh)
			local path = NavMesh.FindPath(mesh, v(1, 0, 1), v(29, 0, 19))
			local loaded = NavMesh.Deserialize(NavMesh.Serialize(mesh))
			expect(canonical(loaded)).is(canonical(mesh))
			expect(NavMesh.IsPathValid(loaded, path)).is_true()
			-- The same edits on both give the same meshes: removing the crate, adding another.
			for _, m in { mesh, loaded } do
				NavMesh.RemoveObstacle(m, crate)
				NavMesh.AddObstacle(m, "Ground", flat(0, { 6.2, 11.1, 8.4, 11.3, 8.1, 13.9, 6.4, 13.6 }))
				NavMesh.Update(m)
			end
			expect(canonical(loaded)).is(canonical(mesh))
			expect(NavMesh.IsPathValid(loaded, path)).is(NavMesh.IsPathValid(mesh, path))
		end)

		test("a loaded mesh answers every query like the original (walls, seams, radius)", function()
			for _, scenario in { Fixtures.ThreeFloorStairs, Fixtures.Courtyard } do
				local mesh = NavMesh.Build(scenario.Desc)
				local loaded = NavMesh.Deserialize(NavMesh.Serialize(mesh))
				local spots = if scenario == Fixtures.ThreeFloorStairs
					then { v(2, 0, 2), v(30, 5, 2), v(12.7, 1.3, 2.2), v(38, 5, 18), v(25, 0, 12) }
					else { v(1, 0, 1), v(29, 0, 1), v(1, 0, 29), v(17, 0, 29), v(6, 0, 10) }
				local function answers(m: any, a: any, b: any): string
					local path = NavMesh.FindPath(m, a, b, { AgentRadius = 0.6 })
					local parts = { path.Status }
					for _, w in path.Waypoints do
						table.insert(parts, string.format("%.5f,%.5f,%.5f", w.Position.X, w.Position.Y, w.Position.Z))
					end
					local blocked, stop = NavMesh.Raycast(m, a, b)
					local moved = NavMesh.MoveAlongSurface(m, a, b, { AgentRadius = 0.4 }).Position
					local d = NavMesh.FindDistanceToWall(m, a, 50)
					table.insert(
						parts,
						string.format(
							"%s %.5f,%.5f %.5f,%.5f %.5f",
							tostring(blocked),
							stop.X,
							stop.Z,
							moved.X,
							moved.Z,
							d
						)
					)
					return table.concat(parts, " ")
				end
				for _, a in spots do
					for _, b in spots do
						expect(answers(loaded, a, b)).with_context(scenario.Name).is(answers(mesh, a, b))
					end
				end
				-- An update on the loaded mesh re-derives the same widths (walls and open edges
				-- come back from the buffer).
				local crate = flat(0, { 3.1, 12.2, 4.9, 12.4, 4.7, 13.8, 3.3, 13.6 })
				for _, m in { mesh, loaded } do
					NavMesh.AddObstacle(m, "Ground", crate)
					NavMesh.Update(m)
				end
				expect(buffer.tostring(NavMesh.Serialize(loaded)) == buffer.tostring(NavMesh.Serialize(mesh)))
					.with_context(scenario.Name)
					.is_true()
			end
		end)

		test("link toggles and one-way links survive a round trip", function()
			for _, scenario in { Fixtures.LinkJump, Fixtures.OneWayLink } do
				for _, enabled in { true, false } do
					local mesh = NavMesh.Build(scenario.Desc)
					NavMesh.SetLinkEnabled(mesh, 1, enabled)
					local loaded = NavMesh.Deserialize(NavMesh.Serialize(mesh))
					local _, _, _, _, _, _, _, both, on = Storage.GetLink(loaded, 1)
					local _, _, _, _, _, _, _, wantBoth, wantOn = Storage.GetLink(mesh, 1)
					expect(both).with_context(`{scenario.Name} {enabled}`).is(wantBoth)
					expect(on).with_context(`{scenario.Name} {enabled}`).is(wantOn)
				end
			end
		end)

		test("meshes of many sizes round-trip (the writer grows at any byte)", function()
			-- Each extra crate adds a few hundred bytes, so the buffer's doublings land on every
			-- kind of field.
			local crates = {}
			for i = 0, 40 do
				local desc: any = {
					TileSize = 8,
					Floors = { Ground = { Walkable = { flat(0, { 0, 0, 64, 0, 64, 8, 0, 8 }) }, Obstacles = crates } },
					Links = if i % 2 == 0
						then { { From = v(0.5, 0, 0.5), To = v(63.5, 0, 7.5), Label = "L" } }
						else nil,
				}
				local mesh = NavMesh.Build(desc)
				local data = NavMesh.Serialize(mesh)
				expect(buffer.tostring(NavMesh.Serialize(NavMesh.Deserialize(data))) == buffer.tostring(data))
					.with_context(`{i} crates`)
					.is_true()
				local x = 1 + i * 1.5
				table.insert(crates, flat(0, { x, 2 + (i % 3) * 0.3, x + 0.7, 2.1, x + 0.6, 5.4, x + 0.1, 5.2 }))
			end
		end)

		test("the frozen v3 bake loads and matches its own frozen snapshot (SR9)", function()
			local mesh = NavMesh.Deserialize(fromBase64(FROZEN_V3))
			local list = NavMesh.ToDrawList(mesh, { Tiles = true, Areas = true, Seams = true, Links = true })
			for _, primitive in list do
				for i, x in primitive.Points do
					primitive.Points[i] = math.round(x * 1e4) / 1e4
				end
			end
			snapshot(list)
			local down = NavMesh.FindPath(mesh, v(38, 5, 18), v(35, 0, 18))
			expect(down.Status).is("Success")
			expect(down.Waypoints[1].Label).is("Drop")
			expect(NavMesh.FindPath(mesh, v(2, 0, 2), v(30, 5, 10)).Status).is("Success")
		end)

		test("the frozen v1 and v2 bakes are rejected with a message to rebuild them (SR9)", function()
			expect(function()
				NavMesh.Deserialize(fromBase64(FROZEN_V1))
			end).fails_with("^NavMesh.Deserialize: this is a format v1 bake, .*rebuild it")
			expect(function()
				NavMesh.Deserialize(fromBase64(FROZEN_V2))
			end).fails_with("^NavMesh.Deserialize: this is a format v2 bake, .*rebuild it")
		end)

		test("v3 sections: unknown optional ones are skipped, unknown required ones refused", function()
			local mesh = NavMesh.Build(Fixtures.SplitLevel.Desc)
			local data = buffer.tostring(NavMesh.Serialize(mesh))
			local function section(tag: number, payload: string): string
				local b = buffer.create(6)
				buffer.writeu16(b, 0, tag)
				buffer.writeu32(b, 2, #payload)
				return buffer.tostring(b) .. payload
			end
			-- Sections are in ascending tag order: optional tags (below 0x8000) come first.
			local optional = buffer.fromstring(
				string.sub(data, 1, 6) .. section(0x0100, "abc") .. section(0x7FFF, "") .. string.sub(data, 7)
			)
			expect(canonical(NavMesh.Deserialize(optional))).is(canonical(mesh))
			expect(function()
				NavMesh.Deserialize(buffer.fromstring(data .. section(0x8100, "")))
			end).fails_with("needs a newer build %(it has required section 0x8100%)")
			-- A repeated or out-of-order tag, and a known section longer than its content.
			for _, bad in
				{
					data .. section(0x8008, ""),
					string.sub(data, 1, 6) .. section(0x0001, "") .. section(0x0001, "") .. string.sub(data, 7),
				}
			do
				expect(function()
					NavMesh.Deserialize(buffer.fromstring(bad))
				end).fails_with("truncated or corrupt")
			end
			-- The first section (the cap: an f64) one byte longer.
			local long = buffer.fromstring(
				string.sub(data, 1, 8)
					.. string.char(9, 0, 0, 0)
					.. string.sub(data, 13, 20)
					.. "x"
					.. string.sub(data, 21)
			)
			expect(function()
				NavMesh.Deserialize(long)
			end).fails_with("truncated or corrupt")
			-- A known section missing entirely.
			local noCap = buffer.fromstring(string.sub(data, 1, 6) .. string.sub(data, 21))
			expect(function()
				NavMesh.Deserialize(noCap)
			end).fails_with("truncated or corrupt")
		end)

		test("damaged obstacle records are rejected: ids must increase below the next id", function()
			local mesh = NavMesh.Build(Fixtures.SplitLevel.Desc)
			NavMesh.AddObstacle(mesh, "Ground", flat(0, { 2, 2, 4, 2, 4, 4, 2, 4 }))
			local data = NavMesh.Serialize(mesh)
			-- The tail: next id, count, then one record (id, floor, state u8, two 4-point lists).
			local recordAt = buffer.len(data) - (4 + 4 + 1 + 2 * (4 + 4 * 4))
			expect(buffer.readu32(data, recordAt - 8)).is(2) -- the next id
			expect(buffer.readu32(data, recordAt)).is(1) -- the record's id
			for _, damage in { { recordAt, 2, 4 }, { recordAt, 0, 4 }, { recordAt + 8, 0, 1 }, { recordAt + 8, 4, 1 } } do
				local bad = buffer.fromstring(buffer.tostring(data))
				if damage[3] == 4 then
					buffer.writeu32(bad, damage[1], damage[2])
				else
					buffer.writeu8(bad, damage[1], damage[2])
				end
				expect(function()
						NavMesh.Deserialize(bad)
					end)
					.with_context(`byte {damage[1]} = {damage[2]}`)
					.fails_with("truncated or corrupt")
			end
			expect(Storage.ObstacleCount(NavMesh.Deserialize(data))).is(1)
		end)

		test("loading rejects another version, a foreign buffer, and damage", function()
			local data = NavMesh.Serialize(NavMesh.Build(Fixtures.SplitLevel.Desc))
			local v4 = buffer.fromstring(buffer.tostring(data))
			buffer.writeu16(v4, 4, 4)
			expect(function()
				NavMesh.Deserialize(v4)
			end).fails_with("unsupported format version 4 %(this build reads 3%)")
			expect(function()
				NavMesh.Deserialize(buffer.fromstring("HELLO WORLD"))
			end).fails_with("not a NavMesh bake")
			local cut = buffer.fromstring(string.sub(buffer.tostring(data), 1, buffer.len(data) - 5))
			expect(function()
				NavMesh.Deserialize(cut)
			end).fails_with("truncated or corrupt")
			expect(function()
				NavMesh.Deserialize(buffer.fromstring(buffer.tostring(data) .. "!"))
			end).fails_with("truncated or corrupt")
			expect(function()
				NavMesh.Deserialize("nope" :: any)
			end).fails_with("expected a buffer")
			-- Shorter than the header: too short to be a bake; exactly the header: truncated.
			expect(function()
				NavMesh.Deserialize(buffer.fromstring("NV"))
			end).fails_with("not a NavMesh bake")
			expect(function()
				NavMesh.Deserialize(buffer.fromstring(string.sub(buffer.tostring(data), 1, 6)))
			end).fails_with("truncated or corrupt")
			-- Every message is the module's own, with no source position in front.
			for _, bad in
				{
					v4,
					buffer.fromstring("HELLO WORLD"),
					cut,
					buffer.fromstring(buffer.tostring(data) .. "!"),
					"nope" :: any,
				}
			do
				local ok, err = pcall(NavMesh.Deserialize, bad)
				expect(ok).is(false)
				expect(string.sub(tostring(err), 1, 21)).with_context(tostring(err)).is("NavMesh.Deserialize: ")
			end
		end)
	end)
end

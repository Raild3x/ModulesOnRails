-- Authors: Logan Hunt (Raildex)
-- September 27, 2026
-- Serialize and Deserialize (ticket 19, SR9): byte-identical round trips, loaded meshes that
-- still update, a frozen v1 bake with its own frozen snapshot, and every load error.

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
	-- it; a v2 format adds its own bake, and this one is then expected to error.
	local FROZEN_V1 =
		"TlZNUwEAAAAAAAAAAAADAAAABgBHcm91bmQAAAAAAADQQAEAAAAAAAAAAQAAAAQAAAAAAAAAACgAAAAoAAAAAAAABAAAAAAAAAAAAAAAABQAAAAUAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGAFN0YWlycwAAAAAAALBAAQAAAAAAAAABAAAABAAAAAAKAAAAFAAAABQAAAAKAAAEAAAAAAAAAAAAAAAABAAAAAQAAAQAAAAAAAAAAAAAAAAAAAAAABRAAAAAAAAAFEAAAAAAAAAAAAUAVXBwZXIAAAAAAADQQAMAAAAAAAAAAQAAAAQAAAAAFAAAACgAAAAoAAAAFAAABAAAAAAAAAAAAAAAABQAAAAUAAAEAAAAAAAAAAAAFEAAAAAAAAAUQAAAAAAAABRAAAAAAAAAFEAEAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABQQAAAAAAAAFBAAQAAAC4AAAAAAAAAAAAAAAAKAAAAAAAAACgAAAAAAAAAKAAAABQAAAAAAAAAFAAAAAoAAAAAAAAACgAAAAQAAAAAAAAAAAAAAEAAAAAAAAAAQAAAAEAAAAAAAAAAQAAAAAAAAAAAAAAAKAAAAAAAAAAAAAAAFAAAAAoAAAAAAAAAAAAAAAAAAAAAAAAAQAAAAEAAAAAAAAAAQAAAAEAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAEAAAABAAAAAQAAAFAAAAAEAAAACAAAAAgAAAAMAAAADAAAABAAAAAQAAAAFAAAABQAAAAEAAAAGAAAABwAAAAgAAAAJAAAACQAAAAoAAAAKAAAACwAAAAsAAAAIAAAACgAAAAEAAAABAAAAAQAAAAEAAAABAAAAAAAAAAMAAAADAAAAAwAAAAMAAAAKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAMEAAAAAAAAAwQAAAAAAmAAAAAAoAAAAAAAAAEAAAAAAAAAAQAAAABAAAAAoAAAAEAAAACgAAAAAAAAAKAAAABAAAAAAAAAAAAAAAEAAAAAAAAAAQAAAAEAAAAAAAAAAQAAAACgAAAAAAAAAKAAAAAAAAAAAAAAAAAAAAAAAAABAAAAAQAAAAAAAAABAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAABAAAAAEAAASAAAAAQAAAAIAAAACAAAAAwAAAAMAAAAEAAAABAAAAAEAAAAFAAAABgAAAAcAAAAIAAAACAAAAAkAAAAJAAAACgAAAAoAAAAHAAAACQAAAAEAAAABAAAAAQAAAAEAAAAAAAAAAwAAAAMAAAADAAAAAwAAAAkAAAAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAACAAAAAAAAAAAAMEAAAAAAAAAAAAAAAAAAAEBAAAAAAAAAMEAAAAAAJgAAAAAQAAAAAAAAABQAAAAAAAAAFAAAAAQAAAAQAAAABAAAABQAAAAAAAAAFAAAAAQAAAAQAAAAAAAAACAAAAAAAAAAIAAAABAAAAAQAAAAEAAAABQAAAAAAAAAFAAAAAAAAAAQAAAAAAAAABAAAAAQAAAAIAAAAAAAAAAgAAAAEAAAACAAAAAAAAAAIAAAABAAAAAQAAAABAAAEgAAAAEAAAACAAAAAgAAAAMAAAADAAAABAAAAAQAAAABAAAABQAAAAYAAAAHAAAACAAAAAgAAAAJAAAACQAAAAoAAAAKAAAABwAAAAkAAAABAAAAAQAAAAEAAAABAAAAAAAAAAMAAAADAAAAAwAAAAMAAAAJAAAAAAAAAAAAAAAAAAAAAAAAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABQQAAAAAAAAFBAAQAAACwAAAAAFAAAAAAAAAAoAAAAAAAAACgAAAAUAAAAFAAAABQAAAAUAAAABAAAABQAAAAAAAAAFAAAAAQAAAAAAAAAAAAAAEAAAAAAAAAAQAAAAEAAAAAAAAAAQAAAABQAAAAAAAAAKAAAAAAAAAAUAAAAAAAAAAAAAAAAAAAAAAAAAEAAAABAAAAAAAAAAEAAAABAAAAAAAAAAAAAAABAAAAAAAAAAAAAAABAAAAAQAAAAEAAABQAAAABAAAAAgAAAAIAAAADAAAAAwAAAAQAAAAEAAAABQAAAAUAAAABAAAABgAAAAcAAAAIAAAACQAAAAkAAAAKAAAACgAAAAsAAAALAAAACAAAAAoAAAABAAAAAQAAAAEAAAABAAAAAQAAAAAAAAADAAAAAwAAAAMAAAADAAAACgAAAAAAAAAAAAAAAAAA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"

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

		test("the frozen v1 bake loads and matches its own frozen snapshot (SR9)", function()
			local mesh = NavMesh.Deserialize(fromBase64(FROZEN_V1))
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

		test("loading rejects another version, a foreign buffer, and damage", function()
			local data = NavMesh.Serialize(NavMesh.Build(Fixtures.SplitLevel.Desc))
			local v2 = buffer.fromstring(buffer.tostring(data))
			buffer.writeu16(v2, 4, 2)
			expect(function()
				NavMesh.Deserialize(v2)
			end).fails_with("unsupported format version 2")
			expect(function()
				NavMesh.Deserialize(buffer.fromstring("HELLO WORLD"))
			end).fails_with("not a NavMesh bake")
			local cut = buffer.fromstring(string.sub(buffer.tostring(data), 1, buffer.len(data) - 5))
			expect(function()
				NavMesh.Deserialize(cut)
			end).fails_with("truncated or corrupt")
			expect(function()
				NavMesh.Deserialize(buffer.fromstring(buffer.tostring(data) .. "!"))
			end).fails_with("trailing bytes")
			expect(function()
				NavMesh.Deserialize("nope" :: any)
			end).fails_with("expected a buffer")
		end)
	end)
end

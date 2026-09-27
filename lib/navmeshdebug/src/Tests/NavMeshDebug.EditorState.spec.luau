-- Authors: Logan Hunt (Raildex)
-- September 27, 2026

return function(t: tiniest)
	local ConstrainedDelaunay = require("../../ConstrainedDelaunay")
	local EditorState = require("../EditorState")
	local NavMesh = require("../../NavMesh")
	local same = require("./Helpers/Same")

	local describe = t.describe
	local expect = t.expect
	local test = t.test

	local DOWN = vector.create(0, -1, 0)

	-- Pointer events looking straight down on (x, z).
	local function press(state, x: number, z: number): boolean
		return EditorState.Apply(state, { Type = "PointerDown", Origin = vector.create(x, 100, z), Direction = DOWN })
	end
	local function drag(state, x: number, z: number): boolean
		return EditorState.Apply(state, { Type = "Drag", Origin = vector.create(x, 100, z), Direction = DOWN })
	end

	local function stairs()
		return EditorState.new("NavMesh", NavMesh.Fixtures.ThreeFloorStairs.Desc)
	end

	describe("EditorState (NavMesh)", function()
		test("edits a copy of the initial description", function()
			local state = stairs()
			expect(state.Description ~= NavMesh.Fixtures.ThreeFloorStairs.Desc).is_true()
			press(state, 40, 20)
			drag(state, 44, 24)
			expect(NavMesh.Fixtures.ThreeFloorStairs.Desc.Floors.Upper.Walkable[1][3]).is(vector.create(40, 5, 20))
		end)

		test("starts from a 20-stud square without an initial description", function()
			local state = EditorState.new("NavMesh")
			expect(#state.Description.Floors.Ground.Walkable[1]).is(4)
			expect(function()
				NavMesh.Build(state.Description)
			end).never_fails()
		end)

		test("a press selects the handle nearest the ray, or nothing", function()
			local state = stairs()
			press(state, 40.4, 20.3)
			local selection = state.Selection :: any
			-- Ground and Upper both have a vertex over (40, 20); the nearer one to the ray wins
			-- ties by order, and both are within reach.
			expect(selection.Kind).is("Vertex")
			expect(selection.Index).is(3)
			press(state, 30, 10)
			expect(state.Selection).never_exists()
		end)

		test("a drag moves the vertex across its own height, snapped to the grid", function()
			local state = stairs()
			press(state, 20, 4)
			local selection = state.Selection :: any
			local before = EditorState.HandlePosition(state, selection)
			expect(drag(state, 22.1, 6.9)).is_true()
			local after = EditorState.HandlePosition(state, selection)
			expect(after).is(vector.create(22, before.Y, 7))
			expect(drag(state, 22.1, 6.9)).never_is_true()
		end)

		test("a drag with nothing selected changes nothing", function()
			local state = stairs()
			expect(drag(state, 5, 5)).never_is_true()
		end)

		test("creates walkable, obstacle and area rings", function()
			local state = EditorState.new("NavMesh")
			expect(
				EditorState.Apply(
					state,
					{ Type = "CreateRing", Kind = "Obstacle", Position = vector.create(10, 0, 10) }
				)
			).is_true()
			local ground = state.Description.Floors.Ground
			expect(same(ground.Obstacles[1], {
				vector.create(8, 0, 8),
				vector.create(12, 0, 8),
				vector.create(12, 0, 12),
				vector.create(8, 0, 12),
			})).is_true()
			expect((state.Selection :: any).List).is("Obstacles")
			EditorState.Apply(
				state,
				{ Type = "CreateRing", Kind = "Area", Position = vector.create(4, 0, 4), Size = 2, Area = 3 }
			)
			expect(ground.Areas[1].Area).is(3)
			EditorState.Apply(
				state,
				{ Type = "CreateRing", Kind = "Walkable", Floor = "Roof", Position = vector.create(4, 9, 4) }
			)
			expect(state.Description.Floors.Roof.Walkable[1][1]).is(vector.create(2, 9, 2))
			expect(function()
				EditorState.Apply(state, { Type = "CreateRing", Kind = "Hole", Position = vector.zero })
			end).fails_with("unknown ring Kind Hole")
			local mesh = NavMesh.Build(state.Description)
			expect(NavMesh.FindPath(mesh, vector.create(1, 0, 1), vector.create(19, 0, 19)).Status).is("Success")
		end)

		test("inserts a vertex at the middle of the selected edge", function()
			local state = EditorState.new("NavMesh")
			press(state, 0, 0)
			expect(EditorState.Apply(state, { Type = "InsertVertex" })).is_true()
			local ring = state.Description.Floors.Ground.Walkable[1]
			expect(#ring).is(5)
			expect(ring[2]).is(vector.create(10, 0, 0))
			expect((state.Selection :: any).Index).is(2)
		end)

		test("deletes a vertex, and the ring once it drops below 3", function()
			local state = EditorState.new("NavMesh")
			EditorState.Apply(state, { Type = "CreateRing", Kind = "Obstacle", Position = vector.create(10, 0, 10) })
			local obstacles = state.Description.Floors.Ground.Obstacles
			press(state, 8, 8)
			expect(EditorState.Apply(state, { Type = "Delete" })).is_true()
			expect(#obstacles[1]).is(3)
			expect(state.Selection).never_exists()
			press(state, 12, 8)
			EditorState.Apply(state, { Type = "Delete" })
			expect(#obstacles).is(0)
			expect(EditorState.Apply(state, { Type = "Delete" })).never_is_true()
		end)

		test("creates and deletes seams and links", function()
			local state = stairs()
			press(state, 30, 10) -- nothing there, so the seam's floors default to the first two
			EditorState.Apply(
				state,
				{ Type = "CreateSeam", From = vector.create(0, 0, 20), To = vector.create(4, 0, 20) }
			)
			local seam = state.Description.Seams[3]
			expect(seam.FloorA).is("Ground")
			expect(seam.FloorB).is("Stairs")
			EditorState.Apply(state, {
				Type = "CreateLink",
				From = vector.create(30, 5, 10),
				To = vector.create(30, 0, 12),
				Bidirectional = false,
				Label = "Drop",
			})
			local link = state.Description.Links[1]
			expect(link.Bidirectional).is(false)
			expect(link.Label).is("Drop")
			press(state, 30, 12)
			expect((state.Selection :: any).Kind).is("Link")
			EditorState.Apply(state, { Type = "Delete" })
			expect(#state.Description.Links).is(0)
			expect(function()
				EditorState.Apply(
					EditorState.new("NavMesh"),
					{ Type = "CreateSeam", From = vector.zero, To = vector.one }
				)
			end).fails_with("CreateSeam needs two floors")
		end)

		test("a synthetic editing session still builds and finds a path", function()
			local state = stairs()
			EditorState.Apply(
				state,
				{ Type = "CreateRing", Kind = "Obstacle", Floor = "Ground", Position = vector.create(30, 0, 10) }
			)
			press(state, 32, 12)
			drag(state, 33, 14)
			EditorState.Apply(state, { Type = "InsertVertex" })
			press(state, 0, 20)
			drag(state, 0, 22)
			EditorState.Apply(state, { Type = "SetMarker", Which = "Start", Position = vector.create(2, 0, 2) })
			EditorState.Apply(state, { Type = "SetMarker", Which = "Goal", Position = vector.create(36, 5, 18) })
			local mesh = NavMesh.Build(state.Description)
			local path = NavMesh.FindPath(mesh, state.Start :: any, state.Goal :: any)
			expect(path.Status).is("Success")
			expect(#state.Description.Floors.Ground.Obstacles[1]).is(5)
		end)

		test("markers and the radius are not description changes", function()
			local state = EditorState.new("NavMesh")
			expect(EditorState.Apply(state, { Type = "SetMarker", Which = "Goal", Position = vector.create(5, 0, 5) })).never_is_true()
			expect((state.Selection :: any).Which).is("Goal")
			expect(drag(state, 6, 6)).never_is_true()
			expect(state.Goal).is(vector.create(6, 0, 6))
			expect(EditorState.Apply(state, { Type = "SetAgentRadius", Radius = -1 })).never_is_true()
			expect(state.AgentRadius).is(0)
			EditorState.Apply(state, { Type = "Delete" })
			expect(state.Goal).never_exists()
		end)

		test("rejects unknown events, wrong-mode events and misshapen descriptions", function()
			local state = EditorState.new("NavMesh")
			expect(function()
				EditorState.Apply(state, { Type = "Explode" })
			end).fails_with('unknown event Type "Explode"')
			expect(function()
				EditorState.Apply(state, { Type = "CreateEdge", From = vector.zero, To = vector.one })
			end).fails_with("CreateEdge is only for CDT mode")
			expect(function()
				EditorState.Apply(state, { Type = "SetDescription", Description = { Coords = {} } })
			end).fails_with("a NavMesh description needs a Floors table")
			expect(function()
				EditorState.Apply(state, { Type = "CreateRing", Kind = "Walkable" })
			end).fails_with("CreateRing needs Position")
		end)
	end)

	describe("EditorState (CDT)", function()
		local function square()
			return EditorState.new(
				"CDT",
				ConstrainedDelaunay.Fixtures.ToInput(ConstrainedDelaunay.Fixtures.SquareWithHole)
			)
		end

		test("creates a ring of the requested group", function()
			local state = EditorState.new("CDT")
			EditorState.Apply(state, { Type = "CreateRing", Kind = "Obstacle", Position = vector.create(10, 0, 10) })
			local desc = state.Description
			expect(#desc.Coords).is(16)
			expect(same(desc.EdgeGroups, { 1, 1, 1, 1, 2, 2, 2, 2 })).is_true()
			expect(same({ table.unpack(desc.Edges, 9, 16) }, { 5, 6, 6, 7, 7, 8, 8, 5 })).is_true()
			expect(ConstrainedDelaunay.TriangleCount(ConstrainedDelaunay.Triangulate(desc)) > 0).is_true()
		end)

		test("dragging a point moves its x, y", function()
			local state = square()
			press(state, 10, 10)
			expect(drag(state, 12, 11)).is_true()
			expect(state.Description.Coords[5]).is(12)
			expect(state.Description.Coords[6]).is(11)
		end)

		test("deleting a ring point closes the ring through its neighbours", function()
			local state = square()
			press(state, 10, 0) -- point 2 of the outer ring 1 -> 2 -> 3 -> 4
			expect(EditorState.Apply(state, { Type = "Delete" })).is_true()
			local desc = state.Description
			expect(#desc.Coords // 2).is(7)
			expect(same({ table.unpack(desc.Edges, 1, 6) }, { 1, 2, 2, 3, 3, 1 })).is_true()
			expect(#desc.EdgeGroups).is(#desc.Edges // 2)
			expect(ConstrainedDelaunay.TriangleCount(ConstrainedDelaunay.Triangulate(desc)) > 0).is_true()
		end)

		test("inserting splits the edge leaving the selected point", function()
			local state = square()
			press(state, 0, 0)
			EditorState.Apply(state, { Type = "InsertVertex" })
			local desc = state.Description
			expect(desc.Coords[17]).is(5)
			expect(desc.Coords[18]).is(0)
			expect(desc.Edges[2]).is(9)
			expect(same({ desc.Edges[17], desc.Edges[18] }, { 9, 2 })).is_true()
			expect((state.Selection :: any).Index).is(9)
		end)

		test("an open constraint edge gets group 0 and writes out the default groups", function()
			local state =
				EditorState.new("CDT", { Coords = { 0, 0, 10, 0, 10, 10, 0, 10 }, Edges = { 1, 2, 2, 3, 3, 4, 4, 1 } })
			EditorState.Apply(
				state,
				{ Type = "CreateEdge", From = vector.create(2, 0, 2), To = vector.create(8, 0, 8) }
			)
			expect(same(state.Description.EdgeGroups, { 1, 1, 1, 1, 0 })).is_true()
			expect(ConstrainedDelaunay.TriangleCount(ConstrainedDelaunay.Triangulate(state.Description)) > 0).is_true()
			expect(function()
				EditorState.Apply(state, { Type = "CreateLink", From = vector.zero, To = vector.one })
			end).fails_with("CreateLink is only for NavMesh mode")
		end)
	end)
end

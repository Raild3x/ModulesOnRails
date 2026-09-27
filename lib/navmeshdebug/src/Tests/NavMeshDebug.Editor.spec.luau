-- Authors: Logan Hunt (Raildex)
-- September 27, 2026

return function(t: tiniest)
	local ConstrainedDelaunay = require("../../ConstrainedDelaunay")
	local NavMesh = require("../../NavMesh")
	local NavMeshEditor = require("../NavMeshEditor")
	local same = require("./Helpers/Same")

	local describe = t.describe
	local expect = t.expect
	local test = t.test

	local DOWN = vector.create(0, -1, 0)
	local BOWTIE = {
		Floors = {
			Ground = {
				Walkable = {
					{
						vector.create(0, 0, 0),
						vector.create(10, 0, 10),
						vector.create(10, 0, 0),
						vector.create(0, 0, 10),
					},
				},
			},
		},
	}

	local function open(mode: any, initial: any?)
		local folder = Instance.new("Folder")
		local editor = NavMeshEditor.new(folder, mode, initial) :: any
		return editor, folder
	end

	local function status(folder: Folder): string
		return (folder:FindFirstChild("Status", true) :: TextLabel).Text
	end

	describe("NavMeshEditor", function()
		test("opens on a fixture and draws its mesh", function()
			local editor, folder = open("NavMesh", NavMesh.Fixtures.ThreeFloorStairs.Desc)
			local root = folder:FindFirstChild("NavMeshEditor") :: Folder
			expect(root).exists()
			expect(root:FindFirstChild("DrawListRenderer")).exists()
			expect(editor._built).exists()
			expect(editor._error).never_exists()
			expect(string.find(status(folder), "NavMesh | radius 0", 1, true) ~= nil).is_true()
			expect(same(editor:GetDescription(), NavMesh.Fixtures.ThreeFloorStairs.Desc)).is_true()
			editor:Destroy()
			folder:Destroy()
		end)

		test("Changed fires a copy after an edit, and not after a selection", function()
			local editor, folder = open("NavMesh", NavMesh.Fixtures.ThreeFloorStairs.Desc)
			local fired = {}
			editor.Changed:Connect(function(desc)
				table.insert(fired, desc)
			end)
			editor:_apply { Type = "PointerDown", Origin = vector.create(0, 100, 0), Direction = DOWN }
			expect(#fired).is(0)
			editor:_apply { Type = "Drag", Origin = vector.create(-2, 100, -2), Direction = DOWN }
			expect(#fired).is(1)
			expect(fired[1].Floors.Ground.Walkable[1][1]).is(vector.create(-2, 0, -2))
			fired[1].Floors.Ground = nil
			expect(editor:GetDescription().Floors.Ground).exists()
			editor:Destroy()
			folder:Destroy()
		end)

		test("finds a path between the markers with the agent radius", function()
			local editor, folder = open("NavMesh", NavMesh.Fixtures.ThreeFloorStairs.Desc)
			editor:_apply { Type = "SetMarker", Which = "Start", Position = vector.create(2, 0, 2) }
			editor:_apply { Type = "SetMarker", Which = "Goal", Position = vector.create(36, 5, 18) }
			editor:_apply { Type = "SetAgentRadius", Radius = 0.5 }
			expect(editor._pathStatus).is("Success")
			expect(string.find(status(folder), "radius 0.5", 1, true) ~= nil).is_true()
			expect(string.find(status(folder), "path Success", 1, true) ~= nil).is_true()
			editor:Destroy()
			folder:Destroy()
		end)

		test("a build error keeps the last good mesh and shows the message", function()
			local editor, folder = open("NavMesh", NavMesh.Fixtures.ThreeFloorStairs.Desc)
			local good = editor._built
			expect(function()
				editor:_apply { Type = "SetDescription", Description = BOWTIE }
			end).never_fails()
			expect(editor._built).is(good)
			expect(string.find(editor._error, "NavMesh.Build", 1, true) ~= nil).is_true()
			expect(string.find(status(folder), "ERROR: NavMesh.Build", 1, true) ~= nil).is_true()
			editor:_apply { Type = "SetDescription", Description = NavMesh.Fixtures.Courtyard.Desc }
			expect(editor._error).never_exists()
			expect(editor._built ~= good).is_true()
			editor:Destroy()
			folder:Destroy()
		end)

		test("an event the state rejects is shown, not thrown", function()
			local editor, folder = open("NavMesh")
			expect(function()
				editor:_apply { Type = "CreateEdge", From = vector.zero, To = vector.one }
			end).never_fails()
			expect(string.find(status(folder), "CreateEdge is only for CDT mode", 1, true) ~= nil).is_true()
			editor:Destroy()
			folder:Destroy()
		end)

		test("edits a CDT triangulation", function()
			local input = ConstrainedDelaunay.Fixtures.ToInput(ConstrainedDelaunay.Fixtures.OverlappingObstacles)
			local editor, folder = open("CDT", input)
			expect(editor._built).exists()
			editor:_apply { Type = "CreateEdge", From = vector.create(14, 0, 14), To = vector.create(18, 0, 18) }
			expect(editor._error).never_exists()
			expect(#editor:GetDescription().Coords).is(#input.Coords + 4)
			editor:Destroy()
			folder:Destroy()
		end)

		test("ExportSource reads back with ImportSource", function()
			for _, scenario in NavMesh.Fixtures.All do
				local editor, folder = open("NavMesh", scenario.Desc)
				local imported = NavMeshEditor.ImportSource(editor:ExportSource())
				expect(same(imported, editor:GetDescription())).is_true()
				editor:Destroy()
				folder:Destroy()
			end
		end)

		test("keys make the events the control table documents", function()
			local editor, folder = open("NavMesh", NavMesh.Fixtures.ThreeFloorStairs.Desc)
			local p = vector.create(30, 0, 10)
			local keys = NavMeshEditor._Keys
			local function key(code: Enum.KeyCode): any
				return keys[code](editor, p)
			end
			expect(key(Enum.KeyCode.One).Kind).is("Walkable")
			expect(key(Enum.KeyCode.Two).Kind).is("Obstacle")
			expect(key(Enum.KeyCode.Three).Kind).is("Area")
			expect(key(Enum.KeyCode.Four).Type).is("CreateSeam")
			expect(key(Enum.KeyCode.Four).To).is(vector.create(30, 0, 14))
			expect(key(Enum.KeyCode.Five).Bidirectional).never_exists()
			expect(key(Enum.KeyCode.Six).Bidirectional).is(false)
			expect(key(Enum.KeyCode.V).Type).is("InsertVertex")
			expect(key(Enum.KeyCode.X).Type).is("Delete")
			expect(key(Enum.KeyCode.Delete).Type).is("Delete")
			expect(key(Enum.KeyCode.Z).Which).is("Start")
			expect(key(Enum.KeyCode.C).Which).is("Goal")
			expect(key(Enum.KeyCode.RightBracket).Radius).is(0.25)
			expect(key(Enum.KeyCode.LeftBracket).Radius).is(-0.25)
			for _, code in { Enum.KeyCode.One, Enum.KeyCode.Five, Enum.KeyCode.Z } do
				editor:_apply(key(code))
			end
			expect(editor._error).never_exists()
			expect(#editor:GetDescription().Links).is(1)
			expect(key(Enum.KeyCode.T)).never_exists()
			expect(editor._showTiles).never_is_true()
			expect(key(Enum.KeyCode.P)).never_exists()
			editor:Destroy()
			folder:Destroy()

			local cdt = open("CDT")
			expect(keys[Enum.KeyCode.Four](cdt, p).Type).is("CreateEdge")
			cdt:Destroy()
		end)

		test("rejects an initial description for the other mode", function()
			expect(function()
				NavMeshEditor.new(Instance.new("Folder"), "CDT", NavMesh.Fixtures.Courtyard.Desc)
			end).fails_with("a CDT description needs a Coords table")
		end)

		test("Destroy removes the drawing and the GUI and disconnects Changed", function()
			local editor, folder = open("NavMesh")
			local connection = editor.Changed:Connect(function() end)
			editor:Destroy()
			expect(folder:FindFirstChild("NavMeshEditor")).never_exists()
			expect(#folder:GetDescendants()).is(0)
			expect(connection.Connected).never_is_true()
			folder:Destroy()
		end)
	end)
end

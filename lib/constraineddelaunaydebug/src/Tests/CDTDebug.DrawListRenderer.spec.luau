-- Authors: Logan Hunt (Raildex)
-- September 25, 2026

return function(t: tiniest)
	local DrawListRenderer = require("../DrawListRenderer")

	local describe = t.describe
	local expect = t.expect
	local test = t.test

	-- The first triangle winds clockwise seen from above, so the fill has to flip it.
	local LIST = {
		{ Kind = "Tri", Points = { 0, 0, 0, 10, 0, 0, 0, 0, 10 }, Color = "#43a047", Layer = "Triangles" },
		{ Kind = "Tri", Points = { 10, 0, 0, 10, 0, 10, 0, 0, 10 }, Color = "#43a047", Layer = "Triangles" },
		{ Kind = "Tri", Points = { 20, 2, 0, 30, 2, 0, 20, 2, 10 }, Color = "#1e88e5", Layer = "Triangles" },
		{ Kind = "Line", Points = { 0, 0, 0, 10, 0, 0 }, Color = "#c62828", Layer = "Constraints" },
		{ Kind = "Label", Points = { 5, 0, 5 }, Color = "#000000", Layer = "Path", Text = "goal" },
	}

	local function container(folder: Folder): Instance
		return folder:FindFirstChild("DrawListRenderer") :: Instance
	end

	local function childrenOf(folder: Folder, className: string): { Instance }
		local out = {}
		for _, child in container(folder):GetChildren() do
			if child:IsA(className) then
				table.insert(out, child)
			end
		end
		return out
	end

	-- Waits (bounded) for the fills still being created.
	local function settle(renderer: any)
		local deadline = os.clock() + 10
		while renderer._pending > 0 and os.clock() < deadline do
			task.wait()
		end
	end

	describe("DrawListRenderer", function()
		test("creates one adornment per layer and colour", function()
			local folder = Instance.new("Folder")
			local renderer = DrawListRenderer.new(folder)
			renderer:Draw(LIST :: any)
			expect(#childrenOf(folder, "WireframeHandleAdornment")).is(4)
			renderer:Destroy()
			folder:Destroy()
		end)

		test("draws points, circles, arrows and labels", function()
			local folder = Instance.new("Folder")
			local renderer = DrawListRenderer.new(folder)
			renderer:Draw({
				{ Kind = "Point", Points = { 1, 0, 1 }, Color = "#000000", Layer = "Vertices" },
				{ Kind = "Circle", Points = { 1, 0, 1 }, Radius = 2, Color = "#e65100", Layer = "Path" },
				{ Kind = "Arrow", Points = { 0, 0, 0, 4, 0, 4 }, Color = "#e65100", Layer = "Path" },
				{ Kind = "Label", Points = { 1, 0, 1 }, Color = "#000000", Layer = "Path", Text = "start" },
			} :: any)
			expect(#childrenOf(folder, "WireframeHandleAdornment")).is(3)
			expect(#childrenOf(folder, "MeshPart")).is(0)
			renderer:Destroy()
			folder:Destroy()
		end)

		test("never yields", function()
			local folder = Instance.new("Folder")
			local renderer = DrawListRenderer.new(folder)
			local co = coroutine.create(function()
				renderer:Draw(LIST :: any)
			end)
			coroutine.resume(co)
			expect(coroutine.status(co)).is("dead")
			settle(renderer)
			renderer:Destroy()
			folder:Destroy()
		end)

		test("fills triangles with one MeshPart per layer and colour, a frame later", function()
			local folder = Instance.new("Folder")
			local renderer = DrawListRenderer.new(folder)
			renderer:Draw(LIST :: any)
			settle(renderer)
			local green = container(folder):FindFirstChild("Fill Triangles|#43a047") :: MeshPart
			local blue = container(folder):FindFirstChild("Fill Triangles|#1e88e5") :: MeshPart
			expect(#childrenOf(folder, "MeshPart")).is(2)
			-- Raised by the default 0.1-stud lift.
			expect(green.Position).is(Vector3.new(5, 0.1, 5))
			expect(blue.Position).is(Vector3.new(25, 2.1, 5))
			expect(green.Color).is(Color3.fromHex("#43a047"))
			expect(green.Anchored).is_true()
			expect(green.CanQuery).never_is_true()
			expect(green.CanCollide).never_is_true()
			renderer:Destroy()
			folder:Destroy()
		end)

		test("fill triangles face up", function()
			local folder = Instance.new("Folder")
			local renderer = DrawListRenderer.new(folder)
			renderer:Draw(LIST :: any)
			local faces = 0
			for _, mesh: EditableMesh in (renderer :: any)._meshes do
				for _, face in mesh:GetFaces() do
					local v = mesh:GetFaceVertices(face)
					local a, b, c = mesh:GetPosition(v[1]), mesh:GetPosition(v[2]), mesh:GetPosition(v[3])
					expect((b - a):Cross(c - a).Y > 0).is_true()
					faces += 1
				end
			end
			expect(faces).is(3)
			settle(renderer)
			renderer:Destroy()
			folder:Destroy()
		end)

		test("splits a fill into meshes of 20,000 triangles", function()
			local folder = Instance.new("Folder")
			local renderer = DrawListRenderer.new(folder)
			local list = table.create(20001)
			for i = 1, 20001 do
				local x = i % 200
				local z = i // 200
				list[i] = {
					Kind = "Tri",
					Points = { x, 0, z, x, 0, z + 1, x + 1, 0, z },
					Color = "#43a047",
					Layer = "Triangles",
				}
			end
			renderer:Draw(list :: any)
			local meshes = (renderer :: any)._meshes
			expect(#meshes).is(2)
			expect(#meshes[1]:GetFaces()).is(20000)
			expect(#meshes[2]:GetFaces()).is(1)
			settle(renderer)
			expect(#childrenOf(folder, "MeshPart")).is(2)
			renderer:Destroy()
			folder:Destroy()
		end)

		test("replaces the previous drawing, discarding fills still being created", function()
			local folder = Instance.new("Folder")
			local renderer = DrawListRenderer.new(folder)
			renderer:Draw(LIST :: any)
			renderer:Draw({ LIST[3] } :: any)
			settle(renderer)
			local fills = childrenOf(folder, "MeshPart")
			expect(#fills).is(1)
			expect(fills[1].Name).is("Fill Triangles|#1e88e5")
			renderer:Draw({ LIST[4] } :: any)
			expect(#childrenOf(folder, "MeshPart")).is(0)
			renderer:Destroy()
			folder:Destroy()
		end)

		test("keeps the previous fills on screen until the new ones arrive (no blink on redraw)", function()
			local folder = Instance.new("Folder")
			local renderer = DrawListRenderer.new(folder)
			renderer:Draw(LIST :: any)
			settle(renderer)
			local before = childrenOf(folder, "MeshPart")
			expect(#before).is(2)
			renderer:Draw(LIST :: any)
			-- The new fills are a frame away; the old ones still show.
			expect(#childrenOf(folder, "MeshPart")).is(2)
			expect(before[1].Parent ~= nil).is_true()
			settle(renderer)
			local after = childrenOf(folder, "MeshPart")
			expect(#after).is(2)
			expect(before[1].Parent == nil).is_true()
			renderer:Destroy()
			folder:Destroy()
		end)

		test("hides a layer", function()
			local folder = Instance.new("Folder")
			local renderer = DrawListRenderer.new(folder)
			renderer:Draw(LIST :: any)
			renderer:SetLayerVisible("Triangles", false)
			settle(renderer)
			local adornment = container(folder):FindFirstChild("Triangles|#43a047") :: WireframeHandleAdornment
			local fill = container(folder):FindFirstChild("Fill Triangles|#43a047") :: MeshPart
			local line = container(folder):FindFirstChild("Constraints|#c62828") :: WireframeHandleAdornment
			expect(adornment.Visible).never_is_true()
			expect(fill.Transparency).is(1)
			expect(line.Visible).is_true()
			renderer:SetLayerVisible("Triangles", true)
			expect(adornment.Visible).is_true()
			expect(fill.Transparency < 1).is_true()
			renderer:Destroy()
			folder:Destroy()
		end)

		test("lines draw over the world by default; AlwaysOnTop = false and Lift are honoured", function()
			local folder = Instance.new("Folder")
			local renderer = DrawListRenderer.new(folder)
			renderer:Draw({ LIST[4] } :: any)
			local line = container(folder):FindFirstChild("Constraints|#c62828") :: WireframeHandleAdornment
			expect(line.AlwaysOnTop).is_true()
			renderer:Destroy()

			renderer = DrawListRenderer.new(folder, { AlwaysOnTop = false, Lift = 0 })
			renderer:Draw(LIST :: any)
			settle(renderer)
			line = container(folder):FindFirstChild("Constraints|#c62828") :: WireframeHandleAdornment
			local green = container(folder):FindFirstChild("Fill Triangles|#43a047") :: MeshPart
			expect(line.AlwaysOnTop).never_is_true()
			expect(green.Position).is(Vector3.new(5, 0, 5))
			renderer:Destroy()
			folder:Destroy()
		end)

		test("errors on an unknown Kind", function()
			local folder = Instance.new("Folder")
			local renderer = DrawListRenderer.new(folder)
			expect(function()
				renderer:Draw({ { Kind = "Hexagon", Points = { 0, 0, 0 }, Color = "#000000", Layer = "X" } } :: any)
			end).fails()
			renderer:Destroy()
			folder:Destroy()
		end)
	end)
end

-- Authors: Logan Hunt (Raildex)
-- September 25, 2026

return function(t: tiniest)
	local DrawListRenderer = require("../DrawListRenderer")

	local describe = t.describe
	local expect = t.expect
	local test = t.test

	local LIST = {
		{ Kind = "Tri", Points = { 0, 0, 0, 10, 0, 0, 0, 0, 10 }, Color = "#43a047", Layer = "Triangles" },
		{ Kind = "Line", Points = { 0, 0, 0, 10, 0, 0 }, Color = "#c62828", Layer = "Constraints" },
		{ Kind = "Label", Points = { 5, 0, 5 }, Color = "#000000", Layer = "Path", Text = "goal" },
	}

	local function container(folder: Folder): Instance
		return folder:FindFirstChild("DrawListRenderer") :: Instance
	end

	describe("DrawListRenderer", function()
		test("creates one adornment per layer and colour", function()
			local folder = Instance.new("Folder")
			local renderer = DrawListRenderer.new(folder)
			renderer:Draw(LIST :: any)
			expect(#container(folder):GetChildren()).is(3)
			renderer:Destroy()
			folder:Destroy()
		end)

		test("hides a layer", function()
			local folder = Instance.new("Folder")
			local renderer = DrawListRenderer.new(folder)
			renderer:Draw(LIST :: any)
			renderer:SetLayerVisible("Triangles", false)
			local adornment = container(folder):FindFirstChild("Triangles|#43a047") :: WireframeHandleAdornment
			expect(adornment.Visible).never_is_true()
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

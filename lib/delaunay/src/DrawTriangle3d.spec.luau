--!strict
return function(t: tiniest)
	local DrawTriangle3d = require(script.Parent.DrawTriangle3d)

	local describe = t.describe
	local expect = t.expect
	local test = t.test

	local PART_LIMIT = 2048

	local function countWedgeParts(model: Model): { WedgePart }
		local wedges: { WedgePart } = {}
		for _, descendant in ipairs(model:GetDescendants()) do
			if descendant:IsA("WedgePart") then
				table.insert(wedges, descendant)
			end
		end
		return wedges
	end

	describe("DrawTriangle3d", function()
		test("subdivides triangles larger than the Roblox part limit", function()
			local parentFolder = Instance.new("Folder")
			parentFolder.Name = "DrawTriangle3dSpec"
			parentFolder.Parent = workspace

			local createConfig = {
				Parent = parentFolder,
				Anchored = true,
				Thickness = 0.2,
			} :: any

			local model = DrawTriangle3d.create({
				Vector3.new(0, 0, 0),
				Vector3.new(4096, 0, 0),
				Vector3.new(0, 4096, 0),
			}, createConfig)

			local wedges = countWedgeParts(model)
			expect(model:GetAttribute("DrawTriangle3dComposite") == true).is(true)
			expect(#wedges > 2).is(true)

			for _, wedge in ipairs(wedges) do
				expect(wedge.Size.X <= PART_LIMIT).is(true)
				expect(wedge.Size.Y <= PART_LIMIT).is(true)
				expect(wedge.Size.Z <= PART_LIMIT).is(true)
			end

			parentFolder:Destroy()
		end)

		test("render rebuilds an existing model when the triangle grows too large", function()
			local parentFolder = Instance.new("Folder")
			parentFolder.Name = "DrawTriangle3dSpecRender"
			parentFolder.Parent = workspace

			local createConfig = {
				Parent = parentFolder,
				Anchored = true,
				Thickness = 0.2,
			} :: any

			local model = DrawTriangle3d.create({
				Vector3.new(0, 0, 0),
				Vector3.new(5, 0, 0),
				Vector3.new(0, 5, 0),
			}, createConfig)

			DrawTriangle3d.render({
				Vector3.new(0, 0, 0),
				Vector3.new(4096, 0, 0),
				Vector3.new(0, 4096, 0),
			}, model)

			local wedges = countWedgeParts(model)
			expect(model:GetAttribute("DrawTriangle3dComposite") == true).is(true)
			expect(#wedges > 2).is(true)

			for _, wedge in ipairs(wedges) do
				expect(wedge.Size.X <= PART_LIMIT).is(true)
				expect(wedge.Size.Y <= PART_LIMIT).is(true)
				expect(wedge.Size.Z <= PART_LIMIT).is(true)
			end

			parentFolder:Destroy()
		end)
	end)
end

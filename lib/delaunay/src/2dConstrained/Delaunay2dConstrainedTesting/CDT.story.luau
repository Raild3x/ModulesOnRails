--!strict
local RunService = game:GetService("RunService")
local NavMesh = require(script.Parent.Parent.NavMesh)
local ConstrainedDelaunayTriangulation = require(script.Parent.Parent.ConstrainedDelaunayTriangulation)
local DrawTriangle3d = require(script.Parent.Parent.Parent.DrawTriangle3d)

local function partToPoint(part: BasePart): Vector2
	return Vector2.new(part.Position.Z, part.Position.X)
end

return function()
	local navmesh = NavMesh.new {
		-- MaxTriangleArea = 350,
	}

	local testPoints = Instance.new("Folder")
	testPoints.Name = "CDT_TestPoints"
	testPoints.Parent = workspace

	for i = 1, 10 do
		local part = Instance.new("Part")
		part.Name = "Point"
		part.Size = Vector3.new(1, 1, 1)
		part.Position = Vector3.new(math.random() * 100, 0, math.random() * 100)
		part.Anchored = true
		part.CanCollide = false
		part.Parent = testPoints
	end

	local function Generate()
		local points = {}
		local polygons = {}

		for i, part in testPoints:GetChildren() do
			if part.Name == "Point" then
				navmesh:AddPoint(partToPoint(part), part)
				table.insert(points, partToPoint(part))
			else
				table.insert(polygons, part)
			end
		end

		navmesh:ClearAllHoles()

		for _, containerInstance in polygons do
			local polygonParts: { BasePart } = containerInstance:GetChildren()
			table.sort(polygonParts, function(a: BasePart, b: BasePart)
				return a.Name < b.Name
			end)

			local polygon: { Vector2 } = table.create(#polygonParts) :: any
			for i, part in polygonParts do
				polygon[i] = partToPoint(part)
			end

			navmesh:AddHole(polygon, containerInstance)
		end

		-- navmesh:GetTriangulation()
		navmesh:Render {
			RenderHeight = 48,
		}
	end

	local running = true
	task.defer(function()
		while running do
			Generate()
			task.wait()
			task.wait()
		end
	end)

	-- ── Cleanup ───────────────────────────────────────────────────────────────
	return function()
		running = false
		navmesh:Destroy()
		testPoints:Destroy()
	end
end

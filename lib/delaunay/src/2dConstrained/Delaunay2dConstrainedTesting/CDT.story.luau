--!strict
local RunService = game:GetService("RunService")
local NavMesh = require(script.Parent.Parent.NavMesh)
local ConstrainedDelaunayTriangulation = require(script.Parent.Parent.ConstrainedDelaunayTriangulation)
local DrawTriangle3d = require(script.Parent.Parent.Parent.DrawTriangle3d)
local DrawUtil = require(script.Parent.Parent.Utils.DrawUtil)

local function partToPoint(part: BasePart): Vector2
	return Vector2.new(part.Position.Z, part.Position.X)
end

return function()
	print("=== Generating Constrained Delaunay triangulation ===")
	local navmesh = NavMesh.new {
		-- MaxTriangleArea = 350,
	}

	local testPoints = Instance.new("Folder")
	testPoints.Name = "CDT_TestPoints"
	testPoints.Parent = workspace

	local initialPoints = {}
	for i = 1, 10 do
		local part = Instance.new("Part")
		part.Name = "Point"
		part.Size = Vector3.new(1, 1, 1)
		part.Position = Vector3.new(math.floor(math.random() * 100), 0, math.floor(math.random() * 100))
		part.Shape = Enum.PartType.Ball
		part.Material = Enum.Material.Neon
		part.Color = Color3.fromRGB(255, 100, 50)
		part.Anchored = true
		part.CanCollide = false
		part.Parent = testPoints
		table.insert(initialPoints, partToPoint(part))
	end
	print("STORY TESTING POINTS:", initialPoints)

	local Generation = 0
	local function Generate()
		Generation += 1
		print("=== Regenerating triangulation - Generation", Generation, "===")
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
			RenderHeight = 0,
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
		DrawUtil.ClearDebugDrawings()
	end
end

--[[
  [string "ReplicatedStorage.src.delaunay.src.2dConstrained.InternalClasses.DelaunayTriangleSet"]:614: Unable to find a triangle that contains the point (0.336344, 0.000000), starting at triangle 3. Are you generating very small triangles? - DelaunayTriangleSet:614
  Stack Begin
  Script 'ReplicatedStorage.src.delaunay.src.2dConstrained.InternalClasses.DelaunayTriangleSet', Line 614 - function FindTriangleThatContainsPoint - DelaunayTriangleSet:614
  Script 'ReplicatedStorage.src.delaunay.src.2dConstrained.ConstrainedDelaunayTriangulation', Line 316 - function _AddPointToTriangulation - ConstrainedDelaunayTriangulation:316
  Script 'ReplicatedStorage.src.delaunay.src.2dConstrained.ConstrainedDelaunayTriangulation', Line 237 - ConstrainedDelaunayTriangulation:237
  Script 'ReplicatedStorage.src.delaunay.src.2dConstrained.InternalClasses.PointBinGrid', Line 130 - function ForEachPoint - PointBinGrid:130
  Script 'ReplicatedStorage.src.delaunay.src.2dConstrained.ConstrainedDelaunayTriangulation', Line 236 - function Triangulate - ConstrainedDelaunayTriangulation:236
  Script 'ReplicatedStorage.src.delaunay.src.2dConstrained.NavMesh', Line 390 - function _Triangulate - NavMesh:390
  Script 'ReplicatedStorage.src.delaunay.src.2dConstrained.NavMesh', Line 400 - function GetTriangulation - NavMesh:400
  Script 'ReplicatedStorage.src.delaunay.src.2dConstrained.NavMesh', Line 616 - function Render - NavMesh:616
  Script 'ReplicatedStorage.src.delaunay.src.2dConstrained.Delaunay2dConstrainedTesting.CDT.story', Line 63 - function Generate - CDT.story:63
  Script 'ReplicatedStorage.src.delaunay.src.2dConstrained.Delaunay2dConstrainedTesting.CDT.story', Line 71 - CDT.story:71
  Stack End
]]

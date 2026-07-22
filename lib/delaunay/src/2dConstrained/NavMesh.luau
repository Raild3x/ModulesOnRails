--!strict
--!native
-- April 09, 2025
--[=[
	@class NavMesh
]=]

--// Imports //--
local Triangle2dUtil = require("./Utils/Triangle2dUtil")
local DelaunayUtil = require("./Utils/DelaunayUtil")
local PolygonUtil = require("./Utils/PolygonUtil")
local GrahamScan = require("./Utils/GrahamScan")
local DrawUtil = require("./Utils/DrawUtil")
local DrawTriangle = require("../DrawTriangle3d")

local DelaunayTriangle = require("./InternalClasses/DelaunayTriangle")

local ConstrainedDelaunayTriangulation = require("./ConstrainedDelaunayTriangulation")
local Janitor = require("../../Janitor")
local Signal = require("../../Signal")

type ConstrainedDelaunayTriangulation = ConstrainedDelaunayTriangulation.ConstrainedDelaunayTriangulation
type DelaunayTriangleSet = ConstrainedDelaunayTriangulation.DelaunayTriangleSet
type DelaunayTriangle = DelaunayTriangle.DelaunayTriangle

type Vector = Vector2 | Vector3
type Polygon = { Vector2 }
type Triangle = { Vector2 }

-- User can provide whatever identifier they want for points and polygons, it will be used as the key in the PointMap and PolygonHoles respectively
type PointId = any
type PolygonId = any

local EPSILON = 0.01 -- Small value to check for equality

local function fuzzyEq(p1: Vector2, p2: Vector2, epsilon: number?): boolean
	epsilon = epsilon or EPSILON
	return math.abs(p1.X - p2.X) < epsilon and math.abs(p1.Y - p2.Y) < epsilon
end

local function Vector2ToVector3(v: Vector2, height: number?): Vector3
	return Vector3.new(v.Y, height or 0, v.X)
end

local function drawLine(p1: Vector3, p2: Vector3, color: Color3?): Part
	local line = Instance.new("Part")
	line.Name = "Line"
	line.Transparency = 0.2
	line.Size = Vector3.new(0.5, 0.5, (p2 - p1).Magnitude)
	line.CFrame = CFrame.new(p1:Lerp(p2, 0.5), p2)
	line.Anchored = true
	line.CastShadow = false
	line.CanCollide = false
	line.CanTouch = false
	line.CanQuery = false
	line.Material = Enum.Material.Neon
	line.Color = color or BrickColor.White().Color
	line.Locked = true
	return line
end

local function reversePoints(points: { Vector2 }): { Vector2 }
	local reversed = table.create(#points) :: { Vector2 }
	for i = 1, #points do
		reversed[i] = points[#points - i + 1]
	end
	return reversed
end

local function swapRemoveFirstValue<T>(array: { T }, value: T): number?
	for i = 1, #array do
		if array[i] == value then
			array[i] = array[#array]
			array[#array] = nil
			return i
		end
	end
	return nil
end

local function drawPolygonOutline(config: {
	Polygon: Polygon,
	Color: Color3?,
	Height: number?,
	Model: Model?,
}): Model
	local polygon = config.Polygon
	local model = config.Model
	if not model then
		model = Instance.new("Model")
		model.Name = "PolygonOutline"
	end

	for i = 1, #polygon do
		local p1 = Vector2ToVector3(polygon[i], config.Height)
		local p2 = Vector2ToVector3(polygon[i % #polygon + 1], config.Height)
		local line = DrawUtil.DrawLine(p1, p2, config.Color)
		line.Parent = model
	end

	return model :: Model
end

--------------------------------------------------------------------------------
--// Class Types //--
--------------------------------------------------------------------------------

type NavSignal<T...> = Signal.ClassicSignal<T...>

export type NavMesh = {
	-- Signals
	PointAdded: NavSignal<Vector2, PointId>,
	PointRemoved: NavSignal<Vector2, PointId>,
	HoleAdded: NavSignal<Polygon>,
	HoleRemoved: NavSignal<Polygon>,
	Dirtied: NavSignal<>,

	Destroy: (self: NavMesh) -> (),

	AddPoint: (self: NavMesh, point: Vector, customId: PointId?) -> PointId,
	GetPoints: (self: NavMesh) -> { Vector2 },
	GetPointCount: (self: NavMesh) -> number,

	RemovePointById: (self: NavMesh, pointId: PointId) -> boolean,
	AddHole: (self: NavMesh, holePolygon: Polygon, customId: PolygonId?) -> PolygonId,
	RemoveHole: (self: NavMesh, holePolygon: Polygon, compareContents: boolean?) -> Polygon?,
	ClearAllHoles: (self: NavMesh) -> (),
	GetMergedHoles: (self: NavMesh) -> { Polygon },
	GetTriangulation: (self: NavMesh) -> { Triangle },
}

type NavMeshInternal = {
	PointMap: { [PointId]: Vector2 },
	PolygonHoles: { Polygon },
	MergedPolygonHoles: { Polygon },
	Triangulator: ConstrainedDelaunayTriangulation,
	_Janitor: Janitor.Janitor,
	_CachedTriangles: { Triangle }?,
	_TriangulationDirty: boolean,
	_HolesDirty: boolean,
	_PointIdCounter: number,
	_TesselationSize: number?,
	_Triangulate: (self: NavMeshInternal) -> (),
} & NavMesh

--------------------------------------------------------------------------------
--// CLASS //--
--------------------------------------------------------------------------------

local NavMesh = {}
NavMesh.ClassName = "NavMesh"
NavMesh.__index = NavMesh

function NavMesh.new(config: {
	MaxTriangleArea: number?,
}?): NavMesh
	local cfg = config or {} :: any
	local self = setmetatable({
		_Janitor = Janitor.new(),
		_TriangulationDirty = true,
		_HolesDirty = true,
		_PointIdCounter = 0,
		_TesselationSize = cfg.MaxTriangleArea,
		PointMap = {} :: { [string]: Vector2 },
		PolygonHoles = {} :: { Polygon },
		MergedPolygonHoles = {} :: { Polygon },
		Triangulator = ConstrainedDelaunayTriangulation.new(),
		PointAdded = Signal.new() :: NavSignal<Vector2, PointId>,
		PointRemoved = Signal.new() :: NavSignal<Vector2, PointId>,
		HoleAdded = Signal.new() :: NavSignal<Polygon>,
		HoleRemoved = Signal.new() :: NavSignal<Polygon>,
		Dirtied = Signal.new() :: NavSignal<>,
	}, NavMesh) :: any

	return self :: NavMesh
end

function NavMesh.Destroy(self: NavMeshInternal)
	self.PointAdded:Destroy()
	self.PointRemoved:Destroy()
	self.HoleAdded:Destroy()
	self.HoleRemoved:Destroy()
	self.Dirtied:Destroy()
	self._Janitor:Destroy()
end

--[=[
	Adds a point to the NavMesh. If a customId is provided, it will be used as the key in the PointMap. 
	Otherwise, a new id will be generated. If you provide an id that is already associated with a point,
	then the point at that id will be overwritten.
]=]
function NavMesh.AddPoint(self: NavMeshInternal, point: Vector, customId: PointId?): PointId
	if typeof(point) == "Vector3" then
		point = Vector2.new(point.Z, point.X)
	end
	assert(typeof(point) == "Vector2", "Given point must be a Vector2")

	-- TODO: Add fuzzyEq comparison to avoid duplicates
	-- for id, p: Vector2 in self.PointMap do
	-- 	if fuzzyEq(p, point) then
	-- 		warn("Point already exists in NavMesh:", point)
	-- 		return id -- Point already exists
	-- 	end
	-- end

	local pointId = customId
	if not pointId then
		self._PointIdCounter += 1
		pointId = tostring(self._PointIdCounter)
	end

	-- Dont do anything if the point is the same
	if self.PointMap[pointId] and fuzzyEq(self.PointMap[pointId], point) then
		return pointId
	end

	if self.PointMap[pointId] then
		print("Updating point with id:", pointId, "to new point:", point)
	end
	self.PointMap[pointId] = point

	self._TriangulationDirty = true
	self.PointAdded:Fire(point, pointId)
	self.Dirtied:Fire()

	return pointId
end

--[=[
	
]=]
function NavMesh.RemovePointById(self: NavMeshInternal, pointId: PointId): boolean
	if not self.PointMap[pointId] then
		return false -- Point with the given ID does not exist
	end

	local point = self.PointMap[pointId]
	self._TriangulationDirty = true
	self.PointMap[pointId] = nil
	self.PointRemoved:Fire(point, pointId)
	self.Dirtied:Fire()

	return true
end

-- --[=[

-- ]=]
-- function NavMesh:RemovePointByVector(point: Vector2 | Vector3)
-- 	if typeof(point) == "Vector3" then
-- 		point = Vector2.new(point.Z, point.X)
-- 	end
-- 	assert(typeof(point) == "Vector2", "Given point must be a Vector2")

-- 	for i, p: Vector2 in ipairs(self.Points) do
-- 		if fuzzyEq(p, point) then
-- 			self._IsDirty = true
-- 			RailUtil.Table.SwapRemove(self.Points, i)
-- 			self:FireSignal("PointRemoved", point)
-- 			self:FireSignal("Dirtied")
-- 			return p
-- 		end
-- 	end
-- 	return nil
-- end

--[=[
	
]=]
function NavMesh.AddHole(self: NavMeshInternal, holePolygon: Polygon, customId: PolygonId?): PolygonId
	local polygonId = customId

	local hullOutline = reversePoints(GrahamScan(self:GetPoints()))
	for _, point in holePolygon do
		if not PolygonUtil.IsPointInPolygon(point, hullOutline) then
			warn("Cannot add hole, polygon outside of the mesh bounds")
			-- DrawUtil.DrawPoint(point, Color3.fromRGB(255, 0, 0), 55).Parent = workspace
			-- drawPolygonOutline({
			-- 	Polygon = hullOutline,
			-- 	Color = Color3.fromRGB(0, 255, 0),
			-- 	Height = 55,
			-- }).Parent = workspace
			-- drawPolygonOutline({
			-- 	Polygon = holePolygon,
			-- 	Color = Color3.fromRGB(255, 0, 0),
			-- 	Height = 55,
			-- }).Parent = workspace
			-- task.wait(2)
			return polygonId
		end
	end

	if PolygonUtil.IsComplex(holePolygon) then
		warn("Cannot add complex polygon as a hole")
		-- drawPolygonOutline({
		-- 	Polygon = holePolygon,
		-- 	Color = Color3.fromRGB(255, 0, 0),
		-- 	Height = 55,
		-- }).Parent = workspace
		-- task.wait(2)
		return polygonId
	end

	self._HolesDirty = true
	self._TriangulationDirty = true

	table.insert(self.PolygonHoles, holePolygon)
	self.HoleAdded:Fire(holePolygon)
	self.Dirtied:Fire()

	return polygonId
end

--[=[
	@param holePolygon -- The polygon to remove from the holes
	@param compareContents -- If true, the contents of the polygon will be compared to find a match. Otherwise, the reference will be used.
]=]
function NavMesh.RemoveHole(self: NavMeshInternal, holePolygon: Polygon, compareContents: boolean?): Polygon?
	if compareContents then
		error("compareContents is not supported yet")
	end
	local idx = swapRemoveFirstValue(self.PolygonHoles, holePolygon)
	if idx then
		self._HolesDirty = true
		self._TriangulationDirty = true
		self.HoleRemoved:Fire(holePolygon)
		self.Dirtied:Fire()
		return holePolygon
	end
	return nil
end

--[=[
	
]=]
function NavMesh.ClearAllHoles(self: NavMeshInternal)
	if #self.PolygonHoles == 0 then
		return -- No holes to clear
	end

	for i = #self.PolygonHoles, 1, -1 do
		local polygon = self.PolygonHoles[i]
		self.PolygonHoles[i] = nil
		self._HolesDirty = true
		self._TriangulationDirty = true
		self.HoleRemoved:Fire(polygon)
	end
	self.Dirtied:Fire()
end

--[=[
	
]=]
function NavMesh.GetMergedHoles(self: NavMeshInternal): { Polygon }
	if self._HolesDirty then
		self.MergedPolygonHoles = PolygonUtil.MassUnion(self.PolygonHoles)
		self._HolesDirty = false
	end
	return self.MergedPolygonHoles
end

--[=[
	
]=]
function NavMesh.GetPoints(self: NavMeshInternal): { Vector2 }
	local points = {}
	for _, point: Vector2 in pairs(self.PointMap) do
		table.insert(points, point)
	end
	return points
end

--[=[
	
]=]
function NavMesh.GetPointCount(self: NavMeshInternal): number
	local count = 0
	for _ in pairs(self.PointMap) do
		count += 1
	end
	return count
end

--[=[
	
]=]
function NavMesh._Triangulate(self: NavMeshInternal)
	local polygonHoles = self:GetMergedHoles()
	if self._TriangulationDirty then
		self.Triangulator:Triangulate(self:GetPoints(), self._TesselationSize, polygonHoles)
		self._TriangulationDirty = false
		self._CachedTriangles = nil
	end
end

--[=[
	
]=]
function NavMesh.GetTriangulation(self: NavMeshInternal): { Triangle }
	self:_Triangulate()
	if not self._CachedTriangles then
		self._CachedTriangles = self.Triangulator:GetTrianglesDiscardingHoles()
	end
	return self._CachedTriangles :: { Triangle }
end

--[=[
	
]=]
function NavMesh.IsPointOnMesh(self: NavMeshInternal, point: Vector, excludeHoles: boolean?): boolean
	if typeof(point) == "Vector3" then
		point = Vector2.new(point.Z, point.X)
	end
	assert(typeof(point) == "Vector2", "Given point must be a Vector2")

	self:_Triangulate()
	if #self:GetPoints() == 0 then
		return false -- No points in the mesh
	end

	local outlinePolygon = self.Triangulator:GetOutlinePolygon()
	local isPointInMeshBounds = DelaunayUtil.IsPointInPolygon(point, outlinePolygon)
	if not isPointInMeshBounds then
		return false -- Point is outside the mesh bounds
	end

	if #self.MergedPolygonHoles == 0 or excludeHoles then
		return true -- No holes, point is inside the mesh bounds
	end

	for _, holePolygon: Polygon in ipairs(self.MergedPolygonHoles) do
		if DelaunayUtil.IsPointInPolygon(point, holePolygon) then
			return false -- Point is inside a hole
		end
	end

	return false
end

--[=[
	
]=]

type PathfindingResult = {
	TriangleIndexs: { number }, -- The indices of the triangles in the triangulation
}
function NavMesh._Astar(self: NavMeshInternal, start: Vector, goal: Vector, config: {}): PathfindingResult?
	local triangulator = self.Triangulator :: ConstrainedDelaunayTriangulation
	local triangleSet = triangulator.TriangleSet :: DelaunayTriangleSet

	local startTriangle: number? = triangleSet:FindTriangleThatContainsPoint(start)
	local goalTriangle: number? = triangleSet:FindTriangleThatContainsPoint(goal)

	-- TODO: Add partial path support
	if not startTriangle then
		warn("Start point is not in the mesh")
		return nil
	end

	if not goalTriangle then
		warn("Goal point is not in the mesh")
		return nil
	end

	local goalPoint: Vector2 = goal :: Vector2

	local centroidCache = {} :: { [number]: Vector2 }
	local function getCentroid(index: number): Vector2
		if centroidCache[index] then
			return centroidCache[index]
		end
		local trianglePoints: { Vector2 } = triangleSet:GetTrianglePoints(index)
		local centroid = Triangle2dUtil.GetCentroid(trianglePoints)
		centroidCache[index] = centroid
		return centroid
	end

	local function getDistance(tri1: number, tri2: number): number
		local centroid1 = getCentroid(tri1)
		local centroid2 = getCentroid(tri2)
		return (centroid1 - centroid2).Magnitude
	end

	local function getDistToGoal(triIndex: number)
		local trianglePoints: { Vector2 } = triangleSet:GetTrianglePoints(triIndex)
		local closestPoint = Triangle2dUtil.GetClosestPointOnTriangleEdges(goalPoint, trianglePoints)
		return (closestPoint - goalPoint).Magnitude
	end

	-- Priority queue for A* search
	local openSet = { [startTriangle] = true }
	local cameFrom = {} :: { [number]: number }

	-- Cost from start to a triangle
	local gScore = { [startTriangle] = 0 }
	-- Estimated total cost (gScore + heuristic)
	local fScore = { [startTriangle] = getDistToGoal(startTriangle) }

	while next(openSet) do
		-- Find the triangle in openSet with the lowest fScore
		local current: number
		local lowestFScore = math.huge
		for triangle, _ in pairs(openSet) do
			if fScore[triangle] and fScore[triangle] < lowestFScore then
				lowestFScore = fScore[triangle]
				current = triangle
			end
		end

		local points = triangleSet:GetTrianglePoints(current)
		local debugTri = DrawTriangle.create(
			{
				Vector2ToVector3(points[1], 49),
				Vector2ToVector3(points[2], 49),
				Vector2ToVector3(points[3], 49),
			},
			{
				Color = BrickColor.random().Color,
				Transparency = 0.5,
			} :: any
		)
		task.wait(0.1)

		if current == goalTriangle then
			-- Reconstruct path
			local path = {}
			while current do
				table.insert(path, 1, current)
				current = cameFrom[current]
			end
			return { TriangleIndexs = path }
		end

		openSet[current] = nil

		-- Get neighbors (adjacent triangles)
		local neighbors = { triangleSet:GetAdjacentTriangleVertexIndices(current) }
		for _, neighbor in neighbors do
			if neighbor == -1 then
				continue
			end -- Skip invalid neighbors
			if table.find(triangulator.DiscardedTriangles, neighbor) then
				continue
			end -- Skip discarded triangles (Polygon holes)

			-- Tentative gScore
			local tentativeGScore = gScore[current] + getDistance(current, neighbor)

			if not gScore[neighbor] or tentativeGScore < gScore[neighbor] then
				-- This path to neighbor is better
				cameFrom[neighbor] = current
				gScore[neighbor] = tentativeGScore
				fScore[neighbor] = tentativeGScore + getDistToGoal(neighbor)
				openSet[neighbor] = true
			end
		end
	end

	warn("No path found")
	return nil
end

--[=[
	
]=]
function NavMesh.ClearRender(self: NavMeshInternal)
	self._Janitor:Remove("RenderModel")
end

--[=[
	
]=]
function NavMesh.Render(
	self: NavMeshInternal,
	_config: {
		RenderHeight: number?,
	}?
)
	local config = {
		RenderHeight = if _config and _config.RenderHeight then _config.RenderHeight else 48.5,
	}

	-- Setup the render model or fetch the existing one
	local RenderModel: Model & any = self._Janitor:Get("RenderModel")
	if RenderModel and RenderModel.Parent then
		-- already have a valid model, use it
	else
		local newRenderModel = Instance.new("Model")
		newRenderModel.Name = "NavMesh_Render"
		newRenderModel.Parent = workspace

		local TrianglesFolder = Instance.new("Folder")
		TrianglesFolder.Name = "Triangles"
		TrianglesFolder.Parent = newRenderModel

		local PointsFolder = Instance.new("Folder")
		PointsFolder.Name = "Points"
		PointsFolder.Parent = newRenderModel

		local MergedHolesFolder = Instance.new("Folder")
		MergedHolesFolder.Name = "MergedHoles"
		MergedHolesFolder.Parent = newRenderModel

		local HolesFolder = Instance.new("Folder")
		HolesFolder.Name = "Holes"
		HolesFolder.Parent = newRenderModel

		RenderModel = self._Janitor:Add(newRenderModel, nil, "RenderModel")
	end

	------------------------------------------------------------------------------------------
	-- Update or create new triangles based on the triangulation
	local existingTriangleModels = RenderModel.Triangles:GetChildren()
	local currentExistingTriangleIndex = 0

	for _, triangle: Triangle in self:GetTriangulation() do
		local triangle3d = {
			Vector2ToVector3(triangle[1], config.RenderHeight),
			Vector2ToVector3(triangle[2], config.RenderHeight),
			Vector2ToVector3(triangle[3], config.RenderHeight),
		}

		currentExistingTriangleIndex += 1
		local model = existingTriangleModels[currentExistingTriangleIndex]
		if model then
			DrawTriangle.render(triangle3d, model :: Model)
		else
			model = DrawTriangle.create(
				triangle3d,
				{
					Color = Color3.fromRGB(
						255 - math.random(0, 50),
						255 - math.random(0, 50),
						255 - math.random(0, 50)
					),
					Transparency = 0.6,
					Parent = RenderModel.Triangles,
				} :: any
			)
		end
		-- local pivot = model:GetPivot()
		-- model:PivotTo(CFrame.new(Vector3.new(pivot.X, config.RenderHeight, pivot.Z)))
	end

	-- Clear any unused models
	for i = currentExistingTriangleIndex + 1, #existingTriangleModels do
		existingTriangleModels[i]:Destroy()
	end

	------------------------------------------------------------------------------------------
	-- Render Merged Holes
	RenderModel.MergedHoles:ClearAllChildren()
	for i, holePolygon: Polygon in self:GetMergedHoles() do
		local HoleModel = drawPolygonOutline {
			Polygon = holePolygon,
			Color = BrickColor.Yellow().Color,
			Height = config.RenderHeight + 1,
		}
		HoleModel.Name = "MergedHole_" .. i
		HoleModel.Parent = RenderModel.MergedHoles
	end

	------------------------------------------------------------------------------------------
	-- Render outline
	local existingOutlineModel = RenderModel:FindFirstChild("TriangulationOutline")
	if existingOutlineModel then
		existingOutlineModel:ClearAllChildren()
	end

	local TriangulationOutline = drawPolygonOutline {
		Polygon = self.Triangulator:GetOutlinePolygon(),
		Color = BrickColor.Red().Color,
		Height = config.RenderHeight + 1,
		Model = existingOutlineModel,
	}
	TriangulationOutline.Name = "TriangulationOutline"
	TriangulationOutline.Parent = RenderModel

	return RenderModel
end

return NavMesh

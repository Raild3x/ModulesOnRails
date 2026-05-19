--!strict
--[=[
	@class DrawTriangle3d
	Utility for drawing triangles in 3D space using wedge parts.

	`DrawTriangle3d` provides functions to create and update triangle models composed of wedge parts.
	Triangles larger than Roblox's part size limit are automatically split into multiple sub-triangles.
	### Example

	```lua
	local DrawTriangle3d = require(path.to.DrawTriangle3d)

	local points = {
	    Vector3.new(0, 0, 0),
	    Vector3.new(5, 0, 0),
	    Vector3.new(2.5, 5, 0),
	}

	local triangleModel = DrawTriangle3d.create(points, {
	    Name = "MyTriangle",
	    Color = Color3.fromRGB(255, 0, 0),
	    Transparency = 0.5,
	    Thickness = 0.2,
	    Anchored = true,
	})

	-------------------------------------------------------
	-- To update the triangle's points later:

	local newPoints = {
	    Vector3.new(0, 0, 0),
	    Vector3.new(5, 0, 0),
	    Vector3.new(2.5, 5, 5),
	}

	DrawTriangle3d.render(newPoints, triangleModel)
	```
]=]

--[=[
	@within DrawTriangle3d
	@interface StyleConfig
	.Thickness number? -- The thickness of the triangle (thickness of the wedge parts)
	.Transparency number? -- The transparency of the triangle
	.Color Color3? -- The color of the triangle
	.Material Enum.Material? -- The material of the triangle
	.CanCollide boolean? -- Whether the triangle can collide
	.CanTouch boolean? -- Whether the triangle can be touched
	.CanQuery boolean? -- Whether the triangle can be queried
	.Locked boolean? -- Whether the triangle parts are locked
]=]
export type StyleConfig = {
	Thickness: number?,
	Transparency: number?,
	Color: Color3?,
	Material: Enum.Material?,
	CanCollide: boolean?,
	CanTouch: boolean?,
	CanQuery: boolean?,
	Locked: boolean?,
}

--[=[
	@within DrawTriangle3d
	@interface TriangleConfig
    .Name string? -- The name of the triangle model
	.Thickness number? -- The thickness of the triangle
	.Transparency number? -- The transparency of the triangle
	.Color Color3? -- The color of the triangle
	.Material Enum.Material? -- The material of the triangle
	.Anchored boolean? -- Whether the triangle is anchored
	.CanCollide boolean? -- Whether the triangle can collide
	.CanTouch boolean? -- Whether the triangle can be touched
	.CanQuery boolean? -- Whether the triangle can be queried
	.Parent Instance? -- The parent of the triangle
]=]
export type TriangleConfig = {
	Name: string?,
	Parent: Instance?,
	Anchored: boolean?,
} & StyleConfig

--------------------------------------------------------------------------------
--// Util //--
--------------------------------------------------------------------------------

local MAX_PART_SIZE = 2048

local WEDGE_TEMPLATE = Instance.new("WedgePart")
do
	WEDGE_TEMPLATE.Size = Vector3.one
	WEDGE_TEMPLATE.Anchored = true
	WEDGE_TEMPLATE.CanCollide = false
	WEDGE_TEMPLATE.CanTouch = false
	WEDGE_TEMPLATE.CanQuery = false
	WEDGE_TEMPLATE.CastShadow = true
	WEDGE_TEMPLATE.Locked = true
	WEDGE_TEMPLATE.Material = Enum.Material.SmoothPlastic
	WEDGE_TEMPLATE.Color = Color3.new(1, 1, 1)
	WEDGE_TEMPLATE.Transparency = 0
end

local function reorderPointsForLongestLine(p1: Vector3, p2: Vector3, p3: Vector3)
	local d12 = (p2 - p1).Magnitude
	local d23 = (p3 - p2).Magnitude
	local d13 = (p3 - p1).Magnitude

	if d12 >= d23 and d12 >= d13 then
		return p1, p2, p3
	elseif d23 >= d12 and d23 >= d13 then
		return p2, p3, p1
	else
		return p1, p3, p2
	end
end

local DrawTriangle3d = {}

local function getTriangleEdgeLengths(points: { Vector3 }): (number, number, number)
	local p1, p2, p3 = points[1], points[2], points[3]
	return (p2 - p1).Magnitude, (p3 - p2).Magnitude, (p3 - p1).Magnitude
end

local function isTriangleWithinPartLimit(points: { Vector3 }): boolean
	local d12, d23, d13 = getTriangleEdgeLengths(points)
	return d12 <= MAX_PART_SIZE and d23 <= MAX_PART_SIZE and d13 <= MAX_PART_SIZE
end

local function splitOversizedTriangle(points: { Vector3 }): { { Vector3 } }
	local result: { { Vector3 } } = {}
	local stack: { { Vector3 } } = { points }

	while #stack > 0 do
		local trianglePoints = table.remove(stack)
		if trianglePoints == nil then
			continue
		end

		if isTriangleWithinPartLimit(trianglePoints) then
			table.insert(result, trianglePoints)
		else
			local p1, p2, p3 = trianglePoints[1], trianglePoints[2], trianglePoints[3]
			local d12, d23, d13 = getTriangleEdgeLengths(trianglePoints)

			if d12 >= d23 and d12 >= d13 then
				local midpoint = (p1 + p2) / 2
				table.insert(stack, { midpoint, p2, p3 })
				table.insert(stack, { p1, midpoint, p3 })
			elseif d23 >= d12 and d23 >= d13 then
				local midpoint = (p2 + p3) / 2
				table.insert(stack, { p1, midpoint, p3 })
				table.insert(stack, { p1, p2, midpoint })
			else
				local midpoint = (p1 + p3) / 2
				table.insert(stack, { p1, p2, midpoint })
				table.insert(stack, { midpoint, p2, p3 })
			end
		end
	end

	return result
end

local function assertTriangleModel(model: Model): (WedgePart, WedgePart)
	local wedge1, wedge2 = (model :: any).T1, (model :: any).T2
	return wedge1, wedge2
end

local function getTriangleStyleSource(model: Model): WedgePart
	local directWedge1 = (model :: any).T1
	if directWedge1 then
		return directWedge1
	end

	for _, child in ipairs(model:GetChildren()) do
		if child:IsA("Model") then
			local childWedge1 = (child :: any).T1
			if childWedge1 then
				return childWedge1
			end
		end
	end

	error("Triangle model does not contain any wedge parts")
end

local function copyStyleFromModel(model: Model): TriangleConfig
	local wedge1 = getTriangleStyleSource(model)
	return {
		Thickness = wedge1.Size.X,
		Transparency = wedge1.Transparency,
		Color = wedge1.Color,
		Material = wedge1.Material,
		CanCollide = wedge1.CanCollide,
		CanTouch = wedge1.CanTouch,
		CanQuery = wedge1.CanQuery,
		Locked = wedge1.Locked,
		Anchored = wedge1.Anchored,
	}
end

local function buildTriangleLeafModel(triangleModel: Model, points: { Vector3 }, config: TriangleConfig)
	local wedge1CF, wedge1Size, wedge2CF, wedge2Size = DrawTriangle3d.calculateCFramesAndSizes(points, config.Thickness)

	local wedge1 = WEDGE_TEMPLATE:Clone()
	wedge1.Name = "T1"
	wedge1.Size = wedge1Size
	wedge1.CFrame = wedge1CF
	wedge1.Parent = triangleModel

	local wedge2 = wedge1:Clone()
	wedge2.Name = "T2"
	wedge2.Size = wedge2Size
	wedge2.CFrame = wedge2CF
	wedge2.Parent = triangleModel

	if config.Anchored == false then
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = wedge1
		weld.Part1 = wedge2
		weld.Parent = triangleModel

		wedge1.Anchored = false
		wedge2.Anchored = false
	end

	DrawTriangle3d.style(triangleModel, config)
end

local function populateTriangleModel(triangleModel: Model, points: { Vector3 }, config: TriangleConfig)
	triangleModel:ClearAllChildren()

	local trianglePieces = splitOversizedTriangle(points)
	if #trianglePieces == 1 then
		triangleModel:SetAttribute("DrawTriangle3dComposite", nil)
		buildTriangleLeafModel(triangleModel, trianglePieces[1], config)
		return
	end

	triangleModel:SetAttribute("DrawTriangle3dComposite", true)

	local anchorPart: WedgePart? = nil
	for index, trianglePiece in ipairs(trianglePieces) do
		local segmentModel = Instance.new("Model")
		segmentModel.Name = `TriangleSegment{index}`
		buildTriangleLeafModel(segmentModel, trianglePiece, config)
		segmentModel.Parent = triangleModel

		if config.Anchored == false then
			local segmentWedge1 = (segmentModel :: any).T1 :: WedgePart
			if anchorPart == nil then
				anchorPart = segmentWedge1
			else
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = anchorPart
				weld.Part1 = segmentWedge1
				weld.Parent = triangleModel
			end
		end
	end
end

--------------------------------------------------------------------------------
--// Class //--
--------------------------------------------------------------------------------

-- Updates an existing triangle model with new vertex positions
local function updateTriangle(points: { Vector3 }, model: Model)
	local wedge1, wedge2 = assertTriangleModel(model)
	local wedge1CF, wedge1Size, wedge2CF, wedge2Size = DrawTriangle3d.calculateCFramesAndSizes(points, wedge1.Size.X)

	wedge1.CFrame = wedge1CF
	wedge1.Size = wedge1Size
	wedge2.CFrame = wedge2CF
	wedge2.Size = wedge2Size
end

--[=[
	Calculates CFrames and Sizes for two wedge parts needed to form a triangle from the given points.
	@param points -- The vertices of the triangle.
	@param _thickness -- The thickness of the wedges. Defaults to 0.2
]=]
function DrawTriangle3d.calculateCFramesAndSizes(
	points: { Vector3 },
	_thickness: number?
): (CFrame, Vector3, CFrame, Vector3)
	local thickness = _thickness or 0.2
	local a, b, c = reorderPointsForLongestLine(points[1], points[2], points[3])

	local bottomVec = b - a
	local bottomVecDir = bottomVec.Unit
	local targVec = c - a

	local projectionScalar = targVec:Dot(bottomVecDir)
	local upV = c - (a + (bottomVecDir * projectionScalar))
	local upVDist = upV.Magnitude

	local w1P = a + targVec / 2
	local w1CFrame = CFrame.lookAt(w1P, w1P + upV, -bottomVecDir)
	local w1Size = Vector3.new(thickness or 0, projectionScalar, upVDist)

	local w2P = b + (c - b) / 2
	local w2CFrame = CFrame.lookAt(w2P, w2P + upV, bottomVecDir)
	local w2Size = Vector3.new(thickness or 0, bottomVec.Magnitude - projectionScalar, upVDist)

	return w1CFrame, w1Size, w2CFrame, w2Size
end

--[=[
	Creates a triangle model using wedge parts.

	Triangles that exceed Roblox's part size limit are split into multiple smaller triangle models.

	If `config.Anchored` is set to `false`, the wedges in each segment will be welded together, and
	segmented triangles will also be chained together so the triangle moves as a single unit while
	still being affected by physics.
]=]
function DrawTriangle3d.create(points: { Vector3 }, config: TriangleConfig?): Model
	assert(#points == 3, "Triangle must have exactly 3 points")

	local cfg = config or {} :: TriangleConfig
	assert(typeof(cfg) == "table", "Config must be a table")

	local triangleContainerModel = Instance.new("Model")
	triangleContainerModel.Name = cfg.Name or "TriangleModel"

	populateTriangleModel(triangleContainerModel, points, cfg)

	triangleContainerModel.Parent = cfg.Parent or workspace
	return triangleContainerModel
end

--[=[
    Styles an existing triangle model with the given configuration
]=]
function DrawTriangle3d.style(triangleModel: Model, config: StyleConfig)
	if triangleModel:GetAttribute("DrawTriangle3dComposite") == true then
		for _, child in ipairs(triangleModel:GetChildren()) do
			if child:IsA("Model") then
				DrawTriangle3d.style(child, config)
			end
		end
		return
	end

	local wedge1: any, wedge2: any = assertTriangleModel(triangleModel)

	local thickness = config.Thickness
	if thickness then
		wedge1.Size = Vector3.new(thickness, wedge1.Size.Y, wedge1.Size.Z)
		wedge2.Size = Vector3.new(thickness, wedge2.Size.Y, wedge2.Size.Z)
	end

	local function trySet(propName: string)
		local value = (config :: any)[propName]
		if value ~= nil then
			wedge1[propName] = value
			wedge2[propName] = value
		end
	end

	local supportedProps = {
		"Transparency",
		"Color",
		"Material",
		"CanCollide",
		"CanTouch",
		"CanQuery",
		"Locked",
	}
	for _, propName in ipairs(supportedProps) do
		trySet(propName)
	end
end

--[=[
    Creates or updates a triangle model to match the given points. 
	If `existingModel` is provided, it will be updated; otherwise, a new model will be created.

	More efficient than creating a new model if you need to update the triangle frequently, as it reuses the same parts.
]=]
function DrawTriangle3d.render(points: { Vector3 }, existingModel: Model?): Model
	if existingModel then
		if existingModel:GetAttribute("DrawTriangle3dComposite") == true or not isTriangleWithinPartLimit(points) then
			populateTriangleModel(existingModel, points, copyStyleFromModel(existingModel))
		else
			updateTriangle(points, existingModel)
		end
		return existingModel
	else
		return DrawTriangle3d.create(points)
	end
end

--[=[
	Bulk renders multiple triangles by calling `nextTriangle` repeatedly until it returns nil.
	`nextTriangle` should return a tuple of ({ Vector3 }?, TriangleModel?). If the first element
	is nil, the bulk rendering will stop.
	```lua
	local DrawTriangle3d = require(path.to.DrawTriangle3d)

	local trianglePoints: { Vector3 } = {
	    { Vector3.new(0, 0, 0), Vector3.new(5, 0, 0), Vector3.new(2.5, 5, 0) },
	    { Vector3.new(1, 1, 1), Vector3.new(6, 1, 1), Vector3.new(3.5, 6, 1) },
	    -- more triangles...
	}

	local triangleModels: { Model } = {}
	for i, points in ipairs(trianglePoints) do
	    triangleModels[i] = DrawTriangle3d.create(points)
	end

	local index = 0
	DrawTriangle3d.bulkRenderViaIterator(function()
	    index += 1
		if index > #trianglePoints then
			return nil
		end
		return trianglePoints[index], triangleModels[index]
	end)
	```
]=]
function DrawTriangle3d.bulkRenderViaIterator(nextTriangle: () -> ({ Vector3 }?, Model?))
	local parts: { BasePart } = {}
	local cframes: { CFrame } = {}
	local deferredUpdates: { { points: { Vector3 }, model: Model } } = {}
	while true do
		local points, model = nextTriangle()
		if not points or not model then
			break
		end

		if model:GetAttribute("DrawTriangle3dComposite") == true or not isTriangleWithinPartLimit(points) then
			table.insert(deferredUpdates, {
				points = points,
				model = model,
			})
		else
			local wedge1, wedge2 = assertTriangleModel(model)
			local w1CF, w1Size, w2CF, w2Size = DrawTriangle3d.calculateCFramesAndSizes(points, wedge1.Size.X)

			table.insert(parts, wedge1)
			table.insert(parts, wedge2)

			table.insert(cframes, w1CF)
			table.insert(cframes, w2CF)

			wedge1.Size = w1Size
			wedge2.Size = w2Size
		end
	end

	for _, update in ipairs(deferredUpdates) do
		DrawTriangle3d.render(update.points, update.model)
	end

	workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
end

return DrawTriangle3d

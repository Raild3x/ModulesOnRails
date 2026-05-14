local DEBUG_HEIGHT = 50

local Util = {}

local function getDebugParent()
	local debugParent = workspace:FindFirstChild("DelaunayUtilDebug")
	if not debugParent then
		debugParent = Instance.new("Folder")
		debugParent.Name = "DelaunayUtilDebug"
		debugParent.Parent = workspace
	end
	return debugParent
end

function Util.DrawPoint(position: Vector2 | Vector3, _color: Color3?, _size: number?): Instance
	if typeof(position) == "Vector2" then
		position = Vector3.new(position.Y, DEBUG_HEIGHT, position.X)
	end

	local point = Instance.new("Part")
	point.Name = "Point"
	point.Size = Vector3.one * (_size or 0.5)
	point.Color = _color or Color3.fromRGB(255, 150, 0)
	point.Transparency = 0.75
	point.Material = Enum.Material.Neon
	point.Anchored = true
	point.CanCollide = false
	point.Position = position
	point.Shape = Enum.PartType.Ball
	point.Parent = getDebugParent()

	-- Debris:AddItem(point, 120)

	return point
end

function Util.DrawLine(start: Vector2 | Vector3, finish: Vector2 | Vector3, _color: Color3?, _width: number?): Instance
	if typeof(start) == "Vector2" then
		start = Vector3.new(start.Y, DEBUG_HEIGHT, start.X)
	end

	if typeof(finish) == "Vector2" then
		finish = Vector3.new(finish.Y, DEBUG_HEIGHT, finish.X)
	end

	local width = _width or 0.3
	local color = _color or Color3.fromRGB(255, 150, 0)

	assert(typeof(start) == "Vector3", "start must be a Vector3. Got: " .. typeof(start))
	assert(typeof(finish) == "Vector3", "finish must be a Vector3. Got: " .. typeof(finish))
	assert(typeof(color) == "Color3", "color must be a Color3. Got: " .. typeof(color))

	local line = Instance.new("Part")
	line.Size = Vector3.new(width, width, (finish - start).Magnitude)
	line.Color = color or Color3.fromRGB(255, 150, 0)
	line.Material = Enum.Material.Neon
	line.Transparency = 0.5
	line.Anchored = true
	line.CanCollide = false
	line.Position = (start + finish) / 2
	line.CFrame = CFrame.lookAt(line.Position, finish)
	line.Parent = getDebugParent()

	-- Debris:AddItem(line, 120)

	return line
end

local i = 0
function Util.DrawRay(
	start: Vector2 | Vector3,
	direction: Vector2 | Vector3,
	_color: Color3?,
	_width: number?
): Instance
	i += 1
	if typeof(start) == "Vector2" then
		start = Vector3.new(start.Y, DEBUG_HEIGHT + i / 20, start.X)
	end

	if typeof(direction) == "Vector2" then
		direction = Vector3.new(direction.Y, 0, direction.X)
	end
	assert(typeof(start) == "Vector3", "start must be a Vector3")
	assert(typeof(direction) == "Vector3", "direction must be a Vector3")

	local parent = Instance.new("Model")
	parent.Name = "Ray"
	parent.Parent = getDebugParent()
	-- Debris:AddItem(parent, 120)

	local width = _width or 0.2
	local color = _color or Color3.fromRGB(255, 150, 0)
	local transparency = 0.5

	local line = Instance.new("Part")
	line.Size = Vector3.new(width, width, direction.Magnitude - width)
	line.Color = color
	line.Material = Enum.Material.Neon
	line.Anchored = true
	line.CanCollide = false
	line.Transparency = transparency
	line.CFrame = CFrame.lookAlong(start + direction / 2, direction)
	line.Parent = parent

	-- Use wedges to make an arrow tip
	local tipPos = start + direction - (direction.Unit * (width * 2))

	local wedge1 = Instance.new("WedgePart")
	wedge1.Size = Vector3.new(width + 0.1, width * 4, width * 4)
	wedge1.Color = color
	wedge1.Transparency = transparency
	wedge1.Material = Enum.Material.Neon
	wedge1.Anchored = true
	wedge1.CanCollide = false
	wedge1.CFrame = CFrame.lookAt(tipPos, start + direction)
		* CFrame.Angles(0, 0, math.pi / 2)
		* CFrame.new(0, width * 2, 0)
	wedge1.Parent = parent

	local wedge2 = wedge1:Clone()
	wedge2.CFrame = CFrame.lookAt(tipPos, start + direction)
		* CFrame.Angles(0, 0, -math.pi / 2)
		* CFrame.new(0, width * 2, 0)
	wedge2.Parent = parent

	return parent
end

function Util.DrawTriangle(triangle: { Vector2 | Vector3 }, _color: Color3?): Instance
	local DrawTriangle = require("../../DrawTriangle3d")

	for i, v in triangle do
		if typeof(v) == "Vector2" then
			triangle[i] = Vector3.new(v.Y, DEBUG_HEIGHT - 0.5, v.X)
		end
	end

	local tModel = DrawTriangle.createTriangleModel(triangle, {
		Color = _color,
		Thickness = 0.1,
		Transparency = 0.5,
	})
	tModel.Parent = getDebugParent()
	-- Debris:AddItem(tModel, 120)

	return tModel
end

return Util

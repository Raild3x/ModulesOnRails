--!strict
local RunService = game:GetService("RunService")

local Delaunay2d = require(script.Parent.Parent.Delaunay2d)
local DrawTriangle3d = require(script.Parent.Parent.Parent.DrawTriangle3d)

local DRAW_TRIANGLES = true
local DRAW_EDGES = true

local function asVec2(part: BasePart): Vector2
	return Vector2.new(part.Position.X, part.Position.Z)
end

local function asVec3(v: Vector2): Vector3
	return Vector3.new(v.X, 0, v.Y)
end

return function()
	local pointCount = 8
	local boundsMin = Vector3.new(-40, 0, -40)
	local boundsMax = Vector3.new(40, 0, 40)

	local pointsFolder = Instance.new("Folder")
	pointsFolder.Name = "Delaunay2d_Vertices"
	pointsFolder.Parent = workspace

	local parts: { Part } = {}
	local attachments: { Attachment } = {}
	local lastPositions: { Vector3 } = table.create(pointCount) :: any

	for i = 1, pointCount do
		local part = Instance.new("Part")
		part.Size = Vector3.one
		part.Shape = Enum.PartType.Ball
		part.Color = Color3.fromRGB(60, 190, 255)
		part.Material = Enum.Material.Neon
		part.Position = Vector3.new(math.random(boundsMin.X, boundsMax.X), 0, math.random(boundsMin.Z, boundsMax.Z))
		part.Anchored = true
		part.CanCollide = false
		part.CastShadow = false
		part.Parent = pointsFolder
		lastPositions[i] = part.Position

		local att = Instance.new("Attachment")
		att.Position = Vector3.zero
		att.Parent = part

		parts[i] = part
		attachments[i] = att
	end

	local triangulation = Delaunay2d.new()

	local edgeFolder = Instance.new("Folder")
	edgeFolder.Name = "Delaunay2d_Edges"
	edgeFolder.Parent = workspace

	local beamAnchor = Instance.new("Part")
	beamAnchor.Name = "BeamAnchor"
	beamAnchor.Size = Vector3.zero
	beamAnchor.Transparency = 1
	beamAnchor.CanCollide = false
	beamAnchor.CanTouch = false
	beamAnchor.CanQuery = false
	beamAnchor.CastShadow = false
	beamAnchor.Anchored = true
	beamAnchor.Position = Vector3.zero
	beamAnchor.Parent = edgeFolder

	local beamCache: { Beam } = {}
	local function getBeam(index: number): Beam
		local existing = beamCache[index]
		if existing then
			return existing
		end

		local beam = Instance.new("Beam")
		beam.Width0 = 0.08
		beam.Width1 = 0.08
		beam.Color = ColorSequence.new(Color3.fromRGB(255, 220, 120))
		beam.Transparency = NumberSequence.new(0.15)
		beam.LightEmission = 0.2
		beam.FaceCamera = true
		beam.Enabled = false
		beam.Parent = beamAnchor
		beamCache[index] = beam
		return beam
	end

	local triangleFolder = Instance.new("Folder")
	triangleFolder.Name = "Delaunay2d_Triangles"
	triangleFolder.Parent = workspace

	local triangleCache: { Model } = {}
	local function createTriangleModel(points3d: { Vector3 }): Model
		return DrawTriangle3d.create(
			points3d,
			{
				Name = "Tri2d",
				Parent = triangleFolder,
				Anchored = true,
				Thickness = 0.01,
				Transparency = 0,
				Color = Color3.fromRGB(math.random(255), math.random(255), math.random(255)),
				Material = Enum.Material.Plastic,
			} :: any
		)
	end

	local function rebuild()
		local points2d = table.create(#parts) :: { Vector2 }
		for i, part in parts do
			points2d[i] = asVec2(part)
		end

		triangulation:SetVertices(points2d)

		if DRAW_TRIANGLES then
			local triangles = triangulation:GetTriangles()
			local triCount = #triangles // 3
			local triIndex = 1
			for i = 1, #triangles, 3 do
				local a = points2d[triangles[i] + 1]
				local b = points2d[triangles[i + 1] + 1]
				local c = points2d[triangles[i + 2] + 1]
				local points3d = { asVec3(a), asVec3(b), asVec3(c) }

				local model = triangleCache[triIndex]
				if model then
					if model.Parent ~= triangleFolder then
						model.Parent = triangleFolder
					end
					DrawTriangle3d.render(points3d, model)
				else
					triangleCache[triIndex] = createTriangleModel(points3d)
				end
				triIndex += 1
			end

			for i = triCount + 1, #triangleCache do
				local model = triangleCache[i]
				if model.Parent ~= nil then
					model.Parent = nil
				end
			end
		end

		if DRAW_EDGES then
			local edges = triangulation:GetEdges()
			for i, edge in edges do
				local beam = getBeam(i)
				beam.Attachment0 = attachments[edge[1] + 1]
				beam.Attachment1 = attachments[edge[2] + 1]
				beam.Enabled = true
			end

			for i = #edges + 1, #beamCache do
				beamCache[i].Enabled = false
			end
		end
	end

	rebuild()

	local connection = RunService.Heartbeat:Connect(function()
		for i, part in parts do
			if part.Position ~= lastPositions[i] then
				lastPositions[i] = part.Position
				rebuild()
				return
			end
		end
	end)

	return function()
		connection:Disconnect()
		pointsFolder:Destroy()
		edgeFolder:Destroy()
		triangleFolder:Destroy()
	end
end

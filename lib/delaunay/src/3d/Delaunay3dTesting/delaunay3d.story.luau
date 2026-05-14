--!strict
local RunService = game:GetService("RunService")
local Delaunay3d = require(script.Parent.Parent.delaunay3d)
local DrawTriangle3d = require(script.Parent.Parent.Parent.DrawTriangle3d)

local DRAW_TRIANGLES = true
local DRAW_EDGES = true

local TRIANGLE_TRANSPARENCY = 0

return function()
	local boundsMin = Vector3.new(0, 0, 0)
	local boundsMax = Vector3.new(120, 60, 120)
	local pointCount = 5

	-- ── Vertex parts ────────────────────────────────────────────────────────
	-- Each Part IS the vertex – its Position is sampled directly each frame.
	local partsFolder = Instance.new("Folder")
	partsFolder.Name = "Delaunay_Vertices"
	partsFolder.Parent = workspace

	local parts: { Part } = {}
	local attachments: { Attachment } = {}
	local pointIds: { string } = table.create(pointCount)
	local lastPositions: { Vector3 } = table.create(pointCount)
	local delaunay = Delaunay3d.new()

	for i = 1, pointCount do
		local part = Instance.new("Part") :: Part
		part.Size = Vector3.one
		part.Shape = Enum.PartType.Ball
		part.Color = Color3.fromRGB(255, 100, 50)
		part.Material = Enum.Material.Neon
		part.Position = Vector3.new(
			math.round(math.random() * (boundsMax.X - boundsMin.X) + boundsMin.X),
			math.round(math.random() * (boundsMax.Y - boundsMin.Y) + boundsMin.Y),
			math.round(math.random() * (boundsMax.Z - boundsMin.Z) + boundsMin.Z)
		)
		part.Anchored = true
		part.CanCollide = false
		part.CastShadow = false
		part.Parent = partsFolder
		lastPositions[i] = part.Position
		pointIds[i] = delaunay:AddPoint(part.Position, `p{i}`)

		local att = Instance.new("Attachment")
		att.Position = Vector3.zero
		att.Parent = part

		table.insert(parts, part)
		table.insert(attachments, att)
	end

	-- ── Edge cache ───────────────────────────────────────────────────────────
	local edgeFolder = Instance.new("Folder")
	edgeFolder.Name = "Delaunay_Edges"
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

	local function getBeam(n: number): Beam
		if beamCache[n] then
			return beamCache[n]
		end
		local beam = Instance.new("Beam")
		beam.Width0 = 0.06
		beam.Width1 = 0.06
		beam.Color = ColorSequence.new(Color3.fromRGB(255, 220, 120))
		beam.Transparency = NumberSequence.new(0.1)
		beam.LightEmission = 0.25
		beam.FaceCamera = true
		beam.Enabled = false
		beam.Parent = beamAnchor
		beamCache[n] = beam
		return beam
	end

	local function buildPosToAttachment(): { [Vector3]: Attachment }
		local map: { [Vector3]: Attachment } = {}
		for i, part in parts do
			map[part.Position] = attachments[i]
		end
		return map
	end

	-- ── Triangle cache ───────────────────────────────────────────────────────
	-- Models are never destroyed during runtime; extra ones are detached when idle.
	local triangleFolder = Instance.new("Folder")
	triangleFolder.Name = "Delaunay_Triangles"
	triangleFolder.Parent = workspace

	local triangleCache: { Model } = {}

	local function createTriangleModel(points: { Vector3 }): Model
		local config = {
			Name = "Tri",
			Parent = triangleFolder,
			Anchored = true,
			Thickness = 0.01,
			Transparency = TRIANGLE_TRANSPARENCY,
			Color = Color3.fromRGB(math.random(255), math.random(255), math.random(255)),
			Material = Enum.Material.Plastic,
		} :: any
		return DrawTriangle3d.create(points, config)
	end

	-- ── Per-frame update ─────────────────────────────────────────────────────
	local updateThread = RunService.Heartbeat:Connect(function()
		for i, part in parts do
			local position = part.Position
			if position ~= lastPositions[i] then
				lastPositions[i] = position
				delaunay:MovePoint(pointIds[i], position)
			end
		end

		local triangles = delaunay:GetTriangles()
		local edges = delaunay:GetEdges()
		local posToAtt = buildPosToAttachment()

		-- Assign / reuse models for every triangle
		if DRAW_TRIANGLES then
			for i, tri in triangles do
				local points = { tri[1], tri[2], tri[3] }
				local model = triangleCache[i]
				if model then
					if model.Parent ~= triangleFolder then
						model.Parent = triangleFolder
					end
					DrawTriangle3d.render(points, model)
				else
					triangleCache[i] = createTriangleModel(points)
				end
			end

			-- Hide any cached triangles beyond the current triangle count
			for i = #triangles + 1, #triangleCache do
				local model = triangleCache[i]
				if model.Parent ~= nil then
					model.Parent = nil
				end
			end
		end

		-- Assign / reuse beams for every edge
		if DRAW_EDGES then
			for i, edge in edges do
				local beam = getBeam(i)
				beam.Attachment0 = posToAtt[edge[1]]
				beam.Attachment1 = posToAtt[edge[2]]
				beam.Enabled = true
			end

			-- Hide any cached beams beyond the current edge count
			for i = #edges + 1, #beamCache do
				beamCache[i].Enabled = false
			end
		end
	end)

	-- ── Cleanup ───────────────────────────────────────────────────────────────
	return function()
		updateThread:Disconnect()
		partsFolder:Destroy()
		edgeFolder:Destroy()
		triangleFolder:Destroy()
	end
end

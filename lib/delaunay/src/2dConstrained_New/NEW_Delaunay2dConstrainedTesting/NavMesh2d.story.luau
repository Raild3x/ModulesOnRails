--!strict
--[=[
NavMesh2d.story — live interactive constrained triangulation story.

Folder layout (created under Workspace/NavMesh2d_Story):
  - BoundaryPoints: BasePart children are triangulation points.
  - Holes:
      * Each child Folder/Model with >= 3 BasePart children is a hole polygon.
      * Direct BasePart children of Holes are treated as one polygon.
  - Edges:
      * Each child Folder/Model with >= 2 BasePart children contributes one
        constrained edge between its first two name-sorted points.
      * Direct BasePart children are paired in name order: (1,2), (3,4), ...

Debug visuals:
  - Debug/Vertices: every vertex known by the finalized triangulation.
  - Debug/EnforcedEdges: every edge in cdt.fixedEdges.
]=]

local RunService = game:GetService("RunService")

local CDTModule = require(script.Parent.Parent.Delaunay2dConstrained)
local CDTUtils = require(script.Parent.Parent.CDTUtils)
local DrawTriangle3d = require(script.Parent.Parent.Parent.DrawTriangle3d)

local EDGE_KEY_SHIFT = CDTUtils.EDGE_KEY_SHIFT

local function partToVec2(part: BasePart): Vector2
	return Vector2.new(part.Position.Z, part.Position.X)
end

local function vec2ToV3(v: Vector2, height: number): Vector3
	return Vector3.new(v.Y, height, v.X)
end

local function pointInPolygon(pt: Vector2, polygon: { Vector2 }): boolean
	local n = #polygon
	if n < 3 then
		return false
	end

	local inside = false
	local j = n
	for i = 1, n do
		local pi = polygon[i]
		local pj = polygon[j]
		if (pi.Y > pt.Y) ~= (pj.Y > pt.Y) then
			if pt.X < (pj.X - pi.X) * (pt.Y - pi.Y) / (pj.Y - pi.Y) + pi.X then
				inside = not inside
			end
		end
		j = i
	end

	return inside
end

local function getSortedChildParts(parent: Instance): { BasePart }
	local out: { BasePart } = {}
	for _, child in ipairs(parent:GetChildren()) do
		if child:IsA("BasePart") then
			table.insert(out, child)
		end
	end
	table.sort(out, function(a, b)
		return a.Name < b.Name
	end)
	return out
end

local function collectHolePolygons(holesFolder: Folder): { { Vector2 } }
	local polygons: { { Vector2 } } = {}

	local directHoleParts = getSortedChildParts(holesFolder)
	if #directHoleParts >= 3 then
		local directPolygon: { Vector2 } = {}
		for _, part in ipairs(directHoleParts) do
			table.insert(directPolygon, partToVec2(part))
		end
		table.insert(polygons, directPolygon)
	end

	for _, child in ipairs(holesFolder:GetChildren()) do
		if child:IsA("Folder") or child:IsA("Model") then
			local holeParts = getSortedChildParts(child)
			if #holeParts >= 3 then
				local poly: { Vector2 } = {}
				for _, part in ipairs(holeParts) do
					table.insert(poly, partToVec2(part))
				end
				table.insert(polygons, poly)
			end
		end
	end

	return polygons
end

local function makeSegment(
	name: string,
	a: Vector3,
	b: Vector3,
	color: Color3,
	thickness: number,
	parent: Instance
): Part
	local delta = b - a
	local length = delta.Magnitude
	if length <= 1e-4 then
		local dot = Instance.new("Part")
		dot.Name = name
		dot.Shape = Enum.PartType.Ball
		dot.Material = Enum.Material.Neon
		dot.Color = color
		dot.Size = Vector3.new(thickness * 2, thickness * 2, thickness * 2)
		dot.Position = a
		dot.Anchored = true
		dot.CanCollide = false
		dot.CanQuery = false
		dot.CanTouch = false
		dot.CastShadow = false
		dot.Parent = parent
		return dot
	end

	local p = Instance.new("Part")
	p.Name = name
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Size = Vector3.new(thickness, thickness, length)
	p.CFrame = CFrame.lookAt((a + b) * 0.5, b)
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Parent = parent
	return p
end

return function()
	print("[NavMesh2d.story] Mounting …")

	local rootFolder = Instance.new("Folder")
	rootFolder.Name = "NavMesh2d_Story"
	rootFolder.Parent = workspace

	local boundaryFolder = Instance.new("Folder")
	boundaryFolder.Name = "BoundaryPoints"
	boundaryFolder.Parent = rootFolder

	local holesFolder = Instance.new("Folder")
	holesFolder.Name = "Holes"
	holesFolder.Parent = rootFolder

	local edgesFolder = Instance.new("Folder")
	edgesFolder.Name = "Edges"
	edgesFolder.Parent = rootFolder

	local renderFolder = Instance.new("Folder")
	renderFolder.Name = "Render"
	renderFolder.Parent = rootFolder

	local debugFolder = Instance.new("Folder")
	debugFolder.Name = "Debug"
	debugFolder.Parent = rootFolder

	local function makeSphere(name: string, pos: Vector3, color: Color3, parent: Instance): Part
		local p = Instance.new("Part") :: Part
		p.Name = name
		p.Shape = Enum.PartType.Ball
		p.Material = Enum.Material.Neon
		p.Color = color
		p.Size = Vector3.new(1.5, 1.5, 1.5)
		p.Position = pos
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Parent = parent
		return p
	end

	local function makeEdgePoint(name: string, pos: Vector3, parent: Instance): Part
		local p = makeSphere(name, pos, Color3.fromRGB(255, 230, 110), parent)
		p.Size = Vector3.new(1.2, 1.2, 1.2)
		return p
	end

	local BOUNDARY_COLOR = Color3.fromRGB(60, 180, 255)
	for _, cfg in ipairs {
		{ name = "P1", x = 0, z = 0 },
		{ name = "P2", x = 40, z = 0 },
		{ name = "P3", x = 40, z = 40 },
		{ name = "P4", x = 0, z = 40 },
		{ name = "P5", x = 20, z = -10 },
		{ name = "P6", x = 50, z = 20 },
		{ name = "P7", x = 20, z = 50 },
		{ name = "P8", x = -10, z = 20 },
	} do
		makeSphere(cfg.name, Vector3.new(cfg.x, 0, cfg.z), BOUNDARY_COLOR, boundaryFolder)
	end

	local defaultHoleFolder = Instance.new("Folder")
	defaultHoleFolder.Name = "Hole_1"
	defaultHoleFolder.Parent = holesFolder
	for _, cfg in ipairs {
		{ name = "H1", x = 12, z = 12 },
		{ name = "H2", x = 28, z = 12 },
		{ name = "H3", x = 28, z = 28 },
		{ name = "H4", x = 12, z = 28 },
	} do
		makeSphere(cfg.name, Vector3.new(cfg.x, 0, cfg.z), Color3.fromRGB(255, 80, 80), defaultHoleFolder)
	end

	local defaultEdgeFolder = Instance.new("Folder")
	defaultEdgeFolder.Name = "Edge_1"
	defaultEdgeFolder.Parent = edgesFolder
	makeEdgePoint("A", Vector3.new(5, 0, 5), defaultEdgeFolder)
	makeEdgePoint("B", Vector3.new(35, 0, 35), defaultEdgeFolder)

	local renderModel: Model? = nil
	local debugModel: Model? = nil

	local function regenerate()
		if renderModel then
			renderModel:Destroy()
			renderModel = nil
		end
		if debugModel then
			debugModel:Destroy()
			debugModel = nil
		end

		local allVerts: { Vector2 } = {}
		local coordToIdx: { [string]: number } = {}

		local function addVert(pt: Vector2): number
			local key = string.format("%.10g,%.10g", pt.X, pt.Y)
			local existing = coordToIdx[key]
			if existing then
				return existing
			end
			table.insert(allVerts, pt)
			local idx = #allVerts
			coordToIdx[key] = idx
			return idx
		end

		for _, part in ipairs(getSortedChildParts(boundaryFolder)) do
			addVert(partToVec2(part))
		end

		local holePolygons = collectHolePolygons(holesFolder)
		local holeEdges: { { number } } = {}
		for _, hole in ipairs(holePolygons) do
			if #hole < 3 then
				continue
			end
			local holeIdx: { number } = {}
			for _, pt in ipairs(hole) do
				table.insert(holeIdx, addVert(pt))
			end
			local n = #holeIdx
			for i = 1, n do
				local a = holeIdx[i] - 1
				local b = holeIdx[i % n + 1] - 1
				table.insert(holeEdges, { a, b })
			end
		end

		local explicitEdges: { { number } } = {}

		local directEdgePoints = getSortedChildParts(edgesFolder)
		for i = 1, #directEdgePoints - 1, 2 do
			local a = addVert(partToVec2(directEdgePoints[i])) - 1
			local b = addVert(partToVec2(directEdgePoints[i + 1])) - 1
			table.insert(explicitEdges, { a, b })
		end

		for _, edgeContainer in ipairs(edgesFolder:GetChildren()) do
			if edgeContainer:IsA("Folder") or edgeContainer:IsA("Model") then
				local edgePts = getSortedChildParts(edgeContainer)
				if #edgePts >= 2 then
					local a = addVert(partToVec2(edgePts[1])) - 1
					local b = addVert(partToVec2(edgePts[2])) - 1
					table.insert(explicitEdges, { a, b })
				end
			end
		end

		if #allVerts < 3 then
			return
		end

		local cdt = CDTModule.new()
		cdt:insertVertices(allVerts)

		local constrainedEdges: { { number } } = {}
		for _, e in ipairs(holeEdges) do
			table.insert(constrainedEdges, e)
		end
		for _, e in ipairs(explicitEdges) do
			table.insert(constrainedEdges, e)
		end
		if #constrainedEdges > 0 then
			cdt:insertEdges(constrainedEdges)
		end

		cdt:eraseSuperTriangle()

		renderModel = Instance.new("Model")
		renderModel.Name = "Triangulation"
		renderModel.Parent = renderFolder

		local triIndex = 0
		local verts = cdt.vertices
		for _, tri in ipairs(cdt.triangles) do
			local vv = tri.vertices
			local v1 = verts[vv[1]]
			local v2 = verts[vv[2]]
			local v3 = verts[vv[3]]

			local centroid = Vector2.new((v1.X + v2.X + v3.X) / 3, (v1.Y + v2.Y + v3.Y) / 3)
			local insideHole = false
			for _, hole in ipairs(holePolygons) do
				if pointInPolygon(centroid, hole) then
					insideHole = true
					break
				end
			end
			if insideHole then
				continue
			end

			triIndex += 1
			DrawTriangle3d.create({
				vec2ToV3(v1, 0),
				vec2ToV3(v2, 0),
				vec2ToV3(v3, 0),
			}, {
				Name = `Triangle_{triIndex}`,
				Parent = renderModel,
				Color = Color3.fromRGB(100, 255, 140),
				Transparency = 0.5,
				Material = Enum.Material.Neon,
				CanCollide = false,
				CanQuery = false,
				CanTouch = false,
				Anchored = true,
				Thickness = 0.2,
			})
		end

		debugModel = Instance.new("Model")
		debugModel.Name = "DebugRender"
		debugModel.Parent = debugFolder

		local debugVerticesFolder = Instance.new("Folder")
		debugVerticesFolder.Name = "Vertices"
		debugVerticesFolder.Parent = debugModel

		for i, v in ipairs(verts) do
			local vertexPart = Instance.new("Part")
			vertexPart.Name = `V_{i}`
			vertexPart.Shape = Enum.PartType.Ball
			vertexPart.Material = Enum.Material.Neon
			vertexPart.Color = Color3.fromRGB(40, 255, 255)
			vertexPart.Size = Vector3.new(0.75, 0.75, 0.75)
			vertexPart.Position = vec2ToV3(v, 0.15)
			vertexPart.Anchored = true
			vertexPart.CanCollide = false
			vertexPart.CanQuery = false
			vertexPart.CanTouch = false
			vertexPart.CastShadow = false
			vertexPart.Parent = debugVerticesFolder
		end

		local debugEdgesFolder = Instance.new("Folder")
		debugEdgesFolder.Name = "EnforcedEdges"
		debugEdgesFolder.Parent = debugModel

		for key in cdt.fixedEdges do
			local lo = math.floor(key / EDGE_KEY_SHIFT)
			local hi = key - lo * EDGE_KEY_SHIFT
			local a = verts[lo]
			local b = verts[hi]
			if a and b then
				makeSegment(
					`E_{lo}_{hi}`,
					vec2ToV3(a, 0.25),
					vec2ToV3(b, 0.25),
					Color3.fromRGB(255, 220, 80),
					0.2,
					debugEdgesFolder
				)
			end
		end
	end

	local running = true
	local heartbeatConn = RunService.Heartbeat:Connect(function()
		if not running then
			return
		end
		local ok, err = pcall(regenerate)
		if not ok then
			warn("[NavMesh2d.story] regenerate error:", err)
		end
	end)

	return function()
		print("[NavMesh2d.story] Unmounting …")
		running = false
		heartbeatConn:Disconnect()
		if renderModel then
			renderModel:Destroy()
			renderModel = nil
		end
		if debugModel then
			debugModel:Destroy()
			debugModel = nil
		end
		rootFolder:Destroy()
	end
end

--!strict
--[=[
Delaunay2dConstrainedFinalizedForms.story

Renders multiple finalized outputs from the same constrained triangulation input
on top of each other for visual comparison:
  - eraseSuperTriangle
  - eraseOuterTriangles
  - eraseOuterTrianglesAndHoles

Folder layout (created under Workspace/Delaunay2dConstrained_FinalizedForms_Story):
  - BoundaryPoints
  - Holes
  - Edges
  - Render
  - Debug
]=]

local RunService = game:GetService("RunService")

local CDTModule = require(script.Parent.Parent.Delaunay2dConstrained)
local CDTUtils = require(script.Parent.Parent.CDTUtils)
local DrawTriangle3d = require(script.Parent.Parent.Parent.DrawTriangle3d)

local EDGE_KEY_SHIFT = CDTUtils.EDGE_KEY_SHIFT

type FinalizeVariant = {
	name: string,
	color: Color3,
	yOffset: number,
	transparency: number,
	finalize: (cdt: any) -> (),
}

local function partToVec2(part: BasePart): Vector2
	return Vector2.new(part.Position.Z, part.Position.X)
end

local function vec2ToV3(v: Vector2, height: number): Vector3
	return Vector3.new(v.Y, height, v.X)
end

local function getSortedChildParts(parent: Instance): { BasePart }
	local out: { BasePart } = {}
	for _, child in ipairs(parent:GetChildren()) do
		if child:IsA("BasePart") then
			table.insert(out, child)
		end
	end
	table.sort(out, function(a: BasePart, b: BasePart)
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

local function makeSphere(name: string, pos: Vector3, color: Color3, parent: Instance): Part
	local p = Instance.new("Part") :: Part
	p.Name = name
	p.Shape = Enum.PartType.Ball
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Size = Vector3.new(1.4, 1.4, 1.4)
	p.Position = pos
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Parent = parent
	return p
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

local function collectInput(
	boundaryFolder: Folder,
	holesFolder: Folder,
	edgesFolder: Folder
): ({ Vector2 }, { { number } }, { { Vector2 } })
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
	local constrainedEdges: { { number } } = {}

	for _, hole in ipairs(holePolygons) do
		if #hole >= 3 then
			local holeIdx: { number } = {}
			for _, pt in ipairs(hole) do
				table.insert(holeIdx, addVert(pt))
			end
			local n = #holeIdx
			for i = 1, n do
				local a = holeIdx[i] - 1
				local b = holeIdx[i % n + 1] - 1
				table.insert(constrainedEdges, { a, b })
			end
		end
	end

	local directEdgePoints = getSortedChildParts(edgesFolder)
	for i = 1, #directEdgePoints - 1, 2 do
		local a = addVert(partToVec2(directEdgePoints[i])) - 1
		local b = addVert(partToVec2(directEdgePoints[i + 1])) - 1
		table.insert(constrainedEdges, { a, b })
	end

	for _, edgeContainer in ipairs(edgesFolder:GetChildren()) do
		if edgeContainer:IsA("Folder") or edgeContainer:IsA("Model") then
			local edgePts = getSortedChildParts(edgeContainer)
			if #edgePts >= 2 then
				local a = addVert(partToVec2(edgePts[1])) - 1
				local b = addVert(partToVec2(edgePts[2])) - 1
				table.insert(constrainedEdges, { a, b })
			end
		end
	end

	return allVerts, constrainedEdges, holePolygons
end

return function()
	print("[Delaunay2dConstrainedFinalizedForms.story] Mounting...")

	local rootFolder = Instance.new("Folder")
	rootFolder.Name = "Delaunay2dConstrained_FinalizedForms_Story"
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

	local boundaryColor = Color3.fromRGB(80, 185, 255)
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
		makeSphere(cfg.name, Vector3.new(cfg.x, 0, cfg.z), boundaryColor, boundaryFolder)
	end

	local hole1 = Instance.new("Folder")
	hole1.Name = "Hole_1"
	hole1.Parent = holesFolder
	for _, cfg in ipairs {
		{ name = "H1", x = 10, z = 12 },
		{ name = "H2", x = 20, z = 8 },
		{ name = "H3", x = 30, z = 12 },
		{ name = "H4", x = 28, z = 25 },
		{ name = "H5", x = 14, z = 24 },
	} do
		makeSphere(cfg.name, Vector3.new(cfg.x, 0, cfg.z), Color3.fromRGB(255, 90, 90), hole1)
	end

	local edge1 = Instance.new("Folder")
	edge1.Name = "Edge_1"
	edge1.Parent = edgesFolder
	makeSphere("A", Vector3.new(3, 0, 30), Color3.fromRGB(255, 230, 110), edge1)
	makeSphere("B", Vector3.new(38, 0, 3), Color3.fromRGB(255, 230, 110), edge1)

	local edge2 = Instance.new("Folder")
	edge2.Name = "Edge_2"
	edge2.Parent = edgesFolder
	makeSphere("A", Vector3.new(0, 0, 20), Color3.fromRGB(255, 230, 110), edge2)
	makeSphere("B", Vector3.new(40, 0, 20), Color3.fromRGB(255, 230, 110), edge2)

	local finalizeVariants: { FinalizeVariant } = {
		{
			name = "eraseSuperTriangle",
			color = Color3.fromRGB(80, 255, 130),
			yOffset = 0.0,
			transparency = 0.62,
			finalize = function(cdt)
				cdt:eraseSuperTriangle()
			end,
		},
		{
			name = "eraseOuterTriangles",
			color = Color3.fromRGB(100, 180, 255),
			yOffset = 1,
			transparency = 0.68,
			finalize = function(cdt)
				cdt:eraseOuterTriangles()
			end,
		},
		{
			name = "eraseOuterTrianglesAndHoles",
			color = Color3.fromRGB(255, 180, 90),
			yOffset = 2,
			transparency = 0.45,
			finalize = function(cdt)
				cdt:eraseOuterTrianglesAndHoles()
			end,
		},
	}

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

		local allVerts, constrainedEdges = collectInput(boundaryFolder, holesFolder, edgesFolder)
		if #allVerts < 3 then
			return
		end

		local newRenderModel = Instance.new("Model")
		newRenderModel.Name = "FinalizedFormsOverlay"
		newRenderModel.Parent = renderFolder
		renderModel = newRenderModel

		local representativeVerts: { Vector2 } = {}
		local representativeFixedEdges: { [number]: boolean } = {}

		for _, variant in ipairs(finalizeVariants) do
			local cdt = CDTModule.new()
			cdt:insertVertices(allVerts)
			if #constrainedEdges > 0 then
				cdt:insertEdges(constrainedEdges)
			end
			variant.finalize(cdt)

			representativeVerts = cdt.vertices
			representativeFixedEdges = cdt.fixedEdges

			local variantModel = Instance.new("Model")
			variantModel.Name = variant.name
			variantModel.Parent = newRenderModel

			local triIndex = 0
			for _, tri in ipairs(cdt.triangles) do
				local vv = tri.vertices
				local v1 = cdt.vertices[vv[1]]
				local v2 = cdt.vertices[vv[2]]
				local v3 = cdt.vertices[vv[3]]
				if v1 and v2 and v3 then
					triIndex += 1
					DrawTriangle3d.create(
						{
							vec2ToV3(v1, variant.yOffset),
							vec2ToV3(v2, variant.yOffset),
							vec2ToV3(v3, variant.yOffset),
						},
						(
								{
									Name = `{variant.name}_Tri_{triIndex}`,
									Parent = variantModel,
									Color = variant.color,
									Transparency = variant.transparency,
									Material = Enum.Material.Neon,
									CanCollide = false,
									CanQuery = false,
									CanTouch = false,
									Anchored = true,
									Thickness = 0.16,
								}
							) :: any
					)
				end
			end
		end

		local newDebugModel = Instance.new("Model")
		newDebugModel.Name = "DebugRender"
		newDebugModel.Parent = debugFolder
		debugModel = newDebugModel

		local debugVerticesFolder = Instance.new("Folder")
		debugVerticesFolder.Name = "Vertices"
		debugVerticesFolder.Parent = newDebugModel

		for i, v in ipairs(representativeVerts) do
			local vp = Instance.new("Part")
			vp.Name = `V_{i}`
			vp.Shape = Enum.PartType.Ball
			vp.Material = Enum.Material.Neon
			vp.Color = Color3.fromRGB(35, 255, 255)
			vp.Size = Vector3.new(0.65, 0.65, 0.65)
			vp.Position = vec2ToV3(v, 0.2)
			vp.Anchored = true
			vp.CanCollide = false
			vp.CanQuery = false
			vp.CanTouch = false
			vp.CastShadow = false
			vp.Parent = debugVerticesFolder
		end

		local debugEdgesFolder = Instance.new("Folder")
		debugEdgesFolder.Name = "EnforcedEdges"
		debugEdgesFolder.Parent = newDebugModel

		for key in representativeFixedEdges do
			local lo = math.floor(key / EDGE_KEY_SHIFT)
			local hi = key - lo * EDGE_KEY_SHIFT
			local a = representativeVerts[lo]
			local b = representativeVerts[hi]
			if a and b then
				makeSegment(
					`E_{lo}_{hi}`,
					vec2ToV3(a, 0.24),
					vec2ToV3(b, 0.24),
					Color3.fromRGB(255, 225, 80),
					0.16,
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
			warn("[Delaunay2dConstrainedFinalizedForms.story] regenerate error:", err)
		end
	end)

	return function()
		print("[Delaunay2dConstrainedFinalizedForms.story] Unmounting...")
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

--!strict
-- Authors: Logan Hunt (Raildex)
-- September 25, 2026
--[=[
	@class DrawListRenderer

	Draws a DrawList in the 3D world (the Roblox backend). One renderer serves both the CDT
	and the NavMesh views: build the list with `CDT.ToDrawList` / `NavMesh.ToDrawList` and
	pass it to `Draw`.

	Lines, points, circles, arrows, labels and triangle outlines go on one
	`WireframeHandleAdornment` per (layer, colour). Triangles are also filled: one
	`EditableMesh`-backed `MeshPart` per (layer, colour) and 20,000 triangles. Ticket 20's
	benchmark chose this over two `WedgePart`s per triangle: on a 4,605-triangle mesh it
	draws in about 11 ms with one fill part, where wedges take about 250 ms and 9,210 parts.

	`Draw` never yields. Creating a `MeshPart` from an `EditableMesh` yields for a frame,
	so the fills appear a frame after `Draw`, and a newer `Draw` discards fills still on
	their way. Like the adornment lines, the fills do not replicate: draw where you look
	(Studio, or a client).

	```lua
	local renderer = DrawListRenderer.new(workspace)
	renderer:Draw(list)
	renderer:SetLayerVisible("Triangles", false)
	renderer:Destroy()
	```
]=]

local AssetService = game:GetService("AssetService")

local ConstrainedDelaunay = require("../ConstrainedDelaunay")

type DrawList = ConstrainedDelaunay.DrawList

local CIRCLE_SEGMENTS = 24
local POINT_CROSS_SIZE = 0.25
local TEXT_SIZE = 16
local FILL_TRANSPARENCY = 0.6
local MESH_CHUNK = 20000 -- an EditableMesh holds at most 20,000 triangles and 60,000 vertices

export type DrawListRenderer = {
	Draw: (self: DrawListRenderer, list: DrawList) -> (),
	SetLayerVisible: (self: DrawListRenderer, layer: string, visible: boolean) -> (),
	Destroy: (self: DrawListRenderer) -> (),
}

type DrawListRendererInternal = DrawListRenderer & {
	_folder: Folder,
	_adornments: { [string]: WireframeHandleAdornment }, -- key = layer .. "|" .. color
	_hiddenLayers: { [string]: boolean },
	_meshes: { EditableMesh }, -- backing the current fills; destroyed on the next Draw
	_generation: number, -- bumped by Draw and Destroy, so late fills know they are stale
	_pending: number, -- fills still being created
}

-- Triangle corners for one (layer, colour), three per triangle.
type Fill = { Layer: string, Color: string, Points: { Vector3 } }

local DrawListRenderer = {}
DrawListRenderer.__index = DrawListRenderer

--[=[
	@within DrawListRenderer
	Creates a renderer whose adornments and fills live in a Folder under `parent`.
]=]
function DrawListRenderer.new(parent: Instance): DrawListRenderer
	local folder = Instance.new("Folder")
	folder.Name = "DrawListRenderer"
	folder.Parent = parent

	local self = setmetatable({
		_folder = folder,
		_adornments = {},
		_hiddenLayers = {},
		_meshes = {},
		_generation = 0,
		_pending = 0,
	}, DrawListRenderer)
	return (self :: any) :: DrawListRenderer
end

local function getAdornment(self: DrawListRendererInternal, layer: string, color: string): WireframeHandleAdornment
	local key = layer .. "|" .. color
	local adornment = self._adornments[key]
	if adornment == nil then
		local created = Instance.new("WireframeHandleAdornment")
		created.Name = key
		created.Adornee = workspace.Terrain
		created.Color3 = Color3.fromHex(color)
		created.AlwaysOnTop = true
		created.Visible = not self._hiddenLayers[layer]
		created:SetAttribute("Layer", layer)
		created.Parent = self._folder
		self._adornments[key] = created
		adornment = created
	end
	return adornment :: WireframeHandleAdornment
end

local function v3(p: { number }, i: number): Vector3
	return Vector3.new(p[i], p[i + 1], p[i + 2])
end

-- Removes the fills and their meshes, and marks fills still being created as stale.
local function clearFills(self: DrawListRendererInternal)
	self._generation += 1
	for _, child in self._folder:GetChildren() do
		if child:IsA("MeshPart") then
			child:Destroy()
		end
	end
	for _, mesh in self._meshes do
		mesh:Destroy()
	end
	table.clear(self._meshes)
end

-- Creates the MeshPart for one mesh chunk. Runs on its own thread: CreateMeshPartAsync yields.
local function createFillPart(self: DrawListRendererInternal, mesh: EditableMesh, name: string, layer: string, color: string, center: Vector3)
	local generation = self._generation
	local ok, part = pcall(AssetService.CreateMeshPartAsync, AssetService, Content.fromObject(mesh))
	self._pending -= 1
	if not ok then
		if generation == self._generation then
			warn(`DrawListRenderer: could not create the fill for {name}: {part}`)
		end
		return
	end
	if generation ~= self._generation then
		part:Destroy()
		return
	end
	part.Name = "Fill " .. name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	part.Color = Color3.fromHex(color)
	part.Transparency = if self._hiddenLayers[layer] then 1 else FILL_TRANSPARENCY
	part.Position = center
	part:SetAttribute("Layer", layer)
	part.Parent = self._folder
end

-- Builds the meshes for `fills` now and creates their parts on spawned threads.
local function drawFills(self: DrawListRendererInternal, fills: { [string]: Fill })
	for key, fill in fills do
		local p = fill.Points
		for first = 1, #p, 3 * MESH_CHUNK do
			local last = math.min(#p, first + 3 * MESH_CHUNK - 1)
			local lo, hi = p[first], p[first]
			for i = first + 1, last do
				lo, hi = lo:Min(p[i]), hi:Max(p[i])
			end
			-- The part sits at the chunk's centre, so the mesh is built around it.
			local center = (lo + hi) / 2
			local ok, mesh = pcall(AssetService.CreateEditableMesh, AssetService)
			if not ok or mesh == nil then
				warn(`DrawListRenderer: EditableMesh unavailable, triangles drawn as outlines only: {mesh}`)
				return
			end
			for i = first, last, 3 do
				local a, b, c = p[i], p[i + 1], p[i + 2]
				-- Face up (+Y), so a floor is seen from above.
				if (b - a):Cross(c - a).Y < 0 then
					b, c = c, b
				end
				mesh:AddTriangle(mesh:AddVertex(a - center), mesh:AddVertex(b - center), mesh:AddVertex(c - center))
			end
			table.insert(self._meshes, mesh)
			self._pending += 1
			task.spawn(createFillPart, self, mesh, key, fill.Layer, fill.Color, center)
		end
	end
end

--[=[
	@within DrawListRenderer
	Replaces whatever was drawn before with `list`. Errors on an unknown primitive `Kind`.
	Never yields; triangle fills appear a frame later.
]=]
function DrawListRenderer.Draw(self: DrawListRendererInternal, list: DrawList)
	for _, adornment in self._adornments do
		adornment:Clear()
	end
	clearFills(self)
	local fills: { [string]: Fill } = {}
	for _, primitive in list do
		local adornment = getAdornment(self, primitive.Layer, primitive.Color)
		local p = primitive.Points
		local kind = primitive.Kind
		if kind == "Line" or kind == "Arrow" then
			adornment:AddLine(v3(p, 1), v3(p, 4))
		elseif kind == "Tri" then
			local a, b, c = v3(p, 1), v3(p, 4), v3(p, 7)
			adornment:AddPath({ a, b, c }, true)
			local key = primitive.Layer .. "|" .. primitive.Color
			local fill = fills[key]
			if fill == nil then
				fill = { Layer = primitive.Layer, Color = primitive.Color, Points = {} }
				fills[key] = fill
			end
			local points = (fill :: Fill).Points
			table.insert(points, a)
			table.insert(points, b)
			table.insert(points, c)
		elseif kind == "Point" then
			local center = v3(p, 1)
			adornment:AddLine(center - Vector3.xAxis * POINT_CROSS_SIZE, center + Vector3.xAxis * POINT_CROSS_SIZE)
			adornment:AddLine(center - Vector3.zAxis * POINT_CROSS_SIZE, center + Vector3.zAxis * POINT_CROSS_SIZE)
		elseif kind == "Circle" then
			local center = v3(p, 1)
			local radius = assert(primitive.Radius, "Circle primitive needs Radius")
			local ring = table.create(CIRCLE_SEGMENTS)
			for s = 1, CIRCLE_SEGMENTS do
				local angle = (s - 1) / CIRCLE_SEGMENTS * 2 * math.pi
				ring[s] = center + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
			end
			adornment:AddPath(ring, true)
		elseif kind == "Label" then
			adornment:AddText(v3(p, 1), primitive.Text or "", TEXT_SIZE)
		else
			error(`DrawListRenderer: unknown DrawPrimitive Kind "{tostring(kind)}"`, 2)
		end
	end
	drawFills(self, fills)
end

--[=[
	@within DrawListRenderer
	Shows or hides every primitive drawn on `layer`.
]=]
function DrawListRenderer.SetLayerVisible(self: DrawListRendererInternal, layer: string, visible: boolean)
	self._hiddenLayers[layer] = not visible or nil
	for _, child in self._folder:GetChildren() do
		if child:GetAttribute("Layer") ~= layer then
			continue
		end
		if child:IsA("WireframeHandleAdornment") then
			child.Visible = visible
		elseif child:IsA("MeshPart") then
			child.Transparency = if visible then FILL_TRANSPARENCY else 1
		end
	end
end

--[=[
	@within DrawListRenderer
	Removes every adornment and fill this renderer created.
]=]
function DrawListRenderer.Destroy(self: DrawListRendererInternal)
	clearFills(self)
	self._folder:Destroy()
	table.clear(self._adornments)
end

return DrawListRenderer

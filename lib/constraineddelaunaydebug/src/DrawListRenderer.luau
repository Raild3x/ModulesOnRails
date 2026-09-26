--!strict
-- Authors: Logan Hunt (Raildex)
-- September 25, 2026
--[=[
	@class DrawListRenderer

	Draws a DrawList in the 3D world (the Roblox backend). One renderer serves both the CDT
	and the NavMesh views: build the list with `CDT.ToDrawList` / `NavMesh.ToDrawList` and
	pass it to `Draw`.

	Phase 0 primitive: one `WireframeHandleAdornment` per (layer, colour), drawing lines and
	text. Filled triangles and the final primitive choice are benchmark-gated.

	```lua
	local renderer = DrawListRenderer.new(workspace)
	renderer:Draw(list)
	renderer:SetLayerVisible("Triangles", false)
	renderer:Destroy()
	```
]=]

local ConstrainedDelaunay = require("../ConstrainedDelaunay")

type DrawList = ConstrainedDelaunay.DrawList

local CIRCLE_SEGMENTS = 24
local POINT_CROSS_SIZE = 0.25
local TEXT_SIZE = 16

export type DrawListRenderer = {
	Draw: (self: DrawListRenderer, list: DrawList) -> (),
	SetLayerVisible: (self: DrawListRenderer, layer: string, visible: boolean) -> (),
	Destroy: (self: DrawListRenderer) -> (),
}

type DrawListRendererInternal = DrawListRenderer & {
	_folder: Folder,
	_adornments: { [string]: WireframeHandleAdornment }, -- key = layer .. "|" .. color
	_hiddenLayers: { [string]: boolean },
}

local DrawListRenderer = {}
DrawListRenderer.__index = DrawListRenderer

--[=[
	@within DrawListRenderer
	Creates a renderer whose adornments live in a Folder under `parent`.
]=]
function DrawListRenderer.new(parent: Instance): DrawListRenderer
	local folder = Instance.new("Folder")
	folder.Name = "DrawListRenderer"
	folder.Parent = parent

	local self = setmetatable({
		_folder = folder,
		_adornments = {},
		_hiddenLayers = {},
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

--[=[
	@within DrawListRenderer
	Replaces whatever was drawn before with `list`. Errors on an unknown primitive `Kind`.
]=]
function DrawListRenderer.Draw(self: DrawListRendererInternal, list: DrawList)
	for _, adornment in self._adornments do
		adornment:Clear()
	end
	for _, primitive in list do
		local adornment = getAdornment(self, primitive.Layer, primitive.Color)
		local p = primitive.Points
		local kind = primitive.Kind
		if kind == "Line" or kind == "Arrow" then
			adornment:AddLine(v3(p, 1), v3(p, 4))
		elseif kind == "Tri" then
			adornment:AddPath({ v3(p, 1), v3(p, 4), v3(p, 7) }, true)
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
end

--[=[
	@within DrawListRenderer
	Shows or hides every primitive drawn on `layer`.
]=]
function DrawListRenderer.SetLayerVisible(self: DrawListRendererInternal, layer: string, visible: boolean)
	self._hiddenLayers[layer] = not visible or nil
	for _, adornment in self._adornments do
		if adornment:GetAttribute("Layer") == layer then
			adornment.Visible = visible
		end
	end
end

--[=[
	@within DrawListRenderer
	Removes every adornment this renderer created.
]=]
function DrawListRenderer.Destroy(self: DrawListRendererInternal)
	self._folder:Destroy()
	table.clear(self._adornments)
end

return DrawListRenderer

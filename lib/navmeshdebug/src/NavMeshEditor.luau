--!strict
-- Authors: Logan Hunt (Raildex)
-- September 27, 2026
--[=[
	@class NavMeshEditor

	In-game mouse editor for NavMesh and CDT descriptions. Run it from a LocalScript in Play
	mode. It draws the built mesh with `DrawListRenderer`, shows a live path between two
	markers, and exports the description as Luau source.

	```lua
	local editor = NavMeshEditor.new(workspace, "NavMesh", NavMesh.Fixtures.ThreeFloorStairs.Desc)
	editor.Changed:Connect(function(desc)
		print(editor:ExportSource())
	end)
	```

	Every edit goes through `EditorState.Apply`, which holds the description, the selection
	and the markers. After an edit the editor rebuilds (`NavMesh.Build` or `CDT.Triangulate`)
	and redraws. A build error, such as a ring that crosses itself, does not stop the editor:
	it keeps drawing the last good mesh and shows the message in its status bar.

	Controls (the character's movement keys, WASD, Space, I and O, are left alone):

	| Input | Action |
	|---|---|
	| Left mouse | select the nearest handle; drag it across its own height |
	| 1 / 2 / 3 | new walkable / obstacle / area ring at the pointer (CDT: group 1 / 2 / 3 ring) |
	| 4 | new seam from the pointer, 4 studs along +Z (CDT: an open constraint edge) |
	| 5 / 6 | new two-way / one-way link from the pointer, 4 studs along +X |
	| V | insert a vertex after the selected one |
	| X or Delete | delete the selection (a ring below 3 vertices goes with it) |
	| Z / C | put the start / goal marker at the pointer |
	| [ / ] or the slider | agent radius down / up |
	| T | show or hide the tile grid |
	| P | print the description as Luau source |
]=]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local ConstrainedDelaunay = require("../ConstrainedDelaunay")
local ConstrainedDelaunayDebug = require("../ConstrainedDelaunayDebug")
local EditorState = require("./EditorState")
local Janitor = require("../Janitor")
local LuauLiteral = require("./LuauLiteral")
local NavMesh = require("../NavMesh")
local Signal = require("../Signal")

local DrawListRenderer = ConstrainedDelaunayDebug.DrawListRenderer

export type EditorMode = EditorState.Mode
export type EditorDescription = NavMesh.NavMeshDesc | ConstrainedDelaunay.TriangulateInput
export type Editor = {
	Changed: Signal.Signal<(EditorDescription) -> (), EditorDescription>,
	GetDescription: (self: Editor) -> EditorDescription,
	ExportSource: (self: Editor) -> string,
	Destroy: (self: Editor) -> (),
}

type EditorInternal = Editor & {
	_janitor: Janitor.Janitor,
	_state: EditorState.State,
	_renderer: any, -- a DrawListRenderer
	_built: any?, -- the last mesh or triangulation that built
	_error: string?, -- the last build, path or input error
	_pathStatus: string?,
	_showTiles: boolean,
	_dragging: boolean,
	_status: TextLabel,
	_radiusFill: Frame, -- the slider's filled part
	_apply: (self: EditorInternal, event: EditorState.Event) -> (),
}

local MAX_RADIUS = 4
local RADIUS_STEP = 0.25
local NEW_EDGE_LENGTH = 4
local HANDLE_COLOR = "#000000"
local SELECTED_COLOR = "#fdd835"
local START_COLOR = "#00c853"
local GOAL_COLOR = "#d50000"

local NavMeshEditor = {}
NavMeshEditor.__index = NavMeshEditor

--[=[
	@within NavMeshEditor
	@prop Changed Signal<(EditorDescription) -> ()>
	Fires a copy of the description after every edit that changes it.
]=]

local function build(state: EditorState.State): any
	if state.Mode == "CDT" then
		return ConstrainedDelaunay.Triangulate(state.Description)
	end
	return NavMesh.Build(state.Description)
end

-- The view: the built mesh (tiles, seams, links and the path), then handles and markers.
local function drawList(self: EditorInternal): { any }
	local state = self._state
	local list: { any } = {}
	self._pathStatus = nil
	if self._built and state.Mode == "CDT" then
		list = ConstrainedDelaunay.ToDrawList(self._built, { ShowConstraints = true })
	elseif self._built then
		local path = nil
		if state.Start and state.Goal then
			local ok, result = pcall(NavMesh.FindPath, self._built, state.Start :: any, state.Goal :: any, {
				AgentRadius = state.AgentRadius,
			})
			if ok then
				path = result
				self._pathStatus = result.Status
			else
				self._pathStatus = tostring(result)
			end
		end
		list = NavMesh.ToDrawList(self._built, { Tiles = self._showTiles, Seams = true, Links = true }, path)
	end
	local selection = state.Selection
	for _, h in EditorState.Handles(state) do
		local p = EditorState.HandlePosition(state, h)
		if h.Kind == "Marker" then
			local start = h.Which == "Start"
			local color = if start then START_COLOR else GOAL_COLOR
			table.insert(list, {
				Kind = "Circle",
				Points = { p.X, p.Y, p.Z },
				Radius = math.max(state.AgentRadius, 0.25),
				Color = color,
				Layer = "Markers",
			})
			table.insert(list, {
				Kind = "Label",
				Points = { p.X, p.Y, p.Z },
				Color = color,
				Layer = "Markers",
				Text = if start then "start" else "goal",
			})
		else
			table.insert(list, { Kind = "Point", Points = { p.X, p.Y, p.Z }, Color = HANDLE_COLOR, Layer = "Handles" })
		end
		if
			selection
			and h.Kind == selection.Kind
			and h.Floor == selection.Floor
			and h.List == selection.List
			and h.Ring == selection.Ring
			and h.Index == selection.Index
			and h.End == selection.End
			and h.Which == selection.Which
		then
			table.insert(
				list,
				{ Kind = "Circle", Points = { p.X, p.Y, p.Z }, Radius = 0.6, Color = SELECTED_COLOR, Layer = "Handles" }
			)
		end
	end
	return list
end

local function describe(h: EditorState.Handle?): string
	if h == nil then
		return "nothing"
	elseif h.Kind == "Vertex" then
		return `{h.Floor} {h.List} ring {h.Ring} vertex {h.Index}`
	elseif h.Kind == "Marker" then
		return `{h.Which} marker`
	elseif h.Kind == "Coord" then
		return `point {h.Index}`
	end
	return `{h.Kind} {h.Index} {h.End}`
end

local function refresh(self: EditorInternal, rebuild: boolean)
	if rebuild then
		local ok, result = pcall(build, self._state)
		if ok then
			self._built, self._error = result, nil
		else
			self._error = tostring(result)
		end
	end
	self._renderer:Draw(drawList(self))
	local state = self._state
	local status = `{state.Mode} | radius {state.AgentRadius} | selected {describe(state.Selection)}`
	if self._pathStatus then
		status ..= ` | path {self._pathStatus}`
	end
	if self._error then
		status ..= ` | ERROR: {self._error}`
	end
	self._status.Text = status
	self._status.TextColor3 = if self._error then Color3.fromRGB(255, 120, 120) else Color3.new(1, 1, 1)
	self._radiusFill.Size = UDim2.fromScale(math.min(state.AgentRadius / MAX_RADIUS, 1), 1)
end

--[=[
	@within NavMeshEditor
	@private
	Applies one `EditorState` event, rebuilds when the description changed, redraws, and
	fires `Changed`. An event the state rejects is shown in the status bar, not thrown.
]=]
function NavMeshEditor._apply(self: EditorInternal, event: EditorState.Event)
	local ok, changed = pcall(EditorState.Apply, self._state, event)
	if not ok then
		self._error = tostring(changed)
		refresh(self, false)
		return
	end
	refresh(self, changed)
	if changed then
		self.Changed:Fire(self:GetDescription())
	end
end

local function pointerRay(): (vector, vector)
	local mouse = UserInputService:GetMouseLocation()
	local ray = (workspace.CurrentCamera :: Camera):ViewportPointToRay(mouse.X, mouse.Y)
	return ray.Origin :: any, ray.Direction :: any -- a Vector3 is a vector at runtime
end

-- Where the pointer meets the plane of the selected handle (or y = 0).
local function pointerPosition(self: EditorInternal): vector?
	local state = self._state
	local height = if state.Selection then EditorState.HandlePosition(state, state.Selection).Y else 0
	local origin, direction = pointerRay()
	return EditorState.RayToPlane(origin, direction, height)
end

-- Key -> the event it makes at pointer position `p` (CDT mode may map a key differently).
local KEYS: { [Enum.KeyCode]: (self: EditorInternal, p: vector) -> EditorState.Event? } = {
	[Enum.KeyCode.One] = function(_, p)
		return { Type = "CreateRing", Kind = "Walkable", Position = p }
	end,
	[Enum.KeyCode.Two] = function(_, p)
		return { Type = "CreateRing", Kind = "Obstacle", Position = p }
	end,
	[Enum.KeyCode.Three] = function(_, p)
		return { Type = "CreateRing", Kind = "Area", Position = p }
	end,
	[Enum.KeyCode.Four] = function(self, p)
		local to = p + vector.create(0, 0, NEW_EDGE_LENGTH)
		return { Type = if self._state.Mode == "CDT" then "CreateEdge" else "CreateSeam", From = p, To = to }
	end,
	[Enum.KeyCode.Five] = function(_, p)
		return { Type = "CreateLink", From = p, To = p + vector.create(NEW_EDGE_LENGTH, 0, 0) }
	end,
	[Enum.KeyCode.Six] = function(_, p)
		return { Type = "CreateLink", From = p, To = p + vector.create(NEW_EDGE_LENGTH, 0, 0), Bidirectional = false }
	end,
	[Enum.KeyCode.V] = function()
		return { Type = "InsertVertex" }
	end,
	[Enum.KeyCode.X] = function()
		return { Type = "Delete" }
	end,
	[Enum.KeyCode.Delete] = function()
		return { Type = "Delete" }
	end,
	[Enum.KeyCode.Z] = function(_, p)
		return { Type = "SetMarker", Which = "Start", Position = p }
	end,
	[Enum.KeyCode.C] = function(_, p)
		return { Type = "SetMarker", Which = "Goal", Position = p }
	end,
	[Enum.KeyCode.LeftBracket] = function(self)
		return { Type = "SetAgentRadius", Radius = self._state.AgentRadius - RADIUS_STEP }
	end,
	[Enum.KeyCode.RightBracket] = function(self)
		return { Type = "SetAgentRadius", Radius = math.min(MAX_RADIUS, self._state.AgentRadius + RADIUS_STEP) }
	end,
	[Enum.KeyCode.T] = function(self)
		self._showTiles = not self._showTiles
		refresh(self, false)
		return nil
	end,
	[Enum.KeyCode.P] = function(self)
		print(self:ExportSource())
		return nil
	end,
}

NavMeshEditor._Keys = KEYS -- for the key-binding spec

-- The status bar and the radius slider (click or drag along the bar).
local function makeGui(self: EditorInternal, janitor: Janitor.Janitor, parent: Instance)
	local gui = janitor:Add(Instance.new("ScreenGui"), "Destroy")
	gui.Name = "NavMeshEditor"
	gui.ResetOnSpawn = false
	local status = Instance.new("TextLabel")
	status.Name = "Status"
	status.BackgroundColor3 = Color3.new(0, 0, 0)
	status.BackgroundTransparency = 0.3
	status.Font = Enum.Font.Code
	status.TextSize = 14
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.TextWrapped = true
	status.Position = UDim2.new(0, 8, 1, -64)
	status.Size = UDim2.new(1, -16, 0, 28)
	status.Parent = gui
	self._status = status

	local slider = Instance.new("Frame")
	slider.Name = "RadiusSlider"
	slider.Active = true
	slider.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
	slider.Position = UDim2.new(0, 8, 1, -30)
	slider.Size = UDim2.new(0, 240, 0, 18)
	slider.Parent = gui
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundColor3 = Color3.fromRGB(0, 200, 83)
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(0, 1)
	fill.Parent = slider
	self._radiusFill = fill
	local held = false
	local function setFromX(x: number)
		local alpha = math.clamp((x - slider.AbsolutePosition.X) / slider.AbsoluteSize.X, 0, 1)
		self:_apply { Type = "SetAgentRadius", Radius = math.round(alpha * MAX_RADIUS / RADIUS_STEP) * RADIUS_STEP }
	end
	janitor:Add(slider.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			held = true
			setFromX(input.Position.X)
		end
	end))
	janitor:Add(UserInputService.InputChanged:Connect(function(input: InputObject)
		if held and input.UserInputType == Enum.UserInputType.MouseMovement then
			setFromX(input.Position.X)
		end
	end))
	janitor:Add(UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			held = false
		end
	end))

	local player = Players.LocalPlayer
	local playerGui = if player then player:FindFirstChildOfClass("PlayerGui") else nil
	gui.Parent = playerGui or parent
end

local function connectInput(self: EditorInternal, janitor: Janitor.Janitor)
	janitor:Add(UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			local origin, direction = pointerRay()
			self:_apply { Type = "PointerDown", Origin = origin, Direction = direction }
			self._dragging = self._state.Selection ~= nil
		elseif input.UserInputType == Enum.UserInputType.Keyboard then
			local key = KEYS[input.KeyCode]
			local p = if key then pointerPosition(self) else nil
			local event = if key then key(self, p or vector.zero) else nil
			if event then
				self:_apply(event)
			end
		end
	end))
	janitor:Add(UserInputService.InputChanged:Connect(function(input: InputObject)
		if self._dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
			local origin, direction = pointerRay()
			self:_apply { Type = "Drag", Origin = origin, Direction = direction }
		end
	end))
	janitor:Add(UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 and self._dragging then
			self._dragging = false
			self:_apply { Type = "PointerUp" }
		end
	end))
end

--[=[
	@within NavMeshEditor
	Starts an editor drawing into a Folder under `parent`. `initial` is copied (default: a
	20-stud square). Errors if `initial` is not a description for `mode`.
]=]
function NavMeshEditor.new(parent: Instance, mode: EditorMode, initial: EditorDescription?): Editor
	local janitor = Janitor.new()
	local folder = janitor:Add(Instance.new("Folder"), "Destroy")
	folder.Name = "NavMeshEditor"
	local self: EditorInternal = setmetatable({
		Changed = Signal.new(janitor),
		_janitor = janitor,
		_state = EditorState.new(mode, initial),
		_renderer = janitor:Add(DrawListRenderer.new(folder), "Destroy"),
		_showTiles = true,
		_dragging = false,
	}, NavMeshEditor) :: any
	makeGui(self, janitor, folder)
	connectInput(self, janitor)
	folder.Parent = parent
	refresh(self, true)
	return self
end

--[=[
	@within NavMeshEditor
	A copy of the description being edited.
]=]
function NavMeshEditor.GetDescription(self: EditorInternal): EditorDescription
	return EditorState.Copy(self._state.Description)
end

--[=[
	@within NavMeshEditor
	The description as a Luau table literal, ready to paste into code or read back with
	`ImportSource`.
]=]
function NavMeshEditor.ExportSource(self: EditorInternal): string
	return LuauLiteral.Print(self._state.Description)
end

--[=[
	@within NavMeshEditor
	Reads a description printed by `ExportSource`. It does not use `loadstring`, so it works
	on a client. Errors, naming the line, on anything else.
]=]
function NavMeshEditor.ImportSource(source: string): EditorDescription
	return LuauLiteral.Parse(source)
end

--[=[
	@within NavMeshEditor
	Removes the drawing, the GUI and the input connections, and disconnects `Changed`.
]=]
function NavMeshEditor.Destroy(self: EditorInternal)
	self._janitor:Destroy()
end

return NavMeshEditor

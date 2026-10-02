--!strict
-- Authors: Logan Hunt (Raildex)
-- September 27, 2026
--[=[
	@class EditorState
	@private

	The editor's state machine: the description being edited, the selection, and the path
	markers. `Apply(state, event)` is the only way to change it. It touches no Instances or
	services and never yields, so specs drive it with synthetic events; `NavMeshEditor` maps
	mouse and key input onto the same events.

	Two modes:
	- `"NavMesh"` edits a `NavMeshDesc`: floor rings (walkable, obstacle, area), seams and
	  links.
	- `"CDT"` edits a `TriangulateInput`: points and directed constraint edges with groups.
	  A CDT point (x, y) sits at world (x, 0, y).

	Pointer events carry a world ray (`Origin`, `Direction`). A press selects the handle
	nearest the ray; a drag moves it across the horizontal plane at its own height. New
	positions snap to a quarter-stud grid, so exported numbers stay short.

	`Apply` mutates `state` and returns whether the description changed. It errors on an
	unknown event or one that does not fit the mode (such as a seam in CDT mode); the editor
	shows that message instead of crashing.
]=]

export type Mode = "CDT" | "NavMesh"

--[=[
	@within EditorState
	@interface Handle
	.Kind "Vertex" | "Seam" | "Link" | "Marker" | "Coord"
	.Floor string? -- Vertex: the floor
	.List string? -- Vertex: "Walkable", "Obstacles" or "Areas"
	.Ring number? -- Vertex: the ring's index in that list
	.Index number? -- Vertex: the vertex in the ring; Seam/Link: the entry; Coord: the point
	.End string? -- Seam/Link: "From" or "To"
	.Which string? -- Marker: "Start" or "Goal"

	Something the pointer can grab.
]=]
export type Handle = {
	Kind: string,
	Floor: string?,
	List: string?,
	Ring: number?,
	Index: number?,
	End: string?,
	Which: string?,
}

--[=[
	@within EditorState
	@interface State
	.Mode Mode
	.Description any -- a NavMeshDesc or a TriangulateInput, owned by the state
	.Selection Handle?
	.Start vector? -- path start marker
	.Goal vector? -- path goal marker
	.AgentRadius number
	.Proposed { any }? -- links shown but not yet in the description (ProposeLinks); any edit drops them
]=]
export type State = {
	Mode: Mode,
	Description: any,
	Selection: Handle?,
	Start: vector?,
	Goal: vector?,
	AgentRadius: number,
	Proposed: { any }?,
}

--[=[
	@within EditorState
	@interface Event
	.Type string
	.Origin vector? -- PointerDown, Drag: the pointer ray
	.Direction vector?
	.PickRadius number? -- PointerDown: how close the ray must pass (default 1 stud)
	.Position vector? -- CreateRing, SetMarker
	.From vector? -- CreateEdge, CreateSeam, CreateLink
	.To vector?
	.Kind string? -- CreateRing: "Walkable", "Obstacle" or "Area"
	.Floor string? -- CreateRing (default: the selected floor, else the first)
	.FloorA string? -- CreateSeam (default: the selected floor, else the first)
	.FloorB string? -- CreateSeam (default: the first other floor)
	.Size number? -- CreateRing: square side (default 4)
	.Area number? -- CreateRing "Area": area id (default 2)
	.Group number? -- CreateRing in CDT mode (default: Walkable 1, Obstacle 2, Area 3)
	.Bidirectional boolean? -- CreateLink (default true)
	.Label string? -- CreateLink
	.Which string? -- SetMarker: "Start" or "Goal"
	.Radius number? -- SetAgentRadius
	.Description any? -- SetDescription
	.Links { any }? -- ProposeLinks: the LinkDescs to show (from NavMesh.GenerateLinks)

	Types: `PointerDown`, `Drag`, `PointerUp`, `CreateRing`, `CreateEdge` (CDT),
	`CreateSeam` (NavMesh), `CreateLink` (NavMesh), `InsertVertex`, `Delete`, `SetMarker`,
	`SetAgentRadius`, `SetDescription`, `ProposeLinks` and `CommitLinks` (NavMesh: show links,
	then add them to the description).
]=]
export type Event = {
	Type: string,
	Origin: vector?,
	Direction: vector?,
	PickRadius: number?,
	Position: vector?,
	From: vector?,
	To: vector?,
	Kind: string?,
	Floor: string?,
	FloorA: string?,
	FloorB: string?,
	Size: number?,
	Area: number?,
	Group: number?,
	Bidirectional: boolean?,
	Label: string?,
	Which: string?,
	Radius: number?,
	Description: any?,
	Links: { any }?,
}

local GRID = 0.25
local DEFAULT_PICK_RADIUS = 1
local DEFAULT_RING_SIZE = 4
local RING_LISTS = { "Walkable", "Obstacles", "Areas" }
local CDT_GROUPS = { Walkable = 1, Obstacle = 2, Area = 3 }

local EditorState = {}

--[=[
	@within EditorState
	Deep-copies plain data (vectors are values, so they are shared).
]=]
function EditorState.Copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, item in value do
		out[key] = EditorState.Copy(item)
	end
	return out
end

local function defaultDescription(mode: Mode): any
	if mode == "CDT" then
		return {
			Coords = { 0, 0, 20, 0, 20, 20, 0, 20 },
			Edges = { 1, 2, 2, 3, 3, 4, 4, 1 },
			EdgeGroups = { 1, 1, 1, 1 },
		}
	end
	return {
		Floors = {
			Ground = {
				Walkable = {
					{
						vector.create(0, 0, 0),
						vector.create(20, 0, 0),
						vector.create(20, 0, 20),
						vector.create(0, 0, 20),
					},
				},
			},
		},
	}
end

--[=[
	@within EditorState
	A state editing a copy of `description` (default: a 20-stud square).
]=]
-- Errors unless `description` has the shape `mode` edits (so Handles never indexes nil).
local function checkShape(mode: Mode, description: any)
	local field = if mode == "CDT" then "Coords" else "Floors"
	if type(description) ~= "table" or type(description[field]) ~= "table" then
		error(`EditorState: a {mode} description needs a {field} table`, 0)
	end
end

function EditorState.new(mode: Mode, description: any?): State
	assert(mode == "NavMesh" or mode == "CDT", `EditorState: unknown mode {tostring(mode)}`)
	if description ~= nil then
		checkShape(mode, description)
	end
	return {
		Mode = mode,
		Description = if description ~= nil then EditorState.Copy(description) else defaultDescription(mode),
		Selection = nil,
		Start = nil,
		Goal = nil,
		AgentRadius = 0,
	}
end

local function snap(v: number): number
	return math.round(v / GRID) * GRID
end

local function sortedFloors(desc: any): { string }
	local names = {}
	for floorName in desc.Floors do
		table.insert(names, floorName)
	end
	table.sort(names)
	return names
end

-- The ring (a list of vectors) a Vertex handle points into.
local function ringOf(desc: any, h: Handle): { vector }
	local ring = desc.Floors[h.Floor][h.List :: string][h.Ring :: number]
	if h.List == "Areas" then
		return ring.Polygon
	end
	return ring
end

--[=[
	@within EditorState
	Every handle in the state, in a stable order: ring vertices (floors sorted by name),
	seam and link ends, CDT points, then markers.
]=]
function EditorState.Handles(state: State): { Handle }
	local desc = state.Description
	local out: { Handle } = {}
	if state.Mode == "CDT" then
		for i = 1, #desc.Coords // 2 do
			table.insert(out, { Kind = "Coord", Index = i })
		end
	else
		for _, floorName in sortedFloors(desc) do
			local floor = desc.Floors[floorName]
			for _, list in RING_LISTS do
				for r, ring in floor[list] or {} do
					local points = if list == "Areas" then ring.Polygon else ring
					for i = 1, #points do
						table.insert(out, { Kind = "Vertex", Floor = floorName, List = list, Ring = r, Index = i })
					end
				end
			end
		end
		for _, kind in { "Seam", "Link" } do
			for i = 1, #(desc[kind .. "s"] or {}) do
				table.insert(out, { Kind = kind, Index = i, End = "From" })
				table.insert(out, { Kind = kind, Index = i, End = "To" })
			end
		end
	end
	if state.Start then
		table.insert(out, { Kind = "Marker", Which = "Start" })
	end
	if state.Goal then
		table.insert(out, { Kind = "Marker", Which = "Goal" })
	end
	return out
end

--[=[
	@within EditorState
	Where a handle is, in world space.
]=]
function EditorState.HandlePosition(state: State, h: Handle): vector
	local desc = state.Description
	if h.Kind == "Coord" then
		local i = h.Index :: number
		return vector.create(desc.Coords[2 * i - 1], 0, desc.Coords[2 * i])
	elseif h.Kind == "Vertex" then
		return ringOf(desc, h)[h.Index :: number]
	elseif h.Kind == "Seam" or h.Kind == "Link" then
		return desc[h.Kind .. "s"][h.Index :: number][h.End :: string]
	end
	return (if h.Which == "Start" then state.Start else state.Goal) :: vector
end

local function setHandlePosition(state: State, h: Handle, p: vector)
	local desc = state.Description
	if h.Kind == "Coord" then
		local i = h.Index :: number
		desc.Coords[2 * i - 1], desc.Coords[2 * i] = p.X, p.Z
	elseif h.Kind == "Vertex" then
		ringOf(desc, h)[h.Index :: number] = p
	elseif h.Kind == "Seam" or h.Kind == "Link" then
		desc[h.Kind .. "s"][h.Index :: number][h.End :: string] = p
	elseif h.Which == "Start" then
		state.Start = p
	else
		state.Goal = p
	end
end

--[=[
	@within EditorState
	Where a pointer ray meets the horizontal plane at `height`, or nil when it runs parallel
	to the plane or points away from it.
]=]
function EditorState.RayToPlane(origin: vector, direction: vector, height: number): vector?
	if math.abs(direction.Y) < 1e-9 then
		return nil
	end
	local t = (height - origin.Y) / direction.Y
	if t < 0 then
		return nil
	end
	local hit = origin + direction * t
	return vector.create(snap(hit.X), height, snap(hit.Z))
end

local function pick(state: State, origin: vector, direction: vector, radius: number): Handle?
	local best, bestDistance = nil, radius
	local lengthSquared = vector.dot(direction, direction)
	for _, h in EditorState.Handles(state) do
		local p = EditorState.HandlePosition(state, h)
		local t = math.max(0, vector.dot(p - origin, direction) / lengthSquared)
		local distance = vector.magnitude(origin + direction * t - p)
		if distance <= bestDistance then
			best, bestDistance = h, distance
		end
	end
	return best
end

local function need<T>(value: T?, field: string, eventType: string): T
	if value == nil then
		error(`EditorState: {eventType} needs {field}`, 0)
	end
	return value
end

local function requireMode(state: State, mode: Mode, eventType: string)
	if state.Mode ~= mode then
		error(`EditorState: {eventType} is only for {mode} mode`, 0)
	end
end

local function square(center: vector, size: number): { vector }
	local h = size / 2
	local x, y, z = snap(center.X), center.Y, snap(center.Z)
	return {
		vector.create(x - h, y, z - h),
		vector.create(x + h, y, z - h),
		vector.create(x + h, y, z + h),
		vector.create(x - h, y, z + h),
	}
end

local function selectedFloor(state: State): string?
	local s = state.Selection
	return if s and s.Kind == "Vertex" then s.Floor else nil
end

local function createRing(state: State, event: Event)
	local center = need(event.Position, "Position", "CreateRing")
	local kind = need(event.Kind, "Kind", "CreateRing")
	local size = event.Size or DEFAULT_RING_SIZE
	local ring = square(center, size)
	local desc = state.Description
	if state.Mode == "CDT" then
		local group = event.Group or CDT_GROUPS[kind] or error(`EditorState: unknown ring Kind {kind}`, 0)
		local base = #desc.Coords // 2
		desc.Edges = desc.Edges or {}
		desc.EdgeGroups = desc.EdgeGroups or {}
		for i, p in ring do
			table.insert(desc.Coords, p.X)
			table.insert(desc.Coords, p.Z)
			table.insert(desc.Edges, base + i)
			table.insert(desc.Edges, base + i % 4 + 1)
			table.insert(desc.EdgeGroups, group)
		end
		state.Selection = { Kind = "Coord", Index = base + 1 }
		return
	end
	local floorName = event.Floor or selectedFloor(state) or sortedFloors(desc)[1] or "Ground"
	desc.Floors[floorName] = desc.Floors[floorName] or { Walkable = {} }
	local floor = desc.Floors[floorName]
	local list
	if kind == "Walkable" then
		list = "Walkable"
		table.insert(floor.Walkable, ring)
	elseif kind == "Obstacle" then
		list = "Obstacles"
		floor.Obstacles = floor.Obstacles or {}
		table.insert(floor.Obstacles, ring)
	elseif kind == "Area" then
		list = "Areas"
		floor.Areas = floor.Areas or {}
		table.insert(floor.Areas, { Polygon = ring, Area = event.Area or 2 })
	else
		error(`EditorState: unknown ring Kind {kind}`, 0)
	end
	state.Selection = { Kind = "Vertex", Floor = floorName, List = list, Ring = #floor[list], Index = 1 }
end

-- CDT: the edges into and out of point i, as indices into the edge list (1-based pairs).
local function edgesAt(desc: any, i: number): ({ number }, { number })
	local incoming, outgoing = {}, {}
	local edges = desc.Edges or {}
	for e = 1, #edges // 2 do
		if edges[2 * e] == i then
			table.insert(incoming, e)
		end
		if edges[2 * e - 1] == i then
			table.insert(outgoing, e)
		end
	end
	return incoming, outgoing
end

local function removeEdge(desc: any, e: number)
	table.remove(desc.Edges, 2 * e)
	table.remove(desc.Edges, 2 * e - 1)
	if desc.EdgeGroups then
		table.remove(desc.EdgeGroups, e)
	end
end

-- CDT: removes point i. A ring through it is closed again by joining its neighbours.
local function deleteCoord(desc: any, i: number)
	local incoming, outgoing = edgesAt(desc, i)
	local edges = desc.Edges or {}
	if #incoming == 1 and #outgoing == 1 then
		local a, b = edges[2 * incoming[1] - 1], edges[2 * outgoing[1]]
		if a ~= b then
			edges[2 * incoming[1]] = b -- a -> i becomes a -> b
			table.remove(incoming, 1)
		end
	end
	local dead = {}
	for _, e in incoming do
		dead[e] = true
	end
	for _, e in outgoing do
		dead[e] = true
	end
	for e = #edges // 2, 1, -1 do
		if dead[e] then
			removeEdge(desc, e)
		end
	end
	table.remove(desc.Coords, 2 * i)
	table.remove(desc.Coords, 2 * i - 1)
	for k, v in edges do
		if v > i then
			edges[k] = v - 1
		end
	end
end

local function delete(state: State): boolean
	local h = state.Selection
	if h == nil then
		return false
	end
	state.Selection = nil
	local desc = state.Description
	if h.Kind == "Marker" then
		if h.Which == "Start" then
			state.Start = nil
		else
			state.Goal = nil
		end
		return false
	elseif h.Kind == "Coord" then
		deleteCoord(desc, h.Index :: number)
	elseif h.Kind == "Seam" or h.Kind == "Link" then
		table.remove(desc[h.Kind .. "s"], h.Index :: number)
	else
		local ring = ringOf(desc, h)
		table.remove(ring, h.Index :: number)
		if #ring < 3 then
			table.remove(desc.Floors[h.Floor][h.List :: string], h.Ring :: number)
		end
	end
	return true
end

local function insertVertex(state: State): boolean
	local h = state.Selection
	local desc = state.Description
	if h and h.Kind == "Vertex" then
		local ring = ringOf(desc, h)
		local i = h.Index :: number
		local a, b = ring[i], ring[i % #ring + 1]
		table.insert(ring, i + 1, vector.create(snap((a.X + b.X) / 2), (a.Y + b.Y) / 2, snap((a.Z + b.Z) / 2)))
		state.Selection = { Kind = "Vertex", Floor = h.Floor, List = h.List, Ring = h.Ring, Index = i + 1 }
		return true
	elseif h and h.Kind == "Coord" then
		local i = h.Index :: number
		local _, outgoing = edgesAt(desc, i)
		local e = outgoing[1]
		if e == nil then
			return false
		end
		local b = desc.Edges[2 * e]
		local coords = desc.Coords
		table.insert(coords, snap((coords[2 * i - 1] + coords[2 * b - 1]) / 2))
		table.insert(coords, snap((coords[2 * i] + coords[2 * b]) / 2))
		local new = #coords // 2
		desc.Edges[2 * e] = new -- i -> b becomes i -> new -> b
		table.insert(desc.Edges, new)
		table.insert(desc.Edges, b)
		if desc.EdgeGroups then
			table.insert(desc.EdgeGroups, desc.EdgeGroups[e])
		end
		state.Selection = { Kind = "Coord", Index = new }
		return true
	end
	return false
end

-- One event; whether the description changed.
local function apply(state: State, event: Event): boolean
	local t = event.Type
	local desc = state.Description
	if t == "PointerDown" then
		local origin = need(event.Origin, "Origin", t)
		local direction = need(event.Direction, "Direction", t)
		state.Selection = pick(state, origin, direction, event.PickRadius or DEFAULT_PICK_RADIUS)
		return false
	elseif t == "Drag" then
		local h = state.Selection
		if h == nil then
			return false
		end
		local old = EditorState.HandlePosition(state, h)
		local hit =
			EditorState.RayToPlane(need(event.Origin, "Origin", t), need(event.Direction, "Direction", t), old.Y)
		if hit == nil or hit == old then
			return false
		end
		setHandlePosition(state, h, hit)
		return h.Kind ~= "Marker"
	elseif t == "PointerUp" then
		return false
	elseif t == "CreateRing" then
		createRing(state, event)
		return true
	elseif t == "CreateEdge" then
		requireMode(state, "CDT", t)
		local from, to = need(event.From, "From", t), need(event.To, "To", t)
		local base = #desc.Coords // 2
		table.insert(desc.Coords, snap(from.X))
		table.insert(desc.Coords, snap(from.Z))
		table.insert(desc.Coords, snap(to.X))
		table.insert(desc.Coords, snap(to.Z))
		desc.Edges = desc.Edges or {}
		table.insert(desc.Edges, base + 1)
		table.insert(desc.Edges, base + 2)
		if desc.EdgeGroups then
			table.insert(desc.EdgeGroups, 0)
		elseif #desc.Edges > 2 then
			-- Groups default to 1; an open edge needs group 0, so write every group out.
			desc.EdgeGroups = table.create(#desc.Edges // 2 - 1, 1)
			table.insert(desc.EdgeGroups, 0)
		else
			desc.EdgeGroups = { 0 }
		end
		state.Selection = { Kind = "Coord", Index = base + 2 }
		return true
	elseif t == "CreateSeam" then
		requireMode(state, "NavMesh", t)
		local floors = sortedFloors(desc)
		local a = event.FloorA or selectedFloor(state) or floors[1]
		local b = event.FloorB
		if b == nil then
			for _, floorName in floors do
				if floorName ~= a then
					b = floorName
					break
				end
			end
		end
		if a == nil or b == nil then
			error("EditorState: CreateSeam needs two floors", 0)
		end
		desc.Seams = desc.Seams or {}
		table.insert(
			desc.Seams,
			{ FloorA = a, FloorB = b, From = need(event.From, "From", t), To = need(event.To, "To", t) }
		)
		state.Selection = { Kind = "Seam", Index = #desc.Seams, End = "To" }
		return true
	elseif t == "CreateLink" then
		requireMode(state, "NavMesh", t)
		desc.Links = desc.Links or {}
		table.insert(desc.Links, {
			From = need(event.From, "From", t),
			To = need(event.To, "To", t),
			Bidirectional = if event.Bidirectional == false then false else nil,
			Label = event.Label,
		})
		state.Selection = { Kind = "Link", Index = #desc.Links, End = "To" }
		return true
	elseif t == "InsertVertex" then
		return insertVertex(state)
	elseif t == "Delete" then
		return delete(state)
	elseif t == "SetMarker" then
		local which = need(event.Which, "Which", t)
		if which == "Start" then
			state.Start = need(event.Position, "Position", t)
		elseif which == "Goal" then
			state.Goal = need(event.Position, "Position", t)
		else
			error(`EditorState: unknown marker {which}`, 0)
		end
		state.Selection = { Kind = "Marker", Which = which }
		return false
	elseif t == "SetAgentRadius" then
		state.AgentRadius = math.max(0, need(event.Radius, "Radius", t))
		return false
	elseif t == "SetDescription" then
		local description = need(event.Description, "Description", t)
		checkShape(state.Mode, description)
		state.Description = EditorState.Copy(description)
		state.Selection = nil
		return true
	elseif t == "ProposeLinks" then
		requireMode(state, "NavMesh", t)
		state.Proposed = EditorState.Copy(need(event.Links, "Links", t))
		return false
	elseif t == "CommitLinks" then
		requireMode(state, "NavMesh", t)
		local proposed = state.Proposed
		if proposed == nil or #proposed == 0 then
			return false
		end
		desc.Links = desc.Links or {}
		table.move(proposed, 1, #proposed, #desc.Links + 1, desc.Links)
		return true
	end
	error(`EditorState: unknown event Type "{tostring(t)}"`, 0)
end

--[=[
	@within EditorState
	Applies one event to `state` and returns whether the description changed. A change drops
	the proposed links: they were generated from the description before it.
]=]
function EditorState.Apply(state: State, event: Event): boolean
	local changed = apply(state, event)
	if changed then
		state.Proposed = nil
	end
	return changed
end

return EditorState

--!strict
-- Map scenario harness (ticket 33). A map builds Parts; the harness turns them into a mesh
-- through NavMeshAdapter, runs the map's scenarios with FindPath and checks each scenario's
-- expectations. It needs no Lune or Studio library, so run.luau (Lune) and Studio.luau (Studio)
-- both use it: they pass in NavMesh, the adapter and `rbx` (Instance, Vector3, CFrame, Color3,
-- Enum).
--
-- A map module (maps/<Name>.luau) returns a Map. See maps/FlatLot.luau, and ticket 33's as-built
-- notes for the conventions.

type Rbx = { Instance: any, Vector3: any, CFrame: any, Color3: any, Enum: any }

export type Built = {
	Walkable: { BasePart },
	Obstacles: { BasePart },
	Points: { [string]: Vector3 }, -- named spots: spawns, goals
	Links: { any }?, -- NavMesh LinkDesc list
	Extra: any?, -- anything else the map's Animate needs (an elevator cab Part)
}

-- Every field is optional; a scenario with none only checks that FindPath runs.
export type Expect = {
	Status: string?, -- the PathStatus
	Floors: { string }?, -- the floors visited, in order (repeats collapsed)
	Visits: { string }?, -- floors the path must visit in this order, among others (a stair's landing)
	Links: { string }?, -- the labels of the links used, in order
	Avoids: { number | string }?, -- areas no path segment may enter: ids, or names from the adapter's table
	MaxStretch: number?, -- Length <= this x the straight line from From to To
	MinLength: number?, -- studs: "goes the long way"
	MaxLength: number?, -- studs: a reference path's length, plus slack
}

export type Scenario = {
	Name: string,
	From: string, -- a point name
	To: string,
	Filter: any?, -- the QueryFilter, or a function of the adapter's area-name table returning it
	Expect: Expect?,
	DisabledLinks: { string }?, -- labels of links switched off for this scenario (an elevator out of service)
	-- A negative control: the scenario passes only if exactly this expectation fails.
	MustFail: string?,
}

export type Map = {
	Name: string,
	MaxAgentRadius: number?, -- default 2
	AdapterOptions: any?,
	Build: (rbx: Rbx, parent: Instance?) -> Built,
	Scenarios: { Scenario },
	View: { From: { number }, To: { number } }?, -- Studio camera; default: straight down over the map
	-- Studio only: called once after drawing; returns a step function run every frame for the
	-- hold (NPCs walking). See Maps/BuildingElevator.luau.
	Animate: ((report: any, NavMesh: any, rbx: Rbx, parent: Instance) -> (dt: number) -> ())?,
	SeeThrough: { string }?, -- names of Parts Studio draws see-through (an upper floor over a stair)
}

export type Row = {
	Scenario: Scenario,
	Path: any, -- the PathResult
	Failed: { string }, -- the expectations that failed, each with why
	Pass: boolean,
	Ms: number, -- FindPath, best of 3
}

export type Report = {
	Map: Map,
	Built: Built,
	Desc: any,
	Areas: { [string]: number }, -- the adapter's area-name table
	Mesh: any,
	Rows: { Row },
	FromPartsMs: number,
	BuildMs: number,
	Triangles: number,
	Floors: number,
	Seams: number,
	BakeBytes: number,
	Pass: boolean,
}

local function v(p: any): vector
	return vector.create(p.X, p.Y, p.Z)
end

local function insidePolygon(x: number, z: number, ring: { any }): boolean
	local hit = false
	for i, a in ring do
		local b = ring[i % #ring + 1]
		if (a.Z > z) ~= (b.Z > z) and x < a.X + (z - a.Z) / (b.Z - a.Z) * (b.X - a.X) then
			hit = not hit
		end
	end
	return hit
end

local function edgeDistance(x: number, z: number, ring: { any }): number
	local best = math.huge
	for i, a in ring do
		local b = ring[i % #ring + 1]
		local dx, dz = b.X - a.X, b.Z - a.Z
		local t = math.clamp(((x - a.X) * dx + (z - a.Z) * dz) / (dx * dx + dz * dz), 0, 1)
		best = math.min(best, math.sqrt((x - a.X - dx * t) ^ 2 + (z - a.Z - dz * t) ^ 2))
	end
	return best
end

-- Does the segment a-b enter an area with this id, on any floor at its height? Not only the
-- end waypoints' floors: a segment between two curb strips lies on the road. Walking an area's
-- edge doesn't count; the height test is the area's Y range (exact for flat areas).
-- ponytail: samples every 0.25 studs; exact clipping if a sliver area ever slips between samples.
local function entersArea(desc: any, a: vector, b: vector, id: number): boolean
	local steps = math.max(1, math.ceil(vector.magnitude(b - a) / 0.25))
	for _, floor in desc.Floors do
		for _, area in floor.Areas or {} do
			if area.Area ~= id then
				continue
			end
			local lo, hi = math.huge, -math.huge
			for _, q in area.Polygon do
				lo, hi = math.min(lo, q.Y), math.max(hi, q.Y)
			end
			for k = 0, steps do
				local p = a + (b - a) * (k / steps)
				if
					p.y >= lo - 0.05
					and p.y <= hi + 0.05
					and insidePolygon(p.x, p.z, area.Polygon)
					and edgeDistance(p.x, p.z, area.Polygon) > 0.05
				then
					return true
				end
			end
		end
	end
	return false
end

local function list(t: { any }): string
	local parts = {}
	for _, x in t do
		table.insert(parts, tostring(x))
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end

local function same(a: { any }, b: { any }): boolean
	if #a ~= #b then
		return false
	end
	for i, x in a do
		if b[i] ~= x then
			return false
		end
	end
	return true
end

-- The expectations a path fails, each as "Name: why".
local function check(e: Expect, path: any, desc: any, areas: { [string]: number }, from: vector, to: vector): { string }
	local failed = {}
	if e.Status and path.Status ~= e.Status then
		table.insert(failed, `Status: got {path.Status}, want {e.Status}`)
	end
	local floors, links = {}, {}
	for _, w in path.Waypoints do
		if floors[#floors] ~= w.Floor then
			table.insert(floors, w.Floor)
		end
		if w.Label then
			table.insert(links, w.Label)
		end
	end
	if e.Floors and not same(floors, e.Floors) then
		table.insert(failed, `Floors: got {list(floors)}, want {list(e.Floors)}`)
	end
	if e.Visits then
		local k = 1
		for _, f in floors do
			if f == e.Visits[k] then
				k += 1
			end
		end
		if k <= #e.Visits then
			table.insert(failed, `Visits: {e.Visits[k]} missing (in order) from {list(floors)}`)
		end
	end
	if e.Links and not same(links, e.Links) then
		table.insert(failed, `Links: got {list(links)}, want {list(e.Links)}`)
	end
	for _, avoid in e.Avoids or {} do
		local id = if type(avoid) == "string" then assert(areas[avoid], `no area named {avoid}`) else avoid
		local w = path.Waypoints
		for i = 2, #w do
			if w[i - 1].Label == nil then -- a link's hop is not walked
				local a, b = v(w[i - 1].Position), v(w[i].Position)
				if entersArea(desc, a, b, id) then
					table.insert(failed, `Avoids: segment {i - 1}-{i} enters area {id}`)
					break
				end
			end
		end
	end
	local straight = vector.magnitude(to - from)
	if e.MaxStretch and path.Length > e.MaxStretch * straight then
		table.insert(
			failed,
			string.format("MaxStretch: %.2f x straight, want <= %.2f", path.Length / straight, e.MaxStretch)
		)
	end
	if e.MinLength and path.Length < e.MinLength then
		table.insert(failed, string.format("MinLength: %.1f, want >= %.1f", path.Length, e.MinLength))
	end
	if e.MaxLength and path.Length > e.MaxLength then
		table.insert(failed, string.format("MaxLength: %.1f, want <= %.1f", path.Length, e.MaxLength))
	end
	return failed
end

local Harness = {}

-- Builds the map (Parts under `parent`, if given), its mesh, and runs every scenario.
function Harness.Run(map: Map, NavMesh: any, Adapter: any, rbx: Rbx, parent: Instance?): Report
	local built = map.Build(rbx, parent)
	local t0 = os.clock()
	local desc, areas = Adapter.FromParts(built.Walkable, built.Obstacles, map.AdapterOptions)
	local fromPartsMs = (os.clock() - t0) * 1000
	desc.MaxAgentRadius = map.MaxAgentRadius or 2
	desc.Links = built.Links
	t0 = os.clock()
	local mesh = NavMesh.Build(desc)
	local buildMs = (os.clock() - t0) * 1000

	local floors = 0
	for _ in desc.Floors do
		floors += 1
	end
	local report: Report = {
		Map = map,
		Built = built,
		Desc = desc,
		Areas = areas,
		Mesh = mesh,
		Rows = {},
		FromPartsMs = fromPartsMs,
		BuildMs = buildMs,
		Triangles = mesh.TriangleCount,
		Floors = floors,
		Seams = #(desc.Seams or {}),
		BakeBytes = buffer.len(NavMesh.Serialize(mesh)),
		Pass = true,
	}
	for _, s in map.Scenarios do
		local from, to = built.Points[s.From], built.Points[s.To]
		assert(from and to, `{map.Name}/{s.Name}: unknown point {if from then s.To else s.From}`)
		local off = {}
		for id, link in desc.Links or {} do
			if table.find(s.DisabledLinks or {}, link.Label) then
				table.insert(off, id)
				NavMesh.SetLinkEnabled(mesh, id, false)
			end
		end
		local filter = if type(s.Filter) == "function" then s.Filter(areas) else s.Filter
		local path, best = nil, math.huge
		for _ = 1, 3 do
			t0 = os.clock()
			path = NavMesh.FindPath(mesh, from, to, filter)
			best = math.min(best, os.clock() - t0)
		end
		for _, id in off do
			NavMesh.SetLinkEnabled(mesh, id, true)
		end
		local failed = check(s.Expect or {}, path, desc, areas, v(from), v(to))
		local pass = #failed == 0
		if s.MustFail then
			pass = #failed == 1 and string.find(failed[1], s.MustFail .. ":", 1, true) == 1
		end
		report.Pass = report.Pass and pass
		table.insert(report.Rows, { Scenario = s, Path = path, Failed = failed, Pass = pass, Ms = best * 1000 })
	end
	return report
end

local function pad(s: string, n: number): string
	return s .. string.rep(" ", n - #s)
end

-- The report as text: one line per scenario, then the map's numbers.
function Harness.Format(r: Report): string
	local width = 8
	for _, row in r.Rows do
		width = math.max(width, #row.Scenario.Name)
	end
	local lines = { `== {r.Map.Name}`, `{pad("scenario", width)}  result  status   length    ms  failed` }
	for _, row in r.Rows do
		local result = if row.Pass then (if row.Scenario.MustFail then "pass*" else "pass") else "FAIL"
		table.insert(
			lines,
			string.format(
				"%s  %-6s  %-7s %7.1f %6.3f  %s",
				pad(row.Scenario.Name, width),
				result,
				row.Path.Status,
				row.Path.Length,
				row.Ms,
				table.concat(row.Failed, "; ")
			)
		)
	end
	table.insert(
		lines,
		string.format(
			"FromParts %.1f ms, Build %.1f ms; %d triangles, %d floors, %d seams; bake %d bytes",
			r.FromPartsMs,
			r.BuildMs,
			r.Triangles,
			r.Floors,
			r.Seams,
			r.BakeBytes
		)
	)
	table.insert(lines, if r.Pass then "MAP PASS" else "MAP FAIL")
	return table.concat(lines, "\n")
end

return Harness

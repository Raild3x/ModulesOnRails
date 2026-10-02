--!strict
-- The Studio side of the map harness: builds the map's Parts in workspace, runs its scenarios
-- (Harness), prints the table, and draws the mesh and every scenario's path for `Hold` seconds.
-- Then it clears the drawing and holds again, so studio.py's second capture (taken then) must
-- differ from the first: the screenshot's negative control.
--
-- While it holds:
-- - Links are arrows: drops white, jumps green arcs, others (stairs, elevators) purple; an
--   arrowhead at each end a link can be taken from.
-- - A map with AreaColors draws its mesh by area (a legend in the corner, with each area's cost
--   in the map's Filter); others by floor.
-- - Start and Goal (green and red balls) are a path probe: drag either and the path between them
--   is drawn again (magenta) with its status on Goal. Start's attributes change the query:
--   AgentRadius, Costs (the map's Filter's area costs), Links (all links on or off), Scenarios
--   (show the scenarios' paths).
-- - `Tour` (from studio.py --tour) moves the camera through views, printing "[MARK] view <tag>"
--   at each, so studio.py captures each one. A stop can also place Start and Goal, set Start's
--   attributes, and set the Parts' transparency (Parts = 1 shows the mesh alone).

local PATH_COLORS = { "#2ee640", "#ff3b30", "#2f8cff", "#ffd60a", "#bf5af2", "#ff9f0a", "#64d2ff", "#ff375f" }
local LINK_COLORS = { Drop = "#ffffff", Jump = "#00ff66" }
local LINK_COLOR = "#a020f0"
local PROBE_COLOR = "#ff00ff"
local Draw = require("./Draw")
local DEFAULT_AREA_COLOR = Draw.DEFAULT_AREA_COLOR

type Stop = {
	Tag: string,
	From: { number },
	To: { number },
	Start: { number }?,
	Goal: { number }?,
	Attributes: { [string]: any }?,
	Parts: number?, -- transparency of the map's Parts at this stop (default as built)
}

local function hex(rgb: { number }): string
	return string.format("#%02x%02x%02x", rgb[1], rgb[2], rgb[3])
end

-- The legend: each area's colour, name and cost; the link and probe colours.
local function legend(map: any, areas: { [string]: number }, filter: any?): Instance
	local gui = Instance.new("ScreenGui")
	gui.Name = "NavMeshLegend"
	local frame = Instance.new("Frame")
	frame.Position = UDim2.fromOffset(12, 12)
	frame.AutomaticSize = Enum.AutomaticSize.XY
	frame.BackgroundColor3 = Color3.new(0, 0, 0)
	frame.BackgroundTransparency = 0.35
	frame.Parent = gui
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 2)
	layout.Parent = frame
	local pad = Instance.new("UIPadding")
	for _, side in { "PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight" } do
		(pad :: any)[side] = UDim.new(0, 6)
	end
	pad.Parent = frame
	local function row(color: string, text: string)
		local label = Instance.new("TextLabel")
		label.AutomaticSize = Enum.AutomaticSize.X
		label.Size = UDim2.fromOffset(0, 18)
		label.BackgroundTransparency = 1
		label.RichText = true
		label.Font = Enum.Font.Code
		label.TextSize = 15
		label.TextColor3 = Color3.new(1, 1, 1)
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Text = `<font color="{color}">■■</font> {text}`
		label.Parent = frame
	end
	local costs = filter and filter.AreaCosts or {}
	row(DEFAULT_AREA_COLOR, "ground  cost 1")
	local names = {}
	for name in map.AreaColors do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		local cost = costs[areas[name] or -1] or 1
		row(
			map.AreaColors[name],
			string.format("%-7s cost %s", name, if cost == math.huge then "never" else tostring(cost))
		)
	end
	row(LINK_COLORS.Drop, "drop (one way)")
	row(LINK_COLORS.Jump, "jump")
	row(PROBE_COLOR, "Start → Goal (drag them)")
	return gui
end

-- A baked map: its Parts built here, the mesh, links and scenario paths from bake.luau (whose
-- table, printed in Lune, is printed again).
local function loadBaked(map: any, NavMesh: any, baked: any, rbx: any, folder: Instance): any
	local data = require(baked.Data) :: any
	print(data.Text)
	local hex = baked.Mesh.Value
	local bytes = buffer.create(#hex // 2)
	for i = 0, #hex // 2 - 1 do
		buffer.writeu8(bytes, i, tonumber(string.sub(hex, 2 * i + 1, 2 * i + 2), 16) :: number)
		if i % 500000 == 0 then
			task.wait() -- under the watchdog
		end
	end
	local function v3(p: { number }): Vector3
		return Vector3.new(p[1], p[2], p[3])
	end
	local links = {}
	for _, link in data.Links do
		table.insert(
			links,
			{ From = v3(link.From), To = v3(link.To), Label = link.Label, Bidirectional = link.Bidirectional }
		)
	end
	local rows = {}
	for _, waypoints in data.Paths do
		local path = { Waypoints = {} }
		for _, w in waypoints do
			table.insert(path.Waypoints, { Position = v3(w.Position), Label = w.Label })
		end
		table.insert(rows, { Path = path })
	end
	return {
		Built = map.Build(rbx, folder),
		Mesh = NavMesh.Deserialize(bytes),
		Desc = { Links = links },
		Areas = data.Areas,
		Rows = rows,
	}
end

return function(
	o: {
		NavMesh: any,
		Adapter: any,
		Renderer: any,
		Harness: any,
		Map: any,
		Hold: number,
		Tour: { Stop }?,
		Dwell: number?,
		Baked: Instance?, -- bake.luau's output (Mesh, a StringValue, and Data), for a map with Bake = true
	}
)
	local folder = Instance.new("Folder")
	folder.Name = o.Map.Name
	folder.Parent = workspace
	local rbx = { Instance = Instance, Vector3 = Vector3, CFrame = CFrame, Color3 = Color3, Enum = Enum }
	local report
	if o.Baked then
		report = loadBaked(o.Map, o.NavMesh, o.Baked, rbx, folder)
	else
		report = o.Harness.Run(o.Map, o.NavMesh, o.Adapter, rbx, folder)
		print(o.Harness.Format(report))
	end
	local map, mesh, NavMesh = o.Map, report.Mesh, o.NavMesh
	local seeThrough = {}
	for _, name in map.SeeThrough or {} do
		seeThrough[name] = true
	end
	for _, p in folder:GetDescendants() do
		if p:IsA("BasePart") and seeThrough[p.Name] then
			p.Transparency = 0.75
		end
	end

	local meshRenderer = o.Renderer.new(folder, { AlwaysOnTop = false })
	local pathRenderer = o.Renderer.new(folder, { AlwaysOnTop = true })
	local linkRenderer = o.Renderer.new(folder, { AlwaysOnTop = true })
	local filter = if map.Filter then map.Filter(report.Areas) else nil
	local gui
	if map.AreaColors then
		-- By area: one fill per colour (not per floor), so thousands of floors stay a few parts.
		meshRenderer:Draw(Draw.Areas(NavMesh, mesh, report.Areas, map.AreaColors))
		gui = legend(map, report.Areas, filter)
		local ok = pcall(function()
			gui.Parent = game:GetService("CoreGui")
		end)
		if not ok then
			gui.Parent = game:GetService("StarterGui")
		end
	else
		meshRenderer:Draw(NavMesh.ToDrawList(mesh, { Seams = true, WallColor = "#ffffff" }))
	end
	linkRenderer:Draw(Draw.Links(report.Desc.Links or {}, Vector3, LINK_COLORS, LINK_COLOR))
	local paths = {}
	for _, row in report.Rows do
		table.insert(paths, row.Path)
	end
	pathRenderer:Draw(NavMesh.ToDrawList(mesh, { Triangles = false, PathColors = PATH_COLORS }, paths))

	-- The path probe.
	local pts, first = report.Built.Points, map.Scenarios[1]
	local function ball(name: string, at: Vector3, color: Color3): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Shape = Enum.PartType.Ball
		p.Size = Vector3.one * 3
		p.Anchored = true
		p.CanCollide = false
		p.Material = Enum.Material.Neon
		p.Color = color
		p.Position = at + Vector3.new(0, 1.5, 0)
		p.Parent = folder
		return p
	end
	local start = ball("Start", pts[first.From], Color3.fromRGB(46, 230, 64))
	local goal = ball("Goal", pts[first.To], Color3.fromRGB(255, 59, 48))
	start:SetAttribute("AgentRadius", if filter and filter.AgentRadius then filter.AgentRadius else 0)
	start:SetAttribute("Costs", filter ~= nil)
	start:SetAttribute("Links", true)
	start:SetAttribute("Scenarios", true)
	local board = Instance.new("BillboardGui")
	board.Size = UDim2.fromOffset(360, 54)
	board.StudsOffset = Vector3.new(0, 4, 0)
	board.AlwaysOnTop = true
	board.Parent = goal
	local status = Instance.new("TextLabel")
	status.Size = UDim2.fromScale(1, 1)
	status.BackgroundColor3 = Color3.new(0, 0, 0)
	status.BackgroundTransparency = 0.3
	status.TextColor3 = Color3.new(1, 1, 1)
	status.Font = Enum.Font.Code
	status.TextSize = 14
	status.TextWrapped = true
	status.Parent = board
	local probeRenderer = o.Renderer.new(folder, { AlwaysOnTop = true })
	local lastKey, linksOn = nil, true
	local function probe()
		local radius = tonumber(start:GetAttribute("AgentRadius")) or 0
		local costs, links = start:GetAttribute("Costs") == true, start:GetAttribute("Links") ~= false
		local key = `{start.Position}|{goal.Position}|{radius}|{costs}|{links}`
		pathRenderer:SetLayerVisible("Path", start:GetAttribute("Scenarios") ~= false)
		if key == lastKey then
			return
		end
		lastKey = key
		if links ~= linksOn then
			linksOn = links
			for id = 1, #(report.Desc.Links or {}) do
				NavMesh.SetLinkEnabled(mesh, id, links)
			end
			linkRenderer:SetLayerVisible("Links", links)
		end
		local f = { AgentRadius = radius, AreaCosts = if costs and filter then filter.AreaCosts else nil }
		local down = Vector3.new(0, 1.5, 0)
		local t0 = os.clock()
		local path = NavMesh.FindPath(mesh, start.Position - down, goal.Position - down, f)
		local ms = (os.clock() - t0) * 1000
		probeRenderer:Draw(NavMesh.ToDrawList(mesh, { Triangles = false, PathColors = { PROBE_COLOR } }, path))
		local used = {}
		for _, w in path.Waypoints do
			if w.Label then
				table.insert(used, w.Label)
			end
		end
		status.Text = string.format(
			"%s  length %.1f  cost %.1f  %d points  %.2f ms\nradius %s  costs %s  links %s%s",
			path.Status,
			path.Length,
			path.Cost,
			#path.Waypoints,
			ms,
			tostring(radius),
			if costs then "on" else "off",
			if links then "on" else "off",
			if #used > 0 then "  via " .. table.concat(used, ", ") else ""
		)
	end

	local camera = workspace.CurrentCamera
	camera.FieldOfView = 50
	local function aim(f: { number }, t: { number })
		local eye, target = Vector3.new(f[1], f[2], f[3]), Vector3.new(t[1], t[2], t[3])
		-- Placed, not locked (user: "do not lock it so I cant look around"). Studio's edit camera
		-- re-aims at Focus, so set both, and again a frame later.
		for _ = 1, 2 do
			camera.CFrame = CFrame.lookAt(eye, target)
			camera.Focus = CFrame.new(target)
			task.wait()
		end
	end
	local view = map.View
	if view then
		aim(view.From, view.To)
	else -- straight down over the walkable Parts, framed to fit
		local lo, hi = Vector3.one * math.huge, Vector3.one * -math.huge
		for _, p in report.Built.Walkable do
			local half = p.Size / 2
			lo, hi = lo:Min(p.Position - half), hi:Max(p.Position + half)
		end
		local mid, size = (lo + hi) / 2, hi - lo
		local h = math.max(size.X / 1.4, size.Z) / 2 / math.tan(math.rad(25)) * 1.15
		local eye = mid + Vector3.new(0, h, 0.01)
		aim({ eye.X, eye.Y, eye.Z }, { mid.X, mid.Y, mid.Z })
	end
	probe()
	print("[MARK] drawn")

	local step = if map.Animate then map.Animate(report, NavMesh, rbx, folder) else nil
	local function hold(seconds: number)
		local deadline = os.clock() + seconds
		while os.clock() < deadline do
			local dt = task.wait()
			probe()
			if step then
				step(dt)
			end
		end
	end

	local built = {}
	for _, list in { report.Built.Walkable, report.Built.Obstacles } do
		for _, p in list do
			built[p] = p.Transparency
		end
	end
	if o.Tour then
		hold(8) -- studio.py moves the window on "drawn"; it settles before the first stop
	end
	for _, stop in o.Tour or {} do
		for p, transparency in built do
			p.Transparency = if stop.Parts then math.max(stop.Parts, transparency) else transparency
		end
		if stop.Start then
			start.Position = Vector3.new(stop.Start[1], stop.Start[2], stop.Start[3]) + Vector3.new(0, 1.5, 0)
		end
		if stop.Goal then
			goal.Position = Vector3.new(stop.Goal[1], stop.Goal[2], stop.Goal[3]) + Vector3.new(0, 1.5, 0)
		end
		for name, value in stop.Attributes or {} do
			start:SetAttribute(name, value)
		end
		aim(stop.From, stop.To)
		hold(1)
		print(`[MARK] view {stop.Tag}`)
		print(`[PROBE] {stop.Tag}: {(status.Text:gsub("%c", "; "))}`)
		hold(o.Dwell or 6)
	end

	hold(o.Hold)
	meshRenderer:Destroy()
	pathRenderer:Destroy()
	linkRenderer:Destroy()
	probeRenderer:Destroy()
	if gui then
		gui:Destroy()
	end
	print("[MARK] cleared")
	task.wait(o.Hold)
end

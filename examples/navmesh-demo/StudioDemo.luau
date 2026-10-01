--!strict
-- The Studio side of the demo: builds the level out of Parts (LevelParts), builds the mesh from
-- those Parts with NavMeshAdapter, runs Game on it, moves a Part per NPC, and draws the mesh and
-- every NPC's path with DrawListRenderer.
-- Used by the run-in-roblox shot script and by the Play-mode LocalScript (see studio.py).

type Options = {
	NavMesh: any,
	Renderer: any, -- DrawListRenderer
	Game: any,
	Level: any,
	LevelParts: any,
	Adapter: any, -- NavMeshAdapter
	Baked: string, -- the bake of Level.luau: timed, and its triangle count printed for comparison
	Seconds: number, -- how long to run; math.huge in Play mode
	Camera: string?, -- "top" | "oblique" | nil (leave the camera alone)
}

local NPC_COLORS = {
	Runner = Color3.fromRGB(46, 204, 64),
	Chaser = Color3.fromRGB(230, 40, 40),
	Small1 = Color3.fromRGB(30, 110, 255),
	Small2 = Color3.fromRGB(30, 110, 255),
	Small3 = Color3.fromRGB(30, 110, 255),
	Big1 = Color3.fromRGB(150, 60, 220),
	Big2 = Color3.fromRGB(150, 60, 220),
}

local function part(parent: Instance, name: string, size: Vector3, cframe: CFrame, color: Color3): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function npcPart(folder: Folder, npc: any): Part
	local p =
		part(folder, npc.Name, Vector3.one * npc.Radius * 2, CFrame.new(), NPC_COLORS[npc.Name] or Color3.new(1, 1, 1))
	p.Shape = Enum.PartType.Ball
	p.CanCollide = false
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(80, 20)
	gui.StudsOffset = Vector3.new(0, npc.Radius + 1, 0)
	gui.AlwaysOnTop = true
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Text = npc.Name
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0
	label.Font = Enum.Font.GothamBold
	label.TextSize = 14
	label.Parent = gui
	gui.Parent = p
	return p
end

local function hex(c: Color3): string
	return c:ToHex()
end

-- HAND-ROLLED: ToDrawList draws at most one path, so every NPC's remaining path is drawn here.
local function pathList(world: any): { any }
	local list = {}
	for _, npc in world.Npcs do
		local follower = npc.Follower
		if follower == nil then
			continue
		end
		local color = "#" .. hex(NPC_COLORS[npc.Name] or Color3.new(1, 1, 1))
		local prev = npc.Position
		local path = follower.Path
		for i = follower.Next, #path.Waypoints do
			local w = path.Waypoints[i].Position
			table.insert(list, {
				Kind = "Line",
				Points = { prev.X, prev.Y + 0.15, prev.Z, w.X, w.Y + 0.15, w.Z },
				Color = color,
				Layer = "Paths",
			})
			prev = w
		end
		if npc.Goal then
			local g = npc.Goal
			table.insert(
				list,
				{ Kind = "Circle", Points = { g.X, g.Y + 0.15, g.Z }, Radius = 0.4, Color = color, Layer = "Paths" }
			)
		end
	end
	return list
end

return function(o: Options)
	local NavMesh, Game = o.NavMesh, o.Game
	local folder = Instance.new("Folder")
	folder.Name = "NavMeshDemo"
	folder.Parent = workspace
	local walkable, obstacles, door =
		o.LevelParts({ Instance = Instance, Vector3 = Vector3, CFrame = CFrame, Color3 = Color3 }, folder)

	local t0 = os.clock()
	local baked = NavMesh.Deserialize(buffer.fromstring(o.Baked))
	print(string.format("[DEMO] Deserialize %.2f ms", (os.clock() - t0) * 1000))
	t0 = os.clock()
	local desc = o.Adapter.FromParts(walkable, obstacles)
	desc.MaxAgentRadius = o.Level.Desc.MaxAgentRadius
	desc.Links = o.Level.Desc.Links
	local mesh = NavMesh.Build(desc)
	local function triangles(m: any): number
		local n = 0
		for _, item in NavMesh.ToDrawList(m) do
			n += if item.Kind == "Tri" then 1 else 0
		end
		return n
	end
	print(
		string.format(
			"[DEMO] FromParts + Build %.2f ms: %d triangles, %d seams (the bake of Level.luau: %d triangles)",
			(os.clock() - t0) * 1000,
			triangles(mesh),
			#desc.Seams,
			triangles(baked)
		)
	)
	local world = Game.new(NavMesh, mesh, o.Level, 7, function(line)
		print("[DEMO] " .. line)
	end)

	local meshRenderer = o.Renderer.new(folder)
	local pathRenderer = o.Renderer.new(folder)
	local function drawMesh()
		local d0 = os.clock()
		meshRenderer:Draw(NavMesh.ToDrawList(world.Mesh, { Areas = true, Seams = true, Links = true }))
		return (os.clock() - d0) * 1000
	end
	print(string.format("[DEMO] first mesh Draw %.2f ms", drawMesh()))

	local npcParts = {}
	for _, npc in world.Npcs do
		npcParts[npc] = npcPart(folder, npc)
	end

	if o.Camera then
		local camera = workspace.CurrentCamera
		camera.CameraType = Enum.CameraType.Scriptable
		camera.FieldOfView = 50
		camera.CFrame = if o.Camera == "top"
			then CFrame.lookAt(Vector3.new(30, 72, 20.01), Vector3.new(30, 0, 20))
			else CFrame.lookAt(Vector3.new(30, 44, 68), Vector3.new(30, 0, 17))
	end

	local lastDoor = world.DoorId
	local accumulator, pathTimer = 0, 0
	local last = os.clock()
	local deadline = last + o.Seconds
	local drawTimes = {}
	while os.clock() < deadline do
		task.wait()
		local now = os.clock()
		accumulator += math.min(now - last, 0.25)
		last = now
		while accumulator >= Game.DT do
			accumulator -= Game.DT
			world:Step(Game.DT)
		end
		for npc, p in npcParts do
			p.Position = npc.Position + Vector3.new(0, npc.Radius, 0)
		end
		if world.DoorId ~= lastDoor then
			lastDoor = world.DoorId
			door.Transparency = if world.DoorId then 0 else 0.85
			door.CanCollide = world.DoorId ~= nil
			table.insert(drawTimes, drawMesh()) -- the mesh changed: redraw it
		end
		pathTimer -= 1
		if pathTimer <= 0 then
			pathTimer = 6
			pathRenderer:Draw(pathList(world))
		end
	end
	local fills = 0
	for _, child in folder:GetDescendants() do
		if child:IsA("MeshPart") then
			fills += 1
		end
	end
	print(`[DEMO] renderer fill MeshParts alive at the end: {fills}`)
	Game.Report(world, function(line)
		print("[DEMO] " .. line)
	end)
	table.sort(drawTimes)
	if #drawTimes > 0 then
		print(
			string.format(
				"[DEMO] mesh redraw after a door toggle: median %.2f ms over %d",
				drawTimes[(#drawTimes + 1) // 2],
				#drawTimes
			)
		)
	end
end

--!strict
-- The Studio side: builds the level's Parts (LevelParts), loads the bake from the NavMeshBake
-- StringValues, runs Game on it, moves a ball per agent, and draws the mesh (redrawn after each
-- Update) and every agent's path with DrawListRenderer. Used by studio.py's edit-mode run.

type Options = {
	NavMesh: any,
	Adapter: any, -- NavMeshAdapter: a fresh FromParts + Build, timed against the bake
	Renderer: any, -- DrawListRenderer
	Game: any,
	LevelParts: any,
	BakeText: any,
	BakeFolder: Instance,
	Seconds: number,
	Camera: string, -- "top" | "oblique" | "door" | "free"
	Draw: boolean, -- false: no debug drawing (the negative control for the screenshot)
}

local KIND_COLORS = {
	Player = Color3.fromRGB(46, 230, 64),
	Chaser = Color3.fromRGB(235, 40, 40),
	Wanderer = Color3.fromRGB(40, 140, 255),
}

local function ball(parent: Instance, npc: any): Part
	local p = Instance.new("Part")
	p.Name = npc.Name
	p.Shape = Enum.PartType.Ball
	p.Anchored, p.CanCollide = true, false
	p.Size = Vector3.one * npc.Radius * 2
	p.Color = KIND_COLORS[npc.Kind]
	p.Material = Enum.Material.Neon
	p.Parent = parent
	return p
end

local function ms(t0: number): number
	return (os.clock() - t0) * 1000
end

return function(o: Options)
	local NavMesh, Game = o.NavMesh, o.Game
	local folder = Instance.new("Folder")
	folder.Name = "Warehouse"
	folder.Parent = workspace
	local rbx = { Instance = Instance, Vector3 = Vector3, CFrame = CFrame, Color3 = Color3, Enum = Enum }
	local walkable, obstacles, doors, crates = o.LevelParts(rbx, folder)

	local t0 = os.clock()
	local data = o.BakeText.Load(o.BakeText.Chunks(o.BakeFolder))
	local decodeMs = ms(t0)
	t0 = os.clock()
	local mesh = NavMesh.Deserialize(data)
	print(
		string.format(
			"[DEMO] bake %d bytes: base64 decode %.2f ms, Deserialize %.2f ms",
			buffer.len(data),
			decodeMs,
			ms(t0)
		)
	)
	t0 = os.clock()
	local desc = o.Adapter.FromParts(walkable, obstacles)
	desc.MaxAgentRadius = 2
	local built = NavMesh.Build(desc)
	local fresh, baked = buffer.tostring(NavMesh.Serialize(built)), buffer.tostring(data)
	local differ = 0
	for i = 1, math.min(#fresh, #baked) do
		differ += if string.byte(fresh, i) ~= string.byte(baked, i) then 1 else 0
	end
	print(
		string.format(
			"[DEMO] FromParts + Build %.2f ms; vs the Lune bake: %d vs %d bytes, %d bytes differ",
			ms(t0),
			#fresh,
			#baked,
			differ
		)
	)

	local world = Game.new(NavMesh, mesh, doors, crates, 7, 1)
	local balls = {}
	for _, npc in world.Npcs do
		balls[npc] = ball(folder, npc)
	end

	local meshRenderer = o.Renderer.new(folder)
	local pathRenderer = o.Renderer.new(folder)
	local drawTimes, pathTimes = {}, {}
	local function drawMesh()
		local d0 = os.clock()
		meshRenderer:Draw(NavMesh.ToDrawList(mesh, { Seams = true, WallColor = "#ffffff" }))
		table.insert(drawTimes, ms(d0))
	end
	-- HAND-ROLLED (debug): the remaining part of each agent's path, coloured by kind.
	local function drawPaths()
		local paths, colors = {}, {}
		for _, npc in world.Npcs do
			local follower = npc.Follower
			if follower then
				local rest = { { Position = npc.Position, Floor = npc.Floor } }
				table.move(follower.Path.Waypoints, follower.Next, #follower.Path.Waypoints, 2, rest)
				table.insert(paths, { Status = "Success", Waypoints = rest, Cost = 0, TileStamps = {} })
				table.insert(colors, "#" .. KIND_COLORS[npc.Kind]:ToHex())
			end
		end
		local d0 = os.clock()
		pathRenderer:Draw(NavMesh.ToDrawList(mesh, { Triangles = false, PathColors = colors }, paths))
		table.insert(pathTimes, ms(d0))
	end
	if o.Draw then
		drawMesh()
	end

	if o.Camera ~= "free" then -- "free" leaves the camera to the user (studio.py play)
		local camera = workspace.CurrentCamera
		camera.CameraType = Enum.CameraType.Scriptable
		camera.FieldOfView = 50
		camera.CFrame = ({
			top = CFrame.lookAt(Vector3.new(200, 330, 120.01), Vector3.new(200, 0, 120)),
			oblique = CFrame.lookAt(Vector3.new(210, 70, -20), Vector3.new(210, 4, 110)),
			door = CFrame.lookAt(Vector3.new(246, 26, 100), Vector3.new(272, 2, 120)), -- the east wall's middle door
		})[o.Camera]
	end

	local updates = 0
	local accumulator, frame = 0, 0
	local last = os.clock()
	local deadline = last + o.Seconds
	while os.clock() < deadline do
		task.wait()
		local now = os.clock()
		accumulator += math.min(now - last, 0.25)
		last = now
		while accumulator >= Game.DT do
			accumulator -= Game.DT
			world:Step(Game.DT)
		end
		for npc, p in balls do
			p.Position = npc.Position + Vector3.new(0, npc.Radius, 0)
		end
		for _, door in world.Doors do
			door.Part.Transparency = if door.Id then 0 else 0.85
		end
		local count = world.Timings.Update and #world.Timings.Update or 0
		if o.Draw and count ~= updates then
			updates = count
			drawMesh()
		end
		frame += 1
		if o.Draw and frame % 6 == 0 then
			drawPaths()
		end
	end
	Game.Report(world, function(line)
		print("[DEMO] " .. line)
	end)
	local function median(xs: { number }): number
		table.sort(xs)
		return xs[math.max(1, (#xs + 1) // 2)] or 0
	end
	print(
		string.format(
			"[DEMO] mesh Draw median %.2f ms over %d; path Draw median %.2f ms over %d",
			median(drawTimes),
			#drawTimes,
			median(pathTimes),
			#pathTimes
		)
	)
end

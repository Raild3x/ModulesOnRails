--!strict
-- Authors: Logan Hunt (Raildex)
-- September 27, 2026
-- F7 scene (ticket 20): draws a real NavMesh with DrawListRenderer and aims a top-down camera
-- at it, then holds Studio open so capture.ps1 can grab the window. `courtyard` is the fixture
-- with a FindPath path; any bench scene name (props, bench, terrain, walls) draws that scene
-- with its tiles and a corner-to-corner path.

type Options = { NavMesh: any, Renderer: any, Scenes: { any }, Scene: string, HoldSeconds: number }

return function(o: Options)
	local NavMesh = o.NavMesh
	local desc, side = nil, 0
	if o.Scene == "courtyard" then
		desc, side = NavMesh.Fixtures.Courtyard.Desc, 33
	else
		for _, scene in o.Scenes do
			if scene.Name == o.Scene then
				desc, side = scene.Make(), scene.Side
			end
		end
	end
	assert(desc, `unknown scene {o.Scene}`)

	local mesh = NavMesh.Build(desc)
	local from, to = Vector3.new(1, 0, 10), Vector3.new(16, 0, 28)
	if o.Scene ~= "courtyard" then
		from, to = Vector3.new(side * 0.02, 0, side * 0.02), Vector3.new(side * 0.98, 0, side * 0.98)
	end
	local path = NavMesh.FindPath(mesh, from, to)
	print(`[MARK] path {path.Status} {#path.Waypoints} waypoints`)
	for _, waypoint in path.Waypoints do
		print(`[MARK] waypoint {waypoint.Position}`)
	end
	local list = NavMesh.ToDrawList(mesh, { Tiles = o.Scene ~= "courtyard" }, path)
	table.insert(
		list,
		{ Kind = "Label", Points = { from.X, 0, from.Z }, Color = "#000000", Layer = "Path", Text = "start" }
	)
	table.insert(list, { Kind = "Label", Points = { to.X, 0, to.Z }, Color = "#000000", Layer = "Path", Text = "goal" })

	local renderer = o.Renderer.new(workspace)
	renderer:Draw(list)
	print(`[MARK] drawn {#list} primitives`)

	local camera = workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = 40
	local center = Vector3.new(side / 2, 0, side / 2)
	camera.CFrame = CFrame.lookAt(center + Vector3.new(0, side * 1.45, 0.01), center)

	local deadline = os.clock() + o.HoldSeconds
	while os.clock() < deadline do
		task.wait(0.5)
	end
	renderer:Destroy()
	print("[MARK] done")
end

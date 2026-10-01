--!strict
-- Authors: Logan Hunt (Raildex)
-- September 27, 2026
-- F7 scene (ticket 21): opens NavMeshEditor in edit mode on a NavMesh fixture plus one
-- skewed obstacle, places both markers and a radius through the public API, aims an oblique
-- camera, and holds Studio open for capture.ps1. The status bar is moved to StarterGui,
-- which Studio shows in edit mode.

type Options = { NavMesh: any, NavMeshEditor: any, Fixture: string, HoldSeconds: number }

return function(o: Options)
	local fixture = o.NavMesh.Fixtures[o.Fixture]
	assert(fixture, `unknown fixture {o.Fixture}`)
	-- The obstacle a 3-stud square at (30, 12) becomes once its third vertex is dragged.
	local desc = table.clone(fixture.Desc)
	desc.Floors = table.clone(desc.Floors)
	local ground = table.clone(desc.Floors.Ground)
	ground.Obstacles = table.clone(ground.Obstacles or {})
	table.insert(ground.Obstacles, {
		Vector3.new(28.5, 0, 10.5),
		Vector3.new(31.5, 0, 10.5),
		Vector3.new(33, 0, 16),
		Vector3.new(28.5, 0, 13.5),
	})
	desc.Floors.Ground = ground
	local editor = o.NavMeshEditor.new(workspace, "NavMesh", desc)
	editor:SetMarkers(Vector3.new(36, 0, 18), Vector3.new(34, 5, 6))
	editor:SetAgentRadius(0.75)

	local gui = workspace:FindFirstChild("NavMeshEditor", true)
	local screen = gui and gui:FindFirstChildOfClass("ScreenGui")
	print(`[MARK] status {screen and (screen:FindFirstChild("Status") :: TextLabel).Text}`)
	if screen then
		screen.Parent = game:GetService("StarterGui")
	end

	local camera = workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = 50
	camera.CFrame = CFrame.lookAt(Vector3.new(20, 38, 42), Vector3.new(21, 1, 9))

	local deadline = os.clock() + o.HoldSeconds
	while os.clock() < deadline do
		task.wait(0.5)
	end
	editor:Destroy()
	if screen then
		screen:Destroy()
	end
	print("[MARK] done")
end

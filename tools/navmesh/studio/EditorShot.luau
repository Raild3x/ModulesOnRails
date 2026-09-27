--!strict
-- Authors: Logan Hunt (Raildex)
-- September 27, 2026
-- F7 scene (ticket 21): opens NavMeshEditor on a NavMesh fixture in edit mode, drives it with
-- the same events the mouse and keys make (a new obstacle, a dragged vertex, both markers and
-- a radius), aims an oblique camera, and holds Studio open for capture.ps1. The status bar
-- is moved to StarterGui, which Studio shows in edit mode.

type Options = { NavMesh: any, NavMeshEditor: any, Fixture: string, HoldSeconds: number }

return function(o: Options)
	local fixture = o.NavMesh.Fixtures[o.Fixture]
	assert(fixture, `unknown fixture {o.Fixture}`)
	local editor = o.NavMeshEditor.new(workspace, "NavMesh", fixture.Desc)
	local down = Vector3.new(0, -1, 0)
	editor:_apply {
		Type = "CreateRing",
		Kind = "Obstacle",
		Floor = "Ground",
		Position = Vector3.new(30, 0, 12),
		Size = 3,
	}
	editor:_apply { Type = "PointerDown", Origin = Vector3.new(31.5, 100, 13.5), Direction = down }
	editor:_apply { Type = "Drag", Origin = Vector3.new(33, 100, 16), Direction = down }
	editor:_apply { Type = "SetMarker", Which = "Start", Position = Vector3.new(36, 0, 18) }
	editor:_apply { Type = "SetMarker", Which = "Goal", Position = Vector3.new(34, 5, 6) }
	editor:_apply { Type = "SetAgentRadius", Radius = 0.75 }
	print(`[MARK] path {editor._pathStatus} error {editor._error}`)

	local gui = workspace:FindFirstChild("NavMeshEditor", true)
	local screen = gui and gui:FindFirstChildOfClass("ScreenGui")
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

--!strict
-- The Studio side of the map harness: builds the map's Parts in workspace, runs its scenarios
-- (Harness), prints the table, and draws the mesh and every scenario's path for `Hold` seconds.
-- Then it clears the drawing and holds again, so studio.py's second capture (taken then) must
-- differ from the first: the screenshot's negative control.

local PATH_COLORS = { "#2ee640", "#ff3b30", "#2f8cff", "#ffd60a", "#bf5af2", "#ff9f0a", "#64d2ff", "#ff375f" }

return function(o: {
	NavMesh: any,
	Adapter: any,
	Renderer: any,
	Harness: any,
	Map: any,
	Hold: number,
})
	local folder = Instance.new("Folder")
	folder.Name = o.Map.Name
	folder.Parent = workspace
	local rbx = { Instance = Instance, Vector3 = Vector3, CFrame = CFrame, Color3 = Color3, Enum = Enum }
	local report = o.Harness.Run(o.Map, o.NavMesh, o.Adapter, rbx, folder)
	print(o.Harness.Format(report))

	local meshRenderer = o.Renderer.new(folder, { AlwaysOnTop = false })
	local pathRenderer = o.Renderer.new(folder, { AlwaysOnTop = true })
	meshRenderer:Draw(o.NavMesh.ToDrawList(report.Mesh, { Seams = true, Links = true, WallColor = "#ffffff" }))
	local paths = {}
	for _, row in report.Rows do
		table.insert(paths, row.Path)
	end
	pathRenderer:Draw(o.NavMesh.ToDrawList(report.Mesh, { Triangles = false, PathColors = PATH_COLORS }, paths))

	local camera = workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = 50
	local view = o.Map.View
	if view then
		local f, t = view.From, view.To
		camera.CFrame = CFrame.lookAt(Vector3.new(f[1], f[2], f[3]), Vector3.new(t[1], t[2], t[3]))
	else -- straight down over the walkable Parts, framed to fit
		local lo, hi = Vector3.one * math.huge, Vector3.one * -math.huge
		for _, p in report.Built.Walkable do
			local half = p.Size / 2
			lo, hi = lo:Min(p.Position - half), hi:Max(p.Position + half)
		end
		local mid, size = (lo + hi) / 2, hi - lo
		local h = math.max(size.X / 1.4, size.Z) / 2 / math.tan(math.rad(25)) * 1.15
		camera.CFrame = CFrame.lookAt(mid + Vector3.new(0, h, 0.01), mid)
	end

	print("[MARK] drawn")
	task.wait(o.Hold)
	meshRenderer:Destroy()
	pathRenderer:Destroy()
	print("[MARK] cleared")
	task.wait(o.Hold)
end

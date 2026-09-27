--!strict
-- Authors: Logan Hunt (Raildex)
-- September 27, 2026
-- Renderer-primitive benchmark (ticket 20): how should DrawListRenderer draw filled `Tri`s?
-- Every variant draws the whole NavMesh DrawList the same way (lines, points and triangle
-- outlines on one WireframeHandleAdornment per layer and colour); only the triangle fill differs:
--   outline      no fill: the Phase 0 renderer, the baseline
--   wedges       two WedgeParts per triangle, rebuilt on every Draw
--   wedgesPooled two WedgeParts per triangle, reused across Draws
--   editableMesh one EditableMesh-backed MeshPart per (layer, colour) and 20,000 triangles.
--                The meshes are built during Draw; `CreateMeshPartAsync` yields one frame, so the
--                parts are created on a spawned thread and a newer Draw discards stale ones.
--   shipped      the real DrawListRenderer, to check it matches its prototype
-- Method (bench.md): interleaved rounds with the variant order rotated, best of `Reps` per round,
-- median over rounds. `draw` and `redraw` are the time Draw blocks the caller; `ready` is how
-- many frames pass before the fills exist. A second pass measures, once per run, the engine
-- memory counters and the render frame times with the drawing in view. Prints [W], [Y], [R]
-- and [M] lines for studio.py; every loop checks the deadline.

local AssetService = game:GetService("AssetService")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")

type Options = {
	NavMesh: any,
	Scenes: { any },
	Shipped: any,
	Rounds: number,
	Reps: number,
	Deadline: number,
}

type Batch = { Color: Color3, Points: { Vector3 } } -- three points per triangle
type Fill = {
	Pending: number,
	Draw: (self: Fill, batches: { [string]: Batch }) -> (),
	Clear: (self: Fill) -> (),
}
type Renderer = { Draw: (self: Renderer, list: any) -> (), Destroy: (self: Renderer) -> () }

local POINT_CROSS_SIZE = 0.25
local FILL_TRANSPARENCY = 0.6
local WEDGE_THICKNESS = 0.05
local MESH_CHUNK = 20000 -- EditableMesh caps at 20,000 triangles and 60,000 vertices

local function v3(p: { number }, i: number): Vector3
	return Vector3.new(p[i], p[i + 1], p[i + 2])
end

local function styleFillPart(part: BasePart, color: Color3)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	part.Transparency = FILL_TRANSPARENCY
	part.Color = color
end

-- Places two wedges over triangle abc (the standard right-triangle split).
local function placeWedges(a: Vector3, b: Vector3, c: Vector3, w1: WedgePart, w2: WedgePart)
	local ab, ac, bc = b - a, c - a, c - b
	local abd, acd, bcd = ab:Dot(ab), ac:Dot(ac), bc:Dot(bc)
	if abd > acd and abd > bcd then
		c, a = a, c
	elseif acd > bcd and acd > abd then
		a, b = b, a
	end
	ab, ac, bc = b - a, c - a, c - b
	local right = ac:Cross(ab).Unit
	local up = bc:Cross(right).Unit
	local back = bc.Unit
	local height = math.abs(ab:Dot(up))
	w1.Size = Vector3.new(WEDGE_THICKNESS, height, math.abs(ab:Dot(back)))
	w1.CFrame = CFrame.fromMatrix((a + b) / 2, right, up, back)
	w2.Size = Vector3.new(WEDGE_THICKNESS, height, math.abs(ac:Dot(back)))
	w2.CFrame = CFrame.fromMatrix((a + c) / 2, -right, up, -back)
end

local function newWedge(parent: Instance, color: Color3): WedgePart
	local w = Instance.new("WedgePart")
	styleFillPart(w, color)
	w.Parent = parent
	return w
end

local Fills: { [string]: (folder: Folder) -> Fill } = {}

Fills.outline = function(_folder)
	return { Pending = 0, Draw = function() end, Clear = function() end } :: any
end

Fills.wedges = function(folder)
	return {
		Pending = 0,
		Draw = function(_self, batches: { [string]: Batch })
			for _, batch in batches do
				local p = batch.Points
				for i = 1, #p, 3 do
					placeWedges(p[i], p[i + 1], p[i + 2], newWedge(folder, batch.Color), newWedge(folder, batch.Color))
				end
			end
		end,
		Clear = function()
			folder:ClearAllChildren()
		end,
	} :: any
end

Fills.wedgesPooled = function(folder)
	local pool: { WedgePart } = {}
	local used = 0
	return {
		Pending = 0,
		Draw = function(_self, batches: { [string]: Batch })
			for _, batch in batches do
				local p = batch.Points
				for i = 1, #p, 3 do
					local w1, w2 = pool[used + 1], pool[used + 2]
					if w1 == nil then
						w1, w2 = newWedge(folder, batch.Color), newWedge(folder, batch.Color)
						pool[used + 1], pool[used + 2] = w1, w2
					else
						w1.Color, w2.Color = batch.Color, batch.Color
						w1.Parent, w2.Parent = folder, folder
					end
					placeWedges(p[i], p[i + 1], p[i + 2], w1, w2)
					used += 2
				end
			end
			for i = used + 1, #pool do
				pool[i].Parent = nil
			end
		end,
		Clear = function()
			used = 0
		end,
	} :: any
end

Fills.editableMesh = function(folder)
	local meshes: { EditableMesh } = {}
	local generation = 0
	local fill: any
	fill = {
		Pending = 0,
		Draw = function(_self, batches: { [string]: Batch })
			local drawn = generation
			for _, batch in batches do
				local p = batch.Points
				for first = 1, #p, 3 * MESH_CHUNK do
					local last = math.min(#p, first + 3 * MESH_CHUNK - 1)
					local lo, hi = p[first], p[first]
					for i = first, last do
						lo, hi = lo:Min(p[i]), hi:Max(p[i])
					end
					local center = (lo + hi) / 2
					local mesh = AssetService:CreateEditableMesh()
					for i = first, last, 3 do
						local a, b, c = p[i], p[i + 1], p[i + 2]
						if (b - a):Cross(c - a).Y < 0 then
							b, c = c, b
						end
						mesh:AddTriangle(
							mesh:AddVertex(a - center),
							mesh:AddVertex(b - center),
							mesh:AddVertex(c - center)
						)
					end
					table.insert(meshes, mesh)
					fill.Pending += 1
					task.spawn(function()
						local ok, part = pcall(AssetService.CreateMeshPartAsync, AssetService, Content.fromObject(mesh))
						fill.Pending -= 1
						if not ok or generation ~= drawn then
							if ok then
								part:Destroy()
							end
							return
						end
						styleFillPart(part, batch.Color)
						part.Position = center
						part.Parent = folder
					end)
				end
			end
		end,
		Clear = function()
			generation += 1
			folder:ClearAllChildren()
			for _, mesh in meshes do
				mesh:Destroy()
			end
			table.clear(meshes)
		end,
	}
	return fill :: any
end

-- The Phase 0 renderer with its triangle fills handed to a Fill.
local function makeRenderer(fillName: string, parent: Instance): Renderer
	local root = Instance.new("Folder")
	root.Name = fillName
	local fillFolder = Instance.new("Folder")
	fillFolder.Name = "Fill"
	fillFolder.Parent = root
	root.Parent = parent
	local fill = Fills[fillName](fillFolder)
	local adornments: { [string]: WireframeHandleAdornment } = {}

	local function adornment(layer: string, color: string): WireframeHandleAdornment
		local key = layer .. "|" .. color
		local a = adornments[key]
		if a == nil then
			a = Instance.new("WireframeHandleAdornment")
			a.Adornee = workspace.Terrain
			a.Color3 = Color3.fromHex(color)
			a.AlwaysOnTop = true
			a.Parent = root
			adornments[key] = a
		end
		return a :: WireframeHandleAdornment
	end

	return {
		_fill = fill,
		Draw = function(_self, list: any)
			for _, a in adornments do
				a:Clear()
			end
			fill:Clear()
			local batches: { [string]: Batch } = {}
			for _, primitive in list do
				local a = adornment(primitive.Layer, primitive.Color)
				local p = primitive.Points
				local kind = primitive.Kind
				if kind == "Line" then
					a:AddLine(v3(p, 1), v3(p, 4))
				elseif kind == "Tri" then
					local pa, pb, pc = v3(p, 1), v3(p, 4), v3(p, 7)
					a:AddPath({ pa, pb, pc }, true)
					local key = primitive.Layer .. "|" .. primitive.Color
					local batch = batches[key]
					if batch == nil then
						batch = { Color = Color3.fromHex(primitive.Color), Points = {} }
						batches[key] = batch
					end
					local points = (batch :: Batch).Points
					table.insert(points, pa)
					table.insert(points, pb)
					table.insert(points, pc)
				elseif kind == "Point" then
					local center = v3(p, 1)
					a:AddLine(center - Vector3.xAxis * POINT_CROSS_SIZE, center + Vector3.xAxis * POINT_CROSS_SIZE)
					a:AddLine(center - Vector3.zAxis * POINT_CROSS_SIZE, center + Vector3.zAxis * POINT_CROSS_SIZE)
				else
					error(`unexpected Kind {kind}`)
				end
			end
			fill:Draw(batches)
		end,
		Destroy = function()
			fill:Clear()
			root:Destroy()
		end,
	} :: any
end

local function median(xs: { number }): number
	local s = table.clone(xs)
	table.sort(s)
	return s[(#s + 1) // 2]
end

-- The same list with every point raised 0.25 studs: a changed list of the same size.
local function shifted(list: { any }): { any }
	local out = table.create(#list)
	for i, primitive in list do
		local copy: any = table.clone(primitive)
		copy.Points = table.clone(primitive.Points)
		for k = 2, #copy.Points, 3 do
			copy.Points[k] += 0.25
		end
		out[i] = copy
	end
	return out
end

local MEMORY_TAGS = {
	Enum.DeveloperMemoryTag.Instances,
	Enum.DeveloperMemoryTag.BaseParts,
	Enum.DeveloperMemoryTag.GraphicsParts,
	Enum.DeveloperMemoryTag.GraphicsMeshParts,
}

local function memorySample(): number
	local total = 0
	for _, tag in MEMORY_TAGS do
		total += Stats:GetMemoryUsageMbForTag(tag)
	end
	return total
end

-- Median render CPU and GPU frame times (ms) over about 1.5 seconds.
local function renderSample(): (number, number)
	local cpu, gpu = {}, {}
	for _ = 1, 15 do
		task.wait(0.1)
		table.insert(cpu, Stats.RenderCPUFrameTime * 1000)
		table.insert(gpu, Stats.RenderGPUFrameTime * 1000)
	end
	return median(cpu), median(gpu)
end

local heartbeats = 0
RunService.Heartbeat:Connect(function()
	heartbeats += 1
end)

return function(o: Options)
	local NavMesh = o.NavMesh
	local workloads = {}
	local courtyard = NavMesh.Build(NavMesh.Fixtures.Courtyard.Desc)
	local path = NavMesh.FindPath(courtyard, Vector3.new(1, 0, 10), Vector3.new(16, 0, 28))
	table.insert(workloads, { Name = "courtyard", Side = 33, List = NavMesh.ToDrawList(courtyard, nil, path) })
	for _, scene in o.Scenes do
		local mesh = NavMesh.Build(scene.Make())
		table.insert(workloads, { Name = scene.Name, Side = scene.Side, List = NavMesh.ToDrawList(mesh) })
	end
	for _, w in workloads do
		w.Changed = shifted(w.List)
		local tris = 0
		for _, primitive in w.List do
			if primitive.Kind == "Tri" then
				tris += 1
			end
		end
		print(`[W] {w.Name} | {tris} tris | {#w.List} primitives`)
	end

	local names = { "outline", "wedges", "wedgesPooled", "editableMesh", "shipped" }
	local function create(name: string): Renderer
		if name == "shipped" then
			return o.Shipped.new(workspace)
		end
		return makeRenderer(name, workspace)
	end
	local function pending(renderer: any): number
		return if renderer._fill then renderer._fill.Pending else (renderer._pending or 0)
	end
	local function waitReady(renderer: any): number
		local start = heartbeats
		while pending(renderer) > 0 do
			task.wait()
		end
		return heartbeats - start
	end

	-- Draw must not yield: a yielding Draw would let two redraws interleave.
	for _, name in names do
		local renderer = create(name)
		local co = coroutine.create(function()
			renderer:Draw(workloads[#workloads].List)
		end)
		coroutine.resume(co)
		print(`[Y] {name} | {if coroutine.status(co) == "dead" then "no yield" else "YIELDS"}`)
		while coroutine.status(co) ~= "dead" do
			task.wait()
		end
		waitReady(renderer)
		renderer:Destroy()
	end

	local draws: { [string]: { number } } = {}
	local redraws: { [string]: { number } } = {}
	local ready: { [string]: number } = {}
	local instances: { [string]: number } = {}
	for round = 1, o.Rounds do
		for k = 0, #names - 1 do
			local name = names[(round + k - 1) % #names + 1]
			for _, w in workloads do
				if os.clock() > o.Deadline then
					print("[MARK] deadline hit")
					return
				end
				local key = `{w.Name}|{name}`
				local bestDraw, bestRedraw = math.huge, math.huge
				for _ = 1, o.Reps do
					local renderer = create(name)
					local t0 = os.clock()
					renderer:Draw(w.List)
					local t1 = os.clock()
					ready[key] = math.max(ready[key] or 0, waitReady(renderer))
					if instances[key] == nil then
						local root = workspace:FindFirstChild(if name == "shipped" then "DrawListRenderer" else name)
						instances[key] = #(root :: Instance):GetDescendants()
					end
					local t2 = os.clock()
					renderer:Draw(w.Changed)
					local t3 = os.clock()
					waitReady(renderer)
					bestDraw, bestRedraw = math.min(bestDraw, t1 - t0), math.min(bestRedraw, t3 - t2)
					renderer:Destroy()
				end
				draws[key] = draws[key] or {}
				redraws[key] = redraws[key] or {}
				table.insert(draws[key], bestDraw * 1000)
				table.insert(redraws[key], bestRedraw * 1000)
				task.wait()
			end
		end
		print(`[MARK] round {round}`)
	end
	for _, w in workloads do
		for _, name in names do
			local key = `{w.Name}|{name}`
			print(
				string.format(
					"[R] %s | %s | %.3f | %.3f | %d | %d",
					w.Name,
					name,
					median(draws[key]),
					median(redraws[key]),
					instances[key],
					ready[key]
				)
			)
		end
	end

	-- Memory and render cost, once per run, with the drawing in view of a top-down camera.
	-- The engine samples its per-tag counters, so each draw settles before it is read.
	local camera = workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = 40
	for _, w in workloads do
		local center = Vector3.new(w.Side / 2, 0, w.Side / 2)
		camera.CFrame = CFrame.lookAt(center + Vector3.new(0, w.Side * 1.45, 0.01), center)
		task.wait(1)
		local cpu, gpu = renderSample()
		print(string.format("[M] %s | none | 0 | %.3f | %.3f", w.Name, cpu, gpu))
		for _, name in names do
			if os.clock() > o.Deadline then
				print("[MARK] deadline hit")
				return
			end
			task.wait(1)
			local before = memorySample()
			local renderer = create(name)
			renderer:Draw(w.List)
			waitReady(renderer)
			task.wait(1)
			cpu, gpu = renderSample()
			print(string.format("[M] %s | %s | %.3f | %.3f | %.3f", w.Name, name, memorySample() - before, cpu, gpu))
			renderer:Destroy()
		end
	end
	print("[MARK] done")
end

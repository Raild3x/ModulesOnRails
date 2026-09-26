-- Navmesh storage benchmark harness (driven by run.py): interleaved rounds (rotated order),
-- best-of-REPS per round, median over rounds. Every loop checks the deadline and prints [MARK]
-- breadcrumbs, so a hang is distinguishable from slow.
local Mesh = require(script.Parent.Mesh)
local gen = script.Parent.gen

local H = {}

local function median(xs)
	local s = table.clone(xs)
	table.sort(s)
	return s[(#s + 1) // 2]
end

local function settle()
	for _ = 1, 3 do
		task.wait()
	end
end

function H.run(cfg)
	local deadline = os.clock() + cfg.budget
	local SIDE, Q, K, REPS, ROUNDS = 224, 2000, 20000, cfg.reps or 3, cfg.rounds or 5
	local CONV_N, CONV_R = 1000, 100
	local base = Mesh.make(SIDE, 7)
	print(string.format("[MARK] mesh V=%d T=%d", base.V, base.T))
	local mods = {}
	for _, L in cfg.layouts do
		mods[L] = require(gen[L])
	end

	-- queries (same RNG stream as the author's b1.luau)
	local rng = Random.new(99)
	local Qd = { qx = table.create(Q), qy = table.create(Q), q3 = table.create(Q), q2 = table.create(Q) }
	for q = 1, Q do
		Qd.qx[q] = rng:NextNumber(1, SIDE - 2)
		Qd.qy[q] = rng:NextNumber(1, SIDE - 2)
		Qd.q3[q] = Vector3.new(Qd.qx[q], Qd.qy[q], 0)
		Qd.q2[q] = Vector2.new(Qd.qx[q], Qd.qy[q])
	end

	for _, meshMode in cfg.meshes do
		local mesh = if meshMode == "grid" then base else Mesh.shuffle(base, 11, meshMode)
		local tp = mesh.tperm
		local src = if tp then tp[1] else 1
		local dst = if tp then tp[mesh.T] else mesh.T
		local stamp = table.create(mesh.T * 2, 0)
		local dist = table.create(mesh.T * 2, 0)
		local genCounter = 0
		local crng = Random.new(5)
		local ids, vsrc, out = table.create(CONV_N), table.create(CONV_N), table.create(CONV_N)
		for i = 1, CONV_N do
			local id = crng:NextInteger(1, mesh.V)
			ids[i] = id
			vsrc[i] = Vector3.new(mesh.xs[id], mesh.ys[id], mesh.zs[id])
		end

		local states, convStates, res, checks, mem = {}, {}, {}, {}, {}
		for _, L in cfg.layouts do
			local before = collectgarbage("count")
			states[L] = mods[L].build(mesh)
			mem[L] = collectgarbage("count") - before
			convStates[L] = mods[L].build(mesh)
			res[L] = {}
			checks[L] = {}
			task.wait()
		end
		print("[MARK] built " .. meshMode)

		local function one(L, w)
			local mod, st = mods[L], states[L]
			genCounter += 1
			if w == "build" then
				local t0 = os.clock()
				local s = mod.build(mesh)
				local dt = os.clock() - t0
				return dt, s.V
			elseif w == "locate" then
				local t0 = os.clock()
				local v = mod.locate(st, Qd, Q)
				return os.clock() - t0, v
			elseif w == "flood" then
				local t0 = os.clock()
				local v = mod.flood(st, stamp, genCounter, src)
				return os.clock() - t0, v
			elseif w == "dijkstra" then
				local t0 = os.clock()
				local d, e = mod.dijkstra(st, src, dst, dist, stamp, genCounter)
				return os.clock() - t0, string.format("%.17g/%d", d, e)
			elseif w == "ins_grow" or w == "ins_settle" or w == "ins_pre" then
				local fresh = if w == "ins_pre" then mod.build(mesh, mesh.V + K, mesh.T + 2 * K) else mod.build(mesh)
				if w ~= "ins_grow" then
					settle()
				end
				local t0 = os.clock()
				mod.insert(fresh, K, 5)
				local dt = os.clock() - t0
				local s, cx = mod.checksum(fresh)
				return dt, string.format("%d/%.17g", s, cx)
			elseif w == "toVec" then
				local t0 = os.clock()
				mod.toVec(convStates[L], ids, out, CONV_N, CONV_R)
				return os.clock() - t0, out[CONV_N].X
			elseif w == "fromVec" then
				local t0 = os.clock()
				mod.fromVec(convStates[L], ids, vsrc, CONV_N, CONV_R)
				return os.clock() - t0, 0
			end
			error(w)
		end

		for round = 1, ROUNDS do
			if os.clock() > deadline then
				warn("[MARK] deadline hit")
				break
			end
			local n = #cfg.layouts
			for k = 0, n - 1 do
				local L = cfg.layouts[(round + k - 1) % n + 1]
				for _, w in cfg.workloads do
					if os.clock() > deadline then
						break
					end
					local best = math.huge
					for _ = 1, REPS do
						local dt, v = one(L, w)
						best = math.min(best, dt)
						checks[L][w] = tostring(v)
					end
					res[L][w] = res[L][w] or {}
					table.insert(res[L][w], best * 1000)
				end
				task.wait()
			end
			print(string.format("[MARK] %s round %d", meshMode, round))
		end

		-- report
		local hdr = { "[HDR]", meshMode, "layout" }
		for _, w in cfg.workloads do
			table.insert(hdr, w)
		end
		print(table.concat(hdr, " | "))
		for _, L in cfg.layouts do
			local row = { string.format("[R] %s %-22s", meshMode, L) }
			for _, w in cfg.workloads do
				local r = res[L][w]
				table.insert(row, if r then string.format("%7.2f", median(r)) else "   n/a")
			end
			table.insert(row, string.format("mem %6.0f KB", mem[L]))
			print(table.concat(row, " | "))
		end
		for _, w in cfg.workloads do
			if w ~= "build" and w ~= "toVec" and w ~= "fromVec" then
				local groups = {}
				for _, L in cfg.layouts do
					local v = checks[L][w] or "?"
					groups[v] = groups[v] or {}
					table.insert(groups[v], L)
				end
				for v, Ls in groups do
					print(string.format("[CHECK] %s %s = %s :: %s", meshMode, w, v, table.concat(Ls, ",")))
				end
			end
		end
		states, convStates = nil, nil
		task.wait()
	end
	print("[MARK] done")
end

return H

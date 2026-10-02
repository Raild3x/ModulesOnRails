--!strict
-- Track F2: Update cost near one huge authored ring. The walkable outline is one noisy circle of
-- n points (radius 150, flat); a 2 x 2 crate sits 3 studs inside it. Each cycle adds the crate
-- (Update) and removes it (Update); cells are medians in ms, by phase. Counts explain the
-- Clearance.Refresh cost: walls swapped in the index, changed walls, triangles the reach rule
-- adds, nearWalls calls and the walls they return.
--   lune run tools/navmesh/bench/huge_ring_update.luau [ns=512,2048] [tiles=8,16,32] [cycles=3]
--     [cap=0] [eps=default] [src=lib/navmesh] [check=0]
-- `eps` sets NavMeshDesc.SimplifyTolerance (eps=0: the ring as given, no simplification).
-- `cap` sets MaxAgentRadius (cap=0: the default, 8 studs; cap=1e999: none).
-- `src` is a copy of lib/navmesh (a prototype); it is copied to .bench/navmesh/hugering/ and
-- clock marks are inserted into the copy's Tiles and Clearance (anchored on code text).
-- `check=1` compares the mesh after each Update with a fresh Build (widths and wall flags).
local fs = require("@lune/fs")
local process = require("@lune/process")

local opts: { [string]: string } = {}
for _, a in process.args do
	local k, v = string.match(a, "^(%w+)=(.*)$")
	if k then
		opts[k] = v
	end
end
local function list(s: string): { number }
	local out = {}
	for x in string.gmatch(s, "[^,]+") do
		table.insert(out, assert(tonumber(x)))
	end
	return out
end
local NS = list(opts.ns or "512,2048")
local TILES = list(opts.tiles or "8,16,32")
local CYCLES = tonumber(opts.cycles) or 3
local CAP = tonumber(opts.cap) or 0
local SRC = opts.src or "lib/navmesh"
local CHECK = opts.check == "1"
local EPS = tonumber(opts.eps)
local PROF = ".bench/navmesh/hugering/" .. (opts.tag or "base")

local function copyDir(from: string, to: string)
	fs.writeDir(to)
	for _, name in fs.readDir(from) do
		local a, b = `{from}/{name}`, `{to}/{name}`
		if fs.isDir(a) then
			copyDir(a, b)
		else
			fs.writeFile(b, fs.readFile(a))
		end
	end
end
if fs.isDir(PROF) then
	fs.removeDir(PROF)
end
copyDir(SRC, `{PROF}/navmesh`)

-- A mark charges the time since the previous one to its name.
local MARK =
	'do local P = _G.PROF; if P then local c = os.clock(); P["%s"] = (P["%s"] or 0) + (c - P._t) * 1000; P._t = c end end\n\t'
local function patch(file: string, marks: { { string } }, extra: { { string } }, more: { { string } }?)
	for _, e in more or {} do
		table.insert(extra, e)
	end
	local path = `{PROF}/navmesh/src/{file}`
	local source = string.gsub(fs.readFile(path), "\r\n", "\n")
	for _, m in marks do
		local start = assert(string.find(source, m[1], 1, true), m[1])
		local at = assert(string.find(source, m[2], start, true), m[2])
		source = string.sub(source, 1, at - 1) .. string.format(MARK, m[3], m[3]) .. string.sub(source, at)
	end
	for _, e in extra do -- plain insertions: code before the anchor
		local at = assert(string.find(source, e[1], 1, true), e[1])
		source = string.sub(source, 1, at - 1) .. e[2] .. string.sub(source, at)
	end
	fs.writeFile(path, source)
end
patch("Tiles.luau", {
	{ "local function prepare", "-- New triangles for each dirty tile.", "prepare" },
	{ "local function prepare", "-- Scratch: vertices interned", "re-snap" },
	{ "local function prepare", "return {\n\t\tPendingFloors", "prepare" },
	{ "local function apply", "-- Clearance. A rebuilt triangle", "apply" },
	{ "local function apply", "local changedTiles = Clearance.Refresh", "width carry" },
	{ "local function apply", "return n, changedRegions", "apply" },
}, {
	{ "\tlocal pendingFloors: { [number]: { { number } } } = {}", "\tif _G.PROF then _G.PROF._t = os.clock() end\n" },
})
local C = "local C = _G.CNT; "
-- computeWidths' inner work (inner=1; it slows the run, so time with inner=0): time in
-- nearWalls and the two chains, Dijkstra pops, relax steps (the pops x walls loop), gap and link
-- evaluations. Their anchors are the shipped code's; a prototype may lack them.
local INNER = if opts.inner == "1"
	then {
		{ "\t\tdone[i] = true", `\t\tdo {C}if C then C.pops += 1 end end\n` },
		{ "\t\t\tlocal bound = math.min(label[j], best)", `\t\t\tdo {C}if C then C.relax += 1 end end\n` },
		{ "\t\t\t\tgap = segSeg(fi, feats[j])", `\t\t\t\tdo {C}if C then C.gapCalls += 1 end end\n` },
		{ "\t\t\t\tcost = linkCost(region, fi, feats[j])", `\t\t\t\tdo {C}if C then C.linkCalls += 1 end end\n` },
		{
			"local feats, toTri, toEdge = nearWalls(index, floor, edges, limit)",
			`do {C}if C then C._c = os.clock() end end\n\t\t\t`,
		},
		{
			"\t\t\tlocal triLinks, gaps = {}, {}",
			`\t\t\tdo {C}if C then C.tNear += (os.clock() - C._c) * 1000 end end\n`,
		},
		{ "r[k] = chain(feats, toTri", `do {C}if C then C._c = os.clock() end end; ` },
		{
			"\n\t\t\t\tend\n\t\t\t\t-- A portal is shared",
			`; do {C}if C then C.tCorner += (os.clock() - C._c) * 1000 end end`,
		},
		{ "r[3 + k] = chain(feats, toEdge[k]", `do {C}if C then C._c = os.clock() end end; ` },
		{ "\n\t\t\t\tend\n\t\t\t\texact = exact", `; do {C}if C then C.tPortal += (os.clock() - C._c) * 1000 end end` },
	}
	else {}
patch("Clearance.luau", {
	{ "function Clearance.Refresh", "local changed: { { number } } = {}", "R: wall swap" },
	{ "function Clearance.Refresh", "-- A neighbour's walls are unchanged", "R: wall swap" },
	{ "function Clearance.Refresh", "-- Reach: every triangle", "R: near flags" },
	{
		"function Clearance.Refresh",
		"computeWidths(n, Storage.GetMaxAgentRadius(n), recompute, index)",
		"R: reach test",
	},
	{ "function Clearance.Refresh", "-- Widths changed in these tiles", "R: computeWidths" },
}, {
	{
		"-- A neighbour's walls are unchanged",
		`do {C}if C then local o = 0; for _ in old do o += 1 end; C.oldOnly += o; C.changed += #changed + o; C.removedTiles += #dirty end end\n\t`,
	},
	{
		"-- Reach: every triangle",
		`do {C}if C then local r = 0; for _ in recompute do r += 1 end; C.newTris += r; C.newSet = table.clone(recompute) end end\n\t`,
	},
	{
		"\tindexes[mesh] = index\n\ttileReaches[mesh] = reaches",
		`do {C}if C then local r = 0; for _ in recompute do r += 1 end; C.recompute += r; local k = 0; for _ in touched do k += 1 end; C.touchedTiles += k end end\n\t`,
	},
	{
		"\t\t\tlocal r = 0\n\t\t\tfor k = 1, 3 do\n\t\t\t\tr = math.max(r, Storage.GetCornerWidth(n, t, k)",
		`\t\t\tdo {C}if C then C.reachTested += 1; C.reachPairs += #changed end end\n`,
	},
	{
		"\t\tlocal first, count = Storage.GetTileRange(n, tile)\n\t\tfor t = first, first + count - 1 do\n\t\t\tif recompute[t]",
		`\t\tdo {C}if C then C.reachTiles += 1 end end\n`,
	},
	{
		"computeWidths(n, Storage.GetMaxAgentRadius(n), recompute, index)",
		`do {C}if C then C.snap = table.create(0); for t in recompute do if not C.newSet[t] then local w = table.create(6); for k = 1, 3 do w[k] = Storage.GetCornerWidth(n, t, k); w[3 + k] = Storage.GetPortalWidth(n, t, k) end; C.snap[t] = w end end end end\n\t`,
	},
	{
		"-- Widths changed in these tiles",
		`do {C}if C then for t, w in C.snap do for k = 1, 3 do if w[k] ~= Storage.GetCornerWidth(n, t, k) or w[3 + k] ~= Storage.GetPortalWidth(n, t, k) then C.widened += 1; break end end end; C.snap = nil; C.newSet = nil end end\n\t`,
	},
	{
		"\t\t\tlocal triLinks, gaps = {}, {}",
		`\t\t\tdo {C}if C and only then C.near += 1; C.feats += #feats; C.feats2 += #feats * #feats; C.maxFeats = math.max(C.maxFeats, #feats); C.maxLimit = math.max(C.maxLimit, limit) end end\n`,
	},
}, INNER)

local root = `../../../{PROF}/navmesh/src/`
local NavMesh = (require :: any)(root .. "NavMesh")
local Build = (require :: any)(root .. "Build")
local Storage = (require :: any)(root .. "Storage")
local MeshChecks = (require :: any)(root .. "Tests/Helpers/MeshChecks")

local function wrap(module: any, name: string, label: string)
	local f = module[name]
	module[name] = function(...)
		local P = _G.PROF
		local t0 = os.clock()
		local a, b, c = f(...)
		if P then
			local spent = (os.clock() - t0) * 1000
			P[label] = (P[label] or 0) + spent
			P._t += spent / 1000
		end
		return a, b, c
	end
end
wrap(Build.Internal, "TileInputs", "TileInputs")
wrap(Build.Internal, "TriangulateTile", "TriangulateTile")

-- The oracle (NavMesh.Obstacles.spec's byTriangle / differsFromFresh, without the draw lists).
local function byTriangle(mesh: any): { [string]: string }
	local out = {}
	for tri = 1, Storage.TriangleCount(mesh) do
		local keys = {}
		local ids = { Storage.GetTriangle(mesh, tri) }
		for k, id in ids do
			local p = Storage.GetVertex(mesh, id)
			keys[k] = math.round(p.X * 256) * 1e7 + math.round(p.Z * 256)
		end
		local first = if keys[1] < keys[2] and keys[1] < keys[3] then 1 elseif keys[2] < keys[3] then 2 else 3
		local widths = {}
		for i = 0, 2 do
			local k = (first + i - 1) % 3 + 1
			table.insert(
				widths,
				string.format("%.6f/%.6f", Storage.GetCornerWidth(mesh, tri, k), Storage.GetPortalWidth(mesh, tri, k))
			)
		end
		for i = 0, 2 do
			table.insert(widths, if Storage.IsWallVertex(mesh, ids[(first + i - 1) % 3 + 1]) then "w" else "-")
		end
		out[`{keys[first]}:{keys[first % 3 + 1]}:{keys[(first + 1) % 3 + 1]}`] = table.concat(widths, " ")
	end
	return out
end
local function differsFromFresh(mesh: any, fresh: any): string
	if Storage.TriangleCount(mesh) ~= Storage.TriangleCount(fresh) then
		return `{Storage.TriangleCount(mesh)} triangles vs {Storage.TriangleCount(fresh)}`
	end
	if Storage.VertexCount(mesh) ~= Storage.VertexCount(fresh) then
		return `{Storage.VertexCount(mesh)} vertices vs {Storage.VertexCount(fresh)}`
	end
	local updated, expected = byTriangle(mesh), byTriangle(fresh)
	for key, widths in expected do
		if updated[key] ~= widths then
			return `{key}: {updated[key]} vs {widths}`
		end
	end
	return table.concat(MeshChecks.Structure(mesh), "\n")
end

local CX, CZ, R = 200, 200, 150
local function ring(n: number): { vector }
	local out = table.create(n)
	for k = 0, n - 1 do
		local a = 2 * math.pi * k / n
		local r = R + 0.3 * math.sin(k * 7.3) + 0.2 * math.sin(k * 1.7) -- deterministic noise
		out[k + 1] = vector.create(CX + r * math.cos(a), 0, CZ + r * math.sin(a))
	end
	return out
end
local cx, cz = CX + R - 4, CZ + 0.37 -- 3 studs inside the outline
local crate = {
	vector.create(cx - 1, 0, cz - 1),
	vector.create(cx + 1, 0, cz - 1),
	vector.create(cx + 1, 0, cz + 1),
	vector.create(cx - 1, 0, cz + 1),
}

local function median(xs: { number }): number
	local s = table.clone(xs)
	table.sort(s)
	return s[(#s + 1) // 2]
end

local ORDER = {
	"prepare",
	"re-snap",
	"TileInputs",
	"TriangulateTile",
	"apply",
	"width carry",
	"R: wall swap",
	"R: near flags",
	"R: reach test",
	"R: computeWidths",
}
local COUNTS = {
	"removedTiles",
	"changed",
	"oldOnly",
	"newTris",
	"reachTiles",
	"reachTested",
	"reachPairs",
	"recompute",
	"widened",
	"touchedTiles",
	"near",
	"feats",
	"feats2",
	"maxFeats",
	"maxLimit",
	"pops",
	"relax",
	"gapCalls",
	"linkCalls",
	"tNear",
	"tCorner",
	"tPortal",
}

print(`src {SRC}, cap {CAP}; ms per Update, median of {CYCLES}; counts are per Update (last run)`)
print("| n | TileSize | op | tris | total | " .. table.concat(ORDER, " | ") .. " |")
print("|" .. string.rep("---|", #ORDER + 5))
local countRows = {}
for _, n in NS do
	for _, tileSize in TILES do
		local desc: any = {
			TileSize = tileSize,
			SimplifyTolerance = EPS,
			Floors = { Ground = { Walkable = { ring(n) } } },
		}
		if CAP > 0 then
			desc.MaxAgentRadius = CAP
		end
		local t0 = os.clock()
		local mesh = NavMesh.Build(desc)
		local buildMs = (os.clock() - t0) * 1000
		local runs: { [string]: { { [string]: number } } } = { add = {}, remove = {} }
		local counts: { [string]: { [string]: number } } = {}
		local lastId
		for cycle = 0, CYCLES do -- cycle 0 is a warm-up
			for _, op in { "add", "remove" } do
				local id
				if op == "add" then
					id = NavMesh.AddObstacle(mesh, "Ground", crate)
				else
					NavMesh.RemoveObstacle(mesh, lastId)
				end
				_G.PROF = { _t = os.clock() }
				local cnt = {}
				for _, k in COUNTS do
					cnt[k] = 0
				end
				_G.CNT = cnt
				t0 = os.clock()
				NavMesh.Update(mesh)
				local total = (os.clock() - t0) * 1000
				local P = _G.PROF
				_G.PROF, _G.CNT = nil, nil
				P._t = nil
				P.total = total
				if op == "add" then
					lastId = id
				end
				if cycle > 0 then
					table.insert(runs[op], P)
					counts[op] = cnt
				end
				if CHECK and cycle == 1 then
					local want = if op == "add"
						then (function()
							local d = table.clone(desc)
							d.Floors = { Ground = { Walkable = desc.Floors.Ground.Walkable, Obstacles = { crate } } }
							return d
						end)()
						else desc
					local diff = differsFromFresh(mesh, NavMesh.Build(want))
					print(`  oracle n={n} ts={tileSize} {op}: {if diff == "" then "equal" else diff}`)
				end
			end
		end
		for _, op in { "add", "remove" } do
			local cells = {}
			for _, k in ORDER do
				local xs = {}
				for _, P in runs[op] do
					table.insert(xs, P[k] or 0)
				end
				table.insert(cells, string.format("%.1f", median(xs)))
			end
			local totals = {}
			for _, P in runs[op] do
				table.insert(totals, P.total)
			end
			print(
				string.format(
					"| %d | %d | %s | %d | %.1f | %s |",
					n,
					tileSize,
					op,
					Storage.TriangleCount(mesh),
					median(totals),
					table.concat(cells, " | ")
				)
			)
			local c = counts[op]
			local cells2 = {}
			for _, k in COUNTS do
				table.insert(cells2, if c[k] == math.floor(c[k]) then tostring(c[k]) else string.format("%.0f", c[k]))
			end
			table.insert(
				countRows,
				`| {n} | {tileSize} | {op} | {string.format("%.0f", buildMs)} | {table.concat(cells2, " | ")} |`
			)
		end
	end
end
print("")
print("| n | TileSize | op | Build ms | " .. table.concat(COUNTS, " | ") .. " |")
print("|" .. string.rep("---|", #COUNTS + 4))
for _, row in countRows do
	print(row)
end

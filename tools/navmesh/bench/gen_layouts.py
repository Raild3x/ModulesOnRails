"""Layout generator for the navmesh storage benchmark (the audited B1 harness, bench.md).

One workload template per math style (scalar / vector); coordinate storage and topology storage
swap independently, so each is isolated. Every layout gets monomorphic code: no layout pays for
another's abstraction. All modules are --!native.

Usage: python gen_layouts.py <out-dir>   (run.py calls this; the output is not committed)
"""
import sys
from pathlib import Path

OUT = Path(sys.argv[1])
OUT.mkdir(parents=True, exist_ok=True)
for p in OUT.glob("*.luau"):
    p.unlink()

# ---------------- coordinate storages ----------------
class Tbl:
    """number table(s): interleaved or split."""
    def __init__(s, d, split, typed=False):
        s.d, s.split, s.typed = d, split, typed
        s.fields = ["XS", "YS", "ZS"][:d] if split else ["C"]
        s.vec = None
    def locals(s):
        ann = ": {number}" if s.typed else ""
        return "; ".join(f"local {f}{ann} = state.{f}" for f in s.fields)
    def comp(s, v, k):
        if s.split:
            return f"{s.fields[k]}[{v}]"
        return f"C[{s.d} * ({v}) - {s.d - 1 - k}]" if s.d - 1 - k else f"C[{s.d} * ({v})]"
    def load(s, pre, v, n):
        return "local " + ", ".join(f"{pre}{'xyz'[k]}" for k in range(n)) + " = " + ", ".join(s.comp(v, k) for k in range(n))
    def store(s, v, xs):
        return "; ".join(f"{s.comp(v, k)} = {x}" for k, x in enumerate(xs))
    def build(s):
        src = ["zs"][:0]
        if s.split:
            lines = [f"local {f} = table.create(capV)" for f in s.fields]
            body = "; ".join(f"{s.fields[k]}[v] = {['xs','ys','zs'][k]}[v]" for k in range(s.d))
        else:
            lines = [f"local C = table.create({s.d} * capV)"]
            body = "; ".join(f"{s.comp('v', k)} = {['xs','ys','zs'][k]}[v]" for k in range(s.d))
        return "\n\t".join(lines) + f"\n\tfor v = 1, V do {body} end", {f: f for f in s.fields}
    grow = ""

class Buf:
    def __init__(s, d, f32, typed=False):
        s.d, s.f32, s.typed = d, f32, typed
        s.sz = 4 if f32 else 8
        s.stride = d * s.sz
        s.fn = "f32" if f32 else "f64"
        s.vec = None
    def locals(s):
        return "local CB" + (": buffer" if s.typed else "") + " = state.CB"
    def off(s, v, k):
        return f"(({v}) - 1) * {s.stride}" + (f" + {k * s.sz}" if k else "")
    def comp(s, v, k):
        return f"buffer.read{s.fn}(CB, {s.off(v, k)})"
    def load(s, pre, v, n):
        return "local " + ", ".join(f"{pre}{'xyz'[k]}" for k in range(n)) + " = " + ", ".join(s.comp(v, k) for k in range(n))
    def store(s, v, xs):
        return "; ".join(f"buffer.write{s.fn}(CB, {s.off(v, k)}, {x})" for k, x in enumerate(xs))
    def build(s):
        body = "; ".join(f"buffer.write{s.fn}(CB, {s.off('v', k)}, {['xs','ys','zs'][k]}[v])" for k in range(s.d))
        return f"local CB = buffer.create(capV * {s.stride})\n\tfor v = 1, V do {body} end", {"CB": "CB", "capV": "capV"}
    @property
    def grow(s):
        return f"""if V > state.capV then
			state.capV *= 2
			local nc = buffer.create(state.capV * {s.stride})
			buffer.copy(nc, 0, CB)
			CB = nc
			state.CB = nc
		end"""

class Vec:
    """{Vector3} or {Vector2} array."""
    def __init__(s, d, kind, typed=False):
        s.d, s.kind, s.typed = d, kind, typed  # kind: "Vector3" | "Vector2"
        s.vec = kind
    def locals(s):
        return "local P" + (f": {{{s.kind}}}" if s.typed else "") + " = state.P"
    def load(s, pre, v, n):
        ann = f": {s.kind}" if s.typed else ""
        return f"local p_{pre}{ann} = P[{v}]; local " + ", ".join(f"{pre}{'xyz'[k]}" for k in range(n)) + " = " + ", ".join(f"p_{pre}.{'XYZ'[k]}" for k in range(n))
    def ctor(s, xs):
        if s.kind == "Vector2":
            return f"Vector2.new({xs[0]}, {xs[1]})"
        return f"Vector3.new({xs[0]}, {xs[1]}, {xs[2] if len(xs) > 2 else 0})"
    def store(s, v, xs):
        return f"P[{v}] = {s.ctor(xs)}"
    def build(s):
        return f"local P = table.create(capV)\n\tfor v = 1, V do P[v] = {s.ctor(['xs[v]', 'ys[v]', 'zs[v]'][:s.d])} end", {"P": "P"}
    grow = ""

# ---------------- topology storages ----------------
class TTopo:
    def __init__(s, typed=False):
        s.typed = typed
    def locals(s):
        ann = ": {number}" if s.typed else ""
        return f"local TVt{ann}, NBt{ann} = state.TV, state.NB"
    def tv(s, i): return f"TVt[{i}]"
    def nb(s, i): return f"NBt[{i}]"
    def settv(s, i, v): return f"TVt[{i}] = {v}"
    def setnb(s, i, v): return f"NBt[{i}] = {v}"
    def build(s):
        return """local TVt = table.create(3 * capT)
	local NBt = table.create(3 * capT)
	for i = 1, 3 * T do
		TVt[i] = tris[i]
		NBt[i] = nbrs[i]
	end""", {"TV": "TVt", "NB": "NBt"}
    grow = ""

class BTopo:
    def __init__(s, typed=False):
        s.typed = typed
    def locals(s):
        ann = ": buffer" if s.typed else ""
        return f"local TB{ann}, NBB{ann} = state.TB, state.NBB"
    def tv(s, i): return f"buffer.readi32(TB, (({i}) - 1) * 4)"
    def nb(s, i): return f"buffer.readi32(NBB, (({i}) - 1) * 4)"
    def settv(s, i, v): return f"buffer.writei32(TB, (({i}) - 1) * 4, {v})"
    def setnb(s, i, v): return f"buffer.writei32(NBB, (({i}) - 1) * 4, {v})"
    def build(s):
        return """local TB = buffer.create(capT * 12)
	local NBB = buffer.create(capT * 12)
	for i = 1, 3 * T do
		buffer.writei32(TB, (i - 1) * 4, tris[i])
		buffer.writei32(NBB, (i - 1) * 4, nbrs[i])
	end""", {"TB": "TB", "NBB": "NBB", "capT": "capT"}
    grow = """if T > state.capT then
			state.capT *= 2
			local nt = buffer.create(state.capT * 12)
			buffer.copy(nt, 0, TB)
			TB = nt
			state.TB = nt
			local nn = buffer.create(state.capT * 12)
			buffer.copy(nn, 0, NBB)
			NBB = nn
			state.NBB = nn
		end"""

# ---------------- math styles ----------------
# style: "scalar" | "vlib" | "vmeth"
def crossz(style, kind, u, w):
    if kind == "Vector2":
        return f"({u}):Cross({w})"
    if style == "vlib":
        return f"vector.cross({u}, {w}).Z"
    return f"({u}):Cross({w}).Z"

def mag(style, e):
    if style == "vlib":
        return f"vector.magnitude({e})"
    return f"({e}).Magnitude"

def render(name, cs, tp, style, d):
    L = cs.locals() + "\n\t" + tp.locals()
    TV, NB, SETTV, SETNB = tp.tv, tp.nb, tp.settv, tp.setnb
    vec = style != "scalar"
    ann = f": {cs.kind}" if (vec and cs.typed) else ""
    comps = "xyz"[:d]

    # --- per-style snippets
    if vec:
        qsetup = f"local qv = Qd.{'q2' if cs.kind == 'Vector2' else 'q3'}"
        qload = f"local p{ann} = qv[q]"
        tri_load = "\n\t\t\t".join(f"local p{n}{ann} = P[{n}]" for n in "abc")
        o1 = crossz(style, cs.kind, "pc - pb", "p - pb")
        o2 = crossz(style, cs.kind, "pa - pc", "p - pc")
        o3 = crossz(style, cs.kind, "pb - pa", "p - pa")
        cen_body = "\n\t\t".join(f"local p{n}{ann} = P[{n}]" for n in "abc") + "\n\t\treturn (pa + pb + pc) / 3"
        dj_t = "local tc = centroid(t)"
        dj_n = "local nc = centroid(n)"
        dj_d = f"local nd = k + {mag(style, 'nc - tc')}"
        ins_load = "\n\t\t".join(f"local p{n}{ann} = P[{n}]" for n in "abc")
        ins_store = "P[V] = (pa + pb + pc) / 3"
    else:
        qsetup = "local qx, qy = Qd.qx, Qd.qy"
        qload = "local px, py = qx[q], qy[q]"
        tri_load = "\n\t\t\t".join(cs.load(f"{n}", n, 2) for n in "abc")
        o1 = "(cx - bx) * (py - by) - (cy - by) * (px - bx)"
        o2 = "(ax - cx) * (py - cy) - (ay - cy) * (px - cx)"
        o3 = "(bx - ax) * (py - ay) - (by - ay) * (px - ax)"
        cen_body = "\n\t\t".join(cs.load(f"{n}", n, d) for n in "abc") + "\n\t\treturn " + ", ".join(f"(a{k} + b{k} + c{k}) / 3" for k in comps)
        dj_t = "local " + ", ".join(f"t{k}" for k in comps) + " = centroid(t)"
        dj_n = "local " + ", ".join(f"n{k}" for k in comps) + " = centroid(n)"
        dj_d = "local " + ", ".join(f"d{k}" for k in comps) + " = " + ", ".join(f"n{k} - t{k}" for k in comps) + \
            "\n\t\t\t\t\tlocal nd = k + math.sqrt(" + " + ".join(f"d{k} * d{k}" for k in comps) + ")"
        ins_load = "\n\t\t".join(cs.load(f"{n}", n, d) for n in "abc")
        ins_store = cs.store("V", [f"(a{k} + b{k} + c{k}) / 3" for k in comps])

    cbuild, cfields = cs.build()
    tbuild, tfields = tp.build()
    fields = {**cfields, **tfields}
    ret = ", ".join(f"{k} = {v}" for k, v in fields.items())

    # conversion: storage -> Vector3 and Vector3 -> storage
    if isinstance(cs, Vec):
        if cs.kind == "Vector3":
            tovec = "out[i] = P[id]"
            fromvec = "P[id] = src[i]"
        else:
            tovec = "local pp = P[id]; out[i] = Vector3.new(pp.X, pp.Y, 0)"
            fromvec = "local s = src[i]; P[id] = Vector2.new(s.X, s.Y)"
    else:
        tovec = cs.load("u", "id", d) + "; out[i] = Vector3.new(" + ", ".join(f"u{k}" for k in comps) + (", 0" if d == 2 else "") + ")"
        fromvec = "local s = src[i]; " + cs.store("id", [f"s.{'XYZ'[k]}" for k in range(d)])

    src = f'''--!native
-- AUDIT GENERATED: {name} (style={style}, dims={d})
local M = {{}}
local MAX_STEPS = 200000

function M.build(mesh, capV, capT)
	local V, T = mesh.V, mesh.T
	capV, capT = capV or V, capT or T
	local xs, ys, zs, tris, nbrs = mesh.xs, mesh.ys, mesh.zs, mesh.tris, mesh.nbrs
	{cbuild}
	{tbuild}
	return {{ {ret}, V = V, T = T }}
end

function M.locate(state, Qd, Q)
	{L}
	{qsetup}
	local found = 0
	local t = 1
	for q = 1, Q do
		{qload}
		local steps = 0
		while true do
			steps += 1
			if steps > MAX_STEPS then
				t = 1
				break
			end
			local base = (t - 1) * 3
			local a = {TV("base + 1")}
			local b = {TV("base + 2")}
			local c = {TV("base + 3")}
			{tri_load}
			local n = 0
			if {o1} < 0 then
				n = {NB("base + 1")}
			elseif {o2} < 0 then
				n = {NB("base + 2")}
			elseif {o3} < 0 then
				n = {NB("base + 3")}
			else
				found += t
				break
			end
			if n == 0 then
				break
			end
			t = n
		end
	end
	return found
end

function M.flood(state, stamp, gen, start)
	{L}
	local stack = table.create(1024)
	local top = 1
	stack[1] = start
	stamp[start] = gen
	local count = 0
	while top > 0 do
		local t = stack[top]
		top -= 1
		count += 1
		local base = (t - 1) * 3
		for e = 1, 3 do
			local n = {NB("base + e")}
			if n ~= 0 and stamp[n] ~= gen then
				stamp[n] = gen
				top += 1
				stack[top] = n
			end
		end
	end
	return count
end

function M.dijkstra(state, src, dst, dist, stamp, gen)
	{L}
	local function centroid(t)
		local base = (t - 1) * 3
		local a = {TV("base + 1")}
		local b = {TV("base + 2")}
		local c = {TV("base + 3")}
		{cen_body}
	end
	local heapT, heapK = table.create(4096), table.create(4096)
	local size = 1
	heapT[1], heapK[1] = src, 0
	dist[src] = 0
	stamp[src] = gen
	local expanded = 0
	while size > 0 do
		local t, k = heapT[1], heapK[1]
		heapT[1], heapK[1] = heapT[size], heapK[size]
		heapT[size], heapK[size] = nil, nil
		size -= 1
		local i = 1
		while true do
			local l = i * 2
			if l > size then
				break
			end
			local r = l + 1
			local m = if r <= size and heapK[r] < heapK[l] then r else l
			if heapK[m] >= heapK[i] then
				break
			end
			heapT[i], heapT[m] = heapT[m], heapT[i]
			heapK[i], heapK[m] = heapK[m], heapK[i]
			i = m
		end
		if k > dist[t] then
			continue
		end
		expanded += 1
		if t == dst then
			break
		end
		{dj_t}
		local base = (t - 1) * 3
		for e = 1, 3 do
			local n = {NB("base + e")}
			if n ~= 0 then
				{dj_n}
				{dj_d}
				if stamp[n] ~= gen or nd < dist[n] then
					stamp[n] = gen
					dist[n] = nd
					size += 1
					heapT[size], heapK[size] = n, nd
					local j = size
					while j > 1 do
						local p = j // 2
						if heapK[p] <= heapK[j] then
							break
						end
						heapT[p], heapT[j] = heapT[j], heapT[p]
						heapK[p], heapK[j] = heapK[j], heapK[p]
						j = p
					end
				end
			end
		end
	end
	return dist[dst], expanded
end

function M.insert(state, K, seed)
	{L}
	local rng = Random.new(seed)
	local V, T = state.V, state.T
	for _ = 1, K do
		local t = rng:NextInteger(1, T)
		local base = (t - 1) * 3
		local a = {TV("base + 1")}
		local b = {TV("base + 2")}
		local c = {TV("base + 3")}
		{ins_load}
		V += 1
		{cs.grow}
		{ins_store}
		local n1 = {NB("base + 1")}
		local n2 = {NB("base + 2")}
		local n3 = {NB("base + 3")}
		local t2, t3 = T + 1, T + 2
		T += 2
		{tp.grow}
		{SETTV("base + 3", "V")}
		{SETNB("base + 1", "t2")}
		{SETNB("base + 2", "t3")}
		{SETNB("base + 3", "n3")}
		local b2 = (t2 - 1) * 3
		{SETTV("b2 + 1", "b")}
		{SETTV("b2 + 2", "c")}
		{SETTV("b2 + 3", "V")}
		{SETNB("b2 + 1", "t3")}
		{SETNB("b2 + 2", "t")}
		{SETNB("b2 + 3", "n1")}
		local b3 = (t3 - 1) * 3
		{SETTV("b3 + 1", "c")}
		{SETTV("b3 + 2", "a")}
		{SETTV("b3 + 3", "V")}
		{SETNB("b3 + 1", "t")}
		{SETNB("b3 + 2", "t2")}
		{SETNB("b3 + 3", "n2")}
		if n1 ~= 0 then
			local nb = (n1 - 1) * 3
			for e = 1, 3 do
				if {NB("nb + e")} == t then
					{SETNB("nb + e", "t2")}
				end
			end
		end
		if n2 ~= 0 then
			local nb = (n2 - 1) * 3
			for e = 1, 3 do
				if {NB("nb + e")} == t then
					{SETNB("nb + e", "t3")}
				end
			end
		end
	end
	state.V, state.T = V, T
	return V + T
end

-- Order-sensitive checksum of topology + exact coordinate sum (%.17g) for cross-checking.
function M.checksum(state)
	{L}
	local s = 0
	for i = 1, 3 * state.T do
		s = (s * 31 + {TV("i")} * 7 + {NB("i")}) % 1000000007
	end
	local cx = 0
	for v = 1, state.V do
		{cs.load("w", "v", d) if not vec else "local p_w = P[v]; local " + ", ".join(f"w{k}" for k in comps) + " = " + ", ".join(f"p_w.{k.upper()}" for k in comps)}
		cx += {" + ".join(f"w{k} * {j + 1}" for j, k in enumerate(comps))}
	end
	return s, cx
end

function M.toVec(state, ids, out, n, R)
	{L}
	for _ = 1, R do
		for i = 1, n do
			local id = ids[i]
			{tovec}
		end
	end
	return out[n]
end

function M.fromVec(state, ids, src, n, R)
	{L}
	for _ = 1, R do
		for i = 1, n do
			local id = ids[i]
			{fromvec}
		end
	end
	return n
end

return M
'''
    (OUT / f"{name}.luau").write_text(src, encoding="utf-8", newline="\n")

LAYOUTS2 = {
    # --- replicas of the author's 2D layouts
    "A_interleaved": (Tbl(2, False), TTopo(), "scalar"),
    "B_split": (Tbl(2, True), TTopo(), "scalar"),
    "C_buf_f64": (Buf(2, False), BTopo(), "scalar"),
    "C_buf_f32": (Buf(2, True), BTopo(), "scalar"),
    "D3_scalar": (Vec(2, "Vector3"), TTopo(), "scalar"),
    "D2_scalar": (Vec(2, "Vector2"), TTopo(), "scalar"),
    # --- isolate coords vs topology
    "H_tblXY_bufTopo": (Tbl(2, True), BTopo(), "scalar"),
    "H_bufXY_tblTopo": (Buf(2, False), TTopo(), "scalar"),
    # --- type annotations
    "C_buf_f64_typed": (Buf(2, False, True), BTopo(True), "scalar"),
    "D3_scalar_typed": (Vec(2, "Vector3", True), TTopo(True), "scalar"),
    # --- vector-idiomatic
    "D3_vlib": (Vec(2, "Vector3"), TTopo(), "vlib"),
    "D3_vlib_typed": (Vec(2, "Vector3", True), TTopo(True), "vlib"),
    "D3_vmeth": (Vec(2, "Vector3"), TTopo(), "vmeth"),
    "D2_vmeth": (Vec(2, "Vector2"), TTopo(), "vmeth"),
    "D3_vlib_typed_bufTopo": (Vec(2, "Vector3", True), BTopo(True), "vlib"),
}
LAYOUTS3 = {
    "T3_interleaved": (Tbl(3, False), TTopo(), "scalar"),
    "T3_split": (Tbl(3, True), TTopo(), "scalar"),
    "B3_f64": (Buf(3, False), BTopo(), "scalar"),
    "B3_f32": (Buf(3, True), BTopo(), "scalar"),
    "B3_f64_tblTopo": (Buf(3, False), TTopo(), "scalar"),
    "V3_scalar_typed": (Vec(3, "Vector3", True), TTopo(True), "scalar"),
    "V3_vlib_typed": (Vec(3, "Vector3", True), TTopo(True), "vlib"),
    "V3_vmeth_typed": (Vec(3, "Vector3", True), TTopo(True), "vmeth"),
    "V3_vlib_typed_bufTopo": (Vec(3, "Vector3", True), BTopo(True), "vlib"),
    "T3_split_bufTopo": (Tbl(3, True), BTopo(), "scalar"),
}
for name, (cs, tp, style) in LAYOUTS2.items():
    render("L2_" + name, cs, tp, style, 2)
for name, (cs, tp, style) in LAYOUTS3.items():
    render("L3_" + name, cs, tp, style, 3)
print("generated", len(list(OUT.glob("*.luau"))))

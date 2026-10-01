--!strict
-- Repros (Track M2, ticket 37): three ways NavMesh.Build rejects input that Part terrain makes.
-- Each prints `false` and the error today. known-gaps.md, "Found by Track M2", has the details.
--   lune run tools/navmesh/bench/core_seam_repros.luau
local NavMesh = require("../../../lib/navmesh/src/NavMesh")

local function v(x: number, y: number, z: number): any
	return vector.create(x, y, z)
end
-- Prints whether f(...) ran, and its error if not.
local function try(label: string, f: (...any) -> ...any, ...: any)
	local ok, err = pcall(f, ...)
	print(label, if ok then "ok" else `false {err}`)
end
local function ring(x0: number, z0: number, x1: number, z1: number): { any }
	return { v(x0, 0, z0), v(x1, 0, z0), v(x1, 0, z1), v(x0, 0, z1) }
end

-- 1. An obstacle covering a whole seam on one floor. Floors A (x 0-10) and B (x 10-20) meet at
--    x = 10, z 0-4; a crate on A covers that seam.
local seam = { FloorA = "A", FloorB = "B", From = v(10, 0, 0), To = v(10, 0, 4) }
local function covered(crate: boolean): any
	return {
		Floors = {
			A = { Walkable = { ring(0, 0, 10, 10) }, Obstacles = if crate then { ring(8, -1, 11, 5) } else nil },
			B = { Walkable = { ring(10, 0, 20, 4) } },
		},
		Seams = { seam },
		MaxAgentRadius = 1,
	}
end
try("1. Build, crate over the seam:", NavMesh.Build, covered(true))
local mesh = NavMesh.Build(covered(false))
NavMesh.AddObstacle(mesh, "A", ring(8, -1, 11, 5))
try("1. Update, crate dropped on the seam:", NavMesh.Update, mesh)

-- 2. A seam ending mid-edge on a diagonal, 7e-6 studs off it: x rounds up on the 1/256 grid and
--    z rounds down, so the end lands a grid step off the floor's edge.
local function diagonal(ex: number, ez: number): any
	return {
		Floors = {
			A = { Walkable = { { v(0, 0, 0), v(10, 0, 0), v(10, 0, 10) } } },
			B = { Walkable = { { v(0, 0, 0), v(10, 0, 10), v(0, 0, 10) } } },
		},
		Seams = { { FloorA = "A", FloorB = "B", From = v(0, 0, 0), To = v(ex, 0, ez) } },
		MaxAgentRadius = 1,
	}
end
try("2. seam end on the diagonal:", NavMesh.Build, diagonal(5.001953125, 5.001953125))
try("2. seam end 7e-6 off it:", NavMesh.Build, diagonal(5.001953125, 5.0019459))

-- 3. A convex obstacle with two corners 0.003 studs apart: on the grid they swap, and the ring
--    folds back on itself. (The adapter's cut of a meadow wedge on its neighbour, from f32 data.)
local fold = {
	v(19.999969482, 0, 99.999984741),
	v(29.985008240, 0, 99.998062134),
	v(30.001983643, 0, 99.998062134),
	v(30.000024796, 0, 100.000038147),
	v(24.999969482, 0, 104.999984741),
}
try("3. obstacle with corners 0.003 apart:", NavMesh.Build, {
	Floors = { A = { Walkable = { ring(0, 90, 40, 110) }, Obstacles = { fold } } },
})

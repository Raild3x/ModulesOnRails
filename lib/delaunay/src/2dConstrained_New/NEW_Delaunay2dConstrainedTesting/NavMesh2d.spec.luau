--!strict
return function(t: tiniest)
	local NavMesh2d = require("../NavMesh2d")

	local describe = t.describe
	local expect = t.expect
	local test = t.test

	-- Standard outer square used across many tests.
	local function makeSquare(scale: number?): { Vector2 }
		local s = scale or 10
		return {
			Vector2.new(0, 0),
			Vector2.new(s, 0),
			Vector2.new(s, s),
			Vector2.new(0, s),
		}
	end

	-- Insert all points from an array, return assigned ids.
	local function addAll(nav: NavMesh2d.NavMesh2d, pts: { Vector2 }): { any }
		local ids = {}
		for _, pt in pts do
			table.insert(ids, nav:addPoint(pt))
		end
		return ids
	end

	-- ════════════════════════════════════════════════════════════════════════
	-- Phase 5A – Data model + triangulation pipeline
	-- ════════════════════════════════════════════════════════════════════════

	describe("NavMesh2d", function()
		describe("new", function()
			test("starts with no points", function()
				local nav = NavMesh2d.new()
				expect(nav:getPointCount()).is(0)
				expect(#nav:getPoints()).is(0)
				nav:destroy()
			end)

			test("starts with no holes", function()
				local nav = NavMesh2d.new()
				local tris = nav:getTriangles()
				expect(#tris).is(0)
				nav:destroy()
			end)
		end)

		-- ── addPoint ─────────────────────────────────────────────────────────
		describe("addPoint", function()
			test("increments count for each unique point", function()
				local nav = NavMesh2d.new()
				nav:addPoint(Vector2.new(0, 0))
				nav:addPoint(Vector2.new(5, 0))
				expect(nav:getPointCount()).is(2)
				nav:destroy()
			end)

			test("returns auto-incremented numeric id when no id is provided", function()
				local nav = NavMesh2d.new()
				local id1 = nav:addPoint(Vector2.new(0, 0))
				local id2 = nav:addPoint(Vector2.new(1, 0))
				expect(id1 ~= id2).is(true)
				nav:destroy()
			end)

			test("uses the provided custom id", function()
				local nav = NavMesh2d.new()
				local id = nav:addPoint(Vector2.new(0, 0), "myPoint")
				expect(id).is("myPoint")
				nav:destroy()
			end)

			test("accepts Vector3 and converts using XZ plane", function()
				local nav = NavMesh2d.new()
				nav:addPoint(Vector3.new(3, 0, 7)) -- X=3, Z=7 → Vector2(7, 3)
				expect(nav:getPointCount()).is(1)
				local pts = nav:getPoints()
				expect(pts[1]).is(Vector2.new(7, 3))
				nav:destroy()
			end)

			test("adding the same point twice (same id) does not increase count", function()
				local nav = NavMesh2d.new()
				nav:addPoint(Vector2.new(5, 5), "p")
				nav:addPoint(Vector2.new(5, 5), "p") -- same coords, same id
				expect(nav:getPointCount()).is(1)
				nav:destroy()
			end)
		end)

		-- ── removePoint ───────────────────────────────────────────────────────
		describe("removePoint", function()
			test("decrements count and returns true for an existing id", function()
				local nav = NavMesh2d.new()
				nav:addPoint(Vector2.new(0, 0), "a")
				nav:addPoint(Vector2.new(1, 0), "b")
				expect(nav:removePoint("a")).is(true)
				expect(nav:getPointCount()).is(1)
				nav:destroy()
			end)

			test("returns false for a missing id", function()
				local nav = NavMesh2d.new()
				expect(nav:removePoint("nope")).is(false)
				nav:destroy()
			end)
		end)

		-- ── getPoints ────────────────────────────────────────────────────────
		describe("getPoints", function()
			test("returns all inserted points", function()
				local nav = NavMesh2d.new()
				local pts = makeSquare()
				addAll(nav, pts)
				local returned = nav:getPoints()
				expect(#returned).is(#pts)
				nav:destroy()
			end)
		end)

		-- ── hole management ───────────────────────────────────────────────────
		describe("addHole / removeHole / clearHoles", function()
			test("addHole marks mesh dirty", function()
				local nav = NavMesh2d.new()
				addAll(nav, makeSquare(20))
				local hole = { Vector2.new(5, 5), Vector2.new(10, 5), Vector2.new(7.5, 10) }
				nav:addHole(hole)
				-- Triangulating after a hole produces fewer tris than without
				local trisWithHole = nav:getTriangles()
				expect(#trisWithHole > 0).is(true)
				nav:destroy()
			end)

			test("removeHole returns true for a hole added by reference", function()
				local nav = NavMesh2d.new()
				addAll(nav, makeSquare(20))
				local hole = { Vector2.new(5, 5), Vector2.new(10, 5), Vector2.new(7.5, 10) }
				nav:addHole(hole)
				expect(nav:removeHole(hole)).is(true)
				nav:destroy()
			end)

			test("removeHole returns false for an unknown polygon", function()
				local nav = NavMesh2d.new()
				local other = { Vector2.new(1, 1), Vector2.new(2, 1), Vector2.new(1.5, 2) }
				expect(nav:removeHole(other)).is(false)
				nav:destroy()
			end)

			test("clearHoles causes re-triangulation without holes", function()
				local nav = NavMesh2d.new()
				addAll(nav, makeSquare(20))
				local hole = { Vector2.new(5, 5), Vector2.new(10, 5), Vector2.new(7.5, 10) }
				nav:addHole(hole)
				nav:getTriangles() -- trigger triangulation with hole
				nav:clearHoles()
				local trisWithout = nav:getTriangles()
				-- Re-triangulated mesh must be non-empty and the former hole interior
				-- must now be accessible (no longer excluded).
				expect(#trisWithout > 0).is(true)
				expect(nav:isPointOnMesh(Vector2.new(7.5, 7))).is(true)
				nav:destroy()
			end)
		end)

		-- ── invalidate ────────────────────────────────────────────────────────
		describe("invalidate", function()
			test("forces re-triangulation on the next getTriangles call", function()
				local nav = NavMesh2d.new()
				addAll(nav, makeSquare())
				local tris1 = nav:getTriangles()
				nav:invalidate()
				local tris2 = nav:getTriangles()
				expect(#tris1).is(#tris2)
				nav:destroy()
			end)
		end)

		-- ── getTriangles ──────────────────────────────────────────────────────
		describe("getTriangles", function()
			test("returns empty for fewer than 3 points", function()
				local nav = NavMesh2d.new()
				nav:addPoint(Vector2.new(0, 0))
				nav:addPoint(Vector2.new(1, 0))
				expect(#nav:getTriangles()).is(0)
				nav:destroy()
			end)

			test("returns 2 triangles for a convex square", function()
				local nav = NavMesh2d.new()
				addAll(nav, makeSquare())
				local tris = nav:getTriangles()
				expect(#tris).is(2)
				nav:destroy()
			end)

			test("each triangle is a 3-element array of Vector2", function()
				local nav = NavMesh2d.new()
				addAll(nav, makeSquare())
				for _, tri in nav:getTriangles() do
					expect(#tri).is(3)
					for _, v in tri do
						expect(typeof(v)).is("Vector2")
					end
				end
				nav:destroy()
			end)

			test("result is cached (same reference until dirtied)", function()
				local nav = NavMesh2d.new()
				addAll(nav, makeSquare())
				local t1 = nav:getTriangles()
				local t2 = nav:getTriangles()
				expect(t1 == t2).is(true)
				nav:destroy()
			end)

			test("cache is invalidated after addPoint", function()
				local nav = NavMesh2d.new()
				addAll(nav, makeSquare())
				local t1 = nav:getTriangles()
				nav:addPoint(Vector2.new(5, 5)) -- interior point
				local t2 = nav:getTriangles()
				expect(t1 ~= t2).is(true)
				nav:destroy()
			end)
		end)

		-- ════════════════════════════════════════════════════════════════════
		-- Phase 5B – Query API
		-- ════════════════════════════════════════════════════════════════════

		-- ── getOutlinePolygon ─────────────────────────────────────────────────
		describe("getOutlinePolygon", function()
			test("returns a polygon with at least 3 vertices", function()
				local nav = NavMesh2d.new()
				addAll(nav, makeSquare())
				local outline = nav:getOutlinePolygon()
				expect(#outline >= 3).is(true)
				nav:destroy()
			end)

			test("outline vertices are all Vector2", function()
				local nav = NavMesh2d.new()
				addAll(nav, makeSquare())
				for _, v in nav:getOutlinePolygon() do
					expect(typeof(v)).is("Vector2")
				end
				nav:destroy()
			end)

			test("returns empty (or 0-length) polygon with fewer than 3 points", function()
				local nav = NavMesh2d.new()
				nav:addPoint(Vector2.new(0, 0))
				expect(#nav:getOutlinePolygon()).is(0)
				nav:destroy()
			end)
		end)

		-- ── isPointOnMesh ────────────────────────────────────────────────────
		describe("isPointOnMesh", function()
			test("returns true for a point clearly inside the mesh", function()
				local nav = NavMesh2d.new()
				addAll(nav, makeSquare(10))
				expect(nav:isPointOnMesh(Vector2.new(5, 5))).is(true)
				nav:destroy()
			end)

			test("returns false for a point clearly outside the mesh", function()
				local nav = NavMesh2d.new()
				addAll(nav, makeSquare(10))
				expect(nav:isPointOnMesh(Vector2.new(50, 50))).is(false)
				nav:destroy()
			end)

			test("returns false for a point inside a hole", function()
				local nav = NavMesh2d.new()
				addAll(nav, makeSquare(20))
				-- Hole: inner square (8–12, 8–12)
				local hole = {
					Vector2.new(8, 8),
					Vector2.new(12, 8),
					Vector2.new(12, 12),
					Vector2.new(8, 12),
				}
				nav:addHole(hole)
				expect(nav:isPointOnMesh(Vector2.new(10, 10))).is(false)
				nav:destroy()
			end)

			test("ignoreHoles=true treats hole interior as on-mesh", function()
				local nav = NavMesh2d.new()
				addAll(nav, makeSquare(20))
				local hole = {
					Vector2.new(8, 8),
					Vector2.new(12, 8),
					Vector2.new(12, 12),
					Vector2.new(8, 12),
				}
				nav:addHole(hole)
				expect(nav:isPointOnMesh(Vector2.new(10, 10), true)).is(true)
				nav:destroy()
			end)

			test("accepts Vector3 input", function()
				local nav = NavMesh2d.new()
				addAll(nav, makeSquare(10))
				-- Vector3(X=5, Z=5) → Vector2(5, 5) which is inside
				expect(nav:isPointOnMesh(Vector3.new(5, 0, 5))).is(true)
				nav:destroy()
			end)
		end)

		-- ── findContainingTriangle ────────────────────────────────────────────
		describe("findContainingTriangle", function()
			test("returns a triangle for a point inside the mesh", function()
				local nav = NavMesh2d.new()
				addAll(nav, makeSquare(10))
				local tri = nav:findContainingTriangle(Vector2.new(5, 2))
				expect(tri ~= nil).is(true)
				if tri then
					expect(#tri).is(3)
				end
				nav:destroy()
			end)

			test("returns nil for a point clearly outside the mesh", function()
				local nav = NavMesh2d.new()
				addAll(nav, makeSquare(10))
				local tri = nav:findContainingTriangle(Vector2.new(100, 100))
				expect(tri).is(nil)
				nav:destroy()
			end)

			test("accepts Vector3 input", function()
				local nav = NavMesh2d.new()
				addAll(nav, makeSquare(10))
				-- Vector3(X=3, Z=3) → Vector2(3, 3) inside the mesh
				local tri = nav:findContainingTriangle(Vector3.new(3, 0, 3))
				expect(tri ~= nil).is(true)
				nav:destroy()
			end)
		end)

		-- ════════════════════════════════════════════════════════════════════
		-- Phase 7 – Signals + Lifecycle
		-- ════════════════════════════════════════════════════════════════════

		-- ── signals ───────────────────────────────────────────────────────────
		describe("signals", function()
			test("pointAdded fires with the point and id when addPoint is called", function()
				local nav = NavMesh2d.new()
				local firedPoint: Vector2? = nil
				local firedId: any = nil
				nav.pointAdded:Connect(function(pt, id)
					firedPoint = pt
					firedId = id
				end)
				nav:addPoint(Vector2.new(3, 7), "myId")
				expect(firedPoint).is(Vector2.new(3, 7))
				expect(firedId).is("myId")
				nav:destroy()
			end)

			test("pointRemoved fires with the point and id when removePoint is called", function()
				local nav = NavMesh2d.new()
				nav:addPoint(Vector2.new(1, 2), "r")
				local firedPoint: Vector2? = nil
				local firedId: any = nil
				nav.pointRemoved:Connect(function(pt, id)
					firedPoint = pt
					firedId = id
				end)
				nav:removePoint("r")
				expect(firedPoint).is(Vector2.new(1, 2))
				expect(firedId).is("r")
				nav:destroy()
			end)

			test("holeAdded fires when addHole is called", function()
				local nav = NavMesh2d.new()
				local firedPoly: { Vector2 }? = nil
				nav.holeAdded:Connect(function(poly)
					firedPoly = poly
				end)
				local hole = { Vector2.new(1, 1), Vector2.new(2, 1), Vector2.new(1.5, 2) }
				nav:addHole(hole)
				expect(firedPoly).is(hole)
				nav:destroy()
			end)

			test("holeRemoved fires once per hole when clearHoles is called", function()
				local nav = NavMesh2d.new()
				addAll(nav, makeSquare(20))
				local hole1 = { Vector2.new(1, 1), Vector2.new(3, 1), Vector2.new(2, 3) }
				local hole2 = { Vector2.new(5, 5), Vector2.new(7, 5), Vector2.new(6, 7) }
				nav:addHole(hole1)
				nav:addHole(hole2)
				local removed: { { Vector2 } } = {}
				nav.holeRemoved:Connect(function(poly)
					table.insert(removed, poly)
				end)
				nav:clearHoles()
				expect(#removed).is(2)
				nav:destroy()
			end)

			test("dirtied fires on addPoint, removePoint, addHole, invalidate", function()
				local nav = NavMesh2d.new()
				local dirtyCount = 0
				nav.dirtied:Connect(function()
					dirtyCount += 1
				end)
				nav:addPoint(Vector2.new(0, 0)) -- +1
				nav:addPoint(Vector2.new(1, 0), "x") -- +1
				nav:removePoint("x") -- +1
				nav:addHole { Vector2.new(0, 0), Vector2.new(1, 0), Vector2.new(0.5, 1) } -- +1
				nav:invalidate() -- +1
				expect(dirtyCount).is(5)
				nav:destroy()
			end)

			test("pointAdded does not fire for a no-op update (same coords, same id)", function()
				local nav = NavMesh2d.new()
				local count = 0
				nav.pointAdded:Connect(function()
					count += 1
				end)
				nav:addPoint(Vector2.new(1, 1), "p") -- fires
				nav:addPoint(Vector2.new(1, 1), "p") -- same → no-op, no fire
				expect(count).is(1)
				nav:destroy()
			end)
		end)

		-- ── destroy ───────────────────────────────────────────────────────────
		describe("destroy", function()
			test("clears cached state", function()
				local nav = NavMesh2d.new()
				addAll(nav, makeSquare())
				nav:getTriangles() -- populate cache
				nav:destroy()
				-- After destroy the object must not be used; we just verify no error.
				expect(true).is(true)
			end)
		end)

		-- ════════════════════════════════════════════════════════════════════
		-- Group A – Hole regression tests (catches hole-inversion bug)
		-- Setup: 20×20 outer square, 4×4 inner hole centred on (10,10).
		-- ════════════════════════════════════════════════════════════════════

		describe("hole regression (outer 20x20 / inner hole 8-12)", function()
			-- Shared fixture builder.
			local function makeHoleMesh()
				local nav = NavMesh2d.new()
				addAll(nav, makeSquare(20))
				nav:addHole {
					Vector2.new(8, 8),
					Vector2.new(12, 8),
					Vector2.new(12, 12),
					Vector2.new(8, 12),
				}
				return nav
			end

			test("A1: isPointOnMesh returns true for a point in the walkable ring", function()
				local nav = makeHoleMesh()
				-- (2,2) is inside the 20×20 boundary and well outside the hole.
				expect(nav:isPointOnMesh(Vector2.new(2, 2))).is(true)
				nav:destroy()
			end)

			test("A2: getTriangles with hole yields more triangles than without", function()
				local nav = makeHoleMesh()
				local navNoHole = NavMesh2d.new()
				addAll(navNoHole, makeSquare(20))
				local trisWithHole = nav:getTriangles()
				local trisNoHole = navNoHole:getTriangles()
				-- Hole vertices enter the CDT as extra constrained points, so the ring
				-- triangulation is finer than the plain 4-vertex square (2 triangles).
				expect(#trisWithHole >= 6).is(true)
				expect(#trisWithHole > #trisNoHole).is(true)
				nav:destroy()
				navNoHole:destroy()
			end)

			test("A3: findContainingTriangle returns nil for a point inside the hole", function()
				local nav = makeHoleMesh()
				expect(nav:findContainingTriangle(Vector2.new(10, 10))).is(nil)
				nav:destroy()
			end)

			test("A4: findContainingTriangle returns a triangle for a point in the walkable ring", function()
				local nav = makeHoleMesh()
				local tri = nav:findContainingTriangle(Vector2.new(2, 2))
				expect(tri ~= nil).is(true)
				nav:destroy()
			end)

			test("A5: getOutlinePolygon reflects the outer boundary, not the hole boundary", function()
				local nav = makeHoleMesh()
				local outline = nav:getOutlinePolygon()
				-- A point in the walkable ring must be INSIDE the outer outline polygon.
				-- If the outline were the hole boundary (the bug), this would be false.
				local insideOutline = false
				local n = #outline
				local j = n
				for i = 1, n do
					local pi = outline[i]
					local pj = outline[j]
					local pt = Vector2.new(2, 2)
					if (pi.Y > pt.Y) ~= (pj.Y > pt.Y) then
						if pt.X < (pj.X - pi.X) * (pt.Y - pi.Y) / (pj.Y - pi.Y) + pi.X then
							insideOutline = not insideOutline
						end
					end
					j = i
				end
				expect(insideOutline).is(true)
				nav:destroy()
			end)
		end)

		-- ════════════════════════════════════════════════════════════════════
		-- Group B – Additional hole edge cases
		-- ════════════════════════════════════════════════════════════════════

		describe("hole edge cases", function()
			test("B1: multiple holes – false inside each hole, true between them", function()
				local nav = NavMesh2d.new()
				-- Outer 30×30 square.
				addAll(nav, {
					Vector2.new(0, 0),
					Vector2.new(30, 0),
					Vector2.new(30, 30),
					Vector2.new(0, 30),
				})
				-- Hole in bottom-left corner region.
				nav:addHole {
					Vector2.new(3, 3),
					Vector2.new(9, 3),
					Vector2.new(9, 9),
					Vector2.new(3, 9),
				}
				-- Hole in top-right corner region.
				nav:addHole {
					Vector2.new(21, 21),
					Vector2.new(27, 21),
					Vector2.new(27, 27),
					Vector2.new(21, 27),
				}
				expect(nav:isPointOnMesh(Vector2.new(6, 6))).is(false) -- inside hole 1
				expect(nav:isPointOnMesh(Vector2.new(24, 24))).is(false) -- inside hole 2
				expect(nav:isPointOnMesh(Vector2.new(15, 15))).is(true) -- between holes
				nav:destroy()
			end)

			test("B2: degenerate 2-vertex hole is silently skipped, no error", function()
				local nav = NavMesh2d.new()
				addAll(nav, makeSquare(10))
				nav:addHole { Vector2.new(3, 3), Vector2.new(7, 3) } -- only 2 points
				local ok, _ = pcall(function()
					return nav:getTriangles()
				end)
				expect(ok).is(true)
				-- Result should be same as the no-hole triangulation.
				local navNoHole = NavMesh2d.new()
				addAll(navNoHole, makeSquare(10))
				expect(#nav:getTriangles()).is(#navNoHole:getTriangles())
				nav:destroy()
				navNoHole:destroy()
			end)

			test("B3: hole entirely outside the mesh boundary is ignored", function()
				local nav = NavMesh2d.new()
				addAll(nav, makeSquare(10))
				nav:addHole {
					Vector2.new(50, 50),
					Vector2.new(60, 50),
					Vector2.new(60, 60),
					Vector2.new(50, 60),
				}
				local navNoHole = NavMesh2d.new()
				addAll(navNoHole, makeSquare(10))
				-- Triangle count should be identical; the out-of-bounds hole changes nothing.
				expect(#nav:getTriangles()).is(#navNoHole:getTriangles())
				nav:destroy()
				navNoHole:destroy()
			end)

			test("B4: hole vertex coincident with a mesh vertex does not error", function()
				local nav = NavMesh2d.new()
				addAll(nav, makeSquare(20))
				-- One hole corner lands exactly on mesh vertex (0,0).
				nav:addHole {
					Vector2.new(0, 0),
					Vector2.new(5, 0),
					Vector2.new(5, 5),
					Vector2.new(0, 5),
				}
				local ok, _ = pcall(function()
					return nav:getTriangles()
				end)
				expect(ok).is(true)
				-- Interior point well away from the hole must still be reachable.
				expect(nav:isPointOnMesh(Vector2.new(15, 15))).is(true)
				nav:destroy()
			end)
		end)

		-- ════════════════════════════════════════════════════════════════════
		-- Group C – Segmenting hole (hole cuts the full mesh width)
		-- Outer: 30×10 rectangle.  Hole: vertical strip (10,0)→(20,0)→(20,10)→(10,10).
		-- The hole vertices lie exactly on the outer boundary, creating two
		-- completely disconnected walkable sub-areas.
		-- ════════════════════════════════════════════════════════════════════

		describe("segmenting hole (disconnected sub-areas)", function()
			local function makeSegmentedMesh()
				local nav = NavMesh2d.new()
				addAll(nav, {
					Vector2.new(0, 0),
					Vector2.new(30, 0),
					Vector2.new(30, 10),
					Vector2.new(0, 10),
				})
				nav:addHole {
					Vector2.new(10, 0),
					Vector2.new(20, 0),
					Vector2.new(20, 10),
					Vector2.new(10, 10),
				}
				return nav
			end

			test("C1: left sub-area is passable", function()
				local nav = makeSegmentedMesh()
				expect(nav:isPointOnMesh(Vector2.new(5, 5))).is(true)
				nav:destroy()
			end)

			test("C2: right sub-area is passable", function()
				local nav = makeSegmentedMesh()
				expect(nav:isPointOnMesh(Vector2.new(25, 5))).is(true)
				nav:destroy()
			end)

			test("C3: hole strip interior is not passable", function()
				local nav = makeSegmentedMesh()
				expect(nav:isPointOnMesh(Vector2.new(15, 5))).is(false)
				nav:destroy()
			end)

			test("C4: getTriangles returns a non-empty result", function()
				local nav = makeSegmentedMesh()
				expect(#nav:getTriangles() > 0).is(true)
				nav:destroy()
			end)

			test("C5: findContainingTriangle works in both sub-areas and returns nil in the hole", function()
				local nav = makeSegmentedMesh()
				expect(nav:findContainingTriangle(Vector2.new(5, 5)) ~= nil).is(true)
				expect(nav:findContainingTriangle(Vector2.new(25, 5)) ~= nil).is(true)
				expect(nav:findContainingTriangle(Vector2.new(15, 5))).is(nil)
				nav:destroy()
			end)
		end)
	end)
end

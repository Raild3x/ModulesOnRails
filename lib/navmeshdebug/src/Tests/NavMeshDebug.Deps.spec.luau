-- Authors: Logan Hunt (Raildex)
-- September 25, 2026

return function(t: tiniest)
	local NavMesh = require("../../NavMesh")
	local NavMeshDebug = require("../NavMeshDebug")
	local ConstrainedDelaunayDebug = require("../../ConstrainedDelaunayDebug")
	local Signal = require("../../Signal")

	local describe = t.describe
	local expect = t.expect
	local test = t.test

	describe("dependencies resolve", function()
		test("navmesh sibling", function()
			expect(NavMesh.Fixtures.All).exists()
		end)

		test("the public module exposes NavMeshEditor as a field", function()
			expect(NavMeshDebug.NavMeshEditor).exists()
		end)

		test("the public module re-exports DrawListRenderer", function()
			expect(NavMeshDebug.DrawListRenderer).is(ConstrainedDelaunayDebug.DrawListRenderer)
		end)

		test("constraineddelaunaydebug sibling", function()
			local svg = ConstrainedDelaunayDebug.SvgBackend.Render {}
			expect(svg:find("<svg", 1, true) ~= nil).is_true()
		end)

		test("better-signal registry dependency", function()
			local signal = Signal.new()
			local got = nil
			signal:Connect(function(value)
				got = value
			end)
			signal:Fire(7)
			expect(got).is(7)
		end)
	end)
end

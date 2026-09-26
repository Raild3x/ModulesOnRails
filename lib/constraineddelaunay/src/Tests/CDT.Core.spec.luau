-- Authors: Logan Hunt (Raildex)
-- September 25, 2026

return function(t: tiniest)
	local CDT = require("../ConstrainedDelaunay")

	local describe = t.describe
	local expect = t.expect
	local test = t.test

	describe("pipeline guard", function()
		-- Fails loudly if a datamodel marker ever moves this package onto the Studio pipeline,
		-- which would silently disable mutation testing and snapshots.
		test("core must stay on the Lune pipeline", function()
			expect(game).never_exists()
		end)
	end)

	describe("public module", function()
		test("exposes PlainData and Fixtures", function()
			expect(CDT.PlainData.Check({ 1, 2 })).is_true()
			expect(#CDT.Fixtures.All > 0).is_true()
		end)
	end)
end

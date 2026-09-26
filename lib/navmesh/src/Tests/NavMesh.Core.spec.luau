-- Authors: Logan Hunt (Raildex)
-- September 25, 2026

return function(t: tiniest)
	local NavMesh = require("../NavMesh")

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
		test("exposes Fixtures with an automatic All list", function()
			expect(NavMesh.Fixtures.All).exists()
		end)
	end)
end

local Merge = require("../Merge")
local Ignore = require("../Ignore")

-- The runner executes from the repo root, so fixture paths are repo-relative.
-- The fixture map (total_slots = 15, one file src/a.luau) lays out:
--   stmt 1 + stmt 2 on line 3 (same-line collapse pair)
--   fn 3 "M.doThing" (public), stmt 4 inside it (fn = 3)
--   decision 5/6 ("a and b"), conds 7/8 ("a") and 9/10 ("b")
--   loop 11 (slots 11..13, ctx "for")
--   stmt 14 on line 12 (inside the env-gate scope)
--   stmt 15 on line 14 (inside the dead scope)
--   const candidates: local M (line 1), local function helper (line 2)
local MAP_PATH = "tools/coverage/lune/core/Tests/fixtures/map.json"
local TOTAL = 15

-- A second fixture map with NO gates/dead arrays, an anonymous fn probe, and
-- an unknown ("arm") probe kind: stmt 1, fn 2 "B.known", fn 3 <anonymous>,
-- fn 4 "B.other", arm 5.
local MIN_MAP_PATH = "tools/coverage/lune/core/Tests/fixtures/map_minimal.json"
local MIN_TOTAL = 5

local function hitsWith(slots: { [number]: number }): { number }
	local hits = table.create(TOTAL, 0)
	for slot, count in slots do
		hits[slot] = count
	end
	return hits
end

local function merge(slots: { [number]: number }, rules)
	return Merge.merge(MAP_PATH, { hits = hitsWith(slots), total = TOTAL, map_sha = "cafe" }, rules)
end

local function mergeMin(slots: { [number]: number }, rules)
	local hits = table.create(MIN_TOTAL, 0)
	for slot, count in slots do
		hits[slot] = count
	end
	return Merge.merge(MIN_MAP_PATH, { hits = hits, total = MIN_TOTAL, map_sha = "cafe" }, rules)
end

local function rulesWith(t: { sites: { string }?, names: { string }?, lines: { string }? })
	local rules = Ignore.empty()
	local sites: { string } = t.sites or {}
	for _, site in sites do
		rules.sites[site] = true
	end
	local names: { string } = t.names or {}
	for _, name in names do
		rules.names[name] = true
	end
	local lines: { string } = t.lines or {}
	for _, line in lines do
		rules.fileLines[line] = true
	end
	rules.isEmpty = false
	return rules
end

return function(tiniest)
	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

	describe("Merge.merge basics", function()
		test("rejects a hit buffer with the wrong slot count", function()
			expect(function()
				Merge.merge(MAP_PATH, { hits = table.create(TOTAL - 1, 0), total = TOTAL - 1, map_sha = "x" })
			end).fails_with("slot mismatch")
		end)

		test("falls back to the runtime map_sha (map.json carries no top-level sha256)", function()
			expect(merge({}).mapSha).is("cafe")
		end)

		test("maps dense probe ids to stable site keys", function()
			local merged = merge({})
			expect(merged.idToSite[5]).is("dec:src/a.luau:8:4")
			expect(merged.idToSite[1]).is("stmt:src/a.luau:3:1")
		end)
	end)

	describe("statement, function and line metrics", function()
		test("counts statements (gated/dead probes excluded from the denominator)", function()
			local merged = merge({ [1] = 1 })
			-- Probes 1, 2, 4 count; 14 is gated and 15 is dead.
			expect(merged.totals.statements.total).is(3)
			expect(merged.totals.statements.covered).is(1)
		end)

		test("records function entries with hits and privacy", function()
			local merged = merge({ [3] = 2 })
			expect(merged.totals.functions.covered).is(1)
			expect(merged.totals.functions.total).is(1)
			local entry = merged.files[1].fnEntries[1]
			expect(entry.name).is("M.doThing")
			expect(entry.hits).is(2)
			expect(entry.isPrivate).never_is_true()
		end)

		test("collapses same-line statement probes into one line", function()
			local merged = merge({ [2] = 1 })
			-- Lines 3 (probes 1+2) and 6 (probe 4); either probe covers line 3.
			expect(merged.totals.lines.total).is(2)
			expect(merged.totals.lines.covered).is(1)
		end)
	end)

	describe("decision and condition metrics", function()
		test("a decision hit both ways is covered with no partial", function()
			local merged = merge({ [5] = 2, [6] = 1 })
			expect(merged.totals.decisions.covered).is(1)
			expect(merged.totals.branches.covered).is(2)
			expect(#merged.files[1].partials).is(0)
		end)

		test("a one-sided decision reports a partial", function()
			local merged = merge({ [5] = 3 })
			expect(merged.totals.decisions.covered).is(0)
			expect(merged.totals.branches.covered).is(1)
			local partial = merged.files[1].partials[1]
			expect(partial.missing).is("never false")
			expect(partial.ctx).is("if")
			expect(partial.src).is("a and b")

			local mirror = merge({ [6] = 2 }).files[1].partials[1]
			expect(mirror.missing).is("never true")
		end)

		test("an unreached decision is uncovered but not partial", function()
			local merged = merge({})
			expect(merged.totals.decisions.covered).is(0)
			expect(merged.totals.decisions.total).is(1)
			expect(#merged.files[1].partials).is(0)
		end)

		test("condition operands are tracked individually", function()
			local merged = merge({ [7] = 1, [8] = 1, [9] = 1 })
			-- "a" varied both ways; "b" was only ever true.
			expect(merged.totals.conditions.covered).is(1)
			expect(merged.totals.conditions.total).is(2)
			local partial = merged.files[1].condPartials[1]
			expect(partial.src).is("b")
			expect(partial.missing).is("never false")
		end)

		test("a condition that was only ever false reports never true", function()
			local merged = merge({ [8] = 1 })
			local partial = merged.files[1].condPartials[1]
			expect(partial.src).is("a")
			expect(partial.missing).is("never true")
		end)
	end)

	describe("maps without gates or dead spans", function()
		test("merges cleanly when a file has no gates/dead arrays", function()
			local merged = mergeMin({ [1] = 1, [2] = 1 })
			expect(merged.totals.statements.covered).is(1)
			expect(merged.totals.statements.total).is(1)
			expect(merged.totals.functions.total).is(3)
			expect(#merged.suppressed.gated).is(0)
			expect(#merged.suppressed.dead).is(0)
		end)

		test("unknown probe kinds stay out of the metrics but keep their site", function()
			local merged = mergeMin({ [5] = 9 })
			expect(merged.totals.statements.total).is(1)
			expect(merged.totals.branches.total).is(0)
			expect(merged.idToSite[5]).is("arm:src/b.luau:10:1")
		end)

		test("anonymous fn entries default their name", function()
			local merged = mergeMin({ [3] = 1 })
			local names = {}
			for _, entry in merged.files[1].fnEntries do
				names[entry.name] = entry
			end
			expect(names["<anonymous>"]).exists()
			expect(names["<anonymous>"].isPrivate).is_true()
		end)

		test("a name rule skips fn probes that are anonymous or named differently", function()
			local merged = mergeMin({}, rulesWith({ names = { "B.known" } }))
			-- Only B.known is suppressed; the anonymous fn and B.other still count.
			expect(#merged.suppressed.ignored).is(1)
			expect(merged.suppressed.ignored[1].label).is("B.known")
			expect(merged.totals.functions.total).is(2)
		end)
	end)

	describe("loop findings", function()
		test("a loop that never iterated more than once is reported", function()
			local merged = merge({ [11] = 1, [12] = 2 })
			expect(#merged.loops).is(1)
			local finding = merged.loops[1]
			expect(finding.ctx).is("for")
			expect(finding.zero).is(1)
			expect(finding.one).is(2)
			expect(finding.many).is(0)
		end)

		test("a loop observed iterating many times is not reported", function()
			expect(#merge({ [13] = 2 }).loops).is(0)
		end)

		test("an unreached loop is not reported", function()
			expect(#merge({}).loops).is(0)
		end)
	end)

	describe("const candidates", function()
		test("candidates from the map surface on Merged with the file stamped", function()
			local merged = merge({})
			expect(#merged.constCandidates).is(2)
			local first = merged.constCandidates[1]
			expect(first.file).is("src/a.luau")
			expect(first.kind).is("local")
			expect(first.names[1]).is("M")
			expect(first.site).is("const:src/a.luau:1:1")
			expect(merged.constCandidates[2].kind).is("local_function")
		end)

		test("a site rule suppresses a candidate into the ignored bucket", function()
			local merged = merge({}, rulesWith({ sites = { "const:src/a.luau:1:1" } }))
			expect(#merged.constCandidates).is(1)
			expect(merged.constCandidates[1].names[1]).is("helper")
			local entry
			for _, e in merged.suppressed.ignored do
				if e.kind == "const" then
					entry = e
				end
			end
			expect(entry).exists()
			expect(entry.label).is("local M")
			expect(entry.detail).is("site rule")
		end)

		test("a file:line rule suppresses a candidate with its decl label", function()
			local merged = merge({}, rulesWith({ lines = { "src/a.luau:2" } }))
			expect(#merged.constCandidates).is(1)
			expect(merged.constCandidates[1].names[1]).is("M")
			local entry
			for _, e in merged.suppressed.ignored do
				if e.kind == "const" then
					entry = e
				end
			end
			expect(entry).exists()
			expect(entry.label).is("local function helper")
		end)

		test("maps without const_candidates merge to an empty list", function()
			expect(#mergeMin({}).constCandidates).is(0)
		end)
	end)

	describe("suppression precedence", function()
		test("env-gated probes are listed with the gate note and excluded", function()
			local merged = merge({})
			expect(#merged.suppressed.gated).is(1)
			local entry = merged.suppressed.gated[1]
			expect(entry.site).is("stmt:src/a.luau:12:2")
			expect(entry.detail).is("RunService:IsRunning() is false in edit mode")
		end)

		test("dead probes are listed with the reason and excluded", function()
			local merged = merge({})
			expect(#merged.suppressed.dead).is(1)
			expect(merged.suppressed.dead[1].site).is("stmt:src/a.luau:14:2")
			expect(merged.suppressed.dead[1].detail).is("unreachable after error(...)")
		end)

		test("ignore rules win over env gates", function()
			local merged = merge({}, rulesWith({ sites = { "stmt:src/a.luau:12:2" } }))
			expect(#merged.suppressed.gated).is(0)
			expect(#merged.suppressed.ignored).is(1)
			expect(merged.suppressed.ignored[1].detail).is("site rule")
		end)

		test("a fn name rule takes the whole body with it, listing only the fn", function()
			local merged = merge({}, rulesWith({ names = { "M.doThing" } }))
			expect(#merged.suppressed.ignored).is(1)
			expect(merged.suppressed.ignored[1].kind).is("fn")
			expect(merged.suppressed.ignored[1].detail).is("name rule")
			-- Body stmt 4 drops out of the denominator without being listed.
			expect(merged.totals.statements.total).is(2)
			expect(merged.totals.functions.total).is(0)
		end)
	end)
end

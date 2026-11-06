--!nonstrict
--[[
	Selector dialect parser (Query/Selector.luau): grammar accept/reject
	matrix, canonical normalization + result-cache identity (interning
	precondition), the native-vs-residual lowering split per the probed
	grammar rows, exact-type attr-eq residuals, :not exactness rules, and
	residual matcher behavior.
]]

return function(t: any)
	local Selector = require(script.Parent.Parent.Query.Selector)

	local describe = t.describe
	local test = t.test
	local expect = t.expect

	-- Runs a MatchSpec the way the engine does: existence when 0 matchers,
	-- else any-of (function matchers get (instance, value), others compare ==).
	local function specMatches(spec, value): boolean
		if spec.exists then
			return value ~= nil
		end
		for i = 1, spec.count do
			local matcher = spec.matchers[i]
			if type(matcher) == "function" then
				if matcher(nil :: any, value) then
					return true
				end
			elseif matcher == value then
				return true
			end
		end
		return false
	end

	describe("grammar accept/reject", function()
		test("kitchen-sink selector parses", function()
			local result = Selector.parse(
				[[Model.Enemy#Boss[$State != "Dead"][$Level >= 5][Anchored = true]:not(.Friendly):has(BasePart), Part]]
			)
			expect(#result.groups).is(2)
		end)

		test("invalid selectors error at parse time", function()
			expect(function()
				Selector.parse("")
			end).fails()
			expect(function()
				Selector.parse("   ")
			end).fails()
			expect(function()
				Selector.parse("*")
			end).fails()
			expect(function()
				Selector.parse("[Anchored = ]")
			end).fails()
			expect(function()
				Selector.parse("[$X = 5")
			end).fails()
			expect(function()
				Selector.parse('[$X = "unterminated]')
			end).fails()
			expect(function()
				Selector.parse(":bogus(Part)")
			end).fails()
			-- ~ demands a string pattern, and a VALID one, at build time.
			expect(function()
				Selector.parse("[$X ~ 5]")
			end).fails()
			expect(function()
				Selector.parse('[$X ~ "%"]')
			end).fails()
			-- Comparisons demand number literals.
			expect(function()
				Selector.parse('[$X >= "5"]')
			end).fails()
			-- :not is restricted to a single compound.
			expect(function()
				Selector.parse("Part:not(Model > Part)")
			end).fails()
		end)
	end)

	describe("normalization + cache identity", function()
		test("equivalent spellings share one normalized form AND one result table", function()
			local a = Selector.parse('.Enemy[$Level >= 5]')
			local b = Selector.parse('[$Level>=5].Enemy')
			expect(a.normalized).is(b.normalized)
			expect(a == b).is(true) -- cache identity => shared matcher closures

			-- Comma groups are commutative.
			expect(Selector.parse("Part, Model") == Selector.parse("Model,  Part")).is(true)
			-- Quote style and bareword strings collapse.
			expect(Selector.parse("[$S = 'hi']") == Selector.parse('[$S = "hi"]')).is(true)
			expect(Selector.parse("[Name = Foo]") == Selector.parse('[Name = "Foo"]')).is(true)
		end)

		test("semantically different literals do NOT collapse", function()
			expect(Selector.parse("[$N = 5]") == Selector.parse('[$N = "5"]')).is(false)
			expect(Selector.parse("[$F = true]") == Selector.parse('[$F = "true"]')).is(false)
		end)

		test("normalized form round-trips", function()
			local first = Selector.parse([[Model.Enemy[$Level >= 5]:not(.Dead), Part#Core]])
			expect(Selector.parse(first.normalized) == first).is(true)
		end)
	end)

	describe("lowering split (native superset vs residual)", function()
		test("seeds and residuals land in their buckets", function()
			local result = Selector.parse('Model.Enemy#Boss[$Level >= 5][Anchored = true]')
			local group = result.groups[1]
			expect(group.lowered.classes[1]).is("Model")
			expect(group.lowered.tags[1]).is("Enemy")
			-- #Boss lowers to a Name property spec; Anchored is the second prop.
			expect(#group.lowered.props).is(2)
			expect(group.lowered.props[1].name).is("Name")
			expect(#group.lowered.attrs).is(1)
			expect(group.lowered.attrs[1].name).is("Level")
		end)

		test("dialect ops widen to attr existence in the native form", function()
			local result = Selector.parse('.Enemy[$Level >= 5][Anchored = true]')
			expect(result.groups[1].nativeSelector).is('.Enemy[$Level][Anchored = true]')
			expect(result.needsNative).is(false)
		end)

		test("attr equality stays native as a coerced superset; floats do not", function()
			expect(Selector.parse("[$N = 5].T").groups[1].nativeSelector).is(".T[$N = 5]")
			expect(Selector.parse("[$N = 1.5].T").groups[1].nativeSelector).is(".T[$N]")
		end)

		test("a compound with no native terms has no native form", function()
			local result = Selector.parse("[Transparency = 0.5]")
			expect(result.groups[1].nativeSelector).is(nil)
			expect(result.nativeSelector).is(nil)
			expect(specMatches(result.groups[1].lowered.props[1], 0.5)).is(true)
			expect(specMatches(result.groups[1].lowered.props[1], 0.25)).is(false)
		end)

		test("needsNative flags combinators and :has only", function()
			expect(Selector.parse("Model > Part").needsNative).is(true)
			expect(Selector.parse("Part:has(Model)").needsNative).is(true)
			expect(Selector.parse("Part.Tag:not(.Other)").needsNative).is(false)
			local chain = Selector.parse("Model >> Part").groups[1]
			expect(#chain.hops).is(2)
			expect(chain.hops[2].combinator).is(">>")
		end)

		test(":not stays native only when its inner is exact", function()
			-- Tag inner: exact, kept.
			expect(Selector.parse("Part:not(.Dead)").groups[1].nativeSelector).is("Part:not(.Dead)")
			-- Attr-eq inner: coerced (inexact) => the whole :not is dropped.
			expect(Selector.parse("Part:not([$X = 1])").groups[1].nativeSelector).is("Part")
			-- Either way the residual :not lowering is complete.
			local lowered = Selector.parse("Part:not(.Dead[$X = 1])").groups[1].loweredNots[1]
			expect(lowered.tags[1]).is("Dead")
			expect(#lowered.attrs).is(1)
		end)
	end)

	describe("residual matcher semantics", function()
		local function attrSpec(selector)
			return Selector.parse(selector).groups[1].lowered.attrs[1]
		end

		test("= is type-exact (unlike the coerced native)", function()
			expect(specMatches(attrSpec("[$N = 5].T"), 5)).is(true)
			expect(specMatches(attrSpec("[$N = 5].T"), "5")).is(false)
			expect(specMatches(attrSpec('[$N = "5"].T'), "5")).is(true)
			expect(specMatches(attrSpec('[$N = "5"].T'), 5)).is(false)
		end)

		test("!= matches absent values by design", function()
			local spec = attrSpec('[$State != "Dead"].T')
			expect(specMatches(spec, "Alive")).is(true)
			expect(specMatches(spec, nil)).is(true)
			expect(specMatches(spec, "Dead")).is(false)
		end)

		test("comparisons match numbers only", function()
			local spec = attrSpec("[$Level >= 5].T")
			expect(specMatches(spec, 5)).is(true)
			expect(specMatches(spec, 4)).is(false)
			expect(specMatches(spec, "6")).is(false)
			expect(specMatches(attrSpec("[$Level < 5].T"), 4)).is(true)
			expect(specMatches(attrSpec("[$Level < 5].T"), 5)).is(false)
		end)

		test("~ pattern-matches strings only", function()
			local spec = attrSpec('[$Id ~ "^ELITE_%d+"].T')
			expect(specMatches(spec, "ELITE_12")).is(true)
			expect(specMatches(spec, "BOSS_12")).is(false)
			expect(specMatches(spec, 12)).is(false)
		end)

		test(":typeof checks the value type", function()
			local spec = attrSpec("[$Data:typeof(number)].T")
			expect(specMatches(spec, 3)).is(true)
			expect(specMatches(spec, "3")).is(false)
		end)

		test("remaining comparison ops and boolean/escape literals", function()
			expect(specMatches(attrSpec("[$L > 5].T"), 6)).is(true)
			expect(specMatches(attrSpec("[$L > 5].T"), 5)).is(false)
			expect(specMatches(attrSpec("[$L <= 5].T"), 5)).is(true)
			expect(specMatches(attrSpec("[$L <= 5].T"), 6)).is(false)
			expect(specMatches(attrSpec("[$F = false].T"), false)).is(true)
			expect(specMatches(attrSpec("[$F = false].T"), true)).is(false)
			-- Escaped quote inside a string literal survives parse + normalize.
			local escaped = attrSpec([=[[$S = "say \"hi\""].T]=])
			expect(specMatches(escaped, 'say "hi"')).is(true)
		end)

		test("property != is enum-aware too", function()
			local props = Selector.parse('[Material != "Neon"].T').groups[1].lowered.props
			expect(specMatches(props[1], Enum.Material.Neon)).is(false)
			expect(specMatches(props[1], Enum.Material.Plastic)).is(true)
			expect(specMatches(props[1], "Neon")).is(false)
		end)

		test("malformed pseudo/typeof forms and trailing garbage error", function()
			expect(function()
				Selector.parse("[$X:typeof]")
			end).fails()
			expect(function()
				Selector.parse("[$X:typeof()]")
			end).fails()
			expect(function()
				Selector.parse("[$X:nope(number)]")
			end).fails()
			expect(function()
				Selector.parse("[$X:typeof(number].T")
			end).fails()
			expect(function()
				Selector.parse("Part:has")
			end).fails()
			expect(function()
				Selector.parse("Part:has(Model")
			end).fails()
			expect(function()
				Selector.parse("Part ]")
			end).fails()
			-- Dangling term sigils.
			expect(function()
				Selector.parse("[$]")
			end).fails()
			expect(function()
				Selector.parse("Part#")
			end).fails()
			expect(function()
				Selector.parse("Part.")
			end).fails()
		end)

		test("property != with non-string literals is plain inequality", function()
			local props = Selector.parse("[Transparency != 5].T").groups[1].lowered.props
			expect(specMatches(props[1], 5)).is(false)
			expect(specMatches(props[1], 4)).is(true)
		end)

		test("repeated terms of every kind accumulate", function()
			local result = Selector.parse(
				"Model Folder.TagA.TagB#N1#N2:not(.X):not(.Y):has(Part):has(Model) > Part.Mid > Seat"
			)
			local group = result.groups[1]
			expect(#group.hops).is(3)
			local first = group.hops[1].compound
			expect(#first.classes).is(2)
			expect(#first.tags).is(2)
			expect(#first.names).is(2)
			expect(#first.nots).is(2)
			expect(#first.has).is(2)
			expect(group.needsNative).is(true)
			-- Chain native form survives with all hops present.
			expect(group.nativeSelector ~= nil).is(true)
		end)

		test(":not with an inexpressible inner drops from the native form", function()
			expect(Selector.parse("Part:not([Transparency = 0.5])").groups[1].nativeSelector).is("Part")
		end)

		test("property equality is enum-aware", function()
			local props = Selector.parse('[Material = "Neon"].T').groups[1].lowered.props
			expect(specMatches(props[1], Enum.Material.Neon)).is(true)
			expect(specMatches(props[1], Enum.Material.Plastic)).is(false)
			expect(specMatches(props[1], "Neon")).is(true)
		end)

		test("[$Attr] existence and #Name lowering", function()
			local exists = attrSpec("[$Num].T")
			expect(specMatches(exists, 0)).is(true)
			expect(specMatches(exists, nil)).is(false)
			local nameSpec = Selector.parse("#Core.T").groups[1].lowered.props[1]
			expect(nameSpec.name).is("Name")
			expect(specMatches(nameSpec, "Core")).is(true)
			expect(specMatches(nameSpec, "Other")).is(false)
		end)
	end)
end

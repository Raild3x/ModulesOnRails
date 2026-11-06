--!nonstrict
--[[
	Query.Selector (Wave 3): selector-dialect strings as composable query
	requirements — root-scoped IsA seeds with descendant watching, residual
	attr/prop re-evaluation, dialect ops, :not lowering, comma OR-groups,
	interning across spellings, cold reads, and the needsNative error.
]]

return function(t: any)
	local CollectionService = game:GetService("CollectionService")
	local H = require(script.Parent.Helpers)
	local Component = require(script.Parent.Parent :: any) :: any
	local Query = Component.Query

	local describe = t.describe
	local test = t.test
	local expect = t.expect

	local function makeRoot(): Folder
		local root = Instance.new("Folder")
		root.Name = "CPQSel_" .. H.uniqueTag()
		root.Parent = workspace
		return root
	end

	local function part(parent: Instance, props, tags, attrs): Instance
		local p = Instance.new("Part")
		p.Anchored = true
		for k, v in props or {} do
			p[k] = v
		end
		for _, tag in tags or {} do
			CollectionService:AddTag(p, tag)
		end
		for k, v in attrs or {} do
			p:SetAttribute(k, v)
		end
		p.Parent = parent
		return p
	end

	describe("reactive selector queries", function()
		test("class+tag selector observes matches; root boundary is live", function()
			local root = makeRoot()
			local outside = makeRoot()
			local tag = H.uniqueTag()
			local inRoot = part(root, nil, { tag })
			part(outside, nil, { tag }) -- tagged but outside the root

			local seen = {}
			local q = Query(Query.Selector(`Part.{tag}`, root))
			local conn = q:observe(function(instance, janitor)
				seen[instance] = true
				janitor:Add(function()
					seen[instance] = nil
				end)
			end)

			expect(H.waitUntil(function()
				return seen[inRoot] == true
			end, 2)).is(true)
			expect(q:count()).is(1)

			-- Reparent out: unmatch (via deferred DescendantRemoving recheck).
			inRoot.Parent = outside
			expect(H.waitUntil(function()
				return seen[inRoot] == nil
			end, 2)).is(true)

			-- And back in: rematch.
			inRoot.Parent = root
			expect(H.waitUntil(function()
				return seen[inRoot] == true
			end, 2)).is(true)

			conn:Disconnect()
			root:Destroy()
			outside:Destroy()
		end)

		test("residual dialect ops re-evaluate on attribute change", function()
			local root = makeRoot()
			local tag = H.uniqueTag()
			local p = part(root, nil, { tag }, { Level = 5 })

			local q = Query(Query.Selector(`.{tag}[$Level >= 10]`, root))
			local matched = {}
			local conn = q:observe(function(instance, janitor)
				matched[instance] = true
				janitor:Add(function()
					matched[instance] = nil
				end)
			end)

			task.wait(0.1)
			expect(matched[p]).is(nil)
			p:SetAttribute("Level", 12)
			expect(H.waitUntil(function()
				return matched[p] == true
			end, 2)).is(true)
			p:SetAttribute("Level", 3)
			expect(H.waitUntil(function()
				return matched[p] == nil
			end, 2)).is(true)

			conn:Disconnect()
			root:Destroy()
		end)

		test("comma OR-groups union; :not excludes", function()
			local root = makeRoot()
			local tagA, tagB, dead = H.uniqueTag(), H.uniqueTag(), H.uniqueTag()
			local pa = part(root, nil, { tagA })
			local model = Instance.new("Model")
			model:AddTag(tagB)
			model.Parent = root
			local deadPart = part(root, nil, { tagA, dead })

			local q = Query(Query.Selector(`Part.{tagA}:not(.{dead}), Model.{tagB}`, root))
			local matches = q:get()
			expect(#matches).is(2)
			expect(q:contains(pa)).is(true)
			expect(q:contains(model)).is(true)
			expect(q:contains(deadPart)).is(false)

			root:Destroy()
		end)
	end)

	describe("cold reads + exactness", function()
		test("get/count/first/contains without a live engine", function()
			local root = makeRoot()
			local tag = H.uniqueTag()
			local p = part(root, nil, { tag }, { N = 5 })
			part(root, nil, { tag }, { N = "5" })

			-- Type-exact residual: only the number-5 part matches [$N = 5].
			local q = Query(Query.Selector(`.{tag}[$N = 5]`, root))
			expect(q:count()).is(1)
			expect(q:first()).is(p)
			expect(q:contains(p)).is(true)
			expect(#q:get()).is(1)

			local qs = Query(Query.Selector(`.{tag}[$N = "5"]`, root))
			expect(qs:count()).is(1)
			expect(qs:contains(p)).is(false)

			root:Destroy()
		end)

		test("bracket-only selectors are bounded by the root", function()
			local root = makeRoot()
			part(root, { Transparency = 0.5 })
			part(root, { Transparency = 0 })

			local q = Query(Query.Selector("[Transparency = 0.5]", root))
			expect(q:count()).is(1)
			-- first() exercises the selector-seed early-exit path.
			expect(q:first() ~= nil).is(true)

			-- The same node in two positions dedupes its subscriptions.
			local node = Query.Selector("[Transparency = 0.5]", root)
			local dup = Query(node):with(node)
			local conn = dup:track()
			expect(dup:count()).is(1)
			conn:Disconnect()

			root:Destroy()
		end)

		test("selectors compose with other requirements", function()
			local root = makeRoot()
			local A, aTag = H.makeClass()
			local p = part(root, nil, { aTag })
			expect(H.waitStarted(A, p, 3)).is(true)

			local q = Query(Query.Selector("Part", root)):with(A)
			expect(q:contains(p)).is(true)
			part(root) -- plain part: matches selector, lacks the component
			expect(q:count()).is(1)

			A:Destroy()
			root:Destroy()
		end)
	end)

	describe("interning + validation", function()
		test("equivalent spellings share one signature (and one node)", function()
			local root = makeRoot()
			local a = Query(Query.Selector('Part[$Lv >= 5].Enemy', root))
			local b = Query(Query.Selector('.Enemy[$Lv>=5]Part', root))
			expect(a:_signature()).is(b:_signature())
			expect(Query.Selector('Part.Enemy', root) == Query.Selector('.Enemy Part', root)).is(true)
			-- A different root is a different engine.
			local other = makeRoot()
			expect(a:_signature() == Query(Query.Selector('Part[$Lv >= 5].Enemy', other)):_signature()).is(false)
			root:Destroy()
			other:Destroy()
		end)

		test("needsNative selectors error at build; unknown ClassNames match nothing", function()
			expect(function()
				Query.Selector("Model > Part")
			end).fails()
			expect(function()
				Query.Selector("Part:has(Model)")
			end).fails()
			-- IsA never errors for unknown names, so a typo'd class silently
			-- matches nothing (same as the native grammar / CSS).
			local root = makeRoot()
			part(root)
			expect(Query(Query.Selector("TotallyNotAClass123", root)):count()).is(0)
			root:Destroy()
		end)

		test("root destruction unmatches observed instances", function()
			local root = makeRoot()
			local tag = H.uniqueTag()
			local p = part(root, nil, { tag })
			local q = Query(Query.Selector(`Part.{tag}`, root))
			local live = {}
			local conn = q:observe(function(instance, janitor)
				live[instance] = true
				janitor:Add(function()
					live[instance] = nil
				end)
			end)
			expect(H.waitUntil(function()
				return live[p] == true
			end, 2)).is(true)

			root:Destroy()
			expect(H.waitUntil(function()
				return live[p] == nil
			end, 2)).is(true)
			conn:Disconnect()
		end)
	end)
end

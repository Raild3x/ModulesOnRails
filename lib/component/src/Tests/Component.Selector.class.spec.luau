--!nonstrict
--[[
	Selector-attached component classes (Wave 4): the unified driver mapping
	Query.Selector engine edges to Lifecycle.Request/Release. Full lifecycle,
	every new StopReason path, same-frame supersede parity with the tag driver
	(the edge-semantics regression gate), SetEnabled round-trips, config
	validation, and the tag-only GetCreateFromInstance guard.
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
		root.Name = "CPSelCls_" .. H.uniqueTag()
		root.Parent = workspace
		return root
	end

	local function makeSelectorClass(selector: string, ancestors, def)
		local class = Component.new({ Selector = selector, Ancestors = ancestors })
		for k, v in def or {} do
			class[k] = v
		end
		return class
	end

	local function taggedPart(parent: Instance, tag: string, attrs): Instance
		local p = Instance.new("Part")
		p.Anchored = true
		CollectionService:AddTag(p, tag)
		for k, v in attrs or {} do
			p:SetAttribute(k, v)
		end
		p.Parent = parent
		return p
	end

	describe("lifecycle on selector classes", function()
		test("construct/start/stop with SelectorUnmatched on attr change", function()
			local root = makeRoot()
			local tag = H.uniqueTag()
			local order = {}
			local stopReason = nil
			local A = makeSelectorClass(`Part.{tag}[$On = 1]`, { root }, {
				OnConstruct = function(_self)
					table.insert(order, "construct")
				end,
				OnStart = function(_self)
					table.insert(order, "start")
				end,
				OnStop = function(_self, reason)
					table.insert(order, "stop")
					stopReason = reason
				end,
			})

			local p = taggedPart(root, tag, { On = 1 })
			expect(H.waitStarted(A, p, 3)).is(true)
			expect(A:FromInstance(p) ~= nil).is(true)

			p:SetAttribute("On", 0)
			expect(H.waitUntil(function()
				return stopReason ~= nil
			end, 3)).is(true)
			expect(stopReason).is("SelectorUnmatched")
			expect(table.concat(order, ",")).is("construct,start,stop")

			A:Destroy()
			root:Destroy()
		end)

		test("LeftAncestry and InstanceDestroyed reasons map correctly", function()
			local root = makeRoot()
			local tag = H.uniqueTag()
			local reasons = {}
			local A = makeSelectorClass(`Part.{tag}`, { root }, {
				OnStop = function(self, reason)
					reasons[self.Instance] = reason
				end,
			})

			local mover = taggedPart(root, tag)
			local doomed = taggedPart(root, tag)
			expect(H.waitStarted(A, mover, 3)).is(true)
			expect(H.waitStarted(A, doomed, 3)).is(true)

			mover.Parent = workspace -- out of the root => out of Ancestors
			expect(H.waitUntil(function()
				return reasons[mover] ~= nil
			end, 3)).is(true)
			expect(reasons[mover]).is("LeftAncestry")

			doomed:Destroy()
			expect(H.waitUntil(function()
				return reasons[doomed] ~= nil
			end, 3)).is(true)
			expect(reasons[doomed]).is("InstanceDestroyed")

			A:Destroy()
			root:Destroy()
			mover:Destroy()
		end)

		test("same-frame flip parity: old component stops, fresh one constructs", function()
			local root = makeRoot()
			local tag = H.uniqueTag()
			local constructs = 0
			local stops = 0
			local A = makeSelectorClass(`Part.{tag}[$On = 1]`, { root }, {
				OnConstruct = function(_self)
					constructs += 1
				end,
				OnStop = function(_self, _reason)
					stops += 1
				end,
			})

			local p = taggedPart(root, tag, { On = 1 })
			expect(H.waitStarted(A, p, 3)).is(true)
			expect(constructs).is(1)

			-- Same-frame unmatch+rematch: the engines deliver both edges
			-- (probe F8: no coalescing), so the supersede protocol runs exactly
			-- as it does for a same-frame untag+retag on a tag class.
			p:SetAttribute("On", 0)
			p:SetAttribute("On", 1)

			expect(H.waitUntil(function()
				return constructs == 2 and stops == 1
			end, 3)).is(true)
			expect(A:Has(p)).is(true)

			A:Destroy()
			root:Destroy()
		end)
	end)

	describe("SetEnabled", function()
		test("disable stops with Disabled; enable reconstructs incl. new arrivals", function()
			local root = makeRoot()
			local tag = H.uniqueTag()
			local reasons = {}
			local A = makeSelectorClass(`Part.{tag}`, { root }, {
				OnStop = function(self, reason)
					reasons[self.Instance] = reason
				end,
			})

			local p1 = taggedPart(root, tag)
			expect(H.waitStarted(A, p1, 3)).is(true)

			A:SetEnabled(false)
			expect(H.waitUntil(function()
				return reasons[p1] ~= nil
			end, 3)).is(true)
			expect(reasons[p1]).is("Disabled")

			-- Appears while disabled: no construction until re-enable.
			local p2 = taggedPart(root, tag)
			task.wait(0.1)
			expect(A:Has(p2)).is(false)

			A:SetEnabled(true)
			expect(H.waitStarted(A, p1, 3)).is(true)
			expect(H.waitStarted(A, p2, 3)).is(true)

			A:Destroy()
			root:Destroy()
		end)

		test("SetEnabled works on tag classes too", function()
			local A, aTag = H.makeClass()
			local p = H.taggedPart(aTag)
			expect(H.waitStarted(A, p, 3)).is(true)

			A:SetEnabled(false)
			expect(H.waitUntil(function()
				return not A:Has(p)
			end, 3)).is(true)
			local p2 = H.taggedPart(aTag)
			task.wait(0.1)
			expect(A:Has(p2)).is(false)

			A:SetEnabled(true)
			expect(H.waitStarted(A, p, 3)).is(true)
			expect(H.waitStarted(A, p2, 3)).is(true)

			A:Destroy()
			p:Destroy()
			p2:Destroy()
		end)
	end)

	describe("class surface", function()
		test("config requires exactly one of Tag / Selector", function()
			expect(function()
				Component.new({})
			end).fails()
			expect(function()
				Component.new({ Tag = "X", Selector = ".X" })
			end).fails()
		end)

		test("GetCreateFromInstance is tag-only", function()
			local root = makeRoot()
			local A = makeSelectorClass("Part.CPNever_" .. H.uniqueTag(), { root })
			expect(function()
				A:GetCreateFromInstance(Instance.new("Part"))
			end).fails()
			A:Destroy()
			root:Destroy()
		end)

		test("selector classes are valid query requirements", function()
			local root = makeRoot()
			local tag = H.uniqueTag()
			local A = makeSelectorClass(`Part.{tag}`, { root })
			local p = taggedPart(root, tag)
			expect(H.waitStarted(A, p, 3)).is(true)

			local q = Query(A)
			expect(q:contains(p)).is(true)
			expect(q:count()).is(1)

			A:Destroy()
			root:Destroy()
		end)

		test("UpdateAncestors moves the driver to new roots", function()
			local rootA = makeRoot()
			local rootB = makeRoot()
			local tag = H.uniqueTag()
			local reasons = {}
			local A = makeSelectorClass(`Part.{tag}`, { rootA }, {
				OnStop = function(self, reason)
					reasons[self.Instance] = reason
				end,
			})

			local inA = taggedPart(rootA, tag)
			local inB = taggedPart(rootB, tag)
			expect(H.waitStarted(A, inA, 3)).is(true)
			task.wait(0.1)
			expect(A:Has(inB)).is(false)

			A:UpdateAncestors({ rootB })
			expect(H.waitUntil(function()
				return reasons[inA] ~= nil
			end, 3)).is(true)
			expect(reasons[inA]).is("LeftAncestry")
			expect(H.waitStarted(A, inB, 3)).is(true)

			A:Destroy()
			rootA:Destroy()
			rootB:Destroy()
		end)
	end)
end

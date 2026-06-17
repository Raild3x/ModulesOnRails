--!strict
--[[
	Unit tests for Diff module snapshot-based diffing.
]]

return function(t: tiniest)
	local Diff = require("../Diff")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	-- Stub oracle: `opaqueSet`/`childrenSet` are plain reference-keyed sets
	-- (not real OpaqueRegistry registries) so these tests probe Diff's ctx
	-- contract in isolation, independent of OpaqueRegistry.
	local function makeCtx(opaqueSet: { [any]: true }?, childrenSet: { [any]: true }?): Diff.Ctx
		local opaque = opaqueSet or {}
		local children = childrenSet or {}
		return {
			isOpaque = function(ref: any): boolean
				return opaque[ref] == true
			end,
			hasOpaqueChildren = function(ref: any): boolean
				return children[ref] == true
			end,
		}
	end

	test("diffFromSnapshot still works with valid snapshots", function()
		local before = Diff.snapshot { x = 1, nested = { y = 2 } }
		local root = Diff.diffFromSnapshot(before, { x = 5, nested = { y = 2 } })
		local flat = Diff.flatten(root, {})

		expect(#flat >= 1).is_true()
		local foundXChange = false
		for _, entry in flat do
			if #entry.path == 1 and entry.path[1] == "x" and entry.type == "changed" and entry.new == 5 then
				foundXChange = true
			end
		end
		expect(foundXChange).is_true()
	end)

	test("ctx == nil behaves identically to omitting it (regression path)", function()
		local before = Diff.snapshot({ a = { b = 1 } }, nil)
		local root = Diff.diffFromSnapshot(before, { a = { b = 2 } }, nil)
		local flat = Diff.flatten(root, {})

		local foundBChange = false
		for _, entry in flat do
			if #entry.path == 2 and entry.path[2] == "b" and entry.type == "changed" and entry.new == 2 then
				foundBChange = true
			end
		end
		expect(foundBChange).is_true()
	end)

	describe("opacity oracle", function()
		test("snapshot of an opaque value is a live-value leaf, not a frozen clone", function()
			local obj = { internal = { 1, 2, 3 } }
			local ctx = makeCtx({ [obj] = true })

			local snap = Diff.snapshot(obj, ctx)

			expect(snap.opaque).is_true()
			expect(snap.children).is(nil)
			expect(snap.ref).is(obj)
			expect(snap.value).is(obj)
			expect(table.isfrozen(snap.value :: any)).never_is_true()
		end)

		test("same ref on both sides of an opaque slot produces no diff, even if internals mutated", function()
			local obj = { internal = 1 }
			local ctx = makeCtx({ [obj] = true })

			local before = Diff.snapshot({ a = obj }, ctx)
			obj.internal = 999 -- internal mutation must be invisible: opacity compares by ref
			local root = Diff.diffFromSnapshot(before, { a = obj }, ctx)

			expect(root).is(nil)
		end)

		test("different refs on an opaque slot produce a single changed leaf (no children)", function()
			local objA = { internal = 1 }
			local objB = { internal = 2 }
			local ctx = makeCtx({ [objA] = true, [objB] = true })

			local before = Diff.snapshot({ a = objA }, ctx)
			local root = Diff.diffFromSnapshot(before, { a = objB }, ctx)

			expect(root).exists()
			local aNode = root and root.children and root.children["a"]
			expect(aNode).exists()
			expect((aNode :: Diff.DiffNode).type).is("changed")
			expect((aNode :: Diff.DiffNode).children).is(nil)
			expect((aNode :: Diff.DiffNode).new).is(objB)
			expect((aNode :: Diff.DiffNode).old).is(objA)
		end)

		test("an opaque value added wholesale produces a leaf, not a child walk", function()
			local obj = { internal = { deep = { 1, 2, 3 } } }
			local ctx = makeCtx({ [obj] = true })

			local before = Diff.snapshot({}, ctx)
			local root = Diff.diffFromSnapshot(before, { a = obj }, ctx)

			local aNode = root and root.children and root.children["a"]
			expect(aNode).exists()
			expect((aNode :: Diff.DiffNode).type).is("added")
			expect((aNode :: Diff.DiffNode).children).is(nil)
			expect((aNode :: Diff.DiffNode).new).is(obj)
		end)

		test("an opaque value removed wholesale produces a leaf, not a child walk", function()
			local obj = { internal = { deep = { 1, 2, 3 } } }
			local ctx = makeCtx({ [obj] = true })

			local before = Diff.snapshot({ a = obj }, ctx)
			local root = Diff.diffFromSnapshot(before, {}, ctx)

			local aNode = root and root.children and root.children["a"]
			expect(aNode).exists()
			expect((aNode :: Diff.DiffNode).type).is("removed")
			expect((aNode :: Diff.DiffNode).children).is(nil)
			expect((aNode :: Diff.DiffNode).old).is(obj)
		end)

		test("a non-opaque parent still diffs structurally around an opaque child leaf", function()
			local opaqueChild = { secret = 1 }
			local ctx = makeCtx({ [opaqueChild] = true })

			local before = Diff.snapshot({ visible = 1, hidden = opaqueChild }, ctx)
			local newOpaqueChild = { secret = 2 }
			local root = Diff.diffFromSnapshot(before, { visible = 2, hidden = newOpaqueChild }, ctx)

			expect(root).exists()
			local visibleNode = root and root.children and root.children["visible"]
			local hiddenNode = root and root.children and root.children["hidden"]
			expect((visibleNode :: Diff.DiffNode).type).is("changed")
			expect((hiddenNode :: Diff.DiffNode).type).is("changed")
			expect((hiddenNode :: Diff.DiffNode).children).is(nil)
			expect((hiddenNode :: Diff.DiffNode).new).is(newOpaqueChild)
		end)

		describe("OpaqueChildren (hasOpaqueChildren)", function()
			test("per-child internal mutation is invisible; the container itself stays transparent", function()
				local container = {}
				local child = { hp = 100 }
				container.child = child
				local ctx = makeCtx(nil, { [container] = true })

				local before = Diff.snapshot(container, ctx)
				child.hp = 50 -- internal mutation on the still-opaque child; must be ignored
				local root = Diff.diffFromSnapshot(before, container, ctx)

				expect(root).is(nil)
			end)

			test("a child ref swap is reported as a single changed leaf", function()
				local container = {}
				local childA = { hp = 100 }
				local childB = { hp = 999 }
				container.slot = childA
				local ctx = makeCtx(nil, { [container] = true })

				local before = Diff.snapshot(container, ctx)
				container.slot = childB
				local root = Diff.diffFromSnapshot(before, container, ctx)

				local slotNode = root and root.children and root.children["slot"]
				expect(slotNode).exists()
				expect((slotNode :: Diff.DiffNode).type).is("changed")
				expect((slotNode :: Diff.DiffNode).children).is(nil)
				expect((slotNode :: Diff.DiffNode).new).is(childB)
			end)

			test("adding a child is tracked as a normal opaque-leaf addition", function()
				local container = { existing = { hp = 1 } }
				local ctx = makeCtx(nil, { [container] = true })

				local before = Diff.snapshot(container, ctx)
				container.fresh = { hp = 2 }
				local root = Diff.diffFromSnapshot(before, container, ctx)

				local freshNode = root and root.children and root.children["fresh"]
				expect(freshNode).exists()
				expect((freshNode :: Diff.DiffNode).type).is("added")
				expect((freshNode :: Diff.DiffNode).children).is(nil)
			end)

			test("removing a child is tracked as a normal opaque-leaf removal", function()
				local childToRemove = { hp = 1 }
				local container = { gone = childToRemove }
				local ctx = makeCtx(nil, { [container] = true })

				local before = Diff.snapshot(container, ctx)
				container.gone = nil
				local root = Diff.diffFromSnapshot(before, container, ctx)

				local goneNode = root and root.children and root.children["gone"]
				expect(goneNode).exists()
				expect((goneNode :: Diff.DiffNode).type).is("removed")
				expect((goneNode :: Diff.DiffNode).children).is(nil)
			end)
		end)

		describe("direct diff with no snapshots (the CheckForChangesBetween shape)", function()
			test("an opaque slot is still detected via the ctx fallback", function()
				local objA = { x = 1 }
				local objB = { x = 2 }
				local ctx = makeCtx({ [objA] = true, [objB] = true })

				local root = Diff.diff({ a = objA }, { a = objB }, nil, nil, ctx)

				local aNode = root and root.children and root.children["a"]
				expect(aNode).exists()
				expect((aNode :: Diff.DiffNode).type).is("changed")
				expect((aNode :: Diff.DiffNode).children).is(nil)
			end)

			test("hasOpaqueChildren is honored via the ctx fallback", function()
				local container = {}
				local childA = { x = 1 }
				container.slot = childA
				local ctx = makeCtx(nil, { [container] = true })

				local childB = { x = 2 }
				local newContainer = { slot = childB }

				local root = Diff.diff(container, newContainer, nil, nil, ctx)

				expect(root).exists()
				local slotNode = root and root.children and root.children["slot"]
				expect(slotNode).exists()
				expect((slotNode :: Diff.DiffNode).type).is("changed")
				expect((slotNode :: Diff.DiffNode).children).is(nil)
			end)
		end)
	end)
end

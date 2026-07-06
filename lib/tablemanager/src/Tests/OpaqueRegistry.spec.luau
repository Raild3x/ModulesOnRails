--!strict
--[[
	Unit tests for OpaqueRegistry: wrapper purity, registration (per-manager
	and global, Opaque and OpaqueChildren), the isOpaque/hasOpaqueChildren
	oracle, and weak-keyed GC behavior.
]]

return function(t: tiniest)
	local OpaqueRegistry = require("../OpaqueRegistry")
	local GcHelpers = require("./Helpers/GcHelpers")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("wrapper constructors", function()
		test("Opaque/GlobalOpaque/OpaqueChildren/GlobalOpaqueChildren have no registration side effect at call time", function()
			local registries = OpaqueRegistry.NewRegistries()
			local obj = { x = 1 }

			OpaqueRegistry.Opaque(obj)
			OpaqueRegistry.GlobalOpaque(obj)
			OpaqueRegistry.OpaqueChildren(obj)
			OpaqueRegistry.GlobalOpaqueChildren(obj)

			expect(registries.Count).is(0)
			expect(registries.Opaque[obj]).is(nil)
			expect(registries.OpaqueChildren[obj]).is(nil)
		end)

		test("wrapper returns a table distinct from the wrapped value", function()
			local obj = { x = 1 }
			local wrapper = OpaqueRegistry.Opaque(obj)

			expect(wrapper).never_is(obj)
			expect(type(wrapper)).is("table")
		end)
	end)

	describe("UnwrapAndRegister", function()
		test("returns the inner value unchanged (same reference)", function()
			local registries = OpaqueRegistry.NewRegistries()
			local obj = { x = 1 }

			local result = OpaqueRegistry.UnwrapAndRegister(registries, OpaqueRegistry.Opaque(obj))

			expect(result).is(obj)
		end)

		test("registers Opaque into the per-manager registry, not the global one", function()
			local registries = OpaqueRegistry.NewRegistries()
			local obj = { x = 1 }

			OpaqueRegistry.UnwrapAndRegister(registries, OpaqueRegistry.Opaque(obj))

			expect(registries.Opaque[obj]).is(true)
			expect(registries.OpaqueChildren[obj]).is(nil)
			expect(registries.Count).is(1)

			local otherRegistries = OpaqueRegistry.NewRegistries()
			local ctx = OpaqueRegistry.MakeCtx(otherRegistries)
			expect(ctx.isOpaque(obj)).is(false) -- not visible to an unrelated manager
		end)

		test("registers OpaqueChildren into the per-manager registry", function()
			local registries = OpaqueRegistry.NewRegistries()
			local container = { items = {} }

			OpaqueRegistry.UnwrapAndRegister(registries, OpaqueRegistry.OpaqueChildren(container))

			expect(registries.OpaqueChildren[container]).is(true)
			expect(registries.Opaque[container]).is(nil)
			expect(registries.Count).is(1)
		end)

		test("registers GlobalOpaque so any manager's ctx resolves it as opaque", function()
			local obj = { tag = "global-opaque-test" }
			OpaqueRegistry.UnwrapAndRegister(OpaqueRegistry.NewRegistries(), OpaqueRegistry.GlobalOpaque(obj))

			local unrelatedRegistries = OpaqueRegistry.NewRegistries()
			local ctx = OpaqueRegistry.MakeCtx(unrelatedRegistries)

			expect(ctx.isOpaque(obj)).is(true)
			expect(unrelatedRegistries.Opaque[obj]).is(nil) -- lives in the global registry, not this manager's
		end)

		test("registers GlobalOpaqueChildren so any manager's ctx resolves it", function()
			local container = { tag = "global-opaque-children-test" }
			OpaqueRegistry.UnwrapAndRegister(OpaqueRegistry.NewRegistries(), OpaqueRegistry.GlobalOpaqueChildren(container))

			local unrelatedRegistries = OpaqueRegistry.NewRegistries()
			local ctx = OpaqueRegistry.MakeCtx(unrelatedRegistries)

			expect(ctx.hasOpaqueChildren(container)).is(true)
		end)

		test("re-registering the same value under a kind does not double-count", function()
			-- The idempotent `== nil` guards (OpaqueRegistry.luau:208/213/218): a
			-- second registration of an already-marked value must NOT bump the count.
			local registries = OpaqueRegistry.NewRegistries()

			-- Per-manager OpaqueChildren (line 208).
			local container = { items = {} }
			OpaqueRegistry.UnwrapAndRegister(registries, OpaqueRegistry.OpaqueChildren(container))
			OpaqueRegistry.UnwrapAndRegister(registries, OpaqueRegistry.OpaqueChildren(container))
			expect(registries.Count).is(1)

			-- GlobalOpaque (line 213) — measured as a delta since the global count is
			-- process-wide.
			local g = { tag = "double-global-opaque" }
			local beforeG = OpaqueRegistry.GlobalCount()
			OpaqueRegistry.UnwrapAndRegister(registries, OpaqueRegistry.GlobalOpaque(g))
			OpaqueRegistry.UnwrapAndRegister(registries, OpaqueRegistry.GlobalOpaque(g))
			expect(OpaqueRegistry.GlobalCount()).is(beforeG + 1)

			-- GlobalOpaqueChildren (line 218).
			local gc = { tag = "double-global-opaque-children" }
			local beforeGC = OpaqueRegistry.GlobalCount()
			OpaqueRegistry.UnwrapAndRegister(registries, OpaqueRegistry.GlobalOpaqueChildren(gc))
			OpaqueRegistry.UnwrapAndRegister(registries, OpaqueRegistry.GlobalOpaqueChildren(gc))
			expect(OpaqueRegistry.GlobalCount()).is(beforeGC + 1)

			expect(registries.OpaqueChildren[container]).is(true)
		end)

		test("a non-wrapper value passes through untouched and unregistered", function()
			local registries = OpaqueRegistry.NewRegistries()
			local obj = { x = 1 }

			local result = OpaqueRegistry.UnwrapAndRegister(registries, obj)

			expect(result).is(obj)
			expect(registries.Count).is(0)
		end)

		test("a scalar wrapper unwraps to the scalar without registering", function()
			local registries = OpaqueRegistry.NewRegistries()

			local result = OpaqueRegistry.UnwrapAndRegister(registries, OpaqueRegistry.Opaque(5))

			expect(result).is(5)
			expect(registries.Count).is(0)
		end)

		test("re-registering the same value does not double-count", function()
			local registries = OpaqueRegistry.NewRegistries()
			local obj = { x = 1 }

			OpaqueRegistry.UnwrapAndRegister(registries, OpaqueRegistry.Opaque(obj))
			OpaqueRegistry.UnwrapAndRegister(registries, OpaqueRegistry.Opaque(obj))

			expect(registries.Count).is(1)
		end)
	end)

	describe("oracle (MakeCtx)", function()
		test("isOpaque/hasOpaqueChildren resolve per-manager marks", function()
			local registries = OpaqueRegistry.NewRegistries()
			local opaqueObj = { a = 1 }
			local childrenContainer = { items = {} }

			OpaqueRegistry.UnwrapAndRegister(registries, OpaqueRegistry.Opaque(opaqueObj))
			OpaqueRegistry.UnwrapAndRegister(registries, OpaqueRegistry.OpaqueChildren(childrenContainer))

			local ctx = OpaqueRegistry.MakeCtx(registries)

			expect(ctx.isOpaque(opaqueObj)).is(true)
			expect(ctx.isOpaque(childrenContainer)).is(false)
			expect(ctx.hasOpaqueChildren(childrenContainer)).is(true)
			expect(ctx.hasOpaqueChildren(opaqueObj)).is(false)
			expect(ctx.isOpaque({})).is(false)
		end)

		test("MakeCtx closures stay correct as marks are added after construction", function()
			local registries = OpaqueRegistry.NewRegistries()
			local ctx = OpaqueRegistry.MakeCtx(registries)
			local obj = { a = 1 }

			expect(ctx.isOpaque(obj)).is(false)

			OpaqueRegistry.UnwrapAndRegister(registries, OpaqueRegistry.Opaque(obj))

			expect(ctx.isOpaque(obj)).is(true)
		end)
	end)

	describe("garbage collection", function()
		test("a per-manager Opaque mark does not keep the object alive (weak-keyed)", function()
			local registries = OpaqueRegistry.NewRegistries()
			local isAlive: () -> boolean

			do
				local obj = { payload = "leak-check" }
				isAlive = GcHelpers.WeakProbe(obj)
				OpaqueRegistry.UnwrapAndRegister(registries, OpaqueRegistry.Opaque(obj))
			end

			local collected = GcHelpers.WaitForCollection(isAlive)

			expect(collected).is_true()
			expect(GcHelpers.CountKeys(registries.Opaque)).is(0)
		end)
	end)
end

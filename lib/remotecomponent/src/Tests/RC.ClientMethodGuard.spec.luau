--!strict
--[[
	Pure coverage for the client method dot-call guard. The real client build path
	(BuildObject + guard application) has no client in the Open Cloud CI server
	context, so the identity-check logic is proven here directly on plain tables.
]]

return function(t: tiniest)
	local ClientMethodGuard = require("../ClientMethodGuard")

	local describe = t.describe
	local test = t.test
	local expect = t.expect

	describe("ClientMethodGuard.apply", function()
		test("a colon call passes through and forwards the arguments", function()
			local received: { any }? = nil
			local owner: any = {
				Shoot = function(_self, ...)
					received = { ... }
				end,
			}
			ClientMethodGuard.apply(owner, "Weapon")
			owner:Shoot("a", "b")
			expect((received :: any)[1]).is("a")
			expect((received :: any)[2]).is("b")
		end)

		test("a dot call errors instead of silently dropping the argument", function()
			local owner: any = { Shoot = function() end }
			ClientMethodGuard.apply(owner, "Weapon")
			expect(function()
				owner.Shoot("x") -- missing self
			end).fails_with("call it with ':'")
		end)

		test("an explicit-self dot call is allowed", function()
			local called = false
			local owner: any = {
				Shoot = function(_self)
					called = true
				end,
			}
			ClientMethodGuard.apply(owner, "Weapon")
			owner.Shoot(owner) -- explicit self via dot
			expect(called).is(true)
		end)

		test("non-function entries (signals, properties) are left untouched", function()
			local prop = { Get = function() end }
			local owner: any = { Ammo = prop }
			ClientMethodGuard.apply(owner, "Weapon")
			expect(owner.Ammo).is(prop)
		end)
	end)
end

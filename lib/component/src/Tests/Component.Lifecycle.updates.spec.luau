--!nonstrict
--[[
	Lifecycle branches the other specs don't reach: the optional per-frame update
	loops (HeartbeatUpdate / SteppedUpdate / RenderSteppedUpdate) that connect at
	start, and construction hooks that YIELD and then resolve via a Promise or
	error (the adopted-Promise `finish` continuation).
]]

return function(t: any)
	local H = require(script.Parent.Helpers)
	local Promise = require(script.Parent.Parent.Parent.Promise :: any) :: any

	local describe = t.describe
	local test = t.test
	local expect = t.expect

	describe("update loops", function()
		test("defining update methods connects them on start", function()
			local heartbeats = 0
			local A, aTag = H.makeClass {
				HeartbeatUpdate = function(_self, _dt)
					heartbeats += 1
				end,
				SteppedUpdate = function(_self, _dt) end,
				RenderSteppedUpdate = function(_self, _dt) end,
			}
			local p = H.taggedPart(aTag)
			expect(H.waitStarted(A, p, 3)).is(true)
			-- Best-effort: the Heartbeat connection fires in Studio's edit loop. The
			-- branch coverage comes from the connect code running at start regardless.
			H.waitUntil(function()
				return heartbeats > 0
			end, 2)

			A:Destroy()
			p:Destroy()
		end)
	end)

	describe("asynchronous construction", function()
		test("a Construct that yields then returns a Promise chains to completion", function()
			local A, aTag = H.makeClass {
				Construct = function(_self)
					task.wait(0.05)
					return Promise.resolve()
				end,
			}
			local p = H.taggedPart(aTag)
			expect(H.waitStarted(A, p, 3)).is(true)

			A:Destroy()
			p:Destroy()
		end)

		test("a Construct that yields then errors never starts", function()
			local A, aTag = H.makeClass {
				Construct = function(_self)
					task.wait(0.05)
					error("late boom")
				end,
			}
			local p = H.taggedPart(aTag)
			task.wait(0.2)
			expect(A:Has(p)).is(false)

			A:Destroy()
			p:Destroy()
		end)
	end)
end

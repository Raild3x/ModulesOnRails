--!nonstrict
--[[
	Coverage for the public class/instance methods that the lifecycle and query
	specs never touch directly: GetAll, GetAncestors/UpdateAncestors,
	WaitForInstance, GetComponent, the AddPromise/RemoveTask/GetTask task API, and
	the module-level getUnsetupComponents getter.
]]

return function(t: any)
	local H = require(script.Parent.Helpers)
	local Component = require(script.Parent.Parent :: any) :: any
	local Promise = require(script.Parent.Parent.Parent.Promise :: any) :: any

	local describe = t.describe
	local test = t.test
	local expect = t.expect

	describe("class reads", function()
		test("GetAll returns a fresh copy of the active components", function()
			local A, aTag = H.makeClass()
			local p1 = H.taggedPart(aTag)
			local p2 = H.taggedPart(aTag)
			expect(H.waitStarted(A, p1, 3)).is(true)
			expect(H.waitStarted(A, p2, 3)).is(true)

			local all = A:GetAll()
			expect(#all).is(2)
			-- A copy: clearing the returned array doesn't disturb the class.
			table.clear(all)
			expect(#A:GetAll()).is(2)

			A:Destroy()
			p1:Destroy()
			p2:Destroy()
		end)

		test("GetAncestors returns a copy; UpdateAncestors swaps it and fires the signal", function()
			local A = H.makeClass()
			local original = A:GetAncestors()
			expect(#original).is(1)
			expect(original[1]).is(workspace)
			-- Mutating the returned copy leaves the class untouched.
			table.insert(original, game)
			expect(#A:GetAncestors()).is(1)

			local firedNew, firedOld = nil, nil
			local conn = A.AncestorsChanged:Connect(function(newList, oldList)
				firedNew, firedOld = newList, oldList
			end)
			A:UpdateAncestors { workspace, game }
			expect(#A:GetAncestors()).is(2)
			expect(firedNew ~= nil and #firedNew == 2).is(true)
			expect(firedOld ~= nil and #firedOld == 1).is(true)

			conn:Disconnect()
			A:Destroy()
		end)
	end)

	describe("cross-component lookup", function()
		test("GetComponent finds a sibling on the same instance, nil otherwise", function()
			local A, aTag = H.makeClass()
			local B, bTag = H.makeClass()
			local Absent = H.makeClass()
			local part = Instance.new("Part")
			part.Anchored = true
			game:GetService("CollectionService"):AddTag(part, aTag)
			game:GetService("CollectionService"):AddTag(part, bTag)
			part.Parent = workspace

			expect(H.waitStarted(A, part, 3)).is(true)
			expect(H.waitStarted(B, part, 3)).is(true)

			local aInst = A:FromInstance(part)
			expect(aInst:GetComponent(B)).is(B:FromInstance(part))
			expect(aInst:GetComponent(Absent)).never_exists()

			A:Destroy()
			B:Destroy()
			Absent:Destroy()
			part:Destroy()
		end)
	end)

	describe("WaitForInstance", function()
		test("resolves immediately for an already-started instance", function()
			local A, aTag = H.makeClass()
			local p = H.taggedPart(aTag)
			expect(H.waitStarted(A, p, 3)).is(true)

			local ok, comp = A:WaitForInstance(p):await()
			expect(ok).is(true)
			expect(comp).is(A:FromInstance(p))

			A:Destroy()
			p:Destroy()
		end)

		test("rejects on timeout when no component ever starts", function()
			local A = H.makeClass()
			local never = Instance.new("Part") -- never tagged / never constructs
			local ok = A:WaitForInstance(never, 0.1):await()
			expect(ok).is(false)

			A:Destroy()
			never:Destroy()
		end)
	end)

	describe("core-Janitor task API", function()
		test("AddTask + GetTask + RemoveTask (clean and no-clean)", function()
			local A, aTag = H.makeClass()
			local p = H.taggedPart(aTag)
			expect(H.waitStarted(A, p, 3)).is(true)
			local inst = A:FromInstance(p)

			local cleaned = false
			local ran = inst:AddTask(function()
				cleaned = true
			end, true, "cleanKey")
			-- GetTask returns the stored task by index.
			expect(inst:GetTask("cleanKey")).is(ran)

			-- RemoveTask cleans by default.
			inst:RemoveTask("cleanKey")
			expect(cleaned).is(true)
			expect(inst:GetTask("cleanKey")).never_exists()

			-- RemoveTask with dontClean skips cleanup.
			local cleaned2 = false
			inst:AddTask(function()
				cleaned2 = true
			end, true, "keepKey")
			inst:RemoveTask("keepKey", true)
			expect(cleaned2).is(false)

			A:Destroy()
			p:Destroy()
		end)

		test("AddPromise registers a promise that RemoveTask cancels", function()
			local A, aTag = H.makeClass()
			local p = H.taggedPart(aTag)
			expect(H.waitStarted(A, p, 3)).is(true)
			local inst = A:FromInstance(p)

			local cancelled = false
			local pending = Promise.new(function(_resolve, _reject, onCancel)
				onCancel(function()
					cancelled = true
				end)
			end)
			inst:AddPromise(pending, "promiseKey")
			inst:RemoveTask("promiseKey")
			expect(H.waitUntil(function()
				return cancelled
			end, 2)).is(true)

			A:Destroy()
			p:Destroy()
		end)
	end)

	describe("module getters", function()
		test("getUnsetupComponents returns a table", function()
			expect(type(Component.getUnsetupComponents())).is("table")
		end)
	end)
end

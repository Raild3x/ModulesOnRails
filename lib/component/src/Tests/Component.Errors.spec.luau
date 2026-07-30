--!nonstrict
--[[
	The full expected-behavior image: an error and a yield injected at every
	lifecycle point (each extension hook, each component hook, and mid-hook
	cancellation), asserting the resulting phase transitions, teardown behavior,
	and core-Janitor cleanup in each case.
]]

local CollectionService = game:GetService("CollectionService")

return function(t: any)
	local H = require(script.Parent.Helpers)

	local describe = t.describe
	local test = t.test
	local expect = t.expect

	-- Build a component whose lifecycle points behave per `behaviors[point]`,
	-- which is "error", "yield", or a function. `log` records what happened.
	local function scenario(behaviors)
		behaviors = behaviors or {}
		local log = { stopReason = nil, cleaned = false, started = false, order = {} }
		local function act(name)
			table.insert(log.order, name)
			local b = behaviors[name]
			if b == "error" then
				error("boom@" .. name)
			elseif b == "yield" then
				task.wait(0.04)
			elseif type(b) == "function" then
				return b()
			end
		end
		local ext = {
			Constructing = function()
				return act("Constructing")
			end,
			Constructed = function()
				return act("Constructed")
			end,
			Starting = function()
				return act("Starting")
			end,
			Started = function()
				return act("Started")
			end,
			Stopping = function()
				table.insert(log.order, "Stopping")
			end,
			Stopped = function()
				table.insert(log.order, "Stopped")
			end,
		}
		local def = {
			Construct = function(self)
				self:AddTask(function()
					log.cleaned = true
				end)
				return act("Construct")
			end,
			Start = function(self)
				log.started = true
				return act("Start")
			end,
			Stop = function(_, reason)
				log.stopReason = reason
			end,
		}
		local class, tag = H.makeClass(def, { Extensions = { ext } })
		return class, tag, log
	end

	local ERROR_POINTS = { "Constructing", "Construct", "Constructed", "Starting", "Start", "Started" }

	describe("an error at any lifecycle point tears down cleanly", function()
		for _, point in ERROR_POINTS do
			test(`error in {point}: Stop runs, core Janitor cleaned, not left tracked`, function()
				local class, tag, log = scenario { [point] = "error" }
				local part = H.taggedPart(tag)

				expect(H.waitUntil(function()
					return log.stopReason ~= nil
				end, 3)).is(true)
				-- Construct registers the AddTask cleanup, so anything from Construct
				-- onward must have been cleaned. (An error in the Constructing hook
				-- precedes Construct, so nothing was registered to clean.)
				if point ~= "Constructing" then
					expect(log.cleaned).is(true)
				end
				expect(class:Has(part)).is(false)
				expect(class:FromInstance(part)).never_exists()

				class:Destroy()
				part:Destroy()
			end)
		end
	end)

	describe("a yield at any lifecycle point still completes", function()
		for _, point in { "Constructing", "Construct", "Constructed", "Starting", "Start", "Started" } do
			test(`yield in {point}: component still starts`, function()
				local class, tag = scenario { [point] = "yield" }
				local part = H.taggedPart(tag)
				expect(H.waitStarted(class, part, 3)).is(true)
				class:Destroy()
				part:Destroy()
			end)
		end
	end)

	describe("isolation and cancellation", function()
		test("one erroring component class does not affect another on the same instance", function()
			local goodStarted = false
			local badClass, badTag = H.makeClass {
				Construct = function()
					error("bad")
				end,
			}
			local goodClass, goodTag = H.makeClass {
				Start = function()
					goodStarted = true
				end,
			}
			local part = Instance.new("Part")
			part.Anchored = true
			CollectionService:AddTag(part, badTag)
			CollectionService:AddTag(part, goodTag)
			part.Parent = workspace

			expect(H.waitUntil(function()
				return goodStarted
			end, 3)).is(true)
			expect(badClass:Has(part)).is(false)

			badClass:Destroy()
			goodClass:Destroy()
			part:Destroy()
		end)

		test("untagging during a yielding Construct cancels it; never starts", function()
			local class, tag, log = scenario {
				Construct = function()
					task.wait(0.3)
				end,
			}
			local part = H.taggedPart(tag)
			task.wait(0.05)
			CollectionService:RemoveTag(part, tag)

			task.wait(0.4)
			expect(log.started).is(false)
			expect(class:Has(part)).is(false)

			class:Destroy()
			part:Destroy()
		end)

		test("leaving valid ancestors during a yielding Construct cancels it", function()
			local class, tag, log = scenario {
				Construct = function()
					task.wait(0.3)
				end,
			}
			local part = H.taggedPart(tag)
			task.wait(0.05)
			part.Parent = game:GetService("ReplicatedStorage")

			task.wait(0.4)
			expect(log.started).is(false)

			class:Destroy()
			part:Destroy()
		end)
	end)
end

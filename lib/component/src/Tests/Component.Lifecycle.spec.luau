--!nonstrict
--[[
	Core lifecycle coverage: construct -> start -> stop across the real
	CollectionService + ancestry machinery. Runs in the Open Cloud server context
	(a real DataModel, so tags, RunService, and task scheduling all behave).

	The "construction request" block covers the scheduling protocol itself — the
	reservation that dedupes construction attempts, the lock that supersedes a
	stale one, and the class-destroy handshake. Those are pure interface tests:
	they assert observable lifecycle behavior, not how the slot is stored.
]]

local CollectionService = game:GetService("CollectionService")

return function(t: any)
	local Component = require(script.Parent.Parent :: any) :: any
	local Helpers = require(script.Parent.Helpers :: any) :: any

	local describe = t.describe
	local test = t.test
	local expect = t.expect

	local makeClass = Helpers.makeClass
	local taggedPart = Helpers.taggedPart
	local waitUntil = Helpers.waitUntil

	describe("construct -> start", function()
		test("a tagged instance under a valid ancestor constructs and starts", function()
			local order = {}
			local class, tag = makeClass {
				Construct = function(self)
					table.insert(order, "construct")
					self.value = 10
				end,
				Start = function(self)
					table.insert(order, "start")
				end,
			}
			local part = taggedPart(tag)

			expect(waitUntil(function()
				return class:Has(part)
			end)).is(true)

			local component = class:FromInstance(part)
			expect(component).exists()
			expect(component.value).is(10)
			expect(component:IsStarted()).is(true)
			expect(class:GetLifecycleStatus(part)).is("Started")
			expect(order[1]).is("construct")
			expect(order[2]).is("start")

			class:Destroy()
			part:Destroy()
		end)

		test("instances outside valid ancestors do not construct", function()
			local class, tag = makeClass(nil, { Ancestors = { workspace } })
			local part = Instance.new("Part")
			CollectionService:AddTag(part, tag)
			part.Parent = game:GetService("ReplicatedStorage")

			task.wait()
			task.wait()
			expect(class:FromInstance(part)).never_exists()

			class:Destroy()
			part:Destroy()
		end)
	end)

	describe("teardown", function()
		test("untagging stops the component and runs Stop with reason Untagged", function()
			local stops = {}
			local class, tag = makeClass {
				Stop = function(self, reason)
					table.insert(stops, reason)
				end,
			}
			local part = taggedPart(tag)
			expect(waitUntil(function()
				return class:Has(part)
			end)).is(true)

			CollectionService:RemoveTag(part, tag)
			expect(waitUntil(function()
				return #stops > 0
			end)).is(true)
			expect(stops[1]).is("Untagged")
			expect(class:FromInstance(part)).never_exists()

			class:Destroy()
			part:Destroy()
		end)

		test("AddTask resources are cleaned up on stop regardless", function()
			local cleaned = false
			local class, tag = makeClass {
				Construct = function(self)
					self:AddTask(function()
						cleaned = true
					end)
				end,
			}
			local part = taggedPart(tag)
			expect(waitUntil(function()
				return class:Has(part)
			end)).is(true)

			CollectionService:RemoveTag(part, tag)
			expect(waitUntil(function()
				return cleaned
			end)).is(true)

			class:Destroy()
			part:Destroy()
		end)

		test("class:Destroy stops components with reason ClassDestroyed", function()
			local reason
			local class, tag = makeClass {
				Stop = function(self, r)
					reason = r
				end,
			}
			local part = taggedPart(tag)
			expect(waitUntil(function()
				return class:Has(part)
			end)).is(true)

			class:Destroy()
			expect(waitUntil(function()
				return reason ~= nil
			end)).is(true)
			expect(reason).is("ClassDestroyed")

			part:Destroy()
		end)
	end)

	describe("yielding lifecycle", function()
		test("a yielding Construct still completes and starts", function()
			local class, tag = makeClass {
				Construct = function(self)
					task.wait(0.05)
					self.ready = true
				end,
				Start = function(self)
					self.started = self.ready == true
				end,
			}
			local part = taggedPart(tag)
			expect(waitUntil(function()
				return class:Has(part)
			end, 3)).is(true)
			expect(class:FromInstance(part).started).is(true)

			class:Destroy()
			part:Destroy()
		end)
	end)

	describe("construction request", function()
		test("two CreateFromInstance calls in one frame construct one component", function()
			local constructs = 0
			local class = makeClass {
				Construct = function(self)
					constructs += 1
				end,
			}
			local part = Instance.new("Part")
			part.Anchored = true
			part.Parent = workspace

			-- Both calls land before the deferred driver runs; the second must
			-- find the slot already reserved rather than start a second chain.
			class:GetOrCreateFromInstance(part)
			class:GetOrCreateFromInstance(part)

			expect(waitUntil(function()
				return class:Has(part)
			end, 3)).is(true)
			task.wait()
			task.wait()
			expect(constructs).is(1)

			class:Destroy()
			part:Destroy()
		end)

		test("a same-frame untag + retag ends with exactly one started component", function()
			local constructs = 0
			local class, tag = makeClass {
				Construct = function(self)
					constructs += 1
				end,
			}
			local part = taggedPart(tag)
			expect(waitUntil(function()
				return class:Has(part)
			end)).is(true)
			expect(constructs).is(1)

			-- Drop and re-add within one frame: the stale reservation must not
			-- survive to block the new one, nor let a second chain start.
			CollectionService:RemoveTag(part, tag)
			CollectionService:AddTag(part, tag)

			expect(waitUntil(function()
				return class:Has(part)
			end, 3)).is(true)
			task.wait()
			task.wait()
			expect(constructs).is(2)
			expect(class:FromInstance(part)).exists()

			class:Destroy()
			part:Destroy()
		end)

		test("a construction cancelled mid-Construct still runs Stop and cleans its tasks", function()
			local cleaned = false
			local stopReason = nil
			local entered = false
			local class, tag = makeClass {
				Construct = function(self)
					self:AddTask(function()
						cleaned = true
					end)
					entered = true
					task.wait(0.25)
				end,
				Stop = function(self, reason)
					stopReason = reason
				end,
			}
			local part = taggedPart(tag)

			expect(waitUntil(function()
				return entered
			end)).is(true)
			expect(class:GetLifecycleStatus(part)).is("Constructing")

			CollectionService:RemoveTag(part, tag)

			expect(waitUntil(function()
				return cleaned
			end, 3)).is(true)
			expect(stopReason).is("Untagged")

			class:Destroy()
			part:Destroy()
		end)

		test("a construction superseded while unpublished stops with reason Superseded", function()
			-- A yielding `ShouldConstruct` parks the driver BEFORE it publishes its
			-- pending record, so an untag cannot cancel it directly — only the
			-- construct lock can catch that it is stale.
			local gate = false
			local entered = false
			local reasons = {}
			local extension = {
				ShouldConstruct = function()
					entered = true
					while not gate do
						task.wait()
					end
					return true
				end,
			}
			local class, tag = makeClass({
				Stop = function(self, reason)
					table.insert(reasons, reason)
				end,
			}, { Extensions = { extension } })
			local part = taggedPart(tag)

			expect(waitUntil(function()
				return entered
			end)).is(true)

			CollectionService:RemoveTag(part, tag)
			gate = true

			expect(waitUntil(function()
				return #reasons > 0
			end, 3)).is(true)
			expect(reasons[1]).is("Superseded")

			class:Destroy()
			part:Destroy()
		end)

		test("class:Destroy during an in-flight teardown still fires Stopped", function()
			local stoppedFired = false
			local class, tag = makeClass {
				Stop = function(self)
					-- Park the deferred stop sequence so Destroy lands mid-teardown.
					task.wait(0.15)
				end,
			}
			local part = taggedPart(tag)
			expect(waitUntil(function()
				return class:Has(part)
			end)).is(true)

			local component = class:FromInstance(part)
			class.Stopped:Connect(function()
				stoppedFired = true
			end)

			CollectionService:RemoveTag(part, tag)
			expect(waitUntil(function()
				return class:GetLifecycleStatus(component) == "Stopping"
			end)).is(true)

			-- The class Janitor owns the `Stopped` signal the parked teardown has
			-- still to fire on; destroying it now must be deferred until idle.
			class:Destroy()

			expect(waitUntil(function()
				return stoppedFired
			end, 3)).is(true)

			part:Destroy()
		end)
	end)

	describe("GetAllComponentsForInstance", function()
		test("returns every component across classes bound to one instance", function()
			local classA, tagA = makeClass()
			local classB, tagB = makeClass()
			local part = Instance.new("Part")
			part.Anchored = true
			CollectionService:AddTag(part, tagA)
			CollectionService:AddTag(part, tagB)
			part.Parent = workspace

			expect(waitUntil(function()
				return classA:Has(part) and classB:Has(part)
			end, 3)).is(true)

			local all = Component.GetAllComponentsForInstance(part)
			expect(#all).is(2)
			local seen = {}
			for _, component in all do
				seen[component] = true
			end
			expect(seen[classA:FromInstance(part)]).is(true)
			expect(seen[classB:FromInstance(part)]).is(true)

			classA:Destroy()
			classB:Destroy()
			part:Destroy()
		end)

		test("a component appears only once it finishes constructing", function()
			local gate = false
			local class, tag = makeClass {
				Construct = function(self)
					while not gate do
						task.wait()
					end
				end,
			}
			local part = taggedPart(tag)

			-- Still constructing: not yet globally visible.
			expect(waitUntil(function()
				return class:GetLifecycleStatus(part) == "Constructing"
			end)).is(true)
			expect(#Component.GetAllComponentsForInstance(part)).is(0)

			gate = true
			expect(waitUntil(function()
				return class:Has(part)
			end, 3)).is(true)
			expect(#Component.GetAllComponentsForInstance(part)).is(1)

			class:Destroy()
			part:Destroy()
		end)

		test("entries drop on teardown, and the instance clears when its last component goes", function()
			local classA, tagA = makeClass()
			local classB, tagB = makeClass()
			local part = Instance.new("Part")
			part.Anchored = true
			CollectionService:AddTag(part, tagA)
			CollectionService:AddTag(part, tagB)
			part.Parent = workspace

			expect(waitUntil(function()
				return classA:Has(part) and classB:Has(part)
			end, 3)).is(true)
			expect(#Component.GetAllComponentsForInstance(part)).is(2)

			CollectionService:RemoveTag(part, tagA)
			expect(waitUntil(function()
				return not classA:Has(part)
			end)).is(true)
			expect(#Component.GetAllComponentsForInstance(part)).is(1)

			CollectionService:RemoveTag(part, tagB)
			expect(waitUntil(function()
				return not classB:Has(part)
			end)).is(true)
			expect(#Component.GetAllComponentsForInstance(part)).is(0)

			classA:Destroy()
			classB:Destroy()
			part:Destroy()
		end)
	end)
end

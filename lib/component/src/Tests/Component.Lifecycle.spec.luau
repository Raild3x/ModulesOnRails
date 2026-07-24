--!nonstrict
--[[
	Core lifecycle coverage: construct -> start -> stop across the real
	CollectionService + ancestry machinery. Runs in the Open Cloud server context
	(a real DataModel, so tags, RunService, and task scheduling all behave).
]]

local CollectionService = game:GetService("CollectionService")

return function(t: any)
	local Component = require(script.Parent.Parent :: any) :: any

	local describe = t.describe
	local test = t.test
	local expect = t.expect

	local tagCounter = 0
	local function uniqueTag(): string
		tagCounter += 1
		return `CmpSpec_{tagCounter}_{os.clock()}`
	end

	-- Spin the scheduler until `predicate()` is truthy or we time out.
	local function waitUntil(predicate, timeout: number?)
		local deadline = os.clock() + (timeout or 2)
		while os.clock() < deadline do
			if predicate() then
				return true
			end
			task.wait()
		end
		return predicate()
	end

	-- Build a tagged part under workspace and its component class; returns both
	-- plus a cleanup fn.
	local function makeClass(overrides, ancestors)
		local tag = uniqueTag()
		local class = Component.new { Tag = tag, Ancestors = ancestors or { workspace } }
		if overrides then
			for k, v in overrides do
				class[k] = v
			end
		end
		return class, tag
	end

	local function taggedPart(tag: string): Instance
		local part = Instance.new("Part")
		part.Anchored = true
		CollectionService:AddTag(part, tag)
		part.Parent = workspace
		return part
	end

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
			local class, tag = makeClass { Ancestors = { workspace } }
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
end

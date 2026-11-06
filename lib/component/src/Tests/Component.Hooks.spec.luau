--!nonstrict
--[[
	Collection-style member hooks + lifecycle-name aliases (Waves 2 + 8):
	OnConstruct/OnStart/OnStop precedence over legacy names, `On*` event
	wrappers, OnAttributeChanged/OnPropertyChanged namespace tables (dot-form
	function statements), mixed-class silent ignore, and teardown
	disconnection.

	Wave 8 native-parity contract (probed, test/collection_probe/
	late_hooks.luau): hooks are live from successful construction to
	teardown-begin; a hook declared at ANY time connects to every live
	instance in the same cycle (no replay); names are declare-once (second
	definition errors); nil / non-function assignment errors. Extension
	`Hooks` are independent additive connections.

	The dispatch guard (`instToComponents[instance] == component`) silences a
	released component's hooks before physical disconnection; its false branch
	needs deferred delivery or the release-to-teardown gap to be observable.
]]

return function(t: any)
	local H = require(script.Parent.Helpers)

	local describe = t.describe
	local test = t.test
	local expect = t.expect

	describe("lifecycle name aliases", function()
		test("OnConstruct/OnStart/OnStop drive the lifecycle", function()
			local order = {}
			local stopReason = nil
			local A, aTag = H.makeClass {
				OnConstruct = function(self)
					table.insert(order, "construct")
					expect(self.Instance ~= nil).is(true)
				end,
				OnStart = function(_self)
					table.insert(order, "start")
				end,
				OnStop = function(_self, reason)
					table.insert(order, "stop")
					stopReason = reason
				end,
			}
			local p = H.taggedPart(aTag)
			expect(H.waitStarted(A, p, 3)).is(true)
			p:RemoveTag(aTag)
			expect(H.waitUntil(function()
				return stopReason ~= nil
			end, 3)).is(true)
			expect(table.concat(order, ",")).is("construct,start,stop")
			expect(stopReason).is("Untagged")

			A:Destroy()
			p:Destroy()
		end)

		test("On* wins when both spellings are defined; legacy alone still runs", function()
			local winner = nil
			local A, aTag = H.makeClass {
				OnStart = function(_self)
					winner = "OnStart"
				end,
				Start = function(_self)
					winner = "Start"
				end,
			}
			local p = H.taggedPart(aTag)
			expect(H.waitStarted(A, p, 3)).is(true)
			expect(winner).is("OnStart")
			A:Destroy()
			p:Destroy()

			local legacyRan = false
			local B, bTag = H.makeClass {
				Start = function(_self)
					legacyRan = true
				end,
			}
			local p2 = H.taggedPart(bTag)
			expect(H.waitStarted(B, p2, 3)).is(true)
			expect(legacyRan).is(true)
			B:Destroy()
			p2:Destroy()
		end)
	end)

	describe("event wrapper hooks", function()
		test("OnChildAdded fires between start and stop with (self, child)", function()
			local calls = {}
			local A, aTag = H.makeClass {
				OnChildAdded = function(self, child)
					table.insert(calls, { self = self, childName = child.Name })
				end,
			}
			local p = H.taggedPart(aTag)
			expect(H.waitStarted(A, p, 3)).is(true)

			local attachment = Instance.new("Attachment")
			attachment.Name = "Probe"
			attachment.Parent = p
			expect(H.waitUntil(function()
				return #calls >= 1
			end, 2)).is(true)
			expect(calls[1].childName).is("Probe")
			expect(calls[1].self.Instance).is(p)

			-- Teardown disconnects the wrapper before Stop: post-stop events
			-- never dispatch.
			p:RemoveTag(aTag)
			H.waitUntil(function()
				return not A:Has(p)
			end, 2)
			local countAfterStop = #calls
			local second = Instance.new("Attachment")
			second.Parent = p
			task.wait(0.1)
			expect(#calls).is(countAfterStop)

			A:Destroy()
			p:Destroy()
		end)

		test("a hook for a member the instance's class lacks is silently ignored", function()
			local A, aTag = H.makeClass {
				OnTouched = function() end, -- Folder has no Touched
				OnName = function() end, -- Name exists but is not a signal
			}
			local folder = Instance.new("Folder")
			folder:AddTag(aTag)
			folder.Parent = workspace
			expect(H.waitStarted(A, folder, 3)).is(true)

			A:Destroy()
			folder:Destroy()
		end)
	end)

	describe("namespace hooks", function()
		test("OnAttributeChanged.X via dot-form function statement, name-filtered", function()
			local hpCalls = 0
			local A, aTag = H.makeClass()
			function A.OnAttributeChanged.HP(self)
				expect(self.Instance ~= nil).is(true)
				hpCalls += 1
			end

			local p = H.taggedPart(aTag)
			expect(H.waitStarted(A, p, 3)).is(true)

			-- Changes before start never dispatch; only the named attribute does.
			p:SetAttribute("Other", 1)
			p:SetAttribute("HP", 100)
			expect(H.waitUntil(function()
				return hpCalls >= 1
			end, 2)).is(true)
			expect(hpCalls).is(1)

			-- Disconnected on stop.
			p:RemoveTag(aTag)
			H.waitUntil(function()
				return not A:Has(p)
			end, 2)
			p:SetAttribute("HP", 50)
			task.wait(0.1)
			expect(hpCalls).is(1)

			A:Destroy()
			p:Destroy()
		end)

		test("OnPropertyChanged.X fires; unknown property names are skipped", function()
			local transparencyCalls = 0
			local A, aTag = H.makeClass()
			function A.OnPropertyChanged.Transparency(_self)
				transparencyCalls += 1
			end
			-- A Part has no `Text` property: the subscription is skipped, the
			-- component still starts.
			function A.OnPropertyChanged.Text(_self) end

			local p = H.taggedPart(aTag)
			expect(H.waitStarted(A, p, 3)).is(true)
			p.Transparency = 0.25
			expect(H.waitUntil(function()
				return transparencyCalls >= 1
			end, 2)).is(true)

			A:Destroy()
			p:Destroy()
		end)

		test("non-function namespace entries error; whole-namespace clobber is tolerated", function()
			local calls = 0
			local A, aTag = H.makeClass()
			function A.OnAttributeChanged.HP(_self)
				calls += 1
			end
			-- Parity: assigning a non-function to a hook name is an error.
			local ok, err = pcall(function()
				A.OnAttributeChanged.Bogus = 5
			end)
			expect(ok).is(false)
			expect(string.find(tostring(err), "expected a function") ~= nil).is(true)
			-- Replacing the namespace itself is an existing-key class write the
			-- interceptor cannot see — documented-undefined, tolerated.
			A.OnPropertyChanged = nil

			local p = H.taggedPart(aTag)
			expect(H.waitStarted(A, p, 3)).is(true)
			p:SetAttribute("HP", 1)
			expect(H.waitUntil(function()
				return calls >= 1
			end, 2)).is(true)

			A:Destroy()
			p:Destroy()
		end)

		test("hooks connect after construction (construct-phase changes never dispatch)", function()
			local calls = 0
			local A, aTag = H.makeClass {
				OnConstruct = function(self)
					self.Instance:SetAttribute("HP", 1)
				end,
			}
			function A.OnAttributeChanged.HP(_self)
				calls += 1
			end

			local p = H.taggedPart(aTag)
			expect(H.waitStarted(A, p, 3)).is(true)
			task.wait(0.1)
			expect(calls).is(0)
			p:SetAttribute("HP", 2)
			expect(H.waitUntil(function()
				return calls >= 1
			end, 2)).is(true)

			A:Destroy()
			p:Destroy()
		end)

		test("hooks are live during the start window (a change made in OnStart dispatches)", function()
			local calls = 0
			local A, aTag = H.makeClass {
				OnStart = function(self)
					self.Instance:SetAttribute("HP", 5)
				end,
			}
			function A.OnAttributeChanged.HP(_self)
				calls += 1
			end

			local p = H.taggedPart(aTag)
			expect(H.waitStarted(A, p, 3)).is(true)
			expect(H.waitUntil(function()
				return calls >= 1
			end, 2)).is(true)

			A:Destroy()
			p:Destroy()
		end)
	end)

	describe("late definition (native parity)", function()
		test("an event hook defined after instances are live connects immediately", function()
			local calls = {}
			local A, aTag = H.makeClass()
			local p = H.taggedPart(aTag)
			expect(H.waitStarted(A, p, 3)).is(true)

			-- Event fired BEFORE the definition: never replayed.
			local early = Instance.new("Attachment")
			early.Parent = p
			task.wait(0.1)

			function A:OnChildAdded(child)
				table.insert(calls, child.Name)
			end
			-- Post-hoc hooks are callbacks, not methods: not readable back.
			expect(rawget(A, "OnChildAdded")).is(nil)

			expect(#calls).is(0) -- no replay of the early event
			local late = Instance.new("Attachment")
			late.Name = "Late"
			late.Parent = p
			expect(H.waitUntil(function()
				return #calls >= 1
			end, 2)).is(true)
			expect(calls[1]).is("Late")

			-- Instances constructed after the definition also get it.
			local p2 = H.taggedPart(aTag)
			expect(H.waitStarted(A, p2, 3)).is(true)
			local second = Instance.new("Attachment")
			second.Name = "Second"
			second.Parent = p2
			expect(H.waitUntil(function()
				return #calls >= 2
			end, 2)).is(true)

			A:Destroy()
			p:Destroy()
			p2:Destroy()
		end)

		test("a namespace hook defined after instances are live connects immediately", function()
			local calls = 0
			local A, aTag = H.makeClass()
			local p = H.taggedPart(aTag)
			expect(H.waitStarted(A, p, 3)).is(true)
			p:SetAttribute("HP", 1) -- before definition: never replayed
			task.wait(0.1)

			function A.OnAttributeChanged.HP(_self)
				calls += 1
			end
			expect(calls).is(0)
			p:SetAttribute("HP", 2)
			expect(H.waitUntil(function()
				return calls >= 1
			end, 2)).is(true)

			A:Destroy()
			p:Destroy()
		end)
	end)

	describe("declare-once and validation (native parity)", function()
		test("second definition of an event hook errors, even with the same function", function()
			local A = (H.makeClass())
			local fn = function(_self) end
			A.OnChildAdded = fn
			local okOther = pcall(function()
				A.OnChildAdded = function(_self) end
			end)
			expect(okOther).is(false)
			local okSame, err = pcall(function()
				A.OnChildAdded = fn
			end)
			expect(okSame).is(false)
			expect(string.find(tostring(err), "already assigned") ~= nil).is(true)
			A:Destroy()
		end)

		test("second definition of a namespace hook errors", function()
			local A = (H.makeClass())
			function A.OnAttributeChanged.HP(_self) end
			local ok, err = pcall(function()
				function A.OnAttributeChanged.HP(_self) end
			end)
			expect(ok).is(false)
			expect(string.find(tostring(err), "already assigned") ~= nil).is(true)
			A:Destroy()
		end)

		test("nil and non-function assignments to hook names error", function()
			local A = (H.makeClass())
			local okNil, errNil = pcall(function()
				A.OnChildAdded = nil
			end)
			expect(okNil).is(false)
			expect(string.find(tostring(errNil), "expected a function") ~= nil).is(true)
			local okNum = pcall(function()
				A.OnSomething = 5
			end)
			expect(okNum).is(false)
			local okKey = pcall(function()
				A.OnAttributeChanged[5] = function() end
			end)
			expect(okKey).is(false)
			A:Destroy()
		end)

		test("a hook declared via config Methods registers AND stays a callable member", function()
			local calls = 0
			local A, aTag = H.makeClass(nil, {
				Methods = {
					OnChildAdded = function(_self, _child)
						calls += 1
					end,
				},
			})
			expect(type(rawget(A, "OnChildAdded"))).is("function")

			local p = H.taggedPart(aTag)
			expect(H.waitStarted(A, p, 3)).is(true)
			Instance.new("Attachment").Parent = p
			expect(H.waitUntil(function()
				return calls >= 1
			end, 2)).is(true)

			A:Destroy()
			p:Destroy()
		end)
	end)

	describe("extension hooks (additive connections)", function()
		test("flat and namespace extension hooks fire and disconnect at stop", function()
			local touched, hpCalls = 0, 0
			local extension = {
				Hooks = {
					OnChildAdded = function(_component, _child)
						touched += 1
					end,
					OnAttributeChanged = {
						HP = function(_component)
							hpCalls += 1
						end,
					},
				},
			}
			local A, aTag = H.makeClass(nil, { Extensions = { extension } })
			local p = H.taggedPart(aTag)
			expect(H.waitStarted(A, p, 3)).is(true)

			Instance.new("Attachment").Parent = p
			p:SetAttribute("HP", 1)
			expect(H.waitUntil(function()
				return touched >= 1 and hpCalls >= 1
			end, 2)).is(true)

			p:RemoveTag(aTag)
			H.waitUntil(function()
				return not A:Has(p)
			end, 2)
			local touchedAfter, hpAfter = touched, hpCalls
			Instance.new("Attachment").Parent = p
			p:SetAttribute("HP", 2)
			task.wait(0.1)
			expect(touched).is(touchedAfter)
			expect(hpCalls).is(hpAfter)

			A:Destroy()
			p:Destroy()
		end)

		test("an extension hook coexists with a same-name class hook (both fire)", function()
			local classCalls, extCalls = 0, 0
			local extension = {
				Hooks = {
					OnChildAdded = function(_component, _child)
						extCalls += 1
					end,
				},
			}
			local A, aTag = H.makeClass({
				OnChildAdded = function(_self, _child)
					classCalls += 1
				end,
			}, { Extensions = { extension } })
			local p = H.taggedPart(aTag)
			expect(H.waitStarted(A, p, 3)).is(true)
			Instance.new("Attachment").Parent = p
			expect(H.waitUntil(function()
				return classCalls >= 1 and extCalls >= 1
			end, 2)).is(true)

			A:Destroy()
			p:Destroy()
		end)

		test("a ShouldExtend-vetoed extension contributes no hooks to that instance", function()
			local extCalls = 0
			local extension = {
				ShouldExtend = function(component)
					return component.Instance:GetAttribute("Extended") == true
				end,
				Hooks = {
					OnChildAdded = function(_component, _child)
						extCalls += 1
					end,
				},
			}
			local A, aTag = H.makeClass(nil, { Extensions = { extension } })

			local vetoed = Instance.new("Part")
			vetoed.Anchored = true
			vetoed:AddTag(aTag)
			vetoed.Parent = workspace
			expect(H.waitStarted(A, vetoed, 3)).is(true)
			Instance.new("Attachment").Parent = vetoed
			task.wait(0.1)
			expect(extCalls).is(0)

			local extended = Instance.new("Part")
			extended.Anchored = true
			extended:SetAttribute("Extended", true)
			extended:AddTag(aTag)
			extended.Parent = workspace
			expect(H.waitStarted(A, extended, 3)).is(true)
			Instance.new("Attachment").Parent = extended
			expect(H.waitUntil(function()
				return extCalls >= 1
			end, 2)).is(true)

			A:Destroy()
			vetoed:Destroy()
			extended:Destroy()
		end)

		test("malformed extension Hooks shapes error at class setup", function()
			local function expectSetupError(hooks: any, needle: string)
				local ok, err = pcall(function()
					local A = (H.makeClass(nil, { Extensions = { { Hooks = hooks } } }))
					A:Destroy()
				end)
				expect(ok).is(false)
				expect(string.find(tostring(err), needle, 1, true) ~= nil).is(true)
			end
			expectSetupError(5, "must be a table")
			expectSetupError({ OnAttributeChanged = function() end }, "table of functions")
			expectSetupError({ OnPropertyChanged = { Anchored = 5 } }, "expected a function")
			expectSetupError({ OnAttributeChanged = { [5] = function() end } }, "expected a function")
			expectSetupError({ Touched = function() end }, "not a valid hook name")
			expectSetupError({ OnConstruct = function() end }, "not a valid hook name")
			expectSetupError({ OnTouched = 5 }, "expected a function")
		end)

		test("a hook-shaped key in extension Methods errors with guidance", function()
			local extension = {
				Methods = {
					OnTouched = function(_self) end,
				},
			}
			local ok, err = pcall(function()
				local A = (H.makeClass(nil, { Extensions = { extension } }))
				A:Destroy()
			end)
			expect(ok).is(false)
			expect(string.find(tostring(err), "Hooks table") ~= nil).is(true)
		end)
	end)
end

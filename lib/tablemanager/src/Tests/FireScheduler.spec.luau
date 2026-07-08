--!strict
--[[
	Direct unit tests for FireScheduler, exercised through its three-method
	interface (FireSignal / RunListener / RunInitial) plus construction:

	  * mode resolution — "bindable" collapses to immediate/deferred once at
	    construction; the signal side is lenient (unknown -> immediate) while the
	    listener side is strict (unknown / non-string errors),
	  * the signal coalesce window — latest-new-value wins, first old value is
	    preserved via the caller-supplied preserve index,
	  * the listener dispatch timings and the coalesce window (including the
	    disconnected-before-flush skip),
	  * RunInitial's immediate-vs-deferred choice and the forceDefer override.

	These assume immediate (non-deferred) native dispatch, matching the rest of
	the suite (see ListenerRegistry.spec's IsDeferred assertion).
]]

return function(t: tiniest)
	local FireScheduler = require("../Listening/FireScheduler")
	local IsDeferred = require("../Listening/IsDeferred")
	assert(IsDeferred() == false, "Tests assume deferred event dispatch is disabled")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	-- A stand-in for one of the manager's public Signals: records each Fire /
	-- FireDeferred call's packed args.
	local function makeFakeSignal()
		local s: any = { fires = {}, deferred = {} }
		function s:Fire(...)
			table.insert(self.fires, table.pack(...))
		end
		function s:FireDeferred(...)
			table.insert(self.deferred, table.pack(...))
		end
		return s
	end

	-- A scheduler with a trivial listener invoker that forwards the eventData to
	-- the listener callback, so RunListener behavior is observable.
	local function makeScheduler(config: any)
		local scheduler = FireScheduler.new(config)
		scheduler:BindListenerInvoker(function(callback, _eventType, eventData, _debugMode)
			callback(eventData)
		end)
		return scheduler
	end

	local function makeListener(callback: (...any) -> ()): any
		return { Callback = callback, Connection = { Connected = true } }
	end

	describe("mode resolution", function()
		test("listener side rejects an unknown mode", function()
			expect(function()
				FireScheduler.new({ ListenerFireMode = "banana" :: any })
			end).fails_with('Invalid ListenerFireMode "banana"')
		end)

		test("listener side rejects a non-string mode", function()
			expect(function()
				FireScheduler.new({ ListenerFireMode = 42 :: any })
			end).fails_with("ListenerFireMode must be a string")
		end)

		test("signal side tolerates an unknown mode (falls through to immediate)", function()
			local scheduler = makeScheduler({ SignalFireMode = "banana" :: any })
			local signal = makeFakeSignal()

			scheduler:FireSignal(signal, nil, "v")
			-- Unknown signal mode behaves as immediate: fired synchronously via :Fire.
			expect(#signal.fires).is(1)
			expect(#signal.deferred).is(0)
		end)

		test("'bindable' resolves to immediate in a non-deferred environment", function()
			local scheduler = makeScheduler({ SignalFireMode = "bindable" })
			local signal = makeFakeSignal()

			scheduler:FireSignal(signal, nil, "v")
			expect(#signal.fires).is(1)
		end)
	end)

	describe("FireSignal", function()
		test("'immediate' fires synchronously via :Fire", function()
			local scheduler = makeScheduler({ SignalFireMode = "immediate" })
			local signal = makeFakeSignal()

			scheduler:FireSignal(signal, nil, "path", 50)
			expect(#signal.fires).is(1)
			expect(signal.fires[1][1]).is("path")
			expect(signal.fires[1][2]).is(50)
		end)

		test("'deferred' routes to :FireDeferred", function()
			local scheduler = makeScheduler({ SignalFireMode = "deferred" })
			local signal = makeFakeSignal()

			scheduler:FireSignal(signal, nil, "path", 50)
			expect(#signal.fires).is(0)
			expect(#signal.deferred).is(1)
		end)

		test("'coalesced' collapses repeated fires, latest new + first old", function()
			local scheduler = makeScheduler({ SignalFireMode = "coalesced" })
			local signal = makeFakeSignal()

			-- Preserve index 3 is the "old value" arg (path, newValue, oldValue).
			scheduler:FireSignal(signal, 3, "path", 50, 100)
			scheduler:FireSignal(signal, 3, "path", 25, 75)
			expect(#signal.fires).is(0) -- nothing synchronous

			task.wait()
			expect(#signal.fires).is(1) -- collapsed into one
			expect(signal.fires[1][2]).is(25) -- latest new value wins
			expect(signal.fires[1][3]).is(100) -- first old value preserved
		end)

		test("'coalesced' with no preserve index is latest-wins for every arg", function()
			local scheduler = makeScheduler({ SignalFireMode = "coalesced" })
			local signal = makeFakeSignal()

			scheduler:FireSignal(signal, nil, "path", 50)
			scheduler:FireSignal(signal, nil, "path", 25)
			task.wait()
			expect(#signal.fires).is(1)
			expect(signal.fires[1][2]).is(25)
		end)

		test("distinct signals coalesce into separate windows", function()
			local scheduler = makeScheduler({ SignalFireMode = "coalesced" })
			local a = makeFakeSignal()
			local b = makeFakeSignal()

			scheduler:FireSignal(a, nil, "a1")
			scheduler:FireSignal(b, nil, "b1")
			task.wait()
			expect(#a.fires).is(1)
			expect(#b.fires).is(1)
		end)
	end)

	describe("RunListener", function()
		test("'immediate' runs the callback synchronously", function()
			local scheduler = makeScheduler({ ListenerFireMode = "immediate" })
			local runs = 0
			local listener = makeListener(function()
				runs += 1
			end)

			scheduler:RunListener(listener, "ValueChanged", { NewValue = 1 }, false)
			expect(runs).is(1)
		end)

		test("'deferred' runs the callback after a yield", function()
			local scheduler = makeScheduler({ ListenerFireMode = "deferred" })
			local runs = 0
			local listener = makeListener(function()
				runs += 1
			end)

			scheduler:RunListener(listener, "ValueChanged", { NewValue = 1 }, false)
			expect(runs).is(0)
			task.wait()
			expect(runs).is(1)
		end)

		test("'coalesced' collapses repeated fires into one carrying latest data", function()
			local scheduler = makeScheduler({ ListenerFireMode = "coalesced" })
			local runs = 0
			local lastValue: any = nil
			local listener = makeListener(function(eventData)
				runs += 1
				lastValue = eventData.NewValue
			end)

			scheduler:RunListener(listener, "ValueChanged", { NewValue = 1 }, false)
			scheduler:RunListener(listener, "ValueChanged", { NewValue = 2 }, false)
			expect(runs).is(0)

			task.wait()
			expect(runs).is(1) -- two fires collapsed
			expect(lastValue).is(2) -- latest event data
		end)

		test("a coalesced listener disconnected before its flush never runs", function()
			local scheduler = makeScheduler({ ListenerFireMode = "coalesced" })
			local runs = 0
			local listener = makeListener(function()
				runs += 1
			end)

			scheduler:RunListener(listener, "ValueChanged", { NewValue = 1 }, false)
			listener.Connection.Connected = false -- disconnect before the deferred flush
			task.wait()
			expect(runs).is(0)
		end)

		test("reuses one idle runner thread across immediate fires", function()
			-- The free-runner thread is created lazily on first immediate dispatch and
			-- reused thereafter; two sequential fires must not leave a thread acquired.
			local scheduler = makeScheduler({ ListenerFireMode = "immediate" })
			local runs = 0
			local listener = makeListener(function()
				runs += 1
			end)

			scheduler:RunListener(listener, "ValueChanged", { NewValue = 1 }, false)
			scheduler:RunListener(listener, "ValueChanged", { NewValue = 2 }, false)
			expect(runs).is(2)
			expect((scheduler :: any)._freeRunnerThread).exists() -- restored, ready to reuse
		end)
	end)

	describe("RunInitial", function()
		test("immediate mode runs the thunk synchronously", function()
			local scheduler = makeScheduler({ ListenerFireMode = "immediate" })
			local ran = false
			scheduler:RunInitial(function()
				ran = true
			end)
			expect(ran).is_true()
		end)

		test("a non-immediate mode defers the thunk", function()
			local scheduler = makeScheduler({ ListenerFireMode = "deferred" })
			local ran = false
			scheduler:RunInitial(function()
				ran = true
			end)
			expect(ran).never_is_true()
			task.wait()
			expect(ran).is_true()
		end)

		test("forceDefer defers even in immediate mode", function()
			local scheduler = makeScheduler({ ListenerFireMode = "immediate" })
			local ran = false
			scheduler:RunInitial(function()
				ran = true
			end, true)
			expect(ran).never_is_true()
			task.wait()
			expect(ran).is_true()
		end)
	end)
end

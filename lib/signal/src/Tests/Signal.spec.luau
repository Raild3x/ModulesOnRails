--!strict
--[[
	Unit tests for the Signal class: construction, firing (immediate/deferred/bindable),
	connection lifecycle, Wait(), and the Wrap/Classic compatibility surfaces.
]]

return function(t: tiniest)
	local Signal = require("../Signal")

	local describe = t.describe
	local test = t.test
	local expect = t.expect

	describe("Construction", function()
		test("Is/instanceof identify Signal instances", function()
			local signal = Signal.new()

			expect(Signal.Is(signal)).is_true()
			expect(Signal.instanceof(signal)).is_true()
			expect(Signal.Is({})).never_is_true()
			expect(Signal.Is(nil)).never_is_true()

			signal:Destroy()
		end)
	end)

	describe("Connect / Fire", function()
		test("Fire delivers arguments to every connection", function()
			local signal = Signal.new()
			local calls = {}

			signal:Connect(function(a, b)
				table.insert(calls, { a, b })
			end)
			signal:Connect(function(a, b)
				table.insert(calls, { a, b })
			end)

			signal:Fire("x", 1)

			expect(#calls).is(2)
			expect(calls[1][1]).is("x")
			expect(calls[1][2]).is(1)
			expect(calls[2][1]).is("x")
			expect(calls[2][2]).is(1)

			signal:Destroy()
		end)

		test("Disconnect stops further delivery", function()
			local signal = Signal.new()
			local count = 0
			local connection = signal:Connect(function()
				count += 1
			end)

			signal:Fire()
			connection:Disconnect()
			signal:Fire()

			expect(count).is(1)
			expect(connection.Connected).never_is_true()

			signal:Destroy()
		end)

		test("disconnect and Destroy aliases behave like Disconnect", function()
			local signal = Signal.new()
			local count = 0
			local c1 = signal:Connect(function()
				count += 1
			end)
			local c2 = signal:Connect(function()
				count += 1
			end)

			c1:disconnect()
			c2:Destroy()
			signal:Fire()

			expect(count).is(0)

			signal:Destroy()
		end)
	end)

	describe("Once", function()
		test("fires exactly once and disconnects itself", function()
			local signal = Signal.new()
			local count = 0

			signal:Once(function()
				count += 1
			end)

			signal:Fire()
			signal:Fire()

			expect(count).is(1)
			expect(signal:IsConnectedTo()).never_is_true()

			signal:Destroy()
		end)

		test("ConnectOnce behaves like Once", function()
			local signal = Signal.new()
			local count = 0

			signal:ConnectOnce(function()
				count += 1
			end)

			signal:Fire()
			signal:Fire()

			expect(count).is(1)

			signal:Destroy()
		end)
	end)

	describe("GetConnections / IsConnectedTo", function()
		test("reflect the currently active connections", function()
			local signal = Signal.new()

			expect(signal:IsConnectedTo()).never_is_true()

			local c1 = signal:Connect(function() end)
			local c2 = signal:Connect(function() end)

			expect(signal:IsConnectedTo()).is_true()
			expect(#signal:GetConnections()).is(2)

			c1:Disconnect()
			expect(#signal:GetConnections()).is(1)

			c2:Disconnect()
			expect(signal:IsConnectedTo()).never_is_true()

			signal:Destroy()
		end)
	end)

	describe("Deferred firing", function()
		test("FireDeferred does not run synchronously", function()
			local signal = Signal.new()
			local ran = false
			signal:Connect(function()
				ran = true
			end)

			signal:FireDeferred()
			expect(ran).never_is_true()

			task.wait()
			expect(ran).is_true()

			signal:Destroy()
		end)

		test("FireDeferredUnsafe does not run synchronously", function()
			local signal = Signal.new()
			local ran = false
			signal:Connect(function()
				ran = true
			end)

			signal:FireDeferredUnsafe()
			expect(ran).never_is_true()

			task.wait()
			expect(ran).is_true()

			signal:Destroy()
		end)

		test("FireBindable/FireBindableUnsafe eventually deliver, matching this environment's defer behavior", function()
			local signal = Signal.new()
			local bindableRan, bindableUnsafeRan = false, false

			signal:Connect(function()
				bindableRan = true
			end)
			signal:FireBindable()

			signal:Connect(function()
				bindableUnsafeRan = true
			end)
			signal:FireBindableUnsafe()

			task.wait()
			expect(bindableRan).is_true()
			expect(bindableUnsafeRan).is_true()

			signal:Destroy()
		end)
	end)

	describe("Wait", function()
		test("yields until Fire and returns the fired arguments", function()
			local signal = Signal.new()
			local received: { any }? = nil

			task.spawn(function()
				local a, b = signal:Wait()
				received = { a, b }
			end)

			signal:Fire("hello", 42)
			task.wait()

			expect(received).exists()
			local capturedValues = received :: { any }
			expect(capturedValues[1]).is("hello")
			expect(capturedValues[2]).is(42)

			signal:Destroy()
		end)
	end)

	describe("DisconnectAll", function()
		test("clears every connection", function()
			local signal = Signal.new()
			local count = 0
			local c1 = signal:Connect(function()
				count += 1
			end)
			local c2 = signal:Connect(function()
				count += 1
			end)

			signal:DisconnectAll()

			expect(c1.Connected).never_is_true()
			expect(c2.Connected).never_is_true()

			signal:Fire()
			expect(count).is(0)

			signal:Destroy()
		end)

		test("cancels threads parked in Wait", function()
			local signal = Signal.new()
			local thread = task.spawn(function()
				signal:Wait()
			end)

			expect(coroutine.status(thread)).is("suspended")

			signal:DisconnectAll()
			task.wait()

			expect(coroutine.status(thread)).is("dead")

			signal:Destroy()
		end)
	end)

	describe("Destroy", function()
		test("disconnects everything and clears state", function()
			local signal = Signal.new()
			local count = 0
			signal:Connect(function()
				count += 1
			end)

			signal:Destroy()
			signal:Fire()

			expect(count).is(0)
		end)

		-- Documents existing behavior rather than asserting an intended contract: `Destroy`
		-- table.clears the instance and strips its metatable, so a second call has no
		-- `Destroy` method left to find. Surfaced here so a future change to this behavior
		-- is a deliberate decision, not an accidental regression.
		test("calling Destroy a second time errors", function()
			local signal = Signal.new()
			signal:Destroy()

			expect(function()
				signal:Destroy()
			end).fails()
		end)
	end)

	describe("Classic aliases", function()
		test("ConnectClassic behaves like Connect", function()
			local signal = Signal.new()
			local count = 0
			local connection = signal:ConnectClassic(function()
				count += 1
			end)

			signal:Fire()
			expect(count).is(1)

			connection:Disconnect()
			signal:Fire()
			expect(count).is(1)

			signal:Destroy()
		end)

		test("OnceClassic behaves like Once", function()
			local signal = Signal.new()
			local count = 0
			signal:OnceClassic(function()
				count += 1
			end)

			signal:Fire()
			signal:Fire()

			expect(count).is(1)

			signal:Destroy()
		end)

		test("ConnectOnceClassic behaves like ConnectOnce", function()
			local signal = Signal.new()
			local count = 0
			signal:ConnectOnceClassic(function()
				count += 1
			end)

			signal:Fire()
			signal:Fire()

			expect(count).is(1)

			signal:Destroy()
		end)
	end)

	describe("Wrap", function()
		local function makeStubRbxSignal()
			local handlers: { (...any) -> () } = {}
			local stub = {}

			function stub.Connect(_self: unknown, callback: (...any) -> ())
				table.insert(handlers, callback)
				local connection = { Connected = true }
				function connection.Disconnect(self: typeof(connection))
					self.Connected = false
				end
				return connection
			end

			function stub.FireAll(_self: unknown, ...: any)
				for _, callback in handlers do
					callback(...)
				end
			end

			return stub
		end

		test("proxies Fire calls from the wrapped signal", function()
			local stub = makeStubRbxSignal()
			local signal = Signal.Wrap(stub :: any)
			local received: unknown = nil

			signal:Connect(function(value)
				received = value
			end)

			stub:FireAll("relayed")

			expect(received).is("relayed")

			signal:Destroy()
		end)
	end)
end

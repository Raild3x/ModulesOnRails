--!strict
--[[
	Unit tests for the Connection class in isolation, independent of Signal's
	Connect/Fire wiring (Connection.new is constructed directly with a stub signal).
]]

return function(t: tiniest)
	local Connection = require("../Connection")

	local describe = t.describe
	local test = t.test
	local expect = t.expect

	-- A minimal `SignalPrivate`-shaped stub: only the fields `Connection.Disconnect`
	-- actually reads (`HandlerListHead`) are needed to exercise the linked-list unhook.
	local function makeStubSignal()
		return { HandlerListHead = nil } :: any
	end

	describe("new", function()
		test("creates a connected node", function()
			local signal = makeStubSignal()
			local connection = Connection.new(signal, function() end)

			expect(connection.Connected).is_true()

			connection:Disconnect()
		end)
	end)

	describe("Disconnect", function()
		test("marks the connection as disconnected", function()
			local signal = makeStubSignal()
			local connection = Connection.new(signal, function() end)
			signal.HandlerListHead = connection

			connection:Disconnect()

			expect(connection.Connected).never_is_true()
		end)

		test("is safe to call more than once", function()
			local signal = makeStubSignal()
			local connection = Connection.new(signal, function() end)
			signal.HandlerListHead = connection

			connection:Disconnect()

			expect(function()
				connection:Disconnect()
			end).never_fails()
		end)

		test("unhooks itself from the middle of the linked list", function()
			local signal = makeStubSignal()
			local c1 = Connection.new(signal, function() end)
			local c2 = Connection.new(signal, function() end)
			local c3 = Connection.new(signal, function() end)
			local c1Internal = c1 :: any
			local c2Internal = c2 :: any

			-- Build the list head-to-tail: c1 -> c2 -> c3 (matches how Signal:Connect
			-- links newly-connected nodes onto the front of the list).
			c1Internal.Next = c2
			c2Internal.Next = c3
			signal.HandlerListHead = c1

			c2:Disconnect()

			expect(c1Internal.Next).is(c3)
		end)

		test("clears HandlerListHead when disconnecting the head node", function()
			local signal = makeStubSignal()
			local connection = Connection.new(signal, function() end)
			signal.HandlerListHead = connection

			connection:Disconnect()

			expect(signal.HandlerListHead).never_exists()
		end)
	end)

	describe("aliases", function()
		test("disconnect and Destroy behave like Disconnect", function()
			local signal = makeStubSignal()
			local c1 = Connection.new(signal, function() end)
			local c2 = Connection.new(signal, function() end)
			signal.HandlerListHead = c1

			c1:disconnect()
			c2:Destroy()

			expect(c1.Connected).never_is_true()
			expect(c2.Connected).never_is_true()
		end)
	end)

	describe("__tostring", function()
		test("returns 'Connection'", function()
			local signal = makeStubSignal()
			local connection = Connection.new(signal, function() end)

			expect(tostring(connection)).is("Connection")

			connection:Disconnect()
		end)
	end)
end

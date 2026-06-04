--!strict
--[=[
	@class ListenerRegistry_new.spec
	
	Unit tests for ListenerRegistry_new to verify:
	- Listener registration and disconnection
	- FireListenersExact (exact path matching)
	- ListenDepth / ListenDepthStyle filtering
	- Once auto-disconnect
	- Multiple listeners on same path
	- Event data structure handling
]=]

return function(t: tiniest)
	local ListenerRegistry = require("../ListenerRegistry")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("Listener Registration", function()
		test("should register a listener and return a connection", function()
			local registry = ListenerRegistry.new(false)

			local connection = registry:RegisterListener("ValueChanged", { "player", "health" }, function() end)

			expect(connection).exists()
			expect(connection.Connected).is_true()

			registry:Destroy()
		end)

		test("should allow disconnecting a listener", function()
			local registry = ListenerRegistry.new(false)

			local connection = registry:RegisterListener("ValueChanged", { "player", "health" }, function() end)
			connection:Disconnect()

			expect(connection.Connected).never_is_true()

			registry:Destroy()
		end)

		test("should not fire disconnected listeners", function()
			local registry = ListenerRegistry.new(false)

			local fireCount = 0
			local connection = registry:RegisterListener("ValueChanged", { "player", "health" }, function()
				fireCount += 1
			end)

			connection:Disconnect()

			registry:FireListenersExact("ValueChanged", { "player", "health" }, {
				NewValue = 50,
				OldValue = 100,
				Metadata = {
					Diff = { type = "changed" },
					OriginPath = { "player", "health" },
					OriginDiff = { type = "changed" },
				},
			})

			expect(fireCount).is(0)

			registry:Destroy()
		end)
	end)

	describe("FireListenersExact", function()
		test("should fire listener at exact matching path", function()
			local registry = ListenerRegistry.new(false)

			local fired = false
			registry:RegisterListener("ValueChanged", { "player", "health" }, function()
				fired = true
			end)

			registry:FireListenersExact("ValueChanged", { "player", "health" }, {
				NewValue = 50,
				OldValue = 100,
				Metadata = {
					Diff = { type = "changed" },
					OriginPath = { "player", "health" },
					OriginDiff = { type = "changed" },
				},
			})

			expect(fired).is_true()

			registry:Destroy()
		end)

		test("should NOT fire listener at parent path", function()
			local registry = ListenerRegistry.new(false)

			local fired = false
			registry:RegisterListener("ValueChanged", { "player" }, function()
				fired = true
			end)

			-- Fire at child path - should NOT fire parent listener
			registry:FireListenersExact("ValueChanged", { "player", "health" }, {
				NewValue = 50,
				OldValue = 100,
				Metadata = {
					Diff = { type = "changed" },
					OriginPath = { "player", "health" },
					OriginDiff = { type = "changed" },
				},
			})

			expect(fired).never_is_true()

			registry:Destroy()
		end)

		test("should NOT fire listener at child path", function()
			local registry = ListenerRegistry.new(false)

			local fired = false
			registry:RegisterListener("ValueChanged", { "player", "health" }, function()
				fired = true
			end)

			-- Fire at parent path - should NOT fire child listener
			registry:FireListenersExact("ValueChanged", { "player" }, {
				NewValue = { health = 50 },
				OldValue = { health = 100 },
				Metadata = {
					Diff = nil,
					OriginPath = { "player", "health" },
					OriginDiff = { type = "changed" },
				},
			})

			expect(fired).never_is_true()

			registry:Destroy()
		end)

		test("should fire multiple listeners on same path", function()
			local registry = ListenerRegistry.new(false)

			local count1 = 0
			local count2 = 0

			registry:RegisterListener("ValueChanged", { "player", "health" }, function()
				count1 += 1
			end)

			registry:RegisterListener("ValueChanged", { "player", "health" }, function()
				count2 += 1
			end)

			registry:FireListenersExact("ValueChanged", { "player", "health" }, {
				NewValue = 50,
				OldValue = 100,
				Metadata = {
					Diff = { type = "changed" },
					OriginPath = { "player", "health" },
					OriginDiff = { type = "changed" },
				},
			})

			expect(count1).is(1)
			expect(count2).is(1)

			registry:Destroy()
		end)
	end)

	describe("ListenDepth Filtering", function()
		test("nil depth (default) fires for ancestor notifications at any depth", function()
			local registry = ListenerRegistry.new(false)

			local fired = false
			registry:RegisterListener("ValueChanged", { "player" }, function()
				fired = true
			end) -- depth=nil by default

			-- Ancestor notification: change originated at ["player", "health"] (depth 1 from listener)
			registry:FireListenersExact("ValueChanged", { "player" }, {
				NewValue = nil,
				OldValue = nil,
				Metadata = {
					Diff = nil,
					OriginPath = { "player", "health" },
					OriginDiff = { type = "changed" },
				},
			})

			expect(fired).is_true()

			registry:Destroy()
		end)

		test("depth=0 does NOT fire for ancestor notifications", function()
			local registry = ListenerRegistry.new(false)

			local fired = false
			registry:RegisterListener("ValueChanged", { "player" }, function()
				fired = true
			end, { ListenDepth = 0 })

			-- Ancestor notification: change at ["player", "health"] is depth 1 from listener
			registry:FireListenersExact("ValueChanged", { "player" }, {
				NewValue = nil,
				OldValue = nil,
				Metadata = {
					Diff = nil,
					OriginPath = { "player", "health" },
					OriginDiff = { type = "changed" },
				},
			})

			expect(fired).never_is_true()

			registry:Destroy()
		end)

		test("depth=0 DOES fire for direct changes (relativeDepth=0)", function()
			local registry = ListenerRegistry.new(false)

			local fired = false
			registry:RegisterListener("ValueChanged", { "player" }, function()
				fired = true
			end, { ListenDepth = 0 })

			-- Direct change at the listener's exact path (Diff present)
			registry:FireListenersExact("ValueChanged", { "player" }, {
				NewValue = { health = 50 },
				OldValue = { health = 100 },
				Metadata = {
					Diff = { type = "changed" },
					OriginPath = { "player" },
					OriginDiff = { type = "changed" },
				},
			})

			expect(fired).is_true()

			registry:Destroy()
		end)

		test("depth=1 style='<=' fires for depth-1 ancestor, not depth-2", function()
			local registry = ListenerRegistry.new(false)

			local fired = false
			registry:RegisterListener("ValueChanged", { "player" }, function()
				fired = true
			end, { ListenDepth = 1, ListenDepthStyle = "<=" })

			-- Depth 1 ancestor: origin at ["player", "health"]
			registry:FireListenersExact("ValueChanged", { "player" }, {
				NewValue = nil,
				OldValue = nil,
				Metadata = {
					Diff = nil,
					OriginPath = { "player", "health" },
					OriginDiff = { type = "changed" },
				},
			})

			expect(fired).is_true()

			fired = false

			-- Depth 2 ancestor: origin at ["player", "stats", "hp"] should NOT fire
			registry:FireListenersExact("ValueChanged", { "player" }, {
				NewValue = nil,
				OldValue = nil,
				Metadata = {
					Diff = nil,
					OriginPath = { "player", "stats", "hp" },
					OriginDiff = { type = "changed" },
				},
			})

			expect(fired).never_is_true()

			registry:Destroy()
		end)

		test("depth=1 style='==' fires at exactly depth 1, not depth 0", function()
			local registry = ListenerRegistry.new(false)

			local fired = false
			registry:RegisterListener("ValueChanged", { "player" }, function()
				fired = true
			end, { ListenDepth = 1, ListenDepthStyle = "==" })

			-- Direct change at listener path (depth 0) should NOT fire
			registry:FireListenersExact("ValueChanged", { "player" }, {
				NewValue = { health = 50 },
				OldValue = { health = 100 },
				Metadata = {
					Diff = { type = "changed" },
					OriginPath = { "player" },
					OriginDiff = { type = "changed" },
				},
			})

			expect(fired).never_is_true()

			-- Depth 1 ancestor (origin at ["player", "health"]) SHOULD fire
			registry:FireListenersExact("ValueChanged", { "player" }, {
				NewValue = nil,
				OldValue = nil,
				Metadata = {
					Diff = nil,
					OriginPath = { "player", "health" },
					OriginDiff = { type = "changed" },
				},
			})

			expect(fired).is_true()

			registry:Destroy()
		end)
	end)

	describe("Once Option", function()
		test("fires exactly once then auto-disconnects", function()
			local registry = ListenerRegistry.new(false)

			local fireCount = 0
			local conn = registry:RegisterListener("ValueChanged", { "player", "health" }, function()
				fireCount += 1
			end, { Once = true })

			local eventData = {
				NewValue = 50,
				OldValue = 100,
				Metadata = {
					Diff = { type = "changed" },
					OriginPath = { "player", "health" },
					OriginDiff = { type = "changed" },
				},
			}

			registry:FireListenersExact("ValueChanged", { "player", "health" }, eventData)
			registry:FireListenersExact("ValueChanged", { "player", "health" }, eventData)

			expect(fireCount).is(1)
			expect(conn.Connected).never_is_true()

			registry:Destroy()
		end)

		test("Connected is false immediately after the first fire", function()
			local registry = ListenerRegistry.new(false)

			local connAfterFire: any = nil
			local conn: any
			conn = registry:RegisterListener("ValueChanged", { "player", "health" }, function()
				connAfterFire = conn
			end, { Once = true })

			registry:FireListenersExact("ValueChanged", { "player", "health" }, {
				NewValue = 50,
				OldValue = 100,
				Metadata = {
					Diff = { type = "changed" },
					OriginPath = { "player", "health" },
					OriginDiff = { type = "changed" },
				},
			})

			-- conn.Connected was already false when the callback ran
			expect(connAfterFire).exists()
			expect(connAfterFire.Connected).never_is_true()

			registry:Destroy()
		end)

		test("re-entrant fire does not double-fire a Once listener", function()
			local registry = ListenerRegistry.new(false)

			local fireCount = 0
			local eventData = {
				NewValue = 50,
				OldValue = 100,
				Metadata = {
					Diff = { type = "changed" },
					OriginPath = { "player", "health" },
					OriginDiff = { type = "changed" },
				},
			}

			registry:RegisterListener("ValueChanged", { "player", "health" }, function()
				fireCount += 1
				-- Re-entrant: fire the same path again inside the callback
				registry:FireListenersExact("ValueChanged", { "player", "health" }, eventData)
			end, { Once = true })

			registry:FireListenersExact("ValueChanged", { "player", "health" }, eventData)

			expect(fireCount).is(1)

			registry:Destroy()
		end)
	end)

	describe("Event Data Handling", function()
		test("should pass correct arguments for ValueChanged", function()
			local registry = ListenerRegistry.new(false)

			local capturedNew = nil
			local capturedOld = nil
			local capturedMetadata = nil

			registry:RegisterListener("ValueChanged", { "player", "health" }, function(newValue, oldValue, metadata)
				capturedNew = newValue
				capturedOld = oldValue
				capturedMetadata = metadata
			end)

			local testMetadata = {
				Diff = { type = "changed" },
				OriginPath = { "player", "health" },
				OriginDiff = { type = "changed" },
			}

			registry:FireListenersExact("ValueChanged", { "player", "health" }, {
				NewValue = 50,
				OldValue = 100,
				Metadata = testMetadata,
			})

			expect(capturedNew).is(50)
			expect(capturedOld).is(100)
			expect(capturedMetadata).is(testMetadata)

			registry:Destroy()
		end)

		test("should pass correct arguments for KeyAdded", function()
			local registry = ListenerRegistry.new(false)

			local capturedValue = nil
			local capturedMetadata = nil

			registry:RegisterListener("KeyAdded", { "player" }, function(value, metadata)
				capturedValue = value
				capturedMetadata = metadata
			end)

			local testMetadata = {
				Diff = { type = "added" },
				OriginPath = { "player", "mana" },
				OriginDiff = { type = "added" },
			}

			registry:FireListenersExact("KeyAdded", { "player" }, {
				NewValue = 50,
				Key = "mana",
				Metadata = testMetadata,
			})

			expect(capturedValue).is(50)
			expect(capturedMetadata).is(testMetadata)

			registry:Destroy()
		end)

		test("should pass correct arguments for ArrayInserted", function()
			local registry = ListenerRegistry.new(false)

			local capturedIndex = nil
			local capturedValue = nil
			local capturedMetadata = nil

			registry:RegisterListener("ArrayInserted", { "items", 3 }, function(index, value, metadata)
				capturedIndex = index
				capturedValue = value
				capturedMetadata = metadata
			end)

			local testMetadata = {
				Diff = { type = "added" },
				OriginPath = { "items", 3 },
				OriginDiff = { type = "added" },
			}

			registry:FireListenersExact("ArrayInserted", { "items", 3 }, {
				Index = 3,
				NewValue = "Sword",
				Metadata = testMetadata,
			})

			expect(capturedIndex).is(3)
			expect(capturedValue).is("Sword")
			expect(capturedMetadata).is(testMetadata)

			registry:Destroy()
		end)
	end)

	describe("Edge Cases", function()
		test("should handle root path (empty array)", function()
			local registry = ListenerRegistry.new(false)

			local fired = false
			registry:RegisterListener("ValueChanged", {}, function()
				fired = true
			end)

			registry:FireListenersExact("ValueChanged", {}, {
				NewValue = { player = { health = 50 } },
				OldValue = { player = { health = 100 } },
				Metadata = {
					Diff = nil,
					OriginPath = { "player", "health" },
					OriginDiff = { type = "changed" },
				},
			})

			expect(fired).is_true()

			registry:Destroy()
		end)

		test("should handle multiple disconnections safely", function()
			local registry = ListenerRegistry.new(false)

			local connection = registry:RegisterListener("ValueChanged", { "player" }, function() end)

			connection:Disconnect()
			connection:Disconnect() -- Should not error

			expect(connection.Connected).never_is_true()

			registry:Destroy()
		end)

		test("should clean up all listeners on Destroy", function()
			local registry = ListenerRegistry.new(false)

			local conn1 = registry:RegisterListener("ValueChanged", { "player" }, function() end)
			local conn2 = registry:RegisterListener("KeyAdded", { "player" }, function() end)

			registry:Destroy()

			expect(conn1.Connected).never_is_true()
			expect(conn2.Connected).never_is_true()
		end)
	end)
end

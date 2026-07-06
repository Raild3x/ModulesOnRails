--!strict
--[[
	Unit tests for ListenerRegistry_new to verify:
	- Listener registration and disconnection
	- FireListenersExact (exact path matching)
	- ListenDepth / ListenDepthStyle filtering
	- Once auto-disconnect
	- Multiple listeners on same path
	- Event data structure handling
]]

return function(t: tiniest)
	local ListenerRegistry = require("../Listening/ListenerRegistry")
	local IsDeferred = require("../Listening/IsDeferred")
	assert(IsDeferred() == false, "Tests assume deferred event dispatch is disabled")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	local function fireAndFlush(registry: any, eventType, path, eventData)
		registry:FireListenersExact(eventType, path, eventData)
		task.wait()
	end

	describe("Listener Registration", function()
		test("should register a listener and return a connection", function()
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			local connection = registry:RegisterListener("ValueChanged", { "player", "health" }, function() end)

			expect(connection).exists()
			expect(connection.Connected).is_true()

			registry:Destroy()
		end)

		test("should allow disconnecting a listener", function()
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			local connection = registry:RegisterListener("ValueChanged", { "player", "health" }, function() end)
			connection:Disconnect()

			expect(connection.Connected).never_is_true()

			registry:Destroy()
		end)

		test("should not fire disconnected listeners", function()
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			local fireCount = 0
			local connection = registry:RegisterListener("ValueChanged", { "player", "health" }, function()
				fireCount += 1
			end)

			connection:Disconnect()

			fireAndFlush(registry, "ValueChanged", { "player", "health" }, {
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
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			local fired = false
			registry:RegisterListener("ValueChanged", { "player", "health" }, function()
				fired = true
			end)

			fireAndFlush(registry, "ValueChanged", { "player", "health" }, {
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
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			local fired = false
			registry:RegisterListener("ValueChanged", { "player" }, function()
				fired = true
			end)

			-- Fire at child path - should NOT fire parent listener
			fireAndFlush(registry, "ValueChanged", { "player", "health" }, {
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
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			local fired = false
			registry:RegisterListener("ValueChanged", { "player", "health" }, function()
				fired = true
			end)

			-- Fire at parent path - should NOT fire child listener
			fireAndFlush(registry, "ValueChanged", { "player" }, {
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
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			local count1 = 0
			local count2 = 0

			registry:RegisterListener("ValueChanged", { "player", "health" }, function()
				count1 += 1
			end)

			registry:RegisterListener("ValueChanged", { "player", "health" }, function()
				count2 += 1
			end)

			fireAndFlush(registry, "ValueChanged", { "player", "health" }, {
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
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			local fired = false
			registry:RegisterListener("ValueChanged", { "player" }, function()
				fired = true
			end) -- depth=nil by default

			-- Ancestor notification: change originated at ["player", "health"] (depth 1 from listener)
			fireAndFlush(registry, "ValueChanged", { "player" }, {
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
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			local fired = false
			registry:RegisterListener("ValueChanged", { "player" }, function()
				fired = true
			end, { ListenDepth = 0 })

			-- Ancestor notification: change at ["player", "health"] is depth 1 from listener
			fireAndFlush(registry, "ValueChanged", { "player" }, {
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
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			local fired = false
			registry:RegisterListener("ValueChanged", { "player" }, function()
				fired = true
			end, { ListenDepth = 0 })

			-- Direct change at the listener's exact path (Diff present)
			fireAndFlush(registry, "ValueChanged", { "player" }, {
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
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			local fired = false
			registry:RegisterListener("ValueChanged", { "player" }, function()
				fired = true
			end, { ListenDepth = 1, ListenDepthStyle = "<=" })

			-- Depth 1 ancestor: origin at ["player", "health"]
			fireAndFlush(registry, "ValueChanged", { "player" }, {
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
			fireAndFlush(registry, "ValueChanged", { "player" }, {
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
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			local fired = false
			registry:RegisterListener("ValueChanged", { "player" }, function()
				fired = true
			end, { ListenDepth = 1, ListenDepthStyle = "==" })

			-- Direct change at listener path (depth 0) should NOT fire
			fireAndFlush(registry, "ValueChanged", { "player" }, {
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
			fireAndFlush(registry, "ValueChanged", { "player" }, {
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
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

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

			fireAndFlush(registry, "ValueChanged", { "player", "health" }, eventData)
			fireAndFlush(registry, "ValueChanged", { "player", "health" }, eventData)

			expect(fireCount).is(1)
			expect(conn.Connected).never_is_true()

			registry:Destroy()
		end)

		test("Connected is false immediately after the first fire", function()
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			local connAfterFire: any = nil
			local conn: any
			conn = registry:RegisterListener("ValueChanged", { "player", "health" }, function()
				connAfterFire = conn
			end, { Once = true })

			fireAndFlush(registry, "ValueChanged", { "player", "health" }, {
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
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			local fireCount = 0
			local eventData: any = {
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

			fireAndFlush(registry, "ValueChanged", { "player", "health" }, eventData)

			expect(fireCount).is(1)

			registry:Destroy()
		end)

		test("the Once cleanup sweep keeps a co-located regular listener and its bucket", function()
			-- The sweep after a Once fire must skip non-Once entries (the
			-- `listeners[i].Once` operand goes false) and keep the bucket alive
			-- because a survivor remains (`next(listeners) == nil` goes false).
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			local regularFires = 0
			local onceFires = 0
			local regConn =
				registry:RegisterListener("ValueChanged", { "player", "health" }, function()
					regularFires += 1
				end)
			registry:RegisterListener("ValueChanged", { "player", "health" }, function()
				onceFires += 1
			end, { Once = true })

			local eventData: any = {
				NewValue = 50,
				OldValue = 100,
				Metadata = {
					Diff = { type = "changed" },
					OriginPath = { "player", "health" },
					OriginDiff = { type = "changed" },
				},
			}

			fireAndFlush(registry, "ValueChanged", { "player", "health" }, eventData)
			fireAndFlush(registry, "ValueChanged", { "player", "health" }, eventData)

			expect(onceFires).is(1) -- Once removed after the first fire
			expect(regularFires).is(2) -- survivor kept firing (bucket not deleted)
			expect(regConn.Connected).is_true()

			registry:Destroy()
		end)

		test("the Once cleanup sweep decrements SnapshotOldValues and ProvideDiff counts", function()
			-- A Once listener that also opted into ProvideDiff + SnapshotOldValues must,
			-- when swept, decrement both aggregate counts (the `listeners[i].SnapshotOldValues`
			-- and `listeners[i].ProvideDiff` operands go true), restoring the node to
			-- "no opted-in coverage".
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			-- A surviving regular listener keeps the bucket alive so the sweep runs
			-- its per-entry decrements rather than wholesale-clearing the node.
			registry:RegisterListener("ValueChanged", { "player", "health" }, function() end)
			registry:RegisterListener("ValueChanged", { "player", "health" }, function() end, {
				Once = true,
				ProvideDiff = true,
				SnapshotOldValues = true,
			})

			-- Before the fire, both opt-ins are active at this node.
			expect(registry:SnapshotRootFor { "player", "health" }).exists()
			expect(registry:WantsFullDiff { "player", "health" }).is_true()

			fireAndFlush(registry, "ValueChanged", { "player", "health" }, {
				NewValue = 50,
				OldValue = 100,
				OldValueSnapshot = 100,
				Metadata = {
					Diff = { type = "changed" },
					OriginPath = { "player", "health" },
					OriginDiff = { type = "changed" },
				},
			})

			-- After the Once listener auto-disconnects and is swept, the counts are
			-- back to zero (the surviving regular listener opted into neither).
			expect(registry:SnapshotRootFor { "player", "health" }).never_exists()
			expect(registry:WantsFullDiff { "player", "health" }).never_is_true()

			registry:Destroy()
		end)
	end)

	describe("Event Data Handling", function()
		test("should pass correct arguments for ValueChanged", function()
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

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

			fireAndFlush(registry, "ValueChanged", { "player", "health" }, {
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
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			local capturedValue = nil
			local capturedMetadata = nil

			registry:RegisterListener("KeyAdded", { "player" }, function(key, value, metadata)
				capturedValue = value
				capturedMetadata = metadata
			end)

			local testMetadata = {
				Diff = { type = "added" },
				OriginPath = { "player", "mana" },
				OriginDiff = { type = "added" },
			}

			fireAndFlush(registry, "KeyAdded", { "player" }, {
				NewValue = 50,
				Key = "mana",
				Metadata = testMetadata,
			})

			expect(capturedValue).is(50)
			expect(capturedMetadata).is(testMetadata)

			registry:Destroy()
		end)

		test("should pass correct arguments for ArrayInserted", function()
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

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

			fireAndFlush(registry, "ArrayInserted", { "items", 3 }, {
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
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			local fired = false
			registry:RegisterListener("ValueChanged", {}, function()
				fired = true
			end)

			fireAndFlush(registry, "ValueChanged", {}, {
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
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			local connection = registry:RegisterListener("ValueChanged", { "player" }, function() end)

			connection:Disconnect()
			connection:Disconnect() -- Should not error

			expect(connection.Connected).never_is_true()

			registry:Destroy()
		end)

		test("should clean up all listeners on Destroy", function()
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			local conn1 = registry:RegisterListener("ValueChanged", { "player" }, function() end)
			local conn2 = registry:RegisterListener("KeyAdded", { "player" }, function() end)

			registry:Destroy()

			expect(conn1.Connected).never_is_true()
			expect(conn2.Connected).never_is_true()
		end)
	end)

	describe("Wildcard Listeners", function()
		test("should fire a wildcard listener for a matching literal segment", function()
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			local matches: { any }? = nil
			registry:RegisterListener("ValueChanged", { "Players", "*", "Health" }, function(_, _, metadata)
				matches = metadata.WildcardMatches
			end)

			fireAndFlush(registry, "ValueChanged", { "Players", "p123", "Health" }, {
				NewValue = 90,
				OldValue = 100,
				Metadata = {
					Diff = { type = "changed" },
					OriginPath = { "Players", "p123", "Health" },
					OriginDiff = { type = "changed" },
				},
			})

			expect(matches).exists()
			expect((matches :: { any })[1]).is("p123")

			registry:Destroy()
		end)

		test("should fire both a literal listener and a wildcard listener for the same change", function()
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			local literalFired, wildcardFired = false, false
			registry:RegisterListener("ValueChanged", { "Players", "p123", "Health" }, function()
				literalFired = true
			end)
			registry:RegisterListener("ValueChanged", { "Players", "*", "Health" }, function()
				wildcardFired = true
			end)

			fireAndFlush(registry, "ValueChanged", { "Players", "p123", "Health" }, {
				NewValue = 90,
				OldValue = 100,
				Metadata = {
					Diff = { type = "changed" },
					OriginPath = { "Players", "p123", "Health" },
					OriginDiff = { type = "changed" },
				},
			})

			expect(literalFired).is_true()
			expect(wildcardFired).is_true()

			registry:Destroy()
		end)

		test("should not fire a wildcard listener for a non-matching path", function()
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			local fired = false
			registry:RegisterListener("ValueChanged", { "Players", "*", "Health" }, function()
				fired = true
			end)

			fireAndFlush(registry, "ValueChanged", { "Players", "p123", "Mana" }, {
				NewValue = 10,
				OldValue = 20,
				Metadata = {
					Diff = { type = "changed" },
					OriginPath = { "Players", "p123", "Mana" },
					OriginDiff = { type = "changed" },
				},
			})

			expect(fired).never_is_true()

			registry:Destroy()
		end)

		test("should accumulate matches left-to-right for multiple wildcard segments", function()
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			local matches: { any }? = nil
			registry:RegisterListener("ValueChanged", { "Players", "*", "Inventory", "*" }, function(_, _, metadata)
				matches = metadata.WildcardMatches
			end)

			fireAndFlush(registry, "ValueChanged", { "Players", "p123", "Inventory", "item7" }, {
				NewValue = "Sword",
				OldValue = nil,
				Metadata = {
					Diff = { type = "changed" },
					OriginPath = { "Players", "p123", "Inventory", "item7" },
					OriginDiff = { type = "changed" },
				},
			})

			expect(matches).exists()
			local m = matches :: { any }
			expect(m[1]).is("p123")
			expect(m[2]).is("item7")

			registry:Destroy()
		end)

		test("should fire a wildcard ancestor listener when a descendant changes", function()
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			local matches: { any }? = nil
			registry:RegisterListener("ValueChanged", { "Players", "*" }, function(_, _, metadata)
				matches = metadata.WildcardMatches
			end)

			-- Ancestor notification: Diff == nil, OriginPath deeper than the listener path
			fireAndFlush(registry, "ValueChanged", { "Players", "p456" }, {
				NewValue = nil,
				OldValue = nil,
				Metadata = {
					Diff = nil,
					OriginPath = { "Players", "p456", "Health" },
					OriginDiff = { type = "changed" },
				},
			})

			expect(matches).exists()
			expect((matches :: { any })[1]).is("p456")

			registry:Destroy()
		end)

		test("Once on a wildcard listener fires once total, not once per matching key", function()
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			local fireCount = 0
			registry:RegisterListener("ValueChanged", { "Players", "*", "Health" }, function()
				fireCount += 1
			end, { Once = true })

			fireAndFlush(registry, "ValueChanged", { "Players", "p123", "Health" }, {
				NewValue = 90,
				OldValue = 100,
				Metadata = {
					Diff = { type = "changed" },
					OriginPath = { "Players", "p123", "Health" },
					OriginDiff = { type = "changed" },
				},
			})

			fireAndFlush(registry, "ValueChanged", { "Players", "p456", "Health" }, {
				NewValue = 70,
				OldValue = 80,
				Metadata = {
					Diff = { type = "changed" },
					OriginPath = { "Players", "p456", "Health" },
					OriginDiff = { type = "changed" },
				},
			})

			expect(fireCount).is(1)

			registry:Destroy()
		end)
	end)

	describe("Dispatch Config", function()
		test("defaults to immediate dispatch when no config is provided", function()
			local registry = ListenerRegistry.new()
			local callOrder = {}

			registry:RegisterListener("ValueChanged", { "player", "health" }, function()
				table.insert(callOrder, "listener")
			end)

			table.insert(callOrder, "before-fire")
			registry:FireListenersExact("ValueChanged", { "player", "health" }, {
				NewValue = 50,
				OldValue = 100,
				Metadata = {
					Diff = { type = "changed" },
					OriginPath = { "player", "health" },
					OriginDiff = { type = "changed" },
				},
			})
			table.insert(callOrder, "after-fire")

			task.wait()

			expect(callOrder[1]).is("before-fire")
			expect(callOrder[2]).is("listener")
			expect(callOrder[3]).is("after-fire")

			registry:Destroy()
		end)

		test("fires deferred when FireMode=Deferred", function()
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "deferred" }
			local callOrder = {}

			registry:RegisterListener("ValueChanged", { "player", "health" }, function()
				table.insert(callOrder, "listener")
			end)

			table.insert(callOrder, "before-fire")
			registry:FireListenersExact("ValueChanged", { "player", "health" }, {
				NewValue = 50,
				OldValue = 100,
				Metadata = {
					Diff = { type = "changed" },
					OriginPath = { "player", "health" },
					OriginDiff = { type = "changed" },
				},
			})
			table.insert(callOrder, "after-fire")

			task.wait()

			expect(callOrder[1]).is("before-fire")
			expect(callOrder[2]).is("after-fire")
			expect(callOrder[3]).is("listener")

			registry:Destroy()
		end)

		test("collapses repeated fires into one call when FireMode=Coalesced", function()
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "coalesced" }
			local fireCount = 0
			local lastNewValue: number? = nil

			registry:RegisterListener("ValueChanged", { "player", "health" }, function(newValue: number)
				fireCount += 1
				lastNewValue = newValue
			end)

			local function fireHealthChange(newValue: number, oldValue: number)
				registry:FireListenersExact("ValueChanged", { "player", "health" }, {
					NewValue = newValue,
					OldValue = oldValue,
					Metadata = {
						Diff = { type = "changed" },
						OriginPath = { "player", "health" },
						OriginDiff = { type = "changed" },
					},
				})
			end

			-- Two fires before yielding should collapse into a single callback
			-- invocation carrying the LATEST data.
			fireHealthChange(75, 100)
			fireHealthChange(50, 75)

			expect(fireCount).is(0) -- nothing has run synchronously

			task.wait()

			expect(fireCount).is(1)
			expect(lastNewValue).is(50)

			registry:Destroy()
		end)

		test("resolves Bindable to either Immediate or Deferred ordering", function()
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "bindable" }
			local callOrder = {}

			registry:RegisterListener("ValueChanged", { "player", "health" }, function()
				table.insert(callOrder, "listener")
			end)

			table.insert(callOrder, "before-fire")
			registry:FireListenersExact("ValueChanged", { "player", "health" }, {
				NewValue = 50,
				OldValue = 100,
				Metadata = {
					Diff = { type = "changed" },
					OriginPath = { "player", "health" },
					OriginDiff = { type = "changed" },
				},
			})
			table.insert(callOrder, "after-fire")

			task.wait()

			-- "Bindable" mirrors the engine's actual SignalBehavior, so either
			-- ordering is valid depending on the environment; what matters is
			-- that the listener ran exactly once.
			expect(#callOrder).is(3)
			expect(table.find(callOrder, "listener") ~= nil).is(true)

			registry:Destroy()
		end)
	end)

	describe("Thread Safety", function()
		test("listeners that yield do not prevent all callbacks from completing", function()
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }
			local completions = {}

			registry:RegisterListener("ValueChanged", { "player", "health" }, function()
				task.wait(0.02)
				table.insert(completions, "slow")
			end)

			registry:RegisterListener("ValueChanged", { "player", "health" }, function()
				table.insert(completions, "fast")
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

			task.wait(0.05)
			expect(#completions).is(2)

			registry:Destroy()
		end)

		test("destroy disconnects consumed once connections", function()
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "deferred" }
			local onceConnection = registry:RegisterListener("ValueChanged", { "player", "health" }, function() end, {
				Once = true,
			})

			registry:FireListenersExact("ValueChanged", { "player", "health" }, {
				NewValue = 50,
				OldValue = 100,
				Metadata = {
					Diff = { type = "changed" },
					OriginPath = { "player", "health" },
					OriginDiff = { type = "changed" },
				},
			})

			registry:Destroy()
			expect(onceConnection.Connected).never_is_true()
		end)
	end)

	describe("SnapshotOldValues / SnapshotRootFor", function()
		test("SnapshotRootFor returns nil when no listener is registered", function()
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			expect(registry:SnapshotRootFor { "player", "health" }).never_exists()

			registry:Destroy()
		end)

		test("SnapshotRootFor returns nil when listeners exist but none opted in", function()
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			registry:RegisterListener("ValueChanged", { "player", "health" }, function() end)

			expect(registry:SnapshotRootFor { "player", "health" }).never_exists()

			registry:Destroy()
		end)

		test(
			"SnapshotRootFor returns the change path (not nil, not deeper) when an opted-in KeyChanged listener sits at the PARENT",
			function()
				local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

				-- A KeyChanged listener registered at {"player"} receives a genuine
				-- (non-synthetic) old value for a change exactly at
				-- {"player", "stats"} -- one level below its own registration path.
				registry:RegisterListener("KeyChanged", { "player" }, function() end, {
					SnapshotOldValues = true,
				})

				local result = registry:SnapshotRootFor { "player", "stats" }
				expect(result).exists()
				local r = result :: { any }
				expect(#r).is(2)
				expect(r[1]).is("player")
				expect(r[2]).is("stats")

				registry:Destroy()
			end
		)

		test("SnapshotRootFor returns the change path when an opted-in listener sits exactly there", function()
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			registry:RegisterListener("ValueChanged", { "player", "health" }, function() end, {
				SnapshotOldValues = true,
			})

			local result = registry:SnapshotRootFor { "player", "health" }
			expect(result).exists()
			expect(#(result :: { any })).is(2)
			expect((result :: { any })[1]).is("player")
			expect((result :: { any })[2]).is("health")

			registry:Destroy()
		end)

		test("SnapshotRootFor descends through a single covering branch to the opted-in listener", function()
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			-- Only one branch under {"player"} carries an opted-in listener, so the
			-- shallowest covering path should descend all the way to it instead of
			-- stopping at {"player"}.
			registry:RegisterListener("ValueChanged", { "player", "stats", "health" }, function() end, {
				SnapshotOldValues = true,
			})

			local result = registry:SnapshotRootFor { "player" }
			expect(result).exists()
			local r = result :: { any }
			expect(#r).is(3)
			expect(r[1]).is("player")
			expect(r[2]).is("stats")
			expect(r[3]).is("health")

			registry:Destroy()
		end)

		test("SnapshotRootFor stops at the lowest common ancestor of two diverging opted-in listeners", function()
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			registry:RegisterListener("ValueChanged", { "player", "stats", "health" }, function() end, {
				SnapshotOldValues = true,
			})
			registry:RegisterListener("ValueChanged", { "player", "stats", "mana" }, function() end, {
				SnapshotOldValues = true,
			})

			local result = registry:SnapshotRootFor { "player" }
			expect(result).exists()
			local r = result :: { any }
			expect(#r).is(2)
			expect(r[1]).is("player")
			expect(r[2]).is("stats")

			registry:Destroy()
		end)

		test(
			"SnapshotRootFor stops at a node that itself has an opted-in listener even with a deeper one below",
			function()
				local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

				registry:RegisterListener("ValueChanged", { "player", "stats" }, function() end, {
					SnapshotOldValues = true,
				})
				registry:RegisterListener("ValueChanged", { "player", "stats", "health" }, function() end, {
					SnapshotOldValues = true,
				})

				local result = registry:SnapshotRootFor { "player" }
				expect(result).exists()
				local r = result :: { any }
				expect(#r).is(2)
				expect(r[1]).is("player")
				expect(r[2]).is("stats")

				registry:Destroy()
			end
		)

		test("SnapshotRootFor becomes nil again after the only opted-in listener disconnects", function()
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			local conn = registry:RegisterListener("ValueChanged", { "player", "health" }, function() end, {
				SnapshotOldValues = true,
			})

			expect(registry:SnapshotRootFor { "player", "health" }).exists()

			conn:Disconnect()

			expect(registry:SnapshotRootFor { "player", "health" }).never_exists()

			registry:Destroy()
		end)

		test("SnapshotRootFor becomes nil after a Once opted-in listener auto-disconnects", function()
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			registry:RegisterListener("ValueChanged", { "player", "health" }, function() end, {
				SnapshotOldValues = true,
				Once = true,
			})

			expect(registry:SnapshotRootFor { "player", "health" }).exists()

			fireAndFlush(registry, "ValueChanged", { "player", "health" }, {
				NewValue = 50,
				OldValue = 100,
				Metadata = {
					Diff = { type = "changed" },
					OriginPath = { "player", "health" },
					OriginDiff = { type = "changed" },
				},
			})

			expect(registry:SnapshotRootFor { "player", "health" }).never_exists()

			registry:Destroy()
		end)

		test(
			"an opted-in listener receives OldValueSnapshot in place of OldValue; a non-opted listener on the same node still gets the raw OldValue",
			function()
				local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

				local rawOld: any = { health = 100 }
				local snapshotOld: any = { health = 100 } -- a distinct table standing in for the frozen copy

				local optedInReceived: any = nil
				local plainReceived: any = nil

				registry:RegisterListener("ValueChanged", { "player" }, function(_, oldValue)
					optedInReceived = oldValue
				end, { SnapshotOldValues = true })

				registry:RegisterListener("ValueChanged", { "player" }, function(_, oldValue)
					plainReceived = oldValue
				end)

				fireAndFlush(registry, "ValueChanged", { "player" }, {
					NewValue = { health = 50 },
					OldValue = rawOld,
					OldValueSnapshot = snapshotOld,
					Metadata = {
						Diff = { type = "changed" },
						OriginPath = { "player" },
						OriginDiff = { type = "changed" },
					},
				})

				expect(optedInReceived).is(snapshotOld)
				expect(plainReceived).is(rawOld)

				registry:Destroy()
			end
		)

		test("an opted-in listener falls back to OldValue when the caller built no snapshot for this change", function()
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			local rawOld: any = { health = 100 }
			local received: any = nil

			registry:RegisterListener("ValueChanged", { "player" }, function(_, oldValue)
				received = oldValue
			end, { SnapshotOldValues = true })

			-- No OldValueSnapshot on the eventData (e.g. SnapshotRootFor returned nil
			-- for this change): the opted-in listener must still receive a usable
			-- old value rather than nil.
			fireAndFlush(registry, "ValueChanged", { "player" }, {
				NewValue = { health = 50 },
				OldValue = rawOld,
				Metadata = {
					Diff = { type = "changed" },
					OriginPath = { "player" },
					OriginDiff = { type = "changed" },
				},
			})

			expect(received).is(rawOld)

			registry:Destroy()
		end)

		test("two opted-in listeners on the same node share ONE lazily-built snapshot clone", function()
			-- The snapshot-substituted eventData clone is built once per node/event
			-- (`snapshotEventData == nil` goes false on the second opted-in listener),
			-- so both listeners receive the very same object.
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			local snapshotOld: any = { health = 100 }
			local firstReceived: any = nil
			local secondReceived: any = nil

			registry:RegisterListener("ValueChanged", { "player" }, function(_, oldValue)
				firstReceived = oldValue
			end, { SnapshotOldValues = true })
			registry:RegisterListener("ValueChanged", { "player" }, function(_, oldValue)
				secondReceived = oldValue
			end, { SnapshotOldValues = true })

			fireAndFlush(registry, "ValueChanged", { "player" }, {
				NewValue = { health = 50 },
				OldValue = { health = 100 },
				OldValueSnapshot = snapshotOld,
				Metadata = {
					Diff = { type = "changed" },
					OriginPath = { "player" },
					OriginDiff = { type = "changed" },
				},
			})

			expect(firstReceived).is(snapshotOld)
			expect(secondReceived).is(snapshotOld)
			expect(firstReceived).is(secondReceived) -- the reused clone, not two copies

			registry:Destroy()
		end)

		test("SnapshotRootFor returns the change path itself once a wildcard opted-in listener exists", function()
			-- Registering a SnapshotOldValues listener at a wildcard path trips the
			-- `_hasSnapshotWildcards` latch (the `segment == WILDCARD` operand goes
			-- true), so SnapshotRootFor conservatively returns the change path.
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			registry:RegisterListener("ValueChanged", { "Players", "*" }, function() end, {
				SnapshotOldValues = true,
			})

			local result = registry:SnapshotRootFor { "Players", "p1" }
			expect(result).exists()
			local r = result :: { any }
			expect(#r).is(2)
			expect(r[1]).is("Players")
			expect(r[2]).is("p1")

			registry:Destroy()
		end)

		test("SnapshotRootFor returns nil for a change on a branch with no opted-in coverage", function()
			-- An opted-in listener exists on one branch, but the queried change is on
			-- an unrelated branch: `getNode(path)` is nil, so SnapshotRootFor bails.
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			registry:RegisterListener("ValueChanged", { "a", "x" }, function() end, {
				SnapshotOldValues = true,
			})

			expect(registry:SnapshotRootFor { "b" }).never_exists()

			registry:Destroy()
		end)

		test("SnapshotRootFor descends past a sibling branch that has only non-opted listeners", function()
			-- Under {"a"}, branch x is opted in and branch y is NOT: the descent must
			-- skip y (its `SnapshotSubtree > 0` operand is false) and follow x alone.
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			registry:RegisterListener("ValueChanged", { "a", "x" }, function() end, {
				SnapshotOldValues = true,
			})
			registry:RegisterListener("ValueChanged", { "a", "y" }, function() end) -- NOT opted in

			local result = registry:SnapshotRootFor { "a" }
			expect(result).exists()
			local r = result :: { any }
			expect(#r).is(2)
			expect(r[1]).is("a")
			expect(r[2]).is("x")

			registry:Destroy()
		end)
	end)

	describe("Coalesced listener lifecycle", function()
		test("a coalesced listener disconnected before its deferred flush never runs", function()
			-- flushCoalescedListener (ListenerRegistry.luau:441) skips a listener that
			-- disconnected between the fire (which scheduled the defer) and the flush.
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "coalesced" }

			local fired = 0
			local conn = registry:RegisterListener("ValueChanged", { "player", "health" }, function()
				fired += 1
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

			-- Disconnect before the deferred flush ticks.
			conn:Disconnect()
			task.wait()

			expect(fired).is(0)

			registry:Destroy()
		end)

		test("Destroy is idempotent", function()
			-- The `self._destroyed` guard makes a second Destroy a no-op.
			local registry = ListenerRegistry.new { DebugMode = false, FireMode = "immediate" }

			registry:RegisterListener("ValueChanged", { "player", "health" }, function() end)

			local ok1 = pcall(function()
				registry:Destroy()
			end)
			local ok2 = pcall(function()
				registry:Destroy()
			end)

			expect(ok1).is_true()
			expect(ok2).is_true()
		end)
	end)
end

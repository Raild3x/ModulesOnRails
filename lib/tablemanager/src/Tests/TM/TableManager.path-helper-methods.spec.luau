--!strict

return function(t: tiniest)
	local TableManager = require("../../TableManager")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("Method: Get", function()
		test("returns nested values by table path", function()
			local manager = TableManager.new {
				game = { world = { region = { zone = 1 } } },
			}

			local zone = manager:Get { "game", "world", "region", "zone" }
			expect(zone).is(1)

			manager:Destroy()
		end)

		test("supports dot-string path input", function()
			local manager = TableManager.new {
				player = { stats = { health = 100 } },
			}

			local health = manager:Get("player.stats.health")
			expect(health).is(100)

			manager:Destroy()
		end)

		test("errors for non-table intermediate segment", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			expect(function()
				manager:Get { "player", "health", "x" }
			end).fails_with("Path segment x is not a table")

			manager:Destroy()
		end)

		test("returns nil when suppressNilPartialPaths is true", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local result = manager:Get({ "player", "health", "x" }, true)
			expect(result).is(nil)

			manager:Destroy()
		end)

		test("allows nil values at the end of the path", function()
			local manager = TableManager.new {
				player = { health = nil },
			}

			local result = manager:Get { "player", "health" }
			expect(result).is(nil)

			manager:Destroy()
		end)
	end)

	describe("Method: GetProxy", function()
		test("returns a proxy for table paths and scalar for value paths", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local playerProxy = manager:GetProxy { "player" }
			local healthValue = manager:GetProxy { "player", "health" }

			expect(playerProxy).exists()
			expect(healthValue).is(100)

			manager:Destroy()
		end)

		test("supports dot-string path input via ParsePath", function()
			local manager = TableManager.new {
				player = { inventory = { slots = 12 } },
			}

			local value = manager:GetProxy("player.inventory.slots")
			expect(value).is(12)

			manager:Destroy()
		end)

		test("errors for non-table intermediate segment", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			expect(function()
				manager:GetProxy { "player", "mana", "x" }
			end).fails_with("Path segment mana is not a table")

			manager:Destroy()
		end)

		test("returns nil when suppressNilPartialPaths is true", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local result = manager:GetProxy({ "player", "mana", "x" }, true)
			expect(result).is(nil)

			manager:Destroy()
		end)

		test("allows nil values at the end of the path", function()
			local manager = TableManager.new {
				player = { health = nil },
			}

			local result = manager:GetProxy { "player", "health" }
			expect(result).is(nil)

			manager:Destroy()
		end)
	end)

	describe("Method: Set", function()
		test("sets nested values by path", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			manager:Set({ "player", "health" }, 75)
			expect(manager.Proxy.player.health).is(75)

			manager:Destroy()
		end)

		test("proxy held before a subtree replacement stays bound to the old table", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local heldPlayer = manager.Proxy.player

			manager:Set({ "player" }, { health = 50 })
			expect(manager.Proxy.player.health).is(50)

			-- heldPlayer is bound to the replaced (now detached) table, not the
			-- "player" path - writing through it must not affect the live tree.
			heldPlayer.health = 999
			expect(manager.Proxy.player.health).is(50)
			expect(manager:Get { "player", "health" }).is(50)

			manager:Destroy()
		end)

		test("supports dot-string path input", function()
			local manager = TableManager.new {
				player = { stats = { health = 100 } },
			}
			manager:Set("player.stats.health", 60)
			expect(manager.Proxy.player.stats.health).is(60)

			manager:Destroy()
		end)

		test("triggers ValueChanged and KeyChanged signals once", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local valueCount = 0
			local keyCount = 0
			local valuePath = nil
			local keyPath = nil
			local keyName = nil

			local vConn = manager.ValueChanged:Connect(function(path)
				valueCount += 1
				valuePath = path
			end)
			local kConn = manager.KeyChanged:Connect(function(path, key)
				keyCount += 1
				keyPath = path
				keyName = key
			end)

			manager:Set({ "player", "health" }, 50)

			expect(valueCount).is(1)
			expect(keyCount).is(1)
			expect(valuePath).is_shallow_equal { "player", "health" }
			expect(keyPath).is_shallow_equal { "player" }
			expect(keyName).is("health")

			vConn:Disconnect()
			kConn:Disconnect()
			manager:Destroy()
		end)

		test("errors when setting the root to a non-table value", function()
			local manager = TableManager.new {
				a = 1,
			}

			expect(function()
				manager:Set({}, 2)
			end).fails_with("root must remain a table")

			manager:Destroy()
		end)

		test("errors for non-table intermediate segments", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			expect(function()
				manager:Set({ "player", "health", "value" }, 10)
			end).fails_with("Path segment health is not a table")

			manager:Destroy()
		end)

		test("nil write through a non-table segment silently succeeds", function()
			-- A nil write is a removal, and a scalar segment means the target
			-- path holds nothing - there is nothing to remove, so this must be
			-- a silent no-op (replication consumers can receive a redundant
			-- child removal after the parent was replaced by a scalar).
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local fired = 0
			manager.ValueChanged:Connect(function()
				fired += 1
			end)

			manager:Set({ "player", "health", "buff" }, nil)

			expect(fired).is(0)
			expect(manager:Get { "player", "health" }).is(100)

			manager:Destroy()
		end)

		test("nil write through a missing segment silently succeeds", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local fired = 0
			manager.ValueChanged:Connect(function()
				fired += 1
			end)

			manager:Set({ "player", "gear", "slot" }, nil)

			expect(fired).is(0)
			expect(manager:Get({ "player", "gear" }, true)).is(nil)

			manager:Destroy()
		end)

		test("errors for a missing intermediate segment without buildTablesDynamically", function()
			local manager = TableManager.new {
				existing = 1,
			}

			expect(function()
				manager:Set({ "a", "b", "c" }, 5)
			end).fails_with("Path segment a is not a table")

			manager:Destroy()
		end)

		test("buildTablesDynamically reports the whole missing subtree, not just the leaf", function()
			-- Regression test: the missing path used to be built with raw,
			-- level-by-level writes that bypassed change detection entirely, so
			-- only the leaf ("c") was ever reported. The fix builds the missing
			-- remainder as ONE subtree through `applyWrite`, so the diff against
			-- the (nil) shadow baseline surfaces every newly created level.
			local manager = TableManager.new {
				existing = 1,
			}

			local keyAddedEvents = {}
			local keyChangedEvents = {}
			local valueChangedEvents = {}
			local kaConn = manager.KeyAdded:Connect(function(path, key, newValue)
				table.insert(keyAddedEvents, { Path = path, Key = key, New = newValue })
			end)
			local kcConn = manager.KeyChanged:Connect(function(path, key, newValue, oldValue)
				table.insert(keyChangedEvents, { Path = path, Key = key, New = newValue, Old = oldValue })
			end)
			local vcConn = manager.ValueChanged:Connect(function(path, newValue, oldValue)
				table.insert(valueChangedEvents, { Path = path, New = newValue, Old = oldValue })
			end)

			-- Separately, the registry-based OnKeyChange/OnValueChange listeners
			-- (unlike the public Signals) ARE told about the new container itself
			-- ("a" going from nil to a table) -- this is the literal "new tables
			-- were added in" notification the bug report asked for.
			local rootKey, rootNew, rootOld
			manager:OnKeyChange({}, function(key, newValue, oldValue)
				rootKey, rootNew, rootOld = key, newValue, oldValue
			end)

			manager:Set({ "a", "b", "c" }, 5, true)

			expect(manager:Get { "a", "b", "c" }).is(5)
			expect(manager.Proxy.a.b.c).is(5)

			-- The deepest-first (post-order) firing order: "c" under "a.b" is
			-- reported before "b" under "a".
			expect(#keyAddedEvents).is(2)
			expect(keyAddedEvents[1].Path).is_shallow_equal { "a", "b" }
			expect(keyAddedEvents[1].Key).is("c")
			expect(keyAddedEvents[1].New).is(5)
			expect(keyAddedEvents[2].Path).is_shallow_equal { "a" }
			expect(keyAddedEvents[2].Key).is("b")
			expect(keyAddedEvents[2].New.c).is(5)

			expect(#valueChangedEvents).is(2)
			expect(valueChangedEvents[1].Path).is_shallow_equal { "a", "b", "c" }
			expect(valueChangedEvents[2].Path).is_shallow_equal { "a", "b" }

			-- The brand-new top container itself ("a") never collapses to a public
			-- KeyChanged/KeyAdded Signal fire (consistent with a normal
			-- `Set(path, newNonEmptyTable)` onto a previously-nil slot elsewhere
			-- in this library) -- its descendants' adds are what drive consumers.
			expect(#keyChangedEvents).is(0)

			assert(rootNew, "rootNew should be set by OnKeyChange")
			expect(rootKey).is("a")
			expect(rootNew.b.c).is(5)
			expect(rootOld).is(nil)

			kaConn:Disconnect()
			kcConn:Disconnect()
			vcConn:Disconnect()
			manager:Destroy()
		end)

		test("buildTablesDynamically only builds the missing remainder when part of the path already exists", function()
			local manager = TableManager.new {
				a = { existing = true },
			}

			local keyAddedEvents = {}
			local conn = manager.KeyAdded:Connect(function(path, key, newValue)
				table.insert(keyAddedEvents, { Path = path, Key = key, New = newValue })
			end)

			manager:Set({ "a", "b", "c" }, 5, true)

			expect(manager:Get { "a", "b", "c" }).is(5)
			-- The pre-existing sibling under "a" is untouched by the rebuild.
			expect(manager:Get { "a", "existing" }).is(true)

			-- Only "c" is a genuine addition; "b" (the new container) reports as
			-- a KeyChanged on its parent "a", which already existed.
			expect(#keyAddedEvents).is(1)
			expect(keyAddedEvents[1].Path).is_shallow_equal { "a", "b" }
			expect(keyAddedEvents[1].Key).is("c")

			conn:Disconnect()
			manager:Destroy()
		end)
	end)
end

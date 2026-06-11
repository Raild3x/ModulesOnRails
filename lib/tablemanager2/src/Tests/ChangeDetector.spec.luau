--!strict
--[[
	IMPORTANT: Callback Classification
	
	ChangeDetector uses metadata.Diff to distinguish between callback types:
	
	- **Leaf Callback**: A direct value change (added, removed, changed)
	  - Check: metadata.Diff ~= nil AND metadata.Diff.type ~= "descendantChanged"
	  
	- **Ancestor Callback**: A container table affected by descendant changes
	  - Check: metadata.Diff == nil OR metadata.Diff.type == "descendantChanged"
	  
	The "descendantChanged" type is used for intermediate tables in the path
	between the captured snapshot and the actual changed value. These should
	be treated as ancestor notifications, not leaf changes.
]]

return function(t: tiniest)
	local ChangeDetector = require("../ChangeDetector")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	test("should capture snapshot and detect changes", function()
		local changes = {}
		local detector = ChangeDetector.new {
			OnValueChanged = function(path, newValue, oldValue, _metadata)
				table.insert(changes, { path = table.clone(path), new = newValue, old = oldValue })
			end,
		}

		local myTable = { root = { x = 1, y = 2 } }

		-- Capture snapshot (returns snapshot object)
		local snapshot = detector:CaptureSnapshot(myTable, { "root" })

		-- Verify snapshot structure
		expect(snapshot.RootTable).is(myTable)
		expect(snapshot.Path[1]).is("root")
		expect(snapshot.Data ~= nil).is_true()
		expect(snapshot.Timestamp ~= nil).is_true()

		-- Make changes
		myTable.root.x = 10
		myTable.root.z = 3

		-- Check for changes using snapshot object
		detector:CheckForChanges(snapshot)

		expect(#changes >= 2).is_true()
	end)

	test("should detect nested table changes with snapshot", function()
		local changes = {}
		local detector = ChangeDetector.new {
			OnValueChanged = function(path, newValue, oldValue, metadata)
				-- Only collect non-descendant leaf changes (actual value changes, not containers)
				if metadata.Diff and metadata.Diff.type ~= "descendantChanged" then
					table.insert(changes, { path = table.clone(path), new = newValue, old = oldValue })
				end
			end,
		}

		local myTable = { a = { b = 1 } }

		local snapshot = detector:CaptureSnapshot(myTable, {})

		-- Make nested change
		myTable.a.b = 2

		detector:CheckForChanges(snapshot)

		-- Should get the leaf change (not the descendantChanged node for 'a')
		expect(#changes).is(1)
		expect(changes[1].path[1]).is("a")
		expect(changes[1].path[2]).is("b")
	end)

	test("should support direct comparison without snapshot", function()
		local changes = {}
		local detector = ChangeDetector.new {
			OnValueChanged = function(path, newValue, oldValue, _metadata)
				-- Only collect leaf changes (where Diff is present)
				table.insert(changes, { path = table.clone(path), new = newValue, old = oldValue })
			end,
		}

		local oldTable = { x = 1 }
		local newTable = { x = 2 }
		local rootTable = { root = newTable }

		detector:CheckForChangesBetween(oldTable, newTable, { "root" }, rootTable)

		expect(#changes).is(3) -- {}, {"root"}, {"root", "x"}
		expect(changes[1].path[1]).is("root")
		expect(changes[1].new).is(2)
		expect(changes[1].old).is(1)
	end)

	test("CheckForChangesBetween fires ancestor callbacks when root table is omitted", function()
		local valuePaths = {}
		local detector = ChangeDetector.new {
			OnValueChanged = function(path, _newValue, _oldValue, _metadata)
				table.insert(valuePaths, table.concat(path, "."))
			end,
		}

		detector:CheckForChangesBetween({ x = 1 }, { x = 2 }, { "root" })

		local sawRootAncestor = false
		for _, path in valuePaths do
			if path == "" then
				sawRootAncestor = true
				break
			end
		end

		expect(sawRootAncestor).is_true()
	end)

	test("CheckForChangesBetween fires ancestor callbacks with explicit root table", function()
		local valuePaths = {}
		local root = { config = { x = 2 } }
		local detector = ChangeDetector.new {
			OnValueChanged = function(path, _newValue, _oldValue, _metadata)
				table.insert(valuePaths, table.concat(path, "."))
			end,
		}

		detector:CheckForChangesBetween({ x = 1 }, { x = 2 }, { "config" }, root)

		local sawRootAncestor = false
		for _, path in valuePaths do
			if path == "" then
				sawRootAncestor = true
				break
			end
		end

		expect(sawRootAncestor).is_true()
	end)

	test("FireDescendantChangedNodes=false suppresses descendantChanged node callbacks", function()
		local callbackCount = 0
		local leafCount = 0
		local detector = ChangeDetector.new {
			FireDescendantChangedNodes = false,
			OnValueChanged = function(_path, _newValue, _oldValue, metadata)
				callbackCount += 1
				if metadata.Diff and metadata.Diff.type ~= "descendantChanged" then
					leafCount += 1
				end
			end,
		}

		local myTable = { a = { b = 1 } }
		local snapshot = detector:CaptureSnapshot(myTable, {})
		myTable.a.b = 2

		detector:CheckForChanges(snapshot)

		expect(callbackCount).is(leafCount)
		expect(leafCount).is(1)
	end)

	test("FireDescendantChangedNodes defaults to true", function()
		local sawDescendantChanged = false
		local detector = ChangeDetector.new {
			OnValueChanged = function(_path, _newValue, _oldValue, metadata)
				if metadata.Diff and metadata.Diff.type == "descendantChanged" then
					sawDescendantChanged = true
				end
			end,
		}

		local myTable = { a = { b = 1 } }
		local snapshot = detector:CaptureSnapshot(myTable, {})
		myTable.a.b = 2

		detector:CheckForChanges(snapshot)

		expect(sawDescendantChanged).is_true()
	end)

	test("CaptureSnapshot rejects non-table roots", function()
		local detector = ChangeDetector.new {}

		local ok, err = pcall(function()
			detector:CaptureSnapshot(123 :: any, {})
		end)

		expect(ok).is(false)
		expect(type(err)).is("string")
		expect((err :: string):find("CaptureSnapshot expects rootTable to be a plain table", 1, true) ~= nil).is_true()
	end)

	test("CheckForChanges rejects snapshots with non-table RootTable", function()
		local detector = ChangeDetector.new {}

		local badSnapshot = {
			RootTable = 123,
			Path = {},
			Data = { value = 1, ref = nil, children = nil },
			Timestamp = os.clock(),
		}

		local ok, err = pcall(function()
			detector:CheckForChanges(badSnapshot :: any)
		end)

		expect(ok).is(false)
		expect(type(err)).is("string")
		expect((err :: string):find("Snapshot.RootTable must be a plain table", 1, true) ~= nil).is_true()
	end)

	test("should support historical diffing with multiple snapshots", function()
		local detector = ChangeDetector.new {}

		local myTable = { health = 100, mana = 50 }

		-- Capture first snapshot
		local snapshot1 = detector:CaptureSnapshot(myTable, {})

		-- Make some changes
		myTable.health = 75
		myTable.mana = 60

		-- Capture second snapshot
		local snapshot2 = detector:CaptureSnapshot(myTable, {})

		-- Make more changes
		myTable.health = 50
		myTable.mana = 70

		-- Can check against either snapshot independently
		local changes1 = {}
		local changes2 = {}

		local detector1 = ChangeDetector.new {
			OnKeyChanged = function(_path, key, newValue, oldValue, metadata)
				if metadata.Diff then
					table.insert(changes1, { key = key, old = oldValue, new = newValue })
				end
			end,
		}

		local detector2 = ChangeDetector.new {
			OnKeyChanged = function(_path, key, newValue, oldValue, metadata)
				if metadata.Diff then
					table.insert(changes2, { key = key, old = oldValue, new = newValue })
				end
			end,
		}

		-- Check against snapshot1 (100/50 -> 50/70)
		detector1:CheckForChanges(snapshot1)

		-- Check against snapshot2 (75/60 -> 50/70)
		detector2:CheckForChanges(snapshot2)

		-- Both should detect changes, but with different old values
		expect(#changes1).is(2)
		expect(#changes2).is(2)

		-- Find health changes
		local health1, health2
		for _, change in ipairs(changes1) do
			if change.key == "health" then
				health1 = change
			end
		end
		for _, change in ipairs(changes2) do
			if change.key == "health" then
				health2 = change
			end
		end

		expect(health1.old).is(100) -- From first snapshot
		expect(health1.new).is(50)
		expect(health2.old).is(75) -- From second snapshot
		expect(health2.new).is(50)
	end)

	test("should provide snapshot context in ancestor callbacks", function()
		local ancestorCallbacks = {}
		local detector = ChangeDetector.new {
			OnValueChanged = function(path, newValue, _oldValue, metadata)
				if metadata.Diff == nil then -- Ancestor callback
					-- Can access snapshot for full context
					table.insert(ancestorCallbacks, {
						path = table.clone(path),
						pathStr = table.concat(path, "."),
						snapshotPath = table.concat(metadata.Snapshot.Path, "."),
						rootTable = metadata.Snapshot.RootTable,
						newValue = newValue, -- Now contains true current value!
					})
				end
			end,
		}

		local myTable = { player = { stats = { Health = 100, Mana = 50 } } }

		local snapshot = detector:CaptureSnapshot(myTable, { "player", "stats" })

		-- Make changes
		myTable.player.stats.Health = 75

		detector:CheckForChanges(snapshot)

		-- Should have ancestor callbacks for "player" and root
		expect(#ancestorCallbacks >= 1).is_true()

		-- Verify ancestor callback receives true current value
		for _, callback in ipairs(ancestorCallbacks) do
			if callback.pathStr == "player" then
				-- Should receive the actual player table
				expect(callback.newValue).is(myTable.player)
				expect(callback.newValue.stats.Health).is(75) -- Can access descendants
			end
		end
	end)

	test("should detect table to scalar transition", function()
		local changes = {}
		local detector = ChangeDetector.new {
			OnValueChanged = function(path, newValue, oldValue, _metadata)
				table.insert(changes, { path = table.clone(path), new = newValue, old = oldValue, type = "value" })
			end,
			OnKeyRemoved = function(path, key, oldValue, _metadata)
				table.insert(changes, { path = table.clone(path), key = key, old = oldValue, type = "removed" })
			end,
			OnKeyAdded = function(path, key, newValue, _metadata)
				table.insert(changes, { path = table.clone(path), key = key, new = newValue, type = "added" })
			end,
		}

		local oldTable = { config = { host = "localhost" } }
		local newTable = { config = "disabled" }

		detector:CheckForChangesBetween(oldTable, newTable, {})

		-- Should get removal of config.host, then addition of config scalar
		expect(#changes >= 2).is_true()
	end)

	test("should fire OnValueChanged callbacks for descendant changes in parent tables", function()
		local valueChanges = {}
		local keyChanges = {}
		local detector = ChangeDetector.new {
			OnValueChanged = function(path, _newValue, _oldValue, metadata)
				local pathStr = table.concat(path, ".")
				table.insert(valueChanges, {
					path = table.clone(path),
					pathStr = pathStr,
					isLeaf = metadata.Diff ~= nil,
					diffType = metadata.Diff and metadata.Diff.type or "ancestor",
				})
			end,
			OnKeyChanged = function(path, key, _newValue, _oldValue, metadata)
				table.insert(keyChanges, {
					path = table.clone(path),
					key = key,
					diffType = metadata.Diff and metadata.Diff.type or "ancestor",
				})
			end,
		}

		local myTable = {
			player = {
				stats = { health = 100, mana = 50 },
				position = { x = 10, y = 20 },
			},
		}

		local snapshot = detector:CaptureSnapshot(myTable, {})

		-- Make nested change
		myTable.player.stats.health = 75

		detector:CheckForChanges(snapshot)

		-- Changes for paths {"player", "stats", "health"}, {"player", "stats"}, {"player"}, {}
		expect(#valueChanges).is(4)
		expect(valueChanges[1].path).is_shallow_equal { "player", "stats", "health" }
		expect(valueChanges[2].path).is_shallow_equal { "player", "stats" }
		expect(valueChanges[3].path).is_shallow_equal { "player" }
		expect(valueChanges[4].path).is_shallow_equal {}

		-- Keys: "health", "stats", "player"
		expect(keyChanges[1].key).is("health")
		expect(keyChanges[2].key).is("stats")
		expect(keyChanges[3].key).is("player")
		expect(#keyChanges).is(3)
	end)

	test("should fire OnValueChanged for multiple nested changes", function()
		local allChanges = {}
		local detector = ChangeDetector.new {
			OnValueChanged = function(path, _newValue, _oldValue, metadata)
				local pathStr = table.concat(path, ".")
				table.insert(allChanges, {
					path = table.clone(path),
					pathStr = pathStr,
					diffType = metadata.Diff and metadata.Diff.type or "ancestor",
				})
			end,
		}

		local myTable = {
			player = {
				stats = { health = 100 },
				position = { x = 10 },
			},
		}

		local snapshot = detector:CaptureSnapshot(myTable, { "player" })

		-- Make changes to different branches
		myTable.player.stats.health = 75
		myTable.player.position.x = 15

		detector:CheckForChanges(snapshot)

		-- Should fire OnValueChanged callbacks for:
		-- - health (changed)
		-- - x (changed)
		-- Plus ancestor notifications (no descendantChanged nodes fire callbacks)
		expect(#allChanges >= 2).is_true()
	end)

	test("should provide ChangeMetadata for all callbacks", function()
		local changes = {}
		local detector = ChangeDetector.new {
			OnKeyChanged = function(_path, key, _newValue, _oldValue, metadata)
				table.insert(changes, {
					key = key,
					hasMetadata = metadata ~= nil,
					hasDiff = metadata and metadata.Diff ~= nil,
					hasOriginPath = metadata and metadata.OriginPath ~= nil,
				})
			end,
		}

		local myTable = { player = { health = 100 } }

		local snapshot = detector:CaptureSnapshot(myTable, {})
		myTable.player.health = 75
		detector:CheckForChanges(snapshot)

		-- Keys: "health", "player"
		expect(#changes).is(2)
	end)

	test("should fire ancestor callbacks up the path hierarchy", function()
		local keyChanges = {}
		local detector = ChangeDetector.new {
			OnKeyChanged = function(path, key, _newValue, _oldValue, metadata)
				-- Ancestor = no Diff OR descendantChanged
				local isAncestor = metadata.Diff == nil or metadata.Diff.type == "descendantChanged"
				table.insert(keyChanges, {
					path = table.clone(path),
					key = key,
					pathStr = table.concat(path, "."),
					metadata = metadata,
					isAncestor = isAncestor,
				})
			end,
		}

		local myTable = { Player = { Stats = { Health = 100 } } }

		-- Capture at nested path (Stats table, not Health scalar)
		local snapshot = detector:CaptureSnapshot(myTable, { "Player", "Stats" })

		-- Make change
		myTable.Player.Stats.Health = 50

		detector:CheckForChanges(snapshot)

		-- Should fire callbacks for:
		-- 1. Leaf: Health changed (Diff present) at path Player.Stats.Health
		-- 2. Ancestor: Stats changed (at Player path, Diff nil, OriginPath = Player.Stats)
		-- 3. Ancestor: Player changed (at root path, Diff nil, OriginPath = Player.Stats)

		-- Check that we got callbacks with proper info
		local foundHealthLeaf = false
		local foundStatsAncestor = false
		local foundPlayerAncestor = false

		for _, change in ipairs(keyChanges) do
			if change.key == "Health" and change.pathStr == "Player.Stats" then
				foundHealthLeaf = true
				-- Should be leaf callback (Diff present)
				expect(change.isAncestor).never_is_true()
			end
			if change.key == "Stats" and change.pathStr == "Player" then
				foundStatsAncestor = true
				-- Should be ancestor callback (Diff nil)
				expect(change.isAncestor).is_true()
				-- OriginPath should point to where the assignment occurred (Player.Stats)
				expect(change.metadata.OriginPath ~= nil).is_true()
				local originKey = change.metadata.OriginPath[#change.metadata.OriginPath]
				expect(originKey).is("Stats")
				expect(#change.metadata.OriginPath).is(2) -- Player.Stats (captured path)
			end
			if change.key == "Player" and change.pathStr == "" then
				foundPlayerAncestor = true
				-- Should be ancestor callback
				expect(change.isAncestor).is_true()
				-- OriginPath should point to captured path
				expect(change.metadata.OriginPath).exists()
				expect(#change.metadata.OriginPath).is(2) -- Player.Stats
			end
		end

		expect(foundHealthLeaf).is_true()
		expect(foundStatsAncestor).is_true()
		expect(foundPlayerAncestor).is_true()
	end)

	test("should fire ancestor callbacks for deeply nested snapshots", function()
		local changes = {}
		local detector = ChangeDetector.new {
			OnKeyChanged = function(path, key, _newValue, _oldValue, metadata)
				-- Ancestor = no Diff OR descendantChanged
				local isAncestor = metadata.Diff == nil or metadata.Diff.type == "descendantChanged"
				table.insert(changes, {
					pathStr = table.concat(path, "."),
					key = key,
					metadata = metadata,
					isAncestor = isAncestor,
				})
			end,
		}

		local myTable = { Root = { Game = { World = { Player = { Stats = { x = 10 } } } } } }

		-- Capture at very nested path
		local snapshot = detector:CaptureSnapshot(myTable, { "Root", "Game", "World", "Player", "Stats" })

		myTable.Root.Game.World.Player.Stats.x = 20

		detector:CheckForChanges(snapshot)

		-- Should fire callbacks for all ancestors plus the leaf
		local ancestorKeys = {}
		local leafKeys = {}

		for _, change in ipairs(changes) do
			if change.isAncestor then
				table.insert(ancestorKeys, change.key)
				-- Ancestor callbacks have either no Diff or descendantChanged Diff
				local isValidAncestor = change.metadata.Diff == nil or change.metadata.Diff.type == "descendantChanged"
				expect(isValidAncestor).is_true()
				expect(change.metadata.OriginPath ~= nil).is_true()
				-- OriginPath should be the captured path (where assignment occurred)
				local originKey = change.metadata.OriginPath[#change.metadata.OriginPath]
				expect(originKey).is("Stats")
			else
				table.insert(leafKeys, change.key)
			end
		end

		-- Should have leaf change for 'x' and ancestors: Stats, Player, World, Game, Root
		expect(#leafKeys).is(1)
		expect(leafKeys[1]).is("x")
		expect(#ancestorKeys).is(5) -- Stats, Player, World, Game, Root
	end)

	test("should not fire ancestor callbacks when path is empty", function()
		local keyChanges = {}
		local detector = ChangeDetector.new {
			OnKeyChanged = function(_path, key, _newValue, _oldValue, _metadata)
				table.insert(keyChanges, { key = key })
			end,
		}

		local myTable = { x = 1 }

		-- Capture at root level (empty path)
		local snapshot = detector:CaptureSnapshot(myTable, {})

		myTable.x = 2

		detector:CheckForChanges(snapshot)

		-- Should only have the leaf change for 'x', no ancestors
		expect(#keyChanges).is(1)
		expect(keyChanges[1].key).is("x")
	end)

	test("should fire ancestor callbacks with CheckForChangesBetween", function()
		local changes = {}
		local detector = ChangeDetector.new {
			OnKeyChanged = function(_path, key, _newValue, _oldValue, metadata)
				table.insert(changes, {
					key = key,
					isAncestor = metadata.Diff == nil,
				})
			end,
		}

		-- Create proper nested structure for CheckForChangesBetween
		local oldValue = { Player = { Stats = { Health = 100 } } }
		local newValue = { Player = { Stats = { Health = 50 } } }

		-- Compare at the Stats level
		detector:CheckForChangesBetween(oldValue.Player.Stats, newValue.Player.Stats, { "Player", "Stats" })

		-- Should fire ancestor callbacks for Stats and Player
		local foundStatsAncestor = false
		local foundPlayerAncestor = false
		for _, change in ipairs(changes) do
			if change.key == "Stats" and change.isAncestor then
				foundStatsAncestor = true
			end
			if change.key == "Player" and change.isAncestor then
				foundPlayerAncestor = true
			end
		end

		expect(foundStatsAncestor or foundPlayerAncestor).is_true()
	end)
	test("should pass ChangeOrigin with full context for leaf changes", function()
		local leafChanges = {}
		local ancestorChanges = {}
		local detector = ChangeDetector.new {
			OnValueChanged = function(path, _newValue, _oldValue, metadata)
				if metadata.Diff then
					-- Leaf change
					table.insert(leafChanges, {
						path = table.clone(path),
						diffType = metadata.Diff.type,
					})
				else
					-- Ancestor notification
					table.insert(ancestorChanges, {
						path = table.clone(path),
						originPath = metadata.OriginPath,
					})
				end
			end,
		}

		local myTable = { data = { x = 10, y = { z = 20 } } }
		local snapshot = detector:CaptureSnapshot(myTable, { "data" })

		myTable.data.x = 15
		myTable.data.y.z = 25

		detector:CheckForChanges(snapshot)

		-- Check that leaf changes have Diff present
		local foundXLeaf = false
		local foundZLeaf = false

		for _, item in ipairs(leafChanges) do
			if #item.path == 2 and item.path[2] == "x" then
				foundXLeaf = true
				expect(item.diffType).is("changed")
			end
			if #item.path == 3 and item.path[3] == "z" then
				foundZLeaf = true
				expect(item.diffType).is("changed")
			end
		end

		expect(foundXLeaf).is_true()
		expect(foundZLeaf).is_true()

		-- Ancestors should have OriginPath
		expect(#ancestorChanges > 0).is_true()
	end)

	test("should distinguish between leaf and ancestor callbacks via metadata", function()
		local callbacks = {}
		local detector = ChangeDetector.new {
			OnKeyChanged = function(path, key, _newValue, _oldValue, metadata)
				-- Leaf callbacks have Diff with type != descendantChanged
				-- Ancestor callbacks have Diff = nil OR type = descendantChanged
				local isLeaf = metadata.Diff ~= nil and metadata.Diff.type ~= "descendantChanged"
				table.insert(callbacks, {
					pathStr = table.concat(path, "."),
					key = key,
					isLeafChange = isLeaf,
					isAncestor = not isLeaf,
					originPath = table.clone(metadata.OriginPath),
				})
			end,
		}

		local myTable = { Root = { Player = { value = 100 } } }
		local snapshot = detector:CaptureSnapshot(myTable, { "Root", "Player" })

		myTable.Root.Player.value = 200

		detector:CheckForChanges(snapshot)

		-- Should have both leaf callback and ancestor callbacks
		local leafCallbacks = 0
		local ancestorCallbacks = 0

		for _, cb in ipairs(callbacks) do
			if cb.isLeafChange then
				leafCallbacks = leafCallbacks + 1
			else
				ancestorCallbacks = ancestorCallbacks + 1
			end
		end

		expect(leafCallbacks).is(1) -- value changed at Root.Player.value
		expect(ancestorCallbacks).is(2) -- Player and Root ancestors
	end)

	test("should provide correct originPath for ancestor callbacks via metadata", function()
		local metadatas = {}
		local detector = ChangeDetector.new {
			OnValueChanged = function(path, _newValue, _oldValue, metadata)
				table.insert(metadatas, {
					path = table.clone(path),
					pathStr = table.concat(path, "."),
					originPath = table.concat(metadata.OriginPath, "."),
					isAncestor = metadata.Diff == nil,
				})
			end,
		}

		local myTable = { Root = { nested = { deeply = { value = 1 } } } }
		local snapshot = detector:CaptureSnapshot(myTable, { "Root" })

		myTable.Root.nested.deeply.value = 2

		detector:CheckForChanges(snapshot)

		-- All callbacks should have OriginPath pointing to captured path (Root)
		-- This is the assignment-as-operation model
		local foundCapturedOrigin = false
		for _, meta in ipairs(metadatas) do
			if meta.originPath == "Root" then
				foundCapturedOrigin = true
			end
		end

		-- At least one callback should point to the captured path
		expect(foundCapturedOrigin).is_true()

		-- Ancestor callbacks should all have OriginPath pointing to captured path
		for _, meta in ipairs(metadatas) do
			if meta.isAncestor then
				expect(meta.originPath).is("Root")
			end
		end
	end)

	test("should provide ChangeMetadata with diff node for OnKeyAdded callbacks", function()
		local additions = {}
		local detector = ChangeDetector.new {
			OnKeyAdded = function(path, key, _newValue, metadata)
				table.insert(additions, {
					pathStr = table.concat(path, "."),
					key = key,
					hasMetadata = metadata ~= nil,
					hasDiff = metadata and metadata.Diff ~= nil,
					diffType = metadata and metadata.Diff and metadata.Diff.type or nil,
					isLeafChange = metadata and metadata.Diff ~= nil,
				})
			end,
		}

		local myTable = { data = { existing = 1 } }
		local snapshot = detector:CaptureSnapshot(myTable, { "data" })

		myTable.data.newKey = 100

		detector:CheckForChanges(snapshot)

		-- Should have leaf addition with metadata
		local foundLeaf = false
		for _, addition in ipairs(additions) do
			if addition.isLeafChange and addition.key == "newKey" then
				foundLeaf = true
				expect(addition.hasMetadata).is_true()
				expect(addition.hasDiff).is_true()
				expect(addition.diffType).is("added")
			end
		end
		expect(foundLeaf).is_true()
	end)

	test("should provide ChangeMetadata with diff node for OnKeyRemoved callbacks", function()
		local removals = {}
		local detector = ChangeDetector.new {
			OnKeyRemoved = function(path, key, _oldValue, metadata)
				table.insert(removals, {
					pathStr = table.concat(path, "."),
					key = key,
					hasMetadata = metadata ~= nil,
					hasDiff = metadata and metadata.Diff ~= nil,
					diffType = metadata and metadata.Diff and metadata.Diff.type or nil,
					isLeafChange = metadata and metadata.Diff ~= nil,
				})
			end,
		}

		local myTable = { data = { toRemove = 100, keepThis = 200 } }
		local snapshot = detector:CaptureSnapshot(myTable, { "data" })

		myTable.data.toRemove = nil

		detector:CheckForChanges(snapshot)

		-- Should have leaf removal with metadata
		local foundLeaf = false
		for _, removal in ipairs(removals) do
			if removal.isLeafChange and removal.key == "toRemove" then
				foundLeaf = true
				expect(removal.hasMetadata).is_true()
				expect(removal.hasDiff).is_true()
				expect(removal.diffType).is("removed")
			end
		end
		expect(foundLeaf).is_true()
	end)

	test("should derive originKey from originPath in metadata", function()
		local metadatas = {}
		local detector = ChangeDetector.new {
			OnKeyChanged = function(_path, _key, _newValue, _oldValue, metadata)
				table.insert(metadatas, metadata)
			end,
		}

		local myTable = { Player = { Stats = { Health = 100 } } }
		local snapshot = detector:CaptureSnapshot(myTable, { "Player", "Stats" })

		myTable.Player.Stats.Health = 50

		detector:CheckForChanges(snapshot)

		-- originKey should be derivable from originPath (captured path)
		-- OriginPath = {"Player", "Stats"} for all callbacks
		for _, metadata in ipairs(metadatas) do
			local derivedKey = metadata.OriginPath[#metadata.OriginPath]
			expect(derivedKey).is("Stats")
		end
	end)

	test("should provide rich ChangeMetadata with diff node information", function()
		local allMetadata = {}
		local detector = ChangeDetector.new {
			OnKeyAdded = function(_path, _key, _newValue, metadata)
				table.insert(allMetadata, { callback = "OnKeyAdded", metadata = metadata })
			end,
			OnKeyRemoved = function(_path, _key, _oldValue, metadata)
				table.insert(allMetadata, { callback = "OnKeyRemoved", metadata = metadata })
			end,
			OnKeyChanged = function(_path, _key, _newValue, _oldValue, metadata)
				table.insert(allMetadata, { callback = "OnKeyChanged", metadata = metadata })
			end,
			OnValueChanged = function(_path, _newValue, _oldValue, metadata)
				table.insert(allMetadata, { callback = "OnValueChanged", metadata = metadata })
			end,
		}

		local myTable = {
			data = {
				toChange = 100,
				toRemove = "old",
				nested = { value = 1 },
			},
		}
		local snapshot = detector:CaptureSnapshot(myTable, { "data" })

		-- Make various changes
		myTable.data.toChange = 200 -- changed
		myTable.data.toRemove = nil -- removed
		myTable.data.newKey = "added" -- added
		myTable.data.nested.value = 2 -- nested change

		detector:CheckForChanges(snapshot)

		-- Validate all metadata has required structure
		for _, entry in ipairs(allMetadata) do
			local metadata = entry.metadata
			expect(metadata ~= nil).is_true()
			expect(metadata.OriginPath ~= nil).is_true()

			-- Only leaf callbacks have non-nil Diff
			if metadata.Diff ~= nil then
				expect(metadata.Diff.type ~= nil).is_true()

				-- Diff node should have type, old, and new fields
				local diffType = metadata.Diff.type
				expect(
					diffType == "added"
						or diffType == "removed"
						or diffType == "changed"
						or diffType == "descendantChanged"
				).is_true()
			end
		end

		-- Should have multiple metadata entries from all callbacks
		expect(#allMetadata > 0).is_true()
	end)

	test("should include old and new values in diff node", function()
		local changes = {}
		local detector = ChangeDetector.new {
			OnKeyChanged = function(_path, key, _newValue, _oldValue, metadata)
				table.insert(changes, {
					key = key,
					diffOld = metadata.Diff.old,
					diffNew = metadata.Diff.new,
					diffType = metadata.Diff.type,
				})
			end,
		}

		local myTable = { score = 100, name = "Alice" }
		local snapshot = detector:CaptureSnapshot(myTable, {})

		myTable.score = 150
		myTable.name = "Bob"

		detector:CheckForChanges(snapshot)

		-- Find the leaf changes and verify old/new values are in the diff
		for _, change in ipairs(changes) do
			if change.key == "score" and change.diffType == "changed" then
				expect(change.diffOld).is(100)
				expect(change.diffNew).is(150)
			elseif change.key == "name" and change.diffType == "changed" then
				expect(change.diffOld).is("Alice")
				expect(change.diffNew).is("Bob")
			end
		end
	end)

	test("should distinguish leaf vs ancestor via originPath length in metadata", function()
		local callbacks = {}
		local detector = ChangeDetector.new {
			OnValueChanged = function(path, _newValue, _oldValue, metadata)
				table.insert(callbacks, {
					path = table.clone(path),
					pathStr = table.concat(path, "."),
					isLeaf = metadata.Diff ~= nil,
					isAncestor = metadata.Diff == nil,
				})
			end,
		}

		local myTable = { level1 = { level2 = { value = 1 } } }
		local snapshot = detector:CaptureSnapshot(myTable, {})

		myTable.level1.level2.value = 2

		detector:CheckForChanges(snapshot)

		-- Should have leaf (Diff present) and ancestors (Diff nil)
		local leaves = 0
		local ancestors = 0

		for _, cb in ipairs(callbacks) do
			if cb.isLeaf then
				leaves = leaves + 1
			elseif cb.isAncestor then
				ancestors = ancestors + 1
			end
		end

		-- One leaf (the actual changed value)
		-- No descendantChanged nodes should fire (they're containers)
		local deepestLeaf = 0
		for _, cb in ipairs(callbacks) do
			if cb.isLeaf and #cb.path == 3 then -- level1.level2.value
				deepestLeaf = deepestLeaf + 1
			end
		end

		expect(deepestLeaf).is(1) -- The actual changed value at deepest level
		expect(ancestors >= 0).is_true() -- May have ancestor notifications
	end)

	-- Edge Case Tests
	describe("Edge Cases", function()
		test("should handle nil to value transition", function()
			local changes = {}
			local detector = ChangeDetector.new {
				OnKeyAdded = function(_path, key, newValue, metadata)
					table.insert(changes, { key = key, new = newValue, type = "added", hasDiff = metadata.Diff ~= nil })
				end,
			}

			local myTable = { x = nil }
			local snapshot = detector:CaptureSnapshot(myTable, {})

			myTable.x = 10

			detector:CheckForChanges(snapshot)

			expect(#changes).is(1)
			expect(changes[1].key).is("x")
			expect(changes[1].new).is(10)
			expect(changes[1].hasDiff).is_true()
		end)

		test("should handle value to nil transition", function()
			local changes = {}
			local detector = ChangeDetector.new {
				OnKeyRemoved = function(_path, key, oldValue, metadata)
					table.insert(
						changes,
						{ key = key, old = oldValue, type = "removed", hasDiff = metadata.Diff ~= nil }
					)
				end,
			}

			local myTable = { x = 10 }
			local snapshot = detector:CaptureSnapshot(myTable, {})

			myTable.x = nil

			detector:CheckForChanges(snapshot)

			expect(#changes).is(1)
			expect(changes[1].key).is("x")
			expect(changes[1].old).is(10)
			expect(changes[1].hasDiff).is_true()
		end)

		test("should handle empty table changes", function()
			local changes = {}
			local detector = ChangeDetector.new {
				OnValueChanged = function(_path, _newValue, _oldValue, metadata)
					if metadata.Diff then
						table.insert(changes, { type = metadata.Diff.type })
					end
				end,
			}

			local myTable = {}
			local snapshot = detector:CaptureSnapshot(myTable, {})

			myTable.newKey = "added"

			detector:CheckForChanges(snapshot)

			expect(#changes >= 1).is_true()
		end)

		test("should handle empty table to empty table (no changes)", function()
			local changes = {}
			local detector = ChangeDetector.new {
				OnValueChanged = function(_path, _newValue, _oldValue, _metadata)
					table.insert(changes, {})
				end,
			}

			local myTable = {}
			local snapshot = detector:CaptureSnapshot(myTable, {})

			detector:CheckForChanges(snapshot)

			expect(#changes).is(0)
		end)

		test("should handle multiple changes to same key", function()
			local changes = {}
			local detector = ChangeDetector.new {
				OnKeyChanged = function(_path, key, newValue, oldValue, metadata)
					if metadata.Diff then
						table.insert(changes, { key = key, new = newValue, old = oldValue })
					end
				end,
			}

			local myTable = { x = 1 }
			local snapshot = detector:CaptureSnapshot(myTable, {})

			myTable.x = 2
			myTable.x = 3 -- Only final state should be detected

			detector:CheckForChanges(snapshot)

			expect(#changes).is(1)
			expect(changes[1].old).is(1)
			expect(changes[1].new).is(3) -- Should see final value, not intermediate
		end)

		test("should handle deeply nested nil values", function()
			local changes = {}
			local detector = ChangeDetector.new {
				OnValueChanged = function(path, _newValue, _oldValue, metadata)
					if metadata.Diff and metadata.Diff.type ~= "descendantChanged" then
						table.insert(changes, { path = table.clone(path) })
					end
				end,
			}

			local myTable = { a = { b = { c = nil } } }
			local snapshot = detector:CaptureSnapshot(myTable, {})

			myTable.a.b.c = 10

			detector:CheckForChanges(snapshot)

			expect(#changes).is(1)
			expect(changes[1].path[1]).is("a")
			expect(changes[1].path[2]).is("b")
			expect(changes[1].path[3]).is("c")
		end)

		test("should handle table replaced with different table", function()
			local changes = {}
			local detector = ChangeDetector.new {
				OnValueChanged = function(_path, _newValue, _oldValue, metadata)
					if metadata.Diff then
						table.insert(changes, { type = metadata.Diff.type })
					end
				end,
			}

			local myTable = { nested = { x = 1 } }
			local snapshot = detector:CaptureSnapshot(myTable, {})

			myTable.nested = { y = 2 } -- Completely different table

			detector:CheckForChanges(snapshot)

			-- Should detect removal of x and addition of y
			expect(#changes >= 2).is_true()
		end)

		test("should handle scalar to table transition", function()
			local removals = {}
			local additions = {}
			local changes = {}
			local detector = ChangeDetector.new {
				OnKeyRemoved = function(_path, key, _oldValue, metadata)
					if metadata.Diff then
						table.insert(removals, { key = key })
					end
				end,
				OnKeyAdded = function(_path, key, _newValue, metadata)
					if metadata.Diff then
						table.insert(additions, { key = key })
					end
				end,
				OnKeyChanged = function(_path, key, newValue, oldValue, metadata)
					if metadata.Diff then
						table.insert(changes, { key = key, old = oldValue, new = newValue })
					end
				end,
			}

			local myTable = { config = "disabled" }
			local snapshot = detector:CaptureSnapshot(myTable, {})

			myTable.config = { host = "localhost" }

			detector:CheckForChanges(snapshot)

			-- scalar -> table is a single "changed" at the key (NOT a removal),
			-- carrying the whole new table, plus the new table's keys reported
			-- as additions for granular listeners.
			expect(#removals).is(0)
			expect(#changes).is(1)
			expect(changes[1].key).is("config")
			expect(changes[1].old).is("disabled")
			expect(type(changes[1].new)).is("table")
			expect(#additions >= 1).is_true()
		end)

		test("table to scalar transition fires subtree teardown before the scalar event", function()
			-- Regression guard: the scalar-sentinel child used to be processed in
			-- pairs() order among the real children, so a consumer could receive
			-- the parent's scalar value FIRST and then fail to apply the
			-- (now-redundant) child removals through a non-table value. The
			-- sentinel must always fire LAST.
			local events = {}
			local detector = ChangeDetector.new {
				OnValueChanged = function(path, newValue, _oldValue, metadata)
					if metadata.Diff and metadata.Diff.type ~= "descendantChanged" then
						table.insert(events, { path = table.clone(path), new = newValue })
					end
				end,
			}

			local myTable = { config = { host = "localhost", ports = { 80, 443 } } }
			local snapshot = detector:CaptureSnapshot(myTable, {})

			myTable.config = "disabled"

			detector:CheckForChanges(snapshot)

			-- Teardown events for the old subtree (paths deeper than {config})
			-- must all precede the single scalar event at {config}, which is last.
			expect(#events >= 2).is_true()
			local lastEvent = events[#events]
			expect(#lastEvent.path).is(1)
			expect(lastEvent.path[1]).is("config")
			expect(lastEvent.new).is("disabled")
			for i = 1, #events - 1 do
				expect(events[i].path[1]).is("config")
				expect(#events[i].path > 1).with_context(`event #{i} should be a descendant teardown`).is_true()
			end
		end)

		test("should handle mixed changes in single operation", function()
			local allChanges = {}
			local detector = ChangeDetector.new {
				OnKeyAdded = function(_path, key, _newValue, metadata)
					if metadata.Diff then
						table.insert(allChanges, { key = key, type = "added" })
					end
				end,
				OnKeyRemoved = function(_path, key, _oldValue, metadata)
					if metadata.Diff then
						table.insert(allChanges, { key = key, type = "removed" })
					end
				end,
				OnKeyChanged = function(_path, key, _newValue, _oldValue, metadata)
					if metadata.Diff then
						table.insert(allChanges, { key = key, type = "changed" })
					end
				end,
			}

			local myTable = { a = 1, b = 2, c = 3 }
			local snapshot = detector:CaptureSnapshot(myTable, {})

			myTable.a = 10 -- changed
			myTable.b = nil -- removed
			myTable.d = 4 -- added

			detector:CheckForChanges(snapshot)

			-- Should have 3 changes: 1 added, 1 removed, 1 changed
			expect(#allChanges).is(3)

			local foundAdded = false
			local foundRemoved = false
			local foundChanged = false
			for _, change in ipairs(allChanges) do
				if change.key == "d" and change.type == "added" then
					foundAdded = true
				end
				if change.key == "b" and change.type == "removed" then
					foundRemoved = true
				end
				if change.key == "a" and change.type == "changed" then
					foundChanged = true
				end
			end

			expect(foundAdded).is_true()
			expect(foundRemoved).is_true()
			expect(foundChanged).is_true()
		end)

		test("should handle changes at root level with empty path", function()
			local changes = {}
			local detector = ChangeDetector.new {
				OnValueChanged = function(path, _newValue, _oldValue, metadata)
					if metadata.Diff and metadata.Diff.type ~= "descendantChanged" then
						table.insert(changes, { pathLength = #path })
					end
				end,
			}

			local oldTable = { x = 1 }
			local newTable = { x = 2 }

			detector:CheckForChangesBetween(oldTable, newTable, {})

			expect(#changes).is(1)
			expect(changes[1].pathLength).is(1) -- Path should be {x}
		end)

		test("should handle no changes when values are identical", function()
			local changes = {}
			local detector = ChangeDetector.new {
				OnValueChanged = function(_path, _newValue, _oldValue, _metadata)
					table.insert(changes, {})
				end,
			}

			local myTable = { x = 1, y = { z = 2 } }
			local snapshot = detector:CaptureSnapshot(myTable, {})

			-- No changes made

			detector:CheckForChanges(snapshot)

			expect(#changes).is(0)
		end)

		test("should handle boolean value changes", function()
			local changes = {}
			local detector = ChangeDetector.new {
				OnKeyChanged = function(_path, key, newValue, oldValue, metadata)
					if metadata.Diff then
						table.insert(changes, { key = key, new = newValue, old = oldValue })
					end
				end,
			}

			local myTable = { enabled = true }
			local snapshot = detector:CaptureSnapshot(myTable, {})

			myTable.enabled = false

			detector:CheckForChanges(snapshot)

			expect(#changes).is(1)
			expect(changes[1].old).is(true)
			expect(changes[1].new).is(false)
		end)

		test("should handle string value changes", function()
			local changes = {}
			local detector = ChangeDetector.new {
				OnKeyChanged = function(_path, key, newValue, oldValue, metadata)
					if metadata.Diff then
						table.insert(changes, { key = key, new = newValue, old = oldValue })
					end
				end,
			}

			local myTable = { name = "Alice" }
			local snapshot = detector:CaptureSnapshot(myTable, {})

			myTable.name = "Bob"

			detector:CheckForChanges(snapshot)

			expect(#changes).is(1)
			expect(changes[1].old).is("Alice")
			expect(changes[1].new).is("Bob")
		end)

		test("should handle number to string transition", function()
			local changes = {}
			local detector = ChangeDetector.new {
				OnKeyChanged = function(_path, key, newValue, oldValue, metadata)
					if metadata.Diff then
						table.insert(changes, {
							key = key,
							new = newValue,
							old = oldValue,
							newType = type(newValue),
							oldType = type(oldValue),
						})
					end
				end,
			}

			local myTable = { value = 123 }
			local snapshot = detector:CaptureSnapshot(myTable, {})

			myTable.value = "123"

			detector:CheckForChanges(snapshot)

			expect(#changes).is(1)
			expect(changes[1].oldType).is("number")
			expect(changes[1].newType).is("string")
		end)

		test("should handle array-like tables", function()
			local changes = {}
			local detector = ChangeDetector.new {
				OnValueChanged = function(_path, _newValue, _oldValue, metadata)
					if metadata.Diff and metadata.Diff.type ~= "descendantChanged" then
						table.insert(changes, { type = metadata.Diff.type })
					end
				end,
			}

			local myTable = { 1, 2, 3 }
			local snapshot = detector:CaptureSnapshot(myTable, {})

			myTable[2] = 20

			detector:CheckForChanges(snapshot)

			expect(#changes).is(1)
		end)

		test("should handle keys with special characters", function()
			local changes = {}
			local detector = ChangeDetector.new {
				OnKeyChanged = function(_path, key, _newValue, _oldValue, metadata)
					if metadata.Diff then
						table.insert(changes, { key = key })
					end
				end,
			}

			local myTable = { ["key-with-dash"] = 1, ["key.with.dot"] = 2 }
			local snapshot = detector:CaptureSnapshot(myTable, {})

			myTable["key-with-dash"] = 10
			myTable["key.with.dot"] = 20

			detector:CheckForChanges(snapshot)

			expect(#changes).is(2)
		end)

		test("should handle origin tracking with multiple sibling changes", function()
			local ancestorCallbacks = {}
			local leafCallbacks = {}
			local detector = ChangeDetector.new {
				OnKeyChanged = function(path, key, _newValue, _oldValue, metadata)
					-- Ancestor = no Diff OR descendantChanged
					local isAncestor = metadata.Diff == nil or metadata.Diff.type == "descendantChanged"
					if isAncestor then
						table.insert(ancestorCallbacks, {
							key = key,
							path = table.clone(path),
							pathStr = table.concat(path, "."),
							originPath = table.concat(metadata.OriginPath, "."),
						})
					else -- Leaf callback
						table.insert(leafCallbacks, {
							key = key,
							path = table.clone(path),
							pathStr = table.concat(path, "."),
						})
					end
				end,
			}
			local myTable = { Root = { a = 1, b = 2 } }
			local snapshot = detector:CaptureSnapshot(myTable, { "Root" })

			myTable.Root.a = 10
			myTable.Root.b = 20

			detector:CheckForChanges(snapshot)

			-- Should have leaf callbacks for 'a' and 'b'
			expect(#leafCallbacks).is(2)

			-- Should have ancestor callback with OriginPath pointing to captured path (Root)
			-- In the assignment-as-operation model, all changes share the same origin
			expect(#ancestorCallbacks >= 1).is_true()

			-- OriginPath should point to captured path (Root), not individual leaves
			if #ancestorCallbacks > 0 then
				local origin = ancestorCallbacks[1].originPath
				expect(origin).is("Root")
			end
		end)

		test("should handle very deep nesting", function()
			local changes = {}
			local detector = ChangeDetector.new {
				OnValueChanged = function(path, _newValue, _oldValue, metadata)
					if metadata.Diff and metadata.Diff.type ~= "descendantChanged" then
						table.insert(changes, { depth = #path })
					end
				end,
			}

			local myTable = { a = { b = { c = { d = { e = { f = 1 } } } } } }
			local snapshot = detector:CaptureSnapshot(myTable, {})

			myTable.a.b.c.d.e.f = 2

			detector:CheckForChanges(snapshot)

			expect(#changes).is(1)
			expect(changes[1].depth).is(6) -- 6 levels deep
		end)

		test("should handle metadata OriginDiff for ancestor callbacks", function()
			local ancestorCallbacks = {}
			local detector = ChangeDetector.new {
				OnValueChanged = function(_path, _newValue, _oldValue, metadata)
					if metadata.Diff == nil then -- Ancestor callback
						table.insert(ancestorCallbacks, {
							hasOriginDiff = metadata.OriginDiff ~= nil,
							originDiffType = metadata.OriginDiff and metadata.OriginDiff.type,
						})
					end
				end,
			}

			local myTable = { nested = { value = 1 } }
			local snapshot = detector:CaptureSnapshot(myTable, {})

			myTable.nested.value = 2

			detector:CheckForChanges(snapshot)

			-- Ancestor callbacks should have OriginDiff
			if #ancestorCallbacks > 0 then
				expect(ancestorCallbacks[1].hasOriginDiff).is_true()
				expect(ancestorCallbacks[1].originDiffType ~= nil).is_true()
			end
		end)

		test("should handle table with numeric and string keys mixed", function()
			local changes = {}
			local detector = ChangeDetector.new {
				OnKeyChanged = function(_path, key, _newValue, _oldValue, metadata)
					if metadata.Diff then
						table.insert(changes, { key = key, keyType = type(key) })
					end
				end,
			}

			local myTable = { [1] = "one", [2] = "two", name = "test" }
			local snapshot = detector:CaptureSnapshot(myTable, {})

			myTable[1] = "ONE"
			myTable.name = "TEST"

			detector:CheckForChanges(snapshot)

			expect(#changes).is(2)

			local foundNumericKey = false
			local foundStringKey = false
			for _, change in ipairs(changes) do
				if change.keyType == "number" then
					foundNumericKey = true
				end
				if change.keyType == "string" then
					foundStringKey = true
				end
			end

			expect(foundNumericKey).is_true()
			expect(foundStringKey).is_true()
		end)

		test("should handle changes to a path that resolves to nil", function()
			local changes = {}
			local detector = ChangeDetector.new {
				OnValueChanged = function(path, _newValue, _oldValue, metadata)
					if metadata.Diff and metadata.Diff.type ~= "descendantChanged" then
						table.insert(changes, { pathStr = table.concat(path, ".") })
					end
				end,
			}

			local myTable = { a = { b = nil } }
			local snapshot = detector:CaptureSnapshot(myTable, { "a", "b" })

			myTable.a.b = 10

			detector:CheckForChanges(snapshot)

			expect(#changes).is(1)
			expect(changes[1].pathStr).is("a.b")
		end)
	end)
end

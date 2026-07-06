--!strict
--[[
	Wildcard ("*") support in the mutation/read methods: Set, Update, Increment,
	and GetMatching. Wildcard segments expand against the live data at call time
	(match-what-exists), multiple wildcards compose as the product of their
	branch factors, and multi-path writes are batched into one coherent flush.
	The listener-side wildcard behavior is covered in
	TableManager.value-listener-methods.spec.luau and ListenerRegistry.spec.luau.
]]

return function(t: tiniest)
	local TableManager = require("../../TableManager")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("Method: Set (wildcard paths)", function()
		test("fans out across a single wildcard", function()
			local manager = TableManager.new {
				Players = {
					A = { Health = 10 },
					B = { Health = 20 },
				},
			}

			manager:Set({ "Players", "*", "Health" }, 100)

			expect(manager.Raw.Players.A.Health).is(100)
			expect(manager.Raw.Players.B.Health).is(100)
			manager:Destroy()
		end)

		test("supports dot-string wildcard paths", function()
			local manager = TableManager.new {
				Players = {
					A = { Health = 10 },
					B = { Health = 20 },
				},
			}

			manager:Set("Players.*.Health", 55)

			expect(manager.Raw.Players.A.Health).is(55)
			expect(manager.Raw.Players.B.Health).is(55)
			manager:Destroy()
		end)

		test("a non-nil write creates a missing literal final key on each matched parent", function()
			local manager = TableManager.new {
				Players = {
					A = { Health = 10 },
					B = {}, -- no Health yet
				},
			}

			manager:Set("Players.*.Health", 100)

			expect(manager.Raw.Players.A.Health).is(100)
			expect(manager.Raw.Players.B.Health).is(100)
			manager:Destroy()
		end)

		test("multiple wildcards compose as the product of branch factors", function()
			local manager = TableManager.new {
				Players = {
					A = { Stats = { Str = 1, Dex = 2 } },
					B = { Stats = { Str = 3 } },
					C = {}, -- no Stats: pruned branch
				},
			}

			manager:Set("Players.*.Stats.*", 0)

			expect(manager.Raw.Players.A.Stats.Str).is(0)
			expect(manager.Raw.Players.A.Stats.Dex).is(0)
			expect(manager.Raw.Players.B.Stats.Str).is(0)
			expect(manager.Raw.Players.C.Stats).is(nil)
			manager:Destroy()
		end)

		test("mid-path branches that cannot resolve are silently skipped", function()
			local manager = TableManager.new {
				Players = {
					A = { Stats = { Str = 1 } },
					B = { Stats = 5 }, -- Stats not a table
				},
			}

			manager:Set("Players.*.Stats.Str", 9)

			expect(manager.Raw.Players.A.Stats.Str).is(9)
			expect(manager.Raw.Players.B.Stats).is(5)
			manager:Destroy()
		end)

		test("zero matches is a no-op (no writes, no events)", function()
			local manager = TableManager.new { Players = {} }

			local fireCount = 0
			manager:OnChange({ "Players" }, function()
				fireCount += 1
			end)

			manager:Set("Players.*.Health", 100)

			expect(fireCount).is(0)
			expect(next(manager.Raw.Players)).is(nil)
			manager:Destroy()
		end)

		test("nil performs a mass delete of existing keys", function()
			local manager = TableManager.new {
				Players = {
					A = { Health = 1 },
					B = { Health = 2 },
				},
			}

			local removedKeys = {}
			manager:OnKeyRemove({ "Players" }, function(key)
				removedKeys[key] = true
			end)

			manager:Set("Players.*", nil)

			expect(next(manager.Raw.Players)).is(nil)
			expect(removedKeys).is_shallow_equal { A = true, B = true }
			manager:Destroy()
		end)

		test("a nil write only targets parents where the final key exists", function()
			local manager = TableManager.new {
				Players = {
					A = { Health = 1, Buff = "haste" },
					B = { Health = 2 },
				},
			}

			local fireCount = 0
			manager:OnValueChange({ "Players", "*", "Buff" }, function()
				fireCount += 1
			end)

			manager:Set("Players.*.Buff", nil)

			expect(manager.Raw.Players.A.Buff).is(nil)
			expect(fireCount).is(1)
			manager:Destroy()
		end)

		test("fires wildcard listeners once per concrete write with the matched keys", function()
			local manager = TableManager.new {
				Players = {
					A = { Health = 10 },
					B = { Health = 20 },
				},
			}

			local firesByPlayer = {}
			manager:OnValueChange({ "Players", "*", "Health" }, function(newValue, _oldValue, metadata)
				local playerId = (metadata.WildcardMatches :: { any })[1]
				firesByPlayer[playerId] = newValue
			end)

			manager:Set("Players.*.Health", 50)

			expect(firesByPlayer).is_shallow_equal { A = 50, B = 50 }
			manager:Destroy()
		end)

		test("a single match takes the ordinary immediate write path", function()
			local manager = TableManager.new {
				Players = { A = { Health = 10 } },
			}

			local fireCount = 0
			manager:OnValueChange({ "Players", "A", "Health" }, function(newValue)
				fireCount += 1
				expect(newValue).is(9)
			end)

			manager:Set("Players.*.Health", 9)

			expect(fireCount).is(1)
			manager:Destroy()
		end)

		test("composes with an already-open Batch window", function()
			local manager = TableManager.new {
				Players = {
					A = { Health = 1 },
					B = { Health = 2 },
				},
			}

			local fireCount = 0
			manager:OnValueChange({ "Players", "*", "Health" }, function()
				fireCount += 1
			end)

			manager:Batch(function()
				manager:Set("Players.*.Health", 7)
				-- Nothing fires until the batch window closes.
				expect(fireCount).is(0)
			end)

			expect(fireCount).is(2)
			expect(manager.Raw.Players.A.Health).is(7)
			expect(manager.Raw.Players.B.Health).is(7)
			manager:Destroy()
		end)

		test("OnApplied carries one concrete op per matched path, never a wildcard path", function()
			local manager = TableManager.new {
				Players = {
					A = { Health = 1 },
					B = { Health = 2 },
				},
			}

			local ops = {}
			local disconnectApplied = manager:OnApplied(function(op)
				table.insert(ops, op)
			end)

			manager:Set("Players.*.Health", 3)

			local setPathsByPlayer = {}
			for _, op in ops do
				for _, segment in op.Path do
					expect(segment).never_is("*")
				end
				if op.Kind == "Set" then
					setPathsByPlayer[op.Path[2]] = true
				end
			end
			expect(setPathsByPlayer).is_shallow_equal { A = true, B = true }

			disconnectApplied()
			manager:Destroy()
		end)

		test("a table value fanned to several paths shares identity under the default allow mode", function()
			local manager = TableManager.new {
				Players = {
					A = {},
					B = {},
				},
			}

			manager:Set("Players.*.Loadout", { Weapon = "Sword" })

			expect(manager.Raw.Players.A.Loadout).is(manager.Raw.Players.B.Loadout)
			expect(manager.Raw.Players.A.Loadout.Weapon).is("Sword")
			manager:Destroy()
		end)

		test("a table value is cloned per additional path under DuplicateReferenceMode copy", function()
			local manager = TableManager.new({
				Players = {
					A = {},
					B = {},
				},
			}, { DuplicateReferenceMode = "copy" })

			manager:Set("Players.*.Loadout", { Weapon = "Sword" })

			expect(manager.Raw.Players.A.Loadout).never_is(manager.Raw.Players.B.Loadout)
			expect(manager.Raw.Players.A.Loadout.Weapon).is("Sword")
			expect(manager.Raw.Players.B.Loadout.Weapon).is("Sword")
			manager:Destroy()
		end)

		test("errors when combined with buildTablesDynamically", function()
			local manager = TableManager.new { Players = {} }

			expect(function()
				manager:Set("Players.*.Health", 100, true)
			end).fails_with("Cannot build tables dynamically")

			manager:Destroy()
		end)

		test("errors when a literal prefix segment is not a table", function()
			local manager = TableManager.new { Player = { Name = "Alice" } }

			expect(function()
				manager:Set("Player.Name.*", 1)
			end).fails_with("Path segment Name is not a table")

			manager:Destroy()
		end)

		test("a literal '*' data key can no longer be written (reserved segment)", function()
			local manager = TableManager.new { cfg = {} }

			-- Previously this wrote the literal key "*"; it is now a
			-- zero-match wildcard no-op.
			manager:Set("cfg.*", 5)

			expect(manager.Raw.cfg["*"]).is(nil)
			manager:Destroy()
		end)

		test("wildcard over an array writes every index", function()
			local manager = TableManager.new { scores = { 10, 20, 30 } }

			manager:Set("scores.*", 0)

			expect(manager.Raw.scores).is_shallow_equal { 0, 0, 0 }
			manager:Destroy()
		end)
	end)

	describe("Method: Update (wildcard paths)", function()
		test("runs the updater once per match with that path's current value", function()
			local manager = TableManager.new {
				Players = {
					A = { Health = 10 },
					B = { Health = 20 },
				},
			}

			local result = manager:Update("Players.*.Health", function(health)
				return health + 1
			end)

			expect(result).is(nil)
			expect(manager.Raw.Players.A.Health).is(11)
			expect(manager.Raw.Players.B.Health).is(21)
			manager:Destroy()
		end)

		test("only visits existing values (missing final keys are skipped)", function()
			local manager = TableManager.new {
				Players = {
					A = { Health = 10 },
					B = {}, -- no Health: updater must not run for B
				},
			}

			local callCount = 0
			manager:Update("Players.*.Health", function(health)
				callCount += 1
				return health + 1
			end)

			expect(callCount).is(1)
			expect(manager.Raw.Players.A.Health).is(11)
			expect(manager.Raw.Players.B.Health).is(nil)
			manager:Destroy()
		end)

		test("supports multiple wildcards", function()
			local manager = TableManager.new {
				Players = {
					A = { Stats = { Str = 1, Dex = 2 } },
					B = { Stats = { Str = 3 } },
				},
			}

			manager:Update("Players.*.Stats.*", function(stat)
				return stat * 2
			end)

			expect(manager.Raw.Players.A.Stats.Str).is(2)
			expect(manager.Raw.Players.A.Stats.Dex).is(4)
			expect(manager.Raw.Players.B.Stats.Str).is(6)
			manager:Destroy()
		end)

		test("batches multi-path writes into one coherent flush", function()
			local manager = TableManager.new {
				Players = {
					A = { Health = 1 },
					B = { Health = 2 },
				},
			}

			local observedDuringFirstFire = nil
			manager:OnValueChange({ "Players", "*", "Health" }, function()
				if observedDuringFirstFire == nil then
					-- By the time ANY listener fires, every write has landed.
					observedDuringFirstFire = manager.Raw.Players.A.Health == 100
						and manager.Raw.Players.B.Health == 100
				end
			end)

			manager:Update("Players.*.Health", function()
				return 100
			end)

			expect(observedDuringFirstFire).is_true()
			manager:Destroy()
		end)

		test("passes the matched key and concrete path for a single wildcard", function()
			local manager = TableManager.new {
				Players = {
					A = { Health = 10 },
					B = { Health = 20 },
				},
			}

			local matchesByPlayer: { [any]: { any } } = {}
			local pathsByPlayer: { [any]: { any } } = {}
			manager:Update("Players.*.Health", function(health, matches, path)
				local resolvedMatches = matches :: { any }
				local playerId = resolvedMatches[1]
				matchesByPlayer[playerId] = resolvedMatches
				pathsByPlayer[playerId] = path :: { any }
				return health
			end)

			-- One match entry per "*"; the concrete path carries the matched key.
			expect(#matchesByPlayer.A).is(1)
			expect(matchesByPlayer.A[1]).is("A")
			expect(pathsByPlayer.A).is_shallow_equal { "Players", "A", "Health" }
			expect(pathsByPlayer.B).is_shallow_equal { "Players", "B", "Health" }
			manager:Destroy()
		end)

		test("passes both matched keys (left-to-right) for multiple wildcards", function()
			local manager = TableManager.new {
				Players = {
					A = { Stats = { Str = 1 } },
				},
			}

			local seen: { any } = {}
			local seenPath: { any } = {}
			manager:Update("Players.*.Stats.*", function(stat, matches, path)
				seen = matches :: { any }
				seenPath = path :: { any }
				return stat
			end)

			expect(#seen).is(2)
			expect(seen[1]).is("A") -- first "*"
			expect(seen[2]).is("Str") -- second "*"
			expect(seenPath).is_shallow_equal { "Players", "A", "Stats", "Str" }
			manager:Destroy()
		end)

		test("a non-wildcard Update receives nil for matches and path", function()
			local manager = TableManager.new { Player = { Health = 10 } }

			local sawMatches: any = "unset"
			local sawPath: any = "unset"
			manager:Update("Player.Health", function(health, matches, path)
				sawMatches = matches
				sawPath = path
				return health + 1
			end)

			expect(sawMatches).is(nil)
			expect(sawPath).is(nil)
			expect(manager.Raw.Player.Health).is(11)
			manager:Destroy()
		end)
	end)

	describe("Method: Increment (wildcard paths)", function()
		test("adds the delta to every matched value and returns nil", function()
			local manager = TableManager.new {
				Players = {
					A = { Health = 10 },
					B = { Health = 20 },
				},
			}

			local result = manager:Increment("Players.*.Health", 5)

			expect(result).is(nil)
			expect(manager.Raw.Players.A.Health).is(15)
			expect(manager.Raw.Players.B.Health).is(25)
			manager:Destroy()
		end)

		test("zero matches is a no-op", function()
			local manager = TableManager.new { Players = {} }

			expect(function()
				manager:Increment("Players.*.Health", 5)
			end).never_fails()

			manager:Destroy()
		end)

		test("errors when a matched value is not addable", function()
			local manager = TableManager.new {
				Players = {
					A = { Health = 10 },
					B = { Health = {} }, -- not addable
				},
			}

			expect(function()
				manager:Increment("Players.*.Health", 5)
			end).fails_with("attempt to perform arithmetic")

			manager:Destroy()
		end)
	end)

	describe("Method: GetMatching", function()
		test("returns one record per match with Path, Value, and WildcardMatches", function()
			local manager = TableManager.new {
				Players = {
					A = { Health = 10 },
					B = { Health = 20 },
				},
			}

			local entries = manager:GetMatching("Players.*.Health")
			expect(#entries).is(2)

			local valuesByPlayer = {}
			for _, entry in entries do
				expect(#entry.Path).is(3)
				expect(entry.Path[1]).is("Players")
				expect(entry.Path[3]).is("Health")
				expect((entry.WildcardMatches :: { any })[1]).is(entry.Path[2])
				valuesByPlayer[entry.Path[2]] = entry.Value
			end
			expect(valuesByPlayer).is_shallow_equal { A = 10, B = 20 }
			manager:Destroy()
		end)

		test("multiple wildcards report one match entry per '*', left-to-right", function()
			local manager = TableManager.new {
				Players = {
					A = { Stats = { Str = 1, Dex = 2 } },
					B = { Stats = { Str = 3 } },
				},
			}

			local entries = manager:GetMatching("Players.*.Stats.*")
			expect(#entries).is(3)
			for _, entry in entries do
				local matches = entry.WildcardMatches :: { any }
				expect(#matches).is(2)
				expect(entry.Value).is(manager.Raw.Players[matches[1]].Stats[matches[2]])
			end
			manager:Destroy()
		end)

		test("only reports existing values", function()
			local manager = TableManager.new {
				Players = {
					A = { Health = 10 },
					B = {}, -- no Health
				},
			}

			local entries = manager:GetMatching("Players.*.Health")
			expect(#entries).is(1)
			expect(entries[1].Path).is_shallow_equal { "Players", "A", "Health" }
			manager:Destroy()
		end)

		test("zero matches returns an empty array", function()
			local manager = TableManager.new { Players = {} }
			expect(#manager:GetMatching("Players.*.Health")).is(0)
			manager:Destroy()
		end)

		test("a wildcard-free path yields a single record with no WildcardMatches", function()
			local manager = TableManager.new { Player = { Health = 10 } }

			local entries = manager:GetMatching("Player.Health")
			expect(#entries).is(1)
			expect(entries[1].Value).is(10)
			expect(entries[1].Path).is_shallow_equal { "Player", "Health" }
			expect(entries[1].WildcardMatches).is(nil)
			manager:Destroy()
		end)

		test("a wildcard-free path to a missing value yields an empty array", function()
			local manager = TableManager.new { Player = { Health = 10 } }
			expect(#manager:GetMatching("Player.Missing")).is(0)
			manager:Destroy()
		end)

		test("errors when a literal prefix segment is not a table, matching Get", function()
			local manager = TableManager.new { Player = { Name = "Alice" } }

			expect(function()
				manager:GetMatching("Player.Name.*")
			end).fails_with("Path segment Name is not a table")

			manager:Destroy()
		end)
	end)
end

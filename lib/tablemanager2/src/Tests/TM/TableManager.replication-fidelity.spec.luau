--!strict
--[[
	Proves that tablemanager2's listener output (the public Signals, and
	separately the metadata.OriginDiff tree) carries enough deterministic,
	self-contained information to reconstruct an independent TableManager's
	state via ReplicationHarness.

	The full matrix runs once per feed mode ("signals" and "diff") to prove
	each is independently sufficient.

	Out of scope (by design):
	- NaN values: NaN ~= NaN breaks both change detection and deep equality,
	  so NaN is not a replicable value and is intentionally untested.
	- ForceNotify beyond the existing scalar-leaf smoke test.

	History: tests marked `FIXME(replication) CONFIRMED` pinned real defects
	(see Docs/REPLICATION-FIDELITY-FINDINGS.md). All confirmed defects have
	since been fixed, including the diff feed's former batch/Swap "channel
	limitation" (resolved by masking tracked arrays out of the batch branch
	diff and tagging array operations with metadata.ArrayOp). Both feeds are
	now expected to converge on the full matrix.
]]

return function(t: tiniest)
	local ReplicationHarness = require("../Helpers/ReplicationHarness")
	local T = require("../../../T")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	local feedModes: { ReplicationHarness.FeedMode } = { "signals", "diff" }

	describe("wire boundary", function()
		test("wireCopy returns a non-identical deep copy of nested tables", function()
			local original = { player = { stats = { health = 100 } } }
			local copy = ReplicationHarness.wireCopy(original)

			expect(copy).never_is(original)
			expect(copy.player).never_is(original.player)
			expect(copy.player.stats).never_is(original.player.stats)
			expect(ReplicationHarness.deepEqual(copy, original)).is_true()
		end)

		test("scalars pass through wireCopy unchanged", function()
			expect(ReplicationHarness.wireCopy(5)).is(5)
			expect(ReplicationHarness.wireCopy("hi")).is("hi")
			expect(ReplicationHarness.wireCopy(true)).is(true)
			expect(ReplicationHarness.wireCopy(nil)).is(nil)
		end)

		test("mutating the replica after apply leaves the source untouched", function()
			local harness = ReplicationHarness.new { player = { health = 100 } }
			harness:Connect()

			harness.Source.Proxy.player.health = 50
			harness.Replica.Proxy.player.health = 999

			expect(harness.Source:Get { "player", "health" }).is(50)

			harness:Destroy()
		end)
	end)

	for _, feedMode in feedModes do
		describe(`feed: {feedMode}`, function()
			describe("scalars", function()
				test("set a new root-level key", function()
					local harness = ReplicationHarness.new({ player = { health = 100 } }, feedMode)
					harness:Connect()

					harness.Source.Proxy.score = 10

					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)

				test("change a nested scalar", function()
					local harness = ReplicationHarness.new({ player = { stats = { health = 100 } } }, feedMode)
					harness:Connect()

					harness.Source.Proxy.player.stats.health = 50

					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)

				test("remove a nested scalar key (set to nil)", function()
					local harness = ReplicationHarness.new({ player = { health = 100, mana = 5 } }, feedMode)
					harness:Connect()

					harness.Source.Proxy.player.mana = nil

					expect(harness:IsConverged()).is_true()
					expect(harness.Replica:Get({ "player", "mana" }, true)).is(nil)
					harness:Destroy()
				end)

				test("falsy values are not mistaken for removal", function()
					local harness = ReplicationHarness.new({ player = { alive = true, gold = 5 } }, feedMode)
					harness:Connect()

					harness.Source.Proxy.player.alive = false
					harness.Source.Proxy.player.gold = 0

					expect(harness:IsConverged()).is_true()
					expect(harness.Replica:Get { "player", "alive" }).is(false)
					expect(harness.Replica:Get { "player", "gold" }).is(0)
					harness:Destroy()
				end)

				test("rewriting the same value emits nothing", function()
					local harness = ReplicationHarness.new({ player = { health = 100 } }, feedMode)
					harness:Connect()

					harness.Source.Proxy.player.health = 100

					expect(harness:OpCount()).is(0)
					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)
			end)

			describe("dictionary keys", function()
				test("add a key holding a nested table wholesale", function()
					local harness = ReplicationHarness.new({ player = { health = 100 } }, feedMode)
					harness:Connect()

					harness.Source.Proxy.settings = { volume = 80, muted = false }

					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)

				test("remove a key holding a nested table", function()
					local harness = ReplicationHarness.new({
						player = { health = 100 },
						settings = { volume = 80, muted = false },
					}, feedMode)
					harness:Connect()

					harness.Source.Proxy.settings = nil

					expect(harness:IsConverged()).is_true()
					expect(harness.Replica:Get({ "settings" }, true)).is(nil)
					harness:Destroy()
				end)

				test("scalar key overwritten with a table", function()
					local harness = ReplicationHarness.new({ value = 5 }, feedMode)
					harness:Connect()

					harness.Source.Proxy.value = { nested = true }

					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)

				test("table key overwritten with a scalar", function()
					local harness = ReplicationHarness.new({ value = { nested = true } }, feedMode)
					harness:Connect()

					harness.Source.Proxy.value = 5

					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)

				test("setting an empty table value yields a table on the replica, not nil", function()
					-- nil -> {} emits an "added" leaf node (formerly defect #1: a
					-- childless descendantChanged node fired nothing).
					local harness = ReplicationHarness.new({ player = { health = 100 } }, feedMode)
					harness:Connect()

					harness.Source.Proxy.inventory = {}

					expect(harness:IsConverged()).is_true()
					expect(type(harness.Replica:Get({ "inventory" }, true))).is("table")
					harness:Destroy()
				end)

				test("table replaced with an identical-content different-reference table converges", function()
					-- Pins current behavior: whether or not TM emits a ref-change
					-- event here, the replica must not diverge.
					local harness = ReplicationHarness.new({ player = { health = 100 } }, feedMode)
					harness:Connect()

					harness.Source.Proxy.player = { health = 100 }

					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)

				test("string key that looks numeric stays distinct from the numeric index", function()
					local harness = ReplicationHarness.new({ dict = { value = 0 } }, feedMode)
					harness:Connect()

					harness.Source.Proxy.dict["1"] = "string-key"
					harness.Source.Proxy.dict[1] = "numeric-key"

					expect(harness:IsConverged()).is_true()
					expect(harness.Replica:Get { "dict", "1" }).is("string-key")
					expect(harness.Replica:Get { "dict", 1 }).is("numeric-key")
					harness:Destroy()
				end)

				test("boolean keys survive the wire", function()
					local harness = ReplicationHarness.new({ flags = { placeholder = 0 } }, feedMode)
					harness:Connect()

					harness.Source.Proxy.flags[true] = "yes"
					harness.Source.Proxy.flags[false] = "no"

					expect(harness:IsConverged()).is_true()
					expect(harness.Replica:Get { "flags", true }).is("yes")
					harness:Destroy()
				end)

				test("empty-string key does not collide with the diff sentinel", function()
					-- Diff's table<->scalar sentinel is a unique userdata (formerly
					-- defect #2: it was "", colliding with genuine "" keys).
					local harness = ReplicationHarness.new({ x = 5 }, feedMode)
					harness:Connect()

					harness.Source.Proxy.x = { [""] = 7 }

					expect(harness:IsConverged()).is_true()
					expect(harness.Replica:Get { "x", "" }).is(7)
					harness:Destroy()
				end)
			end)

			describe("subtree replacement", function()
				test("replacing an existing table drops keys missing from the new table", function()
					local harness = ReplicationHarness.new({ player = { health = 100, mana = 5 } }, feedMode)
					harness:Connect()

					harness.Source.Proxy.player = { health = 50 }

					expect(harness:IsConverged()).is_true()
					expect(harness.Replica:Get({ "player", "mana" }, true)).is(nil)
					harness:Destroy()
				end)

				test("replacing a deeply nested table drops deep keys", function()
					local harness = ReplicationHarness.new({
						a = { b = { c = { keep = 1, drop = 2 } } },
					}, feedMode)
					harness:Connect()

					harness.Source.Proxy.a.b = { c = { keep = 1 } }

					expect(harness:IsConverged()).is_true()
					expect(harness.Replica:Get({ "a", "b", "c", "drop" }, true)).is(nil)
					harness:Destroy()
				end)
			end)

			describe("table<->scalar transitions", function()
				-- Regression guards: the teardown events for an old subtree and
				-- the parent's scalar event used to arrive in nondeterministic
				-- (pairs) order; a consumer that received the scalar first then
				-- errored applying the child removals through a non-table value.
				-- IsConverged() now fails on ANY recorded apply error, so these
				-- assert apply-cleanliness as well as state.
				test("deep table overwritten with a scalar applies cleanly", function()
					local harness = ReplicationHarness.new({
						config = {
							host = "localhost",
							ports = { 80, 443 },
							nested = { deep = { x = 1 } },
						},
					}, feedMode)
					harness:Connect()

					harness.Source.Proxy.config = "disabled"

					expect(#harness:ApplyErrors()).is(0)
					expect(harness:IsConverged()).is_true()
					expect(harness.Replica:Get { "config" }).is("disabled")
					harness:Destroy()
				end)

				test("scalar overwritten with a deep table applies cleanly", function()
					local harness = ReplicationHarness.new({ config = "disabled" }, feedMode)
					harness:Connect()

					harness.Source.Proxy.config = { host = "localhost", nested = { deep = { x = 1 } } }

					expect(#harness:ApplyErrors()).is(0)
					expect(harness:IsConverged()).is_true()
					expect(harness.Replica:Get { "config", "nested", "deep", "x" }).is(1)
					harness:Destroy()
				end)

				test("table to scalar inside a batch applies cleanly", function()
					-- The batch flush runs the same transition diff through
					-- CheckForChangesBetween; sentinel-last ordering must hold
					-- there too.
					local harness = ReplicationHarness.new({
						player = { stats = { str = 5, buffs = { "haste" } }, name = "x" },
					}, feedMode)
					harness:Connect()

					harness.Source:Batch(function()
						harness.Source.Proxy.player.stats = 0
						harness.Source.Proxy.player.name = "y"
					end)

					expect(#harness:ApplyErrors()).is(0)
					expect(harness:IsConverged()).is_true()
					expect(harness.Replica:Get { "player", "stats" }).is(0)
					harness:Destroy()
				end)

				test("scalar to table inside a batch applies cleanly", function()
					local harness = ReplicationHarness.new({ player = { stats = 0 } }, feedMode)
					harness:Connect()

					harness.Source:Batch(function()
						harness.Source.Proxy.player.stats = { str = 5, dex = { base = 2 } }
					end)

					expect(#harness:ApplyErrors()).is(0)
					expect(harness:IsConverged()).is_true()
					expect(harness.Replica:Get { "player", "stats", "dex", "base" }).is(2)
					harness:Destroy()
				end)

				test("Swap of two deep tables applies cleanly", function()
					local harness = ReplicationHarness.new({
						a = { inner = { v = 1, list = { "x" } } },
						b = { other = 2 },
					}, feedMode)
					harness:Connect()

					harness.Source:Swap({ "a" }, { "b" })

					expect(#harness:ApplyErrors()).is(0)
					expect(harness:IsConverged()).is_true()
					expect(harness.Replica:Get { "a", "other" }).is(2)
					expect(harness.Replica:Get { "b", "inner", "v" }).is(1)
					harness:Destroy()
				end)

				test("repeated scalar/table flips at the same key apply cleanly", function()
					local harness = ReplicationHarness.new({ slot = { item = "sword" } }, feedMode)
					harness:Connect()

					harness.Source.Proxy.slot = 0
					harness.Source.Proxy.slot = { item = "shield", mods = { 1, 2 } }
					harness.Source.Proxy.slot = false

					expect(#harness:ApplyErrors()).is(0)
					expect(harness:IsConverged()).is_true()
					expect(harness.Replica:Get { "slot" }).is(false)
					harness:Destroy()
				end)

				if feedMode == "signals" then
					test("teardown events reach the wire before the scalar event", function()
						-- Order assertion at the op-log level: a consumer applying
						-- in receipt order must see every removal UNDER the key
						-- before the scalar write AT the key, or it would apply
						-- them through a non-table value.
						local harness = ReplicationHarness.new({
							config = { host = "localhost", ports = { 80, 443 } },
						}, "signals")
						harness:Connect()

						harness.Source.Proxy.config = "off"

						local sawScalarEvent = false
						for i, entry in (harness :: any)._opLog do
							if entry.Signal ~= "ValueChanged" or entry.Path[1] ~= "config" then
								continue
							end
							if #entry.Path == 1 then
								sawScalarEvent = true
							else
								expect(sawScalarEvent)
									.with_context(`teardown op #{i} arrived after the scalar event`)
									.never_is_true()
							end
						end
						expect(sawScalarEvent).is_true()

						expect(harness:IsConverged()).is_true()
						harness:Destroy()
					end)
				end
			end)

			describe("arrays of scalars", function()
				test("append", function()
					local harness = ReplicationHarness.new({ items = { "a", "b" } }, feedMode)
					harness:Connect()

					harness.Source:ArrayInsert("items", "c")

					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)

				test("insert at index shifts later elements", function()
					local harness = ReplicationHarness.new({ items = { "a", "c" } }, feedMode)
					harness:Connect()

					harness.Source:ArrayInsert("items", 2, "b")

					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)

				test("remove shifts later elements", function()
					local harness = ReplicationHarness.new({ items = { "a", "b", "c" } }, feedMode)
					harness:Connect()

					harness.Source:ArrayRemove("items", 1)

					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)

				test("overwrite an existing index via the proxy", function()
					local harness = ReplicationHarness.new({ items = { "a", "b", "c" } }, feedMode)
					harness:Connect()

					harness.Source.Proxy.items[2] = "B"

					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)

				test("ArraySwapRemove", function()
					local harness = ReplicationHarness.new({ items = { "a", "b", "c", "d" } }, feedMode)
					harness:Connect()

					harness.Source:ArraySwapRemove("items", 1)

					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)

				test("append via direct proxy index write (one past the end)", function()
					local harness = ReplicationHarness.new({ items = { "a", "b" } }, feedMode)
					harness:Connect()

					harness.Source.Proxy.items[3] = "c"

					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)

				test("delete the tail element via proxy nil write", function()
					local harness = ReplicationHarness.new({ items = { "a", "b" } }, feedMode)
					harness:Connect()

					harness.Source.Proxy.items[2] = nil

					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)

				test("nil write in the middle of an array (hole) replicates the hole", function()
					-- A plain nil write is NOT an array op: it arrives without
					-- metadata.ArrayOp and must be applied as a non-shifting Set,
					-- which preserves the hole on both feeds.
					local harness = ReplicationHarness.new({ items = { "a", "b", "c" } }, feedMode)
					harness:Connect()

					harness.Source.Proxy.items[2] = nil

					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)

				test("wholesale replacement that shrinks the array by more than one", function()
					-- A wholesale replacement arrives as one diff delivery whose
					-- numeric removals are applied as non-shifting nil Sets (no
					-- metadata.ArrayOp), so apply order doesn't matter and the
					-- trailing nils truncate the replica's array.
					local harness = ReplicationHarness.new({ items = { "a", "b", "c", "d" } }, feedMode)
					harness:Connect()

					harness.Source.Proxy.items = { "a" }

					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)

				test("nested array path (not root-level)", function()
					local harness = ReplicationHarness.new({
						player = { inventory = { items = { "sword" } } },
					}, feedMode)
					harness:Connect()

					harness.Source:ArrayInsert({ "player", "inventory", "items" }, "shield")
					harness.Source:ArrayRemove({ "player", "inventory", "items" }, 1)

					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)
			end)

			describe("arrays of tables", function()
				test("mutate a field on an array element", function()
					local harness = ReplicationHarness.new({
						items = { { hp = 1 }, { hp = 2 } },
					}, feedMode)
					harness:Connect()

					harness.Source.Proxy.items[1].hp = 99

					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)

				test("insert a table element, shifting later elements", function()
					local harness = ReplicationHarness.new({
						items = { { hp = 1 }, { hp = 3 } },
					}, feedMode)
					harness:Connect()

					harness.Source:ArrayInsert("items", 2, { hp = 2 })

					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)
			end)

			describe("array helper methods", function()
				test("ArrayRemoveFirstValue removes the first match", function()
					local harness = ReplicationHarness.new({ items = { "a", "b", "a" } }, feedMode)
					harness:Connect()

					local index = harness.Source:ArrayRemoveFirstValue("items", "a")

					expect(index).is(1)
					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)

				test("ArrayRemoveFirstValue with no match emits nothing", function()
					local harness = ReplicationHarness.new({ items = { "a", "b" } }, feedMode)
					harness:Connect()

					local index = harness.Source:ArrayRemoveFirstValue("items", "zzz")

					expect(index).is(nil)
					expect(harness:OpCount()).is(0)
					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)

				test("ArraySwapRemoveFirstValue removes the first match", function()
					local harness = ReplicationHarness.new({ items = { "a", "b", "c", "d" } }, feedMode)
					harness:Connect()

					local index = harness.Source:ArraySwapRemoveFirstValue("items", "b")

					expect(index).is(2)
					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)

				test("ArraySwapRemoveFirstValue with no match emits nothing", function()
					local harness = ReplicationHarness.new({ items = { "a", "b" } }, feedMode)
					harness:Connect()

					local index = harness.Source:ArraySwapRemoveFirstValue("items", "zzz")

					expect(index).is(nil)
					expect(harness:OpCount()).is(0)
					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)
			end)

			describe("structural methods", function()
				-- Swap/MoveTo run an internal Batch; their flush deliveries are
				-- masked + ArrayOp-tagged like any other batch (see findings doc).
				test("MoveTo relocates a table between branches", function()
					local harness = ReplicationHarness.new({
						player = { stats = { str = 5, dex = 3 } },
						archive = { placeholder = 0 },
					}, feedMode)
					harness:Connect()

					harness.Source:MoveTo({ "player", "stats" }, { "archive", "stats" })

					expect(harness:IsConverged()).is_true()
					expect(harness.Replica:Get({ "player", "stats" }, true)).is(nil)
					expect(harness.Replica:Get { "archive", "stats", "str" }).is(5)
					harness:Destroy()
				end)

				test("CopyTo deep-copies; later source mutations do not leak into the copy", function()
					local harness = ReplicationHarness.new({
						template = { cost = 5 },
						slots = { placeholder = 0 },
					}, feedMode)
					harness:Connect()

					harness.Source:CopyTo({ "template" }, { "slots", "copy" })
					expect(harness:IsConverged()).is_true()

					harness.Source.Proxy.template.cost = 9

					expect(harness:IsConverged()).is_true()
					expect(harness.Replica:Get { "slots", "copy", "cost" }).is(5)
					expect(harness.Replica:Get { "template", "cost" }).is(9)
					harness:Destroy()
				end)

				test("Swap exchanges two tables in different branches", function()
					local harness = ReplicationHarness.new({
						a = { v = 1 },
						b = { v = 2 },
					}, feedMode)
					harness:Connect()

					harness.Source:Swap({ "a" }, { "b" })

					expect(harness:IsConverged()).is_true()
					expect(harness.Replica:Get { "a", "v" }).is(2)
					expect(harness.Replica:Get { "b", "v" }).is(1)
					harness:Destroy()
				end)

				test("Swap exchanges a scalar with a table", function()
					local harness = ReplicationHarness.new({
						a = 5,
						b = { v = 2 },
					}, feedMode)
					harness:Connect()

					harness.Source:Swap({ "a" }, { "b" })

					expect(harness:IsConverged()).is_true()
					expect(harness.Replica:Get { "b" }).is(5)
					expect(harness.Replica:Get { "a", "v" }).is(2)
					harness:Destroy()
				end)

				test("Swap exchanges two elements of the same array", function()
					local harness = ReplicationHarness.new({ items = { "a", "b", "c" } }, feedMode)
					harness:Connect()

					harness.Source:Swap({ "items", 1 }, { "items", 3 })

					expect(harness:IsConverged()).is_true()
					expect(harness.Replica:Get { "items", 1 }).is("c")
					expect(harness.Replica:Get { "items", 3 }).is("a")
					harness:Destroy()
				end)

				test("Set with buildTablesDynamically creates intermediate tables", function()
					-- The missing path is built as ONE subtree assigned through the
					-- proxy in a single write (formerly: level-by-level raw writes
					-- that bypassed change detection entirely).
					local harness = ReplicationHarness.new({ existing = 1 }, feedMode)
					harness:Connect()

					harness.Source:Set({ "a", "b", "c" }, 5, true)

					expect(harness:IsConverged()).is_true()
					expect(harness.Replica:Get { "a", "b", "c" }).is(5)
					harness:Destroy()
				end)
			end)

			describe("batch", function()
				-- Batch flush contract: the non-array flush masks tracked-array
				-- subtrees out of each branch diff, so array changes reach
				-- consumers exactly once — via the array flush's ArrayOp-tagged
				-- per-op deliveries. Both feeds converge on every case below.
				test("multiple mixed operations in one Batch converge", function()
					local harness = ReplicationHarness.new({
						player = { health = 100, mana = 5 },
						items = { "a", "b" },
					}, feedMode)
					harness:Connect()

					harness.Source:Batch(function()
						harness.Source.Proxy.player.health = 50
						harness.Source.Proxy.player.mana = nil
						harness.Source.Proxy.settings = { volume = 80 }
						harness.Source:ArrayInsert("items", "c")
						harness.Source:ArrayRemove("items", 1)
					end)

					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)

				test("array created inside the batch then inserted into", function()
					-- Arrays created during a batch are pruned from TrackedPaths at
					-- flush, so their creation flows ONLY through the non-array
					-- flush as ordinary adds (formerly defect #4: both phases fired).
					local harness = ReplicationHarness.new({ existing = 1 }, feedMode)
					harness:Connect()

					harness.Source:Batch(function()
						harness.Source.Proxy.newItems = {}
						harness.Source:ArrayInsert("newItems", "a")
						harness.Source:ArrayInsert("newItems", "b")
					end)

					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)

				test("ArrayInsert of a table element inside a Batch", function()
					-- The tracked array (including its elements' string-keyed
					-- fields) is masked out of the non-array flush; only the array
					-- flush's ArrayInserted reaches consumers.
					local harness = ReplicationHarness.new({ items = { { hp = 1 } } }, feedMode)
					harness:Connect()

					harness.Source:Batch(function()
						harness.Source:ArrayInsert("items", 1, { hp = 7 })
					end)

					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)

				test("direct index write in a batch routes through LCS and converges", function()
					local harness = ReplicationHarness.new({ items = { "a", "b", "c" } }, feedMode)
					harness:Connect()

					harness.Source:Batch(function()
						harness.Source.Proxy.items[2] = "X"
						harness.Source:ArrayInsert("items", "d")
						harness.Source:ArrayRemove("items", 1)
					end)

					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)

				test("whole array replaced inside a batch then mutated", function()
					-- A mid-batch reference replacement is captured by the pre-batch
					-- snapshot, so the {a,b}->{x,y} transition is emitted in full via
					-- LCS (formerly defect #5: only the trailing insert emitted).
					local harness = ReplicationHarness.new({ items = { "a", "b" } }, feedMode)
					harness:Connect()

					harness.Source:Batch(function()
						harness.Source.Proxy.items = { "x" }
						harness.Source:ArrayInsert("items", "y")
					end)

					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)

				test("array removed entirely inside a batch after being mutated", function()
					local harness = ReplicationHarness.new({ items = { "a" } }, feedMode)
					harness:Connect()

					harness.Source:Batch(function()
						harness.Source:ArrayInsert("items", "b")
						harness.Source.Proxy.items = nil
					end)

					expect(harness:IsConverged()).is_true()
					expect(harness.Replica:Get({ "items" }, true)).is(nil)
					harness:Destroy()
				end)

				test("pure move (remove + reinsert same value) reaches the wire as a remove/insert pair", function()
					local harness = ReplicationHarness.new({ items = { "a", "b", "c" } }, feedMode)
					harness:Connect()

					harness.Source:Batch(function()
						harness.Source:ArrayRemove("items", 1)
						harness.Source:ArrayInsert("items", 3, "a")
					end)

					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)

				test("ArraySwapRemove inside a batch", function()
					-- LCS sees Set@index then Remove@lastIndex, mirroring the actual
					-- mutation and the non-batched emission order.
					local harness = ReplicationHarness.new({ items = { "a", "b", "c", "d" } }, feedMode)
					harness:Connect()

					harness.Source:Batch(function()
						harness.Source:ArraySwapRemove("items", 1)
					end)

					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)

				test("two arrays and a scalar branch mutated in one batch", function()
					local harness = ReplicationHarness.new({
						player = { inventory = { items = { "a" } } },
						scores = { 1, 2 },
						name = "x",
					}, feedMode)
					harness:Connect()

					harness.Source:Batch(function()
						harness.Source:ArrayInsert({ "player", "inventory", "items" }, "b")
						harness.Source:ArrayRemove("scores", 1)
						harness.Source.Proxy.name = "y"
					end)

					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)

				test("net-zero batch emits nothing", function()
					local harness = ReplicationHarness.new({ items = { "a" } }, feedMode)
					harness:Connect()

					harness.Source:Batch(function()
						harness.Source:ArrayInsert("items", "b")
						harness.Source:ArrayRemove("items", 2)
					end)

					expect(harness:OpCount()).is(0)
					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)

				test("element field mutation plus a shift of the same array in one batch", function()
					-- An in-place element interior write is captured by the pre-batch
					-- snapshot, so LCS re-emits the changed element as a whole-value
					-- op at its post-shift index; the non-array flush is masked out.
					local harness = ReplicationHarness.new({ items = { { hp = 1 } } }, feedMode)
					harness:Connect()

					harness.Source:Batch(function()
						harness.Source.Proxy.items[1].hp = 99
						harness.Source:ArrayInsert("items", 1, { id = "new" })
					end)

					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)
			end)

			describe("ForceNotify", function()
				test("does not corrupt the replica", function()
					local harness = ReplicationHarness.new({ player = { health = 100 } }, feedMode)
					harness:Connect()

					harness.Source.Proxy.player.health = 50
					harness.Source:ForceNotify("player.health")

					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)
			end)

			describe("ambiguity", function()
				--[[
					Shifting array ops are distinguished from plain numeric key
					writes by metadata.ArrayOp, so the diff feed no longer guesses:
					an added-at-numeric-leaf entry WITHOUT ArrayOp is always a
					non-shifting Set. These tests pin that boundary/sparse numeric
					dictionary writes converge under that rule.
				]]
				test("sparse numeric dictionary keys converge", function()
					local harness = ReplicationHarness.new({ lookup = { [1] = "a", [3] = "c" } }, feedMode)
					harness:Connect()

					harness.Source.Proxy.lookup[2] = "b"

					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)

				test("boundary numeric key add on an array-like table converges", function()
					local harness = ReplicationHarness.new({ lookup = { [1] = "a" } }, feedMode)
					harness:Connect()

					harness.Source.Proxy.lookup[2] = "b"

					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)
			end)

			describe("schema validation", function()
				test("rejected writes emit nothing and leave the replica untouched", function()
					local harness = ReplicationHarness.new({ player = { health = 100 }, items = { "a" } }, feedMode, {
						Schema = T.interface {
							player = T.interface { health = T.number },
							items = T.array(T.string),
						},
						OnValidationFailed = function() end,
					})
					harness:Connect()

					harness.Source.Proxy.player.health = "not-a-number"
					harness.Source:ArrayInsert("items", 12345)

					expect(harness:OpCount()).is(0)
					expect(harness:IsConverged()).is_true()
					expect(harness.Replica:Get { "player", "health" }).is(100)
					harness:Destroy()
				end)
			end)

			describe("late join", function()
				test("replica seeded from a mid-stream snapshot stays converged", function()
					local harness = ReplicationHarness.new({ player = { health = 100 }, items = { "a" } }, feedMode)

					-- Mutations BEFORE the replica connects (a client not yet joined).
					harness.Source.Proxy.player.health = 75
					harness.Source:ArrayInsert("items", "b")
					harness.Source.Proxy.session = { id = "abc" }

					-- Join: snapshot, then stream.
					harness:ResyncReplica()
					harness:Connect()

					harness.Source.Proxy.player.health = 50
					harness.Source:ArrayRemove("items", 1)
					harness.Source.Proxy.session = nil

					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)
			end)

			describe("re-entrant mutation", function()
				test("a source listener that clamps during notification", function()
					-- Re-entrant writes are queued by ChangeDetector and dispatched
					-- AFTER the outer write's events, so consumers applying in
					-- receipt order see -50 then the clamp to 0 on both feeds.
					local harness = ReplicationHarness.new({ player = { health = 100 } }, feedMode)
					harness:Connect()

					harness.Source:OnValueChange("player.health", function(newValue)
						if type(newValue) == "number" and newValue < 0 then
							harness.Source:Set({ "player", "health" }, 0)
						end
					end)

					harness.Source.Proxy.player.health = -50

					expect(harness.Source:Get { "player", "health" }).is(0)
					expect(harness:IsConverged()).is_true()
					harness:Destroy()
				end)
			end)
		end)
	end

	describe("echo order (signals feed)", function()
		--[[
			The replica must not only converge - it must RE-EMIT an equivalent
			event stream in the same order, since the rebuilt TableReplicator's
			client-side listeners hang off the replica's own signals.
			EchoMatches compares normalized state-bearing ops (see harness notes;
			a replica can only re-emit ArraySet as ValueChanged via :Set).
		]]
		local function echoTest(name: string, initialData: any, mutate: (harness: any) -> ())
			test(name, function()
				local harness = ReplicationHarness.new(initialData, "signals")
				harness:Connect()

				mutate(harness)

				expect(harness:IsConverged()).is_true()
				expect(harness:EchoMatches()).is_true()
				harness:Destroy()
			end)
		end

		echoTest("scalar set", { player = { health = 100 } }, function(harness)
			harness.Source.Proxy.player.health = 50
		end)

		echoTest("nested key removal", { player = { health = 100, mana = 5 } }, function(harness)
			harness.Source.Proxy.player.mana = nil
		end)

		echoTest("subtree replacement", { player = { health = 100, mana = 5 } }, function(harness)
			harness.Source.Proxy.player = { health = 50, stamina = 10 }
		end)

		echoTest("array insert in the middle", { items = { "a", "c" } }, function(harness)
			harness.Source:ArrayInsert("items", 2, "b")
		end)

		echoTest("array remove", { items = { "a", "b", "c" } }, function(harness)
			harness.Source:ArrayRemove("items", 2)
		end)

		echoTest("ArraySwapRemove", { items = { "a", "b", "c", "d" } }, function(harness)
			harness.Source:ArraySwapRemove("items", 1)
		end)

		echoTest("mixed batch", {
			player = { health = 100, mana = 5 },
			items = { "a", "b" },
		}, function(harness)
			harness.Source:Batch(function()
				harness.Source.Proxy.player.health = 50
				harness.Source.Proxy.player.mana = nil
				harness.Source:ArrayInsert("items", "c")
				harness.Source:ArrayRemove("items", 1)
			end)
		end)
	end)

	describe("deferred listeners (smoke)", function()
		test("a deferred-mode source still converges after the scheduler drains", function()
			local harness = ReplicationHarness.new({ player = { health = 100 }, items = { "a" } }, "signals", {
				ListenerFireMode = "Deferred",
			})
			harness:Connect()

			harness.Source.Proxy.player.health = 50
			harness.Source:ArrayInsert("items", "b")

			task.wait()

			expect(harness:IsConverged()).is_true()
			expect(harness:EchoMatches()).is_true()
			harness:Destroy()
		end)
	end)

	describe("per-step convergence", function()
		test("every individual operation in a long mixed sequence converges", function()
			for _, feedMode in feedModes do
				local harness = ReplicationHarness.new({
					player = { health = 100, mana = 5 },
					items = { "a", "b" },
				}, feedMode)
				harness:Connect()

				local steps: { () -> () } = {
					function()
						harness.Source.Proxy.player.health = 50
					end,
					function()
						harness.Source.Proxy.player.buffs = { "haste" }
					end,
					function()
						harness.Source:ArrayInsert("items", 1, "z")
					end,
					function()
						harness.Source:ArraySwapRemove("items", 1)
					end,
					function()
						harness.Source.Proxy.player = { health = 1 }
					end,
					function()
						harness.Source:Batch(function()
							harness.Source.Proxy.player.health = 2
							harness.Source:ArrayInsert("items", "w")
						end)
					end,
					function()
						harness.Source.Proxy.items = nil
					end,
				}

				for i, step in steps do
					expect(harness:Step(step)).with_context(`feed={feedMode} step={i}`).is_true()
				end

				harness:Destroy()
			end
		end)
	end)
end

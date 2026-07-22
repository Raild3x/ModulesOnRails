--!strict
--[[
	Unit tests for BatchUtils — the pure batch-tracking + snapshot-navigation
	helpers. Snapshot inputs are hand-built to the shape ChangeDetector produces
	(`{ Data = <Diff.Snapshot node> }`, each node carrying `value`, `ref`, and
	`children`) so the navigation helpers can be exercised in isolation, and a
	minimal stub `manager` drives BuildOldSnapshot's SnapshotRootFor gate.
]]

return function(t: tiniest)
	local BatchUtils = require("../Batching/BatchUtils")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	-- Builds a ChangeDetector.Snapshot-shaped object from a nested spec where
	-- each node is `{ value = ..., ref = ..., children = { key = <node> } }`.
	local function makeSnapshot(dataNode: any)
		return { Data = dataNode } :: any
	end

	-- A stub manager exposing only the two fields BuildOldSnapshot reads:
	-- SnapshotRootFor (coverage gate + snapshot root path) and GetOpaqueCtx.
	local function makeManager(rootPath: { any }?, ctx: any?)
		return {
			_listenerRegistry = {
				SnapshotRootFor = function(_self: any, _basePath: { any })
					return rootPath
				end,
			},
			_changeDetector = {
				GetOpaqueCtx = function(_self: any)
					return ctx
				end,
			},
		} :: any
	end

	describe("CreateAncestorSnapshot", function()
		test("wraps the root table without copying", function()
			local root = { a = 1 }
			local snap = BatchUtils.CreateAncestorSnapshot(root)
			expect(snap.RootTable).is(root)
		end)
	end)

	describe("SerializeBatchPath", function()
		test("an empty path serializes to the __root__ sentinel", function()
			expect(BatchUtils.SerializeBatchPath({})).is("__root__")
		end)

		test("segments are joined by a NUL separator", function()
			expect(BatchUtils.SerializeBatchPath({ "a", "b" })).is("a\0b")
		end)

		test("non-string segments are stringified", function()
			expect(BatchUtils.SerializeBatchPath({ "items", 2 })).is("items\0" .. "2")
		end)

		test("distinct paths never collide on the same key", function()
			local ab = BatchUtils.SerializeBatchPath({ "a", "b" })
			local a_b = BatchUtils.SerializeBatchPath({ "a.b" })
			expect(ab == a_b).is(false)
		end)
	end)

	describe("GetSnapshotValue / GetSnapshotRef", function()
		test("navigates children and returns the stored value", function()
			local ref = { live = true }
			local snapshot = makeSnapshot({
				children = {
					player = {
						children = {
							level = { value = 5, ref = ref },
						},
					},
				},
			})
			expect(BatchUtils.GetSnapshotValue(snapshot, { "player", "level" })).is(5)
			expect(BatchUtils.GetSnapshotRef(snapshot, { "player", "level" })).is(ref)
		end)

		test("the root node (empty path) returns the Data node's value/ref", function()
			local ref = {}
			local snapshot = makeSnapshot({ value = "root", ref = ref, children = {} })
			expect(BatchUtils.GetSnapshotValue(snapshot, {})).is("root")
			expect(BatchUtils.GetSnapshotRef(snapshot, {})).is(ref)
		end)

		test("returns nil when a segment is missing", function()
			local snapshot = makeSnapshot({ children = { player = { children = {} } } })
			expect(BatchUtils.GetSnapshotValue(snapshot, { "player", "missing" })).is(nil)
			expect(BatchUtils.GetSnapshotRef(snapshot, { "player", "missing" })).is(nil)
		end)

		test("returns nil when navigation runs off the end of a leaf", function()
			-- "level" has no children table, so descending past it yields nil.
			local snapshot = makeSnapshot({
				children = { level = { value = 5 } },
			})
			expect(BatchUtils.GetSnapshotValue(snapshot, { "level", "deeper" })).is(nil)
		end)

		test("a node with a nil value yields nil", function()
			local snapshot = makeSnapshot({ children = { flag = { value = nil, ref = nil } } })
			expect(BatchUtils.GetSnapshotValue(snapshot, { "flag" })).is(nil)
		end)
	end)

	describe("BuildOldSnapshot", function()
		test("returns nil when no listener covers the path", function()
			local manager = makeManager(nil)
			expect(BatchUtils.BuildOldSnapshot(manager, { "a" }, 1, true)).is(nil)
		end)

		test("alreadyFrozen slices the value at the root path without copying", function()
			-- basePath {"a"} but the snapshot root descends to {"a","b"}, so the
			-- value must be navigated down one level.
			local manager = makeManager({ "a", "b" })
			local oldValue = { b = { c = 3 } }
			local result = BatchUtils.BuildOldSnapshot(manager, { "a" }, oldValue, true)
			expect(result).exists()
			expect((result :: any).Value).is(oldValue.b)
			expect((result :: any).RootPath[2]).is("b")
		end)

		test("navigation stops at nil when an intermediate value is not a table", function()
			-- root path is deeper than the value's actual table depth.
			local manager = makeManager({ "a", "b", "c" })
			local oldValue = { b = 5 } -- b is a scalar, so descent to c hits a non-table
			local result = BatchUtils.BuildOldSnapshot(manager, { "a" }, oldValue, true)
			expect(result).exists()
			expect((result :: any).Value).is(nil)
		end)

		test("without alreadyFrozen it snapshots (deep-copies) the value", function()
			local manager = makeManager({ "a" }) -- root == base, no navigation
			local oldValue = { nested = { x = 1 } }
			local result = BatchUtils.BuildOldSnapshot(manager, { "a" }, oldValue, false)
			expect(result).exists()
			-- Diff.snapshot produces an independent copy, not the same reference.
			expect((result :: any).Value == oldValue).is(false)
			expect((result :: any).Value.nested.x).is(1)
		end)
	end)

	describe("BuildOldSnapshotForLeaf", function()
		test("returns nil when the gate path is not covered", function()
			local manager = makeManager(nil)
			expect(BatchUtils.BuildOldSnapshotForLeaf(manager, { "arr" }, { "arr", 1 }, "v")).is(nil)
		end)

		test("snapshots the leaf value and uses leafPath as the root path", function()
			local manager = makeManager({ "arr" })
			local result = BatchUtils.BuildOldSnapshotForLeaf(manager, { "arr" }, { "arr", 2 }, "hello")
			expect(result).exists()
			expect((result :: any).Value).is("hello")
			expect((result :: any).RootPath[1]).is("arr")
			expect((result :: any).RootPath[2]).is(2)
		end)
	end)

	describe("GetBatchBranchKey", function()
		test("returns the first segment of a path", function()
			expect(BatchUtils.GetBatchBranchKey({ "player", "level" })).is("player")
		end)

		test("returns the __root__ sentinel for an empty path", function()
			expect(BatchUtils.GetBatchBranchKey({})).is("__root__")
		end)
	end)

	describe("MarkBatchBranchDirty", function()
		test("no-ops when batch is nil", function()
			-- Should not error.
			BatchUtils.MarkBatchBranchDirty(nil, { "a" })
			expect(true).is_true()
		end)

		test("marks the top-level branch dirty", function()
			local batch = {
				StartSnapshot = {} :: any,
				TrackedPaths = {},
				DirtyBranches = {},
				PendingPrunes = {},
				Flushing = false,
			}
			BatchUtils.MarkBatchBranchDirty(batch, { "player", "level" })
			expect(batch.DirtyBranches.player).is_true()
		end)
	end)

	describe("EnsureBatchPathTracking", function()
		local function newBatch()
			return {
				StartSnapshot = {} :: any,
				TrackedPaths = {},
				DirtyBranches = {},
				PendingPrunes = {},
				Flushing = false,
			}
		end

		test("records a cloned copy of the path", function()
			local batch = newBatch()
			local path = { "a", "b" }
			BatchUtils.EnsureBatchPathTracking(batch, path)
			local key = BatchUtils.SerializeBatchPath(path)
			expect(batch.TrackedPaths[key]).exists()
			expect(batch.TrackedPaths[key] == path).is(false) -- cloned, not aliased
		end)

		test("is idempotent for the same path", function()
			local batch = newBatch()
			BatchUtils.EnsureBatchPathTracking(batch, { "a" })
			local first = batch.TrackedPaths[BatchUtils.SerializeBatchPath({ "a" })]
			BatchUtils.EnsureBatchPathTracking(batch, { "a" })
			local second = batch.TrackedPaths[BatchUtils.SerializeBatchPath({ "a" })]
			expect(first).is(second) -- second call returned early, did not replace
		end)
	end)
end

--!strict

--[[
	Performance smoke-tests for TableManager's public API.

	This suite is report-only: a test passes if it runs without erroring. The
	`tiniest_time` plugin already annotates each test's wall-clock duration, and
	`bench` below additionally prints a steady-state µs/op figure for the timed
	region specifically (excluding setup/warmup). There are no pass/fail timing
	thresholds -- read the printed numbers and compare them across runs/changes.

	Tests are grouped by the dimension that matters for that method (depth,
	breadth, array size, listener fan-out, batched vs immediate, etc.) so a
	regression in one dimension is easy to spot.

	`perfTest(title, opts)` is the workhorse every benchmark below goes
	through: it registers `test(title, ...)` and runs `bench(opts)` inside it,
	threading `title` through for the printed µs/op line. Families of nearly
	identical benchmarks (varying only by depth, listener count, method name,
	etc.) are built as small local generator functions on top of `perfTest`
	rather than copy-pasted.
]]

return function(t: tiniest)
	local TableManager = require("../../TableManager")

	local test = t.test
	local describe = t.describe

	local ITERATIONS = 5000
	local WARMUP = 100
	local PRINT_PER_OP_AVERAGES = true

	--------------------------------------------------------------------------------
	--// Bench helpers //--
	--------------------------------------------------------------------------------

	type BenchOpts = {
		setup: (() -> any)?,
		action: (i: number, ctx: any) -> (),
		teardown: ((ctx: any) -> ())?,
		iters: number?,
		title: string?,
	}

	-- Runs `setup()` once (its cost amortizes away over many iterations), a short
	-- warmup pass, then `iters` timed iterations of `action`, then `teardown`.
	local function bench(opts: BenchOpts)
		local ctx = if opts.setup then opts.setup() else nil
		local action = opts.action
		local n = opts.iters or ITERATIONS

		for i = 1, WARMUP do
			action(i, ctx)
		end

        const times: {number} = {}
		for i = 1, n do
            const start = os.clock()
			action(i, ctx)
            const elapsed = os.clock() - start
            table.insert(times, elapsed)
		end
		table.sort(times)
        -- prune top and bottom 5% of samples to reduce noise
        const pruneCount = math.floor(n * 0.05)
        const prunedTimes = table.move(times, pruneCount + 1, n - pruneCount, 1, {}) :: {number}
        local total = 0
        for _, t in prunedTimes do
            total += t
        end
        local avg = total / #prunedTimes

		if opts.teardown then
			opts.teardown(ctx)
		end

		if PRINT_PER_OP_AVERAGES then
			print(string.format("%s -> %.4f ms/op  (n=%d)", opts.title or "<no title>", avg * 1e3, n))
		end
	end

	-- Registers `test(title, ...)` and runs `bench(opts)` inside it, threading
	-- `title` through for the printed µs/op line. This is the single entry
	-- point every benchmark below goes through, so adding a new perf case
	-- never requires re-deriving the test/bench wiring.
    const function perfDescribe(describeTitle: string, fn: (perfTest: (title: string, opts: BenchOpts) -> ()) -> ())
        describe(describeTitle, function()
            const function perfTest(title: string, opts: BenchOpts)
                opts.title = describeTitle .. " - " .. title
                test(title, function()
                    task.wait() -- yield so the microprofiler doesnt overflow
                    bench(opts)
                end)
            end
            fn(perfTest)
        end)
    end

	local function destroyManager(manager: any)
		manager:Destroy()
	end

	local noop = function() end

	-- Registers a paired "(unobserved)" / "(observed)" test under `titleBase`
	-- so the two scenarios sit side by side in the output. Both run the same
	-- `action` against a fresh `buildData()` table; the observed variant adds
	-- a root `OnChange` listener first, forcing the write through the tracked
	-- path (shadow-seed + diff/dispatch) instead of short-circuiting at
	-- `shouldTrackChangesAt` -- see the note on `newObservedManager` above.
	local function comparePerfTest(
		perfTest: (title: string, opts: BenchOpts) -> (),
		titleBase: string,
		buildData: () -> any,
		action: (i: number, manager: any) -> (),
		iters: number?
	)
		for _, observed in { false, true } do
			perfTest(`{titleBase} ({if observed then "observed" else "unobserved"})`, {
				setup = function()
					local manager = TableManager.new(buildData())
					if observed then
						manager:OnChange({}, noop)
					end
					return manager
				end,
				action = action,
				teardown = destroyManager,
				iters = iters,
			})
		end
	end

	--------------------------------------------------------------------------------
	--// Data builders //--
	--------------------------------------------------------------------------------

	-- { l1 = { l2 = { ... { value = 1 } } } }, `depth` layers deep.
	local function buildDeep(depth: number): { [string]: any }
		local root: { [string]: any } = { value = 1 }
		for i = depth, 1, -1 do
			root = { [`l{i}`] = root }
		end
		return root
	end

	-- { "l1", "l2", ..., "l<depth>", "value" } -- matches buildDeep(depth).
	local function deepPath(depth: number): { string }
		local path: { string } = {}
		for i = 1, depth do
			path[i] = `l{i}`
		end
		path[depth + 1] = "value"
		return path
	end

	-- A flat table with `count` keys: { k1 = 1, k2 = 2, ... }.
	local function buildWide(count: number): { [string]: number }
		local root = {}
		for i = 1, count do
			root[`k{i}`] = i
		end
		return root
	end

	-- An array of `count` small, distinct tables: { {id=1}, {id=2}, ... }.
	local function buildArray(count: number): { { id: number } }
		local arr = {}
		for i = 1, count do
			arr[i] = { id = i }
		end
		return arr
	end

	--------------------------------------------------------------------------------
	--// Constructor //--
	--------------------------------------------------------------------------------

	perfDescribe("Method: new", function(perfTest)
		local flatData = buildWide(100)
		perfTest("flat table (100 keys)", {
			action = function()
				local manager = TableManager.new(flatData)
				manager:Destroy()
			end,
			iters = 2000,
		})

		local deepData = buildDeep(10)
		perfTest("deep table (10 layers)", {
			action = function()
				local manager = TableManager.new(deepData)
				manager:Destroy()
			end,
			iters = 2000,
		})

		local arrayData = { items = buildArray(100) }
		perfTest("array-heavy table (100 elements)", {
			action = function()
				local manager = TableManager.new(arrayData)
				manager:Destroy()
			end,
			iters = 2000,
		})
	end)

	--------------------------------------------------------------------------------
	--// Reads //--
	--------------------------------------------------------------------------------

	perfDescribe("Method: Get", function(perfTest)
		local function getDepthTest(title: string, depth: number)
			local path = deepPath(depth)
			perfTest(title, {
				setup = function()
					return TableManager.new(buildDeep(depth))
				end,
				action = function(_i, manager)
					manager:Get(path)
				end,
				teardown = destroyManager,
			})
		end

		getDepthTest("1 layer deep", 1)
		getDepthTest("5 layers deep", 5)
		getDepthTest("10 layers deep (array path)", 10)

		local stringPath = table.concat(deepPath(10), ".")
		perfTest("10 layers deep (string path, re-parsed every call)", {
			setup = function()
				return TableManager.new(buildDeep(10))
			end,
			action = function(_i, manager)
				manager:Get(stringPath)
			end,
			teardown = destroyManager,
		})
	end)

	perfDescribe("Method: GetProxy", function(perfTest)
		local function getProxyDepthTest(title: string, depth: number)
			local path = deepPath(depth)
			perfTest(title, {
				setup = function()
					return TableManager.new(buildDeep(depth))
				end,
				action = function(_i, manager)
					manager:GetProxy(path)
				end,
				teardown = destroyManager,
			})
		end

		getProxyDepthTest("1 layer deep", 1)
		getProxyDepthTest("5 layers deep", 5)
		getProxyDepthTest("10 layers deep", 10)
	end)

	--------------------------------------------------------------------------------
	--// Writes //--
	--------------------------------------------------------------------------------

	perfDescribe("Method: Set", function(perfTest)
		-- A root-level OnChange listener forces every write below into the
		-- tracked path (CoversChangesAt: "a root listener is an ancestor of
		-- every path"). Without it, applyWrite's `shouldTrackChangesAt` gate
		-- sees nothing observing and skips shadow-seed + diff/dispatch
		-- entirely, so an unlistened Set is NOT representative of the cost
		-- most callers actually pay.
		local function newObservedManager(data: any): any
			local manager = TableManager.new(data)
			manager:OnChange({}, noop)
			return manager
		end

		local function setDepthTest(title: string, depth: number)
			local path = deepPath(depth)
			perfTest(title, {
				setup = function()
					return newObservedManager(buildDeep(depth))
				end,
				action = function(i, manager)
					manager:Set(path, i % 2)
				end,
				teardown = destroyManager,
			})
		end

		setDepthTest("scalar, 1 layer deep (toggling value)", 1)
		setDepthTest("scalar, 5 layers deep (toggling value)", 5)
		setDepthTest("scalar, 10 layers deep (toggling value)", 10)

		local noOpPath = deepPath(5)
		perfTest("no-op Set (same value every call)", {
			setup = function()
				return newObservedManager(buildDeep(5))
			end,
			action = function(_i, manager)
				manager:Set(noOpPath, 1)
			end,
			teardown = destroyManager,
		})

		local replacePath = { "l1" }
		perfTest("replace a nested table", {
			setup = function()
				return newObservedManager(buildDeep(3))
			end,
			action = function(i, manager)
				manager:Set(replacePath, { l2 = { l3 = { value = i } } })
			end,
			teardown = destroyManager,
		})

		perfTest("replace the root table", {
			setup = function()
				return newObservedManager { value = 1 }
			end,
			action = function(i, manager)
				manager:Set({}, { value = i })
			end,
			teardown = destroyManager,
			iters = 2000,
		})

		local dynamicPath = { "a", "b", "c" }
		local dynamicParentPath = { "a" }
		perfTest("build intermediate tables dynamically, then clear them", {
			setup = function()
				return newObservedManager {}
			end,
			action = function(i, manager)
				manager:Set(dynamicPath, i, true)
				manager:Set(dynamicParentPath, nil)
			end,
			teardown = destroyManager,
			iters = 2000,
		})
	end)

	perfDescribe("Method: ArrayInsert", function(perfTest)
		comparePerfTest(perfTest, "append to the end (growing array)", function()
			return { items = {} }
		end, function(i, manager)
			manager:ArrayInsert("items", i)
		end)

		comparePerfTest(perfTest, "insert at the front of a 200-element array (forces a full shift)", function()
			return { items = buildArray(200) }
		end, function(i, manager)
			manager:ArrayInsert("items", 1, i)
			local items = manager:Get("items") :: { any }
			manager:ArrayRemove("items", #items) -- trim the tail so size stays steady
		end)
	end)

	perfDescribe("Method: ArrayRemove", function(perfTest)
		comparePerfTest(perfTest, "remove from the end of a 200-element array (no shift)", function()
			return { items = buildArray(201) }
		end, function(i, manager)
			local items = manager:Get("items") :: { any }
			manager:ArrayRemove("items", #items)
			manager:ArrayInsert("items", i) -- refill at the end so size stays steady
		end)

		comparePerfTest(perfTest, "remove from the front of a 200-element array (forces a full shift)", function()
			return { items = buildArray(201) }
		end, function(i, manager)
			manager:ArrayRemove("items", 1)
			manager:ArrayInsert("items", i) -- refill at the end so size stays steady
		end)
	end)

	perfDescribe("Method: ArrayRemoveFirstValue", function(perfTest)
		comparePerfTest(perfTest, "find (middle of 200) + shift-remove", function()
			return { items = buildArray(200) }
		end, function(_i, manager)
			local items = manager:Get("items") :: { any }
			local mid = math.floor(#items / 2)
			local target = items[mid]
			manager:ArrayRemoveFirstValue("items", target)
			manager:ArrayInsert("items", mid, { id = -1 }) -- reinsert at the same slot
		end)
	end)

	perfDescribe("Method: ArraySwapRemove", function(perfTest)
		comparePerfTest(perfTest, "O(1) remove from the front of a 200-element array", function()
			return { items = buildArray(201) }
		end, function(_i, manager)
			manager:ArraySwapRemove("items", 1)
			manager:ArrayInsert("items", { id = -1 })
		end)
	end)

	perfDescribe("Method: ArraySwapRemoveFirstValue", function(perfTest)
		comparePerfTest(perfTest, "find (middle of 200) + O(1) swap-remove", function()
			return { items = buildArray(200) }
		end, function(_i, manager)
			local items = manager:Get("items") :: { any }
			local mid = math.floor(#items / 2)
			local target = items[mid]
			manager:ArraySwapRemoveFirstValue("items", target)
			manager:ArrayInsert("items", mid, { id = -1 }) -- reinsert at the same slot
		end)
	end)

	--------------------------------------------------------------------------------
	--// Listeners //--
	--------------------------------------------------------------------------------

	perfDescribe("Listener registration", function(perfTest)
		-- All nine registration methods share the same cost shape (walk/create a
		-- registry trie node, store the entry, disconnect). One generator, fed
		-- with each method's own registration call, replaces nine near-identical
		-- bench blocks.
		local function registrationTest(methodName: string, register: (manager: any) -> any)
			perfTest(methodName, {
				setup = function()
					return TableManager.new { value = 1, items = {} }
				end,
				action = function(_i, manager)
					local connection = register(manager)
					connection:Disconnect()
				end,
				teardown = destroyManager,
			})
		end

		registrationTest("OnChange", function(manager)
			return manager:OnChange("value", noop)
		end)
		registrationTest("OnValueChange", function(manager)
			return manager:OnValueChange("value", noop)
		end)
		registrationTest("Observe", function(manager)
			return manager:Observe("value", noop)
		end)
		registrationTest("OnKeyAdd", function(manager)
			return manager:OnKeyAdd({}, noop)
		end)
		registrationTest("OnKeyRemove", function(manager)
			return manager:OnKeyRemove({}, noop)
		end)
		registrationTest("OnKeyChange", function(manager)
			return manager:OnKeyChange({}, noop)
		end)
		registrationTest("OnArrayInsert", function(manager)
			return manager:OnArrayInsert("items", noop)
		end)
		registrationTest("OnArrayRemove", function(manager)
			return manager:OnArrayRemove("items", noop)
		end)
		registrationTest("OnArraySet", function(manager)
			return manager:OnArraySet("items", noop)
		end)
	end)

	perfDescribe("Listener dispatch (fan-out)", function(perfTest)
		local function dispatchTest(title: string, listenerCount: number, iters: number?)
			perfTest(title, {
				setup = function()
					local manager = TableManager.new { value = 1 }
					for _ = 1, listenerCount do
						manager:OnChange("value", noop)
					end
					return manager
				end,
				action = function(i, manager)
					manager:Set("value", i % 2)
				end,
				teardown = destroyManager,
				iters = iters,
			})
		end

		dispatchTest("0 listeners", 0)
		dispatchTest("1 listener", 1)
		dispatchTest("10 listeners", 10)
		dispatchTest("100 listeners", 100, 2000)
	end)

	--------------------------------------------------------------------------------
	--// For / Map //--
	--------------------------------------------------------------------------------

	perfDescribe("Method: ForKeys", function(perfTest)
		local forKeysData = buildWide(100)
		perfTest("initial subscribe over 100 keys", {
			action = function()
				local manager = TableManager.new(forKeysData)
				local connection = manager:ForKeys({}, noop)
				connection:Disconnect()
				manager:Destroy()
			end,
			iters = 500,
		})

		perfTest("incremental: array insert/remove drives reconciliation", {
			setup = function()
				local manager = TableManager.new { items = buildArray(100) }
				manager:ForKeys("items", noop)
				return manager
			end,
			action = function(i, manager)
				manager:ArrayInsert("items", { id = i })
				local items = manager:Get("items") :: { any }
				manager:ArrayRemove("items", #items)
			end,
			teardown = destroyManager,
		})
	end)

	perfDescribe("Method: ForValues", function(perfTest)
		local forValuesData = buildArray(100)
		perfTest("initial subscribe over 100 values", {
			action = function()
				local manager = TableManager.new { items = forValuesData }
				local connection = manager:ForValues("items", noop)
				connection:Disconnect()
				manager:Destroy()
			end,
			iters = 500,
		})

		perfTest("incremental: array insert/remove drives reconciliation", {
			setup = function()
				local manager = TableManager.new { items = buildArray(100) }
				manager:ForValues("items", noop)
				return manager
			end,
			action = function(i, manager)
				manager:ArrayInsert("items", { id = i })
				local items = manager:Get("items") :: { any }
				manager:ArrayRemove("items", #items)
			end,
			teardown = destroyManager,
		})
	end)

	perfDescribe("Method: ForPairs", function(perfTest)
		local forPairsData = buildWide(100)
		perfTest("initial subscribe over 100 entries", {
			action = function()
				local manager = TableManager.new(forPairsData)
				local connection = manager:ForPairs({}, noop)
				connection:Disconnect()
				manager:Destroy()
			end,
			iters = 500,
		})

		perfTest("incremental: value change at an existing key re-runs the handler", {
			setup = function()
				local manager = TableManager.new(buildWide(100))
				manager:ForPairs({}, noop)
				return manager
			end,
			action = function(i, manager)
				manager:Set("k1", i)
			end,
			teardown = destroyManager,
		})
	end)

	-- MapKeys/MapValues/MapPairs only differ by which method is called and the
	-- transform's signature; one generator drives all three with the "initial
	-- build" + "incremental propagation" pair shared across them.
	local function mapMethodTests(methodName: string, callMap: (source: any, transformFn: any) -> any, transformFn: any)
		perfDescribe(`Method: {methodName}`, function(perfTest)
			local data = buildWide(100)
			perfTest("initial build over 100 keys", {
				action = function()
					local source = TableManager.new(data)
					local derived = callMap(source, transformFn)
					derived:Destroy()
					source:Destroy()
				end,
				iters = 300,
			})

			perfTest("incremental: source value change propagates to the derived output", {
				setup = function()
					local source = TableManager.new(buildWide(100))
					local derived = callMap(source, transformFn)
					return { source = source, derived = derived }
				end,
				action = function(i, ctx)
					ctx.source:Set("k1", i)
				end,
				teardown = function(ctx)
					ctx.derived:Destroy()
					ctx.source:Destroy()
				end,
			})
		end)
	end

	mapMethodTests("MapKeys", function(source, transformFn)
		return source:MapKeys({}, transformFn)
	end, function(_itemJanitor: any, key: any, _value: any): any
		return key
	end)

	mapMethodTests("MapValues", function(source, transformFn)
		return source:MapValues({}, transformFn)
	end, function(_itemJanitor: any, value: any, _key: any): any
		return value
	end)

	mapMethodTests("MapPairs", function(source, transformFn)
		return source:MapPairs({}, transformFn)
	end, function(_itemJanitor: any, key: any, value: any): (any, any)
		return key, value
	end)

	--------------------------------------------------------------------------------
	--// Batching //--
	--------------------------------------------------------------------------------

	local WRITES_PER_BATCH = 20

	local function setupBatchManager(): any
		local manager = TableManager.new(buildWide(WRITES_PER_BATCH))
		for k = 1, WRITES_PER_BATCH do
			manager:OnChange(`k{k}`, noop)
		end
		return manager
	end

	perfDescribe("Method: Batch", function(perfTest)
		perfTest("20 writes per Batch call (dispatch coalesced into one flush)", {
			setup = setupBatchManager,
			action = function(i, manager)
				manager:Batch(function()
					for k = 1, WRITES_PER_BATCH do
						manager:Set(`k{k}`, i)
					end
				end)
			end,
			teardown = destroyManager,
			iters = 2000,
		})

		perfTest("20 writes, immediate (no Batch, dispatch fires per write)", {
			setup = setupBatchManager,
			action = function(i, manager)
				for k = 1, WRITES_PER_BATCH do
					manager:Set(`k{k}`, i)
				end
			end,
			teardown = destroyManager,
			iters = 2000,
		})
	end)

	perfDescribe("Method: Suspend / Resume", function(perfTest)
		perfTest("explicit Suspend/Resume around 20 dirty branches", {
			setup = setupBatchManager,
			action = function(i, manager)
				manager:Suspend()
				for k = 1, WRITES_PER_BATCH do
					manager:Set(`k{k}`, i)
				end
				manager:Resume()
			end,
			teardown = destroyManager,
			iters = 2000,
		})
	end)

	perfDescribe("Method: Flush", function(perfTest)
		perfTest("explicit Flush after a direct Raw mutation (bypass path)", {
			setup = function()
				local manager = TableManager.new { value = 1 }
				manager:OnChange("value", noop)
				return manager
			end,
			action = function(i, manager)
				(manager.Raw :: any).value = i % 2 -- bypasses Set/Proxy entirely
				manager:Flush("value")
			end,
			teardown = destroyManager,
		})
	end)

	perfDescribe("Method: ForceNotify", function(perfTest)
		perfTest("synthetic same-value notification", {
			setup = function()
				local manager = TableManager.new { value = 1 }
				manager:OnChange("value", noop)
				return manager
			end,
			action = function(_i, manager)
				manager:ForceNotify("value")
			end,
			teardown = destroyManager,
		})
	end)

	--------------------------------------------------------------------------------
	--// Movement //--
	--------------------------------------------------------------------------------

	perfDescribe("Method: MoveTo", function(perfTest)
		comparePerfTest(perfTest, "move a small table back and forth between two slots", function()
			return { a = { value = 1 } }
		end, function(i, manager)
			if i % 2 == 1 then
				manager:MoveTo("a", "b")
			else
				manager:MoveTo("b", "a")
			end
		end)
	end)

	perfDescribe("Method: CopyTo", function(perfTest)
		comparePerfTest(perfTest, "deep-copy a small table into another slot", function()
			return { a = { value = 1, nested = { x = 1 } }, b = {} }
		end, function(_i, manager)
			manager:CopyTo("a", "b")
		end)
	end)

	perfDescribe("Method: Swap", function(perfTest)
		comparePerfTest(perfTest, "swap two small tables back and forth", function()
			return { a = { id = "a" }, b = { id = "b" } }
		end, function(_i, manager)
			manager:Swap("a", "b")
		end)
	end)

	--------------------------------------------------------------------------------
	--// Ignored Paths //--
	--------------------------------------------------------------------------------

	perfDescribe("Method: SetPathIgnored", function(perfTest)
		perfTest("Set into an ignored subtree (diff/snapshot skipped)", {
			setup = function()
				local manager = TableManager.new { ignored = { value = 1 } }
				manager:OnChange("ignored", noop)
				manager:SetPathIgnored("ignored", true)
				return manager
			end,
			action = function(i, manager)
				manager:Set("ignored.value", i % 2)
			end,
			teardown = destroyManager,
		})

		perfTest("Set into the equivalent tracked subtree (baseline for comparison)", {
			setup = function()
				local manager = TableManager.new { tracked = { value = 1 } }
				manager:OnChange("tracked", noop)
				return manager
			end,
			action = function(i, manager)
				manager:Set("tracked.value", i % 2)
			end,
			teardown = destroyManager,
		})
	end)

	--------------------------------------------------------------------------------
	--// Linking / Extend //--
	--------------------------------------------------------------------------------

	perfDescribe("Method: Extend", function(perfTest)
		perfTest("extend a nested table into its own manager", {
			setup = function()
				return TableManager.new { child = { value = 1 } }
			end,
			action = function(_i, manager)
				local extended = manager:Extend("child")
				extended:Destroy()
			end,
			teardown = destroyManager,
			iters = 2000,
		})
	end)

	perfDescribe("Method: GetLinkedManagers / IsLinkedWith", function(perfTest)
		perfTest("lookup cost with 10 co-observing managers", {
			setup = function()
				local shared = { value = 1 }
				local root = TableManager.new { stats = shared }
				local others = {}
				for i = 1, 10 do
					others[i] = TableManager.new { stats = shared }
				end
				return { root = root, others = others }
			end,
			action = function(_i, ctx)
				ctx.root:GetLinkedManagers()
				ctx.root:IsLinkedWith(ctx.others[1])
			end,
			teardown = function(ctx)
				for _, other in ctx.others do
					other:Destroy()
				end
				ctx.root:Destroy()
			end,
		})
	end)

	perfDescribe("Linked managers: write fan-out", function(perfTest)
		perfTest("Set on one manager propagates to a co-observing linked manager", {
			setup = function()
				local shared = { value = 1 }
				local a = TableManager.new { stats = shared }
				local b = TableManager.new { stats = shared }
				return { a = a, b = b }
			end,
			action = function(i, ctx)
				ctx.a:Set("stats.value", i % 2)
			end,
			teardown = function(ctx)
				ctx.a:Destroy()
				ctx.b:Destroy()
			end,
		})
	end)

	--------------------------------------------------------------------------------
	--// Opacity wrappers //--
	--------------------------------------------------------------------------------

	perfDescribe("Opacity wrappers", function(perfTest)
		local function opacityTest(title: string, wrap: (value: any) -> any)
			comparePerfTest(perfTest, title, function()
				return {}
			end, function(_i, manager)
				manager:Set("blob", wrap(buildWide(50)))
			end, 2000)
		end

		opacityTest("Set a large nested value, transparent (full diff/clone)", function(value)
			return value
		end)
		opacityTest("Set the same large nested value, wrapped in Opaque (skips clone/walk)", TableManager.Opaque)
		opacityTest("Set with OpaqueChildren (children opaque, container still tracked)", TableManager.OpaqueChildren)
	end)

	--------------------------------------------------------------------------------
	--// Lifecycle //--
	--------------------------------------------------------------------------------

	perfDescribe("Method: Destroy", function(perfTest)
		local function destroyTest(title: string, listenerCount: number)
			perfTest(title, {
				action = function()
					local manager = TableManager.new { value = 1, items = buildArray(10) }
					for _ = 1, listenerCount do
						manager:OnChange("value", noop)
					end
					manager:Destroy()
				end,
				iters = 1000,
			})
		end

		destroyTest("0 listeners registered", 0)
		destroyTest("10 listeners registered", 10)
		destroyTest("100 listeners registered", 100)
	end)
end

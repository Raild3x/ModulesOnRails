--!strict
--[=[
	@ignore
	@class CoalescedFlush

	Routes a flush request through `Config.FlushMode`. "immediate" (the
	default) runs `TableManager:_doFlush` synchronously, same as before this
	module existed. "coalesced" defers it to frame-end (`task.defer`) and
	merges every path requested before then into one pending flush root — the
	running common ancestor of those paths — so a frame with N writes under
	one subtree costs one shadow diff/reconcile instead of N, at the cost of
	widening to the whole tree when writes are scattered across unrelated
	branches.

	Only paths already known trackable (per `Coverage.IsTrackable`) ever reach
	`Request`: callers (`Mutator.applyWrite`/`applyRootSet`) are responsible
	for that gate, exactly as they are for `_doFlush` itself.
]=]

const PathHelpers = require("../PathHelpers")
const TMTypes = require("../TMTypes")

--// Types //--
type PathArray<S = string> = PathHelpers.PathArray<S>
type TableManagerLike = TMTypes.TableManagerLike

const CoalescedFlush = {}

-- The longest shared prefix of `a` and `b` — their common ancestor path. `{}`
-- (root) when they diverge at the first segment.
local function lowestCommonAncestor(a: PathArray, b: PathArray): PathArray
	const result = {}
	const minLen = math.min(#a, #b)
	for i = 1, minLen do
		if a[i] ~= b[i] then
			break
		end
		table.insert(result, a[i])
	end
	return result
end

--[=[
	Routes a flush request for `path` through `self._flushMode`. In
	"immediate" mode this is exactly `self:_doFlush(path)`. In "coalesced"
	mode it merges `path` into the pending frame-end flush root and (the first
	time within a frame) schedules the `task.defer` that drains it.
]=]
function CoalescedFlush.Request(self: TableManagerLike, path: PathArray)
	if self._flushMode ~= "coalesced" then
		self:_doFlush(path)
		return
	end

	if self._pendingFlushRoot == nil then
		self._pendingFlushRoot = table.clone(path)
	else
		self._pendingFlushRoot = lowestCommonAncestor(self._pendingFlushRoot, path)
	end

	if self._coalescedFlushScheduled then
		return
	end
	self._coalescedFlushScheduled = true

	task.defer(function()
		-- Read pending state fresh here (not captured above) so this closure
		-- self-corrects if `FlushPending` already drained it earlier in the
		-- frame (e.g. via `Suspend`/`Flush`): it then just no-ops below.
		self._coalescedFlushScheduled = false
		const root = self._pendingFlushRoot
		self._pendingFlushRoot = nil
		if self._Destroyed or root == nil then
			return
		end
		self:_doFlush(root)
	end)
end

--[=[
	Synchronously runs and clears any pending coalesced flush for `self`.

	Required before anything that takes a fresh baseline directly off live
	data while a coalesced flush is still outstanding (`Suspend`'s pre-batch
	snapshot, an explicit `Flush`) — otherwise that baseline silently absorbs
	the not-yet-reported transition the pending flush was holding, and the
	persistent shadow (once the pending flush eventually no-ops against it)
	never surfaces it to any listener. Flushing first makes the shadow
	authoritative again before the new baseline is taken.
]=]
function CoalescedFlush.FlushPending(self: TableManagerLike)
	const root = self._pendingFlushRoot
	if root == nil then
		return
	end
	self._pendingFlushRoot = nil
	self._coalescedFlushScheduled = false
	self:_doFlush(root)
end

return CoalescedFlush

--[=[
	@class TM Performance

	[TableManager](/api/TableManager) does a lot of work to turn a raw table
	mutation into precise, replay-faithful events — but it is built so that work
	only happens where it earns its keep. This guide explains the optimizations you
	get **for free** and the handful of habits that let you lean on them, so you can
	reason about cost instead of guessing.

	The one-line model: TableManager pays for change detection **in proportion to
	what is actually observed**, not to how much data you store or how often you
	write it.

	## What you get for free

	### Unobserved writes are (almost) free

	Change detection is a diff, gated by a coverage check. If nothing observes a
	path — no listener covers it, no global Signal is connected, no linked manager
	shares it, no `OnApplied` subscriber exists — the whole diff/emit chain is
	skipped and the write is just a table assignment plus a little bookkeeping.

	```lua
	local manager = TableManager.new(bigData)
	manager:Set("Telemetry.Frame", frameId) -- nobody listening here: no diff runs
	```

	This is why defensive `Flush` calls and writes to "cold" branches stay cheap,
	and why you don't need to prune listeners you never registered. (See the
	[Flushing](/api/TM%20Flushing) guide — a flush is a no-op when nothing watches.)

	### Diffs stop at the deepest listener

	When a path *is* observed, the diff is still **depth-bounded**: it descends only
	as deep as the deepest listener that could fire. A listener at `Player` does not
	force a walk of every leaf under `Player` — only down to the levels something
	actually watches.

	### Big or foreign values can opt out entirely

	A value marked **opaque** (or a deeply frozen table) is compared by identity
	only — never cloned, frozen, or walked. This turns the per-diff cost of a large
	immutable blob or a foreign object from O(n) into O(1). See the
	[Opaque Values](/api/TM%20Opaque%20Values) guide.

	### Shared baseline, patched in place

	The "last emitted" baseline every diff compares against is a **shared,
	identity-keyed** store: managers that co-observe the same live table share one
	baseline instead of each keeping a copy. And common writes patch that baseline
	incrementally — a scalar field set or a single array insert/remove updates the
	baseline spine directly rather than re-copying the surrounding subtree.

	### Hot write paths avoid redundant work

	- A plain non-nil `Set` (no dynamic table-building) resolves the parent chain
	  **once**, not twice.
	- `Update`, `Increment`, `UpdateKey`, and `IncrementKey` are single-walk
	  read-modify-writes — they don't re-navigate the path between the read and the
	  write.
	- A scalar-to-scalar `Set` in immediate mode takes a fast lane that synthesizes
	  its one-node diff directly, skipping the general diff engine.

	### Many changes can collapse into one flush

	Both explicit [batching](/api/TM%20Batching) and `FlushMode = "coalesced"`
	merge many writes into a single diff/fire. Repeated fires of the *same* Signal
	within a tick can also coalesce into one. N writes under a subtree then cost one
	flush, not N.

	## How to leverage it

	A short checklist, most-impactful first:

	1. **Write through the API.** `Set`/`ArrayInsert`/the proxy are what let the
	   coverage gate and incremental baseline patching kick in. Bypassing them and
	   later calling `Flush` forces a full re-diff of the branch.
	2. **Don't over-subscribe.** Register listeners at the shallowest path and depth
	   that meets your need; every extra deep listener widens the diff bound. Prefer
	   one `OnChange` at a subtree over many leaf listeners when you only need "did
	   anything here change".
	3. **Batch bulk edits.** Wrap loops of writes in `Batch` (or use `coalesced`
	   flush for high-frequency, frame-driven updates) so listeners fire once.
	4. **Mark big/foreign values opaque.** Anything large-and-immutable or
	   foreign-and-un-walkable should be `Opaque` / `GlobalOpaque`.
	5. **Ignore paths you never observe but write hot.** `IgnoredPaths` (or
	   `SetPathIgnored`) skips all diff/event work for a branch while keeping the
	   value live in `Raw`/`Get`.
	6. **Reuse literal string paths; use arrays for dynamic ones.** A repeated
	   *literal* string path is parsed once and cached; a string assembled per call
	   (`"Player." .. field`) re-splits every time — pass an array for those. See
	   the string-vs-array notes in [Getting Started](/api/TM%20Getting%20Started).

	:::tip Measure, don't assume
	These optimizations mean the expensive cases are the observable, deep, large
	ones. If a workload feels slow, look first at *what is being observed* (listener
	breadth/depth) and *what is being walked* (large transparent tables), not at the
	raw write count.
	:::

	---
	### See also

	- **[TM Flushing](/api/TM%20Flushing)** — the diff→fire→reconcile cycle and the "free when nothing watches" rule.
	- **[TM Batching](/api/TM%20Batching)** — collapsing many writes into one flush.
	- **[TM Opaque Values](/api/TM%20Opaque%20Values)** — opting large/foreign values out of the diff.
	- **[TM Getting Started](/api/TM%20Getting%20Started)** — string vs. array paths and the path cache.
]=]

--[=[
	@class TR Performance & Ordering

	By default TableReplicator already does the right thing: writes are batched per
	frame and applied in a consistent order on every client. This guide explains those
	guarantees and the few knobs you can turn when a replicator has unusual needs.

	### Per-frame batching (the default)

	When you mutate `.Manager`, the write isn't sent immediately. It's queued and flushed
	once per frame, so a burst of writes across many replicators collapses into **at most
	one message per player per frame**. On the client, a whole flush is applied inside a
	single `TableManager` batch, so listeners see one coalesced update rather than a
	storm of intermediate ones.

	You rarely need to change this. The options below are for the cases where you do.

	### `Coalesced` — drop redundant writes

	If a replicator writes the same key many times per frame and only the final value
	matters, set `Coalesced = true`. Intermediate writes to a key are dropped and only
	the latest is sent:

	```lua
	local replicator = ServerReplicator.new({
		Data = { MousePosition = Vector3.zero },
		Targets = "all",
		Coalesced = true, -- only the last MousePosition of the frame is sent
	})
	```

	Best for high-churn, latest-value-wins data (cursor positions, live sliders). Avoid
	it when every intermediate value is meaningful.

	### `ImmediateFlush` — send each op right away

	Set `ImmediateFlush = true` to send each op as it happens instead of waiting for the
	per-frame flush. The main use is guaranteeing a data change lands *before* an external
	`RemoteEvent` you fire in the same frame:

	```lua
	local replicator = ServerReplicator.new({
		Data = { State = "Idle" },
		Targets = "all",
		ImmediateFlush = true,
	})
	```

	:::caution Mutually exclusive
	`Coalesced` and `ImmediateFlush` cannot both be `true` — that combination throws at
	construction. Immediate flushing also gives up the batching win, so reach for it only
	when ordering against external events actually matters.
	:::

	If you only need a one-off flush rather than a permanent mode, call the static
	`ServerReplicator.FlushNow()` to drain all pending ops immediately.

	### Ordering guarantees

	Every replicator's data ops funnel through a single server-wide ordering point, so:

	- **Global order is preserved.** Ops from *different* replicators and different
	  `TableManager`s replay on the client in the exact order the server produced them —
	  not merely per-replicator order.
	- **Audience is captured at write time, re-checked at flush.** A player added
	  mid-frame never double-applies an op already baked into their snapshot; a player
	  removed mid-frame never receives an op for a replicator they were just dropped from.
	- **Ordered remotes interleave with data.** Signals and functions registered as
	  *ordered* variants (see [TR Custom Remotes](/api/TR%20Custom%20Remotes)) travel
	  through the same buffer, so an
	  ordered signal fired after a `Set` arrives after that `Set` is applied.

	### Discovery listener scheduling (`FireMode`)

	Discovery callbacks (`ForEach`, `OnNew`, and the `ReplicatorCreated` signal) are
	scheduled according to a global fire mode. The default, `"bindable"`, mirrors
	Roblox's `BindableEvent` behavior. You can change it for listeners registered
	afterward:

	```lua
	ServerReplicator.SetListenerFireMode("immediate") -- run on a fresh thread at once
	ServerReplicator.SetListenerFireMode("deferred")  -- run at the end of the resumption cycle
	ServerReplicator.SetListenerFireMode("bindable")  -- default, matches BindableEvent

	print(ServerReplicator.ListenerFireMode) -- read-only current mode
	```

	`"immediate"` gives the lowest latency but runs callbacks re-entrantly;
	`"deferred"` is safest if a callback might create or destroy replicators. The setting
	is shared across `ServerReplicator` and `ClientReplicator`.

	:::info Going deeper
	For the full internal picture — the frame buffer, the double `task.defer`, the wire
	format, and table de-duplication — see `ARCHITECTURE.md` in the TableReplicator
	source. This guide covers only the user-facing tuning knobs.
	:::

	---
	### See also

	- **[TR Getting Started](/api/TR%20Getting%20Started)** — where `Coalesced` and `ImmediateFlush` live in the config.
	- **[TR Custom Remotes](/api/TR%20Custom%20Remotes)** — ordered vs unordered signals and functions.
	- **[TR Discovery & Targeting](/api/TR%20Discovery%20&%20Targeting)** — the listeners that `FireMode` schedules.
]=]

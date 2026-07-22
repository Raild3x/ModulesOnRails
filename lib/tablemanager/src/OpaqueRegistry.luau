--!strict
--[=[
	@ignore
	@class OpaqueRegistry

	Tracks which live table references are "opaque" to the diff engine: their
	internal structure is never cloned, frozen, walked, or diffed — only
	identity (`==`) is compared. Marking is by VALUE REFERENCE (weak-keyed
	registries), never by path, since paths move (array shifts, `MoveTo`,
	`Swap`) but identity does not.

	Two wrapper families, each with a per-manager and a global variant:
	- `Opaque` / `GlobalOpaque`: the wrapped value itself is an opaque leaf.
	- `OpaqueChildren` / `GlobalOpaqueChildren`: the wrapped value stays
	  transparent (its own add/remove is still tracked), but its direct
	  table-typed children are treated as opaque leaves. Lets a container be
	  marked once so later-inserted elements are automatically opaque.

	Wrapper constructors are pure (no registration side effect until a value
	is written through `TableManager.Set`/`ArrayInsert`, which calls
	`UnwrapAndRegister`).

	A FROZEN table is also opaque, with no wrapper needed: deeply frozen
	(every table-typed descendant also frozen) unconditionally, per
	`Config.FrozenTablesAreOpaque` (shallow trust) when opted in. Discovery
	happens once, at `Propagation.registerSubtree` (`RegisterIfFrozenOpaque`),
	and is recorded into the SAME per-manager `Opaque` registry an explicit
	`Opaque()` wrapper uses — see the warning on `deepFrozenMemo` for why this
	must never be probed lazily from the `isOpaque` oracle itself.
]=]

const OpaqueRegistry = {}

--// Wrapper markers//--
const OPAQUE = "O"
const GLOBAL_OPAQUE = "GO"
const OPAQUE_CHILDREN = "OC"
const GLOBAL_OPAQUE_CHILDREN = "GOC"

const OPAQUE_KIND_KEY = "__opaque_kind"
type WrapperKind = "O" | "GO" | "OC" | "GOC"
export type Wrapper<T> = { inner: T, __opaque_kind: WrapperKind }

--// Module-global registries (shared across every TableManager) //--
local globalOpaque: { [any]: true? } = setmetatable({}, { __mode = "k" }) :: any
local globalOpaqueChildren: { [any]: true? } = setmetatable({}, { __mode = "k" }) :: any

-- Incremented when a value is newly registered into either global registry;
-- never decremented (entries are GC'd via the weak table, but re-checking
-- "is this number still accurate" on every removal would defeat the point of
-- a cheap gate). Worst case the oracle stays "active" slightly longer than
-- strictly necessary after the last global mark is collected.
local globalCount = 0

-- Module-global, identity-keyed memo of tables already PROVEN deep-frozen
-- (`table.isfrozen` AND every table-typed descendant likewise). Frozen-ness
-- is permanent in Luau (a frozen table can neither gain children nor have an
-- existing one unfrozen), so this is a write-once fact shared safely across
-- every manager: the first full walk that proves it pays the O(n) cost, every
-- later `IsDeepFrozen` call on that identity is an O(1) hit. Weak-keyed so a
-- detached frozen subtree can still be collected.
--
-- IMPORTANT: only ever populated by `Propagation.registerSubtree`'s walk over
-- a value actually being written into a manager's tree (via `RegisterIfFrozenOpaque`
-- below) — NEVER from `MakeCtx`'s `isOpaque` closure. `Diff.snapshot` and other
-- internal machinery build their OWN frozen copy/artifact tables (e.g. the
-- batch pre-snapshot); those are frozen by construction but are not user data,
-- and checking `table.isfrozen` on an arbitrary value handed to `isOpaque`
-- mid-diff would misclassify them as opaque, corrupting that diff. Restricting
-- discovery to `registerSubtree` (which only ever sees values actually
-- entering a tree) keeps `isOpaque` a pure, side-effect-free memo lookup.
local deepFrozenMemo: { [any]: true? } = setmetatable({}, { __mode = "k" }) :: any

export type Registries = {
	Opaque: { [any]: true },
	OpaqueChildren: { [any]: true },
	Count: number,
	-- Config.FrozenTablesAreOpaque (default false): when true, a SHALLOWLY
	-- frozen table (`table.isfrozen(t)` true, descendants untested) is also
	-- treated as opaque, trusting the flag as the caller's own immutability
	-- assertion (same trust model as `Opaque`). Deep-frozen tables are always
	-- opaque regardless of this flag — see `IsDeepFrozen`.
	FrozenTablesAreOpaque: boolean,
}

function OpaqueRegistry.NewRegistries(frozenTablesAreOpaque: boolean?): Registries
	return {
		Opaque = setmetatable({}, { __mode = "k" }) :: any,
		OpaqueChildren = setmetatable({}, { __mode = "k" }) :: any,
		Count = 0,
		FrozenTablesAreOpaque = frozenTablesAreOpaque == true,
	}
end

--[=[
	True if `t` is provably deep-frozen: `table.isfrozen(t)` and every
	table-typed value reachable from it is also frozen. Memoized by identity
	(see `deepFrozenMemo`) — only a COMPLETE walk may write a `true` result;
	a walk that bails early on a not-yet-frozen descendant returns `false`
	without memoizing anything (that descendant may be frozen later).

	A pure, manager-independent oracle — see the warning on `deepFrozenMemo`
	about where this may safely be called from.
]=]
function OpaqueRegistry.IsDeepFrozen(t: any): boolean
	if type(t) ~= "table" then
		return false
	end
	if deepFrozenMemo[t] then
		return true
	end
	if not table.isfrozen(t) then
		return false
	end
	for _, v in t do
		if type(v) == "table" and not OpaqueRegistry.IsDeepFrozen(v) then
			return false
		end
	end
	deepFrozenMemo[t] = true
	return true
end

--[=[
	If `t` qualifies as opaque purely by virtue of being frozen — shallowly,
	when `registries.FrozenTablesAreOpaque` is set (trusting the flag, O(1)),
	or deeply regardless of the flag (provably safe, via `IsDeepFrozen`) —
	marks it into `registries.Opaque` (same registry an explicit `Opaque()`
	wrapper uses, so `Count`/`isOpaque` need no separate frozen-aware logic)
	and returns true. Returns false (no mark) otherwise.

	Called ONLY from `Propagation.registerSubtree`, the single point that
	walks a value actually being written into a manager's tree — see the
	warning on `deepFrozenMemo` for why this must not be called from
	anywhere that might see an internal snapshot/copy artifact instead.
]=]
function OpaqueRegistry.RegisterIfFrozenOpaque(t: any, registries: Registries): boolean
	if type(t) ~= "table" then
		return false
	end
	if registries.Opaque[t] == true then
		return true
	end
	if not ((registries.FrozenTablesAreOpaque and table.isfrozen(t)) or OpaqueRegistry.IsDeepFrozen(t)) then
		return false
	end
	registries.Opaque[t] = true
	registries.Count += 1
	return true
end

--// Wrapper constructors //--
local function OpaqueWrapperGenerator<T>(value: T, opaque_kind: WrapperKind): Wrapper<T>
	return table.freeze({ inner = value, [OPAQUE_KIND_KEY] = opaque_kind } :: any) :: Wrapper<T>
end

function OpaqueRegistry.Opaque<T>(value: T): Wrapper<T>
	return OpaqueWrapperGenerator(value, OPAQUE)
end

function OpaqueRegistry.GlobalOpaque<T>(value: T): Wrapper<T>
	return OpaqueWrapperGenerator(value, GLOBAL_OPAQUE)
end

function OpaqueRegistry.OpaqueChildren<T>(value: T): Wrapper<T>
	return OpaqueWrapperGenerator(value, OPAQUE_CHILDREN)
end

function OpaqueRegistry.GlobalOpaqueChildren<T>(value: T): Wrapper<T>
	return OpaqueWrapperGenerator(value, GLOBAL_OPAQUE_CHILDREN)
end

local function wrapperKind(value: any): WrapperKind?
	if type(value) ~= "table" then
		return nil
	end
	return (value :: any)[OPAQUE_KIND_KEY]
end

--[=[
	If `value` is one of the four wrapper kinds, registers its inner value
	into the right registry (`registries`, the per-manager set, for the
	non-global kinds; the module-global registries otherwise) and returns the
	inner value. Otherwise returns `value` unchanged.

	Opacity is meaningless for scalars (there is no internal structure to
	avoid cloning/walking) — wrapping a scalar unwraps it but does not
	register it, and warns.
]=]
function OpaqueRegistry.UnwrapAndRegister<T>(registries: Registries, value: T | Wrapper<T>): T
	local kind = wrapperKind(value)
	if kind == nil then
		return value
	end

	local inner = (value :: Wrapper<T>).inner
	if type(inner) ~= "table" then
		warn("Opaque/OpaqueChildren wrappers have no effect on non-table values; unwrapping without marking.")
		return inner
	end

	if kind == OPAQUE then
		if registries.Opaque[inner] == nil then
			registries.Count += 1
		end
		registries.Opaque[inner] = true
	elseif kind == OPAQUE_CHILDREN then
		if registries.OpaqueChildren[inner] == nil then
			registries.Count += 1
		end
		registries.OpaqueChildren[inner] = true
	elseif kind == GLOBAL_OPAQUE then
		if globalOpaque[inner] == nil then
			globalCount += 1
		end
		globalOpaque[inner] = true
	elseif kind == GLOBAL_OPAQUE_CHILDREN then
		if globalOpaqueChildren[inner] == nil then
			globalCount += 1
		end
		globalOpaqueChildren[inner] = true
	end

	return inner
end

-- Exposed so a manager can cheaply re-check "did the global registry become
-- active since I last built my ctx" without taking a dependency on the
-- module-level local.
function OpaqueRegistry.GlobalCount(): number
	return globalCount
end

export type Ctx = {
	isOpaque: (ref: any) -> boolean,
	hasOpaqueChildren: (ref: any) -> boolean,
}

--[=[
	Builds the persistent `ctx` oracle closures for a manager's registries.
	Cheap to call once and hold onto — the closures simply close over the
	(mutable) registry tables, so they stay correct as marks are added later.
	Callers should gate USE of the returned ctx behind `registries.Count > 0
	or OpaqueRegistry.GlobalCount() > 0` (see `ChangeDetector`) rather than
	rebuilding it, so an unused oracle costs nothing per write.

	Deliberately does NOT special-case frozen tables here: `isOpaque` must stay
	a pure memo lookup, since it is called mid-diff on values that may be
	internal snapshot/copy artifacts (always frozen by construction, but not
	user data) rather than live tree data — see the warning on `deepFrozenMemo`.
	Frozen-table opacity is decided once, at `Propagation.registerSubtree`
	(`RegisterIfFrozenOpaque`), and recorded into the same `Opaque` registry an
	explicit `Opaque()` wrapper uses, so it is already covered by the first
	check below with no extra logic.
]=]
function OpaqueRegistry.MakeCtx(registries: Registries): Ctx
	local managerOpaque = registries.Opaque
	local managerOpaqueChildren = registries.OpaqueChildren
	return {
		isOpaque = function(ref: any): boolean
			return managerOpaque[ref] == true or globalOpaque[ref] == true
		end,
		hasOpaqueChildren = function(ref: any): boolean
			return managerOpaqueChildren[ref] == true or globalOpaqueChildren[ref] == true
		end,
	}
end

return OpaqueRegistry

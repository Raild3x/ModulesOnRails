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

export type Registries = {
	Opaque: { [any]: true },
	OpaqueChildren: { [any]: true },
	Count: number,
}

function OpaqueRegistry.NewRegistries(): Registries
	return {
		Opaque = setmetatable({}, { __mode = "k" }) :: any,
		OpaqueChildren = setmetatable({}, { __mode = "k" }) :: any,
		Count = 0,
	}
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

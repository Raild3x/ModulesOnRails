--!strict
--[=[
	@class Linker

	Slim per-instance introspection facade reachable via `tm.Linker`. Under the
	implicit-sharing model there is no manual link/unlink: any table reachable
	(transparently) in two or more managers' trees is observed by all of them and
	writes propagate automatically (see `Propagation`). This facade only answers
	"who am I currently sharing with"; to share a region, just place the same
	table in another manager (or use `tm:Extend(path)`), and to stop, replace the
	reference. Opacity (`Opaque`/`OpaqueChildren`) opts a region out.
]=]

const PropagationModule = require("./Propagation")
const TMTypes = require("./TMTypes")

-- `Linker` and `TableManagerLike` (= `TM_Internal<any>`) are defined in
-- `TMTypes` (a leaf module), so this module can reference the real
-- TableManager type without a circular require with TableManager.luau, which
-- requires this module to build `self.Linker`.
type TableManagerLike = TMTypes.TableManagerLike
export type Linker = TMTypes.Linker

-- Implementation-side view of `Linker`, including the back-reference to the
-- host TableManager. `Linker` itself never exposes `_tm`.
type LinkerImpl = Linker & { _tm: TableManagerLike }

--------------------------------------------------------------------------------
--// Module //--
--------------------------------------------------------------------------------

const Linker = {}
const Linker_MT = { __index = Linker }

--[=[
	@function new
	@within Linker
	@private

	Constructs the lazy `Linker` facade for `tm`.
]=]
const function new(tm: TableManagerLike): Linker
	return setmetatable({ _tm = tm }, Linker_MT) :: any
end

--[=[
	@within Linker
	Returns the other managers currently sharing (co-observing) at least one live
	table identity with this one — de-duplicated, excluding self.
]=]
function Linker.GetManagers(self: LinkerImpl): { any }
	return PropagationModule.GetCoObservers(self._tm)
end

--[=[
	@within Linker
	Returns true if this manager currently shares a live table identity with `other`.
]=]
function Linker.IsLinkedWith(self: LinkerImpl, other: any): boolean
	return PropagationModule.IsLinkedWith(self._tm, other)
end

return {
	new = new,
}

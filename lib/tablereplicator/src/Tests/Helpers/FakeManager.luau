--!strict
--[=[
	@ignore
	@class FakeManager

	A minimal stand-in for a TableManager2 instance, used by specs that only
	exercise `ServerReplicator`/`ClientReplicator`'s targeting and hierarchy
	logic (which never reads/writes through the manager) and don't need real
	diffing. Satisfies `ServerReplicator.new`'s duck-type check (a `Raw` table
	plus a callable `Set`) and `OnApplied`'s "returns a disconnect function"
	contract.
]=]

local FakeManager = {}
FakeManager.__index = FakeManager

export type FakeManager = any -- typeof(setmetatable({} :: { Raw: { [any]: any } }, FakeManager))

function FakeManager.new(raw: { [any]: any }?): FakeManager
	return setmetatable({ Raw = raw or {} }, FakeManager)
end

function FakeManager.Set(_self: FakeManager, _path: any, _value: any) end

function FakeManager.OnApplied(_self: FakeManager, _callback: (any) -> ()): () -> ()
	return function() end
end

function FakeManager.OnDestroy(_self: FakeManager, _callback: () -> ()): () -> ()
	return function() end
end

return FakeManager

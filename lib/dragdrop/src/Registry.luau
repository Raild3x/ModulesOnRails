--[[
	DragDrop — source/target registries.

	Pure store: owns the two instance→entry maps, their Destroying
	auto-unregister, and resolution (an instance or any descendant of a
	registered one resolves to its entry). Registration-driven side effects —
	backend lifecycle, cancelling a drag whose source/hover vanished — are
	injected by the assembler as the callbacks below, so the store depends on
	nothing above it and never requires the state machine.
]]

const Types = require("./Types")
const InputUtil = require("./InputUtil")

type SourceEntry = Types.SourceEntry
type TargetEntry = Types.TargetEntry

const sources: { [Instance]: SourceEntry } = {}
const targets: { [Instance]: TargetEntry } = {}

const Registry = {}

--// Injected by the assembler //--

-- Fired after any registration is added or removed (drives backend lifecycle).
Registry.OnChanged = nil :: (() -> ())?
-- Fired when a source/target unregisters, before OnChanged, so the machine can
-- cancel a drag it was carrying or clear a hover it was showing.
Registry.OnSourceRemoved = nil :: ((entry: SourceEntry) -> ())?
Registry.OnTargetRemoved = nil :: ((entry: TargetEntry) -> ())?

const function fireChanged()
	const callback = Registry.OnChanged
	if callback then
		callback()
	end
end

--// Store //--

function Registry.HasRegistrations(): boolean
	return next(sources) ~= nil or next(targets) ~= nil
end

-- Resolve `instance` (or its nearest registered ancestor) to its entry.
function Registry.ResolveSource(instance: Instance?): SourceEntry?
	return InputUtil.ResolveRegistered(sources, instance)
end

function Registry.ResolveTarget(instance: Instance?): TargetEntry?
	return InputUtil.ResolveRegistered(targets, instance)
end

-- Shared body for both registrations: store the entry, auto-unregister on
-- Destroying, and on teardown notify the removal hook then OnChanged.
-- `getOnRemoved` is read at unregister time, not capture time, because the
-- assembler injects the hooks after this module loads.
const function register<T>(
	store: { [Instance]: T },
	instance: GuiObject,
	entry: T,
	getOnRemoved: () -> ((entry: T) -> ())?
): Types.Unregister
	store[instance] = entry

	local destroyingConnection: RBXScriptConnection? = nil
	const function unregister()
		if store[instance] == entry then
			store[instance] = nil
		end
		if destroyingConnection then
			destroyingConnection:Disconnect()
			destroyingConnection = nil
		end
		const onRemoved = getOnRemoved()
		if onRemoved then
			onRemoved(entry)
		end
		fireChanged()
	end

	destroyingConnection = instance.Destroying:Connect(unregister)
	fireChanged()
	return unregister
end

function Registry.RegisterSource(instance: GuiObject, options: Types.SourceOptions): Types.Unregister
	const entry: SourceEntry = { Instance = instance, Options = options }
	return register(sources, instance, entry, function()
		return Registry.OnSourceRemoved
	end)
end

function Registry.RegisterTarget(instance: GuiObject, options: Types.TargetOptions): Types.Unregister
	const entry: TargetEntry = { Instance = instance, Options = options }
	return register(targets, instance, entry, function()
		return Registry.OnTargetRemoved
	end)
end

return Registry

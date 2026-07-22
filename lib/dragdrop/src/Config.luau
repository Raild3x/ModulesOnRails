--[[
	DragDrop — behavior config store.

	Owns the defaults, per-key validation, and the live config table. Behavior
	knobs only — nothing here styles the ghost (that lives in
	`SourceOptions.BuildGhost`). See Types.Config for the public key docs.
]]

const Types = require("./Types")

-- One schema per config key: its default and the value kind Configure()
-- validates against. `default == nil` marks an optional key (GhostContainer,
-- KeyboardCancelKeyCode) — no default, but still validated when supplied. Both
-- the live defaults and validation derive from this table; adding a knob is one
-- entry here, plus its public Types.Config field and doc.
const CONFIG_SCHEMA: { [string]: { default: any, kind: string } } = {
	DragThresholdPx = { default = 8, kind = "number" },
	TouchSlopPx = { default = 12, kind = "number" },
	LongPressSeconds = { default = 0.4, kind = "number" },
	SnapSpeed = { default = 30, kind = "number" },
	GhostContainer = { kind = "LayerCollector" },
	GamepadLiftKeyCode = { default = Enum.KeyCode.ButtonX, kind = "EnumItem" },
	GamepadDropKeyCode = { default = Enum.KeyCode.ButtonA, kind = "EnumItem" },
	GamepadCancelKeyCode = { default = Enum.KeyCode.ButtonB, kind = "EnumItem" },
	KeyboardLiftKeyCode = { default = Enum.KeyCode.Return, kind = "EnumItem" },
	KeyboardCancelKeyCode = { kind = "EnumItem" },
}

-- Overwrite `target` with the schema's defaults (optional keys stay absent).
const function applyDefaults(target: { [string]: any })
	for key, entry in CONFIG_SCHEMA do
		if entry.default ~= nil then
			target[key] = entry.default
		end
	end
end

const store: { [string]: any } = {}
applyDefaults(store)

const Config = {}

-- The current value for `key` (an override applied via Configure, or the default).
function Config.Get(key: string): any
	return store[key]
end

function Config.Configure(config: Types.Config)
	assert(typeof(config) == "table", "[DragDrop] Configure expects a table")
	for key, value in config :: { [string]: any } do
		const entry = CONFIG_SCHEMA[key]
		if not entry then
			error(`[DragDrop] Unknown config key: {tostring(key)}`, 2)
		end
		const expectedKind = entry.kind
		if expectedKind == "LayerCollector" then
			if typeof(value) ~= "Instance" or not (value :: Instance):IsA("LayerCollector") then
				error(`[DragDrop] Config.{key} must be a LayerCollector`, 2)
			end
		elseif typeof(value) ~= expectedKind then
			error(`[DragDrop] Config.{key} must be a {expectedKind}, got {typeof(value)}`, 2)
		end
		store[key] = value
	end
end

-- Restore every config key to its default. This is the only way to clear an
-- optional key (GhostContainer, KeyboardCancelKeyCode): Configure can't accept
-- nil for them because nil values vanish from Luau tables.
function Config.Reset()
	table.clear(store)
	applyDefaults(store)
end

return Config

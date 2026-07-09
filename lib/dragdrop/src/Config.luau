--[[
	DragDrop — behavior config store.

	Owns the defaults, per-key validation, and the live config table. Behavior
	knobs only — nothing here styles the ghost (that lives in
	`SourceOptions.BuildGhost`). See Types.Config for the public key docs.
]]

const Types = require("./Types")

const DEFAULTS = {
	DragThresholdPx = 8,
	TouchSlopPx = 12,
	LongPressSeconds = 0.4,
	SnapSpeed = 30,
	GamepadLiftKeyCode = Enum.KeyCode.ButtonX,
	GamepadDropKeyCode = Enum.KeyCode.ButtonA,
	GamepadCancelKeyCode = Enum.KeyCode.ButtonB,
	KeyboardLiftKeyCode = Enum.KeyCode.Return,
}

-- Value kind expected per config key, for Configure() validation. Keys whose
-- default is nil (GhostContainer, KeyboardCancelKeyCode) still validate here.
const CONFIG_KINDS: { [string]: string } = {
	DragThresholdPx = "number",
	TouchSlopPx = "number",
	LongPressSeconds = "number",
	SnapSpeed = "number",
	GhostContainer = "LayerCollector",
	GamepadLiftKeyCode = "EnumItem",
	GamepadDropKeyCode = "EnumItem",
	GamepadCancelKeyCode = "EnumItem",
	KeyboardLiftKeyCode = "EnumItem",
	KeyboardCancelKeyCode = "EnumItem",
}

const store: { [string]: any } = table.clone(DEFAULTS)

const Config = {}

-- The current value for `key` (an override applied via Configure, or the default).
function Config.Get(key: string): any
	return store[key]
end

function Config.Configure(config: Types.Config)
	assert(typeof(config) == "table", "[DragDrop] Configure expects a table")
	for key, value in config :: { [string]: any } do
		const expectedKind = CONFIG_KINDS[key]
		if not expectedKind then
			error(`[DragDrop] Unknown config key: {tostring(key)}`, 2)
		end
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

-- Restore every config key to its default. This is the only way to CLEAR an
-- optional key (GhostContainer, KeyboardCancelKeyCode): Configure can't accept
-- nil for them because nil values vanish from Luau tables.
function Config.Reset()
	for key in store do
		store[key] = nil
	end
	for key, value in DEFAULTS do
		store[key] = value
	end
end

return Config

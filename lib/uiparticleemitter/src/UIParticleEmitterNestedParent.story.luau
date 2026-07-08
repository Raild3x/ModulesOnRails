-- Authors: Logan Hunt (Raildex)
-- July 07, 2026
--[[
	UI Labs story for visually verifying spawn-area geometry when the
	emitter is parented several GuiObjects deep under the LayerCollector, and
	when Fire() overrides only part of the spawn area (e.g. just Position).

	A green outline marks the expected spawn rectangle -- bursts should
	always land inside it, regardless of nesting depth or which spawn-area
	fields are overridden. This exercises the fix in
	Emitter.computeSpawnArea: a non-overridden spawn-area field must fall
	back to the UI's own AbsolutePosition/AbsoluteSize, not be re-resolved
	against the (unrelated) LayerCollector's size.
]]

local Fusion = require("../Fusion")
local UIParticleEmitter = require(script.Parent :: any)

local peek = Fusion.peek

local CONTROLS = {
	Enabled = false,
	UsePositionOverride = false, -- Fire() overrides only SpawnAreaPosition; Size/Anchor must still come from the nested Frame
	BurstAmount = 40,
	MaintainRelativePosition = false,
}

return {
	fusion = Fusion,
	controls = CONTROLS,
	story = function(props)
		local controls = props.controls
		local scope = props.scope

		-- Nest the emitter two Frames deep, each sized differently than the
		-- ScreenGui, so a spawn-area bug that resolves the UI's own
		-- Size/Position against the LayerCollector (instead of its real
		-- Parent) becomes visually obvious: particles would spawn far
		-- outside the drawn outline (or collapse to a single point).
		local outer = Instance.new("Frame")
		outer.Name = "NestedContainer_Outer"
		outer.AnchorPoint = Vector2.new(0.5, 0.5)
		outer.Position = UDim2.fromScale(0.5, 0.5)
		outer.Size = UDim2.fromOffset(600, 450)
		outer.BackgroundTransparency = 1
		outer.Parent = props.target
		table.insert(scope, outer)

		local inner = Instance.new("Frame")
		inner.Name = "NestedContainer_Inner"
		inner.AnchorPoint = Vector2.new(0.5, 0.5)
		inner.Position = UDim2.fromScale(0.5, 0.5)
		inner.Size = UDim2.fromScale(0.35, 0.4) -- 210x180, a fraction of `outer` -- NOT of the ScreenGui
		inner.BackgroundTransparency = 1
		inner.Parent = outer

		-- Visible outline marking the expected spawn rectangle.
		local outline = Instance.new("Frame")
		outline.Name = "ExpectedSpawnAreaOutline"
		outline.Size = UDim2.fromScale(1, 1)
		outline.BackgroundTransparency = 1
		outline.Parent = inner
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 2
		stroke.Color = Color3.fromRGB(0, 255, 0)
		stroke.Parent = outline

		local emitter = UIParticleEmitter(scope, {
			Parent = inner,
			SpawnAreaSize = UDim2.fromScale(1, 1), -- exactly fills `inner`
			Enabled = controls.Enabled,
			Rate = 15,
			Color3 = Color3.fromRGB(0, 255, 0),
			LifeTime = NumberRange.new(1, 1.5),
			Velocity = Vector2.zero,
			MaintainRelativePosition = controls.MaintainRelativePosition,
			-- Gravity = 0,
		})

		-- Periodic bursts so the story is useful even with Enabled off.
		local moveThread = task.spawn(function()
			while true do
				task.wait()
				inner.Position = UDim2.fromScale(0.5 + math.sin(os.clock()) / 2, 0.5)
			end
		end)
		local burstThread = task.spawn(function()
			while true do
				task.wait(1.5)
				local amount = peek(controls.BurstAmount)
				if peek(controls.UsePositionOverride) then
					-- Only Position is overridden here (to the same spot the
					-- Frame already occupies) -- Size/Anchor must still fall
					-- back to `inner`'s own AbsoluteSize, keeping bursts
					-- inside the green outline.
					emitter:Fire {
						Amount = amount,
						SpawnAreaAbsolutePosition = inner.AbsolutePosition + inner.AbsoluteSize / 2,
						SpawnAreaSize = UDim2.fromOffset(0, 0),
					}
				else
					emitter:Fire { Amount = amount }
				end
			end
		end)
		table.insert(scope, function()
			task.cancel(burstThread)
			task.cancel(moveThread)
		end)
	end,
}

--[[
	DragDrop — ghost/proxy layer.

	Owns the visual proxy that represents the payload while it is airborne, and
	handles its placement only: it mounts the proxy, follows the pointer, and
	springs between slots on selection devices. Appearance comes from the
	consumer's `BuildGhost` (a fallback plate is used when none is given);
	nothing here scales, tilts, or recolors the proxy.

	Coordinate space: everything is canonical (AbsolutePosition) space. The proxy
	is parented either into the consumer's `GhostContainer` or an internal
	high-DisplayOrder ScreenGui. When the container is a ScreenGui that respects
	the GUI inset, positions are shifted by the inset once so the proxy still
	lands at the requested canonical coordinate.

	Sizing is the builder's contract: the proxy frame is sized to the source's
	on-screen footprint, and the built child fills it via `Size = fromScale(1,1)`
	unless it overrides its own Size. The grab point is captured as an offset
	within the source and kept under the cursor.
]]

const RunService = game:GetService("RunService")
const GuiService = game:GetService("GuiService")

const Types = require("./Types")
const InputUtil = require("./InputUtil")

type Payload = Types.Payload
type GhostHandle = Types.GhostHandle

const GHOST_DISPLAY_ORDER = 1_000_000
const GHOST_ZINDEX = 100
const FALLBACK_GHOST_SIZE = Vector2.new(64, 64)
const DEFAULT_PLATE_CORNER = 8
const DEFAULT_PLATE_STROKE = 2

export type MountParams = {
	BuildGhost: ((payload: Payload, source: GuiObject) -> GuiObject)?,
	Payload: Payload,
	SourceInstance: GuiObject,
	GrabPoint: Vector2, -- pointer position at lift (canonical space)
	Container: LayerCollector?, -- consumer-supplied parent, or nil for the internal ScreenGui
	SnapSpeed: number,
}

const GhostLayer = {}

local internalScreenGui: ScreenGui? = nil

const function ensureInternalScreenGui(): ScreenGui
	if internalScreenGui and internalScreenGui.Parent then
		return internalScreenGui
	end
	const gui = Instance.new("ScreenGui")
	gui.Name = "DragDropGhostLayer"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = GHOST_DISPLAY_ORDER
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = InputUtil.GetBasePlayerGui()
	internalScreenGui = gui
	return gui
end

-- The canonical-space offset to subtract when positioning inside `root`, so a
-- child lands at its intended AbsolutePosition regardless of inset handling.
const function rootInsetOffset(root: LayerCollector): Vector2
	if root:IsA("ScreenGui") and not (root :: ScreenGui).IgnoreGuiInset then
		return GuiService:GetGuiInset()
	end
	return Vector2.zero
end

-- Text for the fallback plate. Tags are the only readable field on an opaque
-- payload, so they are what it shows.
const function debugGhostText(payload: Payload): string
	const tags = payload.Tags
	if typeof(tags) == "table" and #tags > 0 then
		return table.concat(tags, ", ")
	end
	return "(no tags)"
end

const function buildDefaultGhost(payload: Payload): GuiObject
	const frame = Instance.new("Frame")
	frame.Name = "DebugGhost"
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromRGB(40, 40, 48)
	frame.BackgroundTransparency = 0.15
	frame.Active = false

	const corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, DEFAULT_PLATE_CORNER)
	corner.Parent = frame

	const stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 255, 255)
	stroke.Transparency = 0.4
	stroke.Thickness = DEFAULT_PLATE_STROKE
	stroke.Parent = frame

	const label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = debugGhostText(payload)
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextScaled = true
	label.FontFace = Font.fromEnum(Enum.Font.GothamMedium)
	label.Parent = frame

	return frame
end

function GhostLayer.mount(params: MountParams): GhostHandle
	const root = params.Container or ensureInternalScreenGui()
	const insetOffset = rootInsetOffset(root)

	const source = params.SourceInstance
	const sourceSize = source.AbsoluteSize
	const sourcePos = source.AbsolutePosition
	const hasFootprint = sourceSize.X > 0 and sourceSize.Y > 0
	const ghostSize = if hasFootprint then sourceSize else FALLBACK_GHOST_SIZE

	-- Where the grab landed inside the source (canonical offset), clamped so the
	-- same point stays under the cursor.
	local grabAnchor = ghostSize / 2
	if hasFootprint then
		const rel = params.GrabPoint - sourcePos
		grabAnchor = Vector2.new(math.clamp(rel.X, 0, sourceSize.X), math.clamp(rel.Y, 0, sourceSize.Y))
	end

	const ghostFrame = Instance.new("Frame")
	ghostFrame.Name = "DragGhost"
	ghostFrame.BackgroundTransparency = 1
	ghostFrame.Active = false
	ghostFrame.Size = UDim2.fromOffset(ghostSize.X, ghostSize.Y)
	ghostFrame.ZIndex = GHOST_ZINDEX

	local currentTopLeft = sourcePos
	local targetTopLeft = sourcePos
	local mode: "Follow" | "Snap" = "Follow"

	const function applyPosition(topLeft: Vector2)
		ghostFrame.Position = UDim2.fromOffset(topLeft.X - insetOffset.X, topLeft.Y - insetOffset.Y)
	end
	applyPosition(currentTopLeft)

	-- Build the visual child (custom or fallback).
	local child: GuiObject? = nil
	if params.BuildGhost then
		const ok, built = pcall(params.BuildGhost, params.Payload, source)
		if ok and typeof(built) == "Instance" then
			child = built :: GuiObject
		elseif not ok then
			warn("[DragDrop] BuildGhost error:", built)
		end
	end
	if not child then
		child = buildDefaultGhost(params.Payload)
	end
	(child :: GuiObject).Parent = ghostFrame
	ghostFrame.Parent = root

	-- Selection-device snapping runs a frame-rate-independent spring toward the
	-- target rect; pointer following sets position directly (no spring).
	const snapSpeed = params.SnapSpeed
	const renderConnection = RunService.RenderStepped:Connect(function(deltaTime: number)
		if mode ~= "Snap" then
			return
		end
		const alpha = 1 - math.exp(-snapSpeed * deltaTime)
		currentTopLeft = currentTopLeft:Lerp(targetTopLeft, alpha)
		applyPosition(currentTopLeft)
	end)

	const handle: GhostHandle = {
		FollowPointer = function(pointerAbs: Vector2)
			mode = "Follow"
			currentTopLeft = pointerAbs - grabAnchor
			targetTopLeft = currentTopLeft
			applyPosition(currentTopLeft)
		end,
		SnapToRect = function(absPos: Vector2, absSize: Vector2)
			mode = "Snap"
			targetTopLeft = absPos + (absSize - ghostSize) / 2
		end,
		Cleanup = function()
			renderConnection:Disconnect()
			ghostFrame:Destroy()
		end,
	}
	return handle
end

return GhostLayer

--[[
	Programmatic DragDrop demo — UI Labs "generic" advanced story (no UI framework).

	Demonstrates Scriptable input mode: SetInputMode("Scriptable") turns off every
	automatic input backend (mouse/touch/gamepad/keyboard), and drags are driven
	entirely through DragDrop.BeginDrag and the DragHandle it returns — the same
	pattern you would use for tutorials, cutscenes, replays, or automated tests.

	Buttons:
	  ▶ RUN  — one full scripted sequence: BeginDrag lifts the box out of
	           FromSlot, the ghost glides to ToSlot over GlideSeconds via
	           handle:MoveTo, hover resolves (SetHoveredTarget — or the glide's
	           own hit-testing with UseHitTest), then handle:Drop() or
	           handle:Cancel() per DropAtEnd.
	  LIFT   — BeginDrag only: lifts FromSlot's box and holds it airborne so the
	           other buttons can drive the same drag one API call at a time.
	  HOVER  — glides the held ghost onto ToSlot, then SetHoveredTarget(ToSlot).
	  DROP   — DragDrop.Drop(): ends the active drag on the current hover
	           (reverts if nothing is hovered — try LIFT then DROP).
	  CANCEL — DragDrop.Cancel(): reverts the active drag; also works mid-glide.
	  RESET  — restores the board to its starting occupancy.

	UI Labs controls:
	  FromSlot / ToSlot — which slots the scripted drag moves between (1..4).
	  GlideSeconds      — how long the ghost takes to glide.
	  UseHitTest        — true: hover comes from MoveTo's hit-testing (needs the
	                      runtime PlayerGui, i.e. Play mode; in edit mode the
	                      hit-test can't see this story's widget and the drop will
	                      revert). false: hover is set explicitly via
	                      SetHoveredTarget, which works everywhere — including
	                      edit mode.
	  DropAtEnd         — false: the sequence cancels instead, demonstrating a
	                      clean revert (DragEnded fires with a nil target).

	Unlike the interactive story, this one is fully functional in EDIT mode: no
	device input is involved anywhere.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DragDrop = require(ReplicatedStorage.src.dragdrop.src.DragDrop)

local SLOT_COUNT = 4
local SLOT_SIZE = 110
local SLOT_PADDING = 14
local IDLE_COLOR = Color3.fromRGB(40, 40, 48)
local FILLED_COLOR = Color3.fromRGB(70, 70, 90)
local HOVER_COLOR = Color3.fromRGB(60, 140, 90)
local RUN_COLOR = Color3.fromRGB(50, 110, 190)
local ACTION_COLOR = Color3.fromRGB(70, 80, 120)
local DROP_ACTION_COLOR = Color3.fromRGB(46, 125, 80)
local CANCEL_ACTION_COLOR = Color3.fromRGB(150, 60, 60)
local RESET_COLOR = Color3.fromRGB(90, 90, 100)
local DISABLED_COLOR = Color3.fromRGB(55, 55, 62)
local BUTTON_HEIGHT = 34

-- Ease-out quadratic: fast start, gentle landing — reads as "carried", not teleported.
local function easeOutQuad(alpha: number): number
	return 1 - (1 - alpha) ^ 2
end

local function centerOf(gui: GuiObject): Vector2
	return gui.AbsolutePosition + gui.AbsoluteSize / 2
end

return {
	summary = "Scriptable-mode drag driven by a DragHandle: BeginDrag → MoveTo glide → "
		.. "SetHoveredTarget/hit-test → Drop or Cancel. <b>Works fully in edit mode.</b>",

	controls = {
		FromSlot = 1,
		ToSlot = 3,
		GlideSeconds = 0.75,
		UseHitTest = false,
		DropAtEnd = true,
	},

	render = function(props)
		-- Live copy of the control values; props.subscribe keeps it current so the
		-- NEXT run uses whatever the panel shows (no story re-mount involved).
		local controls: { [string]: any } = table.clone(props.controls)
		local unsubscribe = props.subscribe(function(values)
			controls = table.clone(values)
		end)

		-- Scriptable mode: automatic backends off. From here on, the only way a
		-- drag exists is through the DragHandle below.
		DragDrop.SetInputMode("Scriptable")

		-- Mount ghosts inside this story's gui root so they render in the UI Labs
		-- preview instead of the (external) default ScreenGui.
		local layerCollector = props.target:FindFirstAncestorWhichIsA("LayerCollector")
		if layerCollector then
			DragDrop.Configure { GhostContainer = layerCollector }
		end

		local cleanups: { () -> () } = {}
		local function addCleanup(item: any)
			table.insert(
				cleanups,
				if typeof(item) == "function"
					then item
					else function()
						item:Disconnect()
					end
			)
		end

		--------------------------------------------------------------------------
		-- Board UI (slots + action buttons + status line)
		--------------------------------------------------------------------------

		-- Occupancy per slot: a label string, or nil for empty. RESET restores it.
		local occupancy: { string? } = {}
		local function resetOccupancy()
			table.clear(occupancy)
			occupancy[1] = "Box 1"
			occupancy[2] = "Box 2"
		end
		resetOccupancy()

		local slotButtons: { TextButton } = {}

		local container = Instance.new("Frame")
		container.Name = "DragDropScriptableStory"
		container.BackgroundTransparency = 1
		container.AnchorPoint = Vector2.new(0.5, 0.5)
		container.Position = UDim2.fromScale(0.5, 0.5)
		container.Size = UDim2.fromOffset(SLOT_COUNT * (SLOT_SIZE + SLOT_PADDING), SLOT_SIZE + 110)

		local row = Instance.new("Frame")
		row.Name = "Slots"
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, SLOT_SIZE)
		row.Parent = container

		local layout = Instance.new("UIListLayout")
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.Padding = UDim.new(0, SLOT_PADDING)
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
		layout.Parent = row

		-- The action buttons themselves are created (and wired) in the
		-- "Programmatic actions" section below, once the functions they trigger
		-- exist; this row is just their layout container.
		local buttonRow = Instance.new("Frame")
		buttonRow.Name = "Actions"
		buttonRow.BackgroundTransparency = 1
		buttonRow.Position = UDim2.new(0, 0, 0, SLOT_SIZE + 12)
		buttonRow.Size = UDim2.new(1, 0, 0, BUTTON_HEIGHT)
		buttonRow.Parent = container

		local buttonLayout = Instance.new("UIListLayout")
		buttonLayout.FillDirection = Enum.FillDirection.Horizontal
		buttonLayout.Padding = UDim.new(0, 4)
		buttonLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		buttonLayout.VerticalAlignment = Enum.VerticalAlignment.Center
		buttonLayout.Parent = buttonRow

		local status = Instance.new("TextLabel")
		status.Name = "Status"
		status.AnchorPoint = Vector2.new(0.5, 0)
		status.Position = UDim2.new(0.5, 0, 0, SLOT_SIZE + 12 + BUTTON_HEIGHT + 8)
		status.Size = UDim2.new(1, 0, 0, 36)
		status.BackgroundTransparency = 1
		status.Text = "idle — RUN plays a full sequence; LIFT drives it step by step"
		status.TextSize = 14
		status.TextWrapped = true
		status.TextColor3 = Color3.fromRGB(200, 200, 210)
		status.Parent = container

		local function setStatus(text: string)
			status.Text = text
			print("[DragDropScriptable.story]", text)
		end

		-- Assigned once the action buttons exist (below); redraw calls it so the
		-- buttons' enabled/greyed states track the drag state alongside the board.
		local updateButtons: (() -> ())? = nil

		local function redraw()
			local hovered = DragDrop.GetHoveredTarget()
			local payload = DragDrop.GetActivePayload()
			local liftedIndex: number? = payload and payload.FromIndex or nil
			for i, button in slotButtons do
				local isHovered = hovered ~= nil and hovered.Metadata.Index == i
				local isLifted = liftedIndex == i
				button.Text = if isLifted then "" else (occupancy[i] or "")
				if isHovered then
					button.BackgroundColor3 = HOVER_COLOR
				elseif occupancy[i] and not isLifted then
					button.BackgroundColor3 = FILLED_COLOR
				else
					button.BackgroundColor3 = IDLE_COLOR
				end
			end
			if updateButtons then
				updateButtons()
			end
		end

		-- Sources and targets register exactly like the interactive story — the
		-- registration side of the API is identical in Scriptable mode; only the
		-- *driving* of drags changes.
		for i = 1, SLOT_COUNT do
			local button = Instance.new("TextButton")
			button.Name = "Slot" .. i
			button.LayoutOrder = i
			button.Size = UDim2.fromOffset(SLOT_SIZE, SLOT_SIZE)
			button.AutoButtonColor = false
			button.TextColor3 = Color3.fromRGB(255, 255, 255)
			button.TextSize = 20
			button.BackgroundColor3 = IDLE_COLOR

			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0, 10)
			corner.Parent = button

			button.Parent = row
			slotButtons[i] = button

			addCleanup(DragDrop.RegisterSource(button, {
				GetPayload = function()
					local label = occupancy[i]
					if not label then
						return nil
					end
					return { Tags = { "Box" }, Label = label, FromIndex = i }
				end,
			}))

			addCleanup(DragDrop.RegisterTarget(button, {
				Accepts = { "Box" },
				Metadata = { Index = i },
				OnDrop = function(payload, dropTarget)
					local targetIndex = dropTarget.Metadata.Index
					local displaced = occupancy[targetIndex]
					occupancy[targetIndex] = payload.Label
					occupancy[payload.FromIndex] = displaced -- nil = move, else swap
				end,
			}))
		end

		addCleanup(DragDrop.ObserveHoveredTarget(redraw))
		addCleanup(DragDrop.ObserveActivePayload(redraw))
		-- The observers repaint while the drag state clears — BEFORE the target's
		-- OnDrop mutates occupancy — so on their own the board would show the box
		-- back in its source slot after a drop. DragEnded fires last (after
		-- OnDrop/OnDragEnd), so this repaint shows the post-drop occupancy.
		addCleanup(DragDrop.DragEnded:Connect(function()
			redraw()
		end))

		--------------------------------------------------------------------------
		-- Programmatic actions
		--------------------------------------------------------------------------

		local busy = false -- a glide animation is in flight (RUN or HOVER)
		local heldHandle: any = nil -- LIFT's DragHandle, awaiting HOVER/DROP/CANCEL
		local ghostPos: Vector2? = nil -- last position fed to MoveTo (glide start point)

		local function clampedSlots(): (number, number)
			return math.clamp(math.floor(controls.FromSlot), 1, SLOT_COUNT),
				math.clamp(math.floor(controls.ToSlot), 1, SLOT_COUNT)
		end

		-- Frame-stepped eased glide feeding handle:MoveTo. Returns whether the
		-- handle survived to the end — DROP/CANCEL mid-glide ends the drag, the
		-- handle goes inactive, and the loop bails.
		local function glideGhost(handle, fromPos: Vector2, toPos: Vector2): boolean
			local glideSeconds = math.max(controls.GlideSeconds, 0.05)
			local startClock = os.clock()
			while handle:IsActive() do
				local alpha = math.clamp((os.clock() - startClock) / glideSeconds, 0, 1)
				local pos = fromPos:Lerp(toPos, easeOutQuad(alpha))
				handle:MoveTo(pos)
				ghostPos = pos
				if alpha >= 1 then
					return true
				end
				task.wait()
			end
			return false
		end

		-- ▶ RUN: the full sequence in one press (lift → glide → hover → finish).
		local function runSequence()
			if busy or DragDrop.IsDragging() then
				return
			end
			busy = true
			redraw()

			local fromIndex, toIndex = clampedSlots()
			local fromSlot = slotButtons[fromIndex]
			local toSlot = slotButtons[toIndex]

			-- 1. Lift. Passing a position makes this a pointer-controlled drag: the
			--    ghost follows whatever we feed MoveTo, and nothing else touches it.
			local startPos = centerOf(fromSlot)
			local handle = DragDrop.BeginDrag(fromSlot, startPos)
			if not handle then
				setStatus(`BeginDrag refused — slot {fromIndex} is empty? (RESET restocks the board)`)
				busy = false
				redraw()
				return
			end
			ghostPos = startPos
			setStatus(`lifted "{handle:GetPayload().Label}" from slot {fromIndex}`)

			-- 2. Glide the ghost to the destination. MoveTo also hit-tests for a
			--    hovered target under the point each call.
			if not glideGhost(handle, startPos, centerOf(toSlot)) then
				-- The drag can die mid-glide (DROP/CANCEL pressed, source destroyed,
				-- story torn down, ...); the handle stays safe to query either way.
				setStatus("drag ended mid-glide (DROP/CANCEL pressed, or cancelled externally)")
				busy = false
				redraw()
				return
			end

			-- 3. Resolve hover. Hit-testing (via MoveTo above) needs the runtime
			--    PlayerGui; the explicit route works everywhere, edit mode included.
			if not controls.UseHitTest then
				local accepted = handle:SetHoveredTarget(toSlot)
				setStatus(`SetHoveredTarget(slot {toIndex}) -> {accepted}`)
			elseif DragDrop.GetHoveredTarget() == nil then
				setStatus("hit-test found no target (edit mode?) — drop will revert")
			end

			-- 4. Finish: drop (true = landed on a valid target) or cancel (revert).
			if controls.DropAtEnd then
				local landed = handle:Drop()
				setStatus(
					if landed
						then `dropped on slot {toIndex} ✓`
						else "drop reverted — no valid target under the ghost"
				)
			else
				handle:Cancel()
				setStatus("cancelled — box reverted to its slot")
			end

			busy = false
			redraw()
		end

		-- LIFT: BeginDrag only — hold the box airborne for the step buttons.
		local function liftAction()
			if busy or DragDrop.IsDragging() then
				return
			end
			local fromIndex = clampedSlots()
			local fromSlot = slotButtons[fromIndex]
			local startPos = centerOf(fromSlot)
			heldHandle = DragDrop.BeginDrag(fromSlot, startPos)
			if not heldHandle then
				setStatus(`BeginDrag refused — slot {fromIndex} is empty? (RESET restocks the board)`)
				return
			end
			ghostPos = startPos
			setStatus(`holding "{heldHandle:GetPayload().Label}" — HOVER, DROP, or CANCEL`)
		end

		-- HOVER: glide the held ghost onto ToSlot, then hover it explicitly.
		local function hoverAction()
			local handle = heldHandle
			if busy or not handle or not handle:IsActive() then
				return
			end
			local _, toIndex = clampedSlots()
			local toSlot = slotButtons[toIndex]
			busy = true
			redraw()
			task.spawn(function()
				local survived = glideGhost(handle, ghostPos or centerOf(toSlot), centerOf(toSlot))
				-- Hover is set AFTER the last MoveTo: in edit mode MoveTo's hit-test
				-- finds nothing and would clobber an earlier explicit hover.
				if survived then
					local accepted = handle:SetHoveredTarget(toSlot)
					setStatus(`SetHoveredTarget(slot {toIndex}) -> {accepted} — DROP to commit`)
				else
					setStatus("drag ended mid-glide")
				end
				busy = false
				redraw()
			end)
		end

		-- DROP / CANCEL act on whatever drag is live (held or mid-RUN): the
		-- module-level calls need no handle.
		local function dropAction()
			if not DragDrop.IsDragging() then
				return
			end
			local landed = DragDrop.Drop()
			setStatus(if landed then "dropped on the hovered slot ✓" else "drop reverted — nothing was hovered")
		end

		local function cancelAction()
			if not DragDrop.IsDragging() then
				return
			end
			DragDrop.Cancel()
			setStatus("cancelled — box reverted to its slot")
		end

		-- RESET: cancel anything live and restore the starting board.
		local function resetAction()
			DragDrop.Cancel()
			resetOccupancy()
			setStatus("board reset")
			redraw()
		end

		--------------------------------------------------------------------------
		-- Action buttons
		--------------------------------------------------------------------------

		local buttonStates: { { Button: TextButton, Color: Color3, IsEnabled: () -> boolean } } = {}

		local function makeButton(
			order: number,
			label: string,
			color: Color3,
			isEnabled: () -> boolean,
			onPress: () -> ()
		)
			local button = Instance.new("TextButton")
			button.Name = label
			button.LayoutOrder = order
			button.Size = UDim2.fromOffset(78, BUTTON_HEIGHT)
			button.AutoButtonColor = false
			button.Text = label
			button.TextSize = 13
			button.TextColor3 = Color3.fromRGB(255, 255, 255)
			button.BackgroundColor3 = color

			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0, 8)
			corner.Parent = button

			button.Parent = buttonRow
			table.insert(buttonStates, { Button = button, Color = color, IsEnabled = isEnabled })
			addCleanup(button.Activated:Connect(function()
				if isEnabled() then
					onPress()
				end
			end))
		end

		local function canStart(): boolean
			return not busy and not DragDrop.IsDragging()
		end

		makeButton(1, "▶ RUN", RUN_COLOR, canStart, function()
			task.spawn(runSequence) -- the glide loop yields; keep the press handler snappy
		end)
		makeButton(2, "LIFT", ACTION_COLOR, canStart, liftAction)
		makeButton(3, "HOVER", ACTION_COLOR, function()
			return not busy and heldHandle ~= nil and heldHandle:IsActive()
		end, hoverAction)
		makeButton(4, "DROP", DROP_ACTION_COLOR, DragDrop.IsDragging, dropAction)
		makeButton(5, "CANCEL", CANCEL_ACTION_COLOR, DragDrop.IsDragging, cancelAction)
		makeButton(6, "RESET", RESET_COLOR, function()
			return true
		end, resetAction)

		updateButtons = function()
			for _, entry in buttonStates do
				entry.Button.BackgroundColor3 = if entry.IsEnabled() then entry.Color else DISABLED_COLOR
			end
		end

		-- A held handle dies with its drag however it ends; drop the reference and
		-- refresh the button states.
		addCleanup(DragDrop.DragEnded:Connect(function()
			heldHandle = nil
			redraw()
		end))

		container.Parent = props.target
		redraw()

		return function()
			unsubscribe()
			DragDrop.Cancel() -- ends any mid-glide drag; the sequence loop then bails
			for _, cleanup in cleanups do
				cleanup()
			end
			container:Destroy()
			DragDrop.SetInputMode("Automatic") -- hand input back to the devices
			DragDrop.ResetConfig() -- release the GhostContainer override
		end
	end,
}

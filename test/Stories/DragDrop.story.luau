--[[
	Interactive DragDrop demo — dual mode.

	Drag item tiles (each carrying different Tags) onto drop zones (each with a
	different Accepts rule) with the REAL mouse. A zone lights green only while a
	COMPATIBLE item hovers it, so incompatible drags visibly do nothing and revert
	— that green-or-not is the tag system reporting live.

	Two ways to run the SAME file:

	  • EDIT TIME — open it in the UI Labs plugin. UI Labs calls `render(props)`
	    and hands us a mount target. NOTE: real-mouse hit-testing usually can't
	    resolve the plugin widget in pure edit mode, so drops there tend to revert;
	    this mode is best for eyeballing layout/ghosts. (The Scriptable story is the
	    one built to fully work at edit time.)

	  • IN GAME — press Play. The module self-mounts a full-screen board into your
	    PlayerGui the moment it is required ON THE CLIENT, and real dragging works
	    end-to-end because the pointer hit-test can see the PlayerGui. Nothing
	    requires a ReplicatedStorage ModuleScript automatically, so trigger it with
	    a one-line client LocalScript (e.g. in StarterPlayer.StarterPlayerScripts):
	        require(game.ReplicatedStorage.test.Stories["DragDrop.story"])

	What each item/zone proves:
	  🗡 Sword {Weapon}             → Weapon Rack, Chest
	  🍎 Apple {Food, Consumable}   → Pantry (Food), Consumables Bag (Consumable), Chest
	  🧪 Elixir {Potion, Consumable}→ Consumables Bag (Consumable), Chest  — NOT Pantry
	  🔑 Key {Key}                  → Vault (when unlocked), Chest
	  🪙 Coin {Currency}            → Vault (when unlocked), Chest
	  Chest accepts anything (no Accepts). The Vault adds a CanDrop gate driven by
	  the in-UI "Vault" toggle — when locked, Key/Coin are rejected even though
	  their tags match (CanDrop is a finer gate checked on top of Accepts).

	Also demonstrated: OnActivated (click a tile without dragging → status line),
	OnDragEnd (drop vs revert logged), and per-item BuildGhost proxies.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local DragDrop = require(ReplicatedStorage.src.dragdrop.src.DragDrop)

local TILE = 96
local PAD = 12
local IDLE_COLOR = Color3.fromRGB(38, 38, 46)
local ZONE_COLOR = Color3.fromRGB(46, 46, 56)
local HOVER_COLOR = Color3.fromRGB(60, 150, 95)
local RESET_COLOR = Color3.fromRGB(90, 90, 100)
local LIFTED_COLOR = Color3.fromRGB(30, 30, 36)
local TOGGLE_ON_COLOR = Color3.fromRGB(60, 130, 95)
local TOGGLE_OFF_COLOR = Color3.fromRGB(120, 70, 70)

-- The item catalogue. `Tags` is the only field the drag system reads; the rest
-- (Emoji, Name, Color) is ours, carried on the payload for the ghost + board.
local ITEMS = {
	{ Key = "sword", Emoji = "🗡", Name = "Sword", Tags = { "Weapon" }, Color = Color3.fromRGB(120, 70, 70) },
	{
		Key = "apple",
		Emoji = "🍎",
		Name = "Apple",
		Tags = { "Food", "Consumable" },
		Color = Color3.fromRGB(90, 120, 70),
	},
	{
		Key = "elixir",
		Emoji = "🧪",
		Name = "Elixir",
		Tags = { "Potion", "Consumable" },
		Color = Color3.fromRGB(80, 90, 140),
	},
	{ Key = "key", Emoji = "🔑", Name = "Key", Tags = { "Key" }, Color = Color3.fromRGB(140, 120, 60) },
	{ Key = "coin", Emoji = "🪙", Name = "Coin", Tags = { "Currency" }, Color = Color3.fromRGB(150, 130, 70) },
}

-- The drop zones. `Accepts = nil` (Chest) takes anything; `Gated = true` (Vault)
-- adds a CanDrop that reads the in-UI Vault toggle.
local ZONES = {
	{ Name = "Weapon Rack", Accepts = { "Weapon" } },
	{ Name = "Pantry", Accepts = { "Food" } },
	{ Name = "Consumables Bag", Accepts = { "Consumable" } },
	{ Name = "Vault 🔒", Accepts = { "Key", "Currency" }, Gated = true },
	{ Name = "Chest (any)", Accepts = nil },
}

local function tagsText(tags: { string }?): string
	if not tags or #tags == 0 then
		return "any"
	end
	return table.concat(tags, ", ")
end

--------------------------------------------------------------------------------
-- Board builder — shared by both entry points.
--
-- Builds the whole interactive board under `target` (any GuiObject inside a
-- LayerCollector) and returns a cleanup function. Fully self-contained: it owns
-- its own Vault lock toggle, so it behaves identically whether UI Labs mounts it
-- at edit time or a live client mounts it in game.
--------------------------------------------------------------------------------

local function mountBoard(target: GuiObject): () -> ()
	-- Real mouse input (undo any Scriptable mode left over from the other story).
	DragDrop.SetInputMode("Automatic")

	-- Mount ghosts inside this board's gui root so they render alongside it.
	local layerCollector = target:FindFirstAncestorWhichIsA("LayerCollector")
		or (target:IsA("LayerCollector") and target :: LayerCollector)
		or nil
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

	----------------------------------------------------------------------------
	-- State
	----------------------------------------------------------------------------

	-- Which item occupies each inventory slot (nil once dragged out). RESET
	-- restocks. Indexed 1..#ITEMS, parallel to ITEMS.
	local inventory: { any } = {}
	-- What has been dropped into each zone (array of item tables per zone).
	local zoneContents: { { any } } = {}
	local function resetBoard()
		for i, item in ITEMS do
			inventory[i] = item
		end
		for zi in ZONES do
			zoneContents[zi] = {}
		end
	end
	resetBoard()

	-- The Vault's CanDrop gate — flipped by the in-UI toggle below. Sole source
	-- of truth for lock state, so it works in every mode with no control panel.
	local vaultUnlocked = false

	local itemTiles: { TextButton } = {}
	local zoneFrames: { Frame } = {}
	local zoneContentLabels: { TextLabel } = {}

	----------------------------------------------------------------------------
	-- Container + rows
	----------------------------------------------------------------------------

	local container = Instance.new("Frame")
	container.Name = "DragDropStory"
	container.BackgroundTransparency = 1
	container.AnchorPoint = Vector2.new(0.5, 0.5)
	container.Position = UDim2.fromScale(0.5, 0.5)
	container.Size = UDim2.fromOffset(#ZONES * (TILE * 1.4 + PAD), TILE * 2 + 150)

	local invLabel = Instance.new("TextLabel")
	invLabel.Text = "INVENTORY — drag an item out"
	invLabel.Size = UDim2.new(1, 0, 0, 20)
	invLabel.BackgroundTransparency = 1
	invLabel.TextColor3 = Color3.fromRGB(180, 180, 190)
	invLabel.TextSize = 13
	invLabel.TextXAlignment = Enum.TextXAlignment.Left
	invLabel.Parent = container

	local invRow = Instance.new("Frame")
	invRow.Name = "Inventory"
	invRow.BackgroundTransparency = 1
	invRow.Position = UDim2.new(0, 0, 0, 22)
	invRow.Size = UDim2.new(1, 0, 0, TILE)
	invRow.Parent = container

	local invLayout = Instance.new("UIListLayout")
	invLayout.FillDirection = Enum.FillDirection.Horizontal
	invLayout.Padding = UDim.new(0, PAD)
	invLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	invLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	invLayout.Parent = invRow

	local zoneLabel = Instance.new("TextLabel")
	zoneLabel.Text = "DROP ZONES — each accepts different tags"
	zoneLabel.Position = UDim2.new(0, 0, 0, TILE + 34)
	zoneLabel.Size = UDim2.new(1, 0, 0, 20)
	zoneLabel.BackgroundTransparency = 1
	zoneLabel.TextColor3 = Color3.fromRGB(180, 180, 190)
	zoneLabel.TextSize = 13
	zoneLabel.TextXAlignment = Enum.TextXAlignment.Left
	zoneLabel.Parent = container

	local zoneRow = Instance.new("Frame")
	zoneRow.Name = "Zones"
	zoneRow.BackgroundTransparency = 1
	zoneRow.Position = UDim2.new(0, 0, 0, TILE + 56)
	zoneRow.Size = UDim2.new(1, 0, 0, TILE)
	zoneRow.Parent = container

	local zoneLayout = Instance.new("UIListLayout")
	zoneLayout.FillDirection = Enum.FillDirection.Horizontal
	zoneLayout.Padding = UDim.new(0, PAD)
	zoneLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	zoneLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	zoneLayout.Parent = zoneRow

	local status = Instance.new("TextLabel")
	status.Name = "Status"
	status.Position = UDim2.new(0, 0, 0, TILE * 2 + 70)
	status.Size = UDim2.new(1, 0, 0, 40)
	status.BackgroundTransparency = 1
	status.Text = "drag an item onto a zone — green means it fits"
	status.TextSize = 14
	status.TextWrapped = true
	status.TextColor3 = Color3.fromRGB(200, 200, 210)
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.Parent = container

	local function setStatus(text: string)
		status.Text = text
		print("[DragDrop.story]", text)
	end

	----------------------------------------------------------------------------
	-- Top-right controls: Vault lock toggle + RESET
	----------------------------------------------------------------------------

	local vaultToggle = Instance.new("TextButton")
	vaultToggle.Name = "VaultToggle"
	vaultToggle.AnchorPoint = Vector2.new(1, 0)
	vaultToggle.Position = UDim2.new(1, -98, 0, 0)
	vaultToggle.Size = UDim2.fromOffset(150, 26)
	vaultToggle.AutoButtonColor = false
	vaultToggle.TextSize = 13
	vaultToggle.TextColor3 = Color3.fromRGB(255, 255, 255)

	local vaultCorner = Instance.new("UICorner")
	vaultCorner.CornerRadius = UDim.new(0, 8)
	vaultCorner.Parent = vaultToggle
	vaultToggle.Parent = container

	local function refreshVaultToggle()
		vaultToggle.Text = if vaultUnlocked then "Vault: 🔓 Unlocked" else "Vault: 🔒 Locked"
		vaultToggle.BackgroundColor3 = if vaultUnlocked then TOGGLE_ON_COLOR else TOGGLE_OFF_COLOR
	end
	refreshVaultToggle()

	addCleanup(vaultToggle.Activated:Connect(function()
		vaultUnlocked = not vaultUnlocked
		refreshVaultToggle()
		setStatus(if vaultUnlocked then "Vault unlocked — Key/Coin now accepted" else "Vault locked — Key/Coin rejected")
	end))

	----------------------------------------------------------------------------
	-- Redraw
	----------------------------------------------------------------------------

	local function redraw()
		local activePayload = DragDrop.GetActivePayload()
		local liftedSlot: number? = activePayload and activePayload.FromSlot or nil
		local hovered = DragDrop.GetHoveredTarget()
		local hoveredZone: number? = hovered and hovered.Metadata.ZoneIndex or nil

		for i, tile in itemTiles do
			local item = inventory[i]
			local isLifted = liftedSlot == i
			if not item then
				tile.Text = "( empty )"
				tile.BackgroundColor3 = IDLE_COLOR
				tile.TextColor3 = Color3.fromRGB(110, 110, 120)
			elseif isLifted then
				-- While airborne the ghost represents it; dim the source tile.
				tile.Text = ""
				tile.BackgroundColor3 = LIFTED_COLOR
			else
				tile.Text = `{item.Emoji}  {item.Name}\n<font size="10">{tagsText(item.Tags)}</font>`
				tile.BackgroundColor3 = item.Color
				tile.TextColor3 = Color3.fromRGB(255, 255, 255)
			end
		end

		for zi, frame in zoneFrames do
			frame.BackgroundColor3 = if hoveredZone == zi then HOVER_COLOR else ZONE_COLOR
			local emojis = {}
			for _, item in zoneContents[zi] do
				table.insert(emojis, item.Emoji)
			end
			local contentLabel = zoneContentLabels[zi]
			contentLabel.Text = if #emojis > 0 then `{table.concat(emojis, " ")}  ({#emojis})` else "—"
		end
	end

	----------------------------------------------------------------------------
	-- Inventory tiles (sources)
	----------------------------------------------------------------------------

	for i, item in ITEMS do
		local tile = Instance.new("TextButton")
		tile.Name = "Item_" .. item.Key
		tile.LayoutOrder = i
		tile.Size = UDim2.fromOffset(TILE * 1.4, TILE)
		tile.AutoButtonColor = false
		tile.RichText = true
		tile.TextSize = 15
		tile.BackgroundColor3 = item.Color
		tile.TextColor3 = Color3.fromRGB(255, 255, 255)

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 10)
		corner.Parent = tile

		tile.Parent = invRow
		itemTiles[i] = tile

		addCleanup(DragDrop.RegisterSource(tile, {
			GetPayload = function()
				local held = inventory[i]
				if not held then
					return nil -- empty slot refuses the lift
				end
				-- Tags travel with the payload; FromSlot/Item ride along for us.
				return { Tags = held.Tags, Item = held, FromSlot = i }
			end,
			OnActivated = function()
				local held = inventory[i]
				setStatus(if held then `clicked {held.Name} (no drag) — OnActivated` else "clicked an empty slot")
			end,
			OnLift = function(payload)
				setStatus(`lifted {payload.Item.Name} \{{tagsText(payload.Tags)}\}`)
			end,
			OnDragEnd = function(payload, dropped)
				if not dropped then
					setStatus(`{payload.Item.Name} reverted — dropped on nothing compatible`)
				end
			end,
			-- Per-item ghost: a colored plate with the emoji + name.
			BuildGhost = function(payload)
				local ghost = Instance.new("Frame")
				ghost.Size = UDim2.fromScale(1, 1)
				ghost.BackgroundColor3 = payload.Item.Color
				ghost.BackgroundTransparency = 0.1

				local gc = Instance.new("UICorner")
				gc.CornerRadius = UDim.new(0, 10)
				gc.Parent = ghost

				local gs = Instance.new("UIStroke")
				gs.Color = Color3.fromRGB(255, 255, 255)
				gs.Transparency = 0.3
				gs.Thickness = 2
				gs.Parent = ghost

				local gl = Instance.new("TextLabel")
				gl.Size = UDim2.fromScale(1, 1)
				gl.BackgroundTransparency = 1
				gl.Text = `{payload.Item.Emoji}  {payload.Item.Name}`
				gl.TextScaled = true
				gl.TextColor3 = Color3.fromRGB(255, 255, 255)
				gl.FontFace = Font.fromEnum(Enum.Font.GothamMedium)
				gl.Parent = ghost

				return ghost
			end,
		}))
	end

	----------------------------------------------------------------------------
	-- Drop zones (targets)
	----------------------------------------------------------------------------

	for zi, zone in ZONES do
		local frame = Instance.new("Frame")
		frame.Name = "Zone_" .. zi
		frame.LayoutOrder = zi
		frame.Size = UDim2.fromOffset(TILE * 1.4, TILE)
		frame.BackgroundColor3 = ZONE_COLOR

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 10)
		corner.Parent = frame

		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(255, 255, 255)
		stroke.Transparency = 0.75
		stroke.Thickness = 1
		stroke.Parent = frame

		local title = Instance.new("TextLabel")
		title.Size = UDim2.new(1, -8, 0, 34)
		title.Position = UDim2.new(0, 4, 0, 4)
		title.BackgroundTransparency = 1
		title.Text = `{zone.Name}\n<font size="10">accepts: {tagsText(zone.Accepts)}</font>`
		title.RichText = true
		title.TextWrapped = true
		title.TextSize = 13
		title.TextColor3 = Color3.fromRGB(230, 230, 240)
		title.Parent = frame

		local contentLabel = Instance.new("TextLabel")
		contentLabel.Size = UDim2.new(1, -8, 1, -42)
		contentLabel.Position = UDim2.new(0, 4, 0, 40)
		contentLabel.BackgroundTransparency = 1
		contentLabel.Text = "—"
		contentLabel.TextScaled = false
		contentLabel.TextSize = 22
		contentLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		contentLabel.Parent = frame

		frame.Parent = zoneRow
		zoneFrames[zi] = frame
		zoneContentLabels[zi] = contentLabel

		addCleanup(DragDrop.RegisterTarget(frame, {
			Accepts = zone.Accepts,
			Metadata = { ZoneIndex = zi },
			-- The Vault's finer gate: reads the live toggle, so flipping it changes
			-- acceptance without re-mounting.
			CanDrop = if zone.Gated
				then function()
					return vaultUnlocked
				end
				else nil,
			OnDrop = function(payload, dropTarget)
				local targetZone = dropTarget.Metadata.ZoneIndex
				table.insert(zoneContents[targetZone], payload.Item)
				inventory[payload.FromSlot] = nil -- consumed out of inventory
				setStatus(`dropped {payload.Item.Name} into {ZONES[targetZone].Name} ✓`)
			end,
		}))
	end

	----------------------------------------------------------------------------
	-- Repaints
	----------------------------------------------------------------------------

	addCleanup(DragDrop.ObserveHoveredTarget(redraw))
	addCleanup(DragDrop.ObserveActivePayload(redraw))
	-- The observers repaint while the drag state clears — BEFORE OnDrop mutates
	-- the board. DragEnded fires last, so this repaint shows the post-drop board.
	addCleanup(DragDrop.DragEnded:Connect(redraw))

	----------------------------------------------------------------------------
	-- RESET
	----------------------------------------------------------------------------

	local resetButton = Instance.new("TextButton")
	resetButton.Name = "Reset"
	resetButton.AnchorPoint = Vector2.new(1, 0)
	resetButton.Position = UDim2.new(1, 0, 0, 0)
	resetButton.Size = UDim2.fromOffset(90, 26)
	resetButton.AutoButtonColor = false
	resetButton.Text = "RESET"
	resetButton.TextSize = 13
	resetButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	resetButton.BackgroundColor3 = RESET_COLOR

	local resetCorner = Instance.new("UICorner")
	resetCorner.CornerRadius = UDim.new(0, 8)
	resetCorner.Parent = resetButton

	resetButton.Parent = container
	addCleanup(resetButton.Activated:Connect(function()
		DragDrop.Cancel()
		resetBoard()
		setStatus("board reset — inventory restocked, zones cleared")
		redraw()
	end))

	container.Parent = target
	redraw()

	return function()
		DragDrop.Cancel() -- end any in-flight drag
		for _, cleanup in cleanups do
			cleanup()
		end
		container:Destroy()
		DragDrop.ResetConfig() -- release the GhostContainer override
	end
end

--------------------------------------------------------------------------------
-- In-game entry — self-mount when required on a running client.
--
-- Nothing auto-requires a ReplicatedStorage ModuleScript, so this fires when a
-- client-side script requires this module during Play/live (see the header for
-- the one-line launcher). Guarded to the client so a Play-mode server require is
-- a no-op, and skipped entirely in edit mode (UI Labs uses `render` below).
--------------------------------------------------------------------------------

if RunService:IsRunning() and RunService:IsClient() then
	task.spawn(function()
		local player = Players.LocalPlayer or Players.PlayerAdded:Wait()
		local playerGui = player:WaitForChild("PlayerGui")

		local screen = Instance.new("ScreenGui")
		screen.Name = "DragDropStandaloneTest"
		screen.ResetOnSpawn = false
		screen.IgnoreGuiInset = true
		screen.DisplayOrder = 50
		screen.Parent = playerGui

		-- A full-screen backdrop that also gives mountBoard a LayerCollector to
		-- find (mirrors the Frame UI Labs hands us as props.target).
		local root = Instance.new("Frame")
		root.Name = "Root"
		root.Size = UDim2.fromScale(1, 1)
		root.BackgroundColor3 = Color3.fromRGB(22, 22, 28)
		root.BackgroundTransparency = 0.25
		root.Parent = screen

		mountBoard(root)
	end)
end

--------------------------------------------------------------------------------
-- Edit-time entry — the UI Labs generic story.
--------------------------------------------------------------------------------

return {
	summary = "Interactive real-mouse drag: item tiles with varied Tags onto zones with varied Accepts. "
		.. "Zones light green only under a compatible item. Runs in UI Labs <b>and</b> self-mounts in Play mode.",

	render = function(props)
		return mountBoard(props.target)
	end,
}

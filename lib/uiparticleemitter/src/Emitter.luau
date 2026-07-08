-- Authors: Logan Hunt (Raildex)
-- July 06, 2026
--[[
	The UIParticleEmitter Fusion component. Owns the spawn-area frame, the
	particle list, and the update loop. The particles folder and instance pool
	are not owned per-emitter: they are shared across every emitter on the same
	LayerCollector via PoolRegistry, so idle instances released by one emitter
	can be reused by another. The emitter holds a pool handle for as long as it
	has particles to render.

	Lifecycle:
	- The update loop runs only while there are live particles or the emitter
	  is Enabled; it disconnects itself when idle.
	- On scope/UI destruction the emitter stops spawning, but by design live
	  particles finish their natural lifetime first: the update connection
	  deliberately survives the Fusion scope and disconnects itself once the
	  last particle dies (the "draining" phase). Set the
	  `CleanupParticlesImmediately` prop to true to destroy live particles
	  the moment the emitter is destroyed instead.
]]

--// Roblox Services //--
local RunService = game:GetService("RunService")

--// Imports //--
local Fusion = require("../Fusion")
local PoolRegistry = require("./PoolRegistry")
local PropResolver = require("./PropResolver")
local SequenceUtil = require("./SequenceUtil")
local Simulation = require("./Simulation")
local Types = require("./Types")

local peek = Fusion.peek
local Parse = PropResolver.Parse
local Defaults = PropResolver.Defaults

-- RenderStepped only exists on clients; fall back to Heartbeat so the
-- emitter still works (and is testable) in plugin/server contexts.
local STEP_SIGNAL: RBXScriptSignal = if RunService:IsClient() then RunService.RenderStepped else RunService.Heartbeat

local Emitter = {}
Emitter.__index = Emitter

--------------------------------------------------------------------------------
-- Internal helpers
--------------------------------------------------------------------------------

local function resolveUDim2(value: UDim2, containerSize: Vector2): (number, number)
	return value.X.Scale * containerSize.X + value.X.Offset, value.Y.Scale * containerSize.Y + value.Y.Offset
end

-- Computes the absolute spawn rectangle. Fire() overrides win over the UI
-- frame's own geometry. Overridden UDim2 fields (SpawnAreaPosition/Size) are
-- explicitly authored as fractions of the LayerCollector and are resolved
-- against it; a field left un-overridden falls back to the UI's own
-- Absolute* properties directly rather than re-resolving ui.Position/ui.Size
-- against the LayerCollector -- those UDim2s are relative to ui.Parent, which
-- may be nested arbitrarily deep under the LayerCollector and have a
-- completely different size.
local function computeSpawnArea(
	ui: Frame,
	layerCollector: LayerCollector,
	area: Types.SpawnAreaOverrides?
): (Vector2, Vector2)
	local hasOverride = area
		and (
			area.SpawnAreaPosition
			or area.SpawnAreaAbsolutePosition
			or area.SpawnAreaAnchorPoint
			or area.SpawnAreaSize
		)
	if not hasOverride then
		return ui.AbsolutePosition, ui.AbsoluteSize
	end
	assert(area, "unreachable")

	local layerCollectorSize = layerCollector.AbsoluteSize

	local containerSize: Vector2
	if area.SpawnAreaSize then
		local sizeX, sizeY = resolveUDim2(area.SpawnAreaSize, layerCollectorSize)
		containerSize = Vector2.new(sizeX, sizeY)
	else
		containerSize = ui.AbsoluteSize
	end

	-- Where the anchor point sits in absolute space, independent of
	-- containerSize (which may itself be overridden to a different size).
	local anchorPos: Vector2
	if area.SpawnAreaAbsolutePosition then
		anchorPos = area.SpawnAreaAbsolutePosition
	elseif area.SpawnAreaPosition then
		local posX, posY = resolveUDim2(area.SpawnAreaPosition, layerCollectorSize)
		anchorPos = Vector2.new(posX, posY)
	else
		anchorPos = ui.AbsolutePosition + ui.AnchorPoint * ui.AbsoluteSize
	end

	local anchor = area.SpawnAreaAnchorPoint or ui.AnchorPoint
	return anchorPos - anchor * containerSize, containerSize
end

--------------------------------------------------------------------------------
-- Constructor
--------------------------------------------------------------------------------

function Emitter.new(scope: Types.Scope<any>, props: Types.EmitterProps)
	local self = setmetatable({}, Emitter)

	self._props = props
	self._particles = {} :: { Types.Particle }
	self._rng = if props.Seed then Random.new(props.Seed) else Random.new()
	self._maxSizeGetter = function()
		return peek(props.MaxParticles) or Defaults.MaxParticles
	end
	self._timeSinceLastSpawn = 0
	self._lastInset = 0
	self._connection = nil :: RBXScriptConnection?
	self._poolHandle = nil :: PoolRegistry.Handle?
	self._destroyed = false -- destruction initiated (no more spawning)
	self._dead = false -- destruction finished (folder gone, loop stopped)
	self._warnedNoTarget = false

	self.UI = Fusion.New(scope, "Frame") {
		Name = "UIParticleEmitter",
		Parent = props.Parent,
		Position = props.SpawnAreaPosition or UDim2.fromScale(0.5, 0.5),
		AnchorPoint = props.SpawnAreaAnchorPoint or Vector2.new(0.5, 0.5),
		Size = props.SpawnAreaSize or UDim2.fromScale(0, 0),
		BackgroundTransparency = 1,
		ZIndex = 10,
	} :: Frame

	self.UI.Destroying:Connect(function()
		self:_OnDestroyed()
	end)
	table.insert(scope, function()
		self:_OnDestroyed()
	end)

	-- Enabled may be a constant or a state object; Observer only accepts
	-- state objects, so constants are handled with a one-time check.
	const function onEnabledChanged()
		if peek(props.Enabled) and not self._destroyed then
			self._timeSinceLastSpawn = 0
			self:_EnsureRunning()
		end
	end
	if typeof(props.Enabled) == "table" then
		Fusion.Observer(scope, props.Enabled :: any):onBind(onEnabledChanged)
	else
		onEnabledChanged()
	end

	if typeof(props.Visible) == "table" then
		Fusion.Observer(scope, props.Visible :: any):onChange(function()
			local visible = peek(props.Visible) ~= false
			for _, particle in self._particles do
				particle.Instance.Visible = visible
			end
		end)
	end

	return self
end

--------------------------------------------------------------------------------
-- Update loop
--------------------------------------------------------------------------------

function Emitter:_EnsureRunning()
	if self._connection or self._dead then
		return
	end
	self._connection = STEP_SIGNAL:Connect(function(dt: number)
		self:_Step(dt)
	end)
end

function Emitter:_Disconnect()
	if self._connection then
		self._connection:Disconnect()
		self._connection = nil
	end
end

--[[
	Advances the emitter by `dt` seconds: simulates and renders every live
	particle, reclaims dead ones, spawns new ones while Enabled, and manages
	the loop/drain lifecycle. Public behavior is driven by the step signal;
	specs may call this directly (after :Stop()) to simulate time.
]]
function Emitter:_Step(dt: number)
	debug.profilebegin("UIParticleEmitter Step")
	const props = self._props
	const scaledDt = dt * (peek(props.TimeScale) or 1)

	local env: Types.SimulationEnv = {
		Drag = peek(props.Drag) or Defaults.Drag,
		Gravity = Vector2.new(0, peek(props.Gravity) or Defaults.Gravity),
		Wind = peek(props.Wind),
	}

	-- GUI inset compensation: prefer the (possibly destroyed) UI's ancestor,
	-- fall back to the shared pool handle's LayerCollector during draining.
	local inset = self._lastInset
	local layerCollector: LayerCollector? = nil
	if self.UI.Parent then
		layerCollector = self.UI:FindFirstAncestorWhichIsA("LayerCollector")
	elseif self._poolHandle then
		layerCollector = self._poolHandle.layerCollector
	end
	if layerCollector then
		inset = layerCollector.AbsolutePosition.Y
		self._lastInset = inset
	end

	-- Simulate, render, and reap in one pass (swap-remove keeps this O(n)).
	const particles = self._particles
	local i = 1
	while particles[i] do
		local particle = particles[i]
		Simulation.Step(particle, scaledDt, env)
		if particle.LifeTime <= 0 then
			(self._poolHandle :: PoolRegistry.Handle).pool:Release(particle.Instance)
			local last = #particles
			particles[i] = particles[last]
			particles[last] = nil
		else
			Simulation.ApplyVisuals(particle, inset)
			i += 1
		end
	end

	-- Continuous spawning
	if not self._destroyed and peek(props.Enabled) then
		const rate = Parse(props.Rate) or Defaults.Rate
		if rate > 0 then
			self._timeSinceLastSpawn += scaledDt
			const spawnInterval = 1 / rate
			while self._timeSinceLastSpawn >= spawnInterval do
				self._timeSinceLastSpawn -= spawnInterval
				self:_SpawnOne(PropResolver.ResolveSpawnParams(props, nil, self._rng), nil)
			end
		end
	end

	-- Lifecycle transitions once fully drained/idle
	if #particles == 0 then
		if self._destroyed then
			self:_FinishDestroy()
		elseif not peek(props.Enabled) then
			self:_Disconnect()
		end
	end
	debug.profileend()
end

--------------------------------------------------------------------------------
-- Spawning
--------------------------------------------------------------------------------

function Emitter:_WarnOnce(reason: string)
	if not self._warnedNoTarget then
		self._warnedNoTarget = true
		warn(`UIParticleEmitter: cannot spawn particles, {reason}`)
	end
end

-- Returns the shared pool handle for `layerCollector`, acquiring one on first
-- use. If the emitter has migrated to a different LayerCollector, its live
-- particles are moved into the new shared folder before the old handle is
-- released (which may tear down the old shared folder/pool).
function Emitter:_EnsurePoolHandle(layerCollector: LayerCollector): PoolRegistry.Handle
	local old = self._poolHandle
	if old and old.layerCollector == layerCollector then
		return old
	end

	local handle = PoolRegistry.Acquire(layerCollector, self._maxSizeGetter)
	self._poolHandle = handle
	if old then
		local folder = PoolRegistry.GetFolder(handle)
		for _, particle in self._particles do
			particle.Instance.Parent = folder
		end
		PoolRegistry.Release(old)
	end
	return handle
end

function Emitter:_SpawnOne(params: Types.SpawnParams, area: Types.SpawnAreaOverrides?)
	local props = self._props
	if params.LifeTime <= 0 then
		return
	end
	if #self._particles >= (peek(props.MaxParticles) or Defaults.MaxParticles) then
		return
	end

	local ui = self.UI :: Frame
	if ui.Parent == nil then
		self:_WarnOnce("the emitter UI has no parent")
		return
	end
	local layerCollector = ui:FindFirstAncestorWhichIsA("LayerCollector")
	if not layerCollector then
		self:_WarnOnce("no LayerCollector ancestor found")
		return
	end
	self._warnedNoTarget = false

	local inset = layerCollector.AbsolutePosition.Y
	self._lastInset = inset

	-- Shared per-LayerCollector particles folder + pool, acquired lazily and
	-- re-acquired if the emitter moved to a different LayerCollector.
	local handle = self:_EnsurePoolHandle(layerCollector)
	local folder = PoolRegistry.GetFolder(handle)

	local containerPos, containerSize = computeSpawnArea(ui, layerCollector, area)

	-- Bake constant size scales into the base size; only sequences animate.
	local baseSize = params.Size
	local sizeScaleSequence: NumberSequence? = nil
	local initialScale = 1
	if typeof(params.SizeScale) == "NumberSequence" then
		sizeScaleSequence = params.SizeScale
		initialScale = SequenceUtil.EvaluateNumberSequence(sizeScaleSequence, 0)
	elseif params.SizeScale ~= nil then
		baseSize *= params.SizeScale :: number
	end

	local colorSequence: ColorSequence? = if typeof(params.Color3) == "ColorSequence" then params.Color3 else nil
	local initialColor: Color3 = if colorSequence
		then SequenceUtil.EvaluateColorSequence(colorSequence, 0)
		else params.Color3 :: Color3
	local transparencySequence: NumberSequence? = if typeof(params.Transparency) == "NumberSequence"
		then params.Transparency
		else nil
	local initialTransparency: number = if transparencySequence
		then SequenceUtil.EvaluateNumberSequence(transparencySequence, 0)
		else params.Transparency :: number

	-- Start position, randomly distributed within the spawn area (or its
	-- center when the area has no size).
	local startX: number, startY: number
	if containerSize.X > 0 and containerSize.Y > 0 then
		startX = containerPos.X + self._rng:NextNumber() * containerSize.X
		startY = containerPos.Y + self._rng:NextNumber() * containerSize.Y
	else
		startX = containerPos.X + containerSize.X / 2
		startY = containerPos.Y + containerSize.Y / 2
	end

	local isImage = params.Image ~= nil
	local instance = handle.pool:Acquire(isImage)
	local initialSize = baseSize * initialScale
	instance.Size = UDim2.fromOffset(initialSize.X, initialSize.Y)
	instance.Rotation = params.Rotation
	instance.Position = UDim2.fromOffset(startX, startY - inset)
	instance.Visible = peek(props.Visible) ~= false
	if isImage then
		local imageLabel = instance :: ImageLabel
		imageLabel.Image = params.Image :: string
		imageLabel.ImageColor3 = initialColor
		imageLabel.ImageTransparency = initialTransparency
	else
		instance.BackgroundColor3 = initialColor
		instance.BackgroundTransparency = initialTransparency
	end
	instance.Parent = folder

	table.insert(self._particles, {
		Instance = instance,
		IsImage = isImage,
		Position = Vector2.new(startX, startY),
		Velocity = params.Velocity,
		LifeTime = params.LifeTime,
		InitialLifeTime = params.LifeTime,
		Rotation = params.Rotation,
		RotationSpeed = params.RotationSpeed,
		BaseSize = baseSize,
		SizeScaleSequence = sizeScaleSequence,
		BaseColor = if colorSequence then nil else params.Color3 :: Color3,
		ColorSequence = colorSequence,
		TransparencySequence = transparencySequence,
		BaseTransparency = if transparencySequence then nil else params.Transparency :: number,
	})

	self:_EnsureRunning()
end

--------------------------------------------------------------------------------
-- Destruction
--------------------------------------------------------------------------------

function Emitter:_OnDestroyed()
	if self._destroyed then
		return
	end
	self._destroyed = true

	if peek(self._props.CleanupParticlesImmediately) then
		for _, particle in self._particles do
			particle.Instance:Destroy()
		end
		table.clear(self._particles)
	end

	if #self._particles == 0 then
		self:_FinishDestroy()
	else
		-- Drain: keep stepping (outside the destroyed scope, intentionally)
		-- until the last particle dies.
		self:_EnsureRunning()
	end
end

function Emitter:_FinishDestroy()
	if self._dead then
		return
	end
	self._dead = true
	self:_Disconnect()
	-- Drop our share of the pool; the registry tears down the shared folder
	-- and pool once the last emitter on the LayerCollector releases.
	if self._poolHandle then
		PoolRegistry.Release(self._poolHandle)
		self._poolHandle = nil
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--[=[
	@within UIParticleEmitter
	@param config FireConfig? -- Optional per-burst overrides

	Fires a burst of particles immediately. `Amount` defaults to the
	emitter's `Rate`. All particle props may be overridden per burst, and the
	spawn area may be overridden via `SpawnAreaPosition`,
	`SpawnAreaAbsolutePosition`, `SpawnAreaAnchorPoint`, and `SpawnAreaSize`.
	A no-op once the emitter has been destroyed.
]=]
function Emitter:Fire(config: Types.FireConfig?)
	if self._destroyed then
		return
	end
	local cfg: Types.FireConfig = config or {}
	local props = self._props
	local amount = Parse(cfg.Amount) or Parse(props.Rate) or Defaults.Rate

	-- Spawn area overrides resolve once per burst, not per particle.
	local area: Types.SpawnAreaOverrides = {
		SpawnAreaPosition = Parse(cfg.SpawnAreaPosition),
		SpawnAreaAbsolutePosition = Parse(cfg.SpawnAreaAbsolutePosition),
		SpawnAreaAnchorPoint = Parse(cfg.SpawnAreaAnchorPoint),
		SpawnAreaSize = Parse(cfg.SpawnAreaSize),
	}

	for _ = 1, amount do
		self:_SpawnOne(PropResolver.ResolveSpawnParams(props, cfg, self._rng), area)
	end
end

--[=[
	@within UIParticleEmitter

	Disconnects the update loop. Live particles freeze in place until the
	loop restarts (via `Fire`, or `Enabled` becoming true again).
]=]
function Emitter:Stop()
	self:_Disconnect()
end

--[=[
	@within UIParticleEmitter

	Immediately removes all live particles (recycling their instances into
	the pool while the emitter is alive).
]=]
function Emitter:Clear()
	local handle = self._poolHandle
	for _, particle in self._particles do
		if handle then
			handle.pool:Release(particle.Instance)
		else
			particle.Instance:Destroy()
		end
	end
	table.clear(self._particles)
	if self._destroyed then
		self:_FinishDestroy()
	end
end

--[=[
	@within UIParticleEmitter
	@return number -- The number of live particles

	Returns the current number of live particles.
]=]
function Emitter:GetParticleCount(): number
	return #self._particles
end

return Emitter

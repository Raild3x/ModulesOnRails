-- Authors: Logan Hunt (Raildex)
-- July 06, 2026
--[[
	Per-emitter GuiObject pool. Reuses Frame/ImageLabel instances instead of
	Instance.new/Destroy per particle. Released instances stay parented to the
	particles folder with Visible = false to avoid reparent churn.
]]

local ParticlePool = {}
ParticlePool.__index = ParticlePool

export type ParticlePool = typeof(setmetatable(
	{} :: {
		_getMaxSize: () -> number,
		_frames: { Frame },
		_images: { ImageLabel },
		_destroyed: boolean,
	},
	ParticlePool
))

function ParticlePool.new(getMaxSize: () -> number): ParticlePool
	return setmetatable({
		_getMaxSize = getMaxSize,
		_frames = {},
		_images = {},
		_destroyed = false,
	}, ParticlePool)
end

--[[
	Pops a pooled instance of the requested kind, or creates a fresh one with
	the static particle properties applied. The caller is responsible for
	setting all per-particle properties (size, colors, rotation, position...).
]]
function ParticlePool.Acquire(self: ParticlePool, isImage: boolean): GuiObject
	local pooled: GuiObject? = if isImage then table.remove(self._images) else table.remove(self._frames)
	if pooled then
		pooled.Visible = true
		return pooled
	end

	local instance: GuiObject
	if isImage then
		local imageLabel = Instance.new("ImageLabel")
		imageLabel.BackgroundTransparency = 1
		instance = imageLabel
	else
		instance = Instance.new("Frame")
	end
	instance.AnchorPoint = Vector2.new(0.5, 0.5)
	instance.BorderSizePixel = 0
	instance.ZIndex = 10
	return instance
end

--[[
	Returns an instance to the pool (hidden, still parented), or destroys it
	if the pool is full or has been destroyed.
]]
function ParticlePool.Release(self: ParticlePool, instance: GuiObject)
	if self._destroyed or #self._frames + #self._images >= self._getMaxSize() then
		instance:Destroy()
		return
	end

	instance.Visible = false
	if instance:IsA("ImageLabel") then
		table.insert(self._images, instance)
	else
		table.insert(self._frames, instance :: Frame)
	end
end

--[[
	Destroys all pooled instances. Any instance released afterwards is
	destroyed instead of pooled.
]]
function ParticlePool.Destroy(self: ParticlePool)
	if self._destroyed then
		return
	end
	self._destroyed = true
	for _, instance in self._frames do
		instance:Destroy()
	end
	for _, instance in self._images do
		instance:Destroy()
	end
	table.clear(self._frames)
	table.clear(self._images)
end

return ParticlePool

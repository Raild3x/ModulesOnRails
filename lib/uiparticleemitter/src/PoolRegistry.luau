-- Authors: Logan Hunt (Raildex)
-- July 07, 2026
--[[
	Per-LayerCollector shared particle resources. Every emitter that spawns into
	the same LayerCollector shares one `UIParticles` folder and one ParticlePool,
	so an idle (recycled) instance released by one emitter can be reused by
	another without reparent churn: released instances stay parented to the
	shared folder, and any emitter on that LayerCollector re-acquires them in
	place.

	Each emitter holds a Handle. The shared folder and pool are created with the
	first handle and destroyed when the last handle is released (refcounted). The
	pool's idle cap is the sum of the live `MaxParticles` of every registered
	emitter, so in the worst case -- every emitter releasing its full complement
	at once -- they all still fit.
]]

local ParticlePool = require("./ParticlePool")

local PARTICLES_FOLDER_NAME = "UIParticles"

type Entry = {
	layerCollector: LayerCollector,
	folder: Folder,
	pool: ParticlePool.ParticlePool,
	getters: { [Handle]: () -> number },
	count: number,
}

export type Handle = {
	pool: ParticlePool.ParticlePool,
	layerCollector: LayerCollector,
	_entry: Entry,
}

local PoolRegistry = {}

-- Live entries keyed by LayerCollector. Entries are inserted with the first
-- Acquire and removed when the last handle is Released, so this never retains
-- resources for a LayerCollector with no active emitters.
local entries: { [LayerCollector]: Entry } = {}

local function makeFolder(layerCollector: LayerCollector): Folder
	local folder = Instance.new("Folder")
	folder.Name = PARTICLES_FOLDER_NAME
	folder.Parent = layerCollector
	return folder
end

--[[
	Registers an emitter against `layerCollector`, creating the shared folder and
	pool on first use. `getMaxSize` reports that emitter's current live particle
	cap; the shared pool's idle cap is the sum across all registered handles.
]]
function PoolRegistry.Acquire(layerCollector: LayerCollector, getMaxSize: () -> number): Handle
	local entry = entries[layerCollector]
	if not entry then
		local created: Entry
		created = {
			layerCollector = layerCollector,
			folder = makeFolder(layerCollector),
			pool = ParticlePool.new(function()
				local total = 0
				for _, getter in created.getters do
					total += getter()
				end
				return total
			end),
			getters = {},
			count = 0,
		}
		entry = created
		entries[layerCollector] = entry
	end

	local handle: Handle = {
		pool = entry.pool,
		layerCollector = layerCollector,
		_entry = entry,
	}
	entry.getters[handle] = getMaxSize
	entry.count += 1
	return handle
end

--[[
	Returns the shared folder, revalidating it first: the folder may have been
	destroyed or re-homed externally, in which case it is recreated/reparented
	under the LayerCollector.
]]
function PoolRegistry.GetFolder(handle: Handle): Folder
	local entry = handle._entry
	if entry.folder.Parent ~= entry.layerCollector then
		if entry.folder.Parent == nil then
			entry.folder = makeFolder(entry.layerCollector)
		else
			entry.folder.Parent = entry.layerCollector
		end
	end
	return entry.folder
end

--[[
	Deregisters a handle. When the last handle for a LayerCollector is released,
	the shared pool and folder are destroyed. Idempotent: releasing an
	already-released handle is a no-op.
]]
function PoolRegistry.Release(handle: Handle)
	local entry = handle._entry
	if entry.getters[handle] == nil then
		return
	end
	entry.getters[handle] = nil
	entry.count -= 1
	if entry.count <= 0 then
		entry.pool:Destroy()
		if entry.folder.Parent then
			entry.folder:Destroy()
		end
		entries[entry.layerCollector] = nil
	end
end

return PoolRegistry

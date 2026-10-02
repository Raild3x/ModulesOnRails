--!strict
-- Prototype (ticket 37's "one floor per terrain" option; deferred until after Track F): the adapter's output for
-- ForestRiver, with every Meadow* floor merged into "Meadow" and every Forest* into "Forest".
-- Seams inside a merged floor go; so do cuts that terrain Parts make on terrain floors.
-- Returns transform(map, built, Adapter) -> desc.
local function key(ring: { any }): string
	local t = {}
	for _, p in ring do
		table.insert(t, string.format("%.3f,%.3f", p.x, p.z))
	end
	table.sort(t)
	return table.concat(t, ";")
end

local function group(name: string): string?
	if string.find(name, "^Meadow") then
		return "Meadow"
	elseif string.find(name, "^Forest") then
		return "Forest"
	end
	return nil
end

return function(map: any, built: any, Adapter: any): any
	local desc = Adapter.FromParts(built.Walkable, built.Obstacles, map.AdapterOptions)
	-- Cuts terrain Parts make on terrain floors, by geometry.
	local terrain = {}
	for _, p in built.Walkable do
		if group(p.Name) then
			table.insert(terrain, p)
		end
	end
	local own = Adapter.FromParts(terrain, {}, {})
	local byTerrain = {}
	for _, f in own.Floors do
		for _, r in f.Obstacles or {} do
			byTerrain[key(r)] = true
		end
	end
	local floors = {}
	for name, f in desc.Floors do
		local g = group(name)
		if g == nil then
			floors[name] = f
			continue
		end
		local m = floors[g] or { Walkable = {}, Obstacles = {}, Areas = {} }
		floors[g] = m
		for _, r in f.Walkable do
			table.insert(m.Walkable, r)
		end
		for _, r in f.Obstacles or {} do
			if not byTerrain[key(r)] then
				table.insert(m.Obstacles, r)
			end
		end
		for _, a in f.Areas or {} do
			table.insert(m.Areas, a)
		end
	end
	local seams = {}
	for _, s in desc.Seams do
		local a, b = group(s.FloorA) or s.FloorA, group(s.FloorB) or s.FloorB
		if a ~= b then
			table.insert(seams, { FloorA = a, FloorB = b, From = s.From, To = s.To })
		end
	end
	return { Floors = floors, Seams = seams, MaxAgentRadius = 2 }
end

-- Ticket 36's measurements on the Street map: for every start on the south sidewalk and goal
-- on the north one (13 x 13 pairs), at several road costs:
--   jaywalk  the share of paths that enter the road (the harness's Avoids check);
--   stretch  path length / the straight line (mean, max): the detour overhead;
--   excess   path length / the best crosswalk-only path (road excluded) for paths that stay off
--            the road: how far the search's crosswalk choice is from the best one.
-- Run from the repo root: lune run tools/navmesh/maps/street_measure.luau [MapName]
local process = require("@lune/process")
local roblox = require("@lune/roblox") :: any
local NavMesh = require("../../../lib/navmesh/src/NavMesh")
local Adapter = require("../../../lib/navmeshadapter/src/NavMeshAdapter")
local Harness = require("./Harness")

local dynRequire: any = require
local street = dynRequire("./Maps/" .. (process.args[1] or "Street"))
local COSTS = { 1, 1.5, 2, 3, 5, 10, math.huge }
local XS = { 4, 12, 20, 28, 36, 44, 52, 60, 68, 76, 84, 92, 96 }

local scenarios = {}
for _, cost in COSTS do
	for _, a in XS do
		for _, b in XS do
			table.insert(scenarios, {
				Name = `{cost} {a} {b}`,
				Cost = cost,
				From = `S{a}`,
				To = `N{b}`,
				Filter = function(areas)
					return { AreaCosts = { [areas.Road] = cost } }
				end,
				Expect = { Status = "Success", Avoids = { "Road" } },
			})
		end
	end
end
local map = table.clone(street)
map.Scenarios = scenarios
map.Build = function(rbx, parent)
	local built = street.Build(rbx, parent)
	for _, x in XS do
		built.Points[`S{x}`] = rbx.Vector3.new(x, 0, 7)
		built.Points[`N{x}`] = rbx.Vector3.new(x, 0, 37)
	end
	return built
end

local report = Harness.Run(map, NavMesh, Adapter, roblox)
local best = {} -- crosswalk-only length per pair
for _, row in report.Rows do
	if row.Scenario.Cost == math.huge then
		best[row.Scenario.From .. row.Scenario.To] = row.Path.Length
	end
end
print("road cost  jaywalk  stretch mean  max   excess mean  max   (n off-road)  not Success")
for _, cost in COSTS do
	local n, jay, sum, max, xs, xmax, xn, bad = 0, 0, 0, 0, 0, 0, 0, 0
	local worst = ""
	for _, row in report.Rows do
		local s = row.Scenario
		if s.Cost ~= cost then
			continue
		end
		n += 1
		if row.Path.Status ~= "Success" then
			bad += 1
			continue
		end
		local from, to = report.Built.Points[s.From], report.Built.Points[s.To]
		local stretch = row.Path.Length / (to - from).Magnitude
		sum += stretch
		max = math.max(max, stretch)
		local entered = false
		for _, f in row.Failed do
			entered = entered or string.find(f, "Avoids:", 1, true) == 1
		end
		if entered then
			jay += 1
		else
			local excess = row.Path.Length / best[s.From .. s.To]
			xs += excess
			xn += 1
			if excess > xmax then
				xmax, worst =
					excess, `{s.From}->{s.To} {string.format("%.1f vs %.1f", row.Path.Length, best[s.From .. s.To])}`
			end
		end
	end
	print(
		string.format(
			"%9s  %6.1f%%  %12.3f %5.3f  %11.3f %5.3f  (%d)  %d  %s",
			tostring(cost),
			100 * jay / n,
			sum / (n - bad),
			max,
			if xn > 0 then xs / xn else 0,
			xmax,
			xn,
			bad,
			worst
		)
	)
end

-- Function to determine orientation of three points
local function orientation(p: Vector2, q: Vector2, r: Vector2): number
	local val = (q.Y - p.Y) * (r.X - q.X) - (q.X - p.X) * (r.Y - q.Y)
	if val == 0 then
		return 0 -- Collinear
	elseif val > 0 then
		return 1 -- Clockwise
	else
		return 2 -- Counterclockwise
	end
end

--[=[
	Uses Graham's scan algorithm to calculate the convex hull of a set of 2D points.
	Graham's scan is better suited for larger sets of points than Giftwrapping.
	However, they will produce the same result.

	@param points -- The points to calculate the convex hull of.
	@return {Vector2} -- The convex hull of the points.

	```lua
	local points = {
		Vector2.new(0, 0),
		Vector2.new(1, 0),
		Vector2.new(0.5, 0.5)
		Vector2.new(0, 1),
		Vector2.new(1, 1),
	}

	local hull = calculateConvexHullGrahamScan(points) -- Output: {Vector2.new(0, 0), Vector2.new(1, 0), Vector2.new(1, 1), Vector2.new(0, 1)}
	```
]=]
local function calculateConvexHullGrahamScan(points: { Vector2 }): { Vector2 }
	local n = #points
	if n < 3 then
		warn("Cannot calculate convex hull with less than 3 points.")
		return points
	end

	-- Find the lowest point (break ties by X)
	local lowest = 1
	for i = 2, n do
		if points[i].Y < points[lowest].Y or (points[i].Y == points[lowest].Y and points[i].X < points[lowest].X) then
			lowest = i
		end
	end

	-- Swap lowest point to front
	points[1], points[lowest] = points[lowest], points[1]
	local p0 = points[1]

	-- Sort by polar angle with respect to the lowest point
	table.sort(points, function(a, b)
		local o = orientation(p0, a, b)
		if o == 0 then -- If collinear, keep the farthest point
			return (p0 - a).Magnitude < (p0 - b).Magnitude
		end
		return o == 2 -- Sort counterclockwise
	end)

	-- Process points using a stack
	local hullSize = 2
	local hull = { points[1], points[2] }

	for i = 3, n do
		while hullSize >= 2 and orientation(hull[hullSize - 1], hull[hullSize], points[i]) ~= 2 do
			table.remove(hull, hullSize) -- Remove the last point if it makes a right turn (clockwise)
			hullSize -= 1
		end
		hullSize += 1
		table.insert(hull, hullSize, points[i]) -- Add the current point to the hull
	end

	return hull
end

return calculateConvexHullGrahamScan

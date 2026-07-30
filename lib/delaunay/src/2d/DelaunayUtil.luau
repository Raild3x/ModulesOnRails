--!strict
--!native

local DelaunayUtil = {}

DelaunayUtil.EPSILON = 2 ^ -52
DelaunayUtil.EDGE_STACK_SIZE = 512

function DelaunayUtil.PseudoAngle(dx: number, dy: number): number
	local p = dx / (math.abs(dx) + math.abs(dy))
	return (dy > 0 and (3 - p) or (1 + p)) / 4
end

function DelaunayUtil.Dist(ax: number, ay: number, bx: number, by: number): number
	local dx = ax - bx
	local dy = ay - by
	return dx * dx + dy * dy
end

function DelaunayUtil.Orient2d(ax: number, ay: number, bx: number, by: number, cx: number, cy: number): number
	return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
end

function DelaunayUtil.InCircle(
	ax: number,
	ay: number,
	bx: number,
	by: number,
	cx: number,
	cy: number,
	px: number,
	py: number
): boolean
	local dx = ax - px
	local dy = ay - py
	local ex = bx - px
	local ey = by - py
	local fx = cx - px
	local fy = cy - py

	local ap = dx * dx + dy * dy
	local bp = ex * ex + ey * ey
	local cp = fx * fx + fy * fy

	return dx * (ey * cp - bp * fy) - dy * (ex * cp - bp * fx) + ap * (ex * fy - ey * fx) < 0
end

function DelaunayUtil.Circumradius(ax: number, ay: number, bx: number, by: number, cx: number, cy: number): number
	local dx = bx - ax
	local dy = by - ay
	local ex = cx - ax
	local ey = cy - ay

	local bl = dx * dx + dy * dy
	local cl = ex * ex + ey * ey
	local d = 0.5 / (dx * ey - dy * ex)

	local x = (ey * bl - dy * cl) * d
	local y = (dx * cl - ex * bl) * d

	return x * x + y * y
end

function DelaunayUtil.Circumcenter(
	ax: number,
	ay: number,
	bx: number,
	by: number,
	cx: number,
	cy: number
): (number, number)
	local dx = bx - ax
	local dy = by - ay
	local ex = cx - ax
	local ey = cy - ay

	local bl = dx * dx + dy * dy
	local cl = ex * ex + ey * ey
	local d = 0.5 / (dx * ey - dy * ex)

	local x = ax + (ey * bl - dy * cl) * d
	local y = ay + (dx * cl - ex * bl) * d

	return x, y
end

local function swap(arr: { number }, i: number, j: number)
	local tmp = arr[i]
	arr[i] = arr[j]
	arr[j] = tmp
end

function DelaunayUtil.Quicksort(ids: { number }, dists: { number }, left: number, right: number)
	if right - left <= 20 then
		for i = left + 1, right do
			local temp = ids[i]
			local tempDist = dists[temp + 1]
			local j = i - 1
			while j >= left and dists[ids[j] + 1] > tempDist do
				ids[j + 1] = ids[j]
				j -= 1
			end
			ids[j + 1] = temp
		end
		return
	end

	local median = math.floor((left + right) / 2)
	local i = left + 1
	local j = right

	swap(ids, median, i)
	if dists[ids[left] + 1] > dists[ids[right] + 1] then
		swap(ids, left, right)
	end
	if dists[ids[i] + 1] > dists[ids[right] + 1] then
		swap(ids, i, right)
	end
	if dists[ids[left] + 1] > dists[ids[i] + 1] then
		swap(ids, left, i)
	end

	local temp = ids[i]
	local tempDist = dists[temp + 1]

	while true do
		repeat
			i += 1
		until dists[ids[i] + 1] >= tempDist

		repeat
			j -= 1
		until dists[ids[j] + 1] <= tempDist

		if j < i then
			break
		end

		swap(ids, i, j)
	end

	ids[left + 1] = ids[j]
	ids[j] = temp

	if right - i + 1 >= j - left then
		DelaunayUtil.Quicksort(ids, dists, i, right)
		DelaunayUtil.Quicksort(ids, dists, left, j - 1)
	else
		DelaunayUtil.Quicksort(ids, dists, left, j - 1)
		DelaunayUtil.Quicksort(ids, dists, i, right)
	end
end

return DelaunayUtil

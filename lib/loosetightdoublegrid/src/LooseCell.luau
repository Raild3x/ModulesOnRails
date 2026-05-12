--!strict
-- Authors: Logan Hunt (Raildex)
-- April 18, 2025

--// Imports //--
local TightCell = require("./TightCell")

--// Types //--
export type EntityId = number
export type AABB = { number } -- {L, B, R, T}
type TightCell = TightCell.TightCell
type GridLike = {
	GetCol: (self: GridLike | any, x: number) -> number,
	GetRow: (self: GridLike | any, y: number) -> number,
	TightGrid: { [number]: TightCell },
	tCols: number,
}
type TightCellOperation = (tightCell: TightCell, looseCellIndex: number) -> any

export type LooseCell = {
	EntityIds: { [EntityId]: true },
	AABBs: { [EntityId]: AABB },
	Dirty: boolean,
	x: number,
	y: number,
	l: number,
	b: number,
	r: number,
	t: number,

	Intersects: (self: LooseCell, left: number, bottom: number, right: number, top: number) -> boolean,
	Insert: (self: LooseCell, id: EntityId, aabb: AABB) -> (),
	Remove: (self: LooseCell, id: EntityId) -> (),
	Update: (self: LooseCell, id: EntityId, l: number, b: number, r: number, t: number) -> (),
	UpdateExtents: (self: LooseCell, grid: GridLike, idx: number) -> (),
}

local profilebegin, profileend = function(label: string) end, function() end
if debug and debug.profilebegin and debug.profileend then
	profilebegin, profileend = debug.profilebegin, debug.profileend
end

--------------------------------------------------------------------------------
--// Util Functions //--
--------------------------------------------------------------------------------

local function CheckCollision(
	left1: number,
	bottom1: number,
	right1: number,
	top1: number,
	left2: number,
	bottom2: number,
	right2: number,
	top2: number
): boolean
	-- Check if the two rectangles overlap
	local noOverlap = right1 <= left2 -- Rectangle 1 is completely to the left of Rectangle 2
		or right2 <= left1 -- Rectangle 2 is completely to the left of Rectangle 1
		or top1 <= bottom2 -- Rectangle 1 is completely below Rectangle 2
		or top2 <= bottom1 -- Rectangle 2 is completely below Rectangle 1

	return not noOverlap -- If there is no overlap, return false; otherwise, return true
end

--------------------------------------------------------------------------------
--// Class //--
--------------------------------------------------------------------------------

local LooseCell = {} :: any
LooseCell.__index = LooseCell

function LooseCell.new(l: number, b: number, r: number, t: number): LooseCell
	local x = (r - l) / 2 + l
	local y = (b - t) / 2 + t

	local self = setmetatable({
		EntityIds = {},
		AABBs = {},
		Dirty = false,
		x = x,
		y = y,
		-- bounding box extents from TR corner
		l = x,
		b = y,
		r = x,
		t = y,
	}, LooseCell)
	--print(l,r,t,b)
	return self :: LooseCell
end

function LooseCell.Intersects(self: LooseCell, left: number, bottom: number, right: number, top: number): boolean
	return CheckCollision(self.l, self.b, self.r, self.t, left, bottom, right, top)
end

function LooseCell.Insert(self: LooseCell, id: EntityId, aabb: AABB)
	self.AABBs[id] = aabb
	self.EntityIds[id] = true
	self.Dirty = true
end

function LooseCell.Remove(self: LooseCell, id: EntityId)
	if self.AABBs[id] then
		self.AABBs[id] = nil
		self.EntityIds[id] = nil
		self.Dirty = true
	end
end

-- Currently equivalent to Remove, but could potentially be optimized in the future?
function LooseCell.Update(self: LooseCell, id: EntityId, l: number, b: number, r: number, t: number)
	local aabb = self.AABBs[id]
	if not aabb then
		return
	end
	aabb[1] = l
	aabb[2] = b
	aabb[3] = r
	aabb[4] = t
	self.Dirty = true
end

-- Calls to attempt to update the extents of the LooseCell. Passes the grid and the index of the cell so the cell doesnt need to store it itself
function LooseCell.UpdateExtents(self: LooseCell, grid: GridLike, idx: number)
	if not self.Dirty then
		return
	end -- only update if dirty
	self.Dirty = false -- reset dirty flag

	-- store the current extents for comparison
	local oL, oR, oT, oB = grid:GetCol(self.l), grid:GetCol(self.r), grid:GetRow(self.t), grid:GetRow(self.b)

	-- update the extents of the AABB
	local l, b, r, t = math.huge, math.huge, -math.huge, -math.huge
	-- TODO: Only check the adjusted AABBs. However, the overhead of adding the adjusted aabbs might not be worth it

	profilebegin("Calculate New Extents")
	for _, aabb: AABB in self.AABBs do
		if aabb[1] < l then
			l = aabb[1]
		end
		if aabb[2] < b then
			b = aabb[2]
		end
		if aabb[3] > r then
			r = aabb[3]
		end
		if aabb[4] > t then
			t = aabb[4]
		end
	end
	if not next(self.AABBs) then
		l, b, r, t = self.x, self.y, self.x, self.y
	end
	self.l, self.b, self.r, self.t = l, b, r, t
	profileend()
	-- print(idx, "New extents: ", "L:", l, "R:", r, "T:", t, "B:", b)

	local nL, nR, nT, nB = grid:GetCol(self.l), grid:GetCol(self.r), grid:GetRow(self.t), grid:GetRow(self.b)
	local TightGrid, tCols = grid.TightGrid, grid.tCols

	local function processSide(
		start: number,
		stop: number,
		fixedStart: number,
		fixedStop: number,
		operation: TightCellOperation
	)
		for x = start, stop do
			for y = fixedStart - 1, fixedStop - 1 do
				local tightCell: TightCell = TightGrid[y * tCols + x]
				operation(tightCell, idx)
			end
		end
	end

	profilebegin("Process Changed TightCells")
	if nL ~= oL then
		if nL < oL then
			processSide(nL, oL - 1, nB, nT, TightCell.insert) -- expanded left: add new left strip
		elseif nL > oL then
			processSide(oL, nL - 1, nB, nT, TightCell.remove) -- shrank left: drop old left strip
		end
	end

	if nR ~= oR then
		if nR < oR then
			processSide(nR + 1, oR, nB, nT, TightCell.remove) -- shrank right: drop old right strip
		elseif nR > oR then
			processSide(oR + 1, nR, nB, nT, TightCell.insert) -- expanded right: add new right strip
		end
	end

	if nT ~= oT then
		if nT < oT then
			processSide(oL, oR, nT + 1, oT, TightCell.remove)
		elseif nT > oT then
			processSide(nL, nR, oT + 1, nT, TightCell.insert)
		end
	end

	if nB ~= oB then
		if nB > oB then
			processSide(oL, oR, oB, nB - 1, TightCell.remove)
		elseif nB < oB then
			processSide(nL, nR, nB, oB - 1, TightCell.insert)
		end
	end
	profileend()
end

return LooseCell

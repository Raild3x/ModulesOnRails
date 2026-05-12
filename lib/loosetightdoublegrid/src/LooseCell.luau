--!strict
-- Authors: Logan Hunt (Raildex)
-- April 18, 2025

--// Imports //--
local TightCell = require("./TightCell")

--// Types //--
export type EntityId = number
export type AABB = {
	l: number,
	b: number,
	r: number,
	t: number,
}
type TightCell = TightCell.TightCell
type GridLike = {
	GetCol: (self: GridLike | any, x: number) -> number,
	GetRow: (self: GridLike | any, y: number) -> number,
	TightGrid: { [number]: TightCell },
	tCols: number,
}
type TightCellOperation = (tightCell: TightCell, looseCellIndex: number) -> any

export type LooseCell = {
	-- EntityIds maps entity id -> starting index in FlatAABBs.
	-- This keeps lookups and updates O(1) when LTDG APIs are called with an EntityId.
	EntityIds: { [EntityId]: number },
	-- FlatAABBs stores packed coordinates in stride-4 layout: {L, B, R, T, ...}
	-- Packed numeric storage reduces table overhead during hot query/raycast loops.
	FlatAABBs: { number },
	-- FlatEntityIds maps slot -> entity id (reverse mapping for EntityIds).
	-- It is required for O(1) swap-remove: when we move the tail AABB into a removed slot,
	-- we must know which entity moved so EntityIds can be updated without searching.
	FlatEntityIds: { EntityId },
	Dirty: boolean,
	x: number,
	y: number,
	l: number,
	b: number,
	r: number,
	t: number,

	Intersects: (self: LooseCell, left: number, bottom: number, right: number, top: number) -> boolean,
	Insert: (self: LooseCell, id: EntityId, l: number, b: number, r: number, t: number) -> (),
	Remove: (self: LooseCell, id: EntityId) -> (),
	Update: (self: LooseCell, id: EntityId, l: number, b: number, r: number, t: number) -> (),
	UpdateExtents: (self: LooseCell, grid: GridLike, idx: number) -> (),
}

local profilebegin, profileend = function(label: string) end, function() end
if debug and debug.profilebegin and debug.profileend then
	profilebegin, profileend = debug.profilebegin, debug.profileend
end

local FLAT_AABB_STRIDE = 4 -- {L, B, R, T}

-- Invariant:
--   let slot = n (1-based), flatIndex = (slot - 1) * FLAT_AABB_STRIDE + 1
--   FlatEntityIds[slot] = entityId  <=>  EntityIds[entityId] = flatIndex
-- This paired mapping is what allows flat coordinate storage while preserving O(1)
-- entity-addressed updates/getters and O(1) removals via swap-remove.

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
		FlatAABBs = {},
		FlatEntityIds = {},
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

function LooseCell.Insert(self: LooseCell, id: EntityId, l: number, b: number, r: number, t: number)
	local flat = self.FlatAABBs
	local writeIndex = #flat + 1
	self.EntityIds[id] = writeIndex
	self.FlatEntityIds[#self.FlatEntityIds + 1] = id
	flat[writeIndex] = l
	flat[writeIndex + 1] = b
	flat[writeIndex + 2] = r
	flat[writeIndex + 3] = t

	self.Dirty = true
end

function LooseCell.Remove(self: LooseCell, id: EntityId)
	local removeIndex = self.EntityIds[id]
	if removeIndex then
		local flat = self.FlatAABBs
		local flatEntityIds = self.FlatEntityIds
		local tailStart = #flat - (FLAT_AABB_STRIDE - 1)
		local removeSlot = math.floor((removeIndex - 1) / FLAT_AABB_STRIDE) + 1
		local tailSlot = #flatEntityIds

		if removeIndex ~= tailStart then
			flat[removeIndex] = flat[tailStart]
			flat[removeIndex + 1] = flat[tailStart + 1]
			flat[removeIndex + 2] = flat[tailStart + 2]
			flat[removeIndex + 3] = flat[tailStart + 3]

			local movedEntityId = flatEntityIds[tailSlot] :: EntityId
			flatEntityIds[removeSlot] = movedEntityId
			self.EntityIds[movedEntityId] = removeIndex
		end

		flat[tailStart] = nil
		flat[tailStart + 1] = nil
		flat[tailStart + 2] = nil
		flat[tailStart + 3] = nil
		flatEntityIds[tailSlot] = nil
		self.EntityIds[id] = nil

		self.Dirty = true
	end
end

-- Currently equivalent to Remove, but could potentially be optimized in the future?
function LooseCell.Update(self: LooseCell, id: EntityId, l: number, b: number, r: number, t: number)
	local writeIndex = self.EntityIds[id]
	if not writeIndex then
		return
	end
	local flat = self.FlatAABBs
	flat[writeIndex] = l
	flat[writeIndex + 1] = b
	flat[writeIndex + 2] = r
	flat[writeIndex + 3] = t

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
	local flat = self.FlatAABBs
	for i = 1, #flat, FLAT_AABB_STRIDE do
		local faL = flat[i]
		local faB = flat[i + 1]
		local faR = flat[i + 2]
		local faT = flat[i + 3]
		if faL < l then
			l = faL
		end
		if faB < b then
			b = faB
		end
		if faR > r then
			r = faR
		end
		if faT > t then
			t = faT
		end
	end
	if #flat == 0 then
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

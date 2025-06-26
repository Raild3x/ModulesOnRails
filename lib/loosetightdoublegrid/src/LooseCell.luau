-- Authors: Logan Hunt (Raildex)
-- April 18, 2025

--// Imports //--
local TightCell = require("./TightCell")

--// Types //--
export type EntityId = number
export type AABB = { number } -- {L, B, R, T}

--------------------------------------------------------------------------------
    --// Util Functions //--
--------------------------------------------------------------------------------

local function CheckCollision(left1, bottom1, right1, top1, left2, bottom2, right2, top2)
    -- Check if the two rectangles overlap
    local noOverlap = 
        right1 <= left2 or -- Rectangle 1 is completely to the left of Rectangle 2
        right2 <= left1 or -- Rectangle 2 is completely to the left of Rectangle 1
        top1 <= bottom2 or -- Rectangle 1 is completely below Rectangle 2
        top2 <= bottom1    -- Rectangle 2 is completely below Rectangle 1

    return not noOverlap -- If there is no overlap, return false; otherwise, return true
end

--------------------------------------------------------------------------------
    --// Class //--
--------------------------------------------------------------------------------

local LooseCell = {};
LooseCell.__index = LooseCell;

function LooseCell.new(l,b,r,t)
    local x = (r-l)/2+l
    local y = (b-t)/2+t

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
    return self
end


function LooseCell:Intersects(left: number, bottom: number, right: number, top: number)
    return CheckCollision(self.l,self.b,self.r,self.t, left,bottom,right,top);
end

function LooseCell:Insert(id: EntityId, aabb: AABB)
    self.AABBs[id] = aabb
    self.Dirty = true
end

function LooseCell:Remove(id: EntityId)
    if self.AABBs[id] then
        self.AABBs[id] = nil
        self.Dirty = true
    end
end

-- Currently equivalent to Remove, but could potentially be optimized in the future?
function LooseCell:Update(id: EntityId, l, b, r, t)
    local aabb = self.AABBs[id]
    aabb[1] = l
    aabb[2] = b
    aabb[3] = r
    aabb[4] = t
    self.Dirty = true
end


-- Calls to attempt to update the extents of the LooseCell. Passes the grid and the index of the cell so the cell doesnt need to store it itself
function LooseCell:UpdateExtents(grid, idx)
    if not self.Dirty then return end -- only update if dirty
    self.Dirty = false -- reset dirty flag

    -- store the current extents for comparison
    local oL, oR, oT, oB = grid:GetCol(self.l), grid:GetCol(self.r), grid:GetRow(self.t), grid:GetRow(self.b)

    -- update the extents of the AABB
    local l, b, r, t = math.huge, math.huge, -math.huge, -math.huge
    -- TODO: Only check the adjusted AABBs. However, the overhead of adding the adjusted aabbs might not be worth it

    debug.profilebegin("Calculate New Extents")
    for _, aabb: AABB in pairs(self.AABBs) do
        if aabb[1] < l then l = aabb[1] end
        if aabb[2] < b then b = aabb[2] end
        if aabb[3] > r then r = aabb[3] end
        if aabb[4] > t then t = aabb[4] end
    end
    if not next(self.AABBs) then
        l, b, r, t = self.x, self.y, self.x, self.y
    end
    self.l, self.b, self.r, self.t = l, b, r, t
    debug.profileend()
    -- print(idx, "New extents: ", "L:", l, "R:", r, "T:", t, "B:", b)

    local nL, nR, nT, nB = grid:GetCol(self.l), grid:GetCol(self.r), grid:GetRow(self.t), grid:GetRow(self.b)
    local TightGrid, tCols = grid.TightGrid, grid.tCols

    local function processSide(start, stop, fixedStart, fixedStop, operation)
        for x = start, stop do
            for y = fixedStart-1, fixedStop-1 do
                local tightCell = TightGrid[y * tCols + x]
                operation(tightCell, idx)
            end
        end
    end

    debug.profilebegin("Process Changed TightCells")
    if nL ~= oL then
        if nL < oL then processSide(nL, oL - 1, nB, nT, TightCell.remove)
        elseif nL > oL then processSide(oR + 1, nR, nB, nT, TightCell.insert) end
    end

    if nR ~= oR then
        if nR < oR then processSide(nR + 1, oR, nB, nT, TightCell.remove)
        elseif nR > oR then processSide(oL, nL - 1, nB, nT, TightCell.insert) end
    end

    if nT ~= oT then
        if nT < oT then processSide(oL, oR, nT + 1, oT, TightCell.remove)
        elseif nT > oT then processSide(nL, nR, oT + 1, nT, TightCell.insert) end
    end

    if nB ~= oB then
        if nB > oB then processSide(oL, oR, oB, nB - 1, TightCell.remove)
        elseif nB < oB then processSide(nL, nR, nB, oB - 1, TightCell.insert) end
    end
    debug.profileend()
end

export type LooseCell = typeof(LooseCell.new(0,0,0,0))

return LooseCell
-- Authors: Logan Hunt (Raildex)
-- April 18, 2025
--[=[
    @class LooseCell
]=]

--// Imports //--
local TightCell = require(script.Parent.TightCell)

--// Types //--
export type EntityId = number
export type AABB = {
	L: number,
	R: number,
	T: number,
	B: number,
}

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

function LooseCell.new(l,r,t,b)
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
        r = x,
        t = y,
        b = y 
    }, LooseCell)
    --print(l,r,t,b)
    return self
end


function LooseCell:Intersects(left: number, bottom: number, right: number, top: number)
    return CheckCollision(self.l,self.b,self.r,self.t, left,bottom,right,top);
end

function LooseCell:Insert(id: EntityId, aabb: AABB)
    self.AABBs[id] = aabb;
    self.Dirty = true;
end

function LooseCell:Remove(id: EntityId)
    if self.AABBs[id] then
        self.AABBs[id] = nil;
        self.Dirty = true;
    end
end

-- Currently equivalent to Remove, but could potentially be optimized in the future?
function LooseCell:Update(id: EntityId, l, b, r, t)
    local aabb = self.AABBs[id]
    aabb.L = l
    aabb.B = b
    aabb.R = r
    aabb.T = t
    self.Dirty = true;
end

function LooseCell:UpdateExtents(grid, idx)
    if not self.Dirty then return end -- only update if dirty
    self.Dirty = false; -- reset dirty flag
    -- print("Updating extents for cell: ", idx)

    -- store the current extents for comparison
    local oL,oR,oT,oB = grid:GetCol(self.l),grid:GetCol(self.r),grid:GetRow(self.t),grid:GetRow(self.b);

    -- update the extents of the AABB
    local l, r, t, b = math.huge, -math.huge, -math.huge, math.huge;
    -- TODO: Only check the adjusted AABBs
    debug.profilebegin("Calculate New Extents")
    for _, aabb: AABB in pairs(self.AABBs) do
        if aabb.L < l then l = aabb.L end
        if aabb.R > r then r = aabb.R end
        if aabb.T > t then t = aabb.T end
        if aabb.B < b then b = aabb.B end
    end
    if not next(self.AABBs) then
        l, r, t, b = self.x, self.x, self.y, self.y;
    end
    self.l, self.r, self.t, self.b = l, r, t, b
    debug.profileend()
    -- print(idx, "New extents: ", "L:",l, "R:",r, "T:",t, "B:",b)

    local nL, nR, nT, nB = grid:GetCol(self.l),grid:GetCol(self.r),grid:GetRow(self.t),grid:GetRow(self.b);
    local TightGrid, tCols = grid.TightGrid, grid.tCols

    local function processSide(start, stop, fixedStart, fixedStop, operation)
        for x = start, stop do
            for y = fixedStart, fixedStop do
                local tightCell = TightGrid[(y - 1) * tCols + x]
                operation(tightCell, idx)
            end
        end
    end

    debug.profilebegin("Process Changed TightCells")
    if nL > oL then processSide(oL, nL - 1, oB, oT, TightCell.remove)
    elseif nL < oL then processSide(nL, oL - 1, nB, nT, TightCell.insert) end

    if nR < oR then processSide(nR + 1, oR, oB, oT, TightCell.remove)
    elseif nR > oR then processSide(oR + 1, nR, nB, nT, TightCell.insert) end

    if nT < oT then processSide(oL, oR, nT + 1, oT, TightCell.remove)
    elseif nT > oT then processSide(nL, nR, oT + 1, nT, TightCell.insert) end

    if nB > oB then processSide(oL, oR, oB, nB - 1, TightCell.remove)
    elseif nB < oB then processSide(nL, nR, nB, oB - 1, TightCell.insert) end
    debug.profileend()
end

export type LooseCell = typeof(LooseCell.new(0,0,0,0))

return LooseCell
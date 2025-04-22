-- Authors: Logan Hunt (Raildex)
-- April 18, 2025
--[=[
    @class LooseTightDoubleGrid
    The `LooseTightDoubleGrid` is a spatial partitioning structure designed to efficiently manage and query entities in a 2D space. 
    It is particularly useful for scenarios where entities with highly dynamic sizes need to be inserted, updated, removed, or queried based on their spatial 
    relationships, such as in games, simulations, or physics engines.

    ## Features
    - **Insertion**: Supports inserting circular, rectangular, and point entities into the grid.
    - **Updates**: Allows updating the position and size of entities.
    - **Removal**: Entities can be removed from the grid.
    - **Queries**: Supports querying entities within rectangular, circular, and point regions. 
      Additional query methods for rotated rectangles and polygons are planned but not yet implemented.
    - **Debugging**: Includes a `Draw` method to visualize the grid and its entities in the 3D workspace.

    ## Scenarios
    The `LooseTightDoubleGrid` is ideal for:
    - **Collision Detection**: Quickly finding potential collisions between entities in a 2D space.
    - **Spatial Queries**: Efficiently retrieving entities within a specific region.
    - **Dynamic Environments**: Managing entities that frequently move or change size.

    ## Example Usage
    ```lua
    local grid = LooseTightDoubleGrid.new({
        Position = Vector2.new(0, 0),
        Size = Vector2.new(32, 32),
        CellSize = 4
    })

    -- Insert a rectangle
    local rectId = grid:InsertRect(Vector2.new(10, 10), Vector2.new(5, 5))

    -- Query entities in a region
    local entities = grid:QueryRect(Vector2.new(10, 10), Vector2.new(6, 6))
    print("Entities in region:", entities)

    -- Update the rectangle's position
    grid:UpdateRect(rectId, Vector2.new(15, 15), Vector2.new(5, 5))

    -- Remove the rectangle
    local success = grid:Remove(rectId)
    print("Did find and remove?", success)
    ```

    :::info How it works - (Info for Nerds)
    Internally the grid is divided into two layers:
    - **Tight Grid**: A fixed grid where each cell contains references to overlapping loose cells.
    - **Loose Grid**: A grid where each cell has a larger boundary than the corresponding tight cell, allowing entities to span multiple cells.

    Entities are stored in the loose grid, and their spatial relationships are managed using axis-aligned bounding boxes (AABBs). 
    The tight grid helps narrow down the search space during queries, improving performance.
    :::
    :::tip Vector2
    Although the documentation specifies `Vector2` for positions and sizes,
    the system will take any table with `X` and `Y` properties.
    :::
]=]

--// Imports //--
local LooseCell = require(script.LooseCell)
local TightCell = require(script.TightCell)

--// Types //--
-- Enum for shape types 
type ShapeType = "c" | "r" | "p"
local SHAPE_TYPE_CIRCLE = "c"
local SHAPE_TYPE_RECT = "r"
local SHAPE_TYPE_POINT = "p"

type LooseCell = LooseCell.LooseCell
export type AABB = LooseCell.AABB -- Stored in the order of {L,B,R,T} (Liberty!), can also be anvisioned as a ccw rotation of the sides.
export type EntityId = LooseCell.EntityId
--[=[
    @within LooseTightDoubleGrid
    @type EntityId number
    An identifier for an entity in the grid. This is a unique number assigned to each entity upon insertion into the grid.
    Ids are not unique between different grids, so they should be used only within the context of a single grid instance.
]=]

--------------------------------------------------------------------------------
    --// Util Functions //--
--------------------------------------------------------------------------------

local function CheckRectRectIntersection(left1, bottom1, right1, top1, left2, bottom2, right2, top2)
    -- Check if the two rectangles overlap
    local noOverlap = 
        right1 <= left2 or -- Rectangle 1 is completely to the left of Rectangle 2
        right2 <= left1 or -- Rectangle 2 is completely to the left of Rectangle 1
        top1 <= bottom2 or -- Rectangle 1 is completely below Rectangle 2
        top2 <= bottom1    -- Rectangle 2 is completely below Rectangle 1

    return not noOverlap -- If there is no overlap, return false; otherwise, return true
end

local function CheckCircleRectIntersection(circleX, circleY, circleRadius, rectLeft, rectBottom, rectRight, rectTop)
    -- Calculate the rectangle's center and half dimensions
    local rectCenterX = (rectLeft + rectRight)
    local rectCenterY = (rectBottom + rectTop)
    local rectWidth = (rectRight - rectLeft)
    local rectHeight = (rectTop - rectBottom)

    -- Calculate the distance between the circle's center and the rectangle's center
    local distanceX = math.abs(circleX * 2 - rectCenterX)
    local distanceY = math.abs(circleY * 2 - rectCenterY)

    -- Check if the circle is too far from the rectangle to intersect
    if distanceX > (rectWidth + circleRadius * 2) then return false end
    if distanceY > (rectHeight + circleRadius * 2) then return false end

    -- Check if the circle is close enough to intersect the rectangle's edges
    if distanceX <= rectWidth then return true end
    if distanceY <= rectHeight then return true end

    -- Check if the circle intersects the rectangle's corners
    local cornerDistanceSquared = (distanceX - rectWidth) * (distanceX - rectWidth) +
                                  (distanceY - rectHeight) * (distanceY - rectHeight)

    return cornerDistanceSquared <= (circleRadius * circleRadius)
end

local function CheckCircleCircleIntersection(cx1, cy1, radius1, cx2, cy2, radius2)
    -- Calculate the squared distance between the two circle centers
    local dx = cx1 - cx2
    local dy = cy1 - cy2
    local distanceSquared = dx * dx + dy * dy

    -- Check if the distance is less than the sum of the radii
    local combinedRadius = radius1 + radius2
    return distanceSquared <= (combinedRadius * combinedRadius)
end

local function getNextId(self: LTDG): EntityId
    local id = self.NextId
    self.NextId += 1
    return id
end

if not debug or not debug.profilebegin then -- This is a workaround for the debug library not being available in some environments.
    debug = {
        profilebegin = function() end,
        profileend = function() end,
    }
end
--------------------------------------------------------------------------------
    --// Class //--
--------------------------------------------------------------------------------

local LTDG = {}
LTDG.ClassName = "LooseTightDoubleGrid"
LTDG.__index = LTDG

--[=[
    @within LooseTightDoubleGrid
    Creates a new instance of LooseTightDoubleGrid with the given configuration.

    - **Position** is the center origin of the grid. *(Default: `Vector2.new(0, 0)`)*
    - **Size** is the number of cells in the x and y directions. *(Default: `Vector2.new(32, 32)`)*
    - **CellSize** is the size of each cell in studs. Adjust this number based on the average sizes of your provided entities in order to optimize performance. *(Default: `4`)*

    ```lua
    local grid = LooseTightDoubleGrid.new({
        Position = Vector2.new(0, 0),
        Size = Vector2.new(32, 32),
        CellSize = 4
    })
    ```
]=]
function LTDG.new(config: {
    Position: Vector2?,
    Size: Vector2?,
    CellSize: number?
}): LTDG
    local origin = config.Position or Vector2.zero
    local cellSize = config.CellSize or 4
    local size = config.Size or Vector2.new(32, 32)
    local width = size.X
    local height = size.Y

    assert(cellSize > 0, "Cell size must be greater than 0")
    assert(width % 1 == 0, "Width must be an integer")
    assert(height % 1 == 0, "Height must be an integer")
    assert(width > 0, "Width must be greater than 0")
    assert(height > 0, "Height must be greater than 0")

    -- potential support for unnatural cell size?
    local cellWidth = cellSize
    local cellHeight = cellSize
    local bottomCornerX = origin.X - cellSize*width / 2
    local bottomCornerY = origin.Y - cellSize*height / 2

    local TG = table.create(width*height);
    local LG = table.create(width*height);
    for i = 1, height*width do
        TG[i] = TightCell.new(i);
        --LN[i] = Node.new();
        local l = bottomCornerX + (i-1)%width*cellWidth
        local b = bottomCornerY + ((math.floor((i-1)/height))%height)*cellHeight
        LG[i] = LooseCell.new(l, b, l+cellWidth, b+cellHeight);
        --if i%20==0 then print() end
    end

    local self = setmetatable({
        NextId = 1,
        Position = origin,
        BottomCornerY = bottomCornerY, -- I store these to provide slightly faster access
        BottomCornerX = bottomCornerX,
        TightGrid = TG,
        LooseGrid = LG,
        tCols = width,
        tRows = height,
        cWidth = cellWidth, 
        cHeight = cellHeight,
        invCellWidth = 1/cellWidth, -- Precomputed Inverse
        invCellHeight = 1/cellHeight, -- Precomputed Inverse
        ShapeMap = {} :: {[EntityId]: ShapeType},
        EntityIdToLooseCellIdx = {} :: {[EntityId]: number},
        DirtyLooseCells = {} :: {[LooseCell]: number},
    }, LTDG);

    return self
end

--[=[
    @within LooseTightDoubleGrid
    @private
    Gets the row index from a given world y-coordinate.
]=]
function LTDG:GetRow(y: number)
    local row = (y - self.BottomCornerY) * self.invCellHeight + 1
    if row < 1 then
        return 1
    elseif row > self.tRows then
        return self.tRows
    end
    return math.floor(row)
end

--[=[
    @within LooseTightDoubleGrid
    @private
    Gets the column index from a given world x-coordinate.

    ```lua
    local col = grid:GetCol(15)
    print("Column:", col)
    ```
]=]
function LTDG:GetCol(x: number)
    local col = (x - self.BottomCornerX) * self.invCellWidth + 1
    if col < 1 then
        return 1
    elseif col > self.tCols then
        return self.tCols
    end
    return math.floor(col)
end

--------------------------------------------------------------------------------
    --// (Insertion / Update / Removal) - Methods //--
--------------------------------------------------------------------------------

--[=[
    @within LooseTightDoubleGrid
    Inserts a rectangular entity into the grid.

    ```lua
    -- Example Code for generating some parts and registering them in the grid
    local function V3ToV2(v3: Vector3): Vector2
        return Vector2.new(v3.X, v3.Z)
    end
    
    local IdToPart = {}
    for i = 1, 10 do
        local part = Instance.new("Part")
        part.Size = Vector3.new(math.random(1, 5), 1, math.random(1, 5))
        part.Position = Vector3.new(math.random(-20, 20), 1, math.random(-20, 20))
        part.Anchored = true
        part.Parent = workspace

        local entityId = grid:InsertRect(V3ToV2(part.Position), V3ToV2(part.Size))

        -- Some potential ways you could identify the connection between the part and the entityId:
        IdToPart[entityId] = part -- A: store the part in a table for later reference
        part:SetAttribute("EntityId", entityId) -- B: store the entity ID in the part's attribute for lookup

        print("Inserted Rect Entity ID:", entityId)
    end
    ```
]=]
function LTDG:InsertRect(position: Vector2, size: Vector2): EntityId
    debug.profilebegin("LTDG:InsertRect")
    local halfSizeX = size.X * 0.5
    local halfSizeY = size.Y * 0.5
    local aabb: AABB = { 
        position.X - halfSizeX, -- L
        position.Y - halfSizeY, -- B
        position.X + halfSizeX, -- R
        position.Y + halfSizeY  -- T
    }

    local id = getNextId(self)

    local cX = self:GetCol(position.X)
    local cY = self:GetRow(position.Y)
    local index = (cY-1)*self.tCols + cX;
    
    self.ShapeMap[id] = SHAPE_TYPE_RECT
    self.EntityIdToLooseCellIdx[id] = index
    self.LooseGrid[index]:Insert(id, aabb)
    
    local looseCell = self.LooseGrid[index]
    -- TODO: Check if this would be more efficient than an array
    self.DirtyLooseCells[looseCell] = index
    debug.profileend()
    return id
end

--[=[
    @within LooseTightDoubleGrid
    Inserts a circular entity into the grid.

    ```lua
    local entityId = grid:InsertCircle(Vector2.new(5, 5), 2)
    print("Inserted Circle Entity ID:", entityId)
    ```
]=]
function LTDG:InsertCircle(position: Vector2, radius: number): EntityId
    debug.profilebegin("LTDG:InsertCircle")
    local aabb: AABB = { 
        position.X - radius, -- L
        position.Y - radius, -- B
        position.X + radius, -- R
        position.Y + radius  -- T
    }

    local id = getNextId(self)

    local cX = self:GetCol(position.X)
    local cY = self:GetRow(position.Y)
    local index = (cY-1)*self.tCols + cX;
    
    self.ShapeMap[id] = SHAPE_TYPE_CIRCLE
    self.EntityIdToLooseCellIdx[id] = index
    self.LooseGrid[index]:Insert(id, aabb)
    
    local looseCell = self.LooseGrid[index]
    self.DirtyLooseCells[looseCell] = index
    debug.profileend()
    return id
end

--[=[
    @within LooseTightDoubleGrid
    Inserts a point entity into the grid.

    ```lua
    local entityId = grid:InsertPoint(Vector2.new(10, 10))
    print("Inserted Point Entity ID:", entityId)
    ```
]=]
function LTDG:InsertPoint(position: Vector2): EntityId
    debug.profilebegin("LTDG:InsertPoint")
    local aabb: AABB = {
        position.X,
        position.Y,
        position.X,
        position.Y,
    }

    local id = getNextId(self)

    local cX = self:GetCol(position.X)
    local cY = self:GetRow(position.Y)
    local index = (cY-1)*self.tCols + cX;
    
    self.ShapeMap[id] = SHAPE_TYPE_POINT
    self.EntityIdToLooseCellIdx[id] = index
    self.LooseGrid[index]:Insert(id, aabb)
    
    local looseCell = self.LooseGrid[index]
    self.DirtyLooseCells[looseCell] = index
    debug.profileend()
    return id
end

--[=[
    @within LooseTightDoubleGrid
    @private

    Updates an entity's position and bounding box in the grid.
]=]
function LTDG:_UpdateEntity(entityId: EntityId, newPos: Vector2, L: number, B: number, R: number, T: number)
    local looseCellIdx = self.EntityIdToLooseCellIdx[entityId]
    if not looseCellIdx then
        error("Entity not found: " .. tostring(entityId))
    end

    local looseCell = self.LooseGrid[looseCellIdx]
    self.DirtyLooseCells[looseCell] = looseCellIdx

    local cX = self:GetCol(newPos.X)
    local cY = self:GetRow(newPos.Y)
    local newIndex = (cY - 1) * self.tCols + cX

    if newIndex ~= looseCellIdx then
        looseCell:Remove(entityId) -- remove from old cell
        local newLooseCell = self.LooseGrid[newIndex]
        newLooseCell:Insert(entityId, {L, B, R, T})
        self.EntityIdToLooseCellIdx[entityId] = newIndex
        self.DirtyLooseCells[newLooseCell] = newIndex
    else
        looseCell:Update(entityId, L, B, R, T) -- update position in the same cell
    end
end

--[=[
    @within LooseTightDoubleGrid
    Updates the position and size of a rectangular entity.

    ```lua
    grid:UpdateRect(entityId, Vector2.new(12, 12), Vector2.new(5, 7))
    print("Updated Rect Entity ID:", entityId)
    ```
]=]
function LTDG:UpdateRect(entityId: EntityId, newPosition: Vector2, newSize: Vector2)
    debug.profilebegin("LTDG:UpdateRect")
    if self.ShapeMap[entityId] ~= SHAPE_TYPE_RECT then
        warn("Entity is not a rectangle: " .. tostring(entityId))
        self.ShapeMap[entityId] = SHAPE_TYPE_RECT -- force it to be a rectangle
    end

    local halfSizeX = newSize.X * 0.5
    local halfSizeY = newSize.Y * 0.5
    self:_UpdateEntity(entityId, newPosition, 
        newPosition.X - halfSizeX, -- L
        newPosition.Y - halfSizeY, -- B
        newPosition.X + halfSizeX, -- R
        newPosition.Y + halfSizeY  -- T
    )
    debug.profileend()
end

--[=[
    @within LooseTightDoubleGrid
    Updates the position and radius of a circular entity.

    ```lua
    grid:UpdateCircle(entityId, Vector2.new(8, 8), 3)
    print("Updated Circle Entity ID:", entityId)
    ```
]=]
function LTDG:UpdateCircle(entityId: EntityId, newPosition: Vector2, newRadius: number)
    debug.profilebegin("LTDG:UpdateCircle")
    if self.ShapeMap[entityId] ~= SHAPE_TYPE_CIRCLE then
        warn("Entity is not a circle: " .. tostring(entityId))
        self.ShapeMap[entityId] = SHAPE_TYPE_CIRCLE -- force it to be a circle
    end

    self:_UpdateEntity(entityId, newPosition, 
        newPosition.X - newRadius, -- L
        newPosition.Y - newRadius, -- B
        newPosition.X + newRadius, -- R
        newPosition.Y + newRadius  -- T
    )
    debug.profileend()
end

--[=[
    @within LooseTightDoubleGrid
    Updates the position of a point entity.

    ```lua
    grid:UpdatePoint(entityId, Vector2.new(15, 15))
    print("Updated Point Entity ID:", entityId)
    ```
]=]
function LTDG:UpdatePoint(entityId: EntityId, newPosition: Vector2)
    debug.profilebegin("LTDG:UpdatePoint")
    if self.ShapeMap[entityId] ~= SHAPE_TYPE_POINT then
        warn("Entity is not a point: " .. tostring(entityId))
        self.ShapeMap[entityId] = SHAPE_TYPE_POINT -- force it to be a point
    end

    self:_UpdateEntity(entityId, newPosition, 
        newPosition.X, -- L
        newPosition.Y, -- B
        newPosition.X, -- R
        newPosition.Y  -- T
    )
    debug.profileend()
end

--[=[
    @within LooseTightDoubleGrid
    Removes an entity from the grid.
    Return true if the entity was found and removed.
    Return false if the entity was not found.

    ```lua
    local entityId = grid:InsertRect(Vector2.new(10, 10), Vector2.new(5, 5))

    local didRemove = grid:Remove(entityId)
    ```
]=]
function LTDG:Remove(entityId: EntityId): boolean
    local looseCellIdx = self.EntityIdToLooseCellIdx[entityId]
    if not looseCellIdx then return false end -- entity not found

    local looseCell = self.LooseGrid[looseCellIdx]
    looseCell:Remove(entityId)
    self.ShapeMap[entityId] = nil
    self.EntityIdToLooseCellIdx[entityId] = nil

    self.DirtyLooseCells[looseCell] = looseCellIdx -- mark loose cell as dirty
    return true
end

--[=[
    @within LooseTightDoubleGrid
    Checks if an entity exists in the grid.

    ```lua
    local exists = grid:Has(entityId)
    print("Entity exists:", exists)
    ```
]=]
function LTDG:Has(entityId: EntityId): boolean
    return self.EntityIdToLooseCellIdx[entityId] ~= nil
end

--[=[
    @within LooseTightDoubleGrid
    Returns the size of an entity.
    Errors if no entity with the id is in the grid.

    ```lua
    local size = grid:GetEntitySize(entityId)
    print("Entity Size:", size)
    ```
]=]
function LTDG:GetEntitySize(id: EntityId): Vector2
    local looseCellIdx = self.EntityIdToLooseCellIdx[id]
    if not looseCellIdx then 
        error("Entity not found: " .. tostring(id))
    end -- entity not found

    local looseCell = self.LooseGrid[looseCellIdx]
    local aabb: AABB = looseCell.AABBs[id]

    return Vector2.new(aabb[3] - aabb[1], aabb[4] - aabb[2]) :: any
end

--[=[
    @within LooseTightDoubleGrid
    Returns the position of an entity.
    Errors if no entity with the id is in the grid..

    ```lua
    local position = grid:GetEntityPosition(entityId)
    print
]=]
function LTDG:GetEntityPosition(id: EntityId): Vector2
    local looseCellIdx = self.EntityIdToLooseCellIdx[id]
    if not looseCellIdx then 
        error("Entity not found: " .. tostring(id))
    end -- entity not found

    local looseCell = self.LooseGrid[looseCellIdx]
    local aabb: AABB = looseCell.AABBs[id]

    return Vector2.new((aabb[1] + aabb[3]) * 0.5, (aabb[2] + aabb[4]) * 0.5) :: any
end

--[=[
    @within LooseTightDoubleGrid
    Gets the position and size of an entity.
    Faster than calling `GetEntityPosition` and `GetEntitySize` separately.
    Errors if no entity with the id is in the grid.

    ```lua
    local position, size = grid:GetEntityPositionAndSize(entityId)
    print("Entity Position:", position, "Size:", size)
    ```
]=]
function LTDG:GetEntityPositionAndSize(id: EntityId): (Vector2, Vector2)
    local looseCellIdx = self.EntityIdToLooseCellIdx[id]
    if not looseCellIdx then 
        error("Entity not found: " .. tostring(id))
    end -- entity not found

    local looseCell = self.LooseGrid[looseCellIdx]
    local aabb: AABB = looseCell.AABBs[id]

    return Vector2.new((aabb[1] + aabb[3]) / 2, (aabb[2] + aabb[4]) / 2) :: any,
        Vector2.new(aabb[3] - aabb[1], aabb[4] - aabb[2]) :: any
end

--------------------------------------------------------------------------------
    --// Query Methods //--
--------------------------------------------------------------------------------

--[=[
    @within LooseTightDoubleGrid
    @private
    Queries entities within a specified rectangular region bounds.
]=]
function LTDG:_QueryRegion(qL: number, qB: number, qR: number, qT: number, queryShapeType: ShapeType?): { EntityId }
    debug.profilebegin("LTDG:_QueryRegion")
    queryShapeType = queryShapeType or SHAPE_TYPE_RECT -- Default to rectangle if not specified
    
    debug.profilebegin("Calculate Cols and Rows")
    local tx1 = self:GetCol(qL)
    local tx2 = self:GetCol(qR)
    local ty1 = self:GetRow(qB)
    local ty2 = self:GetRow(qT)
    debug.profileend()

    debug.profilebegin("Update Loose Cell Extents")
    for looseCell, looseCellIdx in self.DirtyLooseCells do
        looseCell:UpdateExtents(self, looseCellIdx)
        self.DirtyLooseCells[looseCell] = nil -- clear dirty flag
    end
    debug.profileend()

    local intersectingEntities: { EntityId } = {}

    local ShapeMap = self.ShapeMap;
    local qCenterX = (qL + qR) * 0.5
    local qCenterY = (qB + qT) * 0.5
    local qRadius = (qR - qL) * 0.5

    local function checkLooseCellAgainstCircle(looseCell: LooseCell)
        debug.profilebegin("Check LooseCell Against Circle")
        for entityId, aabb: AABB in looseCell.AABBs do
            local l, b, r, t = aabb[1], aabb[2], aabb[3], aabb[4]
            if CheckRectRectIntersection(l, b, r, t, qL, qB, qR, qT) then
                if ShapeMap[entityId] == SHAPE_TYPE_CIRCLE then
                    local cx = (l + r) * 0.5
                    local cy = (b + t) * 0.5
                    local entityRadius = (r - l) * 0.5
                    if CheckCircleCircleIntersection(
                        qCenterX, qCenterY, qRadius,
                        cx, cy, entityRadius
                    ) then
                        table.insert(intersectingEntities, entityId)-- add entity to query results
                    end
                elseif CheckCircleRectIntersection(
                    qCenterX, qCenterY, qRadius,
                    l, b, r, t
                ) then
                    table.insert(intersectingEntities, entityId)-- add entity to query results
                end
            end
        end
        debug.profileend()
    end

    local function checkLooseCellAgainstRect(looseCell: LooseCell)
        debug.profilebegin("Check LooseCell Against Rect")
        for entityId, aabb: AABB in looseCell.AABBs do
            local l, b, r, t = aabb[1], aabb[2], aabb[3], aabb[4]
            if CheckRectRectIntersection(l, b, r, t, qL, qB, qR, qT) then
                if ShapeMap[entityId] == SHAPE_TYPE_CIRCLE then
                    local cx = (l + r) * 0.5
                    local cy = (b + t) * 0.5
                    local entityRadius = (r - l) * 0.5
                    if CheckCircleRectIntersection(
                        cx, cy, entityRadius,
                        qL, qB, qR, qT
                    ) then
                        table.insert(intersectingEntities, entityId)-- add entity to query results
                    end
                else
                    table.insert(intersectingEntities, entityId)-- add entity to query results
                end
            end
        end
        debug.profileend()
    end

    local checkLooseCell = if queryShapeType == SHAPE_TYPE_CIRCLE then checkLooseCellAgainstCircle else checkLooseCellAgainstRect

    local TightGrid = self.TightGrid;
    local LooseGrid = self.LooseGrid;
    local tCols = self.tCols;
    local checkedLooseCells = {};

    debug.profilebegin("Check Tight Cells")
    for ty = ty1-1, ty2-1 do
        local trow = ty*tCols;
        for tx = tx1, tx2 do
            local tightCell = TightGrid[trow + tx];
            for _, looseCellIdx in tightCell do
                if checkedLooseCells[looseCellIdx] then
                    continue -- skip already checked loose cells
                else
                    checkedLooseCells[looseCellIdx] = true -- mark loose cell as checked
                end
                
                local looseCell: LooseCell = LooseGrid[looseCellIdx];
                if looseCell:Intersects(qL,qB,qR,qT) then -- if looseCell intersects search area
                    checkLooseCell(looseCell)
                end
            end
        end
    end
    debug.profileend()

    debug.profileend()
    return intersectingEntities;
end

--[=[
    @within LooseTightDoubleGrid
    Queries entities within a rectangular region.

    ```lua
    local entityIds = grid:QueryRect(Vector2.new(10, 10), Vector2.new(6, 6))
    print("Entities in Rect:", entityIds)
    ```
]=]
function LTDG:QueryRect(pos: Vector2, size: Vector2): { EntityId }
    local halfSizeX = size.X * 0.5
    local halfSizeY = size.Y * 0.5
    return self:_QueryRegion(
        pos.X - halfSizeX, -- L
        pos.Y - halfSizeY, -- B
        pos.X + halfSizeX, -- R
        pos.Y + halfSizeY  -- T
    )
end

--[=[
    @within LooseTightDoubleGrid
    Queries entities within a circular region.

    ```lua
    local entities = grid:QueryCircle(Vector2.new(15, 15), 5)
    print("Entities in Circle:", entities)
    ```
]=]
function LTDG:QueryCircle(pos: Vector2, radius: number): { EntityId }
    local qL, qB, qR, qT = pos.X - radius, pos.Y - radius, pos.X + radius, pos.Y + radius
    local candidates = self:_QueryRegion(qL, qB, qR, qT, SHAPE_TYPE_CIRCLE)
    return candidates
end

--[=[
    @within LooseTightDoubleGrid
    Queries entities at a specific point.

    ```lua
    local entitiesIds = grid:QueryPoint(Vector2.new(20, 20))
    print("Entities at Point:", entitiesIds)
    ```
]=]
function LTDG:QueryPoint(pos: Vector2): { EntityId }
    debug.profilebegin("LTDG:QueryPoint")
    local cX = self:GetCol(pos.X)
    local cY = self:GetRow(pos.Y)
    local index = (cY - 1) * self.tCols + cX
    local looseCell = self.LooseGrid[index]

    local intersectingEntities = {}
    for entityId, aabb: AABB in looseCell.AABBs do
        if pos.X >= aabb[1] and pos.X <= aabb[3] and pos.Y >= aabb[2] and pos.Y <= aabb[4] then
            table.insert(intersectingEntities, entityId)
        end
    end
    debug.profileend()
    return intersectingEntities
end

--[=[
    @within LooseTightDoubleGrid
    Queries the closest entity to a given point. Closeness is determined by the distance to the edge of the entity's shape.

    This method searches for the entity that is closest to the specified point in the grid. 
    It considers all shapes (circles, rectangles, and points) and uses a two-tier comparison:
    - **Primary Metric**: Distance to the edge of the shape.
    - **Secondary Metric**: Distance to the center of the shape (used to break ties when the point is inside multiple shapes).
    
    Under this two-tier metric, the method will return an entity if the point is inside the entity, even if another
    entities's center is technically closer to the point. `Point` entities are treated as circles with a radius of 0.

    The method uses an expanding search algorithm, starting from the tight cell containing the point and gradually expanding outward until the closest entity is found.

    ```lua
    -- Insert some entities
    local rectId = grid:InsertRect(Vector2.new(10, 10), Vector2.new(5, 5))
    local circleId = grid:InsertCircle(Vector2.new(15, 15), 3)
    local pointId = grid:InsertPoint(Vector2.new(20, 20))

    -- Query the closest entity to a point
    local closestEntityId = grid:QueryClosestToPoint(Vector2.new(12, 12))
    print("Closest Entity ID:", closestEntityId)
    ```
]=]
function LTDG:QueryClosestToPoint(point: Vector2): EntityId?
    debug.profilebegin("LTDG:QueryClosestToPoint")

    -- Utility function to calculate the squared distance from a point to a shape
    local function calculateDistanceSquaredToShape(aabb: AABB, shapeType: ShapeType): (number, number)
        local l, b, r, t = aabb[1], aabb[2], aabb[3], aabb[4]
        -- Center of the AABB
        local centerX = (l + r) * 0.5
        local centerY = (b + t) * 0.5
        local dx = point.X - centerX
        local dy = point.Y - centerY
        local distanceSquaredToCenter = dx * dx + dy * dy

        if shapeType == SHAPE_TYPE_CIRCLE then
            -- For circles, calculate the squared distance to the edge
            local radius = (r - l) * 0.5
            local radiusSquared = radius * radius

            if distanceSquaredToCenter <= radiusSquared then
                -- Point is inside the circle; return 0 for edge distance and distance to center as secondary metric
                return 0, distanceSquaredToCenter
            else
                -- Point is outside the circle; return distance to the edge and distance to the center
                return distanceSquaredToCenter - radiusSquared, distanceSquaredToCenter
            end
        elseif shapeType == SHAPE_TYPE_RECT then
            -- For rectangles, clamp the point to the rectangle's bounds
            local clampedX = math.clamp(point.X, l, r)
            local clampedY = math.clamp(point.Y, b, t)
            local clampedDx = point.X - clampedX
            local clampedDy = point.Y - clampedY
            local distanceSquaredToEdge = clampedDx * clampedDx + clampedDy * clampedDy

            if distanceSquaredToEdge == 0 then
                -- Point is inside the rectangle; return 0 for edge distance and distance to center as secondary metric
                return 0, distanceSquaredToCenter
            else
                -- Point is outside the rectangle; return distance to the edge and distance to the center
                return distanceSquaredToEdge, distanceSquaredToCenter
            end
        elseif shapeType == SHAPE_TYPE_POINT then
            return distanceSquaredToCenter, distanceSquaredToCenter
        else
            error("Unknown shape type: " .. tostring(shapeType))
        end
    end

    -- Track the closest entity and its distance metrics
    local ShapeMap = self.ShapeMap
    local closestEntityId = nil
    local closestDistanceSquared = math.huge
    local closestDistanceToCenter = math.huge

    -- Function to check all entities in a loose cell
    local function checkLooseCell(looseCell: LooseCell)
        local didFind = false
        for entityId, aabb: AABB in looseCell.AABBs do
            didFind = true
            local shapeType = ShapeMap[entityId]
            local distanceSquaredToEdge, distanceSquaredToCenter = calculateDistanceSquaredToShape(aabb, shapeType)
            
            -- Compare based on primary metric (edge distance), then secondary metric (center distance)
            if distanceSquaredToEdge < closestDistanceSquared or (
                distanceSquaredToEdge == closestDistanceSquared and 
                distanceSquaredToCenter < closestDistanceToCenter
            ) then
                closestDistanceSquared = distanceSquaredToEdge
                closestDistanceToCenter = distanceSquaredToCenter
                closestEntityId = entityId
            end
        end
        return didFind
    end

    -- Get the initial tight cell coordinates
    local cX = self:GetCol(point.X)
    local cY = self:GetRow(point.Y)

    local tCols = self.tCols
    local tRows = self.tRows
    local LooseGrid = self.LooseGrid
    local TightGrid = self.TightGrid

    -- Expanding search algorithm
    local checkedLooseCells = {}
    local checkedTightCells = {}

    local tightCellIndexCount = 0
    local tightCellXIndicesToCheck = table.create(4)
    local tightCellYIndicesToCheck = table.create(4)

    local radius = 0
    while true do
        local startX = math.max(1, cX - radius)
        local endX = math.min(tCols, cX + radius)
        local startY = math.max(1, cY - radius)
        local endY = math.min(tRows, cY + radius)

        -- Check the outermost layer of tight cells for the current radius
        -- I use multiple loops to avoid checking through the same cells multiple times
        for x = startX, endX do
            -- Top row
            if startY > 0 then
                local tightCellIndex = (startY - 1) * tCols + x
                checkedTightCells[tightCellIndex] = true -- mark tight cell as checked
                for _, looseCellIndex in TightGrid[tightCellIndex] do
                    if not checkedLooseCells[looseCellIndex] then
                        checkedLooseCells[looseCellIndex] = true -- mark loose cell as checked
                        if checkLooseCell(LooseGrid[looseCellIndex]) then
                            tightCellIndexCount += 1
                            tightCellYIndicesToCheck[tightCellIndexCount] = startY -- mark tight cell as checked
                            tightCellXIndicesToCheck[tightCellIndexCount] = x
                        end
                    end
                end
            end

            -- Bottom row
            if endY <= tRows then
                local tightCellIndex = (endY - 1) * tCols + x
                checkedTightCells[tightCellIndex] = true -- mark tight cell as checked
                for _, looseCellIndex in TightGrid[tightCellIndex] do
                    if not checkedLooseCells[looseCellIndex] then
                        checkedLooseCells[looseCellIndex] = true -- mark loose cell as checked
                        if checkLooseCell(LooseGrid[looseCellIndex]) then
                            tightCellIndexCount += 1
                            tightCellYIndicesToCheck[tightCellIndexCount] = endY -- mark tight cell as checked
                            tightCellXIndicesToCheck[tightCellIndexCount] = x
                        end
                    end
                end
            end
        end

        -- shift start and end to not include corner cells
        for y = startY + 1, endY - 1 do
            -- Left column
            if startX > 0 then
                local tightCellIndex = (y - 1) * tCols + startX
                checkedTightCells[tightCellIndex] = true -- mark tight cell as checked
                for _, looseCellIndex in TightGrid[tightCellIndex] do
                    if not checkedLooseCells[looseCellIndex] then
                        checkedLooseCells[looseCellIndex] = true -- mark loose cell as checked
                        if checkLooseCell(LooseGrid[looseCellIndex]) then
                            tightCellIndexCount += 1
                            tightCellYIndicesToCheck[tightCellIndexCount] = y -- mark tight cell as checked
                            tightCellXIndicesToCheck[tightCellIndexCount] = startX -- mark tight cell as checked
                        end
                    end
                end
            end

            -- Right column
            if endX <= tCols then
                local tightCellIndex = (y - 1) * tCols + endX
                checkedTightCells[tightCellIndex] = true -- mark tight cell as checked
                for _, looseCellIndex in TightGrid[tightCellIndex] do
                    if not checkedLooseCells[looseCellIndex] then
                        checkedLooseCells[looseCellIndex] = true -- mark loose cell as checked
                        if checkLooseCell(LooseGrid[looseCellIndex]) then
                            tightCellIndexCount += 1
                            tightCellYIndicesToCheck[tightCellIndexCount] = y -- mark tight cell as checked
                            tightCellXIndicesToCheck[tightCellIndexCount] = endX -- mark tight cell as checked
                        end
                    end
                end
            end
        end

        for i = 1, tightCellIndexCount do
            local tcX, tcY = tightCellXIndicesToCheck[i], tightCellYIndicesToCheck[i]
            for y = -1, 1 do
                for x = -1, 1 do
                    local nx = tcX + x
                    local ny = tcY + y
                    if nx < 1 or nx > tCols or ny < 1 or ny > tRows or (x == 0 and y == 0) then
                        continue -- skip out of bounds cells
                    end
                    local tightCellIndex = (ny - 1) * tCols + nx
                    if not checkedTightCells[tightCellIndex] then
                        checkedTightCells[tightCellIndex] = true -- mark tight cell as checked
                        for _, looseCellIndex in TightGrid[tightCellIndex] do
                            if not checkedLooseCells[looseCellIndex] then
                                checkedLooseCells[looseCellIndex] = true -- mark loose cell as checked
                                checkLooseCell(LooseGrid[looseCellIndex])
                            end
                        end
                    end
                end 
            end
        end

        -- Stop if we found an entity or if the search exceeds the grid bounds
        if closestEntityId or radius > math.max(tCols, tRows) then
            break
        end

        radius += 1
    end

    debug.profileend()
    return closestEntityId
end

--[=[
    @within LooseTightDoubleGrid
    Performs a raycast through the grid, checking for intersections with entities.
    The ray starts at `origin` and travels in the `direction`. The magnitude of
    the direction vector determines the length of the ray.
    
    The `rayParams` table can include a `FilterList` of entity IDs to include or exclude, 
    and a `FilterType` to specify whether the filter is inclusive or exclusive.

    Returns the closest intersection, including the hit position, normal, distance,
    and the intersected entity ID.

    ```lua
    local id1 = grid:InsertRect(Vector2.new(5, 0), Vector2.new(2, 2))
    local id2 = grid:InsertCircle(Vector2.new(8, 0), 1)

    local hit = grid:Raycast(Vector2.new(0, 0), Vector2.new(10, 0), {
        FilterList = {id1}, -- ignore the rect
        FilterType = Enum.RaycastFilterType.Exclude,
    })
    if hit then
        print("Hit entity:", hit.EntityId)
    end
    ```
]=]
function LTDG:Raycast(origin: Vector2, direction: Vector2, _rayParams: {
        FilterList: { EntityId }?,
        FilterType: Enum.RaycastFilterType?,
        CustomFilter: ((EntityId) -> boolean)?,
    }?): {
        Normal: Vector2,
        Position: Vector2,
        Distance: number,
        EntityId: EntityId,
    }?
    debug.profilebegin("LTDG:Raycast")

    local FILTER_TYPE_INCLUDE = Enum.RaycastFilterType.Include

    local skipFilter = not _rayParams or (not _rayParams.FilterList and not _rayParams.CustomFilter)
    local filterList = _rayParams and _rayParams.FilterList
    local customFilter = _rayParams and _rayParams.CustomFilter
    local filterType = _rayParams and _rayParams.FilterType or FILTER_TYPE_INCLUDE

    -- Helper function to determine if an entity is filtered out of potential results
    local function isFilteredOut(entityId: EntityId): boolean
        local isFiltered = false
        if customFilter then
            isFiltered = customFilter(entityId)
        elseif filterList then
            isFiltered = table.find(filterList, entityId) ~= nil
        end
        if filterType == FILTER_TYPE_INCLUDE then
            return not isFiltered -- Include only if the filter is not found
        else
            return isFiltered -- Exclude if the filter is found
        end
    end

    -- Initialize variables for tracking the closest hit
    local closestHit = nil
    local closestDistance = math.huge

    -- Localize frequently accessed properties for performance
    local tCols = self.tCols
    local tRows = self.tRows
    local LooseGrid = self.LooseGrid
    local TightGrid = self.TightGrid
    local cWidth = self.cWidth
    local cHeight = self.cHeight
    local ShapeMap = self.ShapeMap

    -- Calculate the maximum distance of the ray
    local maxDistance = direction.Magnitude
    local directionUnit = direction.Unit
    if maxDistance <= 0 then
        warn("Ray direction has zero magnitude. This may result in unexpected behavior!")
    end

    -- Track checked loose cells to avoid redundant checks
    local checkedLooseCells = {}

    -- Grid traversal algorithm to find intersected tight cells
    local function traverseGrid(origin, directionUnit)
        local col, row = self:GetCol(origin.X), self:GetRow(origin.Y)

        -- If the ray starts outside the grid bounds, calculate the first intersection point within the grid
        if col < 1 or col > tCols or row < 1 or row > tRows then
            local tMinX, tMinY = -math.huge, -math.huge
            if directionUnit.X ~= 0 then
                if directionUnit.X > 0 then
                    tMinX = ((1 - 1) * cWidth - origin.X) / directionUnit.X
                else
                    tMinX = ((tCols - 1) * cWidth + cWidth - origin.X) / directionUnit.X
                end
            end
            if directionUnit.Y ~= 0 then
                if directionUnit.Y > 0 then
                    tMinY = ((1 - 1) * cHeight - origin.Y) / directionUnit.Y
                else
                    tMinY = ((tRows - 1) * cHeight + cHeight - origin.Y) / directionUnit.Y
                end
            end

            local tMin = math.max(tMinX, tMinY)
            if tMin < 0 or tMin > maxDistance then
                return function() return nil end -- No valid starting point within the grid
            end

            origin = origin + directionUnit * tMin
            col, row = self:GetCol(origin.X), self:GetRow(origin.Y)
        end

        local endPoint = origin + direction
        local endCol = self:GetCol(endPoint.X)
        local endRow = self:GetRow(endPoint.Y)

        -- Determine the step direction (+1 or -1) for X and Y
        local stepX = if directionUnit.X > 0 then 1 else -1
        local stepY = if directionUnit.Y > 0 then 1 else -1

        -- Calculate tDeltaX and tDeltaY (distance to cross one cell in X and Y)
        -- Calculate tDeltaX and tDeltaY (distance to cross one cell in X and Y)
        local tDeltaX = if directionUnit.X ~= 0 then math.abs(cWidth / directionUnit.X) else math.huge
        local tDeltaY = if directionUnit.Y ~= 0 then math.abs(cHeight / directionUnit.Y) else math.huge

        -- Calculate tMaxX and tMaxY (time to first grid boundary in X and Y)
        local tMaxX = if directionUnit.X > 0 then ((col - 1) * cWidth + cWidth - origin.X) / directionUnit.X else (origin.X - (col - 1) * cWidth) / -directionUnit.X
        local tMaxY = if directionUnit.Y > 0 then ((row - 1) * cHeight + cHeight - origin.Y) / directionUnit.Y else (origin.Y - (row - 1) * cHeight) / -directionUnit.Y

        local lastIteration = false
        return function()
            if col < 1 or col > tCols or row < 1 or row > tRows or lastIteration then
                return nil
            end

            if col == endCol and row == endRow then
                lastIteration = true -- Mark as last iteration if we hit the end cell
            end

            local tightCellIndex = (row - 1) * tCols + col

            -- Move to the next cell based on which boundary is closer
            if tMaxX < tMaxY then
                col += stepX
                tMaxX += tDeltaX
            else
                row += stepY
                tMaxY += tDeltaY
            end
            return tightCellIndex
        end
    end

    -- Iterate through tight cells along the ray
    for tightCellIndex in traverseGrid(origin, directionUnit) do
        local tightCell = TightGrid[tightCellIndex]
        for _, looseCellIndex in tightCell do
            if checkedLooseCells[looseCellIndex] then
                continue -- Skip already checked loose cells
            end
            checkedLooseCells[looseCellIndex] = true -- Mark loose cell as checked

            local looseCell = LooseGrid[looseCellIndex]

            -- Check each entity in the loose cell for ray intersection
            for entityId, aabb: AABB in looseCell.AABBs do
                if not skipFilter and isFilteredOut(entityId) then continue end

                local shapeType = ShapeMap[entityId]
                local hit, hitPos, normal = false, nil, nil

                if shapeType == SHAPE_TYPE_RECT then
                    hit, hitPos, normal = self:_RayAABBIntersection(origin, directionUnit, aabb[1], aabb[2], aabb[3], aabb[4])
                elseif shapeType == SHAPE_TYPE_CIRCLE then
                    hit, hitPos, normal = self:_RayCircleIntersection(origin, directionUnit, aabb)
                elseif shapeType == SHAPE_TYPE_POINT then
                    hit, hitPos, normal = self:_RayPointIntersection(origin, directionUnit, aabb)
                else
                    warn(entityId, "Unknown shape type: " .. tostring(shapeType))
                end

                if hit then
                    local distance = (hitPos - origin).Magnitude
                    if distance <= maxDistance and distance < closestDistance then
                        closestDistance = distance
                        closestHit = table.freeze {
                            Normal = normal,
                            Position = hitPos,
                            Distance = distance,
                            EntityId = entityId,
                        }
                    end
                end
            end
        end

        if closestHit then
            break -- Stop searching if we found a hit in the current cell
        end
    end

    debug.profileend()
    return closestHit
end

-- Helper function to calculate ray-AABB intersection
function LTDG:_RayAABBIntersection(origin: Vector2, direction: Vector2, l: number, b: number, r: number, t: number): (boolean, Vector2?, Vector2?)
    local invDirX = 1 / direction.X
    local invDirY = 1 / direction.Y

    local t1 = (l - origin.X) * invDirX
    local t2 = (r - origin.X) * invDirX
    local t3 = (b - origin.Y) * invDirY
    local t4 = (t - origin.Y) * invDirY

    local tMin = math.max(math.min(t1, t2), math.min(t3, t4))
    local tMax = math.min(math.max(t1, t2), math.max(t3, t4))

    if tMax < 0 or tMin > tMax then
        return false, nil, nil
    end

    local hitPos = origin + direction.Unit * tMin
    local normal = Vector2.zero
    if tMin == t1 then normal = Vector2.new(-1, 0)
    elseif tMin == t2 then normal = Vector2.new(1, 0)
    elseif tMin == t3 then normal = Vector2.new(0, -1)
    elseif tMin == t4 then normal = Vector2.new(0, 1) end

    return true, hitPos, normal
end

-- Helper function to calculate ray-circle intersection
function LTDG:_RayCircleIntersection(origin: Vector2, direction: Vector2, aabb: AABB): (boolean, Vector2?, Vector2?)
    local cx = (aabb[1] + aabb[3]) * 0.5
    local cy = (aabb[2] + aabb[4]) * 0.5
    local radius = (aabb[3] - aabb[1]) * 0.5

    local oc = Vector2.new(origin.X - cx, origin.Y - cy)
    local a = direction:Dot(direction)
    local b = 2 * oc:Dot(direction)
    local c = oc:Dot(oc) - radius * radius

    local discriminant = b * b - 4 * a * c
    if discriminant < 0 then
        return false, nil, nil
    end

    local t = (-b - math.sqrt(discriminant)) / (2 * a)
    if t < 0 then
        return false, nil, nil
    end

    local hitPos = origin + direction.Unit * t
    local normal = (hitPos - Vector2.new(cx, cy)).Unit
    return true, hitPos, normal
end

-- Helper function to calculate ray-point intersection
function LTDG:_RayPointIntersection(origin: Vector2, direction: Vector2, aabb: AABB): (boolean, Vector2?, Vector2?)
    local px, py = aabb[1], aabb[2] -- Point coordinates

    -- Vector from ray origin to the point
    local toPointX = px - origin.X
    local toPointY = py - origin.Y

    -- Cross product to check if the point lies on the ray's line
    local cross = toPointX * direction.Y - toPointY * direction.X
    if cross ~= 0 then
        return false, nil, nil -- Point is not on the ray's line
    end

    -- Dot product to ensure the point is in the correct direction
    local dot = toPointX * direction.X + toPointY * direction.Y
    if dot < 0 then
        return false, nil, nil -- Point is behind the ray's origin
    end

    -- If both checks pass, the point lies on the ray
    return true, Vector2.new(px, py), Vector2.zero
end

--[=[
    @within LooseTightDoubleGrid
    @private
    @unreleased
    @error Not implemented.
    Gets all the entities that overlap with a rotated rectangular region.

    ```lua
    grid:QueryRotatedRect(Vector2.new(30, 30), Vector2.new(10, 5), 45)
    ```
]=]
function LTDG:QueryRotatedRect(pos: Vector2, size: Vector2, angle: number): { EntityId }
    error("GetEntitiesOnRotatedRect not implemented")
end

--[=[
    @within LooseTightDoubleGrid
    @private
    @unreleased
    @error Not implemented.
    
    Queries entities within a polygonal region. The given polygon must be an array of Vector2 points
    that define the vertices of the polygon in **counter clockwise order**.

    ```lua
    grid:QueryPolygon({Vector2.new(0, 0), Vector2.new(0, 10), Vector2.new(5, 5)})
    ```
]=]
function LTDG:QueryPolygon(polygon: {Vector2}): { EntityId }
    error("GetEntitiesOnPolygon not implemented")
end

--------------------------------------------------------------------------------
    --// Debug Methods //--
--------------------------------------------------------------------------------

--[=[
    @within LooseTightDoubleGrid
    Renders the grid and its entities for debugging purposes.
    Subsequent calls will destroy the previous render model.

    ```lua
    local renderModel = grid:Draw()
    print("Render Model:", renderModel)
    ```
]=]
function LTDG:Draw(): Instance
    if self._LastRender then
        self._LastRender:Destroy()
    end
    local RenderModel = Instance.new("Folder")
    RenderModel.Name = "LTDG_Render"
    self._LastRender = RenderModel

    local CornerPos = self.Position - Vector2.new(self.tCols*self.cWidth, self.tRows*self.cHeight)/2
    local CornerPart = Instance.new("Part")
    CornerPart.Anchored = true
    CornerPart.CanCollide = false
    CornerPart.CanQuery = false
    CornerPart.CanTouch = false
    CornerPart.CastShadow = false
    CornerPart.TopSurface = Enum.SurfaceType.Smooth
    CornerPart.BottomSurface = Enum.SurfaceType.Smooth
    CornerPart.Color = Color3.fromRGB(0, 255, 0)
    CornerPart.Material = Enum.Material.Neon
    CornerPart.Size = Vector3.one
    CornerPart.Position = Vector3.new(CornerPos.X, 1, CornerPos.Y)
    CornerPart.Parent = RenderModel
    -- CornerPart.Locked = true

    for y = 0, self.tRows-1 do
        for x = 0, self.tCols-1 do
            local idx = y*self.tCols+x+1;
            local cell = self.LooseGrid[idx];
            cell:UpdateExtents(self, idx)

            local tightCellPart = CornerPart:Clone()
            tightCellPart.Name = "TightCell_"..idx
            tightCellPart.Size = Vector3.new(self.cWidth - 0.1, 0.1, self.cHeight - 0.1)
            tightCellPart.Position = CornerPart.Position + Vector3.new(x * self.cWidth + self.cWidth/2, 0, y * self.cHeight + self.cHeight/2)
            tightCellPart.Transparency = 0.75
            tightCellPart.Color = Color3.fromRGB(255, 255, 255)
            tightCellPart.Parent = RenderModel

            local l, r, t, b = cell.l, cell.r, cell.t, cell.b;
            local looseCellPart = CornerPart:Clone()
            looseCellPart.Name = "LooseCell_"..idx
            looseCellPart.Size = Vector3.new(r-l, 0.1, t-b)
            looseCellPart.Position = Vector3.new(
                l + (r-l)/2, 
                1.2, 
                b + (t-b)/2
            )
            looseCellPart.Transparency = 0.75
            looseCellPart.Color = Color3.fromRGB(164, 167, 16)
            looseCellPart.Parent = RenderModel

            local selectionBox = Instance.new("SelectionBox")
            selectionBox.LineThickness = 0.1
            selectionBox.Adornee = looseCellPart
            selectionBox.Parent = looseCellPart

            for id, aabb: AABB in cell.AABBs do
                local aabbPart = looseCellPart:Clone()
                aabbPart.Name = "AABB_"..id
                aabbPart.Size = Vector3.new(aabb[3] - aabb[1], 0.1, aabb[4] - aabb[2])
                aabbPart.Position = Vector3.new(
                    (aabb[3] + aabb[1])/2, 
                    1.5, 
                    (aabb[4] + aabb[2])/2
                )
                aabbPart.Transparency = 0.75
                aabbPart.Color = Color3.fromRGB(255, 0, 0)
                aabbPart.Parent = RenderModel
            end
        end
    end

    RenderModel.Parent = workspace
    return RenderModel
end

export type LTDG = typeof(LTDG.new({}))

return table.freeze(LTDG)
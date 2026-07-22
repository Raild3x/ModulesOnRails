--!strict
--!native
--[=[
    @class PointBinGrid
    A data structure that sorts a list of points by their proximity. It is a grid that divides the 2D space into NxN cells, 
    each of them acting as a "bin" that contains points.
]=]

local function drawLine(startPos: Vector3, endPos: Vector3, color: Color3?, duration: number?)
	-- Create a part to represent the line
	local line = Instance.new("Part")
	line.Name = "PBG_Line"
	line.Anchored = true
	line.CanCollide = false
	line.Size = Vector3.new((endPos - startPos).Magnitude, 0.1, 0.1) -- Thin line
	line.CFrame = CFrame.new((startPos + endPos) / 2, endPos) + Vector3.yAxis * 20 -- Position and orientation
	line.Color = color or Color3.fromRGB(255, 255, 255)
	line.Parent = workspace

	-- Remove the part after the duration
	task.delay(duration or 60, function()
		if line then
			line:Destroy()
		end
	end)
end

export type PointBinGrid = {
	AddPoint: (self: PointBinGrid, newPoint: Vector2) -> (),
	ForEachPoint: (self: PointBinGrid, func: (point: Vector2) -> ()) -> (),
	DrawGrid: (self: PointBinGrid, color: Color3?, duration: number?) -> (),
	DrawPointAddition: (self: PointBinGrid, point: Vector2, columnIndex: number, rowIndex: number) -> (),
}

export type PointBinGridInternal = {
	Cells: { { Vector2 }? },
	m_cellSize: Vector2,
	m_gridSize: Vector2,
	m_cellsPerSide: number,
} & PointBinGrid

--------------------------------------------------------------------------------
--// Class //--
--------------------------------------------------------------------------------

local PointBinGrid = {}
PointBinGrid.__index = PointBinGrid

-- function PointBinGrid:__iter()
--     local binIndex = 0
--     local pointIndex = 0
--     local cells = self.Cells

--     return function()
--         while binIndex < #cells do
--             local bin = cells[binIndex + 1] -- Lua arrays are 1-based
--             if bin then
--                 pointIndex += 1
--                 if pointIndex <= #bin then
--                     return bin[pointIndex]
--                 end
--             end
--             binIndex += 1
--             pointIndex = 0
--         end
--     end
-- end

--[=[
    Constructs a new PointBinGrid.

    @param cellsPerSide number -- The amount of cells per side of the grid.
    @param gridSize Vector2 -- The size of the grid in the 2D space.
    @return PointBinGrid
]=]
function PointBinGrid.new(cellsPerSide: number, gridSize: Vector2): PointBinGrid
	debug.profilebegin("Create PointBinGrid")
	local self = setmetatable({}, PointBinGrid)

	-- Handle degenerate point clouds (collinear or single point)
	-- If either dimension is 0, use a single cell grid to avoid binning errors
	if gridSize.X == 0 or gridSize.Y == 0 then
		warn("Degenerate grid size detected. Using a single cell grid to avoid binning errors.")
		cellsPerSide = 1
		gridSize = Vector2.new(1, 1) -- Use unit size for arithmetic; single cell means all points bin together
	end

	self.Cells = table.create(cellsPerSide * cellsPerSide) -- Array of bins (each bin is a table of Vector2 points)
	self.m_cellSize = gridSize / cellsPerSide
	self.m_gridSize = gridSize
	self.m_cellsPerSide = cellsPerSide

	-- Initialize empty bins (Doesnt table.create already do this?)
	for i = 1, cellsPerSide * cellsPerSide do
		self.Cells[i] = nil
	end

	-- self:DrawGrid()
	debug.profileend()
	return self :: any
end

--[=[
    Adds a point to a bin of the grid, according to its position in 2D space.

    @param newPoint Vector2 -- The point to add.
]=]
function PointBinGrid.AddPoint(self: PointBinGridInternal, newPoint: Vector2)
	debug.profilebegin("AddPoint to PointBinGrid")
	local cellsPerSide: number = self.m_cellsPerSide

	local rowIndex = math.floor(0.99 * cellsPerSide * newPoint.Y / self.m_gridSize.Y)
	local columnIndex = math.floor(0.99 * cellsPerSide * newPoint.X / self.m_gridSize.X)

	local binIndex
	if rowIndex % 2 == 0 then
		binIndex = rowIndex * cellsPerSide + columnIndex + 1
	else
		binIndex = (rowIndex + 1) * cellsPerSide - columnIndex
	end

	-- print(binIndex)

	if not self.Cells[binIndex] then
		self.Cells[binIndex] = {}
	end

	table.insert(self.Cells[binIndex] :: { Vector2 }, newPoint)
	debug.profileend()
	-- self:DrawPointAddition(newPoint, columnIndex, rowIndex)
end

--[=[
    
]=]
function PointBinGrid.ForEachPoint(self: PointBinGridInternal, func: (point: Vector2) -> ())
	for _, cell in self.Cells do
		for _, point in cell do
			func(point)
		end
	end
end

function PointBinGrid.DrawGrid(self: PointBinGridInternal, color: Color3?, duration: number?)
	local cellsPerSide: number = self.m_cellsPerSide
	local cellSize: Vector2 = self.m_cellSize
	local gridSize: Vector2 = self.m_gridSize

	for i = 0, cellsPerSide - 1 do
		-- Draw horizontal lines
		local startPos = Vector3.new(0, 0, i * cellSize.Y)
		local endPos = Vector3.new(gridSize.X, 0, i * cellSize.Y)
		drawLine(startPos, endPos, color, duration)
	end

	for j = 0, cellsPerSide - 1 do
		-- Draw vertical lines
		local startPos = Vector3.new(j * cellSize.X, 0, 0)
		local endPos = Vector3.new(j * cellSize.X, 0, gridSize.Y)
		drawLine(startPos, endPos, color, duration)
	end
end

function PointBinGrid.DrawPointAddition(
	self: PointBinGridInternal,
	point: Vector2,
	columnIndex: number,
	rowIndex: number
)
	-- Calculate the bottom-left corner of the cell
	local cellBottomLeftCorner = Vector2.new(columnIndex * self.m_cellSize.X, rowIndex * self.m_cellSize.Y)

	-- Calculate the center of the cell
	local cellCenter = cellBottomLeftCorner + self.m_cellSize * 0.5

	-- Convert the 2D points to 3D for drawing
	local point3D = Vector3.new(point.X, 0, point.Y)
	local cellCenter3D = Vector3.new(cellCenter.X, 0, cellCenter.Y)

	-- Draw a line from the point to the center of the cell
	drawLine(point3D, cellCenter3D, Color3.fromRGB(0, 255, 255), 60.0) -- Cyan color
end

return PointBinGrid

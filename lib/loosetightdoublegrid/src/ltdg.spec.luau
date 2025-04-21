local LooseTightDoubleGrid = require("./init")
local LooseCell = require("LooseCell")

local Vector2 = {
	new = function(x, y)
		return { X = x, Y = y }
	end,
}

local test_suite = function(tiniest)
	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

	local function createGenericGrid()
		return LooseTightDoubleGrid.new({
			Position = Vector2.new(0, 0),
			Size = Vector2.new(10, 10),
			CellSize = 2,
		})
	end

	describe("LooseTightDoubleGrid", function()
		describe("Initialization", function()
			test("should initialize with correct properties", function()
				local grid = createGenericGrid()
				expect(grid.Position).is_shallow_equal(Vector2.new(0, 0))
				expect(grid.tCols).is(10)
				expect(grid.tRows).is(10)
				expect(grid.cWidth).is(2)
				expect(grid.cHeight).is(2)
			end)
		end)

		describe("Entity Operations", function()
			describe("Insertion", function()
				test("should insert a rectangle entity", function()
					local grid = createGenericGrid()
					local id = grid:InsertRect(Vector2.new(5, 5), Vector2.new(2, 2))
					expect(grid:Has(id)).is(true)
				end)

				test("should insert a circular entity", function()
					local grid = createGenericGrid()
					local id = grid:InsertCircle(Vector2.new(3, 3), 1)
					expect(grid:Has(id)).is(true)
				end)

				test("should insert a point entity", function()
					local grid = createGenericGrid()
					local id = grid:InsertPoint(Vector2.new(7, 7))
					expect(grid:Has(id)).is(true)
				end)
			end)

			describe("Update", function()
				test("should update a rectangle entity", function()
					local grid = createGenericGrid()
					local id = grid:InsertRect(Vector2.new(5, 5), Vector2.new(2, 2))
					grid:UpdateRect(id, Vector2.new(6, 6), Vector2.new(3, 3))
					local entities = grid:QueryRect(Vector2.new(6, 6), Vector2.new(3, 3))
					expect(entities).has_value(id)
				end)

				test("should update a circular entity", function()
					local grid = createGenericGrid()
					local id = grid:InsertCircle(Vector2.new(3, 3), 1)
					grid:UpdateCircle(id, Vector2.new(4, 4), 2)
					local entities = grid:QueryCircle(Vector2.new(4, 4), 2)
					expect(entities).has_value(id)
				end)

				test("should update a point entity", function()
					local grid = createGenericGrid()
					local id = grid:InsertPoint(Vector2.new(7, 7))
					grid:UpdatePoint(id, Vector2.new(8, 8))
					local entities = grid:QueryPoint(Vector2.new(8, 8))
					expect(entities).has_value(id)
				end)
			end)

			describe("Removal", function()
				test("should remove an entity", function()
					local grid = createGenericGrid()
					local id = grid:InsertRect(Vector2.new(5, 5), Vector2.new(2, 2))
					local removed = grid:Remove(id)
					expect(removed).is(true)
					expect(grid:Has(id)).is(false)
				end)

				test("should return false when removing a non-existent entity", function()
					local grid = createGenericGrid()
					local removed = grid:Remove(999)
					expect(removed).is(false)
				end)
			end)
		end)

		describe("Query Operations", function()
			describe("Query Region", function()
				test("should return entities fully contained within a single loose cell", function()
					local grid = createGenericGrid()
				
					-- Insert entities into the grid
					local id1 = grid:InsertRect(Vector2.new(1, 1), Vector2.new(1, 1)) -- Fully within one loose cell
					local id2 = grid:InsertRect(Vector2.new(3, 3), Vector2.new(1, 1)) -- Outside the query region
				
					-- Query a region that only overlaps with id1
					local entities = grid:_QueryRegion(0.5, 0.5, 1.5, 1.5)
					expect(entities).has_value(id1)
					expect(entities).never_has_value(id2)
				end)
	
				test("should return entities spanning multiple loose cells", function()
					local grid = createGenericGrid()
				
					-- Insert entities into the grid
					local id1 = grid:InsertRect(Vector2.new(1, 1), Vector2.new(1, 1)) -- In one cell
					local id2 = grid:InsertRect(Vector2.new(3, 3), Vector2.new(2, 2)) -- Spans multiple cells
				
					-- Query a region that overlaps both entities
					local entities = grid:_QueryRegion(0, 0, 4, 4)
					expect(entities).has_value(id1)
					expect(entities).has_value(id2)
				end)
	
				test("should return an empty result when no entities are in the region", function()
					local grid = createGenericGrid()
				
					-- Insert entities outside the query region
					grid:InsertRect(Vector2.new(5, 5), Vector2.new(1, 1))
				
					-- Query a region with no entities
					local entities = grid:_QueryRegion(0, 0, 1, 1)
					expect(#entities).is(0)
				end)
	
				test("should return entities when the region touches the edge of a loose cell", function()
					local grid = createGenericGrid()
				
					-- Insert entities into the grid
					local id1 = grid:InsertRect(Vector2.new(2, 2), Vector2.new(1, 1)) -- On the edge of a loose cell
				
					-- Query a region that touches the edge of the loose cell
					local entities = grid:_QueryRegion(1.5, 1.5, 2.5, 2.5)
					expect(entities).has_value(id1)
				end)
	
				test("should handle regions larger than the grid", function()
					local grid = createGenericGrid()
				
					-- Insert entities into the grid
					local id1 = grid:InsertRect(Vector2.new(5, 5), Vector2.new(1, 1))
				
					-- Query a region larger than the grid
					local entities = grid:_QueryRegion(-10, -10, 20, 20)
					expect(entities).has_value(id1)
				end)
			end)
	
			describe("Query Specific Shapes", function()
				test("should query entities in a rectangular region", function()
					local grid = createGenericGrid()
					local id1 = grid:InsertRect(Vector2.new(5, 5), Vector2.new(2, 2))
					local id2 = grid:InsertRect(Vector2.new(8, 8), Vector2.new(2, 2))
					local entities = grid:QueryRect(Vector2.new(5, 5), Vector2.new(3, 3))
					expect(entities).has_value(id1)
					expect(entities).never_has_value(id2)
				end)
	
				test("should query entities in a circular region", function()
					local grid = createGenericGrid()
					local id1 = grid:InsertCircle(Vector2.new(5, 5), 2)
					local id2 = grid:InsertCircle(Vector2.new(8, 8), 2)
					local entities = grid:QueryCircle(Vector2.new(5, 5), 2.1)
					expect(entities).has_value(id1)
					expect(entities).never_has_value(id2)
				end)
	
				test("should query entities at a specific point", function()
					local grid = createGenericGrid()
					local id1 = grid:InsertPoint(Vector2.new(5, 5))
					local id2 = grid:InsertPoint(Vector2.new(8, 8))
					local entities = grid:QueryPoint(Vector2.new(5, 5))
					expect(entities).has_value(id1)
					expect(entities).never_has_value(id2)
				end)
	
				test("should correctly identify point entities at a specific point", function()
					local grid = createGenericGrid()
				
					-- Insert a point entity
					local id = grid:InsertPoint(Vector2.new(5, 5))
				
					-- Query the exact point
					local entities = grid:QueryPoint(Vector2.new(5, 5))
					expect(entities).has_value(id)
				
					-- Query a point outside the entity's bounds
					local emptyEntities = grid:QueryPoint(Vector2.new(6, 6))
					expect(#emptyEntities).is(0)
				end)
		
				test("should correctly identify overlapping entities", function()
					local grid = createGenericGrid()
				
					-- Insert overlapping entities
					local id1 = grid:InsertRect(Vector2.new(5, 5), Vector2.new(4, 4))
					local id2 = grid:InsertRect(Vector2.new(6, 6), Vector2.new(4, 4))
				
					-- Query a region that overlaps both entities
					local entities = grid:QueryRect(Vector2.new(5, 5), Vector2.new(6, 6))
					expect(entities).has_value(id1)
					expect(entities).has_value(id2)
				end)
			end)
	
			describe("Circle Queries", function()
				test("should correctly query entities in a circular region", function()
					local grid = createGenericGrid()
					local id1 = grid:InsertCircle(Vector2.new(5, 5), 2)
					local id2 = grid:InsertCircle(Vector2.new(8, 8), 2)
					local entities = grid:QueryCircle(Vector2.new(5, 5), 2.12)
					expect(entities).has_value(id1)
					expect(entities).never_has_value(id2)
				end)
			
				test("should handle circle-rectangle intersections", function()
					local grid = createGenericGrid()
					local id = grid:InsertRect(Vector2.new(5, 5), Vector2.new(2, 2))
					local entities = grid:QueryCircle(Vector2.new(5, 5), 2)
					expect(entities).has_value(id)
				end)
			
				test("should handle circle-circle intersections", function()
					local grid = createGenericGrid()
					local id1 = grid:InsertCircle(Vector2.new(5, 5), 2)
					local id2 = grid:InsertCircle(Vector2.new(6, 6), 2)
					local entities = grid:QueryCircle(Vector2.new(5, 5), 2.2)
					expect(entities).has_value(id1)
					expect(entities).has_value(id2)
				end)
			end)
		end)

		describe("Edge Cases", function()
			test("should handle querying an empty grid", function()
				local grid = createGenericGrid()
				local entities = grid:QueryRect(Vector2.new(0, 0), Vector2.new(10, 10))
				expect(#entities).is(0)
			end)

			test("should handle updating a non-existent entity", function()
				local grid = createGenericGrid()
				expect(function()
					grid:UpdateRect(999, Vector2.new(5, 5), Vector2.new(2, 2))
				end).fails()
			end)
		end)

		describe("Performance", function()
			test("should handle a large number of entities", function()
				local grid = createGenericGrid()
				for i = 1, 10000 do
					grid:InsertRect(Vector2.new(math.random(0, 20), math.random(0, 20)), Vector2.new(1, 1))
				end
				local entities = grid:QueryRect(Vector2.new(10, 10), Vector2.new(5, 5))
				expect(#entities > 0)
			end)
		end)

		describe("GetEntity Methods", function()
			test("should return the correct position of an entity", function()
				local grid = createGenericGrid()
				local id = grid:InsertRect(Vector2.new(5, 5), Vector2.new(2, 2))
				local position = grid:GetEntityPosition(id)
				expect(position).is_shallow_equal(Vector2.new(5, 5))
			end)
		
			test("should return the correct size of an entity", function()
				local grid = createGenericGrid()
				local id = grid:InsertRect(Vector2.new(5, 5), Vector2.new(2, 2))
				local size = grid:GetEntitySize(id)
				expect(size).is_shallow_equal(Vector2.new(2, 2))
			end)
		
			test("should return the correct position and size of an entity", function()
				local grid = createGenericGrid()
				local id = grid:InsertRect(Vector2.new(5, 5), Vector2.new(2, 2))
				local position, size = grid:GetEntityPositionAndSize(id)
				expect(position).is_shallow_equal(Vector2.new(5, 5))
				expect(size).is_shallow_equal(Vector2.new(2, 2))
			end)
		
			test("should throw an error when getting position of a non-existent entity", function()
				local grid = createGenericGrid()
				expect(function()
					grid:GetEntityPosition(999)
				end).fails()
			end)
		
			test("should throw an error when getting size of a non-existent entity", function()
				local grid = createGenericGrid()
				expect(function()
					grid:GetEntitySize(999)
				end).fails()
			end)
		
			test("should throw an error when getting position and size of a non-existent entity", function()
				local grid = createGenericGrid()
				expect(function()
					grid:GetEntityPositionAndSize(999)
				end).fails()
			end)
		end)

		describe("LooseCell", function()
			test("Intersects should correctly identify intersections", function()
				local looseCell = LooseCell.new(0, 0, 10, 10) -- Loose cell bounds: L=0, B=0, R=10, T=10
				looseCell.l = 0
				looseCell.b = 0
				looseCell.r = 10
				looseCell.t = 10
				-- print("LooseCell bounds:", looseCell.l, looseCell.r, looseCell.t, looseCell.b)
	
				-- Test cases for intersection
				expect(looseCell:Intersects(5, 5, 15, 15)).is(true) -- Partial overlap
				expect(looseCell:Intersects(0, 0, 10, 10)).is(true) -- Exact overlap
				expect(looseCell:Intersects(-5, -5, 5, 5)).is(true) -- Partial overlap
				expect(looseCell:Intersects(15, 15, 20, 20)).is(false) -- No overlap
			end)
		end)

		describe("Internal Methods", function()
			test("LTDG:_UpdateEntity should throw an error for non-existent entities", function()
				local grid = createGenericGrid()
			
				-- Attempt to update a non-existent entity
				expect(function()
					grid:_UpdateEntity(999, Vector2.new(5, 5), 0, 0, 10, 10)
				end).fails()
			end)
		end)
	end)
end

return test_suite
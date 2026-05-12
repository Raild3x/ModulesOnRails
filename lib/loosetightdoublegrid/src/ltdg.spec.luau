local LooseTightDoubleGrid = require("./ltdg")
local LooseCell = require("./LooseCell")
local Vector2 = require("./Shims/Vector2")
local Enum = require("./Shims/Enum")

local _profilebegin, _profileend = function(label: string) end, function() end
if debug and debug.profilebegin and debug.profileend then
	_profilebegin, _profileend = debug.profilebegin, debug.profileend
end

local task = task
if not task then
	task = {
		wait = function(num: number) end,
	}
end

local DO_BENCHMARKS = false

local test_suite = function(tiniest: tiniest)
	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

	local function createGenericGrid()
		return LooseTightDoubleGrid.new {
			Position = Vector2.new(0, 0),
			Size = Vector2.new(10, 10),
			CellSize = 2,
		}
	end

	local function checkVectorsEqual(v1, v2)
		if v1 == v2 then
			return
		end
		expect(v1).exists()
		expect(v2).exists()
		expect(v1.X).is(v2.X)
		expect(v1.Y).is(v2.Y)
	end

	local function createDeterministicRng(seed: number)
		local state = seed
		local function nextUnit()
			state = (1103515245 * state + 12345) % 2147483648
			return state / 2147483648
		end

		return {
			nextNumber = function(min: number, max: number)
				return min + (max - min) * nextUnit()
			end,
			nextInt = function(min: number, max: number)
				return math.floor(min + (max - min + 1) * nextUnit())
			end,
		}
	end

	local function runPerfBenchmark(name: string, iterations: number, callback)
		callback(0, 0) -- warmup

		local function copyArray(source)
			local out = {}
			for i = 1, #source do
				out[i] = source[i]
			end
			return out
		end

		local function calculateStats(samples, trimPercent: number)
			local count = #samples
			assert(count > 0, "Perf benchmark requires at least 1 sample")

			local sorted = copyArray(samples)
			table.sort(sorted)

			local sum = 0
			for i = 1, count do
				sum += sorted[i]
			end

			local average = sum / count
			local median = if count % 2 == 1
				then sorted[(count + 1) / 2]
				else (sorted[count / 2] + sorted[count / 2 + 1]) * 0.5

			local trimCountEachSide = math.floor(count * trimPercent)
			local trimStart = trimCountEachSide + 1
			local trimEnd = count - trimCountEachSide
			if trimStart > trimEnd then
				trimStart = 1
				trimEnd = count
				trimCountEachSide = 0
			end

			local trimmedSum = 0
			for i = trimStart, trimEnd do
				trimmedSum += sorted[i]
			end
			local trimmedCount = trimEnd - trimStart + 1
			local trimmedAverage = trimmedSum / trimmedCount

			return {
				average = average,
				median = median,
				trimmedAverage = trimmedAverage,
				trimPercent = trimPercent,
				trimCountEachSide = trimCountEachSide,
				sampleCount = count,
				min = sorted[1],
				max = sorted[count],
			}
		end

		local sampleCount = 100
		local trimPercent = 0.05
		local totalSamplesMs = {}
		local perOpSamplesUs = {}
		local totalChecksum = 0

		for sampleIndex = 1, sampleCount do
			local start = os.clock()
			local checksum = 0
			for i = 1, iterations do
				checksum += callback(i, sampleIndex) or 0
			end
			local elapsed = os.clock() - start
			totalSamplesMs[sampleIndex] = elapsed * 1000
			perOpSamplesUs[sampleIndex] = elapsed * 1000000 / iterations
			totalChecksum += checksum
			if sampleIndex % 2 == 0 then
				task.wait()
			end
		end

		local totalMsStats = calculateStats(totalSamplesMs, trimPercent)
		local perOpUsStats = calculateStats(perOpSamplesUs, trimPercent)

		print(
			string.format(
				"[PERF] %s | samples=%d | iters=%d | total(ms): avg=%.3f med=%.3f trim%.0f%%=%.3f | perOp(us): avg=%.2f med=%.2f trim%.0f%%=%.2f | checksum=%d",
				name,
				sampleCount,
				iterations,
				totalMsStats.average,
				totalMsStats.median,
				trimPercent * 100,
				totalMsStats.trimmedAverage,
				perOpUsStats.average,
				perOpUsStats.median,
				trimPercent * 100,
				perOpUsStats.trimmedAverage,
				totalChecksum
			)
		)

		return {
			totalMs = totalMsStats.average,
			perOpUs = perOpUsStats.average,
			checksum = totalChecksum,
			totalMsStats = totalMsStats,
			perOpUsStats = perOpUsStats,
			samples = sampleCount,
			iterations = iterations,
		}
	end

	local function createPerfGrid()
		return LooseTightDoubleGrid.new {
			Position = Vector2.new(0, 0),
			Size = Vector2.new(160, 160),
			CellSize = 4,
		}
	end

	local function populateMixedEntities(grid, entityCount: number, seed: number)
		local rng = createDeterministicRng(seed)
		local ids = {}
		for i = 1, entityCount do
			local pos = Vector2.new(rng.nextNumber(-300, 300), rng.nextNumber(-300, 300))
			if i % 3 == 1 then
				ids[i] = grid:InsertRect(pos, Vector2.new(rng.nextNumber(1, 8), rng.nextNumber(1, 8)))
			elseif i % 3 == 2 then
				ids[i] = grid:InsertCircle(pos, rng.nextNumber(0.5, 4))
			else
				ids[i] = grid:InsertPoint(pos)
			end
		end
		return ids
	end

	describe("Initialization", function()
		test("should initialize with correct properties", function()
			local grid = createGenericGrid()
			checkVectorsEqual(grid.Position, Vector2.new(0, 0))
			checkVectorsEqual(grid.Size, Vector2.new(10, 10))
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

			test("should query moved rectangle only at its new location", function()
				local grid = createGenericGrid()
				local id = grid:InsertRect(Vector2.new(1, 1), Vector2.new(2, 2))

				grid:UpdateRect(id, Vector2.new(8, 1), Vector2.new(2, 2))

				local oldEntities = grid:QueryRect(Vector2.new(1, 1), Vector2.new(2, 2))
				expect(oldEntities).never_has_value(id)

				local newEntities = grid:QueryRect(Vector2.new(8, 1), Vector2.new(2, 2))
				expect(newEntities).has_value(id)
			end)

			test("should query final location after multiple rectangle moves", function()
				local grid = createGenericGrid()
				local id = grid:InsertRect(Vector2.new(1, 1), Vector2.new(2, 2))

				grid:UpdateRect(id, Vector2.new(8, 1), Vector2.new(2, 2))
				grid:UpdateRect(id, Vector2.new(8, 8), Vector2.new(2, 2))
				grid:UpdateRect(id, Vector2.new(2, 8), Vector2.new(2, 2))
				grid:UpdateRect(id, Vector2.new(6, 6), Vector2.new(2, 2))

				local staleEntities = grid:QueryRect(Vector2.new(1, 1), Vector2.new(2, 2))
				expect(staleEntities).never_has_value(id)

				local finalEntities = grid:QueryRect(Vector2.new(6, 6), Vector2.new(2, 2))
				expect(finalEntities).has_value(id)
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

			test("should query moved circle only at its new location", function()
				local grid = createGenericGrid()
				local id = grid:InsertCircle(Vector2.new(2, 8), 1)

				grid:UpdateCircle(id, Vector2.new(8, 8), 1)

				local oldEntities = grid:QueryCircle(Vector2.new(2, 8), 1.2)
				expect(oldEntities).never_has_value(id)

				local newEntities = grid:QueryCircle(Vector2.new(8, 8), 1.2)
				expect(newEntities).has_value(id)
			end)

			test("should honor filters for moved circles", function()
				local grid = createGenericGrid()
				local includeId = grid:InsertCircle(Vector2.new(1, 1), 1)
				local excludeId = grid:InsertCircle(Vector2.new(1, 1), 1)

				grid:UpdateCircle(includeId, Vector2.new(6, 6), 1)
				grid:UpdateCircle(excludeId, Vector2.new(8, 6), 1)

				local includeEntities = grid:QueryCircle(Vector2.new(7, 6), 3, {
					FilterList = { excludeId },
					FilterType = Enum.RaycastFilterType.Exclude,
				})
				expect(includeEntities).has_value(includeId)
				expect(includeEntities).never_has_value(excludeId)

				local onlyFarEntities = grid:QueryCircle(Vector2.new(7, 6), 3, {
					FilterList = { excludeId },
					FilterType = Enum.RaycastFilterType.Include,
				})
				expect(onlyFarEntities).has_value(excludeId)
				expect(onlyFarEntities).never_has_value(includeId)
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

		describe("QueryClosestToPoint", function()
			test("should return nil when the grid is empty", function()
				local grid = createGenericGrid()
				local closestEntityId = grid:QueryClosestToPoint(Vector2.new(5, 5))
				expect(closestEntityId).is(nil)
			end)

			test("should return the closest entity when multiple entities are present", function()
				local grid = createGenericGrid()
				local rectId = grid:InsertRect(Vector2.new(5, 5), Vector2.new(2, 2))
				local _circleId = grid:InsertCircle(Vector2.new(9, 5), 1)
				local closestEntityId = grid:QueryClosestToPoint(Vector2.new(7, 5))
				expect(closestEntityId).is(rectId)
			end)

			test(
				"should return the entity containing the point whose center is closest when inside multiple shapes",
				function()
					local grid = createGenericGrid()
					local rectId = grid:InsertRect(Vector2.new(5, 5), Vector2.new(4, 4))
					local _circleId = grid:InsertCircle(Vector2.new(9, 5), 3)
					local closestEntityId = grid:QueryClosestToPoint(Vector2.new(6, 5))
					expect(closestEntityId).is(rectId) -- Rect is prioritized due to center distance tie-breaking
				end
			)

			test("should return the closest point entity when multiple points are present", function()
				local grid = createGenericGrid()
				local pointId1 = grid:InsertPoint(Vector2.new(5, 5))
				local _pointId2 = grid:InsertPoint(Vector2.new(7.1, 7))
				local closestEntityId = grid:QueryClosestToPoint(Vector2.new(6, 6))
				expect(closestEntityId).is(pointId1)
			end)

			test("should handle overlapping entities correctly", function()
				local grid = createGenericGrid()
				local _rectId = grid:InsertRect(Vector2.new(5, 5), Vector2.new(4, 4))
				local circleId = grid:InsertCircle(Vector2.new(6, 5), 2)
				local closestEntityId = grid:QueryClosestToPoint(Vector2.new(6, 5))
				expect(closestEntityId).is(circleId) -- Circle internal pos is closer to the query point
			end)

			test("should handle entities on the edge of the grid", function()
				local grid = createGenericGrid()
				local rectId = grid:InsertRect(Vector2.new(0, 0), Vector2.new(2, 2))
				local closestEntityId = grid:QueryClosestToPoint(Vector2.new(0, 0))
				expect(closestEntityId).is(rectId)
			end)

			test("should handle entities with the same distance to the query point", function()
				local grid = createGenericGrid()
				local rectId = grid:InsertRect(Vector2.new(5, 5), Vector2.new(2, 2))
				local _circleId = grid:InsertCircle(Vector2.new(5, 5), 1)
				local closestEntityId = grid:QueryClosestToPoint(Vector2.new(5, 5))
				expect(closestEntityId).is(rectId) -- Rect is prioritized due to tie-breaking
			end)

			-- test("should handle a large number of entities efficiently", function()
			-- 	local grid = createGenericGrid()
			-- 	for i = 1, 1000 do
			-- 		grid:InsertRect(Vector2.new(math.random(0, 10), math.random(0, 10)), Vector2.new(1, 1))
			-- 	end
			-- 	local closestEntityId = grid:QueryClosestToPoint(Vector2.new(5, 5))
			-- 	expect(closestEntityId).is_not(nil) -- Ensure it returns a valid entity
			-- end)

			test("should handle points exactly on the edge of a circle", function()
				local grid = createGenericGrid()
				local circleId = grid:InsertCircle(Vector2.new(5, 5), 2)
				local closestEntityId = grid:QueryClosestToPoint(Vector2.new(7, 5))
				expect(closestEntityId).is(circleId)
			end)

			test("should handle points exactly on the edge of a rectangle", function()
				local grid = createGenericGrid()
				local rectId = grid:InsertRect(Vector2.new(5, 5), Vector2.new(4, 4))
				local closestEntityId = grid:QueryClosestToPoint(Vector2.new(7, 5))
				expect(closestEntityId).is(rectId)
			end)
		end)
	end)

	describe("Raycast", function()
		test("should return nil when no entities are intersected", function()
			local grid = createGenericGrid()
			local hit = grid:Raycast(Vector2.new(0, 0), Vector2.new(1, 0))
			expect(hit).is(nil)
		end)

		test("should return the closest intersected rectangle entity", function()
			local grid = createGenericGrid()
			local id1 = grid:InsertRect(Vector2.new(5, 5), Vector2.new(2, 2))
			local _id2 = grid:InsertRect(Vector2.new(8, 5), Vector2.new(2, 2))
			local hit = grid:Raycast(Vector2.new(0, 5), Vector2.new(10, 0))
			expect(hit).is_not(nil)
			expect(hit.EntityId).is(id1)
		end)

		test("should return the closest intersected circle entity", function()
			local grid = createGenericGrid()
			local id1 = grid:InsertCircle(Vector2.new(5, 5), 2)
			local _id2 = grid:InsertCircle(Vector2.new(8, 5), 2)
			local hit = grid:Raycast(Vector2.new(0, 5), Vector2.new(10, 0))
			expect(hit).is_not(nil)
			expect(hit.EntityId).is(id1)
		end)

		test("should return the closest intersected point entity", function()
			local grid = createGenericGrid()
			local id1 = grid:InsertPoint(Vector2.new(5, 5))
			local _id2 = grid:InsertPoint(Vector2.new(8, 5))
			local hit = grid:Raycast(Vector2.new(0, 5), Vector2.new(10, 0))
			expect(hit).is_not(nil)
			expect(hit.EntityId).is(id1)
		end)

		test("should handle mixed entity types and return the closest intersection", function()
			local grid = createGenericGrid()
			local rectId = grid:InsertRect(Vector2.new(5, 5), Vector2.new(2, 2))
			local _circleId = grid:InsertCircle(Vector2.new(8, 5), 2)
			local _pointId = grid:InsertPoint(Vector2.new(10, 5))
			local hit = grid:Raycast(Vector2.new(0, 5), Vector2.new(10, 0))
			expect(hit).is_not(nil)
			expect(hit.EntityId).is(rectId)
		end)

		test("should respect the filter list and exclude entities", function()
			local grid = createGenericGrid()
			local id1 = grid:InsertRect(Vector2.new(5, 5), Vector2.new(2, 2))
			local id2 = grid:InsertRect(Vector2.new(8, 5), Vector2.new(2, 2))
			local hit = grid:Raycast(Vector2.new(0, 5), Vector2.new(10, 0), {
				FilterList = { id1 },
				FilterType = Enum.RaycastFilterType.Exclude,
			})
			expect(hit).is_not(nil)
			expect(hit.EntityId).is(id2)
		end)

		test("should respect the filter list and include only specified entities", function()
			local grid = createGenericGrid()
			local _id1 = grid:InsertRect(Vector2.new(5, 5), Vector2.new(2, 2))
			local id2 = grid:InsertRect(Vector2.new(8, 5), Vector2.new(2, 2))
			local hit = grid:Raycast(Vector2.new(0, 5), Vector2.new(10, 0), {
				FilterList = { id2 },
				FilterType = Enum.RaycastFilterType.Include,
			})
			expect(hit).is_not(nil)
			expect(hit.EntityId).is(id2)
		end)

		test("should respect a custom filter function", function()
			local grid = createGenericGrid()
			local _id1 = grid:InsertRect(Vector2.new(5, 5), Vector2.new(2, 2))
			local id2 = grid:InsertRect(Vector2.new(8, 5), Vector2.new(2, 2))
			local hit = grid:Raycast(Vector2.new(0, 5), Vector2.new(10, 0), {
				FilterType = Enum.RaycastFilterType.Include,
				CustomFilter = function(entityId)
					return entityId == id2
				end,
			})
			expect(hit).is_not(nil)
			expect(hit.EntityId).is(id2)
		end)

		test("should handle rays that start inside an entity", function()
			local grid = createGenericGrid()
			local id = grid:InsertRect(Vector2.new(5, 5), Vector2.new(2, 2))
			local hit = grid:Raycast(Vector2.new(5, 5), Vector2.new(10, 0))
			expect(hit).is_not(nil)
			expect(hit.EntityId).is(id)
		end)

		test("should handle rays that miss all entities", function()
			local grid = createGenericGrid()
			grid:InsertRect(Vector2.new(5, 5), Vector2.new(2, 2))
			local hit = grid:Raycast(Vector2.new(0, 0), Vector2.new(10, 1))
			expect(hit).is(nil)
		end)

		test("should handle rays that intersect multiple entities and return the closest one", function()
			local grid = createGenericGrid()
			local id1 = grid:InsertRect(Vector2.new(5, 5), Vector2.new(2, 2))
			local _id2 = grid:InsertRect(Vector2.new(8, 5), Vector2.new(2, 2))
			local hit = grid:Raycast(Vector2.new(0, 5), Vector2.new(10, 0))
			expect(hit).is_not(nil)
			expect(hit.EntityId).is(id1)
		end)

		test("should respect the maximum distance of the ray", function()
			local grid = createGenericGrid()
			local id1 = grid:InsertRect(Vector2.new(5, 5), Vector2.new(2, 2))
			local _id2 = grid:InsertRect(Vector2.new(10, 5), Vector2.new(2, 2))
			local hit = grid:Raycast(Vector2.new(0, 5), Vector2.new(6, 0)) -- Ray ends before reaching id2
			expect(hit).is_not(nil)
			expect(hit.EntityId).is(id1)
		end)

		test("should return nil if no entities are within the ray's maximum distance", function()
			local grid = createGenericGrid()
			grid:InsertRect(Vector2.new(10, 5), Vector2.new(2, 2))
			local hit = grid:Raycast(Vector2.new(0, 5), Vector2.new(5, 0)) -- Ray ends before reaching any entity
			expect(hit).is(nil)
		end)

		test("should handle rays starting outside the grid bounds and intersecting entities", function()
			local grid = createGenericGrid()
			local id = grid:InsertRect(Vector2.new(5, 5), Vector2.new(2, 2))
			local hit = grid:Raycast(Vector2.new(-200, 5), Vector2.new(400, 0)) -- Starts outside the grid
			expect(hit).is_not(nil)
			expect(hit.EntityId).is(id)
		end)

		test("should return nil for rays starting outside the grid bounds and missing all entities", function()
			local grid = createGenericGrid()
			grid:InsertRect(Vector2.new(5, 5), Vector2.new(2, 2))
			local hit = grid:Raycast(Vector2.new(-10, -10), Vector2.new(5, 5)) -- Starts outside and misses
			expect(hit).is(nil)
		end)

		test("should raycast a moved rectangle at its new position and miss its old position", function()
			local grid = createGenericGrid()
			local id = grid:InsertRect(Vector2.new(1, 1), Vector2.new(2, 2))

			grid:UpdateRect(id, Vector2.new(8, 1), Vector2.new(2, 2))

			local oldPosHit = grid:Raycast(Vector2.new(0, 1), Vector2.new(3, 0))
			expect(oldPosHit).is(nil)

			local newPosHit = grid:Raycast(Vector2.new(6, 1), Vector2.new(4, 0))
			expect(newPosHit).is_not(nil)
			expect(newPosHit.EntityId).is(id)
		end)

		test("should raycast a moved circle after crossing cells", function()
			local grid = createGenericGrid()
			local id = grid:InsertCircle(Vector2.new(2, 8), 1)

			grid:UpdateCircle(id, Vector2.new(8, 8), 1)

			local hit = grid:Raycast(Vector2.new(6, 8), Vector2.new(4, 0))
			expect(hit).is_not(nil)
			expect(hit.EntityId).is(id)
		end)

		test("should raycast a moved point and not hit the stale location", function()
			local grid = createGenericGrid()
			local id = grid:InsertPoint(Vector2.new(2, 2))

			grid:UpdatePoint(id, Vector2.new(7, 7))

			local staleHit = grid:Raycast(Vector2.new(1, 2), Vector2.new(2, 0))
			expect(staleHit).is(nil)

			local movedHit = grid:Raycast(Vector2.new(6, 7), Vector2.new(2, 0))
			expect(movedHit).is_not(nil)
			expect(movedHit.EntityId).is(id)
		end)

		test("should return nearest moved entity when multiple moved entities lie on the same ray", function()
			local grid = createGenericGrid()
			local nearId = grid:InsertRect(Vector2.new(1, 5), Vector2.new(2, 2))
			local farId = grid:InsertRect(Vector2.new(1, 5), Vector2.new(2, 2))

			grid:UpdateRect(nearId, Vector2.new(6, 5), Vector2.new(2, 2))
			grid:UpdateRect(farId, Vector2.new(9, 5), Vector2.new(2, 2))

			local hit = grid:Raycast(Vector2.new(0, 5), Vector2.new(12, 0))
			expect(hit).is_not(nil)
			expect(hit.EntityId).is(nearId)
		end)

		test("should not raycast an entity after it is moved and then removed", function()
			local grid = createGenericGrid()
			local id = grid:InsertRect(Vector2.new(2, 2), Vector2.new(2, 2))

			grid:UpdateRect(id, Vector2.new(8, 8), Vector2.new(2, 2))
			expect(grid:Remove(id)).is(true)

			local oldPathHit = grid:Raycast(Vector2.new(0, 2), Vector2.new(4, 0))
			expect(oldPathHit).is(nil)

			local newPathHit = grid:Raycast(Vector2.new(6, 8), Vector2.new(4, 0))
			expect(newPathHit).is(nil)
		end)

		test("should raycast using final location after many cross-cell moves", function()
			local grid = createGenericGrid()
			local id = grid:InsertRect(Vector2.new(1, 1), Vector2.new(2, 2))

			grid:UpdateRect(id, Vector2.new(8, 1), Vector2.new(2, 2))
			grid:UpdateRect(id, Vector2.new(8, 8), Vector2.new(2, 2))
			grid:UpdateRect(id, Vector2.new(1, 8), Vector2.new(2, 2))
			grid:UpdateRect(id, Vector2.new(6, 6), Vector2.new(2, 2))

			local staleHorizontalHit = grid:Raycast(Vector2.new(0, 1), Vector2.new(4, 0))
			expect(staleHorizontalHit).is(nil)

			local finalPosHit = grid:Raycast(Vector2.new(4, 6), Vector2.new(4, 0))
			expect(finalPosHit).is_not(nil)
			expect(finalPosHit.EntityId).is(id)
		end)

		test("should respect include and exclude filters for moved entities", function()
			local grid = createGenericGrid()
			local includeId = grid:InsertRect(Vector2.new(1, 4), Vector2.new(2, 2))
			local excludeId = grid:InsertRect(Vector2.new(1, 4), Vector2.new(2, 2))

			grid:UpdateRect(includeId, Vector2.new(6, 4), Vector2.new(2, 2))
			grid:UpdateRect(excludeId, Vector2.new(9, 4), Vector2.new(2, 2))

			local includeHit = grid:Raycast(Vector2.new(0, 4), Vector2.new(12, 0), {
				FilterList = { excludeId },
				FilterType = Enum.RaycastFilterType.Exclude,
			})
			expect(includeHit).is_not(nil)
			expect(includeHit.EntityId).is(includeId)

			local onlyFarHit = grid:Raycast(Vector2.new(0, 4), Vector2.new(12, 0), {
				FilterList = { excludeId },
				FilterType = Enum.RaycastFilterType.Include,
			})
			expect(onlyFarHit).is_not(nil)
			expect(onlyFarHit.EntityId).is(excludeId)
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

		describe("FilterParams optional FilterList", function()
			test("should allow CustomFilter without FilterList in QueryRect", function()
				local grid = createGenericGrid()
				local id1 = grid:InsertRect(Vector2.new(5, 5), Vector2.new(2, 2))
				local id2 = grid:InsertRect(Vector2.new(8, 8), Vector2.new(2, 2))
				local entities = grid:QueryRect(Vector2.new(5, 5), Vector2.new(10, 10), {
					CustomFilter = function(entityId)
						return entityId == id1
					end,
					FilterType = Enum.RaycastFilterType.Include,
				})
				expect(entities).has_value(id1)
				expect(entities).never_has_value(id2)
			end)

			test("should allow CustomFilter without FilterList in QueryCircle", function()
				local grid = createGenericGrid()
				local id1 = grid:InsertCircle(Vector2.new(5, 5), 2)
				local id2 = grid:InsertCircle(Vector2.new(8, 8), 2)
				local entities = grid:QueryCircle(Vector2.new(5, 5), 5, {
					CustomFilter = function(entityId)
						return entityId == id1
					end,
					FilterType = Enum.RaycastFilterType.Include,
				})
				expect(entities).has_value(id1)
				expect(entities).never_has_value(id2)
			end)

			test("should allow FilterType without FilterList (defaults to Include) in Raycast", function()
				local grid = createGenericGrid()
				local id1 = grid:InsertRect(Vector2.new(5, 5), Vector2.new(2, 2))
				local _id2 = grid:InsertRect(Vector2.new(8, 5), Vector2.new(2, 2))
				local hit = grid:Raycast(Vector2.new(0, 5), Vector2.new(10, 0), {
					CustomFilter = function(entityId)
						return entityId == id1
					end,
				})
				expect(hit).is_not(nil)
				expect(hit.EntityId).is(id1)
			end)
		end)

		describe("Circle-Rectangle corner intersection", function()
			test("should detect circle just touching rectangle corner", function()
				local grid = createGenericGrid()
				-- Rectangle centered at (5, 5) with size 2x2, so corners at (4,4), (6,4), (4,6), (6,6)
				local rectId = grid:InsertRect(Vector2.new(5, 5), Vector2.new(2, 2))
				-- Circle with radius ≈ 1.414 at (3, 3) should barely touch corner at (4, 4)
				local _circleId = grid:InsertCircle(Vector2.new(3, 3), 1.415)
				local entities = grid:QueryCircle(Vector2.new(3, 3), 1.415)
				expect(entities).has_value(rectId)
			end)

			test("should not detect circle when just missing rectangle corner", function()
				local grid = createGenericGrid()
				local rectId = grid:InsertRect(Vector2.new(5, 5), Vector2.new(2, 2))
				-- Circle with radius slightly less than diagonal distance to corner should miss
				local _circleId = grid:InsertCircle(Vector2.new(3, 3), 1.413)
				local entities = grid:QueryCircle(Vector2.new(3, 3), 1.413)
				expect(entities).never_has_value(rectId)
			end)

			test("should correctly handle circle-rect corner collision at each corner", function()
				local grid = createGenericGrid()
				local rectId = grid:InsertRect(Vector2.new(5, 5), Vector2.new(2, 2))

				-- Test bottom-left corner (4, 4)
				expect(grid:QueryCircle(Vector2.new(3, 3), 1.415)).has_value(rectId)

				-- Test bottom-right corner (6, 4)
				expect(grid:QueryCircle(Vector2.new(7, 3), 1.415)).has_value(rectId)

				-- Test top-right corner (6, 6)
				expect(grid:QueryCircle(Vector2.new(7, 7), 1.415)).has_value(rectId)

				-- Test top-left corner (4, 6)
				expect(grid:QueryCircle(Vector2.new(3, 7), 1.415)).has_value(rectId)
			end)

			test("should handle very small rectangles with corner collisions", function()
				local grid = createGenericGrid()
				local rectId = grid:InsertRect(Vector2.new(5, 5), Vector2.new(0.2, 0.2))
				-- Small rect with corners at (4.9, 4.9), (5.1, 4.9), etc.
				-- Circle at (4.8, 4.8) with radius 0.15 should catch corner at (4.9, 4.9)
				local entities = grid:QueryCircle(Vector2.new(4.8, 4.8), 0.15)
				expect(entities).has_value(rectId)
			end)

			test("should handle tall rectangles (height > width) with corner intersections", function()
				local grid = createGenericGrid()
				-- Tall narrow rectangle
				local rectId = grid:InsertRect(Vector2.new(5, 5), Vector2.new(1, 4))
				-- Circle approaching from the side should detect corner collision
				local _circleId = grid:InsertCircle(Vector2.new(3, 7), 2.25)
				local entities = grid:QueryCircle(Vector2.new(3, 7), 2.25)
				expect(entities).has_value(rectId)
			end)
		end)

		describe("Non-square grid initialization", function()
			test("should correctly initialize wide rectangular grid (width > height)", function()
				local grid = LooseTightDoubleGrid.new {
					Position = Vector2.new(0, 0),
					Size = Vector2.new(10, 5),
					CellSize = 2,
				}
				expect(grid.tCols).is(10)
				expect(grid.tRows).is(5)

				-- Verify cells are positioned correctly by inserting entities
				-- in different rows to check they're in the right loose cells
				local id1 = grid:InsertRect(Vector2.new(-8, -4), Vector2.new(1, 1))
				local id2 = grid:InsertRect(Vector2.new(-8, 2), Vector2.new(1, 1))

				-- Query at first row's position should find id1, not id2
				local row1Entities = grid:QueryRect(Vector2.new(-8, -4), Vector2.new(1, 1))
				expect(row1Entities).has_value(id1)

				-- Query at second row's position should find id2, not id1
				local row2Entities = grid:QueryRect(Vector2.new(-8, 2), Vector2.new(1, 1))
				expect(row2Entities).has_value(id2)
			end)

			test("should correctly initialize tall rectangular grid (height > width)", function()
				local grid = LooseTightDoubleGrid.new {
					Position = Vector2.new(0, 0),
					Size = Vector2.new(5, 10),
					CellSize = 2,
				}
				expect(grid.tCols).is(5)
				expect(grid.tRows).is(10)

				-- Insert entities at different column positions
				local id1 = grid:InsertRect(Vector2.new(-4, 0), Vector2.new(1, 1))
				local id2 = grid:InsertRect(Vector2.new(2, 0), Vector2.new(1, 1))

				-- Query at first column's position should find id1, not id2
				local col1Entities = grid:QueryRect(Vector2.new(-4, 0), Vector2.new(1, 1))
				expect(col1Entities).has_value(id1)

				-- Query at second column's position should find id2, not id1
				local col2Entities = grid:QueryRect(Vector2.new(2, 0), Vector2.new(1, 1))
				expect(col2Entities).has_value(id2)
			end)

			test("should correctly place entities across multiple cells in non-square grid", function()
				local grid = LooseTightDoubleGrid.new {
					Position = Vector2.new(0, 0),
					Size = Vector2.new(8, 4),
					CellSize = 2,
				}

				-- Insert a large entity spanning multiple cells
				-- Rectangle at (0, 0) with size (8, 4) spans from (-4, -2) to (4, 2)
				local id = grid:InsertRect(Vector2.new(0, 0), Vector2.new(8, 4))

				-- Query various regions that overlap with the entity
				-- Query at left side should find it
				expect(grid:QueryRect(Vector2.new(-2, 0), Vector2.new(2, 2))).has_value(id)
				-- Query at center should find it
				expect(grid:QueryRect(Vector2.new(0, 0), Vector2.new(2, 2))).has_value(id)
				-- Query at right side should find it
				expect(grid:QueryRect(Vector2.new(2, 0), Vector2.new(2, 2))).has_value(id)
			end)

			test("should correctly query rectangular grid after entity updates", function()
				local grid = LooseTightDoubleGrid.new {
					Position = Vector2.new(0, 0),
					Size = Vector2.new(12, 6),
					CellSize = 2,
				}

				local id = grid:InsertRect(Vector2.new(-8, -3), Vector2.new(2, 2))

				-- Should find at original location
				local originalLocation = grid:QueryRect(Vector2.new(-8, -3), Vector2.new(3, 3))
				expect(originalLocation).has_value(id)

				-- Move to new location
				grid:UpdateRect(id, Vector2.new(6, 3), Vector2.new(2, 2))

				-- Should not find at original location
				local staleLocation = grid:QueryRect(Vector2.new(-8, -3), Vector2.new(3, 3))
				expect(staleLocation).never_has_value(id)

				-- Should find at new location
				local newLocation = grid:QueryRect(Vector2.new(6, 3), Vector2.new(3, 3))
				expect(newLocation).has_value(id)
			end)

			test("should maintain spatial coherence in very wide grid", function()
				local grid = LooseTightDoubleGrid.new {
					Position = Vector2.new(0, 0),
					Size = Vector2.new(20, 2),
					CellSize = 2,
				}

				-- Place entities at opposite ends
				local leftId = grid:InsertRect(Vector2.new(-18, 0), Vector2.new(1, 1))
				local rightId = grid:InsertRect(Vector2.new(18, 0), Vector2.new(1, 1))

				-- Left query should only find left entity
				local leftQuery = grid:QueryRect(Vector2.new(-18, 0), Vector2.new(5, 5))
				expect(leftQuery).has_value(leftId)
				expect(leftQuery).never_has_value(rightId)

				-- Right query should only find right entity
				local rightQuery = grid:QueryRect(Vector2.new(18, 0), Vector2.new(5, 5))
				expect(rightQuery).has_value(rightId)
				expect(rightQuery).never_has_value(leftId)
			end)

			test("should maintain spatial coherence in very tall grid", function()
				local grid = LooseTightDoubleGrid.new {
					Position = Vector2.new(0, 0),
					Size = Vector2.new(2, 20),
					CellSize = 2,
				}

				-- Place entities at opposite ends
				local bottomId = grid:InsertRect(Vector2.new(0, -18), Vector2.new(1, 1))
				local topId = grid:InsertRect(Vector2.new(0, 18), Vector2.new(1, 1))

				-- Bottom query should only find bottom entity
				local bottomQuery = grid:QueryRect(Vector2.new(0, -18), Vector2.new(5, 5))
				expect(bottomQuery).has_value(bottomId)
				expect(bottomQuery).never_has_value(topId)

				-- Top query should only find top entity
				local topQuery = grid:QueryRect(Vector2.new(0, 18), Vector2.new(5, 5))
				expect(topQuery).has_value(topId)
				expect(topQuery).never_has_value(bottomId)
			end)
		end)
	end)

	describe("GetEntity Methods", function()
		test("should return the correct position of an entity", function()
			local grid = createGenericGrid()
			local id = grid:InsertRect(Vector2.new(5, 5), Vector2.new(2, 2))
			local position = grid:GetEntityPosition(id)
			checkVectorsEqual(position, Vector2.new(5, 5))
		end)

		test("should return the correct size of an entity", function()
			local grid = createGenericGrid()
			local id = grid:InsertRect(Vector2.new(5, 5), Vector2.new(2, 2))
			local size = grid:GetEntitySize(id)
			checkVectorsEqual(size, Vector2.new(2, 2))
		end)

		test("should return the correct position and size of an entity", function()
			local grid = createGenericGrid()
			local id = grid:InsertRect(Vector2.new(5, 5), Vector2.new(2, 2))
			local position, size = grid:GetEntityPositionAndSize(id)
			checkVectorsEqual(position, Vector2.new(5, 5))
			checkVectorsEqual(size, Vector2.new(2, 2))
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

	describe("Performance Benchmarks", function()
		local PERF_ENTITY_COUNT = 15000
		local PERF_QUERY_COUNT = 3000
		local PERF_UPDATE_COUNT = 7000
		local PERF_RAYCAST_COUNT = 3000

		if DO_BENCHMARKS == false then
			return
		end

		-- Paste comparison results directly under each benchmark:
		-- BEFORE: total avg=___ms | median=___ms | trim5%=___ms | perOp avg=___us | median=___us | trim5%=___us
		-- AFTER:  total avg=___ms | median=___ms | trim5%=___ms | perOp avg=___us | median=___us | trim5%=___us

		test("benchmark Insert mixed entities", function()
			local grid = createPerfGrid()
			local rng = createDeterministicRng(101)

			local report = runPerfBenchmark("InsertMixed", PERF_ENTITY_COUNT, function(i)
				local pos = Vector2.new(rng.nextNumber(-300, 300), rng.nextNumber(-300, 300))
				if i % 3 == 1 then
					return grid:InsertRect(pos, Vector2.new(rng.nextNumber(1, 8), rng.nextNumber(1, 8)))
				elseif i % 3 == 2 then
					return grid:InsertCircle(pos, rng.nextNumber(0.5, 4))
				else
					return grid:InsertPoint(pos)
				end
			end)

			expect(report.totalMsStats.average > 0).is(true)
			expect(report.totalMsStats.median > 0).is(true)
			expect(report.totalMsStats.trimmedAverage > 0).is(true)
			expect(report.perOpUsStats.average > 0).is(true)
			expect(report.perOpUsStats.median > 0).is(true)
			expect(report.perOpUsStats.trimmedAverage > 0).is(true)
		end)

		test("benchmark Update mixed entities", function()
			local grid = createPerfGrid()
			local ids = populateMixedEntities(grid, PERF_ENTITY_COUNT, 202)
			local rng = createDeterministicRng(203)

			local report = runPerfBenchmark("UpdateMixed", PERF_UPDATE_COUNT, function(i)
				local id = ids[((i - 1) % #ids) + 1]
				local pos = Vector2.new(rng.nextNumber(-300, 300), rng.nextNumber(-300, 300))
				local mode = i % 3
				if mode == 1 then
					grid:UpdateRect(id, pos, Vector2.new(rng.nextNumber(1, 8), rng.nextNumber(1, 8)))
				elseif mode == 2 then
					grid:UpdateCircle(id, pos, rng.nextNumber(0.5, 4))
				else
					grid:UpdatePoint(id, pos)
				end
				return id
			end)

			expect(report.totalMsStats.average > 0).is(true)
			expect(report.totalMsStats.median > 0).is(true)
			expect(report.totalMsStats.trimmedAverage > 0).is(true)
			expect(report.perOpUsStats.average > 0).is(true)
			expect(report.perOpUsStats.median > 0).is(true)
			expect(report.perOpUsStats.trimmedAverage > 0).is(true)
		end)

		test("benchmark Remove entities", function()
			local grid = createPerfGrid()
			local ids = populateMixedEntities(grid, PERF_ENTITY_COUNT, 303)

			local report = runPerfBenchmark("RemoveEntities", #ids, function(i)
				local id = ids[i]
				if grid:Remove(id) then
					return 1
				end
				return 0
			end)

			expect(report.checksum).is(#ids)
			expect(report.totalMsStats.average > 0).is(true)
			expect(report.totalMsStats.median > 0).is(true)
			expect(report.totalMsStats.trimmedAverage > 0).is(true)
			expect(report.perOpUsStats.average > 0).is(true)
			expect(report.perOpUsStats.median > 0).is(true)
			expect(report.perOpUsStats.trimmedAverage > 0).is(true)
		end)

		test("benchmark QueryRect", function()
			local grid = createPerfGrid()
			populateMixedEntities(grid, PERF_ENTITY_COUNT, 404)
			local rng = createDeterministicRng(405)

			local report = runPerfBenchmark("QueryRect", PERF_QUERY_COUNT, function()
				local pos = Vector2.new(rng.nextNumber(-250, 250), rng.nextNumber(-250, 250))
				local size = Vector2.new(rng.nextNumber(6, 30), rng.nextNumber(6, 30))
				return #grid:QueryRect(pos, size)
			end)

			expect(report.totalMsStats.average > 0).is(true)
			expect(report.totalMsStats.median > 0).is(true)
			expect(report.totalMsStats.trimmedAverage > 0).is(true)
			expect(report.perOpUsStats.average > 0).is(true)
			expect(report.perOpUsStats.median > 0).is(true)
			expect(report.perOpUsStats.trimmedAverage > 0).is(true)
		end)

		test("benchmark QueryCircle", function()
			local grid = createPerfGrid()
			populateMixedEntities(grid, PERF_ENTITY_COUNT, 505)
			local rng = createDeterministicRng(506)

			local report = runPerfBenchmark("QueryCircle", PERF_QUERY_COUNT, function()
				local pos = Vector2.new(rng.nextNumber(-250, 250), rng.nextNumber(-250, 250))
				return #grid:QueryCircle(pos, rng.nextNumber(4, 18))
			end)

			expect(report.totalMsStats.average > 0).is(true)
			expect(report.totalMsStats.median > 0).is(true)
			expect(report.totalMsStats.trimmedAverage > 0).is(true)
			expect(report.perOpUsStats.average > 0).is(true)
			expect(report.perOpUsStats.median > 0).is(true)
			expect(report.perOpUsStats.trimmedAverage > 0).is(true)
		end)

		test("benchmark QueryPoint", function()
			local grid = createPerfGrid()
			populateMixedEntities(grid, PERF_ENTITY_COUNT, 606)
			local rng = createDeterministicRng(607)

			local report = runPerfBenchmark("QueryPoint", PERF_QUERY_COUNT, function()
				local pos = Vector2.new(rng.nextNumber(-250, 250), rng.nextNumber(-250, 250))
				return #grid:QueryPoint(pos)
			end)

			expect(report.totalMsStats.average > 0).is(true)
			expect(report.totalMsStats.median > 0).is(true)
			expect(report.totalMsStats.trimmedAverage > 0).is(true)
			expect(report.perOpUsStats.average > 0).is(true)
			expect(report.perOpUsStats.median > 0).is(true)
			expect(report.perOpUsStats.trimmedAverage > 0).is(true)
		end)

		test("benchmark QueryClosestToPoint", function()
			local grid = createPerfGrid()
			populateMixedEntities(grid, PERF_ENTITY_COUNT, 707)
			local rng = createDeterministicRng(708)

			local report = runPerfBenchmark("QueryClosestToPoint", PERF_QUERY_COUNT, function()
				local pos = Vector2.new(rng.nextNumber(-250, 250), rng.nextNumber(-250, 250))
				local id = grid:QueryClosestToPoint(pos)
				return id or 0
			end)

			expect(report.totalMsStats.average > 0).is(true)
			expect(report.totalMsStats.median > 0).is(true)
			expect(report.totalMsStats.trimmedAverage > 0).is(true)
			expect(report.perOpUsStats.average > 0).is(true)
			expect(report.perOpUsStats.median > 0).is(true)
			expect(report.perOpUsStats.trimmedAverage > 0).is(true)
		end)

		test("benchmark Raycast", function()
			local grid = createPerfGrid()
			populateMixedEntities(grid, PERF_ENTITY_COUNT, 808)
			local rng = createDeterministicRng(809)

			local report = runPerfBenchmark("Raycast", PERF_RAYCAST_COUNT, function()
				local origin = Vector2.new(rng.nextNumber(-250, 250), rng.nextNumber(-250, 250))
				local direction = Vector2.new(rng.nextNumber(-80, 80), rng.nextNumber(-80, 80))
				local hit = grid:Raycast(origin, direction)
				return hit and hit.EntityId or 0
			end)

			expect(report.totalMsStats.average > 0).is(true)
			expect(report.totalMsStats.median > 0).is(true)
			expect(report.totalMsStats.trimmedAverage > 0).is(true)
			expect(report.perOpUsStats.average > 0).is(true)
			expect(report.perOpUsStats.median > 0).is(true)
			expect(report.perOpUsStats.trimmedAverage > 0).is(true)
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

	describe("Filtering", function()
		test("should filter entities using FilterList with Include", function()
			local grid = createGenericGrid()
			local id1 = grid:InsertRect(Vector2.new(5, 5), Vector2.new(2, 2))
			local id2 = grid:InsertRect(Vector2.new(8, 8), Vector2.new(2, 2))
			local entities = grid:QueryRect(Vector2.new(5, 5), Vector2.new(10, 10), {
				FilterList = { id1 },
				FilterType = Enum.RaycastFilterType.Include,
			})
			expect(entities).has_value(id1)
			expect(entities).never_has_value(id2)
		end)

		test("should filter entities using FilterList with Exclude", function()
			local grid = createGenericGrid()
			local id1 = grid:InsertRect(Vector2.new(5, 5), Vector2.new(2, 2))
			local id2 = grid:InsertRect(Vector2.new(8, 8), Vector2.new(2, 2))
			local entities = grid:QueryRect(Vector2.new(5, 5), Vector2.new(10, 10), {
				FilterList = { id1 },
				FilterType = Enum.RaycastFilterType.Exclude,
			})
			expect(entities).never_has_value(id1)
			expect(entities).has_value(id2)
		end)

		test("should filter entities using a custom filter function", function()
			local grid = createGenericGrid()
			local id1 = grid:InsertRect(Vector2.new(5, 5), Vector2.new(2, 2))
			local id2 = grid:InsertRect(Vector2.new(8, 8), Vector2.new(2, 2))
			local entities = grid:QueryRect(Vector2.new(5, 5), Vector2.new(10, 10), {
				CustomFilter = function(entityId)
					return entityId == id2
				end,
			})
			expect(entities).never_has_value(id1)
			expect(entities).has_value(id2)
		end)
	end)

	describe("__iter Metamethod", function()
		test("should iterate over all entities in the grid", function()
			local grid = createGenericGrid()
			local id1 = grid:InsertRect(Vector2.new(5, 5), Vector2.new(2, 2))
			local id2 = grid:InsertCircle(Vector2.new(8, 8), 2)
			local id3 = grid:InsertPoint(Vector2.new(10, 10))

			local iteratedEntities = {}
			for entityId, shapeType in grid do
				iteratedEntities[entityId] = shapeType
			end

			expect(iteratedEntities[id1]).is("r")
			expect(iteratedEntities[id2]).is("c")
			expect(iteratedEntities[id3]).is("p")
		end)
	end)

	-- createGenericGrid(): Position=(0,0), Size=(10,10), CellSize=2
	-- World span x∈[-10,10], y∈[-10,10]; each tight cell is 2×2 world units.
	-- Column/row boundaries at every even integer:
	--   Col 4: x∈[-4,-2)  Col 5: x∈[-2,0)  Col 6: x∈[0,2)  Col 7: x∈[2,4)
	--   Row 4: y∈[-4,-2)  Row 5: y∈[-2,0)  Row 6: y∈[0,2)  Row 7: y∈[2,4)
	-- A LooseCell is assigned by entity centre; its AABB can extend into neighbouring
	-- tight cells. UpdateExtents must INSERT the loose cell into those neighbours so
	-- queries that cross into them can reach the entity.
	describe("TightCell registration", function()
		test("entity is findable via the left neighbouring tight cells after initial insert", function()
			local grid = createGenericGrid()
			-- Centre (0,0) → LooseCell col 6.  AABB {-1,-1, 1,1} extends left into col 5.
			-- UpdateExtents must INSERT (not remove) the loose cell into col-5 tight cells.
			local id = grid:InsertRect(Vector2.new(0, 0), Vector2.new(2, 2))
			-- Query confined to col 5, row 6 – does not touch the entity's home col-6 tight cells.
			local entities = grid:QueryRect(Vector2.new(-1, 1), Vector2.new(1, 1))
			expect(entities).has_value(id)
		end)

		test("entity is findable via the right neighbouring tight cells after initial insert", function()
			local grid = createGenericGrid()
			-- Centre (1.5,0) → LooseCell col 6.  AABB {0.5,-1, 2.5,1} extends right into col 7.
			-- UpdateExtents must INSERT the loose cell into col-7 tight cells.
			local id = grid:InsertRect(Vector2.new(1.5, 0), Vector2.new(2, 2))
			-- Query confined to col 7, rows 5–6 – does not touch the entity's home col-6 tight cells.
			local entities = grid:QueryRect(Vector2.new(2.5, 0), Vector2.new(0.5, 1))
			expect(entities).has_value(id)
		end)

		test("entity is findable in newly covered tight cells after AABB expands left and right via update", function()
			local grid = createGenericGrid()
			-- Initial insert: AABB {-1,-1, 1,1} → LooseCell covers cols 5–6.
			local id = grid:InsertRect(Vector2.new(0, 0), Vector2.new(2, 2))
			-- Grow: AABB {-3,-1, 3,1} → expands into col 4 (left) and col 7 (right).
			grid:UpdateRect(id, Vector2.new(0, 0), Vector2.new(6, 2))
			-- Newly added left column (col 4, x∈[-4,-2)).
			local left = grid:QueryRect(Vector2.new(-3, 0), Vector2.new(1, 2))
			expect(left).has_value(id)
			-- Newly added right column (col 7, x∈[2,4)).
			local right = grid:QueryRect(Vector2.new(2.5, 0), Vector2.new(0.5, 2))
			expect(right).has_value(id)
		end)

		test("entity is findable in newly covered tight cells after AABB expands top and bottom via update", function()
			local grid = createGenericGrid()
			-- Initial insert: AABB {-1,-1, 1,1} → LooseCell covers rows 5–6.
			local id = grid:InsertRect(Vector2.new(0, 0), Vector2.new(2, 2))
			-- Grow: AABB {-1,-3, 1,3} → expands into row 7 (top) and row 4 (bottom).
			grid:UpdateRect(id, Vector2.new(0, 0), Vector2.new(2, 6))
			-- Newly added top row (row 7, y∈[2,4)).
			local top = grid:QueryRect(Vector2.new(0.5, 2.5), Vector2.new(1, 1))
			expect(top).has_value(id)
			-- Newly added bottom row (row 4, y∈[-4,-2)).
			local bottom = grid:QueryRect(Vector2.new(0.5, -3), Vector2.new(1, 1))
			expect(bottom).has_value(id)
		end)
	end)
end

return test_suite

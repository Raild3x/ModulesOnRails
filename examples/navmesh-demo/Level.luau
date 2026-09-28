--!strict
-- The demo level as a NavMesh description, plus the gameplay constants the NPC code needs.
-- Shared by the Lune sim, the bake script and the Studio place (plain data, `vector` only).
--
--   z
--   40 +--------------------+=====ramp=====+====== balcony (y 6) =========+
--      |                    |  (x 20..32)  |          | wall |  v jump   |
--      |  north yard        +--------------+          |      |  (48,31)  |
--      |                                              | door |  east     |
--   25 |~~~~~~~ mud (area 2) ~~~~~~~~~~~~|            |  z   |  room     |
--   15 |~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~|            | 18-22|           |
--      |   [c]  [c]  <- 2-stud gap                    |      |           |
--    0 +----------------------------------------------+------+-----------+
--      x 0                                             40    41          60

-- A ring from flat {x, z, ...} pairs at height y.
local function flat(y: number, xz: { number }): { vector }
	local ring = {}
	for i = 1, #xz, 2 do
		table.insert(ring, vector.create(xz[i], y, xz[i + 1]))
	end
	return ring
end

-- An axis-aligned box footprint.
local function rect(y: number, x0: number, z0: number, x1: number, z1: number): { vector }
	return flat(y, { x0, z0, x1, z0, x1, z1, x0, z1 })
end

local Level = {}

Level.MUD = 2
Level.DOOR = rect(0, 40, 18, 41, 22) -- footprint of the door leaf when closed
Level.JUMP_LABEL = "Jump"

Level.Desc = {
	MaxAgentRadius = 2,
	Floors = {
		Ground = {
			Walkable = { rect(0, 0, 0, 60, 40) },
			Obstacles = {
				rect(0, 10, 6, 14, 10), -- crate pair with a 2-stud gap between them:
				rect(0, 10, 12, 14, 16), -- small NPCs fit, big ones do not
				rect(0, 24, 4, 28, 8), -- lone crate
				rect(0, 50, 8, 54, 12), -- crate in the east room
				rect(0, 40, 0, 41, 18), -- east wall, south of the door
				rect(0, 40, 22, 41, 40), -- east wall, north of the door
				rect(0, 20, 34, 32, 40), -- the ramp's footprint (solid underneath)
			},
			Areas = { { Polygon = rect(0, 0, 18, 30, 26), Area = Level.MUD } },
		},
		-- Rises from y 0 at x 20 to y 6 at x 32.
		Ramp = {
			Walkable = {
				{
					vector.create(20, 0, 34),
					vector.create(32, 6, 34),
					vector.create(32, 6, 40),
					vector.create(20, 0, 40),
				},
			},
		},
		-- Runs east over the wall; the east end drops into the east room.
		Balcony = { Walkable = { rect(6, 32, 34, 52, 40) } },
	},
	Seams = {
		{ FloorA = "Ground", FloorB = "Ramp", From = vector.create(20, 0, 34), To = vector.create(20, 0, 40) },
		{ FloorA = "Ramp", FloorB = "Balcony", From = vector.create(32, 6, 34), To = vector.create(32, 6, 40) },
	},
	Links = {
		-- One-way drop from the balcony into the east room.
		{
			From = vector.create(50, 6, 35.5),
			To = vector.create(50, 0, 31),
			Bidirectional = false,
			Label = Level.JUMP_LABEL,
		},
	},
}

return Level

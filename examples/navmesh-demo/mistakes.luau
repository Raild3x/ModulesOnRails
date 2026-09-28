--!strict
-- Authoring and query mistakes made on purpose, printing the error each one raises (or what
-- happens instead when nothing is raised). Run: lune run examples/navmesh-demo/mistakes.luau
local NavMesh = require("../../lib/navmesh/src/NavMesh")

local function v(x: number, y: number, z: number): any
	return vector.create(x, y, z)
end
local function rect(y: number, x0: number, z0: number, x1: number, z1: number): { any }
	return { v(x0, y, z0), v(x1, y, z0), v(x1, y, z1), v(x0, y, z1) }
end
local function floorOf(ring: { any }): any
	return { Floors = { Ground = { Walkable = { ring } } } }
end
local base = rect(0, 0, 0, 20, 20)

local cases: { { any } } = {
	{
		"bow-tie walkable ring",
		function()
			return NavMesh.Build(floorOf { v(0, 0, 0), v(10, 0, 10), v(10, 0, 0), v(0, 0, 10) })
		end,
	},
	{
		"two-point ring",
		function()
			return NavMesh.Build(floorOf { v(0, 0, 0), v(10, 0, 0) })
		end,
	},
	{
		"ring closed by repeating the first point",
		function()
			return NavMesh.Build(floorOf { v(0, 0, 0), v(10, 0, 0), v(10, 0, 10), v(0, 0, 10), v(0, 0, 0) })
		end,
	},
	{
		"Walkable given a ring instead of a list of rings",
		function()
			return NavMesh.Build { Floors = { Ground = { Walkable = base :: any } } }
		end,
	},
	{
		"Floors given as an array instead of a name map",
		function()
			return NavMesh.Build { Floors = { { Walkable = { base } } } :: any }
		end,
	},
	{
		"overlapping walkable rings at different heights",
		function()
			return NavMesh.Build { Floors = { Ground = { Walkable = { base, rect(3, 10, 10, 30, 30) } } } }
		end,
	},
	{
		"Vector3-like table instead of a vector",
		function()
			return NavMesh.Build(floorOf { { X = 0, Y = 0, Z = 0 }, v(10, 0, 0), v(10, 0, 10) } :: any)
		end,
	},
	{
		"coordinate out of range",
		function()
			return NavMesh.Build(floorOf(rect(0, 0, 0, 40000, 10)))
		end,
	},
	{
		"obstacle entirely outside the floor",
		function()
			local mesh =
				NavMesh.Build { Floors = { Ground = { Walkable = { base }, Obstacles = { rect(0, 50, 50, 60, 60) } } } }
			return `built fine: {NavMesh.FindPath(mesh, v(1, 0, 1), v(19, 0, 19)).Status}`
		end,
	},
	{
		"obstacle covering the whole floor",
		function()
			local mesh =
				NavMesh.Build { Floors = { Ground = { Walkable = { base }, Obstacles = { rect(0, -1, -1, 21, 21) } } } }
			return `built fine: {NavMesh.FindPath(mesh, v(1, 0, 1), v(19, 0, 19)).Status}`
		end,
	},
	{
		"seam not on the floor edges",
		function()
			return NavMesh.Build {
				Floors = { A = { Walkable = { base } }, B = { Walkable = { rect(5, 20, 0, 40, 20) } } },
				Seams = { { FloorA = "A", FloorB = "B", From = v(10, 0, 0), To = v(10, 0, 10) } },
			}
		end,
	},
	{
		"seam naming a missing floor",
		function()
			return NavMesh.Build {
				Floors = { A = { Walkable = { base } } },
				Seams = { { FloorA = "A", FloorB = "Nope", From = v(20, 0, 0), To = v(20, 0, 10) } },
			}
		end,
	},
	{
		"seam between floors whose heights disagree along it",
		function()
			return NavMesh.Build {
				Floors = { A = { Walkable = { base } }, B = { Walkable = { rect(5, 20, 0, 40, 20) } } },
				Seams = { { FloorA = "A", FloorB = "B", From = v(20, 0, 0), To = v(20, 0, 20) } },
			}
		end,
	},
	{
		"link end nowhere near a floor",
		function()
			return NavMesh.Build {
				Floors = { Ground = { Walkable = { base } } },
				Links = { { From = v(5, 0, 5), To = v(100, 0, 100) } },
			}
		end,
	},
	{
		"link end 3 studs above the floor (inside default SnapExtents Y=4?)",
		function()
			local mesh = NavMesh.Build {
				Floors = { Ground = { Walkable = { base } } },
				Links = { { From = v(5, 3, 5), To = v(15, 0, 15), Label = "X" } },
			}
			return "built fine"
		end,
	},
	{
		"area id 0",
		function()
			return NavMesh.Build {
				Floors = { Ground = { Walkable = { base }, Areas = { { Polygon = rect(0, 1, 1, 5, 5), Area = 0 } } } },
			}
		end,
	},
	{
		"area id 1.5",
		function()
			return NavMesh.Build {
				Floors = { Ground = { Walkable = { base }, Areas = { { Polygon = rect(0, 1, 1, 5, 5), Area = 1.5 } } } },
			}
		end,
	},
	{
		"TileSize 0",
		function()
			return NavMesh.Build { TileSize = 0, Floors = { Ground = { Walkable = { base } } } }
		end,
	},
	{
		"AgentRadius above MaxAgentRadius",
		function()
			local mesh = NavMesh.Build { MaxAgentRadius = 1, Floors = { Ground = { Walkable = { base } } } }
			return NavMesh.FindPath(mesh, v(1, 0, 1), v(19, 0, 19), { AgentRadius = 2 })
		end,
	},
	{
		"AreaCosts negative",
		function()
			local mesh = NavMesh.Build(floorOf(base))
			return NavMesh.FindPath(mesh, v(1, 0, 1), v(19, 0, 19), { AreaCosts = { [1] = -1 } })
		end,
	},
	{
		"misspelled filter field (AgentRaduis)",
		function()
			local mesh = NavMesh.Build(floorOf(base))
			local p = NavMesh.FindPath(mesh, v(1, 0, 1), v(19, 0, 19), { AgentRaduis = 5 } :: any)
			return `no error: Status {p.Status}`
		end,
	},
	{
		"AddObstacle on a missing floor",
		function()
			local mesh = NavMesh.Build(floorOf(base))
			return NavMesh.AddObstacle(mesh, "Groud", rect(0, 5, 5, 8, 8))
		end,
	},
	{
		"AddObstacle with a bow-tie",
		function()
			local mesh = NavMesh.Build(floorOf(base))
			return NavMesh.AddObstacle(mesh, "Ground", { v(0, 0, 0), v(10, 0, 10), v(10, 0, 0), v(0, 0, 10) })
		end,
	},
	{
		"RemoveObstacle twice",
		function()
			local mesh = NavMesh.Build(floorOf(base))
			local id = NavMesh.AddObstacle(mesh, "Ground", rect(0, 5, 5, 8, 8))
			NavMesh.RemoveObstacle(mesh, id)
			NavMesh.RemoveObstacle(mesh, id)
			return "no error"
		end,
	},
	{
		"RemoveObstacle of an unknown id",
		function()
			local mesh = NavMesh.Build(floorOf(base))
			NavMesh.RemoveObstacle(mesh, 42)
			return "no error"
		end,
	},
	{
		"forgetting Update after AddObstacle",
		function()
			local mesh = NavMesh.Build(floorOf(base))
			NavMesh.AddObstacle(mesh, "Ground", rect(0, 0, 9, 20, 11))
			return `path still {NavMesh.FindPath(mesh, v(1, 0, 1), v(1, 0, 19)).Status} straight through the wall`
		end,
	},
	{
		"MoveAlongSurface from off the mesh",
		function()
			local mesh = NavMesh.Build(floorOf(base))
			return NavMesh.MoveAlongSurface(mesh, v(-5, 0, -5), v(5, 0, 5))
		end,
	},
	{
		"FindPath from 5 studs above the floor (a jumping NPC)",
		function()
			local mesh = NavMesh.Build(floorOf(base))
			return NavMesh.FindPath(mesh, v(5, 5, 5), v(15, 0, 15)).Status
		end,
	},
	{
		"FindPath from HumanoidRootPart height (3 studs up)",
		function()
			local mesh = NavMesh.Build(floorOf(base))
			return NavMesh.FindPath(mesh, v(5, 3, 5), v(15, 0, 15)).Status
		end,
	},
	{
		"MaxExpansions 3 on the demo level (a Budget, not a mistake)",
		function()
			local mesh = NavMesh.Build(require("./Level").Desc)
			local p = NavMesh.FindPath(mesh, v(5, 0, 5), v(55, 0, 30), { MaxExpansions = 3 })
			local last = p.Waypoints[#p.Waypoints].Position
			return `{p.Status}, {#p.Waypoints} waypoints ending at ({last.X}, {last.Y}, {last.Z})`
		end,
	},
	{
		"SetLinkEnabled with no links",
		function()
			local mesh = NavMesh.Build(floorOf(base))
			NavMesh.SetLinkEnabled(mesh, 1, false)
			return "no error"
		end,
	},
	{
		"Deserialize garbage",
		function()
			return NavMesh.Deserialize(buffer.fromstring("hello world, not a mesh"))
		end,
	},
	{
		"Deserialize a truncated bake",
		function()
			local data = NavMesh.Serialize(NavMesh.Build(floorOf(base)))
			local cut = buffer.create(buffer.len(data) - 5)
			buffer.copy(cut, 0, data, 0, buffer.len(cut))
			return NavMesh.Deserialize(cut)
		end,
	},
}

for _, case in cases do
	local ok, result = pcall(case[2])
	local shown = if type(result) == "table" then `table (Status {result.Status or "?"})` else tostring(result)
	print(`[{if ok then "ok " else "ERR"}] {case[1]}\n      -> {shown}`)
end

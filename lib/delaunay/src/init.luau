--!strict
-- Authors: Logan Hunt (Raildex)
--[=[
    @class Delaunay

    A library for computing Delaunay triangulations in 2D and 3D.

    Main entry point file.  See [Delaunay2d](/api/Delaunay2d) and [Delaunay3d](/api/Delaunay3d) for documentation of the individual algorithms.
]=]

local Delaunay2d = require(script["2d"].Delaunay2d)
-- export type Delaunay2d = Delaunay2d.Delaunay2d

local Delaunay2dConstrained = nil -- Not implemented yet
-- export type Delaunay2dConstrained = Delaunay2dConstrained.Delaunay2dConstrained

local Delaunay3d = require(script["3d"].Delaunay3d)
export type Delaunay3d = Delaunay3d.Delaunay3dObject

return {
	Delaunay2d = Delaunay2d,
	Delaunay2dConstrained = Delaunay2dConstrained,
	Delaunay3d = Delaunay3d,
}

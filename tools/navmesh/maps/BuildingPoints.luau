--!strict
-- Named points in the building (Building.luau), shared by its maps.
return function(rbx: any): { [string]: Vector3 }
	local V3 = rbx.Vector3
	return {
		Street = V3.new(30, 0, -12), -- outside the doorway
		Lobby = V3.new(30, 0, 15),
		Upstairs = V3.new(20, 12, 30),
		Landing = V3.new(46.5, 6, 28),
		NarrowFoot = V3.new(2, 0, 8), -- west of the narrow stair's foot, clear of the corner
		NarrowHead = V3.new(24, 12, 2.5),
	}
end

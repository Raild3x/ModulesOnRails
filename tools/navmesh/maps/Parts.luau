--!strict
-- Part makers for maps: anchored, coloured, parented if a parent is given. `rbx` is Lune's
-- `@lune/roblox` or Studio's globals, so the same map builds in both.

type Rbx = { Instance: any, Vector3: any, CFrame: any, Color3: any, Enum: any }

return function(rbx: Rbx, parent: Instance?)
	local V3, CF = rbx.Vector3, rbx.CFrame
	local P = {}

	function P.part(class: string, name: string, size: Vector3, cframe: CFrame, rgb: { number }): BasePart
		local p = rbx.Instance.new(class)
		p.Name = name
		p.Anchored = true
		p.Size = size
		p.CFrame = cframe
		p.Color = rbx.Color3.fromRGB(rgb[1], rgb[2], rgb[3])
		p.Parent = parent
		return p
	end

	-- A block standing on y = y0 over x0..x1, z0..z1, h tall.
	function P.box(name: string, x0: number, z0: number, x1: number, z1: number, y0: number, h: number, rgb: { number })
		return P.part("Part", name, V3.new(x1 - x0, h, z1 - z0), CF.new((x0 + x1) / 2, y0 + h / 2, (z0 + z1) / 2), rgb)
	end

	-- A 1-stud slab whose top is at y.
	function P.slab(name: string, x0: number, z0: number, x1: number, z1: number, y: number, rgb: { number })
		return P.box(name, x0, z0, x1, z1, y - 1, 1, rgb)
	end

	return P
end

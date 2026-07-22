-- This file is just here so I can test the Vector3 type in Lune. It's ignored in actual Roblox Code.

if Vector3 then
	return Vector3
end

local Vector3 = {}
Vector3.__index = function(self, key)
	if key == "Magnitude" then
		return math.sqrt(self.X * self.X + self.Y * self.Y + self.Z * self.Z)
	elseif key == "Unit" then
		local mag = math.sqrt(self.X * self.X + self.Y * self.Y + self.Z * self.Z)
		if mag > 0 then
			return Vector3.new(self.X / mag, self.Y / mag, self.Z / mag)
		else
			return Vector3.new(0, 0, 0)
		end
	end
	return rawget(Vector3, key)
end

function Vector3.new(x: number?, y: number?, z: number?)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, Vector3)
end

function Vector3.fromAxis(normalId)
	-- normalId is a Roblox Enum.NormalId; accepts string names as a fallback
	local axes = {
		Right = Vector3.new(1, 0, 0),
		Top = Vector3.new(0, 1, 0),
		Back = Vector3.new(0, 0, 1),
		Left = Vector3.new(-1, 0, 0),
		Bottom = Vector3.new(0, -1, 0),
		Front = Vector3.new(0, 0, -1),
	}
	local name = tostring(normalId):match("%.(%w+)$") or tostring(normalId)
	return axes[name] or Vector3.new(0, 0, 0)
end

function Vector3.fromNormalId(normalId)
	return Vector3.fromAxis(normalId)
end

function Vector3:__tostring()
	return string.format("%g, %g, %g", self.X, self.Y, self.Z)
end

function Vector3:__add(other)
	return Vector3.new(self.X + other.X, self.Y + other.Y, self.Z + other.Z)
end

function Vector3:__sub(other)
	return Vector3.new(self.X - other.X, self.Y - other.Y, self.Z - other.Z)
end

function Vector3:__mul(other)
	if type(other) == "number" then
		return Vector3.new(self.X * other, self.Y * other, self.Z * other)
	else
		return Vector3.new(self.X * other.X, self.Y * other.Y, self.Z * other.Z)
	end
end

function Vector3:__div(other)
	if type(other) == "number" then
		return Vector3.new(self.X / other, self.Y / other, self.Z / other)
	else
		return Vector3.new(self.X / other.X, self.Y / other.Y, self.Z / other.Z)
	end
end

function Vector3:__unm()
	return Vector3.new(-self.X, -self.Y, -self.Z)
end

function Vector3:__eq(other)
	return self.X == other.X and self.Y == other.Y and self.Z == other.Z
end

function Vector3:Dot(other)
	return self.X * other.X + self.Y * other.Y + self.Z * other.Z
end

function Vector3:Cross(other)
	return Vector3.new(
		self.Y * other.Z - self.Z * other.Y,
		self.Z * other.X - self.X * other.Z,
		self.X * other.Y - self.Y * other.X
	)
end

function Vector3:Lerp(other, t: number)
	return Vector3.new(
		self.X + (other.X - self.X) * t,
		self.Y + (other.Y - self.Y) * t,
		self.Z + (other.Z - self.Z) * t
	)
end

function Vector3:Angle(other, axis)
	local dot = math.clamp(self.Unit:Dot(other.Unit), -1, 1)
	local angle = math.acos(dot)
	if axis then
		local cross = self:Cross(other)
		if cross:Dot(axis) < 0 then
			angle = -angle
		end
	end
	return angle
end

function Vector3:FuzzyEq(other, epsilon: number?)
	local e = epsilon or 1e-5
	return math.abs(self.X - other.X) <= e and math.abs(self.Y - other.Y) <= e and math.abs(self.Z - other.Z) <= e
end

function Vector3:Min(other)
	return Vector3.new(math.min(self.X, other.X), math.min(self.Y, other.Y), math.min(self.Z, other.Z))
end

function Vector3:Max(other)
	return Vector3.new(math.max(self.X, other.X), math.max(self.Y, other.Y), math.max(self.Z, other.Z))
end

function Vector3:Floor()
	return Vector3.new(math.floor(self.X), math.floor(self.Y), math.floor(self.Z))
end

function Vector3:Ceil()
	return Vector3.new(math.ceil(self.X), math.ceil(self.Y), math.ceil(self.Z))
end

function Vector3:Abs()
	return Vector3.new(math.abs(self.X), math.abs(self.Y), math.abs(self.Z))
end

function Vector3:Sign()
	local function sign(n)
		if n > 0 then
			return 1
		elseif n < 0 then
			return -1
		else
			return 0
		end
	end
	return Vector3.new(sign(self.X), sign(self.Y), sign(self.Z))
end

Vector3.zero = Vector3.new(0, 0, 0)
Vector3.one = Vector3.new(1, 1, 1)
Vector3.xAxis = Vector3.new(1, 0, 0)
Vector3.yAxis = Vector3.new(0, 1, 0)
Vector3.zAxis = Vector3.new(0, 0, 1)

return Vector3 :: Vector3

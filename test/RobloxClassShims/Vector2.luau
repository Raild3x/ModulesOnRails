-- This file is just here so I can test the Vector2 type in Lune. It's ignored in actual Roblox Code.

if Vector2 then
	return Vector2
end

local Vector2 = {}
Vector2.__index = function(self, key)
	if key == "Magnitude" then
		return math.sqrt(self.X * self.X + self.Y * self.Y)
	elseif key == "Unit" then
		local mag = math.sqrt(self.X * self.X + self.Y * self.Y)
		if mag > 0 then
			return Vector2.new(self.X / mag, self.Y / mag)
		else
			return Vector2.new(0, 0)
		end
	end
	return rawget(Vector2, key)
end

function Vector2.new(x: number?, y: number?)
	return setmetatable({ X = x or 0, Y = y or 0 }, Vector2)
end

function Vector2:__tostring()
	return string.format("%g, %g", self.X, self.Y)
end

function Vector2:__add(other)
	return Vector2.new(self.X + other.X, self.Y + other.Y)
end

function Vector2:__sub(other)
	return Vector2.new(self.X - other.X, self.Y - other.Y)
end

function Vector2:__mul(other)
	if type(other) == "number" then
		return Vector2.new(self.X * other, self.Y * other)
	else
		return Vector2.new(self.X * other.X, self.Y * other.Y)
	end
end

function Vector2:__div(other)
	if type(other) == "number" then
		return Vector2.new(self.X / other, self.Y / other)
	else
		return Vector2.new(self.X / other.X, self.Y / other.Y)
	end
end

function Vector2:__unm()
	return Vector2.new(-self.X, -self.Y)
end

function Vector2:__eq(other)
	return self.X == other.X and self.Y == other.Y
end

function Vector2:Dot(other)
	return self.X * other.X + self.Y * other.Y
end

function Vector2:Cross(other)
	return self.X * other.Y - self.Y * other.X
end

function Vector2:Lerp(other, t: number)
	return Vector2.new(self.X + (other.X - self.X) * t, self.Y + (other.Y - self.Y) * t)
end

function Vector2:Angle(other, isSigned: boolean?)
	local dot = self:Dot(other)
	local cross = self:Cross(other)
	local angle = math.atan2(math.abs(cross), dot)
	if isSigned and cross < 0 then
		return -angle
	end
	return angle
end

function Vector2:FuzzyEq(other, epsilon: number?)
	local e = epsilon or 1e-5
	return math.abs(self.X - other.X) <= e and math.abs(self.Y - other.Y) <= e
end

function Vector2:Min(other)
	return Vector2.new(math.min(self.X, other.X), math.min(self.Y, other.Y))
end

function Vector2:Max(other)
	return Vector2.new(math.max(self.X, other.X), math.max(self.Y, other.Y))
end

function Vector2:Floor()
	return Vector2.new(math.floor(self.X), math.floor(self.Y))
end

function Vector2:Ceil()
	return Vector2.new(math.ceil(self.X), math.ceil(self.Y))
end

function Vector2:Abs()
	return Vector2.new(math.abs(self.X), math.abs(self.Y))
end

function Vector2:Sign()
	local function sign(n)
		if n > 0 then
			return 1
		elseif n < 0 then
			return -1
		else
			return 0
		end
	end
	return Vector2.new(sign(self.X), sign(self.Y))
end

Vector2.zero = Vector2.new(0, 0)
Vector2.one = Vector2.new(1, 1)
Vector2.xAxis = Vector2.new(1, 0)
Vector2.yAxis = Vector2.new(0, 1)

return Vector2 :: Vector2

-- This file is just here so I can test the Vector2 type in Lune. It's ignored in actual Roblox Code.

if Vector2 then
	return Vector2
end

local vector2 = {}
vector2.__index = function(self, key)
	if key == "Magnitude" then
		return math.sqrt(self.X * self.X + self.Y * self.Y)
	elseif key == "Unit" then
		local mag = self.Magnitude
		if mag > 0 then
			return vector2.new(self.X / mag, self.Y / mag)
		else
			return vector2.new(0, 0)
		end
	end
	return rawget(vector2, key)
end

function vector2.new(x: number, y: number)
	return setmetatable({ X = x or 0, Y = y or 0 }, vector2)
end

function vector2:__add(other)
	return vector2.new(self.X + other.X, self.Y + other.Y)
end

function vector2:__sub(other)
	return vector2.new(self.X - other.X, self.Y - other.Y)
end

function vector2:__mul(scalar)
	return vector2.new(self.X * scalar, self.Y * scalar)
end

function vector2:__eq(other)
	return self.X == other.X and self.Y == other.Y
end

function vector2:Dot(other)
	return self.X * other.X + self.Y * other.Y
end

vector2.zero = vector2.new(0, 0)

return vector2 :: Vector2

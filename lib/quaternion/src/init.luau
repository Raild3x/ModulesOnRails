--[=[
	@class Quaternion
	
	A quaternion implementation for 3D rotations in Roblox.
	Quaternions provide a way to represent rotations without the issues of gimbal lock
	that can occur with Euler angles, and are more computationally efficient than rotation matrices.
	
	@example
	```lua
	local Quaternion = require(path.to.Quaternion)
	
	-- Create a quaternion from axis-angle representation
	local q1 = Quaternion.fromCFrame(CFrame.Angles(0, math.pi/4, 0))
	
	-- Create a quaternion directly
	local q2 = Quaternion.new(1, 0, 0, 0) -- Identity quaternion
	
	-- Multiply quaternions (compose rotations)
	local result = q1 * q2
	
	-- Interpolate between rotations
	local interpolated = q1:Slerp(q2, 0.5)
	```
]=]

type QuaternionStatic = {
	__type: string,
	new: (w: number, x: number, y: number, z: number) -> Quaternion,
	fromCFrame: (cf: CFrame) -> Quaternion,
	Inverse: (self: Quaternion) -> Quaternion,
	ToAxisAngle: (self: Quaternion) -> (Vector3, number),
	Slerp: (self: Quaternion, other: Quaternion, t: number) -> Quaternion,
	SlerpClosest: (self: Quaternion, other: Quaternion, t: number) -> Quaternion,
	ToCFrame: (self: Quaternion) -> CFrame,
}

-- Internal quaternion table with methods
local quaternion = { __type = "quaternion" }
local quaternion_mt = { __index = quaternion }

-- Weak reference table to store Vector3 components for each quaternion instance
-- Performance Note: Using weak references prevents memory leaks when quaternions are garbage collected
local ref = setmetatable({}, { __mode = "k" })

-- Pre-computed math constants for performance
local PI: number = math.pi

local cos = math.cos
local sin = math.sin
local acos = math.acos

--[=[
	Quaternion multiplication metamethod (quaternion composition).
	
	Multiplies two quaternions together, which represents the composition of their rotations.
	The order matters: q1 * q2 applies rotation q2 first, then q1.
	
	Performance Note: This operation involves several vector operations (Dot, Cross) which can be expensive
	
	@param q0 Quaternion -- First quaternion
	@param q1 Quaternion -- Second quaternion
	@return Quaternion -- The composed rotation
	
	@example
	```lua
	local q1 = Quaternion.fromCFrame(CFrame.Angles(math.pi/2, 0, 0)) -- 90 degree X rotation
	local q2 = Quaternion.fromCFrame(CFrame.Angles(0, math.pi/2, 0)) -- 90 degree Y rotation
	local combined = q1 * q2 -- Apply Y rotation, then X rotation
	```
]=]
function quaternion_mt.__mul(q0: Quaternion, q1: Quaternion): Quaternion
	local w0, w1 = q0.W, q1.W
	local v0, v1 = ref[q0], ref[q1]
	local nw = w0 * w1 - v0:Dot(v1)
	local nv = v0 * w1 + v1 * w0 + v0:Cross(v1)
	return quaternion.new(nw, nv.x, nv.y, nv.z)
end

--[=[
	Quaternion exponentiation metamethod (power operation).
	
	Raises a quaternion to a scalar power, which scales the rotation angle by that factor.
	Useful for animation and interpolation where you want partial rotations.
	
	Performance Note: Involves ToAxisAngle conversion and trigonometric calculations
	
	@param q0 Quaternion -- The quaternion to raise to a power
	@param t number -- The power/scaling factor
	@return Quaternion -- The scaled rotation
	
	@example
	```lua
	local q = Quaternion.fromCFrame(CFrame.Angles(math.pi, 0, 0)) -- 180 degree rotation
	local half = q ^ 0.5 -- 90 degree rotation (half the original)
	local double = q ^ 2 -- 360 degree rotation (double the original)
	```
]=]
function quaternion_mt.__pow(q0: Quaternion, t: number): Quaternion
	local axis, theta = q0:ToAxisAngle()
	theta = theta * t * 0.5
	axis = sin(theta) * axis
	return quaternion.new(cos(theta), axis.x, axis.y, axis.z)
end

--[=[
	String representation metamethod for debugging and display purposes.
	
	Converts the quaternion to a readable string format showing W, X, Y, Z components.
	
	@param q0 Quaternion -- The quaternion to convert to string
	@return string -- String representation in format "w, x, y, z"
	
	@example
	```lua
	local q = Quaternion.new(1, 0, 0, 0)
	print(tostring(q)) -- Output: "1, 0, 0, 0"
	```
]=]
function quaternion_mt.__tostring(q0: Quaternion): string
	local t = { q0.W, q0.X, q0.Y, q0.Z }
	return table.concat(t, ", ")
end

local function createQuaternion(w: number, x: number, y: number, z: number)
	local self = {}

	self.W = w
	self.X = x
	self.Y = y
	self.Z = z

	self = setmetatable(self, quaternion_mt)
	ref[self] = Vector3.new(x, y, z)

	return self
end

export type Quaternion = typeof(createQuaternion(1, 0, 0, 0))  & {
	Inverse: (self: Quaternion) -> Quaternion,
	ToAxisAngle: (self: Quaternion) -> (Vector3, number),
	Slerp: (self: Quaternion, other: Quaternion, t: number) -> Quaternion,
	SlerpClosest: (self: Quaternion, other: Quaternion, t: number) -> Quaternion,
	ToCFrame: (self: Quaternion) -> CFrame,
}

--[=[
	Creates a new quaternion with the specified components.
	
	A quaternion represents a rotation in 3D space using four components:
	- W: scalar (real) component
	- X, Y, Z: vector (imaginary) components
	
	For a normalized quaternion representing rotation:
	- W = cos(θ/2) where θ is the rotation angle
	- X, Y, Z = sin(θ/2) * axis components where axis is the rotation axis
	
	Performance Note: Creates a new Vector3 for internal storage - consider object pooling for frequent allocations
	
	@param w number -- Scalar component (real part)
	@param x number -- X component of vector part
	@param y number -- Y component of vector part  
	@param z number -- Z component of vector part
	@return Quaternion -- New quaternion instance
	
	@example
	```lua
	-- Identity quaternion (no rotation)
	local identity = Quaternion.new(1, 0, 0, 0)
	
	-- 180 degree rotation around X axis
	local rotation = Quaternion.new(0, 1, 0, 0)
	```
]=]
function quaternion.new(w: number, x: number, y: number, z: number): Quaternion
	return createQuaternion(w, x, y, z) :: any
end

--[=[
	Creates a quaternion from a CFrame's rotation component.
	
	Extracts the rotational part of a CFrame and converts it to quaternion representation.
	The position component of the CFrame is ignored, only rotation is considered.
	
	This is the primary way to create quaternions from existing Roblox rotation data.
	
	Performance Note: Uses CFrame:ToAxisAngle() which involves matrix decomposition
	
	@param cf CFrame -- CFrame to extract rotation from
	@return Quaternion -- Quaternion representing the same rotation
	
	@example
	```lua
	-- From CFrame.Angles
	local cf = CFrame.Angles(math.pi/4, 0, 0) -- 45 degree X rotation
	local q = Quaternion.fromCFrame(cf)
	
	-- From part rotation
	local part = workspace.SomePart
	local partRotation = Quaternion.fromCFrame(part.CFrame)
	```
]=]
function quaternion.fromCFrame(cf: CFrame): Quaternion
	local axis, theta = cf:ToAxisAngle()
	theta = theta * 0.5
	axis = sin(theta) * axis
	return quaternion.new(cos(theta), axis.x, axis.y, axis.z)
end

--[=[
	Calculates the inverse (conjugate divided by magnitude squared) of the quaternion.
	
	The inverse quaternion represents the opposite rotation. When multiplied with the original,
	it produces the identity quaternion (no rotation).
	
	For normalized quaternions, the inverse is simply the conjugate, but this implementation
	handles non-normalized quaternions correctly by dividing by the magnitude squared.
	
	Performance Note: Involves dot product and division operations - expensive for frequent use
	
	@return Quaternion -- The inverse quaternion
	
	@example
	```lua
	local q = Quaternion.fromCFrame(CFrame.Angles(math.pi/2, 0, 0))
	local qInverse = q:Inverse()
	local identity = q * qInverse -- Should be very close to (1, 0, 0, 0)
	```
]=]
function quaternion:Inverse(): Quaternion
	local w = self.W
	local conjugate = w * w + ref[self]:Dot(ref[self])

	local nw = w / conjugate
	local nv = -ref[self] / conjugate

	return quaternion.new(nw, nv.x, nv.y, nv.z)
end

--[=[
	Converts the quaternion back to axis-angle representation.
	
	Returns the rotation axis (as a unit vector) and rotation angle that this quaternion represents.
	This is useful for understanding what rotation the quaternion represents in human-readable terms.
	
	Edge case: If the rotation angle is zero (identity quaternion), returns an arbitrary axis (1,0,0)
	since any axis is valid for zero rotation.
	
	Performance Note: Involves acos calculation and vector normalization - moderately expensive
	
	@return Vector3 -- Unit vector representing the rotation axis
	@return number -- Rotation angle in radians
	
	@example
	```lua
	local q = Quaternion.fromCFrame(CFrame.Angles(math.pi/2, 0, 0))
	local axis, angle = q:ToAxisAngle()
	-- axis will be approximately Vector3.new(1, 0, 0)
	-- angle will be approximately math.pi/2
	```
]=]
function quaternion:ToAxisAngle(): (Vector3, number)
	local axis = ref[self]
	local theta = acos(self.W) * 2

	-- if theta is equivalent to zero then pick a random axis
	if theta % (PI * 2) == 0 and axis:Dot(axis) == 0 then
		axis = Vector3.new(1, 0, 0)
	end

	return axis.Unit, theta
end

--[=[
	Spherical Linear Interpolation between two quaternions.
	
	Smoothly interpolates between this quaternion and another along the shortest arc on the
	4D unit sphere. This produces natural-looking rotation animations without the issues
	of linear interpolation (which can cause unwanted scaling effects).
	
	Performance Note: Involves inverse calculation and exponentiation - expensive operation
	Consider caching results or using lower-level SLERP implementations for real-time use
	
	@param self2 Quaternion -- Target quaternion to interpolate towards
	@param t number -- Interpolation factor (0 = this quaternion, 1 = self2)
	@return Quaternion -- Interpolated quaternion
	
	@example
	```lua
	local start = Quaternion.fromCFrame(CFrame.Angles(0, 0, 0))
	local finish = Quaternion.fromCFrame(CFrame.Angles(math.pi/2, 0, 0))
	
	-- Animate from start to finish over time
	for i = 0, 1, 0.1 do
		local interpolated = start:Slerp(finish, i)
		-- Use interpolated quaternion for smooth animation
	end
	```
]=]
function quaternion:Slerp(self2: Quaternion, t: number): Quaternion
	return ((self2 * self:Inverse()) ^ t) * self
end

--[=[
	Spherical Linear Interpolation that chooses the shortest rotation path.
	
	Since quaternions q and -q represent the same rotation, there are two possible paths
	for interpolation. This function automatically chooses the shorter path by checking
	the dot product of the quaternions and negating one if necessary.
	
	This prevents the "long way around" rotations that can occur with naive SLERP.
	
	Performance Note: Includes dot product calculation overhead but prevents inefficient rotations
	
	@param self2 Quaternion -- Target quaternion to interpolate towards
	@param t number -- Interpolation factor (0 = this quaternion, 1 = self2)
	@return Quaternion -- Interpolated quaternion via shortest path
	
	@example
	```lua
	local q1 = Quaternion.fromCFrame(CFrame.Angles(0, 0, 0))
	local q2 = Quaternion.fromCFrame(CFrame.Angles(0, math.pi * 1.9, 0)) -- Almost full rotation
	
	-- Without SlerpClosest, this would rotate the long way (340 degrees)
	-- With SlerpClosest, this will rotate the short way (20 degrees)
	local smooth = q1:SlerpClosest(q2, 0.5)
	```
]=]
function quaternion:SlerpClosest(self2: Quaternion, t: number): Quaternion
	if self.W * self2.W + self.X * self2.X + self.Y * self2.Y + self.Z * self2.Z > 0 then
		-- choose self2
		return self:Slerp(self2, t)
	else
		-- choose -self2
		self2 = quaternion.new(-self2.W, -self2.X, -self2.Y, -self2.Z)
		return self:Slerp(self2, t)
	end
end

--[=[
	Converts the quaternion back to a CFrame representation.
	
	Creates a CFrame with no translation (position 0,0,0) and the rotation represented
	by this quaternion. This is the inverse operation of fromCFrame().
	
	Note: The parameter order for CFrame.new with quaternion components is (x, y, z, w)
	where x, y, z are the vector components and w is the scalar component.
	
	Performance Note: CFrame creation is relatively fast, good for applying rotations to parts
	
	@return CFrame -- CFrame representing the same rotation at origin
	
	@example
	```lua
	local q = Quaternion.fromCFrame(CFrame.Angles(math.pi/4, 0, 0))
	local cf = q:ToCFrame()
	
	-- Apply rotation to a part
	workspace.SomePart.CFrame = CFrame.new(part.Position) * cf
	```
]=]
function quaternion:ToCFrame(): CFrame
	return CFrame.new(0, 0, 0, self.X, self.Y, self.Z, self.W)
end

--[=[
	Performance Improvement Recommendations:
	
	1. **Object Pooling**: For frequent quaternion creation/destruction, implement an object pool
	   to avoid garbage collection pressure from the Vector3 references.
	
	2. **Normalization**: Add a :Normalize() method and ensure quaternions stay normalized
	   to avoid expensive division operations in Inverse().
	
	3. **Fast SLERP**: Consider implementing a more direct SLERP algorithm instead of using
	   multiplication and exponentiation for better performance in animation loops.
	
	4. **Caching**: For repeated operations on the same quaternions, cache results of
	   expensive operations like ToAxisAngle() and Inverse().
	
	5. **SIMD Opportunities**: The mathematical operations could benefit from vectorization
	   if Luau ever supports SIMD instructions.
	
	6. **Memory Layout**: Consider storing components directly instead of using a separate
	   Vector3 reference table for better cache locality.
]=]

return quaternion

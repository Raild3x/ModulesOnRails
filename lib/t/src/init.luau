--!strict
-- t: a runtime typechecker for Roblox
-- forked by raild3x from osyris's t

--[=[
	@class t

	A composable runtime typechecker for Luau and Roblox.

	Each validator returns `true` on success or `false, errorMessage` on
	failure, which makes the library useful both for defensive assertions and
	reusable configuration validation.

	### Examples

	```lua
	local t = require(path.to.t)

	local ok, err = t.string("hello")
	print(ok, err) --> true nil

	local checkPlayer = t.interface({
		Name = t.string,
		Health = t.numberConstrained(0, 100),
	})

	print(checkPlayer({ Name = "Builderman", Health = 100 })) --> true
	print(checkPlayer({ Name = "Builderman", Health = 150 })) --> false [interface] ...
	```

	```lua
	local t = require(path.to.t)


	local isStringArray = t.array(t.string)
    assert(isStringArray({ "a", "b", "c" })) -- true
    assert(isStringArray({ "a", 1, "c" })) -- false, bad value for key 2: string expected, got number
	```
]=]

--- A checker function that returns `true` on success or `false, errorMessage` on failure.
export type Check = (value: any) -> (boolean, string?)
export type Validator<T> = (value: any) -> (boolean, string?)
export type TupleValidator = (...any) -> (boolean, string?)
export type Predicate<T> = (value: T) -> (boolean, string?)
--[[
    NOTE:
    Technically validators should return (true) | (false, string), but Luau doesn't support this very nicely, 
    so we use (boolean, string?) instead. Internally true is just casted to `any` to satisfy the type system.
    This is done to keep backwards compatibility with the original T library.
]]

type CheckMap = { [any]: Check }
type ChildCheckMap = { [string]: Check }

local t = {}

--[=[
	@within t
	Creates a checker using Lua's native `type()`.

	## Example
	```lua
	local isTable = t.type("table")
	print(isTable({})) --> true
	```

	@param typeName string -- The Lua type name to check against
	@return Validator<any>
]=]
function t.type(typeName: string): Validator<any>
	return function(value: any): (boolean, string?)
		local valueType = type(value)
		if valueType == typeName then
			return true :: any
		else
			return false, string.format("%s expected, got %s", typeName, valueType)
		end
	end
end

--[=[
	@within t
	Creates a checker using Roblox's `typeof()`.

	## Example
	```lua
	local isVector3 = t.typeof("Vector3")
	print(isVector3(Vector3.zero)) --> true
	```

	@param typeName string -- The Roblox type name to check against
	@return Validator<any>
]=]
function t.typeof(typeName: string): Validator<any>
	return function(value: any): (boolean, string?)
		local valueType = typeof(value)
		if valueType == typeName then
			return true :: any
		else
			return false, string.format("%s expected, got %s", typeName, valueType)
		end
	end
end

--[=[
	@within t
	Matches any type except nil.

	## Example
	```lua
	print(t.any("value")) --> true
	print(t.any(nil)) --> false, "any expected, got nil"
	```

	@param value any
	@return boolean
	@return string?
]=]
function t.any(value: any): (boolean, string?)
	if value ~= nil then
		return true :: any
	else
		return false, "any expected, got nil"
	end
end

-- Lua primitives

--[=[
	Ensures Lua primitive boolean type.
	@prop boolean Check
	@within t
]=]
t.boolean = t.typeof("boolean")

--[=[
	Ensures Lua primitive buffer type.
	@prop buffer Check
	@within t
]=]
t.buffer = t.typeof("buffer")

--[=[
	Ensures Lua primitive thread type.
	@prop thread Check
	@within t
]=]
t.thread = t.typeof("thread")

--[=[
	Ensures Lua primitive function type.
	@prop callback Check
	@within t
]=]
t.callback = t.typeof("function")
t["function"] = t.callback

--[=[
	Ensures Lua primitive nil type.
	@prop none Check
	@within t
]=]
t.none = t.typeof("nil")
t["nil"] = t.none

--[=[
	Ensures Lua primitive string type.
	@prop string Check
	@within t
]=]
t.string = t.typeof("string")

--[=[
	Ensures Lua primitive table type.
	@prop table Check
	@within t
]=]
t.table = t.typeof("table")

--[=[
	Ensures Lua primitive userdata type.
	@prop userdata Check
	@within t
]=]
t.userdata = t.type("userdata")

--[=[
	Ensures Lua primitive vector type.
	@prop vector Check
	@within t
]=]
t.vector = t.type("vector")

--[=[
	@within t
	Ensures value is a non-NaN number.

	## Example
	```lua
	print(t.number(42)) --> true
	print(t.number(0 / 0)) --> false, "unexpected NaN value"
	```

	@param value any
	@return boolean
	@return string?
]=]
function t.number(value: any): (boolean, string?)
	local valueType = typeof(value)
	if valueType == "number" then
		if value == value then
			return true :: any
		else
			return false, "unexpected NaN value"
		end
	else
		return false, string.format("number expected, got %s", valueType)
	end
end

--[=[
	@within t
	Ensures value is NaN.

	## Example
	```lua
	print(t.nan(0 / 0)) --> true
	print(t.nan(5)) --> false, "unexpected non-NaN value"
	```

	@param value any
	@return boolean
	@return string?
]=]
function t.nan(value: any): (boolean, string?)
	local valueType = typeof(value)
	if valueType == "number" then
		if value ~= value then
			return true :: any
		else
			return false, "unexpected non-NaN value"
		end
	else
		return false, string.format("number expected, got %s", valueType)
	end
end

-- Roblox types

--[=[
	Ensures Roblox Axes type.
	@prop Axes Check
	@within t
]=]
t.Axes = t.typeof("Axes")

--[=[
	Ensures Roblox BrickColor type.
	@prop BrickColor Check
	@within t
]=]
t.BrickColor = t.typeof("BrickColor")

--[=[
	Ensures Roblox CatalogSearchParams type.
	@prop CatalogSearchParams Check
	@within t
]=]
t.CatalogSearchParams = t.typeof("CatalogSearchParams")

--[=[
	Ensures Roblox CFrame type.
	@prop CFrame Check
	@within t
]=]
t.CFrame = t.typeof("CFrame")

--[=[
	Ensures Roblox Color3 type.
	@prop Color3 Check
	@within t
]=]
t.Color3 = t.typeof("Color3")

--[=[
	Ensures Roblox ColorSequence type.
	@prop ColorSequence Check
	@within t
]=]
t.ColorSequence = t.typeof("ColorSequence")

--[=[
	Ensures Roblox ColorSequenceKeypoint type.
	@prop ColorSequenceKeypoint Check
	@within t
]=]
t.ColorSequenceKeypoint = t.typeof("ColorSequenceKeypoint")

--[=[
	Ensures Roblox DateTime type.
	@prop DateTime Check
	@within t
]=]
t.DateTime = t.typeof("DateTime")

--[=[
	Ensures Roblox DockWidgetPluginGuiInfo type.
	@prop DockWidgetPluginGuiInfo Check
	@within t
]=]
t.DockWidgetPluginGuiInfo = t.typeof("DockWidgetPluginGuiInfo")

--[=[
	Ensures Roblox Enum type.
	@prop Enum Check
	@within t
]=]
t.Enum = t.typeof("Enum")

--[=[
	Ensures Roblox EnumItem type.
	@prop EnumItem Check
	@within t
]=]
t.EnumItem = t.typeof("EnumItem")

--[=[
	Ensures Roblox Enums type.
	@prop Enums Check
	@within t
]=]
t.Enums = t.typeof("Enums")

--[=[
	Ensures Roblox Faces type.
	@prop Faces Check
	@within t
]=]
t.Faces = t.typeof("Faces")

--[=[
	Ensures Roblox FloatCurveKey type.
	@prop FloatCurveKey Check
	@within t
]=]
t.FloatCurveKey = t.typeof("FloatCurveKey")

--[=[
	Ensures Roblox Font type.
	@prop Font Check
	@within t
]=]
t.Font = t.typeof("Font")

--[=[
	Ensures Roblox Instance type.
	@prop Instance Check
	@within t
]=]
t.Instance = t.typeof("Instance")

--[=[
	Ensures Roblox NumberRange type.
	@prop NumberRange Check
	@within t
]=]
t.NumberRange = t.typeof("NumberRange")

--[=[
	Ensures Roblox NumberSequence type.
	@prop NumberSequence Check
	@within t
]=]
t.NumberSequence = t.typeof("NumberSequence")

--[=[
	Ensures Roblox NumberSequenceKeypoint type.
	@prop NumberSequenceKeypoint Check
	@within t
]=]
t.NumberSequenceKeypoint = t.typeof("NumberSequenceKeypoint")

--[=[
	Ensures Roblox OverlapParams type.
	@prop OverlapParams Check
	@within t
]=]
t.OverlapParams = t.typeof("OverlapParams")

--[=[
	Ensures Roblox PathWaypoint type.
	@prop PathWaypoint Check
	@within t
]=]
t.PathWaypoint = t.typeof("PathWaypoint")

--[=[
	Ensures Roblox PhysicalProperties type.
	@prop PhysicalProperties Check
	@within t
]=]
t.PhysicalProperties = t.typeof("PhysicalProperties")

--[=[
	Ensures Roblox Random type.
	@prop Random Check
	@within t
]=]
t.Random = t.typeof("Random")

--[=[
	Ensures Roblox Ray type.
	@prop Ray Check
	@within t
]=]
t.Ray = t.typeof("Ray")

--[=[
	Ensures Roblox RaycastParams type.
	@prop RaycastParams Check
	@within t
]=]
t.RaycastParams = t.typeof("RaycastParams")

--[=[
	Ensures Roblox RaycastResult type.
	@prop RaycastResult Check
	@within t
]=]
t.RaycastResult = t.typeof("RaycastResult")

--[=[
	Ensures Roblox RBXScriptConnection type.
	@prop RBXScriptConnection Check
	@within t
]=]
t.RBXScriptConnection = t.typeof("RBXScriptConnection")

--[=[
	Ensures Roblox RBXScriptSignal type.
	@prop RBXScriptSignal Check
	@within t
]=]
t.RBXScriptSignal = t.typeof("RBXScriptSignal")

--[=[
	Ensures Roblox Rect type.
	@prop Rect Check
	@within t
]=]
t.Rect = t.typeof("Rect")

--[=[
	Ensures Roblox Region3 type.
	@prop Region3 Check
	@within t
]=]
t.Region3 = t.typeof("Region3")

--[=[
	Ensures Roblox Region3int16 type.
	@prop Region3int16 Check
	@within t
]=]
t.Region3int16 = t.typeof("Region3int16")

--[=[
	Ensures Roblox TweenInfo type.
	@prop TweenInfo Check
	@within t
]=]
t.TweenInfo = t.typeof("TweenInfo")

--[=[
	Ensures Roblox UDim type.
	@prop UDim Check
	@within t
]=]
t.UDim = t.typeof("UDim")

--[=[
	Ensures Roblox UDim2 type.
	@prop UDim2 Check
	@within t
]=]
t.UDim2 = t.typeof("UDim2")

--[=[
	Ensures Roblox Vector2 type.
	@prop Vector2 Check
	@within t
]=]
t.Vector2 = t.typeof("Vector2")

--[=[
	Ensures Roblox Vector2int16 type.
	@prop Vector2int16 Check
	@within t
]=]
t.Vector2int16 = t.typeof("Vector2int16")

--[=[
	Ensures Roblox Vector3 type.
	@prop Vector3 Check
	@within t
]=]
t.Vector3 = t.typeof("Vector3")

--[=[
	Ensures Roblox Vector3int16 type.
	@prop Vector3int16 Check
	@within t
]=]
t.Vector3int16 = t.typeof("Vector3int16")

--[=[
	@within t
	Ensures value is a given literal value. When given multiple arguments,
	creates a union of the provided literals.

	## Example
	```lua
	local stateCheck = t.literal("idle", "running")
	print(stateCheck("idle")) --> true
	```

	@param ... any -- The literal value(s) to match
	@return Validator<T>
]=]
function t.literal<T>(...: T): Validator<T>
	local size = select("#", ...)
	if size == 1 then
		local literal = ...
		return function(value: any): (boolean, string?)
			if value ~= literal then
				return false, string.format("expected %s, got %s", tostring(literal), tostring(value))
			end
			return true :: any
		end
	else
		local literals = {}
		for i = 1, size do
			local value = select(i, ...)
			literals[i] = t.literal(value)
		end
		return t.union(table.unpack(literals, 1, size))
	end
end

--[=[
	Alias for `t.literal`.
	@prop exactly Check
	@within t
	@deprecated Use `t.literal` instead.
]=]
t.exactly = t.literal

--[=[
	@within t
	Returns a `t.union` of each key in the table as a `t.literal`.

	## Example
	```lua
	local isMode = t.keyOf({ Easy = true, Hard = true })
	print(isMode("Easy")) --> true
	```

	@param keyTable {[any]: any} -- The table whose keys are the allowed values
	@return Validator<K>
]=]
function t.keyOf<K>(keyTable: { [K]: any }): Validator<K>
	local keys = {}
	local length = 0
	for key in pairs(keyTable) do
		length = length + 1
		keys[length] = key
	end
	return t.literal(table.unpack(keys, 1, length))
end

--[=[
	@within t
	Returns a `t.union` of each value in the table as a `t.literal`.

	## Example
	```lua
	local isRank = t.valueOf({ Bronze = 1, Silver = 2 })
	print(isRank(2)) --> true
	```

	@param valueTable {[any]: any} -- The table whose values are the allowed values
	@return Validator<V>
]=]
function t.valueOf<V>(valueTable: { [any]: V }): Validator<V>
	local values = {}
	local length = 0
	for _, value in pairs(valueTable) do
		length = length + 1
		values[length] = value
	end
	return t.literal(table.unpack(values, 1, length))
end

--[=[
	@within t
	Ensures value is an integer (whole number).

	## Example
	```lua
	print(t.integer(8)) --> true
	print(t.integer(8.5)) --> false, "integer expected, got 8.5"
	```

	@param value any
	@return boolean
	@return string?
]=]
function t.integer(value: any): (boolean, string?)
	local success, errMsg = t.number(value)
	if not success then
		return false, errMsg or ""
	end
	if value % 1 == 0 then
		return true :: any
	else
		return false, string.format("integer expected, got %s", value)
	end
end

--[=[
	@within t
	Ensures value is an integer where `min <= value`.

	## Example
	```lua
	local atLeastTen = t.integerMin(10)
	print(atLeastTen(12)) --> true
	```

	@param min number -- The inclusive minimum bound
	@return Check
]=]
function t.integerMin(min: number): Check
	assert(t.integer(min))
	return function(value: any): (boolean, string?)
		local success, errMsg = t.integer(value)
		if not success then
			return false, errMsg or ""
		end
		if value >= min then
			return true :: any
		else
			return false, string.format("integer >= %s expected, got %s", tostring(min), tostring(value))
		end
	end
end

--[=[
	@within t
	Ensures value is an integer where `value <= max`.

	## Example
	```lua
	local atMostTen = t.integerMax(10)
	print(atMostTen(8)) --> true
	```

	@param max number -- The inclusive maximum bound
	@return Check
]=]
function t.integerMax(max: number): Check
	assert(t.integer(max))
	return function(value: any): (boolean, string?)
		local success, errMsg = t.integer(value)
		if not success then
			return false, errMsg or ""
		end
		if value <= max then
			return true :: any
		else
			return false, string.format("integer <= %s expected, got %s", tostring(max), tostring(value))
		end
	end
end

--[=[
	@within t
	Ensures value is an integer where `min < value`.

	## Example
	```lua
	local positive = t.integerMinExclusive(0)
	print(positive(1)) --> true
	```

	@param min number -- The exclusive minimum bound
	@return Check
]=]
function t.integerMinExclusive(min: number): Check
	assert(t.integer(min))
	return function(value: any): (boolean, string?)
		local success, errMsg = t.integer(value)
		if not success then
			return false, errMsg or ""
		end
		if min < value then
			return true :: any
		else
			return false, string.format("integer > %s expected, got %s", tostring(min), tostring(value))
		end
	end
end

--[=[
	@within t
	Ensures value is an integer where `value < max`.

	## Example
	```lua
	local belowTen = t.integerMaxExclusive(10)
	print(belowTen(9)) --> true
	```

	@param max number -- The exclusive maximum bound
	@return Check
]=]
function t.integerMaxExclusive(max: number): Check
	assert(t.integer(max))
	return function(value: any): (boolean, string?)
		local success, errMsg = t.integer(value)
		if not success then
			return false, errMsg or ""
		end
		if value < max then
			return true :: any
		else
			return false, string.format("integer < %s expected, got %s", tostring(max), tostring(value))
		end
	end
end

--[=[
	Ensures value is an integer greater than 0.
	@prop integerPositive Check
	@within t
]=]
t.integerPositive = t.integerMinExclusive(0)

--[=[
	Ensures value is an integer less than 0.
	@prop integerNegative Check
	@within t
]=]
t.integerNegative = t.integerMaxExclusive(0)

--[=[
	@within t
	Ensures value is an integer where `min <= value <= max`.

	## Example
	```lua
	local levelCheck = t.integerConstrained(1, 100)
	print(levelCheck(25)) --> true
	```

	@param min number -- The inclusive minimum bound
	@param max number -- The inclusive maximum bound
	@return Check
]=]
function t.integerConstrained(min: number, max: number): Check
	assert(t.integer(min))
	assert(t.integer(max))
	local minCheck = t.integerMin(min)
	local maxCheck = t.integerMax(max)
	return function(value: any): (boolean, string?)
		local minSuccess, minErrMsg = minCheck(value)
		if not minSuccess then
			return false, minErrMsg or ""
		end
		local maxSuccess, maxErrMsg = maxCheck(value)
		if not maxSuccess then
			return false, maxErrMsg or ""
		end
		return true :: any
	end
end

--[=[
	@within t
	Ensures value is an integer where `min < value < max`.

	## Example
	```lua
	local bounded = t.integerConstrainedExclusive(0, 10)
	print(bounded(5)) --> true
	```

	@param min number -- The exclusive minimum bound
	@param max number -- The exclusive maximum bound
	@return Check
]=]
function t.integerConstrainedExclusive(min: number, max: number): Check
	assert(t.integer(min))
	assert(t.integer(max))
	local minCheck = t.integerMinExclusive(min)
	local maxCheck = t.integerMaxExclusive(max)
	return function(value: any): (boolean, string?)
		local minSuccess, minErrMsg = minCheck(value)
		if not minSuccess then
			return false, minErrMsg or ""
		end
		local maxSuccess, maxErrMsg = maxCheck(value)
		if not maxSuccess then
			return false, maxErrMsg or ""
		end
		return true :: any
	end
end

--[=[
	@within t
	Ensures value is a number where `min <= value`.

	## Example
	```lua
	local atLeastTen = t.numberMin(10)
	print(atLeastTen(12)) --> true
	```

	@param min number -- The inclusive minimum bound
	@return Check
]=]
function t.numberMin(min: number): Check
	return function(value: any): (boolean, string?)
		local success, errMsg = t.number(value)
		if not success then
			return false, errMsg or ""
		end
		if value >= min then
			return true :: any
		else
			return false, string.format("number >= %s expected, got %s", tostring(min), tostring(value))
		end
	end
end

--[=[
	@within t
	Ensures value is a number where `value <= max`.

	## Example
	```lua
	local atMostTen = t.numberMax(10)
	print(atMostTen(8)) --> true
	```

	@param max number -- The inclusive maximum bound
	@return Check
]=]
function t.numberMax(max: number): Check
	return function(value: any): (boolean, string?)
		local success, errMsg = t.number(value)
		if not success then
			return false, errMsg
		end
		if value <= max then
			return true :: any
		else
			return false, string.format("number <= %s expected, got %s", tostring(max), tostring(value))
		end
	end
end

--[=[
	@within t
	Ensures value is a number where `min < value`.

	## Example
	```lua
	local positive = t.numberMinExclusive(0)
	print(positive(1)) --> true
	```

	@param min number -- The exclusive minimum bound
	@return Check
]=]
function t.numberMinExclusive(min: number): Check
	return function(value: any): (boolean, string?)
		local success, errMsg = t.number(value)
		if not success then
			return false, errMsg or ""
		end
		if min < value then
			return true :: any
		else
			return false, string.format("number > %s expected, got %s", tostring(min), tostring(value))
		end
	end
end

--[=[
	@within t
	Ensures value is a number where `value < max`.

	## Example
	```lua
	local belowTen = t.numberMaxExclusive(10)
	print(belowTen(9)) --> true
	```

	@param max number -- The exclusive maximum bound
	@return Check
]=]
function t.numberMaxExclusive(max: number): Check
	return function(value: any): (boolean, string?)
		local success, errMsg = t.number(value)
		if not success then
			return false, errMsg or ""
		end
		if value < max then
			return true :: any
		else
			return false, string.format("number < %s expected, got %s", tostring(max), tostring(value))
		end
	end
end

--[=[
	Ensures value is a number greater than 0.
	@prop numberPositive Check
	@within t
]=]
t.numberPositive = t.numberMinExclusive(0)

--[=[
	Ensures value is a number less than 0.
	@prop numberNegative Check
	@within t
]=]
t.numberNegative = t.numberMaxExclusive(0)

--[=[
	@within t
	Ensures value is a number where `min <= value <= max`.

	## Example
	```lua
	local healthCheck = t.numberConstrained(0, 100)
	print(healthCheck(75)) --> true
	```

	@param min number -- The inclusive minimum bound
	@param max number -- The inclusive maximum bound
	@return Check
]=]
function t.numberConstrained(min: number, max: number): Check
	assert(t.number(min))
	assert(t.number(max))
	local minCheck = t.numberMin(min)
	local maxCheck = t.numberMax(max)
	return function(value: any): (boolean, string?)
		local minSuccess, minErrMsg = minCheck(value)
		if not minSuccess then
			return false, minErrMsg or ""
		end
		local maxSuccess, maxErrMsg = maxCheck(value)
		if not maxSuccess then
			return false, maxErrMsg or ""
		end
		return true :: any
	end
end

--[=[
	@within t
	Ensures value is a number where `min < value < max`.

	## Example
	```lua
	local unitInterval = t.numberConstrainedExclusive(0, 1)
	print(unitInterval(0.5)) --> true
	```

	@param min number -- The exclusive minimum bound
	@param max number -- The exclusive maximum bound
	@return Check
]=]
function t.numberConstrainedExclusive(min: number, max: number): Check
	assert(t.number(min))
	assert(t.number(max))
	local minCheck = t.numberMinExclusive(min)
	local maxCheck = t.numberMaxExclusive(max)
	return function(value: any): (boolean, string?)
		local minSuccess, minErrMsg = minCheck(value)
		if not minSuccess then
			return false, minErrMsg or ""
		end
		local maxSuccess, maxErrMsg = maxCheck(value)
		if not maxSuccess then
			return false, maxErrMsg or ""
		end
		return true :: any
	end
end

--[=[
	@within t
	Ensures value is a string matching the given Lua pattern.

	## Example
	```lua
	local isSlug = t.match("^[a-z]+%-%d+$")
	print(isSlug("entry-42")) --> true
	```

	@param pattern string -- The Lua pattern to match against
	@return Validator<string>
]=]
function t.match(pattern: string): Validator<string>
	assert(t.string(pattern))
	return function(value: any): (boolean, string?)
		local stringSuccess, stringErrMsg = t.string(value)
		if not stringSuccess then
			return false, stringErrMsg
		end
		if string.match(value, pattern) == nil then
			return false, string.format("%q failed to match pattern %q", value, pattern)
		end
		return true :: any
	end
end

--[=[
	@within t
	Ensures value is either nil or passes the given check.

	## Example
	```lua
	local maybeString = t.optional(t.string)
	print(maybeString(nil)) --> true
	```

	@param check Validator<T> -- The check to apply when the value is non-nil
	@return Validator<T?>
]=]
function t.optional<T>(check: Validator<T>): Validator<T?>
	assert(t.callback(check))
	return function(value: any): (boolean, string?)
		if value == nil then
			return true :: any
		end
		local success, errMsg = check(value)
		if success then
			return true :: any
		else
			return false, string.format("(optional) %s", errMsg or "")
		end
	end
end

--[=[
	@within t
	Refines an existing validator with an additional predicate.

	## Example
	```lua
	local nonEmptyString = t.where(t.string, function(value)
		return #value > 0, "string must not be empty"
	end)
	```

	@param check Validator<T> -- The base validator that must pass first
	@param predicate Predicate<T> -- Additional validation applied after `check`
	@param errorMessage string? -- Fallback message when the predicate fails without its own message
	@return Validator<T>
]=]
function t.where<T>(check: Validator<T>, predicate: Predicate<T>, errorMessage: string?): Validator<T>
	assert(t.callback(check))
	assert(t.callback(predicate))
	return function(value: any): (boolean, string?)
		local success, errMsg = check(value)
		if not success then
			return false, errMsg or ""
		end

		local predicateSuccess, predicateErrMsg = predicate(value :: T)
		if predicateSuccess then
			return true :: any
		end

		return false, predicateErrMsg or errorMessage or "value failed refinement"
	end
end

--[=[
	@within t
	Matches a tuple of values against a tuple of checks.

	## Example
	```lua
	local fooArgs = t.tuple(t.string, t.number)
	print(fooArgs("score", 50)) --> true
	```

	@param ... Check -- The check for each tuple position, in order
	@return TupleValidator
]=]
function t.tuple(...: Check): TupleValidator
	local checks = { ... }
	return function(...: any): (boolean, string?)
		local args = { ... }
		for i, check in ipairs(checks) do
			local success, errMsg = check(args[i])
			if success == false then
				return false, string.format("Bad tuple index #%s:\n\t%s", tostring(i), errMsg or "")
			end
		end
		return true :: any
	end
end

--[=[
	@within t
	Matches a tuple of values against a tuple of checks and disallows excess arguments.

	## Example
	```lua
	local createArgs = t.strictTuple(t.string, t.number)
	print(createArgs("score", 50)) --> true
	```

	@param ... Check -- The check for each tuple position, in order
	@return TupleValidator
]=]
function t.strictTuple(...: Check): TupleValidator
	local checks = { ... }
	return function(...: any): (boolean, string?)
		local argCount = select("#", ...)
		if argCount > #checks then
			return false, string.format("Bad tuple length: expected %d arguments, got %d", #checks, argCount)
		end

		local args = { ... }
		for i, check in ipairs(checks) do
			local success, errMsg = check(args[i])
			if success == false then
				return false, string.format("Bad tuple index #%s:\n\t%s", tostring(i), errMsg or "")
			end
		end

		return true :: any
	end
end

--[=[
	@within t
	Ensures all keys in a table pass the given check.

	## Example
	```lua
	local stringKeys = t.keys(t.string)
	print(stringKeys({ Name = true })) --> true
	```

	@param check Validator<K> -- The check applied to each key
	@return Validator<{ [K]: any }>
]=]
function t.keys<K>(check: Validator<K>): Validator<{ [K]: any }>
	assert(t.callback(check))
	return function(value: any): (boolean, string?)
		local tableSuccess, tableErrMsg = t.table(value)
		if tableSuccess == false then
			return false, tableErrMsg or ""
		end
		for key in pairs(value) do
			local success, errMsg = check(key)
			if success == false then
				return false, string.format("bad key %s:\n\t%s", tostring(key), errMsg or "")
			end
		end
		return true :: any
	end
end

--[=[
	@within t
	Ensures all values in a table pass the given check.

	## Example
	```lua
	local numberValues = t.values(t.number)
	print(numberValues({ Coins = 10 })) --> true
	```

	@param check Validator<V> -- The check applied to each value
	@return Validator<{ [any]: V }>
]=]
function t.values<V>(check: Validator<V>): Validator<{ [any]: V }>
	assert(t.callback(check))
	return function(value: any): (boolean, string?)
		local tableSuccess, tableErrMsg = t.table(value)
		if tableSuccess == false then
			return false, tableErrMsg or ""
		end
		for key, val in pairs(value) do
			local success, errMsg = check(val)
			if success == false then
				return false, string.format("bad value for key %s:\n\t%s", tostring(key), errMsg or "")
			end
		end
		return true :: any
	end
end

--[=[
	@within t
	Ensures value is a table where all keys pass `keyCheck` and all values pass `valueCheck`.

	## Example
	```lua
	local scoreMap = t.map(t.string, t.number)
	print(scoreMap({ Alpha = 10 })) --> true
	```

	@param keyCheck Validator<K> -- Check applied to each key
	@param valueCheck Validator<V> -- Check applied to each value
	@return Validator<{ [K]: V }>
]=]
function t.map<K, V>(keyCheck: Validator<K>, valueCheck: Validator<V>): Validator<{ [K]: V }>
	assert(t.callback(keyCheck))
	assert(t.callback(valueCheck))
	local keyChecker = t.keys(keyCheck)
	local valueChecker = t.values(valueCheck)
	return function(value: any): (boolean, string?)
		local keySuccess, keyErr = keyChecker(value)
		if not keySuccess then
			return false, keyErr or ""
		end
		local valueSuccess, valueErr = valueChecker(value)
		if not valueSuccess then
			return false, valueErr or ""
		end
		return true :: any
	end
end

--[=[
	@within t
	Ensures value is a set — a table where all keys pass `valueCheck` and all values are `true`.

	## Example
	```lua
	local tagSet = t.set(t.string)
	print(tagSet({ Fast = true, Active = true })) --> true
	```

	@param valueCheck Validator<K> -- Check applied to each key
	@return Validator<{ [K]: true }>
]=]
function t.set<K>(valueCheck: Validator<K>): Validator<{ [K]: true }>
	return t.map(valueCheck, t.literal(true))
end

do
	local arrayKeysCheck = t.keys(t.integer)

	--[=[
		@within t
		Ensures value is a sequential array where every element passes the given check.

		## Example
		```lua
		local stringArray = t.array(t.string)
		print(stringArray({ "a", "b" })) --> true
		```

		@param check Validator<T> -- The check applied to each element
		@return Validator<{T}>
	]=]
	function t.array<T>(check: Validator<T>): Validator<{ T }>
		assert(t.callback(check))
		local valuesCheck = t.values(check)
		return function(value: any): (boolean, string?)
			local keySuccess, keyErrMsg = arrayKeysCheck(value)
			if keySuccess == false then
				return false, string.format("[array] %s", keyErrMsg or "")
			end
			-- # is unreliable for sparse arrays
			-- Count upwards using ipairs to avoid false positives from the behavior of #
			local arraySize = 0
			while value[arraySize + 1] ~= nil do
				arraySize += 1
			end
			for key in pairs(value) do
				if key < 1 or key > arraySize then
					return false, string.format("[array] key %s must be sequential", tostring(key))
				end
			end
			local valueSuccess, valueErrMsg = valuesCheck(value)
			if not valueSuccess then
				return false, string.format("[array] %s", valueErrMsg or "")
			end
			return true :: any
		end
	end

	--[=[
		@within t
		Ensures value is an array with an exact sequence of element types.
		The array must not be longer than the number of provided checks.

		## Example
		```lua
		local playerTuple = t.strictArray(t.string, t.number)
		print(playerTuple({ "Builderman", 100 })) --> true
		```

		@param ... Check -- The checks for each array index, in order
		@return Check
	]=]
	function t.strictArray(...: Check): Check
		local valueTypes = { ... } :: { Check }
		assert(t.array(t.callback)(valueTypes))
		return function(value: any): (boolean, string?)
			local keySuccess, keyErrMsg = arrayKeysCheck(value)
			if keySuccess == false then
				return false, string.format("[strictArray] %s", keyErrMsg or "")
			end
			if #valueTypes < #value then
				return false, string.format("[strictArray] Array size exceeds limit of %d", #valueTypes)
			end
			for idx, typeFn in ipairs(valueTypes) do
				local typeCheck = typeFn :: Check
				local typeSuccess, typeErrMsg = typeCheck(value[idx])
				if not typeSuccess then
					return false, string.format("[strictArray] Array index #%s - %s", tostring(idx), typeErrMsg or "")
				end
			end
			return true :: any
		end
	end
end

do
	local callbackArray = t.array(t.callback)

	--[=[
		@within t
		Creates a union type that passes if any of the given checks pass.

		## Example
		```lua
		local stringOrNumber = t.union(t.string, t.number)
		print(stringOrNumber(5)) --> true
		```

		@param ... Check -- The checks to union
		@return Validator<T>
	]=]
	function t.union<T>(...: Validator<T>): Validator<T>
		local checks = { ... }
		assert(callbackArray(checks))
		return function(value: any): (boolean, string?)
			local failureMessages = {}
			for index, check in ipairs(checks) do
				local success, errMsg = check(value)
				if success then
					return true :: any
				end
				failureMessages[index] = string.format("[%d] %s", index, errMsg or "union branch failed")
			end
			return false, string.format("bad type for union:\n\t%s", table.concat(failureMessages, "\n\t"))
		end
	end

	--- Alias for `t.union`.
	t.some = t.union

	--[=[
		@within t
		Creates an intersection type that passes only if all of the given checks pass.

		## Example
		```lua
		local positiveInteger = t.intersection(t.integer, t.numberPositive)
		print(positiveInteger(4)) --> true
		```

		@param ... Check -- The checks to intersect
		@return Validator<T>
	]=]
	function t.intersection<T>(...: Validator<T>): Validator<T>
		local checks = { ... }
		assert(callbackArray(checks))
		return function(value: any): (boolean, string?)
			for _, check in ipairs(checks) do
				local success, errMsg = check(value)
				if not success then
					return false, errMsg or ""
				end
			end
			return true :: any
		end
	end

	--- Alias for `t.intersection`.
	t.every = t.intersection
end

do
	local checkInterface = t.map(t.any, t.callback)

	--[=[
		@within t
		Ensures value is a table matching the given interface definition.
		Extra fields on the table are allowed.

		## Example
		```lua
		local playerCheck = t.interface({
			Name = t.string,
			Health = t.number,
		})
		```

		@param checkTable {[any]: Check} -- Map of field name to checker
		@return Validator<T>
	]=]
	function t.interface<T>(checkTable: CheckMap): Validator<T>
		assert(checkInterface(checkTable))
		return function(value: any): (boolean, string?)
			local tableSuccess, tableErrMsg = t.table(value)
			if tableSuccess == false then
				return false, tableErrMsg or ""
			end
			for key, check in pairs(checkTable) do
				local success, errMsg = check(value[key])
				if success == false then
					return false, string.format("[interface] bad value for %s:\n\t%s", tostring(key), errMsg or "")
				end
			end
			return true :: any
		end
	end

	--[=[
		@within t
		Ensures value is a table whose known fields pass the given checks when present.
		Missing fields are allowed.

		## Example
		```lua
		local patchCheck = t.partialInterface({
			Name = t.string,
			Health = t.number,
		})
		```

		@param checkTable {[any]: Check} -- Map of field name to checker for optional fields
		@return Validator<T>
	]=]
	function t.partialInterface<T>(checkTable: CheckMap): Validator<T>
		assert(checkInterface(checkTable))
		return function(value: any): (boolean, string?)
			local tableSuccess, tableErrMsg = t.table(value)
			if tableSuccess == false then
				return false, tableErrMsg or ""
			end
			for key, check in pairs(checkTable) do
				local fieldValue = value[key]
				if fieldValue ~= nil then
					local success, errMsg = check(fieldValue)
					if success == false then
						return false,
							string.format("[partialInterface] bad value for %s:\n\t%s", tostring(key), errMsg or "")
					end
				end
			end
			return true :: any
		end
	end

	--[=[
		@within t
		Ensures value is a table matching the given interface definition exactly.
		Any extra fields not present in `checkTable` will cause the check to fail.

		## Example
		```lua
		local exactPlayerCheck = t.strictInterface({
			Name = t.string,
			Health = t.number,
		})
		```

		@param checkTable {[any]: Check} -- Map of field name to checker
		@return Validator<T>
	]=]
	function t.strictInterface<T>(checkTable: CheckMap): Validator<T>
		assert(checkInterface(checkTable))
		return function(value: any): (boolean, string?)
			local tableSuccess, tableErrMsg = t.table(value)
			if tableSuccess == false then
				return false, tableErrMsg or ""
			end
			for key, check in pairs(checkTable) do
				local success, errMsg = check(value[key])
				if success == false then
					return false, string.format("[interface] bad value for %s:\n\t%s", tostring(key), errMsg or "")
				end
			end
			for key in pairs(value) do
				if not checkTable[key] then
					return false, string.format("[interface] unexpected field %q", tostring(key))
				end
			end
			return true :: any
		end
	end
end

--[=[
	@within t
	Ensures value is an Instance whose `ClassName` exactly matches the given class name.

	## Example
	```lua
	local isFolder = t.instanceOf("Folder")
	print(isFolder(Instance.new("Folder"))) --> true
	```

	@param className string -- The exact class name to match
	@param childTable {[string]: Check}? -- Optional map of child names to checks
	@return Validator<Instance>
]=]
function t.instanceOf(className: string, childTable: ChildCheckMap?): Validator<Instance>
	assert(t.string(className))
	local childrenCheck: Check?
	if childTable ~= nil then
		childrenCheck = t.children(childTable)
	end
	return function(value: any): (boolean, string?)
		local instanceSuccess, instanceErrMsg = t.Instance(value)
		if not instanceSuccess then
			return false, instanceErrMsg or ""
		end
		if value.ClassName ~= className then
			return false, string.format("%s expected, got %s", className, value.ClassName)
		end
		if childrenCheck then
			local childrenSuccess, childrenErrMsg = childrenCheck(value)
			if not childrenSuccess then
				return false, childrenErrMsg
			end
		end
		return true :: any
	end
end

t.instance = t.instanceOf

--[=[
	@within t
	Ensures value is an Instance that passes `value:IsA(className)`.

	## Example
	```lua
	local isGuiObject = t.instanceIsA("GuiObject")
	print(isGuiObject(Instance.new("Frame"))) --> true
	```

	@param className string -- The class name to use with `IsA`
	@param childTable {[string]: Check}? -- Optional map of child names to checks
	@return Validator<Instance>
]=]
function t.instanceIsA(className: string, childTable: ChildCheckMap?): Validator<Instance>
	assert(t.string(className))
	local childrenCheck: Check?
	if childTable ~= nil then
		childrenCheck = t.children(childTable)
	end
	return function(value: any): (boolean, string?)
		local instanceSuccess, instanceErrMsg = t.Instance(value)
		if not instanceSuccess then
			return false, instanceErrMsg or ""
		end
		if not value:IsA(className) then
			return false, string.format("%s expected, got %s", className, value.ClassName)
		end
		if childrenCheck then
			local childrenSuccess, childrenErrMsg = childrenCheck(value)
			if not childrenSuccess then
				return false, childrenErrMsg
			end
		end
		return true :: any
	end
end

--[=[
	@within t
	Ensures value is an EnumItem belonging to the given Enum type.

	## Example
	```lua
	local isMaterial = t.enum(Enum.Material)
	print(isMaterial(Enum.Material.Slate)) --> true
	```

	@param enum Enum -- The Enum type to check against
	@return Validator<EnumItem>
]=]
function t.enum(enum: Enum): Validator<EnumItem>
	assert(t.Enum(enum))
	return function(value: any): (boolean, string?)
		local enumItemSuccess, enumItemErrMsg = t.EnumItem(value)
		if not enumItemSuccess then
			return false, enumItemErrMsg
		end
		if value.EnumType == enum then
			return true :: any
		else
			return false, string.format("enum of %s expected, got enum of %s", tostring(enum), tostring(value.EnumType))
		end
	end
end

do
	local checkWrap = t.tuple(t.callback, t.callback)

	--[=[
		@within t
		Wraps a callback with an argument-check assertion. The returned function
		will `assert` the check before forwarding to the original callback.

		## Example
		```lua
		local add = t.wrap(function(a, b)
			return a + b
		end, t.tuple(t.number, t.number))
		```

		@param callback (...any) -> ...any -- The function to wrap
		@param checkArgs TupleValidator -- The check asserted on the arguments
		@return (...any) -> ...any
	]=]
	function t.wrap<Args..., Returns...>(callback: (Args...) -> Returns..., checkArgs: TupleValidator): (Args...) -> Returns...
		assert(checkWrap(callback, checkArgs))
		return function(...: any): ...any
			assert(checkArgs(...))
			return callback(...)
		end
	end
end

--[=[
	@within t
	Wraps a check in an `assert`, producing a function that throws on failure.

	## Example
	```lua
	local assertString = t.strict(t.tuple(t.string))
	assertString("hello")
	```

	@param check TupleValidator -- The check to wrap
	@return (...any) -> ()
]=]
function t.strict<Args...>(check: TupleValidator): (Args...) -> ()
	return function(...: Args...): ()
		assert(check(...))
	end
end

do
	local checkChildren = t.map(t.string, t.callback)

	--[=[
		@within t
		Ensures an Instance tree has named children that pass the corresponding checks.
		Each entry in `checkTable` must be satisfied by a child with that exact name.

		## Example
		```lua
		local hasConfig = t.children({
			Config = t.instanceOf("StringValue"),
		})
		```

		:::warning
		If the instance has multiple children with the same name, this check will always fail.
		:::

		@param checkTable {[string]: Check} -- Map of child name to checker
		@return Validator<Instance>
	]=]
	function t.children(checkTable: ChildCheckMap): Validator<Instance>
		assert(checkChildren(checkTable))
		return function(value: any): (boolean, string?)
			local instanceSuccess, instanceErrMsg = t.Instance(value)
			if not instanceSuccess then
				return false, instanceErrMsg or ""
			end
			local childrenByName = {}
			for _, child in ipairs(value:GetChildren()) do
				local name = child.Name
				if checkTable[name] then
					if childrenByName[name] then
						return false, string.format("Cannot process multiple children with the same name %q", name)
					end
					childrenByName[name] = child
				end
			end
			for name, check in pairs(checkTable) do
				local success, errMsg = check(childrenByName[name])
				if not success then
					return false, string.format("[%s.%s] %s", value:GetFullName(), name, errMsg or "")
				end
			end
			return true :: any
		end
	end
end

export type RuntimeTypeChecker = typeof(t)

return t

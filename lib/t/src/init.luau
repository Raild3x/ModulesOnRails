--!strict
-- t: a runtime typechecker for Roblox
-- forked by raild3x from osyris's t

--[=[
    @class T

    A composable runtime typechecker for Luau and Roblox.

    Each check returns `true` on success or `false, errorMessage` on
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

--[=[
	@within T
	@type Check<T = any> (value: any) -> (boolean, string?)
	A function that validates a single value and returns `true` on success or `false, errorMessage` on failure.
	`T` is a phantom type tag used for composition — callers may pass any value regardless of T.
]=]
export type Check<T = any> = (value: any) -> (boolean, string?)
--[=[
	@within T
	@type TupleCheck<T... = ...any> (T...) -> (boolean, string?)
	A function that validates a list of positional arguments and returns `true` on success or `false, errorMessage` on failure.
]=]
export type CheckTuple<T... = ...any> = (T...) -> (boolean, string?)
--[[
	NOTE:
	Technically checks should return (true) | (false, string), but Luau doesn't support this very nicely,
    so we use (boolean, string?) instead. Internally true is just casted to `any` to satisfy the type system.
    This is done to keep backwards compatibility with the original T library.
]]

-- --[=[
-- 	@within T
-- 	@type TupleCheck<T... = ...any> (T...) -> (boolean, string?)
-- 	A function that validates a list of positional arguments and returns `true` on success or `false, errorMessage` on failure.

-- 	```lua
-- 	local argCheck: t.TupleCheck<string, number> = t.strictTuple(t.string, t.number)
-- 	```
-- ]=]
-- export type TupleCheck<T... = ...any> = (T...) -> (boolean, string?)

--[=[
	@within T
	@type Predicate<T> (T) -> (boolean, string?)
	A refinement function used by `t.where` to apply an additional rule after a base check has passed.

	```lua
	local function isPositive(value: number)
		return value > 0, "number must be positive"
	end
	```
]=]
export type Predicate<T> = (value: T) -> (boolean, string?)

local t = {}

--[=[
	@within T
	@function type
	Creates a checker using Lua's native `type()`.

	```lua
	local isTable = t.type("table")
	print(isTable({})) --> true
	```

	@param typeName string -- The Lua type name to check against
	@return Check
]=]
function t.type(typeName: string): Check<any>
	return function(value: unknown): (boolean, string?)
		local valueType = type(value)
		if valueType == typeName then
			return true :: any
		else
			return false, string.format("%s expected, got %s", typeName, valueType)
		end
	end
end

--[=[
	@within T
	@function typeof
	Creates a checker using Roblox's `typeof()`.

	```lua
	local isVector3 = t.typeof("Vector3")
	print(isVector3(Vector3.zero)) --> true
	```

	@param typeName string -- The Roblox type name to check against
	@return Check
]=]
function t.typeof(typeName: string): Check<any>
	return function(value: unknown): (boolean, string?)
		local valueType = typeof(value)
		if valueType == typeName then
			return true :: any
		else
			return false, string.format("%s expected, got %s", typeName, valueType)
		end
	end
end

--[=[
	@within T
	@function any
	Matches any type except nil.

	```lua
	print(t.any("value")) --> true
	print(t.any(nil)) --> false, "any expected, got nil"
	```

	@param value any
	@return boolean
	@return string?
]=]
function t.any(value: unknown): (boolean, string?)
	if value ~= nil then
		return true :: any
	else
		return false, "any expected, got nil"
	end
end

-- Lua primitives

--[=[
	Ensures Lua primitive boolean type.
	@within T
	@function boolean
	@param value any
	@return boolean
	@return string?
]=]
t.boolean = t.typeof("boolean") :: Check<boolean>

--[=[
	Ensures Lua primitive buffer type.
	@within T
	@function buffer
	@param value any
	@return boolean
	@return string?
]=]
t.buffer = t.typeof("buffer") :: Check<buffer>

--[=[
	Ensures Lua primitive thread type.
	@within T
	@function thread
	@param value any
	@return boolean
	@return string?
]=]
t.thread = t.typeof("thread") :: Check<thread>

--[=[
	Ensures Lua primitive function type.
	@within T
	@function callback
	@param value any
	@return boolean
	@return string?
]=]
t.callback = t.typeof("function") :: Check<(...any) -> ...any>
t["function"] = t.callback

--[=[
	Ensures Lua primitive nil type.
	@within T
	@function none
	@param value any
	@return boolean
	@return string?
]=]
t.none = t.typeof("nil") :: Check<nil>
t["nil"] = t.none

--[=[
	Ensures Lua primitive string type.
	@within T
	@function string
	@param value any
	@return boolean
	@return string?
]=]
t.string = t.typeof("string") :: Check<string>

--[=[
	Ensures Lua primitive table type.
	@within T
	@function table
	@param value any
	@return boolean
	@return string?
]=]
t.table = t.typeof("table") :: Check<{ [any]: any }>

--[=[
	Ensures Lua primitive userdata type.
	@within T
	@function userdata
	@param value any
	@return boolean
	@return string?
]=]
t.userdata = t.type("userdata") :: Check<any>

--[=[
	Ensures Lua primitive vector type.
	@within T
	@function vector
	@param value any
	@return boolean
	@return string?
]=]
t.vector = t.type("vector") :: Check<vector>

--[=[
	@function number
	@within T
	Ensures value is a non-NaN number.

	```lua
	print(t.number(42)) --> true
	print(t.number(0 / 0)) --> false, "unexpected NaN value"
	```

	@param value any
	@return boolean
	@return string?
]=]
function t.number(value: unknown): (boolean, string?)
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
t.number = (t.number :: any) :: Check<number>

--[=[
	@within T
	@function nan
	Ensures value is NaN.

	```lua
	print(t.nan(0 / 0)) --> true
	print(t.nan(5)) --> false, "unexpected non-NaN value"
	```

	@param value any
	@return boolean
	@return string?
]=]
function t.nan(value: unknown): (boolean, string?)
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
t.nan = (t.nan :: any) :: Check<number>

-- Roblox types

--[=[
	Ensures Roblox Axes type.
	@within T
	@function Axes
	@param value any
	@return boolean
	@return string?
]=]
t.Axes = t.typeof("Axes") :: Check<Axes>

--[=[
	Ensures Roblox BrickColor type.
	@within T
	@function BrickColor
	@param value any
	@return boolean
	@return string?
]=]
t.BrickColor = t.typeof("BrickColor") :: Check<BrickColor>

--[=[
	Ensures Roblox CatalogSearchParams type.
	@within T
	@function CatalogSearchParams
	@param value any
	@return boolean
	@return string?
]=]
t.CatalogSearchParams = t.typeof("CatalogSearchParams") :: Check<CatalogSearchParams>

--[=[
	Ensures Roblox CFrame type.
	@within T
	@function CFrame
	@param value any
	@return boolean
	@return string?
]=]
t.CFrame = t.typeof("CFrame") :: Check<CFrame>

--[=[
	Ensures Roblox Color3 type.
	@within T
	@function Color3
	@param value any
	@return boolean
	@return string?
]=]
t.Color3 = t.typeof("Color3") :: Check<Color3>

--[=[
	Ensures Roblox ColorSequence type.
	@within T
	@function ColorSequence
	@param value any
	@return boolean
	@return string?
]=]
t.ColorSequence = t.typeof("ColorSequence") :: Check<ColorSequence>

--[=[
	Ensures Roblox ColorSequenceKeypoint type.
	@within T
	@function ColorSequenceKeypoint
	@param value any
	@return boolean
	@return string?
]=]
t.ColorSequenceKeypoint = t.typeof("ColorSequenceKeypoint") :: Check<ColorSequenceKeypoint>

--[=[
	Ensures Roblox DateTime type.
	@within T
	@function DateTime
	@param value any
	@return boolean
	@return string?
]=]
t.DateTime = t.typeof("DateTime") :: Check<DateTime>

--[=[
	Ensures Roblox DockWidgetPluginGuiInfo type.
	@within T
	@function DockWidgetPluginGuiInfo
	@param value any
	@return boolean
	@return string?
]=]
t.DockWidgetPluginGuiInfo = t.typeof("DockWidgetPluginGuiInfo") :: Check<DockWidgetPluginGuiInfo>

--[=[
	Ensures Roblox Enum type.
	@within T
	@function Enum
	@param value any
	@return boolean
	@return string?
]=]
t.Enum = t.typeof("Enum") :: Check<Enum>

--[=[
	Ensures Roblox EnumItem type.
	@within T
	@function EnumItem
	@param value any
	@return boolean
	@return string?
]=]
t.EnumItem = t.typeof("EnumItem") :: Check<EnumItem>

--[=[
	Ensures Roblox Enums type.
	@within T
	@function Enums
	@param value any
	@return boolean
	@return string?
]=]
t.Enums = t.typeof("Enums") :: Check<Enums>

--[=[
	Ensures Roblox Faces type.
	@within T
	@function Faces
	@param value any
	@return boolean
	@return string?
]=]
t.Faces = t.typeof("Faces") :: Check<Faces>

--[=[
	Ensures Roblox FloatCurveKey type.
	@within T
	@function FloatCurveKey
	@param value any
	@return boolean
	@return string?
]=]
t.FloatCurveKey = t.typeof("FloatCurveKey") :: Check<FloatCurveKey>

--[=[
	Ensures Roblox Font type.
	@within T
	@function Font
	@param value any
	@return boolean
	@return string?
]=]
t.Font = t.typeof("Font") :: Check<Font>

--[=[
	Ensures Roblox Instance type.
	@within T
	@function Instance
	@param value any
	@return boolean
	@return string?
]=]
t.Instance = t.typeof("Instance") :: Check<Instance>

--[=[
	Ensures Roblox NumberRange type.
	@within T
	@function NumberRange
	@param value any
	@return boolean
	@return string?
]=]
t.NumberRange = t.typeof("NumberRange") :: Check<NumberRange>

--[=[
	Ensures Roblox NumberSequence type.
	@within T
	@function NumberSequence
	@param value any
	@return boolean
	@return string?
]=]
t.NumberSequence = t.typeof("NumberSequence") :: Check<NumberSequence>

--[=[
	Ensures Roblox NumberSequenceKeypoint type.
	@within T
	@function NumberSequenceKeypoint
	@param value any
	@return boolean
	@return string?
]=]
t.NumberSequenceKeypoint = t.typeof("NumberSequenceKeypoint") :: Check<NumberSequenceKeypoint>

--[=[
	Ensures Roblox OverlapParams type.
	@within T
	@function OverlapParams
	@param value any
	@return boolean
	@return string?
]=]
t.OverlapParams = t.typeof("OverlapParams") :: Check<OverlapParams>

--[=[
	Ensures Roblox PathWaypoint type.
	@within T
	@function PathWaypoint
	@param value any
	@return boolean
	@return string?
]=]
t.PathWaypoint = t.typeof("PathWaypoint") :: Check<PathWaypoint>

--[=[
	Ensures Roblox PhysicalProperties type.
	@within T
	@function PhysicalProperties
	@param value any
	@return boolean
	@return string?
]=]
t.PhysicalProperties = t.typeof("PhysicalProperties") :: Check<PhysicalProperties>

--[=[
	Ensures Roblox Random type.
	@within T
	@function Random
	@param value any
	@return boolean
	@return string?
]=]
t.Random = t.typeof("Random") :: Check<Random>

--[=[
	Ensures Roblox Ray type.
	@within T
	@function Ray
	@param value any
	@return boolean
	@return string?
]=]
t.Ray = t.typeof("Ray") :: Check<Ray>

--[=[
	Ensures Roblox RaycastParams type.
	@within T
	@function RaycastParams
	@param value any
	@return boolean
	@return string?
]=]
t.RaycastParams = t.typeof("RaycastParams") :: Check<RaycastParams>

--[=[
	Ensures Roblox RaycastResult type.
	@within T
	@function RaycastResult
	@param value any
	@return boolean
	@return string?
]=]
t.RaycastResult = t.typeof("RaycastResult") :: Check<RaycastResult>

--[=[
	Ensures Roblox RBXScriptConnection type.
	@within T
	@function RBXScriptConnection
	@param value any
	@return boolean
	@return string?
]=]
t.RBXScriptConnection = t.typeof("RBXScriptConnection") :: Check<RBXScriptConnection>

--[=[
	Ensures Roblox RBXScriptSignal type.
	@within T
	@function RBXScriptSignal
	@param value any
	@return boolean
	@return string?
]=]
t.RBXScriptSignal = t.typeof("RBXScriptSignal") :: Check<RBXScriptSignal>

--[=[
	Ensures Roblox Rect type.
	@within T
	@function Rect
	@param value any
	@return boolean
	@return string?
]=]
t.Rect = t.typeof("Rect") :: Check<Rect>

--[=[
	Ensures Roblox Region3 type.
	@within T
	@function Region3
	@param value any
	@return boolean
	@return string?
]=]
t.Region3 = t.typeof("Region3") :: Check<Region3>

--[=[
	Ensures Roblox Region3int16 type.
	@within T
	@function Region3int16
	@param value any
	@return boolean
	@return string?
]=]
t.Region3int16 = t.typeof("Region3int16") :: Check<Region3int16>

--[=[
	Ensures Roblox TweenInfo type.
	@within T
	@function TweenInfo
	@param value any
	@return boolean
	@return string?
]=]
t.TweenInfo = t.typeof("TweenInfo") :: Check<TweenInfo>

--[=[
	Ensures Roblox UDim type.
	@within T
	@function UDim
	@param value any
	@return boolean
	@return string?
]=]
t.UDim = t.typeof("UDim") :: Check<UDim>

--[=[
	Ensures Roblox UDim2 type.
	@within T
	@function UDim2
	@param value any
	@return boolean
	@return string?
]=]
t.UDim2 = t.typeof("UDim2") :: Check<UDim2>

--[=[
	Ensures Roblox Vector2 type.
	@within T
	@function Vector2
	@param value any
	@return boolean
	@return string?
]=]
t.Vector2 = t.typeof("Vector2") :: Check<Vector2>

--[=[
	Ensures Roblox Vector2int16 type.
	@within T
	@function Vector2int16
	@param value any
	@return boolean
	@return string?
]=]
t.Vector2int16 = t.typeof("Vector2int16") :: Check<Vector2int16>

--[=[
	Ensures Roblox Vector3 type.
	@within T
	@function Vector3
	@param value any
	@return boolean
	@return string?
]=]
t.Vector3 = t.typeof("Vector3") :: Check<Vector3>

--[=[
	Ensures Roblox Vector3int16 type.
	@within T
	@function Vector3int16
	@param value any
	@return boolean
	@return string?
]=]
t.Vector3int16 = t.typeof("Vector3int16") :: Check<Vector3int16>

--[=[
	@function literal
	@within T
	Ensures value is a given literal value. When given multiple arguments,
	creates a union of the provided literals.

	```lua
	local stateCheck = t.literal("idle", "running")
	print(stateCheck("idle")) --> true
	```

	@param ... any -- The literal value(s) to match
	@return Check
]=]
function t.literal<L>(...: L): Check<L>
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
	@function exactly
	@within T
	@deprecated Use `t.literal` instead.
	@param ... any -- The literal value(s) to match
	@return Check<T>
]=]
t.exactly = t.literal

--[=[
	@within T
	@function keyOf
	Returns a `t.union` of each key in the table as a `t.literal`.

	```lua
	local isMode = t.keyOf({ Easy = true, Hard = true })
	print(isMode("Easy")) --> true
	```

	@param keyTable {[K]: any} -- The table whose keys are the allowed values
	@return Check<K>
]=]
function t.keyOf<K>(keyTable: { [K]: any }): Check<K>
	local keys = {}
	local length = 0
	for key in pairs(keyTable) do
		length = length + 1
		keys[length] = key
	end
	return t.literal(table.unpack(keys, 1, length))
end

--[=[
	@within T
	@function valueOf
	Returns a `t.union` of each value in the table as a `t.literal`.

	```lua
	local isRank = t.valueOf({ Bronze = 1, Silver = 2 })
	print(isRank(2)) --> true
	```

	@param valueTable {[any]: V} -- The table whose values are the allowed values
	@return Check
]=]
function t.valueOf<V>(valueTable: { [any]: V }): Check<V>
	local values = {}
	local length = 0
	for _, value in pairs(valueTable) do
		length = length + 1
		values[length] = value
	end
	return t.literal(table.unpack(values, 1, length))
end

--[=[
	@within T
	@function integer
	Ensures value is an integer (whole number).

	```lua
	print(t.integer(8)) --> true
	print(t.integer(8.5)) --> false, "integer expected, got 8.5"
	```

	@param value any
	@return boolean
	@return string?
]=]
function t.integer(value: unknown): (boolean, string?)
	local success, errMsg = t.number(value)
	if not success then
		return false, errMsg or ""
	end
	if (value :: number) % 1 == 0 then
		return true :: any
	else
		return false, string.format("integer expected, got %s", tostring(value))
	end
end
t.integer = (t.integer :: any) :: Check<number>

--[=[
	@within T
	@function integerMin
	Ensures value is an integer where `min <= value`.

	```lua
	local atLeastTen = t.integerMin(10)
	print(atLeastTen(12)) --> true
	```

	@param min number -- The inclusive minimum bound
	@return Check
]=]
function t.integerMin(min: number): Check<number>
	assert(t.integer(min))
	return function(value: any): (boolean, string?)
		local success, errMsg = t.integer(value)
		if not success then
			return false, errMsg or ""
		end
		if (value :: number) >= min then
			return true :: any
		else
			return false, string.format("integer >= %s expected, got %s", tostring(min), tostring(value))
		end
	end
end

--[=[
	@within T
	@function integerMax
	Ensures value is an integer where `value <= max`.

	```lua
	local atMostTen = t.integerMax(10)
	print(atMostTen(8)) --> true
	```

	@param max number -- The inclusive maximum bound
	@return Check
]=]
function t.integerMax(max: number): Check<number>
	assert(t.integer(max))
	return function(value: any): (boolean, string?)
		local success, errMsg = t.integer(value)
		if not success then
			return false, errMsg or ""
		end
		if (value :: number) <= max then
			return true :: any
		else
			return false, string.format("integer <= %s expected, got %s", tostring(max), tostring(value))
		end
	end
end

--[=[
	@within T
	@function integerMinExclusive
	Ensures value is an integer where `min < value`.

	```lua
	local positive = t.integerMinExclusive(0)
	print(positive(1)) --> true
	```

	@param min number -- The exclusive minimum bound
	@return Check
]=]
function t.integerMinExclusive(min: number): Check<number>
	assert(t.integer(min))
	return function(value: any): (boolean, string?)
		local success, errMsg = t.integer(value)
		if not success then
			return false, errMsg or ""
		end
		if min < (value :: number) then
			return true :: any
		else
			return false, string.format("integer > %s expected, got %s", tostring(min), tostring(value))
		end
	end
end

--[=[
	@within T
	@function integerMaxExclusive
	Ensures value is an integer where `value < max`.

	```lua
	local belowTen = t.integerMaxExclusive(10)
	print(belowTen(9)) --> true
	```

	@param max number -- The exclusive maximum bound
	@return Check
]=]
function t.integerMaxExclusive(max: number): Check<number>
	assert(t.integer(max))
	return function(value: any): (boolean, string?)
		local success, errMsg = t.integer(value)
		if not success then
			return false, errMsg or ""
		end
		if (value :: number) < max then
			return true :: any
		else
			return false, string.format("integer < %s expected, got %s", tostring(max), tostring(value))
		end
	end
end

--[=[
	Ensures value is an integer greater than 0.
	@within T
	@function integerPositive
	@param value any
	@return boolean
	@return string?
]=]
t.integerPositive = t.integerMinExclusive(0) :: Check<number>

--[=[
	Ensures value is an integer less than 0.
	@within T
	@function integerNegative
	@param value any
	@return boolean
	@return string?
]=]
t.integerNegative = t.integerMaxExclusive(0) :: Check<number>

--[=[
	@within T
	@function integerConstrained
	Ensures value is an integer where `min <= value <= max`.

	```lua
	local levelCheck = t.integerConstrained(1, 100)
	print(levelCheck(25)) --> true
	```

	@param min number -- The inclusive minimum bound
	@param max number -- The inclusive maximum bound
	@return Check
]=]
function t.integerConstrained(min: number, max: number): Check<number>
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
	@within T
	@function integerConstrainedExclusive
	Ensures value is an integer where `min < value < max`.

	```lua
	local bounded = t.integerConstrainedExclusive(0, 10)
	print(bounded(5)) --> true
	```

	@param min number -- The exclusive minimum bound
	@param max number -- The exclusive maximum bound
	@return Check
]=]
function t.integerConstrainedExclusive(min: number, max: number): Check<number>
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
	@within T
	@function numberMin
	Ensures value is a number where `min <= value`.

	```lua
	local atLeastTen = t.numberMin(10)
	print(atLeastTen(12)) --> true
	```

	@param min number -- The inclusive minimum bound
	@return Check
]=]
function t.numberMin(min: number): Check<number>
	return function(value: any): (boolean, string?)
		local success, errMsg = t.number(value)
		if not success then
			return false, errMsg or ""
		end
		if (value :: number) >= min then
			return true :: any
		else
			return false, string.format("number >= %s expected, got %s", tostring(min), tostring(value))
		end
	end
end

--[=[
	@within T
	@function numberMax
	Ensures value is a number where `value <= max`.

	```lua
	local atMostTen = t.numberMax(10)
	print(atMostTen(8)) --> true
	```

	@param max number -- The inclusive maximum bound
	@return Check
]=]
function t.numberMax(max: number): Check<number>
	return function(value: any): (boolean, string?)
		local success, errMsg = t.number(value)
		if not success then
			return false, errMsg
		end
		if (value :: number) <= max then
			return true :: any
		else
			return false, string.format("number <= %s expected, got %s", tostring(max), tostring(value))
		end
	end
end

--[=[
	@within T
	@function numberMinExclusive
	Ensures value is a number where `min < value`.

	```lua
	local positive = t.numberMinExclusive(0)
	print(positive(1)) --> true
	```

	@param min number -- The exclusive minimum bound
	@return Check
]=]
function t.numberMinExclusive(min: number): Check<number>
	return function(value: any): (boolean, string?)
		local success, errMsg = t.number(value)
		if not success then
			return false, errMsg or ""
		end
		if min < (value :: number) then
			return true :: any
		else
			return false, string.format("number > %s expected, got %s", tostring(min), tostring(value))
		end
	end
end

--[=[
	@within T
	@function numberMaxExclusive
	Ensures value is a number where `value < max`.

	```lua
	local belowTen = t.numberMaxExclusive(10)
	print(belowTen(9)) --> true
	```

	@param max number -- The exclusive maximum bound
	@return Check
]=]
function t.numberMaxExclusive(max: number): Check<number>
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
	@within T
	@function numberPositive
	@param value any
	@return boolean
	@return string?
]=]
t.numberPositive = t.numberMinExclusive(0) :: Check<number>

--[=[
	Ensures value is a number less than 0.
	@within T
	@function numberNegative
	@param value any
	@return boolean
	@return string?
]=]
t.numberNegative = t.numberMaxExclusive(0) :: Check<number>

--[=[
	@within T
	@function numberConstrained
	Ensures value is a number where `min <= value <= max`.

	```lua
	local healthCheck = t.numberConstrained(0, 100)
	print(healthCheck(75)) --> true
	```

	@param min number -- The inclusive minimum bound
	@param max number -- The inclusive maximum bound
	@return Check
]=]
function t.numberConstrained(min: number, max: number): Check<number>
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
	@within T
	@function numberConstrainedExclusive
	Ensures value is a number where `min < value < max`.

	```lua
	local unitInterval = t.numberConstrainedExclusive(0, 1)
	print(unitInterval(0.5)) --> true
	```

	@param min number -- The exclusive minimum bound
	@param max number -- The exclusive maximum bound
	@return Check
]=]
function t.numberConstrainedExclusive(min: number, max: number): Check<number>
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
	@within T
	@function match
	Ensures value is a string matching the given Lua pattern.

	```lua
	local isSlug = t.match("^[a-z]+%-%d+$")
	print(isSlug("entry-42")) --> true
	```

	@param pattern string -- The Lua pattern to match against
	@return Check<string>
]=]
function t.match(pattern: string): Check<string>
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
	@within T
	@function optional
	Ensures value is either nil or passes the given check.

	```lua
	local maybeString = t.optional(t.string)
	print(maybeString(nil)) --> true
	```

	@param check Check<T> -- The check to apply when the value is non-nil
	@return Check<T?>
]=]
function t.optional<T>(check: Check<T>): Check<T?>
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
	@within T
	@function where
	Refines an existing check with an additional predicate.

	```lua
	local nonEmptyString = t.where(t.string, function(value)
		return #value > 0, "string must not be empty"
	end)
	```

	@param check Check<T> -- The base check that must pass first
	@param predicate Predicate<T> -- Additional validation applied after `check`
	@return Check<T>
]=]
function t.where<T>(check: Check<T>, predicate: Predicate<T>): Check<T>
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

		return false, predicateErrMsg or "value failed refinement"
	end
end

--[=[
	@within T
	@function tuple
	Matches a tuple of values against a tuple of checks.

	```lua
	local fooArgs = t.tuple(t.string, t.number)
	print(fooArgs("score", 50)) --> true
	```

	@param ... Check -- The check for each tuple position, in order
	@return TupleCheck
]=]
function t.tuple(...: Check<any>): CheckTuple
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
	@within T
	@function strictTuple
	Matches a tuple of values against a tuple of checks and disallows excess arguments.

	```lua
	local createArgs = t.strictTuple(t.string, t.number)
	print(createArgs("score", 50)) --> true
	```

	@param ... Check -- The check for each tuple position, in order
	@return TupleCheck
]=]
function t.strictTuple(...: Check<any>): CheckTuple
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
	@within T
	@function keys
	Ensures all keys in a table pass the given check.

	```lua
	local stringKeys = t.keys(t.string)
	print(stringKeys({ Name = true })) --> true
	```

	@param check Check<K> -- The check applied to each key
	@return Check<{ [K]: unknown }>
]=]
function t.keys<K>(check: Check<K>): Check<{ [K]: unknown }>
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
	@within T
	@function values
	Ensures all values in a table pass the given check.

	```lua
	local numberValues = t.values(t.number)
	print(numberValues({ Coins = 10 })) --> true
	```

	@param check Check<V> -- The check applied to each value
	@return Check<{ [any]: V }>
]=]
function t.values<V>(check: Check<V>): Check<{ [any]: V }>
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
	@within T
	@function map<K, V>
	Ensures value is a table where all keys pass `keyCheck` and all values pass `valueCheck`.

	```lua
	local scoreMap = t.map(t.string, t.number)
	print(scoreMap({ Alpha = 10 })) --> true
	```

	@param keyCheck Check<K> -- Check applied to each key
	@param valueCheck Check<V> -- Check applied to each value
	@return Check<{ [K]: V }>
]=]
function t.map<K, V>(keyCheck: Check<K>, valueCheck: Check<V>): Check<{ [K]: V }>
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
	@within T
	@function set
	Ensures value is a set — a table where all keys pass `valueCheck` and all values are `true`.

	```lua
	local tagSet = t.set(t.string)
	print(tagSet({ Fast = true, Active = true })) --> true
	```

	@param valueCheck Check<K> -- Check applied to each key
	@return Check<{ [K]: true }>
]=]
function t.set<K>(valueCheck: Check<K>): Check<{ [K]: true }>
	return t.map(valueCheck, t.literal(true :: true))
end

do
	local arrayKeysCheck = t.keys(t.integer)

	--[=[
		@within T
		@function array
		Ensures value is a sequential array where every element passes the given check.

		## Example
		```lua
		local stringArray = t.array(t.string)
		print(stringArray({ "a", "b" })) --> true
		```

		@param check Check<T> -- The check applied to each element
		@return Check<{V}>
	]=]
	function t.array<V>(check: Check<V>): Check<{ V }>
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
		@within T
		@function strictArray
		Ensures value is an array with an exact sequence of element types.
		The array must not be longer than the number of provided checks.

		## Example
		```lua
		local playerTuple = t.strictArray(t.string, t.number)
		print(playerTuple({ "Builderman", 100 })) --> true
		```

		@param ... Check -- The checks for each array index, in order
		@return Check<{ any }>
	]=]
	-- NOTE: returns Check<{ any }> because Luau lacks variadic generics.
	-- Positional element types (e.g. Check<{ string, number }>) cannot be expressed without overloads.
	function t.strictArray(...: Check<any>): Check<{ any }>
		local valueTypes = { ... }
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
				local typeCheck = typeFn :: Check<any>
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
		@within T
		@function union
		Creates a union type that passes if any of the given checks pass.

		## Example
		```lua
		local stringOrNumber = t.union(t.string, t.number)
		print(stringOrNumber(5)) --> true
		```

		@param ... Check -- The checks to union
		@return Check
	]=]
	-- NOTE: returns Check<any> because Luau lacks variadic generics.
	-- t.union(t.string, t.number) cannot produce Check<string | number> at the type level.
	function t.union(...: Check<any>): Check<any>
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

	--[=[
		Alias for `t.union`.
		@within T
		@function some
		@deprecated Use `t.union` instead.
		@param ... Check<T> -- The checks to union
		@return Check<T>
	]=]
	t.some = t.union

	--[=[
		@within T
		@function intersection
		Creates an intersection type that passes only if all of the given checks pass.

		## Example
		```lua
		local positiveInteger = t.intersection(t.integer, t.numberPositive)
		print(positiveInteger(4)) --> true
		```

		@param ... Check -- The checks to intersect
		@return Check<T>
	]=]
	-- NOTE: returns Check<any> because Luau lacks variadic generics.
	-- t.intersection(t.integer, t.numberPositive) cannot produce Check<number & integer> at the type level.
	function t.intersection(...: Check<any>): Check<any>
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

	--[=[
		Alias for `t.intersection`.
		@within T
		@function every
		@deprecated Use `t.intersection` instead.
		@param ... Check<T> -- The checks to intersect
		@return Check<T>
	]=]
	t.every = t.intersection
end

--[=[
	@within T
	@function unionOf
	Two-argument typed union. Returns `Check<A | B>`, which `t.union` cannot express
	due to Luau's lack of variadic generics.

	```lua
	local stringOrNumber = t.unionOf(t.string, t.number)
	-- type: Check<string | number>
	```

	@param checkA Check<A>
	@param checkB Check<B>
	@return Check<A | B>
]=]
function t.unionOf<A, B>(checkA: Check<A>, checkB: Check<B>): Check<A | B>
	return t.union(checkA, checkB) :: Check<A | B>
end

--[=[
	@within T
	@function intersectionOf
	Two-argument typed intersection. Returns `Check<A & B>`, which `t.intersection` cannot express
	due to Luau's lack of variadic generics.

	```lua
	local positiveInt = t.intersectionOf(t.integer, t.numberPositive)
	-- type: Check<number & number>
	```

	@param checkA Check<A>
	@param checkB Check<B>
	@return Check<A & B>
]=]
function t.intersectionOf<A, B>(checkA: Check<A>, checkB: Check<B>): Check<A & B>
	return t.intersection(checkA, checkB) :: Check<A & B>
end

do
	local checkInterface = t.map(t.any, t.callback)

	--[=[
		@within T
		@function interface
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
		@return Check<any>
	]=]
	function t.interface(checkTable: { [any]: Check<any> }): Check<any>
		assert(checkInterface(checkTable))
		return function(value: any): (boolean, string?)
			local tableSuccess, tableErrMsg = t.table(value)
			if tableSuccess == false then
				return false, tableErrMsg or ""
			end
			for key, check in pairs(checkTable) do
				local success, errMsg = check(value[key])
				if success == false then
					if type(key) == "string" then
						return false, string.format("[interface] bad value for %s:\n\t%s", key :: string, errMsg or "")
					else
						return false, string.format("bad value for key %s:\n\t%s", type(key), errMsg or "")
					end
				end
			end
			return true :: any
		end
	end

	--[=[
		@within T
		@function partialInterface
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
		@return Check<any>
	]=]
	function t.partialInterface(checkTable: { [any]: Check<any> }): Check<any>
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
						if type(key) == "string" then
							return false,
								string.format("[partialInterface] bad value for %s:\n\t%s", key :: string, errMsg or "")
						else
							return false,
								string.format("bad value for key %s:\n\t%s", type(key), errMsg or "")
						end
					end
				end
			end
			return true :: any
		end
	end

	--[=[
		@within T
		@function strictInterface
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
		@return Check<any>
	]=]
	function t.strictInterface(checkTable: { [any]: Check<any> }): Check<any>
		assert(checkInterface(checkTable))
		return function(value: any): (boolean, string?)
			local tableSuccess, tableErrMsg = t.table(value)
			if tableSuccess == false then
				return false, tableErrMsg or ""
			end
			for key, check in pairs(checkTable) do
				local success, errMsg = check(value[key])
				if success == false then
					if type(key) == "string" then
						return false, string.format("[interface] bad value for %s:\n\t%s", key :: string, errMsg or "")
					else
						return false, string.format("bad value for key %s:\n\t%s", type(key), errMsg or "")
					end
				end
			end
			for key in pairs(value) do
				if not checkTable[key] then
					if type(key) == "string" then
						return false, string.format("[interface] unexpected field %q", key :: string)
					else
						return false, "[interface] unexpected field"
					end
				end
			end
			return true :: any
		end
	end
end

--[=[
	@within T
	@function instanceOf
	Ensures value is an Instance whose `ClassName` exactly matches the given class name.

	```lua
	local isFolder = t.instanceOf("Folder")
	print(isFolder(Instance.new("Folder"))) --> true
	```

	@param className string -- The exact class name to match
	@param childTable {[string]: Check}? -- Optional map of child names to checks
	@return Check<Instance>
]=]
function t.instanceOf(className: string, childTable: { [string]: Check<Instance> }?): Check<Instance>
	assert(t.string(className))
	local childrenCheck
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
				return false, childrenErrMsg or ""
			end
		end
		return true :: any
	end
end

--[=[
	Alias for `t.instanceOf`.
	@within T
	@function instance
	@deprecated Use `t.instanceOf` instead.
	@param className string -- The exact class name to match
	@param childTable {[string]: Check}? -- Optional map of child names to checks
	@return Check<Instance>
]=]
t.instance = t.instanceOf

--[=[
	@within T
	@function instanceIsA
	Ensures value is an Instance that passes `value:IsA(className)`.

	```lua
	local isGuiObject = t.instanceIsA("GuiObject")
	print(isGuiObject(Instance.new("Frame"))) --> true
	```

	@param className string -- The class name to use with `IsA`
	@param childTable {[string]: Check<Instance>}? -- Optional map of child names to checks
	@return Check<Instance>
]=]
function t.instanceIsA(className: string, childTable: { [string]: Check<Instance> }?): Check<Instance>
	assert(t.string(className))
	local childrenCheck
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
				return false, childrenErrMsg or ""
			end
		end
		return true :: any
	end
end

--[=[
	@within T
	@function enum
	Ensures value is an EnumItem belonging to the given Enum type.

	:::tip Choosing the right Enum check
	There are three related validators — use the one that matches how specific you need to be:

	- **`t.Enum`** — accepts an `Enum` *type object* (e.g. `Enum.Material`), not an item from it.
	  Use this when a function receives an enum category as a parameter.

	- **`t.EnumItem`** — accepts *any* `EnumItem`, from any enum.
	  Use this when you only care that the value is some enum item, regardless of which enum it belongs to.

	- **`t.itemOfEnum(Enum.X)`** — accepts an `EnumItem` that belongs to a *specific* enum.
	  Use this when you need the value to come from exactly one known enum (e.g. only `Enum.Material` items).
	:::

	Alias: `t.enum`

	```lua
	-- Only accepts Enum.Material items
	local isMaterial = t.itemOfEnum(Enum.Material)
	print(isMaterial(Enum.Material.Slate))  --> true
	print(isMaterial(Enum.KeyCode.A))       --> false

	-- Accepts any EnumItem from any enum
	print(t.EnumItem(Enum.Material.Slate))  --> true
	print(t.EnumItem(Enum.KeyCode.A))       --> true

	-- Accepts the Enum type object itself, not an item
	print(t.Enum(Enum.Material))            --> true
	print(t.Enum(Enum.Material.Slate))      --> false
	```

	@param enum Enum -- The Enum type to check against
	@return Check<EnumItem>
]=]
function t.itemOfEnum(enum: Enum): Check<EnumItem>
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
t.enum = t.itemOfEnum -- Alias for itemOfEnum

do
	local checkWrap = t.tuple(t.callback, t.callback)

	--[=[
		@within T
		@function wrap
		Wraps a callback with an argument-check assertion. The returned function
		will `assert` the check before forwarding to the original callback.

		## Example
		```lua
		local add = t.wrap(function(a, b)
			return a + b
		end, t.tuple(t.number, t.number))
		```

		@param callback (...any) -> ...any -- The function to wrap
		@param checkArgs TupleCheck -- The check asserted on the arguments
		@return (...any) -> ...any
	]=]
	function t.wrap<V..., R...>(callback: (V...) -> R..., checkArgs: CheckTuple<V...>): (V...) -> R...
		assert(checkWrap(callback, checkArgs))
		return function(...: any): ...any
			assert(checkArgs(...))
			return callback(...)
		end
	end
end

--[=[
	@within T
	@function strict
	Wraps a check in an `assert`, producing a function that throws on failure.

	```lua
	local assertString = t.strict(t.tuple(t.string))
	assertString("hello")
	```

	@param check TupleCheck -- The check to wrap
	@return (...any) -> ()
]=]
function t.strict<Args...>(check: CheckTuple<Args...>): (Args...) -> ()
	return function(...: Args...): ()
		assert(check(...))
	end
end

do
	local checkChildren = t.map(t.string, t.callback)

	--[=[
		@within T
		@function children
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
		@return Check<Instance>
	]=]
	function t.children(checkTable: { [string]: Check<any> }): Check<Instance>
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

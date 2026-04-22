<h2 align="center">
	<b>T</b><br>A Runtime Type Checker for Luau/Roblox
</h2>


`t` is a library of type validator functions that allow you to easily compose type definitions to check values against.

## Why?
When building large systems, it can often be difficult to find type mismatch bugs.\
Typechecking helps you ensure that your functions are recieving the appropriate types for their arguments.

In Roblox specifically, it is important to type check your Remote objects to ensure that exploiters aren't sending you bad data which can cause your server to error (and potentially crash!).

## Quick Start

```lua
local t = require(path.to.t)

local createPlayerArgs = t.tuple(
	t.string,
	t.numberConstrained(0, 100),
	t.optional(t.string)
)

local function createPlayer(name, health, team)
	assert(createPlayerArgs(name, health, team))
	-- name: string
	-- health: number in [0, 100]
	-- team: string?
end
```

## Basic Validators

Primitive checks:

- `t.boolean`
- `t.buffer`
- `t.thread`
- `t.callback`
- `t.none`
- `t.string`
- `t.table`
- `t.userdata`
- `t.vector`
- `t.number`
- `t.nan`

Roblox value types are also exposed directly, for example:

- `t.Instance`
- `t.CFrame`
- `t.Color3`
- `t.Vector3`
- `t.Enum`
- `t.EnumItem`
- ...etc

You can also build ad hoc checkers with:

- `t.type(typeName)`
- `t.typeof(typeName)`

```lua
local isVector3 = t.typeof("Vector3")
print(isVector3(Vector3.zero)) --> true
```

## Composition

- `t.any(value)`
- `t.literal(...)`
- `t.keyOf(keyTable)`
- `t.valueOf(valueTable)`
- `t.optional(check)`
- `t.where(check, predicate, errorMessage?)`
- `t.tuple(...)`
- `t.strictTuple(...)`
- `t.union(...)` / `t.some(...)`
- `t.intersection(...)` / `t.every(...)`

```lua
local nonEmptyString = t.where(t.string, function(value)
	return #value > 0, "string must not be empty"
end)

print(nonEmptyString("hello")) --> true
print(nonEmptyString("")) --> false, "string must not be empty"
```

## Tables and Arrays

- `t.keys(check)`
- `t.values(check)`
- `t.map(keyCheck, valueCheck)`
- `t.set(valueCheck)`
- `t.array(check)`
- `t.strictArray(...)`

```lua
local tagsCheck = t.set(t.string)
print(tagsCheck({ Fast = true, Active = true })) --> true
```

## Interfaces

- `t.interface(definition)`
- `t.partialInterface(definition)`
- `t.strictInterface(definition)`

`t.interface` requires each declared field and allows extra fields.

`t.partialInterface` validates declared fields only when they are present, which is useful for patch payloads and optional update objects.

`t.strictInterface` requires each declared field and rejects extra fields.

```lua
local playerPatch = t.partialInterface({
	Name = t.string,
	Health = t.numberConstrained(0, 100),
})

print(playerPatch({ Name = "Builderman" })) --> true
print(playerPatch({ Health = 150 })) --> false, "[partialInterface] bad value for Health: ..."
```

## Numbers and Strings

Numeric helpers:

- `t.integer`
- `t.integerMin(min)`
- `t.integerMax(max)`
- `t.integerMinExclusive(min)`
- `t.integerMaxExclusive(max)`
- `t.integerConstrained(min, max)`
- `t.integerConstrainedExclusive(min, max)`
- `t.integerPositive`
- `t.integerNegative`
- `t.numberMin(min)`
- `t.numberMax(max)`
- `t.numberMinExclusive(min)`
- `t.numberMaxExclusive(max)`
- `t.numberConstrained(min, max)`
- `t.numberConstrainedExclusive(min, max)`
- `t.numberPositive`
- `t.numberNegative`

String helpers:

- `t.match(pattern)`

## Roblox-Specific Validators

- `t.instanceOf(className, childTable?)`
- `t.instanceIsA(className, childTable?)`
- `t.children(checkTable)`
- `t.enum(enum)`

```lua
local buttonCheck = t.instanceIsA("GuiButton")
local materialCheck = t.enum(Enum.Material)
```

`t.children` fails if more than one relevant child has the same name.

## Function Helpers

- `t.wrap(callback, argCheck)`
- `t.strict(check)`

```lua
local add = t.wrap(function(a, b)
	return a + b
end, t.tuple(t.number, t.number))

print(add(2, 3)) --> 5
```

## Custom Validators

You can always compose your own validator directly:

```lua
local t = require(path.to.t)

local function isTaggedObject(value)
	local ok, err = t.table(value)
	if not ok then
		return false, err
	end

	if value.Tag ~= "Enemy" then
		return false, "Enemy-tagged table expected"
	end

	return true
end
```

## Return Contract

On failure you get `false` and an error string. On success you get `true` and the second result will be <i>void</i>, <b>NOT nil</b>. 
Do not rely on the exact number of returned values. This is done to keep compatibility with
the original T library by [osyrisrblx](https://github.com/osyrisrblx/t)

## Examples

See the contained spec file for a concrete set of examples covering primitives, composition, interfaces, Roblox-specific checks, and wrapper helpers.

--!strict
--[=[
	@class SchemaNavigator
	@ignore

	Resolves and validates path-based schema checks using T metadata
	introspection (`T.GetMeta`).
]=]

const PathHelpers = require("./PathHelpers")
const T = require("../T")

type Path = PathHelpers.Path

export type Check = (value: any) -> (boolean, string?)
export type CheckMeta =
	{ kind: "interface" | "strictInterface" | "partialInterface", fields: { [any]: Check } }
	| { kind: "optional", innerCheck: Check }
	| { kind: "array", valueCheck: Check }

const SchemaNavigator = {}

const function getMeta(check: Check): CheckMeta?
	return T.GetMeta(check) :: any
end

const function unwrapOptionalForTraversal(check: Check): Check
	local current = check
	while true do
		const meta = getMeta(current)
		if meta and meta.kind == "optional" then
			current = meta.innerCheck
		else
			break
		end
	end
	return current
end

--[=[
	@within SchemaNavigator
	Walks the schema's metadata tree along the given path and returns the
	`Check` that covers the node at that path, or `nil` if the path is not
	described by the schema (indicating the path is unconstrained).

	Optional wrappers are transparently unwrapped during traversal so that a
	field typed as `t.optional(t.interface(...))` is still navigable.

	@param schema Check -- The root schema check to navigate.
	@param path Path -- The path to resolve within the schema.
	@return Check? -- The check at the resolved path, or nil if unconstrained.
]=]
function SchemaNavigator.Navigate(schema: Check, path: Path): Check?
	const parsedPath = PathHelpers.ParsePath(path)
	local current: Check? = schema

	for _, segment in parsedPath do
		if not current then
			return nil
		end

		const traversable = unwrapOptionalForTraversal(current)
		const meta = getMeta(traversable)
		if not meta then
			return nil
		end

		if meta.kind == "interface" or meta.kind == "strictInterface" or meta.kind == "partialInterface" then
			current = meta.fields[segment]
		elseif meta.kind == "array" then
			if type(segment) ~= "number" then
				return nil
			end
			current = meta.valueCheck
		elseif meta.kind == "optional" then
			current = meta.innerCheck
		else
			error("Unsupported schema kind: " .. tostring(meta.kind))
		end
	end

	return current
end

--[=[
	@within SchemaNavigator
	Resolves the check at the given path within the schema (via `Navigate`)
	and runs it against `value`. Returns `true` when the path is unconstrained
	by the schema, so only paths explicitly described by the schema are
	enforced.

	@param schema Check -- The root schema check.
	@param path Path -- The path of the value being validated.
	@param value any -- The value to validate.
	@return boolean -- Whether the value passed validation.
	@return string? -- An error message when validation fails.
]=]
function SchemaNavigator.Validate(schema: Check, path: Path, value: any): (boolean, string?)
	const check = SchemaNavigator.Navigate(schema, path)
	if not check then
		return true :: any
	end

	const ok, err = check(value)
	if ok then
		return true :: any
	end

	return false, err or "Schema validation failed"
end

return SchemaNavigator

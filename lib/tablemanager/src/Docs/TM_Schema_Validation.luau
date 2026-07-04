--[=[
	@class TM Schema Validation

	A **schema** validates the shape of a [TableManager](/api/TableManager)'s data
	when the manager is created, so malformed data fails fast at construction rather
	than surfacing as a mysterious bug later.

	## Attaching a schema

	Pass `Config.Schema` a [`T`](/api/TableManager#T) check (the `T` runtime type
	library is re-exported as `TableManager.T`). The initial data is validated
	against it at construction time; a mismatch errors from `new`.

	```lua
	local T = TableManager.T

	local manager = TableManager.new({
		Player = { Name = "Alice", Level = 1 },
	}, {
		Schema = T.interface {
			Player = T.interface {
				Name = T.string,
				Level = T.number,
			},
		},
	})
	```

	Use `T.strictInterface` to also reject unexpected keys, and combinators like
	`T.array(T.number)` for collections:

	```lua
	Schema = T.strictInterface {
		Scores = T.array(T.number),
	}
	```

	## OnValidationFailed

	Provide `OnValidationFailed` to observe failures. It is called with
	`(path, value, err)` *before* the error is raised, which is useful for logging
	or telemetry.

	```lua
	local manager = TableManager.new(data, {
		Schema = schema,
		OnValidationFailed = function(path, value, err)
			warn(`validation failed at {table.concat(path, ".")}: {err}`)
		end,
	})
	```

	---
	### See also

	- **[TM Getting Started](/api/TM%20Getting%20Started)** — the config table at a glance.
	- **[TM Opaque Values](/api/TM%20Opaque%20Values)** — telling the diff engine to leave certain values alone.
	- **[TM Listeners & Fire Modes](/api/TM%20Listeners%20&%20Fire%20Modes)** — observing data once it's validated.
]=]

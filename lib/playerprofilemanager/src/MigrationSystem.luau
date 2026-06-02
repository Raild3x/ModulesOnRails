--!strict
-- Authors: Logan Hunt (Raildex)
-- Data migration system for PlayerProfileManager

--// Imports //--
const Types = require(script.Parent.Types)
const Constants = require(script.Parent.Constants)
const Logger = require(script.Parent.Logger)

type DataMigrator = Types.DataMigrator
type DataVersion = Types.DataVersion
type Profile = Types.Profile
type Logger = Logger.Logger
const VERSION_KEY = Constants.VERSION_KEY

--[=[
	@interface DataMigrator
	.FromVersion string | number
	.ToVersion string | number
	.Migrate (profileData: TFrom, userId: number) -> TTo

	Used to transform data from one version to another. Migrators must form a
	complete, unbroken chain from the oldest stored version to the current
	`DefaultDataSchema.__VERSION`. Gaps, duplicates, or a chain that does not
	terminate at the current version will cause an error at construction time.

	```lua
	-- Convert the deprecated 'Candy' currency into 'Gems' at a 1:10 rate
	local migrator = {
		FromVersion = "0.0.1",
		ToVersion = "0.0.2",
		Migrate = function(data: table, _userId: number)
			data.Gems = (data.Gems or 0) + (data.Candy or 0) * 10
			data.Candy = nil
			return data
		end,
	}
	```
]=]

--[[
	Finds the migrator whose FromVersion matches `fromVersion`, or nil if none.
	Duplicate detection is handled upfront by `validateMigratorChain`.
]]
local function lookupMigrator(migrators: { DataMigrator }, fromVersion: DataVersion): DataMigrator?
	for _, migration in ipairs(migrators) do
		if migration.FromVersion == fromVersion then
			return migration
		end
	end
	return nil
end

--[[
	Validates that `migrators` form a complete, linear chain ending at `targetVersion`.
	Errors at construction time so misconfiguration surfaces immediately rather than
	during a live player load.
]]
local function validateMigratorChain(migrators: { DataMigrator }, targetVersion: DataVersion)
	if #migrators == 0 then
		return
	end

	-- Build fromVersion -> migrator map; detect duplicates
	local fromMap: { [DataVersion]: DataMigrator } = {}
	for _, migration in ipairs(migrators) do
		if fromMap[migration.FromVersion] then
			error(
				`Duplicate migrator for version '{migration.FromVersion}'. Each version must have exactly one migrator.`
			)
		end
		fromMap[migration.FromVersion] = migration
	end

	-- Collect all ToVersions into a set
	local toVersionSet: { [DataVersion]: boolean } = {}
	for _, migration in ipairs(migrators) do
		toVersionSet[migration.ToVersion] = true
	end

	-- Entry point: a FromVersion that is not the ToVersion of any other migrator
	local entryVersion: DataVersion? = nil
	local entryCount = 0
	for fromVersion in fromMap do
		if not toVersionSet[fromVersion] then
			entryVersion = fromVersion
			entryCount += 1
		end
	end

	if entryCount == 0 then
		error("Migrator chain has a cycle — no entry point found.")
	elseif entryCount > 1 then
		error("Migrator chain has multiple disconnected entry points. The chain must be linear.")
	end

	-- Walk the chain from entry to end
	local visited: { [DataVersion]: boolean } = {}
	local current: DataVersion = entryVersion :: DataVersion
	while fromMap[current] do
		if visited[current] then
			error(`Migrator chain has a cycle at version '{current}'.`)
		end
		visited[current] = true
		current = (fromMap[current] :: DataMigrator).ToVersion
	end

	-- Chain must terminate at the target schema version
	if current ~= targetVersion then
		error(
			`Migrator chain ends at '{current}' but DefaultDataSchema["{VERSION_KEY}"] is '{targetVersion}'. The chain must end at the current schema version.`
		)
	end

	-- All migrators must be reachable (no orphaned branches)
	local visitedCount = 0
	for _ in visited do
		visitedCount += 1
	end
	if visitedCount ~= #migrators then
		error("Migrator chain has orphaned (unreachable) migrators.")
	end
end

--[[
	Walks the migration chain until the profile version matches the schema version.
	Relies on `validateMigratorChain` having verified the chain is complete at construction.
]]
local function migrateProfileData(
	migrators: { DataMigrator }?,
	targetVersion: DataVersion,
	userId: number,
	profile: Profile,
	logger: Logger
)
	if not migrators then
		return
	end

	while profile.Data[VERSION_KEY] ~= nil and profile.Data[VERSION_KEY] ~= targetVersion do
		local currentVersion = profile.Data[VERSION_KEY]
		local migrator = lookupMigrator(migrators, currentVersion)

		if not migrator then
			logger:Error(`No migrator found for userId {userId}'s data version '{currentVersion}'.`)
		end

		local nextVersion = migrator.ToVersion
		logger:Info(`Migrating userId {userId}'s data from {currentVersion} to {nextVersion}`)

		local newData: any?
		local ok, err = pcall(function()
			newData = migrator.Migrate(profile.Data, userId)
			local migratorName = `{currentVersion} -> {nextVersion}`
			if not newData then
				logger:Warn(
					`Migrator[{migratorName}] returned nil — assuming same table. Return the modified table to silence this warning.`
				)
			else
				logger:Assert(type(newData) == "table", `Migrator[{migratorName}] must return a table`)
			end
		end)

		if not ok then
			logger:Error(`Error migrating userId {userId}'s data: {err}`)
		end

		-- Mutate the existing data table in-place so ProfileStore's internal reference stays valid.
		-- If the migrator returned a distinct table, copy its contents back into the original.
		if newData and newData ~= profile.Data then
			for k in profile.Data do
				profile.Data[k] = nil
			end
			for k, v in newData do
				profile.Data[k] = v
			end
		end
		profile.Data[VERSION_KEY] = nextVersion
	end
end

return {
	validateMigratorChain = validateMigratorChain,
	migrateProfileData = migrateProfileData,
}

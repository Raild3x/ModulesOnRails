--!strict
-- Authors: Logan Hunt (Raildex)
-- Type definitions for PlayerProfileManager

--// Imports //--
const Packages = script.Parent.Parent
const ProfileTypeDef = require(script.Parent.ProfileTypeDef)
const Signal = require(Packages.Signal)
const Promise = require(Packages.Promise)

--// Base Types //--
type table = { [any]: any }
export type Promise = Promise.Promise
export type Profile = ProfileTypeDef.Profile
export type ProfileStore = ProfileTypeDef.ProfileStore

--// Signal Types //--
export type LoadSuccessSignal = Signal.Signal<(userId: number) -> (), number>
export type LoadFailureSignal = Signal.Signal<(userId: number, err: string) -> (), number, string>
export type ReleasingSignal = Signal.Signal<(userId: number, profile: Profile) -> (), number, Profile>

--// Save Callback Types //--
export type SaveCallbackType = "OnSave" | "OnLastSave"
export type SaveCallback = {
	callback: (profile: Profile) -> (),
	priority: number,
}
export type SaveCallbackBuckets = {
	OnSave: { SaveCallback },
	OnLastSave: { SaveCallback },
}
export type SaveCallbackConnection = {
	Disconnect: () -> (),
	Destroy: () -> (),
}

--// Wipe Lock Types //--
export type WipeLockValue = {
	acquiredAt: number,
	initiator: string,
}
export type WipeLockMap = {
	UpdateAsync: (
		self: WipeLockMap,
		key: string,
		transform: (existingValue: WipeLockValue?) -> WipeLockValue,
		expiration: number
	) -> WipeLockValue?,
	GetAsync: (self: WipeLockMap, key: string) -> WipeLockValue?,
	RemoveAsync: (self: WipeLockMap, key: string) -> (),
}

--// Data Migration Types //--
export type DataVersion = string | number
export type DataMigrator<TFrom = table, TTo = table> = {
	FromVersion: DataVersion,
	ToVersion: DataVersion,
	Migrate: (profileData: TFrom, userId: number) -> TTo,
}

--// Configuration Types //--
export type PPM_Config = {
	DataStoreKey: string?,
	DefaultDataSchema: { [string]: any },
	UseMock: boolean?,
	Migrator: { DataMigrator }?,
	GetPlayerKeyCallback: ((userId: number) -> string)?,
	ReconcileCallback: ((userId: number, profile: Profile) -> ())?,
	OnProfileLoadFailureCallback: ((userId: number, err: string) -> ())?,
	Debug: boolean?,
	LogLevel: number?,
	DebugProfileUserId: number?,
}

--// PlayerProfileManager Types //--
export type PlayerProfileManager = {
	ClassName: string,
	new: (config: PPM_Config) -> PlayerProfileManager,
	SAVE_PRIORITY: {
		HIGHEST: number,
		HIGH: number,
		NORMAL: number,
		LOW: number,
		LOWEST: number,
	},
	LogLevel: {
		Trace: number,
		Debug: number,
		Info: number,
		Warn: number,
		Error: number,
	},
	-- lifecycle signals
	PlayerProfileLoadSuccess: LoadSuccessSignal,
	PlayerProfileLoadFailure: LoadFailureSignal,
	PlayerProfileReleasing: ReleasingSignal,
	-- status methods
	IsLoaded: (self: PlayerProfileManager, playerOrUserId: Player | number) -> boolean,
	IsLoading: (self: PlayerProfileManager, playerOrUserId: Player | number) -> boolean,
	OnLoaded: (self: PlayerProfileManager, playerOrUserId: Player | number) -> Promise,
	GetPlayerStatus: (
		self: PlayerProfileManager,
		playerOrUserId: Player | number
	) -> {
		isLoaded: boolean,
		isLoading: boolean,
		profile: Profile?,
	},
	-- profile access methods
	GetProfile: (self: PlayerProfileManager, playerOrUserId: Player | number) -> Profile?,
	PromiseProfile: (self: PlayerProfileManager, playerOrUserId: Player | number) -> Promise,
	OnSave: (
		self: PlayerProfileManager,
		playerOrUserId: Player | number,
		callback: (profile: Profile) -> (),
		priority: number?
	) -> SaveCallbackConnection,
	OnLastSave: (
		self: PlayerProfileManager,
		playerOrUserId: Player | number,
		callback: (profile: Profile) -> (),
		priority: number?
	) -> SaveCallbackConnection,
	WipeProfile: (self: PlayerProfileManager, userId: number) -> Promise,
	-- lifecycle methods
	Destroy: (self: PlayerProfileManager) -> (),
}

return {}

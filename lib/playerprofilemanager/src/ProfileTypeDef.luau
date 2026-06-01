local _Signal = require(script.Parent.Parent.Signal)
type table = { [any]: any }

--[=[
    @private
    JSONAcceptable recursive type for DataStore-compatible values.
    Matches ProfileStore v1.0.3 export type.
]=]
export type JSONAcceptable = { JSONAcceptable } | { [string]: JSONAcceptable } | number | string | boolean | buffer

--[=[
    @private
    DataStoreKeyInfo structure returned by DataStore:GetAsync() and similar.
    Contains metadata about a DataStore key version.
]=]
export type DataStoreKeyInfo = {
	CreatedTime: number,
	UpdatedTime: number,
	Version: string,
	GetMetadata: (self: DataStoreKeyInfo) -> { [string]: any },
	GetUserIds: (self: DataStoreKeyInfo) -> { number },
}

--[=[
    @private
    @within PlayerProfileManager
    @interface Profile
    .Data table
    .LastSavedData table (Read-only)
    .FirstSessionTime number (Read-only)
    .SessionLoadCount number (Read-only)
    .Session {PlaceId: number, JobId: string}? (Read-only)
    .RobloxMetaData table
    .UserIds {number}
    .KeyInfo DataStoreKeyInfo
    .OnSave Signal
    .OnLastSave Signal
    .OnSessionEnd Signal
    .OnAfterSave Signal
    .ProfileStore ProfileStore
    .Key string
    
    .IsActive (Profile) -> boolean
    .Reconcile (Profile) -> ()
    .EndSession (Profile) -> ()
    .AddUserId (Profile, userId: number) -> ()
    .RemoveUserId (Profile, userId: number) -> ()
    .MessageHandler (Profile, fn: (message: JSONAcceptable, processed: () -> ()) -> ()) -> ()
    .Save (Profile) -> ()
    .SetAsync (Profile) -> ()

    Interface Type for ProfileStore v1.x Profiles.
]=]
export type Profile = {
	-- Data fields
	Data: table,
	LastSavedData: table, -- Read-only snapshot of last successful save
	FirstSessionTime: number, -- Read-only os.time() of first session
	SessionLoadCount: number, -- Read-only count of sessions started
	Session: { PlaceId: number, JobId: string }?, -- Read-only current session info or nil
	RobloxMetaData: table, -- Writable, auto-saved on release
	UserIds: { number }, -- Read-only, list of associated user IDs
	KeyInfo: DataStoreKeyInfo, -- Read-only DataStore key metadata

	-- Signals (better-signal v2.1.0 style)
	OnSave: {
		Connect: (self: any, listener: () -> ()) -> { Disconnect: (self: any) -> () },
	}, -- Fires before save
	OnLastSave: {
		Connect: (
			self: any,
			listener: (reason: "Manual" | "External" | "Shutdown") -> ()
		) -> { Disconnect: (self: any) -> () },
	}, -- Fires before final save (reason: "Manual" | "External" | "Shutdown")
	OnSessionEnd: {
		Connect: (self: any, listener: () -> ()) -> { Disconnect: (self: any) -> () },
	}, -- Fires when session ends
	OnAfterSave: {
		Connect: (self: any, listener: (last_saved_data: table) -> ()) -> { Disconnect: (self: any) -> () },
	}, -- Fires after successful save

	-- References
	ProfileStore: ProfileStore,
	Key: string,

	-- Methods
	IsActive: (Profile) -> boolean,
	Reconcile: (Profile) -> (),
	EndSession: (Profile) -> (),
	AddUserId: (Profile, userId: number) -> (),
	RemoveUserId: (Profile, userId: number) -> (),
	MessageHandler: (Profile, fn: (message: JSONAcceptable, processed: () -> ()) -> ()) -> (),
	Save: (Profile) -> (),
	SetAsync: (Profile) -> (),
}

--[=[
    @private
    @within PlayerProfileManager
    @interface ProfileStore
    .Mock ProfileStore
    .Name string
    .StartSessionAsync (self: ProfileStore, profile_key: string, params: {Steal: boolean?, Cancel: (() -> boolean)?}?) -> Profile?
    .MessageAsync (self: ProfileStore, profile_key: string, message: table) -> boolean
    .GetAsync (self: ProfileStore, profile_key: string, version: string?) -> Profile?
    .RemoveAsync (self: ProfileStore, profile_key: string) -> boolean

    Interface type for a ProfileStore v1.x store object returned by `ProfileStore.New`.
]=]
export type ProfileStore = {
	Mock: ProfileStore,
	Name: string,
	StartSessionAsync: (
		self: ProfileStore,
		profile_key: string,
		params: { Steal: boolean?, Cancel: (() -> boolean)? }?
	) -> Profile?,
	MessageAsync: (self: ProfileStore, profile_key: string, message: JSONAcceptable) -> boolean,
	GetAsync: (self: ProfileStore, profile_key: string, version: string?) -> Profile?,
	RemoveAsync: (self: ProfileStore, profile_key: string) -> boolean,
}

return {}

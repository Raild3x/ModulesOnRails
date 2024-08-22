local Signal = require(script.Parent.Parent.Signal)
type table = {[any]: any}
type Signal = Signal.ScriptSignal<any> & table

type DataStoreKeyInfo = any
type GlobalUpdates = any
type DataStoreSupportedValue = any

--[=[
    @private
    @within PlayerProfileManager
    @interface Profile
    .Data table
    .MetaData table
    .MetaTagsUpdated Signal
    .RobloxMetaData table
    .UserIds {number
    .KeyInfo DataStoreKeyInfo
    .KeyInfoUpdated Signal --Types.Signal<DataStoreKeyInfo>
    .GlobalUpdates GlobalUpdates
    .IsActive (Profile) -> boolean
    .GetMetaTag (Profile, tagName: string) -> any
    .Reconcile (Profile) -> ()
    .ListenToRelease (Profile, listener: (placeId: number?, game_job_Id: number?) -> ()) -> RBXScriptConnection
    .Release (Profile) -> ()
    .ListenToHopReady (Profile, listener: () -> ()) -> RBXScriptConnection
    .AddUserId (Profile, userId: number) -> ()
    .RemoveUserId (Profile, userId: number) -> ()
    .Identify (Profile) -> string
    .SetMetaTag (Profile, tagName: string, value: DataStoreSupportedValue) -> ()
    .Save (Profile) -> ()
    .ClearGlobalUpdates (Profile) -> ()
    .OverwriteAsync (Profile) -> ()

    Interface Type for Profiles
]=]
export type Profile = {
	Data: table;
	MetaData: {};
	MetaTagsUpdated: Signal;
	RobloxMetaData: {};
	UserIds: {number};
	KeyInfo: DataStoreKeyInfo;
	KeyInfoUpdated: Signal; --Types.Signal<DataStoreKeyInfo>;
	GlobalUpdates: GlobalUpdates;
	
	IsActive: (Profile) -> (boolean);
	GetMetaTag: (Profile, tagName: string) -> (any);
	Reconcile: (Profile) -> ();
	ListenToRelease: (Profile, listener: (placeId: number?, game_job_Id: number?) -> ()) -> (RBXScriptConnection);
	Release: (Profile) -> ();
	ListenToHopReady: (Profile, listener: () -> ()) -> (RBXScriptConnection);
	AddUserId: (Profile, userId: number) -> ();
	RemoveUserId: (Profile, userId: number) -> ();
	Identify: (Profile) -> (string);
	SetMetaTag: (Profile, tagName: string, value: DataStoreSupportedValue) -> ();
	Save: (Profile) -> ();
	ClearGlobalUpdates: (Profile) -> ();
	OverwriteAsync: (Profile) -> ();
}

return nil
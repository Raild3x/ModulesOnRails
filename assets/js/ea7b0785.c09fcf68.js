"use strict";(self.webpackChunkdocs=self.webpackChunkdocs||[]).push([[5574],{33414:e=>{e.exports=JSON.parse('{"functions":[{"name":"new","desc":"Creates a new PlayerProfileManager. This is a singleton class, so calling this function multiple\\ntimes will return the same instance. Takes a config table, see PPM_Config for more info on the individual\\nfields it supports.\\n\\n```lua\\nPlayerProfileManager.new({\\n    DataStoreKey = \\"PlayerData\\";\\n    DefaultDataSchema = {\\n        __VERSION = \\"0.0.0\\";\\n        Currency = 0;\\n    };\\n})\\n```","params":[{"name":"config","desc":"","lua_type":"PPM_Config"}],"returns":[{"desc":"","lua_type":"PlayerProfileManager\\r\\n"}],"function_type":"static","source":{"line":133,"path":"lib/playerprofilemanager/src/init.luau"}},{"name":"_reconcileProfile","desc":"","params":[{"name":"player","desc":"","lua_type":"Player"},{"name":"profile","desc":"","lua_type":"Profile"}],"returns":[],"function_type":"method","private":true,"source":{"line":178,"path":"lib/playerprofilemanager/src/init.luau"}},{"name":"_lookupMigrator","desc":"Looks up a migrator function for a specific version","params":[{"name":"fromVersion","desc":"","lua_type":"number"}],"returns":[{"desc":"","lua_type":"DataMigrator?\\r\\n"}],"function_type":"method","private":true,"source":{"line":190,"path":"lib/playerprofilemanager/src/init.luau"}},{"name":"_migrateProfileData","desc":"Attempts to migrate the player\'s profile data to the latest version.","params":[{"name":"player","desc":"","lua_type":"Player"},{"name":"profile","desc":"","lua_type":"Profile"}],"returns":[],"function_type":"method","private":true,"source":{"line":208,"path":"lib/playerprofilemanager/src/init.luau"}},{"name":"_generatePlayerKey","desc":"Generates a key for the player based on the GetPlayerKeyCallback if it exists.","params":[{"name":"playerOrUserId","desc":"","lua_type":"Player | number | string"}],"returns":[{"desc":"","lua_type":"string\\r\\n"}],"function_type":"method","private":true,"source":{"line":255,"path":"lib/playerprofilemanager/src/init.luau"}},{"name":"_attemptLoadProfile","desc":"Attempts to load the profile for the given player asyncronously.","params":[{"name":"player","desc":"","lua_type":"Player"}],"returns":[{"desc":"","lua_type":"Promise\\r\\n"}],"function_type":"method","private":true,"source":{"line":267,"path":"lib/playerprofilemanager/src/init.luau"}},{"name":"_createPlayerData","desc":"","params":[{"name":"player","desc":"","lua_type":"Player"}],"returns":[{"desc":"","lua_type":"Promise\\r\\n"}],"function_type":"method","private":true,"source":{"line":302,"path":"lib/playerprofilemanager/src/init.luau"}},{"name":"_PromisePlayerLoadEventFailure","desc":"Generates a promise that will reject when the player leaves or the profile fails to load.","params":[{"name":"player","desc":"","lua_type":"Player"}],"returns":[{"desc":"","lua_type":"Promise\\r\\n"}],"function_type":"method","private":true,"source":{"line":356,"path":"lib/playerprofilemanager/src/init.luau"}},{"name":"_PromisePlayerLoadEventSuccess","desc":"Generates a promise that will resolve when the player\'s profile is loaded.","params":[{"name":"player","desc":"","lua_type":"Player"}],"returns":[{"desc":"","lua_type":"Promise\\r\\n"}],"function_type":"method","private":true,"source":{"line":368,"path":"lib/playerprofilemanager/src/init.luau"}},{"name":"IsLoaded","desc":"Returns whether or not the player\'s profile is currently loaded.\\n\\n```lua\\nlocal isLoaded = PlayerProfileManager:IsLoaded(player)\\n```","params":[{"name":"player","desc":"","lua_type":"Player"}],"returns":[{"desc":"","lua_type":"boolean"}],"function_type":"method","source":{"line":386,"path":"lib/playerprofilemanager/src/init.luau"}},{"name":"OnLoaded","desc":"Returns a promise that will resolve when the player\'s profile is loaded.\\nRejects if the player leaves or the profile fails to load.\\n\\n```lua\\nPlayerProfileManager:OnLoaded(player):andThen(function()\\n    print(\\"Profile loaded for \\" .. player.Name)\\nend)\\n```","params":[{"name":"player","desc":"","lua_type":"Player"}],"returns":[{"desc":"","lua_type":"Promise<()>"}],"function_type":"method","source":{"line":403,"path":"lib/playerprofilemanager/src/init.luau"}},{"name":"WipeProfile","desc":"THIS METHOD IS UNFINISHED AND CURRENTLY CAUSES ERRORS.\\nWipes the player\'s profile from the data store.\\nUse this in cases where you need to reset a player\'s data or\\ncomply with a right to erasure request.","params":[{"name":"userId","desc":"","lua_type":"number"}],"returns":[{"desc":"","lua_type":"Promise\\r\\n"}],"function_type":"method","private":true,"unreleased":true,"source":{"line":422,"path":"lib/playerprofilemanager/src/init.luau"}},{"name":"GetProfile","desc":"Returns the player\'s profile, if it exists. May return nil if this players profile is not loaded.\\n\\n```lua\\nlocal profile: Profile? = PlayerProfileManager:GetProfile(player)\\n```","params":[{"name":"player","desc":"","lua_type":"Player"}],"returns":[{"desc":"","lua_type":"Profile?"}],"function_type":"method","source":{"line":458,"path":"lib/playerprofilemanager/src/init.luau"}},{"name":"PromiseProfile","desc":"Returns a promise that resolves with the player\'s profile when it is ready.\\nRejects if the player leaves or the profile fails to load.\\n\\n```lua\\nPlayerProfileManager:PromiseProfile(player):andThen(function(profile: Profile)\\n    print(\\"Profile loaded for \\" .. player.Name)\\nend)\\n```","params":[{"name":"player","desc":"","lua_type":"Player"}],"returns":[{"desc":"","lua_type":"Promise<Profile>"}],"function_type":"method","source":{"line":476,"path":"lib/playerprofilemanager/src/init.luau"}}],"properties":[],"types":[{"name":"DataMigrator","desc":"Used to Transform data from one version to another\\n```lua\\n-- Turn all the deprecated currency \'Candy\' into the new currency \'Gems\' at a  1:10 rate\\nlocal migrator = {\\n    FromVersion = \\"0.0.1\\",\\n    ToVersion = \\"0.0.2\\"\\n    Migrate = function(data: table, plr: Player)\\n        if not data.Gems then\\n            data.Gems = 0\\n        end\\n\\n        local candy = data.Candy or 0\\n        data.Gems += candy * 10\\n        data.Candy = nil\\n\\n        return data\\n    end\\n}\\n```","fields":[{"name":"FromVersion","lua_type":"string","desc":""},{"name":"ToVersion","lua_type":"string","desc":""},{"name":"Migrate","lua_type":"(profileData: table, profileOwner: Player) -> (table)","desc":""}],"source":{"line":62,"path":"lib/playerprofilemanager/src/init.luau"}},{"name":"PPM_Config","desc":"- **DataStoreKey** is the internal Key used for the PlayerData\'s DataStore.\\n- **DefaultDataSchema** is a template table that is used for reconciling the player\'s profile with. It is what new players are given if they dont have existing data.\\n- **UseMock** determines whether or not a Mock ProfileStore will be used.\\n- **Migrator** is a table of DataMigrators that are used to transform data from one version to another.\\n\\n- **GetPlayerKeyCallback** is a callback that is used to fetch the Key that each player\'s data is mapped to.\\n- **ReconcileCallback** is a callback that is called when the system attempts to reconcile the players profile. It will default to calling Profile:Reconcile if not provided.\\n- **OnProfileLoadFailureCallback** is a callback that is called if the player\'s data fails to load. It will default to kicking the player if not provided.","fields":[{"name":"DataStoreKey","lua_type":"string","desc":""},{"name":"DefaultDataSchema","lua_type":"table","desc":""},{"name":"UseMock","lua_type":"boolean?","desc":""},{"name":"Migrator","lua_type":"{DataMigrator}","desc":""},{"name":"GetPlayerKeyCallback","lua_type":"((player: Player) -> (string))?","desc":""},{"name":"ReconcileCallback","lua_type":"((player: Player, profile: Profile) -> ())?","desc":""},{"name":"OnProfileLoadFailureCallback","lua_type":"((player: Player, err: string) -> ())?","desc":""}],"source":{"line":103,"path":"lib/playerprofilemanager/src/init.luau"}},{"name":"Profile","desc":"Interface Type for Profiles","fields":[{"name":"Data","lua_type":"table","desc":""},{"name":"MetaData","lua_type":"table","desc":""},{"name":"MetaTagsUpdated","lua_type":"Signal","desc":""},{"name":"RobloxMetaData","lua_type":"table","desc":""},{"name":"UserIds","lua_type":"{number","desc":""},{"name":"KeyInfo","lua_type":"DataStoreKeyInfo","desc":""},{"name":"KeyInfoUpdated","lua_type":"Signal","desc":"Types.Signal<DataStoreKeyInfo>"},{"name":"GlobalUpdates","lua_type":"GlobalUpdates","desc":""},{"name":"IsActive","lua_type":"(Profile) -> boolean","desc":""},{"name":"GetMetaTag","lua_type":"(Profile, tagName: string) -> any","desc":""},{"name":"Reconcile","lua_type":"(Profile) -> ()","desc":""},{"name":"ListenToRelease","lua_type":"(Profile, listener: (placeId: number?, game_job_Id: number?) -> ()) -> RBXScriptConnection","desc":""},{"name":"Release","lua_type":"(Profile) -> ()","desc":""},{"name":"ListenToHopReady","lua_type":"(Profile, listener: () -> ()) -> RBXScriptConnection","desc":""},{"name":"AddUserId","lua_type":"(Profile, userId: number) -> ()","desc":""},{"name":"RemoveUserId","lua_type":"(Profile, userId: number) -> ()","desc":""},{"name":"Identify","lua_type":"(Profile) -> string","desc":""},{"name":"SetMetaTag","lua_type":"(Profile, tagName: string, value: DataStoreSupportedValue) -> ()","desc":""},{"name":"Save","lua_type":"(Profile) -> ()","desc":""},{"name":"ClearGlobalUpdates","lua_type":"(Profile) -> ()","desc":""},{"name":"OverwriteAsync","lua_type":"(Profile) -> ()","desc":""}],"private":true,"source":{"line":37,"path":"lib/playerprofilemanager/src/ProfileTypeDef.luau"}}],"name":"PlayerProfileManager","desc":"This class is responsible for managing player profiles. It provides simple interfaces for handling\\nplayer profile loading, reconciliation, and data migration.\\n\\nIt is a singleton class, so calling\\n`PlayerProfileManager.new` multiple times will return the same instance. It is recommended to\\ncreate a `PlayerDataService` to manage this class.","realm":["Server"],"source":{"line":15,"path":"lib/playerprofilemanager/src/init.luau"}}')}}]);
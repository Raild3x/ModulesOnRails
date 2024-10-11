"use strict";(self.webpackChunkdocs=self.webpackChunkdocs||[]).push([[2452],{27101:e=>{e.exports=JSON.parse('{"functions":[{"name":"newClassToken","desc":"Returns a ClassToken Symbol that is used for identifying the STR Class.\\nWe use unique symbols instead of strings to prevent accidental collisions.\\n\\n:::warning\\nThis may only be called once per unique string. The returned symbol should\\nbe used repeatedly instead of calling this function again. Calling this\\nfunction again with the same string will result in an error.\\n:::","params":[{"name":"tokenName","desc":"","lua_type":"string"}],"returns":[{"desc":"","lua_type":"ClassToken\\r\\n"}],"function_type":"static","source":{"line":283,"path":"lib/tablereplicator/src/Server/ServerTableReplicator.luau"}},{"name":"new","desc":"Creates a new ServerTableReplicator instance.\\nThe config must be given a TableManager instance and a ClassToken Symbol.\\n\\nA list of replication targets can be provided to specify which\\nplayers the STR should replicate to immediately. If no replication targets\\nare specified, the STR will not replicate to any players.\\n\\nYou can specify a Parent STR instead of giving ReplicationTargets and it will\\ninherit the replication targets of the top level STR.\\n\\nOptionally, a list of tags can be provided to help identify the STR. The\\ntags list will become immutable internally after the STR is created.\\n\\nEXAMPLE:\\n```lua\\n-- Some Server Script\\nlocal token = ServerTableReplicator.newClassToken(\\"PlayerData\\")\\n\\nPlayers.PlayerAdded:Connect(function(player)\\n    local manager = TableManager.new({\\n        Money = math.random(1, 100);\\n    })\\n\\n    local replicator = ServerTableReplicator.new({\\n        TableManager = manager,\\n        ClassToken = token,\\n        ReplicationTargets = \\"All\\",\\n        Tags = {UserId = player.UserId},\\n    })\\nend)\\n```\\n```lua\\n-- Some Client Script\\nClientTableReplicator.listenToNewReplicator(\\"PlayerData\\", function(replicator)\\n    print(\\"New PlayerData STR: \\", replicator:GetTag(\\"UserId\\"))\\n    print(\\"Money: \\", replicator:GetTableManager():Get(\\"Money\\"))\\nend)\\n```\\n\\n:::warning Top Level Replicators\\nA replicator must be given either a Parent Replicator or a list of ReplicationTargets.\\nIf both are given then it will produce an error.\\n\\nIf you give ReplicationTargets then that Replicator will be known as TopLevel. Only\\nTopLevel Replicators can have their ReplicationTargets manually changed.\\n\\nIf a Parent Replicator is given, the Child Replicator will inherit the replication targets of the Ancestor\\nTopLevel Replicator.\\n:::","params":[{"name":"config","desc":"","lua_type":"{\\r\\n    ClassToken: ClassToken,\\r\\n    TableManager: TableManager,\\r\\n    ReplicationTargets: ReplicationTargets?,\\r\\n    Parent: ServerTableReplicator?,\\r\\n    Tags: {[string]: any}?,\\r\\n    Client: {[string]: any}?,\\r\\n}"}],"returns":[],"function_type":"static","source":{"line":348,"path":"lib/tablereplicator/src/Server/ServerTableReplicator.luau"}},{"name":"Destroy","desc":"Destroys the Replicator on both the Server and any replicated Clients","params":[],"returns":[],"function_type":"method","source":{"line":470,"path":"lib/tablereplicator/src/Server/ServerTableReplicator.luau"}},{"name":"_InitListeners","desc":"","params":[],"returns":[],"function_type":"method","private":true,"source":{"line":482,"path":"lib/tablereplicator/src/Server/ServerTableReplicator.luau"}},{"name":"_GeneratePacket","desc":"Serializes the STR into a packet that can be sent to the client.","params":[],"returns":[{"desc":"","lua_type":"TRPacket\\r\\n"}],"function_type":"method","private":true,"source":{"line":527,"path":"lib/tablereplicator/src/Server/ServerTableReplicator.luau"}},{"name":"_StopReplicatingToTargets","desc":"Tells the client to stop replicating to the targets.","params":[{"name":"targets","desc":"","lua_type":"CanBeArray<Player>"}],"returns":[],"function_type":"method","private":true,"source":{"line":540,"path":"lib/tablereplicator/src/Server/ServerTableReplicator.luau"}},{"name":"_StartReplicatingToTargets","desc":"Tries to immediately replicate to the targets if not replicated already.","params":[{"name":"targets","desc":"","lua_type":"CanBeArray<Player>"}],"returns":[],"function_type":"method","private":true,"source":{"line":561,"path":"lib/tablereplicator/src/Server/ServerTableReplicator.luau"}},{"name":"RegisterRemoteSignal","desc":"Registers a new reliable remote signal.","params":[{"name":"signalName","desc":"","lua_type":"string"}],"returns":[],"function_type":"method","private":true,"unreleased":true,"source":{"line":597,"path":"lib/tablereplicator/src/Server/ServerTableReplicator.luau"}},{"name":"RegisterRemoteUnreliableSignal","desc":"Registers a new unreliable remote signal.","params":[{"name":"signalName","desc":"","lua_type":"string"}],"returns":[],"function_type":"method","private":true,"unreleased":true,"source":{"line":607,"path":"lib/tablereplicator/src/Server/ServerTableReplicator.luau"}},{"name":"GetRemoteSignal","desc":"Gets an existing RemoteSignal by name. Can be either reliable or unreliable.","params":[{"name":"signalName","desc":"","lua_type":"string"}],"returns":[{"desc":"","lua_type":"ServerCustomRemote\\r\\n"}],"function_type":"method","private":true,"unreleased":true,"source":{"line":617,"path":"lib/tablereplicator/src/Server/ServerTableReplicator.luau"}},{"name":"RegisterRemoteFunction","desc":"","params":[{"name":"fnName","desc":"","lua_type":"string"},{"name":"fn","desc":"","lua_type":"(...any) -> ...any"}],"returns":[],"function_type":"method","private":true,"unreleased":true,"source":{"line":627,"path":"lib/tablereplicator/src/Server/ServerTableReplicator.luau"}},{"name":"IsReplicatingToAll","desc":"Returns whether or not this STR is replicating to all current and future players.","params":[],"returns":[{"desc":"","lua_type":"boolean\\r\\n"}],"function_type":"method","source":{"line":637,"path":"lib/tablereplicator/src/Server/ServerTableReplicator.luau"}},{"name":"IsReplicationTarget","desc":"Checks whether the player is a valid target for replication.\\nNot whether the player is currently being replicated to.","params":[{"name":"player","desc":"","lua_type":"Player"}],"returns":[{"desc":"","lua_type":"boolean\\r\\n"}],"function_type":"method","source":{"line":645,"path":"lib/tablereplicator/src/Server/ServerTableReplicator.luau"}},{"name":"GetReplicationTargets","desc":"Gets the list of Players that this Replicator is attempting to replicate to.","params":[],"returns":[{"desc":"","lua_type":"{Player}\\r\\n"}],"function_type":"method","source":{"line":659,"path":"lib/tablereplicator/src/Server/ServerTableReplicator.luau"}},{"name":"GetActiveReplicationTargets","desc":"Gets the list of Players that this Replicator is *currently* replicating to.\\nThis is different from GetReplicationTargets as it does not include pending replication targets.","params":[],"returns":[{"desc":"","lua_type":"{Player}\\r\\n"}],"function_type":"method","source":{"line":676,"path":"lib/tablereplicator/src/Server/ServerTableReplicator.luau"}},{"name":"Set","desc":"Shortcut to set a value in the TableManager.","params":[{"name":"...","desc":"","lua_type":"any"}],"returns":[],"function_type":"method","private":true,"source":{"line":692,"path":"lib/tablereplicator/src/Server/ServerTableReplicator.luau"}},{"name":"SetParent","desc":"Sets the Parent of this STR to the given STR.","params":[{"name":"newParent","desc":"","lua_type":"ServerTableReplicator"}],"returns":[],"function_type":"method","source":{"line":699,"path":"lib/tablereplicator/src/Server/ServerTableReplicator.luau"}},{"name":"DestroyFor","desc":"Removes a player or list of players from the replication targets.","params":[{"name":"targets","desc":"","lua_type":"ReplicationTargets"}],"returns":[],"function_type":"method","source":{"line":821,"path":"lib/tablereplicator/src/Server/ServerTableReplicator.luau"}},{"name":"ReplicateFor","desc":"Adds a player or list of players to the replication targets.","params":[{"name":"targets","desc":"","lua_type":"ReplicationTargets"}],"returns":[],"function_type":"method","source":{"line":856,"path":"lib/tablereplicator/src/Server/ServerTableReplicator.luau"}},{"name":"SetReplicationTargets","desc":"Overwrites the current replication targets with the new targets.","params":[{"name":"targets","desc":"","lua_type":"ReplicationTargets"}],"returns":[],"function_type":"method","source":{"line":891,"path":"lib/tablereplicator/src/Server/ServerTableReplicator.luau"}}],"properties":[{"name":"AddedActivePlayer","desc":"A signal that fires whenever a player starts being replicated to.\\nThis happens when their client requests the current data from the server.","lua_type":"Signal<Player>","source":{"line":166,"path":"lib/tablereplicator/src/Server/ServerTableReplicator.luau"}},{"name":"RemovedActivePlayer","desc":"A signal that fires whenever a player stops being replicated to.\\nThis happens when the player leaves the game.","lua_type":"Signal<Player>","private":true,"source":{"line":175,"path":"lib/tablereplicator/src/Server/ServerTableReplicator.luau"}},{"name":"All","desc":"A STR that replicates to all current and future players.\\nUsed as a global parent for child STRs that need a home and should\\nbe replicated to all current and future players. Do not modify\\nanything about this STR, only use it as a Parent.","lua_type":"ServerTableReplicator","source":{"line":950,"path":"lib/tablereplicator/src/Server/ServerTableReplicator.luau"}},{"name":"None","desc":"A STR that doesnt replicate to anyone.\\nUsed as a global parent for child STRs that shouldnt be replicated.\\nDo not modify anything about this STR, only use it as a Parent.","lua_type":"ServerTableReplicator","source":{"line":963,"path":"lib/tablereplicator/src/Server/ServerTableReplicator.luau"}}],"types":[{"name":"ReplicationTargets","desc":"The Player(s) that the STR should replicate to.\\nIf \\"All\\" is given then the STR will replicate to all current and future players.","lua_type":"\\"All\\" | Player | {Player}","source":{"line":87,"path":"lib/tablereplicator/src/Server/ServerTableReplicator.luau"}},{"name":"ClassToken","desc":"A unique symbol that identifies the STR Class.\\nThis is used to identify the STR Class when it is replicated to the client.\\nUse `.newClassToken` to generate an object of this type. Do NOT manually create\\nthe table.","lua_type":"{Name: string}","source":{"line":31,"path":"lib/tablereplicator/src/Shared/TableReplicatorUtil.luau"}}],"name":"ServerTableReplicator","desc":"ServerTableReplicator handles replication of a given TableManager object to the client.\\nThis system very closely follows the idea behind ReplicaService and should be familiar to\\nanyone who has used it.\\n\\nInherits from BaseTableReplicator. See BaseTableReplicator for inherited methods.","realm":["Server"],"source":{"line":13,"path":"lib/tablereplicator/src/Server/ServerTableReplicator.luau"}}')}}]);
"use strict";(self.webpackChunkdocs=self.webpackChunkdocs||[]).push([[3799],{60250:e=>{e.exports=JSON.parse('{"functions":[{"name":"new","desc":"Creates a new TableReplicatorSingleton.\\n\\n```lua\\nlocal ClientPlayerData = TableReplicatorSingleton.new {\\n    ClassTokenName = \\"PlayerData\\";\\n    DefaultDataSchema = Import(\\"PlayerDataSchema\\");\\n    ConditionFn = function(replicator)\\n        return replicator:GetTag(\\"UserId\\") == LocalPlayer.UserId\\n    end;\\n}\\n\\nreturn ClientPlayerData\\n```","params":[{"name":"config","desc":"","lua_type":"Config"}],"returns":[],"function_type":"static","source":{"line":80,"path":"lib/tablereplicator/src/Client/TableReplicatorSingleton.luau"}},{"name":"Get","desc":"Fetches the value at the path. An index can be provided to fetch the value at\\nthat index. If the value is not ready yet, it will return the value rom the\\ndefault schema if one was given. If the path is untraversable, it will return\\nnil.\\n\\n```lua\\nlocal coins = ClientPlayerData:Get(\\"Coins\\")\\nlocal thirdItem = ClientPlayerData:Get(\\"Inventory\\", 3) -- Equivalent to `ClientPlayerData:Get(\\"Inventory\\")[3]`\\n```","params":[{"name":"path","desc":"","lua_type":"Path"},{"name":"index","desc":"","lua_type":"number?"}],"returns":[{"desc":"","lua_type":"any?\\n"}],"function_type":"method","source":{"line":135,"path":"lib/tablereplicator/src/Client/TableReplicatorSingleton.luau"}},{"name":"Observe","desc":"Called immediately and then whenever the value at the path changes.\\nThe callback will be called with the new value.\\n\\n```lua\\nClientPlayerData:Observe(\\"Coins\\", function(newValue)\\n    print(\\"Coins changed to\\", newValue)\\nend)\\n```","params":[{"name":"path","desc":"","lua_type":"Path"},{"name":"callback","desc":"","lua_type":"(newValue: any?) -> ()"}],"returns":[{"desc":"","lua_type":"() -> ()\\n"}],"function_type":"method","source":{"line":164,"path":"lib/tablereplicator/src/Client/TableReplicatorSingleton.luau"}},{"name":"ListenToValueChange","desc":"Called when the value at the path is changed.\\nThe callback will be called with the new value.\\n\\n```lua\\nClientPlayerData:ListenToValueChange(\\"Coins\\", function(newValue)\\n    print(\\"Coins changed to\\", newValue)\\nend)\\n```","params":[{"name":"path","desc":"","lua_type":"Path"},{"name":"callback","desc":"","lua_type":"(...any) -> ()"}],"returns":[{"desc":"A function that, when called, will disconnect the listener.","lua_type":"function"}],"function_type":"method","source":{"line":182,"path":"lib/tablereplicator/src/Client/TableReplicatorSingleton.luau"}},{"name":"ListenToAnyChange","desc":"Called when the value at the path is changed through any means.\\nThis includes if the value is an array and a value in the array is changed, inserted, or removed.","params":[{"name":"path","desc":"","lua_type":"Path"},{"name":"callback","desc":"","lua_type":"(...any) -> ()"}],"returns":[{"desc":"","lua_type":"() -> ()\\n"}],"function_type":"method","source":{"line":204,"path":"lib/tablereplicator/src/Client/TableReplicatorSingleton.luau"}},{"name":"ToFusionState","desc":"Returns a Fusion State object that will automatically update when the value at\\nthe path changes. This is useful for when you want to use Fusion dependents\\nto respond to changes in the value.\\n\\n```lua\\nlocal coinsState = ClientPlayerData:ToFusionState(\\"Coins\\")\\n\\nNew \\"TextLabel\\" {\\n    Text = coinsState;\\n}\\n```","params":[{"name":"path","desc":"","lua_type":"Path"}],"returns":[{"desc":"","lua_type":"State<any>\\n"}],"function_type":"method","source":{"line":241,"path":"lib/tablereplicator/src/Client/TableReplicatorSingleton.luau"}},{"name":"GetTableManager","desc":"Gets the TableManager for the TableReplicatorSingleton. This will error if\\nthe TableManager is not ready yet.\\n\\n```lua\\nlocal TM = ClientPlayerData:GetTableManager()\\n```","params":[],"returns":[{"desc":"","lua_type":"TableManager\\n"}],"function_type":"method","source":{"line":262,"path":"lib/tablereplicator/src/Client/TableReplicatorSingleton.luau"}},{"name":"GetTableReplicator","desc":"Gets the TableReplicator for the TableReplicatorSingleton. This will error if\\nthe TableReplicator is not ready yet.\\n\\n```lua\\nlocal TR = ClientPlayerData:GetTableReplicator()\\n```","params":[],"returns":[{"desc":"","lua_type":"ClientTableReplicator\\n"}],"function_type":"method","source":{"line":275,"path":"lib/tablereplicator/src/Client/TableReplicatorSingleton.luau"}},{"name":"PromiseTableManager","desc":"Returns a promise that resolves with the TableManager when it is ready.\\n\\n```lua\\nClientPlayerData:PromiseTableManager():andThen(function(TM: TableManager)\\n    print(\\"TableManager is ready!\\")\\nend)\\n```","params":[],"returns":[{"desc":"","lua_type":"Promise<TableManager>"}],"function_type":"method","source":{"line":291,"path":"lib/tablereplicator/src/Client/TableReplicatorSingleton.luau"}},{"name":"PromiseTableReplicator","desc":"Returns a promise that resolves with the TableReplicator when it is ready.\\n\\n```lua\\nClientPlayerData:PromiseTableReplicator():andThen(function(TR: ClientTableReplicator)\\n    print(\\"TableReplicator is ready!\\")\\nend)\\n```","params":[],"returns":[{"desc":"","lua_type":"Promise<ClientTableReplicator>"}],"function_type":"method","source":{"line":308,"path":"lib/tablereplicator/src/Client/TableReplicatorSingleton.luau"}},{"name":"IsReady","desc":"Returns whether or not a valid Replicator has been found and hooked into.\\n\\n```lua\\nif ClientPlayerData:IsReady() then\\n    print(\\"We have a valid Replicator!\\")\\nend\\n```","params":[],"returns":[{"desc":"","lua_type":"boolean\\n"}],"function_type":"method","source":{"line":323,"path":"lib/tablereplicator/src/Client/TableReplicatorSingleton.luau"}},{"name":"OnReady","desc":"Returns a promise that resolves when the TableReplicatorSingleton is ready.\\n\\n```lua\\nClientPlayerData:OnReady():andThen(function()\\n    print(\\"Found a valid Replicator!\\")\\nend)\\n```","params":[],"returns":[{"desc":"","lua_type":"Promise<()>"}],"function_type":"method","source":{"line":338,"path":"lib/tablereplicator/src/Client/TableReplicatorSingleton.luau"}}],"properties":[],"types":[{"name":"Config","desc":"","fields":[{"name":"ClassTokenName","lua_type":"string","desc":"The name of the class token to listen for."},{"name":"DefaultDataSchema","lua_type":"table?","desc":"The default schema to use if the replicator is not ready yet."},{"name":"ConditionFn","lua_type":"((replicator: ClientTableReplicator) -> boolean)?","desc":"A function that returns whether or not the replicator is valid and should be bound."}],"source":{"line":59,"path":"lib/tablereplicator/src/Client/TableReplicatorSingleton.luau"}}],"name":"TableReplicatorSingleton","desc":"This class provides a system for creating easy access to a single TableReplicator\\nthat is guaranteed to exist. This is useful for when you want to access data, that\\nmay not have replicated yet, immediately. You provide a default schema to use if\\nthe TableReplicator is not ready yet.","realm":["Client"],"source":{"line":12,"path":"lib/tablereplicator/src/Client/TableReplicatorSingleton.luau"}}')}}]);
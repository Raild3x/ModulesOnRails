"use strict";(self.webpackChunkdocs=self.webpackChunkdocs||[]).push([[4724],{82669:e=>{e.exports=JSON.parse('{"functions":[{"name":"__iter","desc":"Iterates over all replicators that are currently in memory.\\n```lua\\nfor _, replicator in TableReplicator do\\n    print(replicator:GetServerId())\\nend\\n```","params":[],"returns":[],"function_type":"static","tags":["Metamethod"],"source":{"line":74,"path":"lib/tablereplicator/src/Shared/BaseTableReplicator.luau"}},{"name":"getFromServerId","desc":"Returns the replicator with the given id if one exists.","params":[{"name":"id","desc":"","lua_type":"Id"}],"returns":[{"desc":"","lua_type":"BaseTableReplicator?\\n"}],"function_type":"static","tags":["Static"],"source":{"line":146,"path":"lib/tablereplicator/src/Shared/BaseTableReplicator.luau"}},{"name":"forEach","desc":"forEach is a special function that allows you to run a function on all replicators that currently\\nexist or will exist that match the given condition.\\n\\n:::caution\\nThere are rare edge cases where if a Replicator is destroyed soon after it is created and you have deffered events,\\nit will be destroyed before the ReplicatorCreated signal fires. In this case you can set allowDestroyedReplicators to true\\nto allow destroyed replicators to be returned.\\n:::","params":[{"name":"condition","desc":"","lua_type":"SearchCondition"},{"name":"fn","desc":"","lua_type":"(replicator: BaseTableReplicator, manager: TableManager?) -> ()"},{"name":"allowDestroyedReplicators","desc":"","lua_type":"boolean?\\n"}],"returns":[],"function_type":"static","tags":["Static"],"source":{"line":165,"path":"lib/tablereplicator/src/Shared/BaseTableReplicator.luau"}},{"name":"promiseFirstReplicator","desc":"promiseFirstReplicator is a special function that allows you to run a function on the first replicator to satisfy\\nthe given condition. If no replicator currently exists that satisfies the condition then it will wait for one to be created.\\n\\n\\n```lua\\nBaseTableReplicator.promiseFirstReplicator(\\"Test\\")\\n```\\n:::caution\\nThere are rare edge cases where if a Replicator is destroyed soon after it is created and you have deffered events,\\nit will be destroyed before the ReplicatorCreated signal fires. In this case you can set allowDestroyedReplicators to true\\nto allow destroyed replicators to be returned.\\n:::","params":[{"name":"condition","desc":"","lua_type":"SearchCondition"},{"name":"allowDestroyedReplicators","desc":"","lua_type":"boolean?"}],"returns":[{"desc":"","lua_type":"Promise<BaseTableReplicator, TableManager?>"}],"function_type":"static","tags":["Static"],"source":{"line":218,"path":"lib/tablereplicator/src/Shared/BaseTableReplicator.luau"}},{"name":"getAll","desc":"Fetches all replicators that are currently in memory. This is very slow and should be used sparingly.","params":[{"name":"classTokenName","desc":"","lua_type":"string?"}],"returns":[{"desc":"","lua_type":"{BaseTableReplicator}\\n"}],"function_type":"static","tags":["Static"],"source":{"line":251,"path":"lib/tablereplicator/src/Shared/BaseTableReplicator.luau"}},{"name":"onNew","desc":"Listens for new replicators that are created with the given class token.","params":[{"name":"classToken","desc":"","lua_type":"CanBeArray<string | ClassToken>"},{"name":"fn","desc":"","lua_type":"(replicator: BaseTableReplicator) -> ()"}],"returns":[{"desc":"","lua_type":"() -> ()"}],"function_type":"static","tags":["Static"],"source":{"line":265,"path":"lib/tablereplicator/src/Shared/BaseTableReplicator.luau"}},{"name":"new","desc":"","params":[{"name":"config","desc":"","lua_type":"{\\n    ServerId: Id?;\\n    Tags: Tags?;\\n    TableManager: TableManager;\\n    IsTopLevel: boolean?;\\n}"}],"returns":[],"function_type":"static","tags":["Static"],"private":true,"source":{"line":296,"path":"lib/tablereplicator/src/Shared/BaseTableReplicator.luau"}},{"name":"Destroy","desc":"","params":[],"returns":[],"function_type":"method","private":true,"source":{"line":334,"path":"lib/tablereplicator/src/Shared/BaseTableReplicator.luau"}},{"name":"_FireCreationListeners","desc":"Fires the creation listeners for this replicator.","params":[],"returns":[],"function_type":"method","private":true,"source":{"line":348,"path":"lib/tablereplicator/src/Shared/BaseTableReplicator.luau"}},{"name":"GetTableManager","desc":"Gets the TableManager that is being replicated.","params":[],"returns":[{"desc":"","lua_type":"TableManager\\n"}],"function_type":"method","source":{"line":375,"path":"lib/tablereplicator/src/Shared/BaseTableReplicator.luau"}},{"name":"GetServerId","desc":"Returns the server id for this replicator.\\nOn the Server this is equivalent to :GetId()","params":[],"returns":[{"desc":"","lua_type":"Id\\n"}],"function_type":"method","source":{"line":383,"path":"lib/tablereplicator/src/Shared/BaseTableReplicator.luau"}},{"name":"GetTokenName","desc":"Fetches the name of the class token that this replicator is using.","params":[],"returns":[{"desc":"","lua_type":"string\\n"}],"function_type":"method","source":{"line":390,"path":"lib/tablereplicator/src/Shared/BaseTableReplicator.luau"}},{"name":"IsTopLevel","desc":"Returns whether or not this replicator is a top level replicator.\\nA top level replicator is a replicator that has no parent.\\nOnly top level replicators can have their ReplicationTargets set.","params":[],"returns":[{"desc":"","lua_type":"boolean\\n"}],"function_type":"method","source":{"line":399,"path":"lib/tablereplicator/src/Shared/BaseTableReplicator.luau"}},{"name":"GetParent","desc":"Returns the parent of this replicator if it has one.\\nIf this replicator is a top level replicator then this will return nil.","params":[],"returns":[{"desc":"","lua_type":"BaseTableReplicator?\\n"}],"function_type":"method","source":{"line":412,"path":"lib/tablereplicator/src/Shared/BaseTableReplicator.luau"}},{"name":"GetChildren","desc":"Returns the immediate children of this replicator.","params":[],"returns":[{"desc":"","lua_type":"{BaseTableReplicator}\\n"}],"function_type":"method","source":{"line":419,"path":"lib/tablereplicator/src/Shared/BaseTableReplicator.luau"}},{"name":"GetDescendants","desc":"Returns the descendants of this replicator.","params":[],"returns":[{"desc":"","lua_type":"{BaseTableReplicator}\\n"}],"function_type":"method","source":{"line":426,"path":"lib/tablereplicator/src/Shared/BaseTableReplicator.luau"}},{"name":"FindFirstChild","desc":"Finds the first child that satisfies the given condition.\\nThe condition can be a `function`, a `ClassToken`, a `string` representing a ClassToken\'s name, or a `Tags` dictionary.\\nIf recursive is true then it will search through all descendants.\\n```lua\\nlocal child = tr:FindFirstChild(function(child)\\n    local manager = child:GetTableManager()\\n    return manager:Get(\\"Test\\") == 1\\n})\\n```","params":[{"name":"condition","desc":"","lua_type":"SearchCondition"},{"name":"recursive","desc":"","lua_type":"boolean?"}],"returns":[{"desc":"","lua_type":"BaseTableReplicator?\\n"}],"function_type":"method","source":{"line":451,"path":"lib/tablereplicator/src/Shared/BaseTableReplicator.luau"}},{"name":"PromiseFirstChild","desc":"Returns a promise that resolves when the first child that satisfies the given function is found.\\n\\n```lua\\ntr:PromiseFirstChild(function(replicator)\\n    local manager = replicator:GetTableManager()\\n    return manager:Get(\\"Test\\") == 1\\n}):andThen(function(replicator)\\n    print(\\"Found child with data key \'Test\' equal to 1!\\")\\nend)\\n\\ntr:PromiseFirstChild(\\"Test\\"):andThen(function(replicator)\\n    print(\\"Found child with classtoken \'Test\'!\\")\\nend)\\n\\ntr:PromiseFirstChild({UserId == 12345}):andThen(function(replicator)\\n    print(\\"Found child with UserId Tag matching 12345!\\")\\nend)\\n```","params":[{"name":"condition","desc":"","lua_type":"SearchCondition"}],"returns":[{"desc":"","lua_type":"Promise<BaseTableReplicator>"}],"function_type":"method","source":{"line":493,"path":"lib/tablereplicator/src/Shared/BaseTableReplicator.luau"}},{"name":"GetTag","desc":"Returns the value of the given tag for this replicator.","params":[{"name":"tagKey","desc":"","lua_type":"string"}],"returns":[{"desc":"","lua_type":"any\\n"}],"function_type":"method","source":{"line":512,"path":"lib/tablereplicator/src/Shared/BaseTableReplicator.luau"}},{"name":"GetTags","desc":"Returns the tags dictionary for this replicator.","params":[],"returns":[{"desc":"","lua_type":"Tags\\n"}],"function_type":"method","source":{"line":519,"path":"lib/tablereplicator/src/Shared/BaseTableReplicator.luau"}},{"name":"IsSupersetOfTags","desc":"Checks whether or not the given tags are a subset of this replicator\'s tags.\\nELI5: Are all the given tags also on this replicator?\\nAliased as `:ContainsAllTags(tags)`\\n    ```lua\\nlocal tr = TableReplicator.new({\\n    Tags = {\\n        Test1 = 1,\\n        Test2 = 2,\\n    }\\n})\\n\\ntr:IsSupersetOfTags({\\n    Test1 = 1,\\n}) -- true\\n\\ntr:IsSupersetOfTags({\\n    Test2 = 2,\\n}) -- true\\n```","params":[{"name":"tags","desc":"","lua_type":"Tags"}],"returns":[{"desc":"","lua_type":"boolean\\n"}],"function_type":"method","source":{"line":544,"path":"lib/tablereplicator/src/Shared/BaseTableReplicator.luau"}},{"name":"IsSubsetOfTags","desc":"Checks whether or not this replicator\'s tags are a subset of the given tags.\\nELI5: Are all the tags on this replicator also on the given tags?\\nAliased as `:IsWithinTags(tags)`\\n```lua\\nlocal tr = TableReplicator.new({\\n    Tags = {\\n        Test1 = 1,\\n        Test2 = 2,\\n    }\\n})\\n\\ntr:IsSubsetOfTags({\\n    Test1 = 1,\\n    Test2 = 2,\\n    Test3 = 3,\\n}) -- true\\n\\ntr:IsSubsetOfTags({\\n    Test1 = 1,\\n}) -- false\\n```","params":[{"name":"tags","desc":"","lua_type":"Tags"}],"returns":[{"desc":"","lua_type":"boolean\\n"}],"function_type":"method","source":{"line":578,"path":"lib/tablereplicator/src/Shared/BaseTableReplicator.luau"}}],"properties":[{"name":"ReplicatorCreated","desc":"A signal that fires whenever a new replicator is created.","lua_type":"Signal<BaseTableReplicator>","source":{"line":84,"path":"lib/tablereplicator/src/Shared/BaseTableReplicator.luau"}}],"types":[{"name":"Id","desc":"The id of a replicator.","lua_type":"number","source":{"line":39,"path":"lib/tablereplicator/src/Shared/BaseTableReplicator.luau"}},{"name":"SearchCondition","desc":"A condition that can be used to filter replicators.\\nThe condition can be a `function`, a `ClassToken`, a `string` representing a ClassToken\'s name, or a `Tags` dictionary.\\n- If the condition is a function then it should return a boolean to indicate success.\\n- If the condition is a ClassToken then it will check if the replicator\'s class token matches the given token.\\n- If the condition is a string then it will check if the replicator\'s class token name matches the given string.\\n- If the condition is a Tags dictionary then it will check if the replicator\'s tags are a superset of the given tags.","lua_type":"string | ClassToken | Tags | (replicator: BaseTableReplicator, manager: TableManager?) -> (boolean)","source":{"line":101,"path":"lib/tablereplicator/src/Shared/BaseTableReplicator.luau"}},{"name":"Tags","desc":"The valid tag format that can be given to a TableReplicator.\\nThis table will become locked once given to a TableReplicator.\\nDo not attempt to modify it after the fact.\\n```lua\\nlocal tags = table.freeze {\\n    OwnerId = Player.UserId;\\n    ToolType = \\"Sword\\";\\n}\\n```","lua_type":"{[string]: any}","source":{"line":20,"path":"lib/tablereplicator/src/Shared/TableReplicatorUtil.luau"}}],"name":"BaseTableReplicator","desc":"Inherits from BaseObject.\\n\\nExposed Object Signals:\\n```lua\\n:GetSignal(\\"ParentChanged\\")\\n:GetSignal(\\"ChildAdded\\")\\n:GetSignal(\\"ChildRemoved\\")\\n```","source":{"line":15,"path":"lib/tablereplicator/src/Shared/BaseTableReplicator.luau"}}')}}]);
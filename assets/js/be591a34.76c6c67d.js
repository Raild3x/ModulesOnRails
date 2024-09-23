"use strict";(self.webpackChunkdocs=self.webpackChunkdocs||[]).push([[9686],{82205:e=>{e.exports=JSON.parse('{"functions":[{"name":"fromTemplate","desc":"Creates a ReplicatedTableSingleton object from the given template configuration.\\n\\nSee [TableReplicatorSingleton.new](TableReplicatorSingleton#new) for more information.","params":[],"returns":[],"function_type":"static","tags":["Static"],"source":{"line":90,"path":"lib/tablereplicator/src/Client/ClientTableReplicator.luau"}},{"name":"bind","desc":"Binds the given table to a ClientTableReplicator ClassName.","params":[{"name":"tblOrStr","desc":"","lua_type":"table | string"}],"returns":[{"desc":"","lua_type":"table\\n"}],"function_type":"static","private":true,"unreleased":true,"source":{"line":97,"path":"lib/tablereplicator/src/Client/ClientTableReplicator.luau"}},{"name":"_newReplicator","desc":"The CTR constructor. is private because it should not be called externally.","params":[{"name":"config","desc":"","lua_type":"{\\n    Id: Id;\\n    Parent: ClientTableReplicator?;\\n    TableManager: TableManager;\\n    ClassTokenName: string?;\\n    Tags: Tags?;\\n}"}],"returns":[],"function_type":"static","private":true,"source":{"line":135,"path":"lib/tablereplicator/src/Client/ClientTableReplicator.luau"}},{"name":"new","desc":"This method exists to catch people trying to do something they shouldnt.","params":[{"name":"...","desc":"","lua_type":"any"}],"returns":[],"function_type":"static","private":true,"source":{"line":173,"path":"lib/tablereplicator/src/Client/ClientTableReplicator.luau"}},{"name":"listenForNewReplicator","desc":"Listens for a new ClientTableReplicator of the given ClassName.","params":[{"name":"classTokenName","desc":"","lua_type":"string"},{"name":"fn","desc":"","lua_type":"(replicator: ClientTableReplicator) -> ()"}],"returns":[{"desc":"","lua_type":"() -> ()"}],"function_type":"static","source":{"line":181,"path":"lib/tablereplicator/src/Client/ClientTableReplicator.luau"}},{"name":"Destroy","desc":"Overrides the default Destroy method to prevent the user from destroying","params":[],"returns":[],"function_type":"method","private":true,"source":{"line":196,"path":"lib/tablereplicator/src/Client/ClientTableReplicator.luau"}},{"name":"_Destroy","desc":"This is the actual Destroy method.","params":[],"returns":[],"function_type":"method","private":true,"source":{"line":204,"path":"lib/tablereplicator/src/Client/ClientTableReplicator.luau"}},{"name":"requestServerData","desc":"Requests all the existing replicators from the server. This should only\\nbe called once, calling it multiple times will return the same promise.\\nAll replicator listeners should be registered before calling this method.","params":[],"returns":[{"desc":"","lua_type":"Promise\\n"}],"function_type":"static","source":{"line":315,"path":"lib/tablereplicator/src/Client/ClientTableReplicator.luau"}}],"properties":[],"types":[],"name":"ClientTableReplicator","desc":"Inherits from [BaseTableReplicator](#BaseTableReplicator)\\n\\n:::warning\\nYou must call `ClientTableReplicator.requestServerData()` in order to begin\\nreplication to the client. It should only be called ideally once and after\\nall listeners have been registered.\\n:::","realm":["Client"],"source":{"line":15,"path":"lib/tablereplicator/src/Client/ClientTableReplicator.luau"}}')}}]);
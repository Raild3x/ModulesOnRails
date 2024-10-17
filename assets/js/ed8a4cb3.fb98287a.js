"use strict";(self.webpackChunkdocs=self.webpackChunkdocs||[]).push([[386],{6188:e=>{e.exports=JSON.parse('{"functions":[{"name":"indexReady","desc":"Returns a promise that resolves when the ClientNetWire is ready for use and the index exists.\\nThe resolved value is the value of the index.","params":[{"name":"wireOrName","desc":"","lua_type":"ClientNetWire | string"},{"name":"idx","desc":"The index to wait for existence of","lua_type":"string"}],"returns":[{"desc":"","lua_type":"Promise"}],"function_type":"static","realm":["Client"],"source":{"line":106,"path":"lib/netwire/src/ClientWire.luau"}},{"name":"onReady","desc":"Returns a promise that resolves when the ClientNetWire is ready for use.","params":[{"name":"clientNetWire","desc":"","lua_type":"ClientNetWire | string"}],"returns":[{"desc":"","lua_type":"Promise"}],"function_type":"static","realm":["Client"],"source":{"line":128,"path":"lib/netwire/src/ClientWire.luau"}},{"name":"isReady","desc":"Can be used to check if a clientNetWire is ready for use.","params":[{"name":"clientNetWire","desc":"","lua_type":"ClientNetWire | string"}],"returns":[{"desc":"","lua_type":"boolean"}],"function_type":"static","realm":["Client"],"source":{"line":156,"path":"lib/netwire/src/ClientWire.luau"}},{"name":"destroy","desc":"Destroys a ClientNetWire, removing it from the cache.","params":[{"name":"clientNetWire","desc":"","lua_type":"ClientNetWire"}],"returns":[],"function_type":"static","realm":["Client"],"source":{"line":174,"path":"lib/netwire/src/ClientWire.luau"}},{"name":"new","desc":"Creates a new ClientNetWire. If a ClientNetWire with the same nameSpace already exists, it will be returned instead.","params":[{"name":"nameSpace","desc":"","lua_type":"string"}],"returns":[{"desc":"","lua_type":"ClientNetWire"}],"function_type":"static","tags":["constructor","static"],"source":{"line":234,"path":"lib/netwire/src/ClientWire.luau"}}],"properties":[{"name":"ClassName","desc":"","lua_type":"\\"ClientNetWire\\"","readonly":true,"source":{"line":224,"path":"lib/netwire/src/ClientWire.luau"}}],"types":[],"name":"ClientNetWire","desc":"Uses Sleitnick\'s Comm under the hood.\\n\\n:::caution\\nWire indices may not always be ready for use immediately after creating a ClientNetWire.\\nThis can be the case if the ServerWire is created dynamically. To wait for a ClientNetWire\\nto be ready for use, use NetWire.promiseWire. And then to wait for a\\nparticular index to be ready, use NetWire.promiseIndex.\\n:::\\n\\n```lua\\nlocal NetWire = require(game:GetService(\\"ReplicatedStorage\\").NetWire)\\n\\nlocal myNetWire = NetWire.Client(\\"MyNetWire\\")\\n\\nmyNetWire:ServerSideFunction(someArg)\\n\\nmyNetWire.ServerSideEvent:Connect(function(someArg)\\n    print(someArg)\\nend)\\n\\nmyNetWire.ServerSideEvent:Fire(someArg)\\n```","realm":["Client"],"source":{"line":30,"path":"lib/netwire/src/ClientWire.luau"}}')}}]);
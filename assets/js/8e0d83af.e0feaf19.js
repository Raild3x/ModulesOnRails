"use strict";(self.webpackChunkdocs=self.webpackChunkdocs||[]).push([[359],{6188:e=>{e.exports=JSON.parse('{"functions":[{"name":"new","desc":"Creates a new ClientNetWire. If a ClientNetWire with the same nameSpace already exists, it will be returned instead.","params":[{"name":"nameSpace","desc":"","lua_type":"string"}],"returns":[{"desc":"","lua_type":"ClientNetWire"}],"function_type":"static","tags":["constructor","static"],"source":{"line":230,"path":"lib/netwire/src/ClientWire.lua"}}],"properties":[{"name":"ClassName","desc":"","lua_type":"\\"ClientNetWire\\"","readonly":true,"source":{"line":220,"path":"lib/netwire/src/ClientWire.lua"}}],"types":[],"name":"ClientNetWire","desc":"Uses Sleitnick\'s Comm under the hood.\\n\\n:: caution ::\\nWire indices may not always be ready for use immediately after creating a ClientNetWire.\\nThis can be the case if the ServerWire is created dynamically. To wait for a ClientNetWire\\nto be ready for use, use NetWire.promiseWire. And then to wait for a\\nparticular index to be ready, use NetWire.promiseIndex.\\n\\n```lua\\nlocal NetWire = require(game:GetService(\\"ReplicatedStorage\\").NetWire)\\n\\nlocal myNetWire = NetWire.Client(\\"MyNetWire\\")\\n\\nmyNetWire:ServerSideFunction(someArg)\\n\\nmyNetWire.ServerSideEvent:Connect(function(someArg)\\n    print(someArg)\\nend)\\n\\nmyNetWire.ServerSideEvent:Fire(someArg)\\n```","realm":["Client"],"source":{"line":29,"path":"lib/netwire/src/ClientWire.lua"}}')}}]);
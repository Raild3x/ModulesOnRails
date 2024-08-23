"use strict";(self.webpackChunkdocs=self.webpackChunkdocs||[]).push([[7554],{69986:e=>{e.exports=JSON.parse('{"functions":[{"name":"indexReady","desc":"Returns a promise that resolves when the ClientNetWire is ready for use and the index exists.\\nThe resolved value is the value of the index.","params":[{"name":"wireOrName","desc":"","lua_type":"ClientNetWire | string"},{"name":"idx","desc":"The index to wait for existence of","lua_type":"string"}],"returns":[{"desc":"","lua_type":"Promise"}],"function_type":"static","realm":["Client"],"source":{"line":104,"path":"lib/netwire/src/ClientWire.lua"}},{"name":"onReady","desc":"Returns a promise that resolves when the ClientNetWire is ready for use.","params":[{"name":"clientNetWire","desc":"","lua_type":"ClientNetWire | string"}],"returns":[{"desc":"","lua_type":"Promise"}],"function_type":"static","realm":["Client"],"source":{"line":126,"path":"lib/netwire/src/ClientWire.lua"}},{"name":"isReady","desc":"Can be used to check if a clientNetWire is ready for use.","params":[{"name":"clientNetWire","desc":"","lua_type":"ClientNetWire | string"}],"returns":[{"desc":"","lua_type":"boolean"}],"function_type":"static","realm":["Client"],"source":{"line":154,"path":"lib/netwire/src/ClientWire.lua"}},{"name":"destroy","desc":"Destroys a ClientNetWire, removing it from the cache.","params":[{"name":"clientNetWire","desc":"","lua_type":"ClientNetWire"}],"returns":[],"function_type":"static","realm":["Client"],"source":{"line":172,"path":"lib/netwire/src/ClientWire.lua"}},{"name":"getClient","desc":"Returns a ClientNetWire from the cache, if it exists.","params":[{"name":"wireName","desc":"","lua_type":"string"}],"returns":[{"desc":"","lua_type":"ClientNetWire?"}],"function_type":"static","realm":["Client"],"source":{"line":192,"path":"lib/netwire/src/ClientWire.lua"}},{"name":"createEvent","desc":"Returns an EventMarker that is used to mark where a remoteSignal should be created.\\nCalls ServerNetWire:RegisterEvent() when set to the index of a ServerNetWire.\\nSee ServerNetWire:RegisterEvent for more information.","params":[],"returns":[{"desc":"","lua_type":"ServerRemoteEvent\\r\\n"}],"function_type":"static","realm":["Server"],"source":{"line":455,"path":"lib/netwire/src/ServerWire.lua"}},{"name":"createProperty","desc":"Returns an PropertyMarker that is used to mark where a remoteProperty should be created.\\nCalls ServerNetWire:RegisterProperty() when set to the index of a ServerNetWire.\\nSee ServerNetWire:RegisterProperty for more information.","params":[{"name":"initialValue","desc":"","lua_type":"any?"}],"returns":[{"desc":"","lua_type":"ServerRemoteProperty\\r\\n"}],"function_type":"static","realm":["Server"],"source":{"line":471,"path":"lib/netwire/src/ServerWire.lua"}},{"name":"getServer","desc":"Returns a ServerNetWire from the cache, if it exists.","params":[{"name":"wireName","desc":"","lua_type":"string"}],"returns":[{"desc":"","lua_type":"ServerNetWire?"}],"function_type":"static","realm":["Server"],"source":{"line":483,"path":"lib/netwire/src/ServerWire.lua"}}],"properties":[{"name":"Client","desc":"","lua_type":"ClientNetWire","realm":["Client"],"source":{"line":93,"path":"lib/netwire/src/ClientWire.lua"}},{"name":"Server","desc":"","lua_type":"ServerNetWire","realm":["Server"],"source":{"line":445,"path":"lib/netwire/src/ServerWire.lua"}}],"types":[],"name":"NetWire","desc":"NetWire is a networking library that enables functionality similar to Sleitnick\'s [Comm](https://sleitnick.github.io/RbxUtil/api/Comm/) library,\\nexcept it doesn\'t require the usage of intermediate instances.\\n\\nBasic usage:\\n```lua\\n-- SERVER\\nlocal NetWire = require(Packages.NetWire)\\nlocal myWire = NetWire(\\"MyWire\\")\\n\\nmyWire.MyEvent = NetWire.createEvent()\\n\\nmyWire.MyEvent:Connect(function(plr: Player, msg: string)\\n    print(plr, \\"said:\\", msg)\\nend)\\n```\\n```lua\\n-- CLIENT\\nlocal NetWire = require(Packages.NetWire)\\nlocal myWire = NetWire(\\"MyWire\\")\\n\\nmyWire.MyEvent:Fire(\\"Hello, world!\\")\\n```","source":{"line":29,"path":"lib/netwire/src/init.lua"}}')}}]);
"use strict";(self.webpackChunkdocs=self.webpackChunkdocs||[]).push([[9959],{12029:e=>{e.exports=JSON.parse('{"functions":[{"name":"createEvent () -> MARKER","desc":"Redirects to NetWire.createEvent","params":[],"returns":[],"function_type":"static","source":{"line":93,"path":"lib/remotecomponent/src/init.luau"}},{"name":"createUnreliableEvent () -> MARKER","desc":"Redirects to NetWire.createUnreliableEvent","params":[],"returns":[],"function_type":"static","source":{"line":100,"path":"lib/remotecomponent/src/init.luau"}},{"name":"createProperty (initialValue: any) -> MARKER","desc":"Redirects to NetWire.createProperty","params":[],"returns":[],"function_type":"static","source":{"line":107,"path":"lib/remotecomponent/src/init.luau"}}],"properties":[],"types":[{"name":"RemoteComponent","desc":"","fields":[{"name":"Client","lua_type":"table?","desc":"Only available on the server. Set this to a table to expose it to the client."},{"name":"Server","lua_type":"table?","desc":"Only available on the client. The indices of this are inferred from the server."}],"source":{"line":67,"path":"lib/remotecomponent/src/init.luau"}}],"name":"RemoteComponent","desc":"RemoteComponent is a component extension that allows you to easily give\\nnetworking capabilities to your components.\\n\\nYou can access the server-side component from the client by using the `.Server` index\\non the component. You can access the client-side component from the server by using\\nthe `.Client` index on the component.\\n\\n```lua\\n-- MyComponent.server.lua\\nlocal MyComponent = Component.new {\\n\\tTag = \\"MyComponent\\",\\n\\tAncestors = {workspace},\\n\\tExtensions = {RemoteComponent},\\n}\\n\\nMyComponent.Client = {\\n\\tTestProperty = RemoteComponent.createProperty(0),\\n\\tTestSignal = RemoteComponent.createEvent(),\\n}\\n\\nfunction MyComponent.Client:TestMethod(player: Player)\\n\\treturn (\\"Hello from the server!\\")\\nend\\n```\\n\\n```lua\\n-- MyComponent.client.lua\\nlocal MyComponent = Component.new {\\n\\tTag = \\"MyComponent\\",\\n\\tAncestors = {workspace},\\n\\tExtensions = {RemoteComponent},\\n}\\n\\nfunction MyComponent:Start()\\n\\tself.Server:TestMethod():andThen(print)\\nend\\n```\\n\\n:::caution Fast tagging and untagging\\nYou can encounter issues if you untag and then retag again quickly or unparent and\\nreparent to the same location on the server. This is because the server will rebuild the\\ncomponent, but the client will not recognize that there was a change as collectionservice\\nwont think anything is different and their remotes can become desynced.\\n:::\\n\\n:::caution RemoteComponent Usage Limitations\\nAccessing `.Server` or `.Client` is only safe to do so once the client has completed its \\nextension \'Starting\' cycle and began its `:Start()` method\\n:::\\n\\n:::caution Yielding accidents\\nWhen using RemoteComponent, you *must* have both a client and server component. If you do not,\\nthen the client will yield until the server component is created. If only one side extends RemoteComponent,\\nthen you may encounter infinite yields.\\n:::","source":{"line":60,"path":"lib/remotecomponent/src/init.luau"}}')}}]);
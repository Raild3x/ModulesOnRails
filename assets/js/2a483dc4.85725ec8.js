"use strict";(self.webpackChunkdocs=self.webpackChunkdocs||[]).push([[496],{45216:e=>{e.exports=JSON.parse('{"functions":[{"name":"isState","desc":"Checks if the given value is a state object.\\n\\n\\n```lua\\nlocal a = Value(10)\\nprint( FusionUtil.isState(a) ) -- true\\n```","params":[{"name":"v","desc":"The object to check","lua_type":"any"}],"returns":[{"desc":"Whether the value is a state object","lua_type":"boolean"}],"function_type":"static","source":{"line":46,"path":"lib/tablereplicator/_Index/raild3x_railutil@1.7.1/railutil/FusionUtil/FusionUtil_v0_2_0.luau"}},{"name":"isValue","desc":"Checks if the given value is a state object with a set method.\\n\\n\\n```lua\\nlocal a = Value(10)\\nprint( FusionUtil.isValue(a) ) -- true\\n```","params":[{"name":"v","desc":"The object to check","lua_type":"any"}],"returns":[{"desc":"Whether the value is a state object with a set method","lua_type":"boolean"}],"function_type":"static","source":{"line":65,"path":"lib/tablereplicator/_Index/raild3x_railutil@1.7.1/railutil/FusionUtil/FusionUtil_v0_2_0.luau"}},{"name":"use<T>","desc":"Returns the given literal or state object\'s value.\\n\\n\\n```lua\\nlocal a = Value(10)\\nlocal b = 20\\n\\nlocal use = FusionUtil.use\\n\\nprint( use(a) ) -- 10\\nprint( use(b) ) -- 20\\n```","params":[{"name":"obj","desc":"The state or literal to get the value of","lua_type":"CanBeState<T>"}],"returns":[{"desc":"The value of the state or literal","lua_type":"T"}],"function_type":"static","source":{"line":88,"path":"lib/tablereplicator/_Index/raild3x_railutil@1.7.1/railutil/FusionUtil/FusionUtil_v0_2_0.luau"}},{"name":"promiseStateChange","desc":"Creates a promise that resolves when the given state changes.\\nIf a callback is given then the callback must return true for the promise to resolve.\\n\\n\\n```lua\\nlocal a = Value(10)\\nFusionUtil.promiseStateChange(a, function(value)\\n\\treturn value > 10\\nend):andThen(function(value)\\n\\tprint(\\"Value is now greater than 10\\")\\nend)\\n\\na:set(5) -- Promise does not resolve\\na:set(15) -- Promise resolves\\n```","params":[{"name":"state","desc":"The state to observe","lua_type":"State<any>"},{"name":"callback","desc":"An optional condition to check before resolving the promise","lua_type":"((value: any) -> boolean)?"}],"returns":[{"desc":"The promise that will resolve when the state changes","lua_type":"Promise"}],"function_type":"static","source":{"line":131,"path":"lib/tablereplicator/_Index/raild3x_railutil@1.7.1/railutil/FusionUtil/FusionUtil_v0_2_0.luau"}},{"name":"formatAssetId","desc":"Takes an AssetId and ensures it to a valid State<string>.\\n\\n\\n```lua\\nlocal assetId = FusionUtil.formatAssetId(\\"rbxassetid://1234567890\\")\\nprint( use(assetId) ) -- \\"rbxassetid://1234567890\\"\\n```\\n```lua\\nlocal assetId = FusionUtil.formatAssetId(1234567890)\\nprint( use(assetId) ) -- \\"rbxassetid://1234567890\\"\\n```","params":[{"name":"id","desc":"The AssetId to format","lua_type":"CanBeState<string | number>"},{"name":"default","desc":"The default AssetId to use if the id is nil","lua_type":"(string | number)?"}],"returns":[{"desc":"The State<string> that is synced with the AssetId","lua_type":"CanBeState<string>"}],"function_type":"static","source":{"line":162,"path":"lib/tablereplicator/_Index/raild3x_railutil@1.7.1/railutil/FusionUtil/FusionUtil_v0_2_0.luau"}},{"name":"ratio","desc":"Generates a computed that calculates the ratio of two numbers as a State<number>.\\n\\n\\n```lua\\nlocal numerator = Value(100)\\nlocal denominator = Value(200)\\n\\nlocal ratio = FusionUtil.ratio(numerator, denominator)\\nprint( use(ratio) ) -- 0.5\\n```","params":[{"name":"numerator","desc":"The numerator of the ratio","lua_type":"CanBeState<number>"},{"name":"denominator","desc":"The denominator of the ratio","lua_type":"CanBeState<number>"},{"name":"mutator","desc":"An optional State to scale by or a function to mutate the ratio","lua_type":"(CanBeState<T> | (ratio: number) -> T)?\\r\\n"}],"returns":[{"desc":"The ratio (Potentially mutated)","lua_type":"State<T>"}],"function_type":"static","source":{"line":196,"path":"lib/tablereplicator/_Index/raild3x_railutil@1.7.1/railutil/FusionUtil/FusionUtil_v0_2_0.luau"}},{"name":"eq","desc":"A simple equality function that returns true if the two states are equal.\\n\\t\\n\\n```lua\\nlocal a = Value(10)\\nlocal b = Value(10)\\nlocal c = FusionUtil.eq(a, b)\\nprint( use(c) ) -- true\\na:set(20)\\nprint( use(c) ) -- false\\n```","params":[{"name":"stateToCheck1","desc":"The first potential state to check","lua_type":"CanBeState<any>"},{"name":"stateToCheck2","desc":"The second potential state to check","lua_type":"CanBeState<any>"}],"returns":[{"desc":"A state resolving to the equality of the two given arguments","lua_type":"State<boolean>"}],"function_type":"static","source":{"line":235,"path":"lib/tablereplicator/_Index/raild3x_railutil@1.7.1/railutil/FusionUtil/FusionUtil_v0_2_0.luau"}}],"properties":[],"types":[],"name":"[0.2.0] FusionUtil","desc":"A collection of utility functions for Fusion.\\n\\nDO NOT ACCESS THIS IN MULTIPLE VMs. Studio freaks out when\\nfusion is loaded in multiple VMs for some unknown reason.","source":{"line":12,"path":"lib/tablereplicator/_Index/raild3x_railutil@1.7.1/railutil/FusionUtil/FusionUtil_v0_2_0.luau"}}')}}]);
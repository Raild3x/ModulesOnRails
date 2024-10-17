"use strict";(self.webpackChunkdocs=self.webpackChunkdocs||[]).push([[3231],{9256:e=>{e.exports=JSON.parse('{"functions":[{"name":"new","desc":"Creates a new DropletServerManager if one has not already been made,\\nreturns the existing one if one already exists.","params":[],"returns":[{"desc":"","lua_type":"DropletServerManager"}],"function_type":"static","tags":["constructor"],"source":{"line":117,"path":"lib/dropletmanager/src/Server/DropletServerManager.lua"}},{"name":"Destroy","desc":"","params":[],"returns":[],"function_type":"method","private":true,"source":{"line":158,"path":"lib/dropletmanager/src/Server/DropletServerManager.lua"}},{"name":"_GenerateSeed","desc":"Generates a new unused seed","params":[],"returns":[{"desc":"","lua_type":"number\\r\\n"}],"function_type":"method","private":true,"source":{"line":166,"path":"lib/dropletmanager/src/Server/DropletServerManager.lua"}},{"name":"RegisterResourceType","desc":"Registers a new resource type. Attempting to register a resource type with the same name as an existing one will error.\\n```lua\\nlocal data = Import(\\"ExampleResourceTypeData\\") -- This is an Example file included in the package you can check out.\\nDropletServerManager:RegisterResourceType(\\"Example\\", data)\\n```","params":[{"name":"resourceType","desc":"","lua_type":"string"},{"name":"data","desc":"","lua_type":"ResourceTypeData"}],"returns":[],"function_type":"method","source":{"line":181,"path":"lib/dropletmanager/src/Server/DropletServerManager.lua"}},{"name":"GetResourceTypeData","desc":"Returns the resource type data for the given resource type.","params":[{"name":"resourceType","desc":"","lua_type":"string"}],"returns":[{"desc":"","lua_type":"ResourceTypeData?\\r\\n"}],"function_type":"method","source":{"line":190,"path":"lib/dropletmanager/src/Server/DropletServerManager.lua"}},{"name":"GetDropletServerData","desc":"Returns the droplet server data for the given seed.","params":[{"name":"seed","desc":"","lua_type":"number"}],"returns":[{"desc":"","lua_type":"DropletUtil.DropletServerCacheData?\\r\\n"}],"function_type":"method","private":true,"source":{"line":199,"path":"lib/dropletmanager/src/Server/DropletServerManager.lua"}},{"name":"Spawn","desc":"Creates a new droplet request to create some defined number of droplets of a given ResourceType.\\nThe droplet request will be created on the server and replicated to the clients.\\n\\nA PlayerTargets array can be passed to specify which players the droplet request should be replicated to,\\nif one isnt given it replicates to all connected players at the moment of the request.\\n\\n:::caution Caveats\\nSome properties of the interface have special behaviors depending on their type.\\nSee \'ResourceSpawnData\' for more info on important caveats and behavior.\\n:::\\n\\n```lua\\nlocal Bounds = 35\\n\\nlocal seed = DropletServerManager:Spawn({\\n    ResourceType = \\"Example\\";\\n    Value = NumberRange.new(0.6, 1.4);\\n    Count = NumberRange.new(2, 10);\\n    LifeTime = NumberRange.new(10, 20);\\n    SpawnLocation = Vector3.new(\\n        math.random(-Bounds,Bounds),\\n        7,\\n        math.random(-Bounds,Bounds)\\n    );\\n    CollectorMode = DropletUtil.Enums.CollectorMode.MultiCollector;\\n})\\n```","params":[{"name":"data","desc":"The data used to spawn the droplet.","lua_type":"ResourceSpawnData"}],"returns":[{"desc":"The seed of the droplet request.","lua_type":"number"}],"function_type":"method","source":{"line":235,"path":"lib/dropletmanager/src/Server/DropletServerManager.lua"}},{"name":"Claim","desc":"Force claim a droplet(s) for a player.","params":[{"name":"collector","desc":"The player claiming the droplet.","lua_type":"Player"},{"name":"seed","desc":"The droplet request identifier.","lua_type":"number"},{"name":"dropletNumber","desc":"The particular droplet number to claim. If nil, all remaining droplets will be claimed.","lua_type":"number?"}],"returns":[{"desc":"Whether or not the claim was successful.","lua_type":"boolean"}],"function_type":"method","source":{"line":320,"path":"lib/dropletmanager/src/Server/DropletServerManager.lua"}},{"name":"Collect","desc":"Force collects a droplet(s) resource and returns whether or not the collection was successful.","params":[{"name":"collector","desc":"The player collecting the resource.","lua_type":"Player"},{"name":"seed","desc":"The droplet request identifier.","lua_type":"number"},{"name":"dropletNumber","desc":"The particular droplet number to collect. If nil, all droplets will be collected.","lua_type":"number?"}],"returns":[{"desc":"Whether or not the collection was successful.","lua_type":"boolean"}],"function_type":"method","source":{"line":387,"path":"lib/dropletmanager/src/Server/DropletServerManager.lua"}},{"name":"GetCollectionRadius","desc":"Gets the collection radius for the given player.","params":[{"name":"player","desc":"","lua_type":"Player"}],"returns":[{"desc":"","lua_type":"number\\r\\n"}],"function_type":"method","source":{"line":470,"path":"lib/dropletmanager/src/Server/DropletServerManager.lua"}},{"name":"SetCollectionRadius","desc":"Sets the collection radius for the given player.","params":[{"name":"player","desc":"","lua_type":"Player"},{"name":"radius","desc":"","lua_type":"number"}],"returns":[],"function_type":"method","source":{"line":477,"path":"lib/dropletmanager/src/Server/DropletServerManager.lua"}}],"properties":[],"types":[],"name":"DropletServerManager","desc":"","source":{"line":6,"path":"lib/dropletmanager/src/Server/DropletServerManager.lua"}}')}}]);
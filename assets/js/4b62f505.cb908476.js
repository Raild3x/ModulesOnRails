"use strict";(self.webpackChunkdocs=self.webpackChunkdocs||[]).push([[824],{89039:e=>{e.exports=JSON.parse('{"functions":[{"name":"Set","desc":"Sets the top-level value of all clients to the same value.\\n\\n:::note Override Per-Player Data\\nThis will override any per-player data that was set using\\n`SetFor` or `SetFilter`. To avoid overriding this data,\\n`SetTop` can be used instead.\\n:::\\n\\n```lua\\n-- Examples\\nremoteProperty:Set(10)\\nremoteProperty:Set({SomeData = 32})\\nremoteProperty:Set(\\"HelloWorld\\")\\n```","params":[{"name":"value","desc":"","lua_type":"any"}],"returns":[],"function_type":"method","source":{"line":94,"path":"lib/comm/src/Server/RemoteProperty.lua"}},{"name":"SetTop","desc":"Set the top-level value of the property, but does not override\\nany per-player data (e.g. set with `SetFor` or `SetFilter`).\\nAny player without custom-set data will receive this new data.\\n\\nThis is useful if certain players have specific values that\\nshould not be changed, but all other players should receive\\nthe same new value.\\n\\n```lua\\n-- Using just \'Set\' overrides per-player data:\\nremoteProperty:SetFor(somePlayer, \\"CustomData\\")\\nremoteProperty:Set(\\"Data\\")\\nprint(remoteProperty:GetFor(somePlayer)) --\x3e \\"Data\\"\\n\\n-- Using \'SetTop\' does not override:\\nremoteProperty:SetFor(somePlayer, \\"CustomData\\")\\nremoteProperty:SetTop(\\"Data\\")\\nprint(remoteProperty:GetFor(somePlayer)) --\x3e \\"CustomData\\"\\n```","params":[{"name":"value","desc":"","lua_type":"any"}],"returns":[],"function_type":"method","source":{"line":121,"path":"lib/comm/src/Server/RemoteProperty.lua"}},{"name":"SetFilter","desc":"Sets the value for specific clients that pass the `predicate`\\nfunction test. This can be used to finely set the values\\nbased on more control logic (e.g. setting certain values\\nper team).\\n\\n```lua\\n-- Set the value of \\"NewValue\\" to players with a name longer than 10 characters:\\nremoteProperty:SetFilter(function(player)\\n\\treturn #player.Name > 10\\nend, \\"NewValue\\")\\n```","params":[{"name":"predicate","desc":"","lua_type":"(Player, any) -> boolean"},{"name":"value","desc":"Value to set for the clients (and to the predicate)","lua_type":"any"}],"returns":[],"function_type":"method","source":{"line":144,"path":"lib/comm/src/Server/RemoteProperty.lua"}},{"name":"SetFor","desc":"Set the value of the property for a specific player. This\\nwill override the value used by `Set` (and the initial value\\nset for the property when created).\\n\\nThis value _can_ be `nil`. In order to reset the value for a\\ngiven player and let the player use the top-level value held\\nby this property, either use `Set` to set all players\' data,\\nor use `ClearFor`.\\n\\n```lua\\nremoteProperty:SetFor(somePlayer, \\"CustomData\\")\\n```","params":[{"name":"player","desc":"","lua_type":"Player"},{"name":"value","desc":"","lua_type":"any"}],"returns":[],"function_type":"method","source":{"line":166,"path":"lib/comm/src/Server/RemoteProperty.lua"}},{"name":"SetForList","desc":"Set the value of the property for specific players. This just\\nloops through the players given and calls `SetFor`.\\n\\n```lua\\nlocal players = {player1, player2, player3}\\nremoteProperty:SetForList(players, \\"CustomData\\")\\n```","params":[{"name":"players","desc":"","lua_type":"{ Player }"},{"name":"value","desc":"","lua_type":"any"}],"returns":[],"function_type":"method","source":{"line":182,"path":"lib/comm/src/Server/RemoteProperty.lua"}},{"name":"ClearFor","desc":"Clears the custom property value for the given player. When\\nthis occurs, the player will reset to use the top-level\\nvalue held by this property (either the value set when the\\nproperty was created, or the last value set by `Set`).\\n\\n```lua\\nremoteProperty:Set(\\"DATA\\")\\n\\nremoteProperty:SetFor(somePlayer, \\"CUSTOM_DATA\\")\\nprint(remoteProperty:GetFor(somePlayer)) --\x3e \\"CUSTOM_DATA\\"\\n\\n-- DOES NOT CLEAR, JUST SETS CUSTOM DATA TO NIL:\\nremoteProperty:SetFor(somePlayer, nil)\\nprint(remoteProperty:GetFor(somePlayer)) --\x3e nil\\n\\n-- CLEAR:\\nremoteProperty:ClearFor(somePlayer)\\nprint(remoteProperty:GetFor(somePlayer)) --\x3e \\"DATA\\"\\n```","params":[{"name":"player","desc":"","lua_type":"Player"}],"returns":[],"function_type":"method","source":{"line":209,"path":"lib/comm/src/Server/RemoteProperty.lua"}},{"name":"ClearForList","desc":"Clears the custom value for the given players. This\\njust loops through the list of players and calls\\nthe `ClearFor` method for each player.","params":[{"name":"players","desc":"","lua_type":"{ Player }"}],"returns":[],"function_type":"method","source":{"line":222,"path":"lib/comm/src/Server/RemoteProperty.lua"}},{"name":"ClearFilter","desc":"The same as `SetFiler`, except clears the custom value\\nfor any player that passes the predicate.","params":[{"name":"predicate","desc":"","lua_type":"(Player) -> boolean"}],"returns":[],"function_type":"method","source":{"line":232,"path":"lib/comm/src/Server/RemoteProperty.lua"}},{"name":"Get","desc":"Returns the top-level value held by the property. This will\\neither be the initial value set, or the last value set\\nwith `Set()`.\\n\\n```lua\\nremoteProperty:Set(\\"Data\\")\\nprint(remoteProperty:Get()) --\x3e \\"Data\\"\\n```","params":[],"returns":[{"desc":"","lua_type":"any\\r\\n"}],"function_type":"method","source":{"line":250,"path":"lib/comm/src/Server/RemoteProperty.lua"}},{"name":"GetFor","desc":"Returns the current value for the given player. This value\\nwill depend on if `SetFor` or `SetFilter` has affected the\\ncustom value for the player. If so, that custom value will\\nbe returned. Otherwise, the top-level value will be used\\n(e.g. value from `Set`).\\n\\n```lua\\n-- Set top level data:\\nremoteProperty:Set(\\"Data\\")\\nprint(remoteProperty:GetFor(somePlayer)) --\x3e \\"Data\\"\\n\\n-- Set custom data:\\nremoteProperty:SetFor(somePlayer, \\"CustomData\\")\\nprint(remoteProperty:GetFor(somePlayer)) --\x3e \\"CustomData\\"\\n\\n-- Set top level again, overriding custom data:\\nremoteProperty:Set(\\"NewData\\")\\nprint(remoteProperty:GetFor(somePlayer)) --\x3e \\"NewData\\"\\n\\n-- Set custom data again, and set top level without overriding:\\nremoteProperty:SetFor(somePlayer, \\"CustomData\\")\\nremoteProperty:SetTop(\\"Data\\")\\nprint(remoteProperty:GetFor(somePlayer)) --\x3e \\"CustomData\\"\\n\\n-- Clear custom data to use top level data:\\nremoteProperty:ClearFor(somePlayer)\\nprint(remoteProperty:GetFor(somePlayer)) --\x3e \\"Data\\"\\n```","params":[{"name":"player","desc":"","lua_type":"Player"}],"returns":[{"desc":"","lua_type":"any\\r\\n"}],"function_type":"method","source":{"line":284,"path":"lib/comm/src/Server/RemoteProperty.lua"}},{"name":"Destroy","desc":"Destroys the RemoteProperty object.","params":[],"returns":[],"function_type":"method","source":{"line":293,"path":"lib/comm/src/Server/RemoteProperty.lua"}},{"name":"Set","desc":"Sets the top-level value of all clients to the same value.\\n\\n:::note Override Per-Player Data\\nThis will override any per-player data that was set using\\n`SetFor` or `SetFilter`. To avoid overriding this data,\\n`SetTop` can be used instead.\\n:::\\n\\n```lua\\n-- Examples\\nremoteProperty:Set(10)\\nremoteProperty:Set({SomeData = 32})\\nremoteProperty:Set(\\"HelloWorld\\")\\n```","params":[{"name":"value","desc":"","lua_type":"any"}],"returns":[],"function_type":"method","source":{"line":91,"path":"lib/tablereplicator/_Index/sleitnick_comm@1.0.1/comm/Server/RemoteProperty.lua"}},{"name":"SetTop","desc":"Set the top-level value of the property, but does not override\\nany per-player data (e.g. set with `SetFor` or `SetFilter`).\\nAny player without custom-set data will receive this new data.\\n\\nThis is useful if certain players have specific values that\\nshould not be changed, but all other players should receive\\nthe same new value.\\n\\n```lua\\n-- Using just \'Set\' overrides per-player data:\\nremoteProperty:SetFor(somePlayer, \\"CustomData\\")\\nremoteProperty:Set(\\"Data\\")\\nprint(remoteProperty:GetFor(somePlayer)) --\x3e \\"Data\\"\\n\\n-- Using \'SetTop\' does not override:\\nremoteProperty:SetFor(somePlayer, \\"CustomData\\")\\nremoteProperty:SetTop(\\"Data\\")\\nprint(remoteProperty:GetFor(somePlayer)) --\x3e \\"CustomData\\"\\n```","params":[{"name":"value","desc":"","lua_type":"any"}],"returns":[],"function_type":"method","source":{"line":118,"path":"lib/tablereplicator/_Index/sleitnick_comm@1.0.1/comm/Server/RemoteProperty.lua"}},{"name":"SetFilter","desc":"Sets the value for specific clients that pass the `predicate`\\nfunction test. This can be used to finely set the values\\nbased on more control logic (e.g. setting certain values\\nper team).\\n\\n```lua\\n-- Set the value of \\"NewValue\\" to players with a name longer than 10 characters:\\nremoteProperty:SetFilter(function(player)\\n\\treturn #player.Name > 10\\nend, \\"NewValue\\")\\n```","params":[{"name":"predicate","desc":"","lua_type":"(Player, any) -> boolean"},{"name":"value","desc":"Value to set for the clients (and to the predicate)","lua_type":"any"}],"returns":[],"function_type":"method","source":{"line":141,"path":"lib/tablereplicator/_Index/sleitnick_comm@1.0.1/comm/Server/RemoteProperty.lua"}},{"name":"SetFor","desc":"Set the value of the property for a specific player. This\\nwill override the value used by `Set` (and the initial value\\nset for the property when created).\\n\\nThis value _can_ be `nil`. In order to reset the value for a\\ngiven player and let the player use the top-level value held\\nby this property, either use `Set` to set all players\' data,\\nor use `ClearFor`.\\n\\n```lua\\nremoteProperty:SetFor(somePlayer, \\"CustomData\\")\\n```","params":[{"name":"player","desc":"","lua_type":"Player"},{"name":"value","desc":"","lua_type":"any"}],"returns":[],"function_type":"method","source":{"line":163,"path":"lib/tablereplicator/_Index/sleitnick_comm@1.0.1/comm/Server/RemoteProperty.lua"}},{"name":"SetForList","desc":"Set the value of the property for specific players. This just\\nloops through the players given and calls `SetFor`.\\n\\n```lua\\nlocal players = {player1, player2, player3}\\nremoteProperty:SetForList(players, \\"CustomData\\")\\n```","params":[{"name":"players","desc":"","lua_type":"{ Player }"},{"name":"value","desc":"","lua_type":"any"}],"returns":[],"function_type":"method","source":{"line":179,"path":"lib/tablereplicator/_Index/sleitnick_comm@1.0.1/comm/Server/RemoteProperty.lua"}},{"name":"ClearFor","desc":"Clears the custom property value for the given player. When\\nthis occurs, the player will reset to use the top-level\\nvalue held by this property (either the value set when the\\nproperty was created, or the last value set by `Set`).\\n\\n```lua\\nremoteProperty:Set(\\"DATA\\")\\n\\nremoteProperty:SetFor(somePlayer, \\"CUSTOM_DATA\\")\\nprint(remoteProperty:GetFor(somePlayer)) --\x3e \\"CUSTOM_DATA\\"\\n\\n-- DOES NOT CLEAR, JUST SETS CUSTOM DATA TO NIL:\\nremoteProperty:SetFor(somePlayer, nil)\\nprint(remoteProperty:GetFor(somePlayer)) --\x3e nil\\n\\n-- CLEAR:\\nremoteProperty:ClearFor(somePlayer)\\nprint(remoteProperty:GetFor(somePlayer)) --\x3e \\"DATA\\"\\n```","params":[{"name":"player","desc":"","lua_type":"Player"}],"returns":[],"function_type":"method","source":{"line":206,"path":"lib/tablereplicator/_Index/sleitnick_comm@1.0.1/comm/Server/RemoteProperty.lua"}},{"name":"ClearForList","desc":"Clears the custom value for the given players. This\\njust loops through the list of players and calls\\nthe `ClearFor` method for each player.","params":[{"name":"players","desc":"","lua_type":"{ Player }"}],"returns":[],"function_type":"method","source":{"line":219,"path":"lib/tablereplicator/_Index/sleitnick_comm@1.0.1/comm/Server/RemoteProperty.lua"}},{"name":"ClearFilter","desc":"The same as `SetFiler`, except clears the custom value\\nfor any player that passes the predicate.","params":[{"name":"predicate","desc":"","lua_type":"(Player) -> boolean"}],"returns":[],"function_type":"method","source":{"line":229,"path":"lib/tablereplicator/_Index/sleitnick_comm@1.0.1/comm/Server/RemoteProperty.lua"}},{"name":"Get","desc":"Returns the top-level value held by the property. This will\\neither be the initial value set, or the last value set\\nwith `Set()`.\\n\\n```lua\\nremoteProperty:Set(\\"Data\\")\\nprint(remoteProperty:Get()) --\x3e \\"Data\\"\\n```","params":[],"returns":[{"desc":"","lua_type":"any\\n"}],"function_type":"method","source":{"line":247,"path":"lib/tablereplicator/_Index/sleitnick_comm@1.0.1/comm/Server/RemoteProperty.lua"}},{"name":"GetFor","desc":"Returns the current value for the given player. This value\\nwill depend on if `SetFor` or `SetFilter` has affected the\\ncustom value for the player. If so, that custom value will\\nbe returned. Otherwise, the top-level value will be used\\n(e.g. value from `Set`).\\n\\n```lua\\n-- Set top level data:\\nremoteProperty:Set(\\"Data\\")\\nprint(remoteProperty:GetFor(somePlayer)) --\x3e \\"Data\\"\\n\\n-- Set custom data:\\nremoteProperty:SetFor(somePlayer, \\"CustomData\\")\\nprint(remoteProperty:GetFor(somePlayer)) --\x3e \\"CustomData\\"\\n\\n-- Set top level again, overriding custom data:\\nremoteProperty:Set(\\"NewData\\")\\nprint(remoteProperty:GetFor(somePlayer)) --\x3e \\"NewData\\"\\n\\n-- Set custom data again, and set top level without overriding:\\nremoteProperty:SetFor(somePlayer, \\"CustomData\\")\\nremoteProperty:SetTop(\\"Data\\")\\nprint(remoteProperty:GetFor(somePlayer)) --\x3e \\"CustomData\\"\\n\\n-- Clear custom data to use top level data:\\nremoteProperty:ClearFor(somePlayer)\\nprint(remoteProperty:GetFor(somePlayer)) --\x3e \\"Data\\"\\n```","params":[{"name":"player","desc":"","lua_type":"Player"}],"returns":[{"desc":"","lua_type":"any\\n"}],"function_type":"method","source":{"line":281,"path":"lib/tablereplicator/_Index/sleitnick_comm@1.0.1/comm/Server/RemoteProperty.lua"}},{"name":"Destroy","desc":"Destroys the RemoteProperty object.","params":[],"returns":[],"function_type":"method","source":{"line":290,"path":"lib/tablereplicator/_Index/sleitnick_comm@1.0.1/comm/Server/RemoteProperty.lua"}}],"properties":[],"types":[],"name":"RemoteProperty","desc":"Created via `ServerComm:CreateProperty()`.\\n\\nValues set can be anything that can pass through a\\n[RemoteEvent](https://developer.roblox.com/en-us/articles/Remote-Functions-and-Events#parameter-limitations).\\n\\nHere is a cheat-sheet for the below methods:\\n- Setting data\\n\\t- `Set`: Set \\"top\\" value for all current and future players. Overrides any custom-set data per player.\\n\\t- `SetTop`: Set the \\"top\\" value for all players, but does _not_ override any custom-set data per player.\\n\\t- `SetFor`: Set custom data for the given player. Overrides the \\"top\\" value. (_Can be nil_)\\n\\t- `SetForList`: Same as `SetFor`, but accepts a list of players.\\n\\t- `SetFilter`: Accepts a predicate function which checks for which players to set.\\n- Clearing data\\n\\t- `ClearFor`: Clears the custom data set for a given player. Player will start using the \\"top\\" level value instead.\\n\\t- `ClearForList`: Same as `ClearFor`, but accepts a list of players.\\n\\t- `ClearFilter`: Accepts a predicate function which checks for which players to clear.\\n- Getting data\\n\\t- `Get`: Retrieves the \\"top\\" value\\n\\t- `GetFor`: Gets the current value for the given player. If cleared, returns the top value.\\n\\n:::caution Network\\nCalling any of the data setter methods (e.g. `Set()`) will\\nfire the underlying RemoteEvent to replicate data to the\\nclients. Therefore, setting data should only occur when it\\nis necessary to change the data that the clients receive.\\n:::\\n\\n:::caution Tables\\nTables _can_ be used with RemoteProperties. However, the\\nRemoteProperty object will _not_ watch for changes within\\nthe table. Therefore, anytime changes are made to the table,\\nthe data must be set again using one of the setter methods.\\n:::","realm":["Server"],"source":{"line":50,"path":"lib/tablereplicator/_Index/sleitnick_comm@1.0.1/comm/Server/RemoteProperty.lua"}}')}}]);
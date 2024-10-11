"use strict";(self.webpackChunkdocs=self.webpackChunkdocs||[]).push([[6107],{17968:e=>{e.exports=JSON.parse('{"functions":[{"name":"new","desc":"Creates a new TableManager. Takes a table to manage, if one is not given then it will construct an empty table.\\n\\n:::warning Modifying the given table\\nOnce you give a table to a `TableManager`, you should never modify it directly.\\nDoing so can result in the `TableManager` being unable to properly track changes\\nand potentially cause data desyncs.\\n:::\\n\\n:::caution Key/Value Rules\\nThe given table\'s keys should follow these rules:\\n- No Mixed Tables (Tables containing keys of different datatypes)\\n- Avoid using tables as keys.\\n- Keys *must* not contain periods.\\n- Keys *must* not be empty strings.\\n- Tables/Arrays should be assigned to only one key. (No shared references as this can cause desyncs)\\n- Nested tables/arrays should not be given to other `TableManager` instances. (Can cause desyncs)\\n:::\\n\\n:::info\\nOnly one `TableManager` should be created for a given table. Attempting to create a `TableManager` for a table\\nthat is already being managed will return the existing `TableManager`.\\n:::\\n\\n:::tip Call metamethod\\nYou can call the `TableManager` class to create a new instance of it.\\n`TableManager()` is equivalent to `TableManager.new()`.\\n:::\\n\\n\\n```lua\\nlocal tbl = {\\n    Coins = 0;\\n    Inventory = {\\n        \\"Sword\\";\\n        \\"Shield\\";\\n    };\\n}\\n\\nlocal tblMngr = TableManager.new(tbl)\\n\\ntblMngr:SetValue(\\"Coins\\", 100)\\ntblMngr:IncrementValue(\\"Coins\\", 55)\\nprint(tblMngr:Get(\\"Coins\\")) -- 155\\n\\ntblMngr:ArrayInsert(\\"Inventory\\", \\"Potion\\")\\ntblMngr:ArrayInsert(\\"Inventory\\", 2, \\"Bow\\")\\nprint(tblMngr:Get(\\"Inventory\\")) -- {\\"Sword\\", \\"Bow\\", \\"Shield\\", \\"Potion\\"}\\n```","params":[{"name":"data","desc":"","lua_type":"table?"}],"returns":[{"desc":"","lua_type":"TableManager\\n"}],"function_type":"static","tags":["Constructor"],"source":{"line":340,"path":"lib/tablemanager/src/init.luau"}},{"name":"Destroy","desc":"Disconnects any listeners and removes the table from the managed tables.","params":[],"returns":[],"function_type":"method","source":{"line":378,"path":"lib/tablemanager/src/init.luau"}},{"name":"Set","desc":"Sets the value at the given path to the given value.\\n:Set acts as a combined function for :SetValue and :ArraySet.\\n```lua\\n:Set(myPathToValue, newValue)\\n:Set(myPathToArray, index, newValue)\\n```\\n\\n:::caution Overwriting the root table\\nOverwriting the root table is not recommended, but is technically possible by giving\\nan empty table or string as a `Path`. Doing so has not been tested in depth and may\\nresult in unintended behavior.\\n:::\\n\\n:::caution Setting array values\\nYou cannot set values to nil in an array with this method due to the way it parses args.\\nUse `ArraySet` instead if you need to set values to nil.\\n:::","params":[{"name":"path","desc":"","lua_type":"Path"},{"name":"...","desc":"","lua_type":"any"}],"returns":[],"function_type":"method","source":{"line":406,"path":"lib/tablemanager/src/init.luau"}},{"name":"Increment","desc":"Increments the value at the given path by the given amount.\\nIf the value is not a number, it will throw an error.\\n:Increment acts as a combined function for :IncrementValue and :ArrayIncrement.\\n```lua\\n:Increment(myPathToValue, amountToIncrementBy)\\n:Increment(myPathToArray, index, amountToIncrementBy)\\n```","params":[{"name":"path","desc":"","lua_type":"Path"},{"name":"...","desc":"","lua_type":"any"}],"returns":[{"desc":"","lua_type":"number?\\n"}],"function_type":"method","source":{"line":425,"path":"lib/tablemanager/src/init.luau"}},{"name":"Update","desc":"Mutates the value at the given path by calling the given function with the current value.\\n```lua\\n:Update(myPathToValue, function(currentValue)\\n    return currentValue + 1\\nend)\\n```\\n:::info Aliases\\n`:Mutate` is an alias for `:Update`. This alias is consistent with all other \'Update\' methods.\\n:::","params":[{"name":"path","desc":"","lua_type":"Path"},{"name":"...","desc":"","lua_type":"any"}],"returns":[{"desc":"","lua_type":"any?\\n"}],"function_type":"method","source":{"line":446,"path":"lib/tablemanager/src/init.luau"}},{"name":"SetValue","desc":"Sets the value at the given path to the given value.\\nThis will fire the ValueChanged signal if the value is different.\\nReturns a boolean indicating whether or not the value was changed.\\n```lua\\nlocal didChange = manager:SetValue(\\"MyPath.To.Value\\", 100)\\n```","params":[{"name":"path","desc":"","lua_type":"Path"},{"name":"value","desc":"","lua_type":"any"}],"returns":[{"desc":"","lua_type":"boolean\\n"}],"function_type":"method","source":{"line":465,"path":"lib/tablemanager/src/init.luau"}},{"name":"IncrementValue","desc":"Increments the value at the given path by the given amount.\\nIf the value at the path or the given amount is not a number,\\nit will throw an error. Returns the newly incremeneted value.\\n```lua\\nlocal newValue = manager:IncrementValue(\\"MyPath.To.Value\\", 100)\\n```","params":[{"name":"path","desc":"","lua_type":"Path"},{"name":"amount","desc":"","lua_type":"Numeric"}],"returns":[{"desc":"","lua_type":"number\\n"}],"function_type":"method","source":{"line":483,"path":"lib/tablemanager/src/init.luau"}},{"name":"UpdateValue","desc":"Mutates the value at the given path by calling the given function with the current value.\\nThe function should return the new value.\\n```lua\\nmanager:SetValue(\\"MyPath.To.Value\\", \\"Hello World\\")\\n\\nlocal newValue = manager:UpdateValue(\\"MyPath.To.Value\\", function(currentValue)\\n    return string.upper(currentValue) .. \\"!\\"\\nend)\\n\\nprint(newValue) -- HELLO WORLD!\\nprint(manager:GetValue(\\"MyPath.To.Value\\")) -- HELLO WORLD!\\n```","params":[{"name":"path","desc":"","lua_type":"Path"},{"name":"fn","desc":"","lua_type":"(currentValue: any) -> (any)"}],"returns":[{"desc":"","lua_type":"any\\n"}],"function_type":"method","source":{"line":506,"path":"lib/tablemanager/src/init.luau"}},{"name":"SetManyValues","desc":"Sets the values at the given path to the given values.\\nThis will fire the ValueChanged listener for each value that is different.\\n:::caution\\nUses pairs to check through the given table and thus *Does not support setting values to nil*.\\n:::\\n```lua\\nlocal manager = TableManager.new({\\n    Foo = {\\n        Bar = {\\n            Value1 = 0;\\n            Value2 = 0;\\n            Value3 = 0;\\n        };\\n    };\\n})\\n\\nmanager:SetManyValues(\\"Foo.Bar\\", {\\n    Value1 = 100;\\n    Value3 = 300;\\n})\\n```","params":[{"name":"path","desc":"","lua_type":"Path"},{"name":"valueDict","desc":"","lua_type":"{[any]: any}"}],"returns":[],"function_type":"method","source":{"line":537,"path":"lib/tablemanager/src/init.luau"}},{"name":"ArrayUpdate","desc":"Mutates an index or indices in the array at the given path by calling the given function with the current value.\\n\\n```lua\\nmanager:SetValue(\\"MyArray\\", {1, 2, 3, 4, 5})\\n\\nmanager:ArrayUpdate(\\"MyArray\\", 3, function(currentValue)\\n    return currentValue * 2\\n})\\n\\nprint(manager:GetValue(\\"MyArray\\")) -- {1, 2, 6, 4, 5}\\n```","params":[{"name":"path","desc":"The path to the array to mutate.","lua_type":"Path"},{"name":"index","desc":"The index or indices to mutate. If \\"#\\" is given, it will mutate all indices.","lua_type":"number | {number} | \\"#\\""},{"name":"fn","desc":"The function to call with the current value. Should return the new value.","lua_type":"(currentValue: any) -> (any)"}],"returns":[],"function_type":"method","source":{"line":563,"path":"lib/tablemanager/src/init.luau"}},{"name":"ArrayIncrement","desc":"Increments the indices at the given path by the given amount.\\n\\n```lua\\nmanager:SetValue(\\"MyArray\\", {1, 2, 3, 4, 5})\\n\\nmanager:ArrayIncrement(\\"MyArray\\", 3, 10)\\n\\nprint(manager:GetValue(\\"MyArray\\")) -- {1, 2, 13, 4, 5}\\n```","params":[{"name":"path","desc":"The path to the array to increment.","lua_type":"Path"},{"name":"index","desc":"The index or indices to increment.","lua_type":"number | {number}"},{"name":"amount","desc":"The amount to increment by. If not given, it will increment by 1.","lua_type":"number?"}],"returns":[],"function_type":"method","source":{"line":604,"path":"lib/tablemanager/src/init.luau"}},{"name":"ArraySet","desc":"Sets the value at the given index in the array at the given path.\\nThe index can be a number or an array of numbers. If an array is given then\\nthe value will be set at each of those indices in the array.","params":[{"name":"path","desc":"","lua_type":"Path"},{"name":"index","desc":"","lua_type":"(CanBeArray<number> | \'#\')?"},{"name":"value","desc":"","lua_type":"any"}],"returns":[],"function_type":"method","source":{"line":657,"path":"lib/tablemanager/src/init.luau"}},{"name":"ArrayInsert","desc":"Inserts the given value into the array at the given path at the given index.\\nIf no index is given, it will insert at the end of the array.\\nThis follows the convention of `table.insert` where the index is given in the middle\\nonly if there are 3 args.\\n```lua\\nx:ArrayInsert(\\"MyArray\\", \\"Hello\\") -- Inserts \\"Hello\\" at the end of the array\\nx:ArrayInsert(\\"MyArray\\", 1, \\"Hello\\") -- Inserts \\"Hello\\" at index 1\\nx:ArrayInsert(\\"MyArray\\", 1) -- appends 1 to the end of the array\\nx:ArrayInsert(\\"MyArray\\", 1, 2) -- Inserts 2 at index 1\\n```","params":[{"name":"path","desc":"","lua_type":"Path"},{"name":"...","desc":"","lua_type":"any"}],"returns":[],"function_type":"method","source":{"line":722,"path":"lib/tablemanager/src/init.luau"}},{"name":"ArrayRemove","desc":"Removes the value at the given index from the array at the given path.\\nIf no index is given, it will remove the last value in the array.\\nReturns the value that was removed if one was.","params":[{"name":"path","desc":"","lua_type":"Path"},{"name":"index","desc":"","lua_type":"number?"}],"returns":[{"desc":"","lua_type":"any\\n"}],"function_type":"method","source":{"line":762,"path":"lib/tablemanager/src/init.luau"}},{"name":"ArrayRemoveFirstValue","desc":"Removes the first instance of the given value from the array at the given path.\\nReturns a number indicating the index that it was was removed from if one was.","params":[{"name":"path","desc":"","lua_type":"Path"},{"name":"value","desc":"","lua_type":"any"}],"returns":[{"desc":"","lua_type":"number?\\n"}],"function_type":"method","source":{"line":794,"path":"lib/tablemanager/src/init.luau"}},{"name":"Get","desc":"Fetches the value at the given path.\\nAccepts a string path or an array path.\\nAccepts an optional secondary argument to fetch a value at an index in an array.\\nAliases: `GetValue`\\n\\n```lua\\nlocal manager = TableManager.new({\\n    Currency = {\\n        Coins = 100;\\n        Gems = 10;\\n    };\\n})\\n\\n-- The following are all equivalent acceptable methods of fetching the value.\\nprint(manager:Get(\\"Currency.Coins\\")) -- 100\\nprint(manager:Get({\\"Currency\\", \\"Coins\\"})) -- 100\\nprint(manager:Get().Currency.Coins) -- 100\\n```\\n:::note Getting the Root Table\\nCalling `:Get()` with no arguments, an empty string,\\nor an empty table will return the root table.\\n:::","params":[{"name":"path","desc":"","lua_type":"Path"},{"name":"idx","desc":"","lua_type":"(number | string)?"}],"returns":[{"desc":"","lua_type":"any\\n"}],"function_type":"method","source":{"line":860,"path":"lib/tablemanager/src/init.luau"}},{"name":"ToTableState","desc":"Returns a <a href=\\"https://supersocial.github.io/orion/api/TableState\\">TableState</a> Object for the given path.\\n:::warning\\nThis method is not feature complete and does not work for all edge cases and should be used with caution.\\n:::\\n```lua\\nlocal path = \\"MyPath.To.Value\\"\\nlocal state = manager:ToTableState(path)\\n\\nstate:Set(100)\\nmanager:Increment(path, 50)\\nstate:Increment(25)\\n\\nprint(state:Get()) -- 175\\n```","params":[{"name":"path","desc":"","lua_type":"Path"}],"returns":[{"desc":"","lua_type":"TableState\\n"}],"function_type":"method","source":{"line":903,"path":"lib/tablemanager/src/init.luau"}},{"name":"ToFusionState","desc":"Returns a Fusion State object that is bound to the value at the given path.\\nThis method is memoized so calling it repeatedly with the same path will\\nreturn the same State object and quickly.\\n:::caution Deffered Signals\\nThe value of the Fusion State object is updated via the ValueChanged listener\\nand thus may be deffered if your signals are deffered.\\n:::\\n:::caution Setting\\nAlthough this currently returns a Fusion Value object, it is not recommended to set the value\\nas this may be a Computed in the future. Setting the state will not actually change the value\\nin the TableManager.\\n:::\\n\\n```lua\\nlocal path = \\"MyPath.To.Value\\"\\n\\nmanager:SetValue(path, 100)\\nlocal state = manager:ToFusionState(path)\\nprint(peek(state)) -- 100\\n\\nmanager:SetValue(path, 200)\\ntask.wait() -- If your signals are deffered then the state will update on the next frame\\nprint(peek(state)) -- 200\\n```","params":[{"name":"path","desc":"","lua_type":"Path"}],"returns":[{"desc":"","lua_type":"FusionState<any>\\n"}],"function_type":"method","source":{"line":942,"path":"lib/tablemanager/src/init.luau"}},{"name":"PromiseValue","desc":"Creates a promise that resolves when the given condition is met. The condition is immediately and\\nevery time the value changes. If no condition is given then it will resolve with the current value\\nunless it is nil, in which case it will resolve on the first change.","params":[{"name":"path","desc":"","lua_type":"Path"},{"name":"condition","desc":"","lua_type":"(value: any?) -> (boolean)"}],"returns":[{"desc":"","lua_type":"Promise\\n"}],"function_type":"method","source":{"line":956,"path":"lib/tablemanager/src/init.luau"}},{"name":"Observe","desc":"Observes a value at a path and calls the function immediately with the current value, as well as when it changes.\\n:::caution Listening to nil values\\nIt will *NOT* fire if the new/starting value is nil, unless runOnNil is true. When it changes from nil, the oldValue will\\nbe the last known non nil value. The binding call of the function is an exception and will give nil as the oldValue.\\nThis is done so that Observe can be used to execute instructions when a value is percieved as \'ready\'.\\n:::\\n\\n\\n\\n\\n\\n```lua\\nlocal path = \\"MyPath.To.Value\\"\\nlocal connection = manager:Observe(path, function(newValue)\\n    print(\\"Value at\\", path, \\"is\\", newValue)\\nend)\\n\\nconnection() -- Disconnects the listener\\n```","params":[{"name":"path","desc":"The path to the value to observe.","lua_type":"Path"},{"name":"fn","desc":"The function to call when the value changes.","lua_type":"ValueListenerFn"},{"name":"runOnNil","desc":"Whether or not to fire the function when the value is nil.","lua_type":"boolean?"}],"returns":[{"desc":"A connection used to disconnect the listener.","lua_type":"Connection"}],"function_type":"method","source":{"line":1006,"path":"lib/tablemanager/src/init.luau"}},{"name":"ListenToKeyChange","desc":"Listens to a change at a specified path and calls the function when the value changes.\\n\\n```lua\\nmanager:Set(\\"Stats\\", {\\n    Health = 100;\\n    Mana = 50;\\n})\\n\\nlocal connection = manager:ListenToKeyChange(\\"Stats\\", function(key, newValue)\\n    print(`{key} changed to {newValue}`)\\nend)\\n\\nmanager:SetValue(\\"Stats.Health\\", 200) -- Health changed to 200\\nmanager:SetValue(\\"Stats.Mana\\", 100) -- Mana changed to 100\\n```","params":[{"name":"parentPath","desc":"","lua_type":"Path?"},{"name":"fn","desc":"","lua_type":"(keyChanged: any, newValue: any, oldValue: any) -> ()"}],"returns":[],"function_type":"method","source":{"line":1045,"path":"lib/tablemanager/src/init.luau"}},{"name":"ListenToKeyAdd","desc":"Listens to when a new key is added (Changed from nil) to a table at a specified path and calls the function.","params":[{"name":"parentPath","desc":"","lua_type":"Path?"},{"name":"fn","desc":"","lua_type":"(newKey: any, newValue: any) -> ()"}],"returns":[{"desc":"","lua_type":"Connection\\n"}],"function_type":"method","source":{"line":1096,"path":"lib/tablemanager/src/init.luau"}},{"name":"ListenToKeyRemove","desc":"Listens to when a key is removed (Set to nil) from a table at a specified path and calls the function.","params":[{"name":"parentPath","desc":"","lua_type":"Path?"},{"name":"fn","desc":"","lua_type":"(removedKey: any, lastValue: any) -> ()"}],"returns":[{"desc":"","lua_type":"Connection\\n"}],"function_type":"method","source":{"line":1109,"path":"lib/tablemanager/src/init.luau"}},{"name":"ListenToValueChange","desc":"Listens to a change at a specified path and calls the function when the value changes.\\nThis does NOT fire when the value is an array/dictionary and one of its children changes.\\n```lua\\nlocal connection = manager:ListenToValueChange(\\"MyPath.To.Value\\", function(newValue, oldValue)\\n    print(\\"Value changed from\\", oldValue, \\"to\\", newValue)\\nend)\\n\\nconnection() -- Disconnects the listener\\n```","params":[{"name":"path","desc":"","lua_type":"Path"},{"name":"fn","desc":"","lua_type":"ValueListenerFn"}],"returns":[{"desc":"","lua_type":"Connection\\n"}],"function_type":"method","source":{"line":1130,"path":"lib/tablemanager/src/init.luau"}},{"name":"ListenToArraySet","desc":"Listens to when an index is set in an array at a specified path and calls the function.\\nThe function receives the index and the new value.\\n:::caution\\nThe array listeners do not fire from changes to parent or child values.\\n:::","params":[{"name":"path","desc":"","lua_type":"Path"},{"name":"fn","desc":"","lua_type":"(changedIndex: number, newValue: any) -> ()"}],"returns":[{"desc":"","lua_type":"Connection\\n"}],"function_type":"method","source":{"line":1143,"path":"lib/tablemanager/src/init.luau"}},{"name":"ListenToArrayInsert","desc":"Listens to when a value is inserted into an array at a specified path and calls the function when the value changes.","params":[{"name":"path","desc":"","lua_type":"Path"},{"name":"fn","desc":"","lua_type":"(changedIndex: number, newValue: any) -> ()"}],"returns":[{"desc":"","lua_type":"Connection\\n"}],"function_type":"method","source":{"line":1152,"path":"lib/tablemanager/src/init.luau"}},{"name":"ListenToArrayRemove","desc":"Listens to when a value is removed from an array at a specified path and calls the function.","params":[{"name":"path","desc":"","lua_type":"Path"},{"name":"fn","desc":"","lua_type":"(oldIndex: number, oldValue: any) -> ()"}],"returns":[{"desc":"","lua_type":"Connection\\n"}],"function_type":"method","source":{"line":1162,"path":"lib/tablemanager/src/init.luau"}},{"name":"_GetRawData","desc":"Gets the top level table being managed by this TableManager.","params":[],"returns":[],"function_type":"method","private":true,"source":{"line":1183,"path":"lib/tablemanager/src/init.luau"}},{"name":"_AddToListeners","desc":"","params":[{"name":"listenerType","desc":"","lua_type":"ListenerType"},{"name":"path","desc":"","lua_type":"Path"},{"name":"listenerFn","desc":"","lua_type":"(...any) -> ()"}],"returns":[{"desc":"","lua_type":"Connection\\n"}],"function_type":"method","private":true,"source":{"line":1190,"path":"lib/tablemanager/src/init.luau"}},{"name":"_UpsertListenerTableForPath","desc":"Creates a listener table for the given path if it doesn\'t exist.\\nReturns the listener table.","params":[{"name":"listenerType","desc":"","lua_type":"ListenerType"},{"name":"pathArray","desc":"","lua_type":"PathArray"}],"returns":[{"desc":"","lua_type":"{[any]: any}\\n"}],"function_type":"method","private":true,"source":{"line":1224,"path":"lib/tablemanager/src/init.luau"}},{"name":"_GetListenerSignalForPath","desc":"Gets the listener signal for the given path if it exists.","params":[{"name":"listenerType","desc":"","lua_type":"ListenerType"},{"name":"pathArray","desc":"","lua_type":"PathArray"}],"returns":[{"desc":"","lua_type":"SignalInternal?\\n"}],"function_type":"method","private":true,"source":{"line":1263,"path":"lib/tablemanager/src/init.luau"}},{"name":"_FireListeners","desc":"Fires listeners for the given path.\\nTakes a bunch of props to make processing less intensive. I want to improve performance for this.","params":[{"name":"props","desc":"","lua_type":"{\\n    Path: {string};\\n    ArrayPath: {string}?;\\n    ArrayIndex: number?;\\n    ListenerType: ListenerType;\\n    ListenerContainer: ListenerContainer?;\\n    NewValue: any;\\n    OldValue: any;\\n}"}],"returns":[],"function_type":"method","private":true,"source":{"line":1283,"path":"lib/tablemanager/src/init.luau"}},{"name":"_FireChildListeners","desc":"Fires child listeners for the given path.","params":[{"name":"_metadata","desc":"","lua_type":"ChangeMetadata"},{"name":"_listenerContainer","desc":"","lua_type":"ListenerContainer"}],"returns":[],"function_type":"method","private":true,"source":{"line":1353,"path":"lib/tablemanager/src/init.luau"}},{"name":"_FireParentListeners","desc":"Fires parent listeners for the given path.","params":[{"name":"_metadata","desc":"","lua_type":"ChangeMetadata"}],"returns":[{"desc":"","lua_type":"ListenerContainer?\\n"}],"function_type":"method","private":true,"source":{"line":1387,"path":"lib/tablemanager/src/init.luau"}},{"name":"_SetValue","desc":"","params":[{"name":"path","desc":"","lua_type":"Path"},{"name":"newValue","desc":"","lua_type":"any"},{"name":"lastKey","desc":"","lua_type":"(string)?"}],"returns":[],"function_type":"method","private":true,"source":{"line":1444,"path":"lib/tablemanager/src/init.luau"}}],"properties":[{"name":"Enums","desc":"A collection of enums used by the TableManager.","lua_type":"{ListenerType: ListenerTypeEnum, DataChangeSource: DataChangeSourceEnum}","source":{"line":284,"path":"lib/tablemanager/src/init.luau"}}],"types":[{"name":"CanBeArray<T>","desc":"A type that could be an individual of the type or an array of the type.","lua_type":"T | {T}","source":{"line":66,"path":"lib/tablemanager/src/init.luau"}},{"name":"Path","desc":"A path to a value in a table.\\nCan be written as a string in dot format or an array of strings.\\n:::Note\\nThe array format is faster to parse and should be used when possible.\\n:::\\n```lua\\nlocal tbl = {\\n    MyPath = {\\n        To = {\\n            Value = 0;\\n        };\\n    };\\n}\\n\\nlocal path1: Path = \\"MyPath.To.Value\\" -- Style 1\\nlocal path2: Path = {\\"MyPath\\", \\"To\\", \\"Value\\"} -- Style 2\\n```","lua_type":"string | {any}","source":{"line":89,"path":"lib/tablemanager/src/init.luau"}},{"name":"ValueListenerFn","desc":"","lua_type":"(newValue: any, oldValue: any?, changeMetadata: ChangeMetadata?) -> ()","source":{"line":96,"path":"lib/tablemanager/src/init.luau"}},{"name":"ListenerType","desc":"This information is mostly for internal use.","lua_type":"\\"ValueChanged\\" | \\"ArraySet\\" | \\"ArrayInsert\\" | \\"ArrayRemove\\"","source":{"line":107,"path":"lib/tablemanager/src/init.luau"}},{"name":"DataChangeSource","desc":"This information is mostly for internal use.","lua_type":"\\"self\\" | \\"child\\" | \\"parent\\"","source":{"line":122,"path":"lib/tablemanager/src/init.luau"}},{"name":"ChangeMetadata","desc":"Metadata about the change that fired a listener. Used to provide more context to listeners.\\nAllows you to figure out where the change came from, if it wasnt a direct change.","fields":[{"name":"ListenerType","lua_type":"ListenerType","desc":"The listener type that was fired."},{"name":"SourceDirection","lua_type":"DataChangeSource","desc":"The source direction of the change."},{"name":"SourcePath","lua_type":"{string}","desc":"The origin path of the change."},{"name":"NewValue","lua_type":"any?","desc":"[Only for value changes] The new value."},{"name":"OldValue","lua_type":"any?","desc":"[Only for value changes] The old value."}],"source":{"line":141,"path":"lib/tablemanager/src/init.luau"}}],"name":"TableManager","desc":"A class for managing a table such that you can listen to changes and modify values easily.\\nTableManager is designed to provide robust listener functionality at the cost of some performance.\\n\\n:::tip\\nThe TableManager has some methods to combine functionality for both values and arrays.\\nIt will redirect to the proper method depending on your given arguments.\\n```lua\\n:Set() -- Redirects to :SetValue() or :ArraySet()\\n:Increment() -- Redirects to :IncrementValue() or :ArrayIncrement()\\n:Update() -- Redirects to :UpdateValue() or :UpdateArray()\\n```\\n:::\\n:::info Signals\\nTableManager has Signals you can access if you want to utilize the raw events with libraries\\nthat can take advantage of signals like Promises.\\n```lua\\n:GetSignal(\\"ValueChanged\\")\\n:GetSignal(\\"ArraySet\\")\\n:GetSignal(\\"ArrayInsert\\")\\n:GetSignal(\\"ArrayRemove\\")\\n```\\n:::","source":{"line":29,"path":"lib/tablemanager/src/init.luau"}}')}}]);
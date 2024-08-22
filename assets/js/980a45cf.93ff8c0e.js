"use strict";(self.webpackChunkdocs=self.webpackChunkdocs||[]).push([[3400],{79689:e=>{e.exports=JSON.parse('{"functions":[{"name":"getObjectFromId","desc":"Fetches the object with the given ID if it exists.\\n\\n```lua\\nlocal obj = BaseObject.new()\\n\\nlocal id = obj:GetId()\\n\\nprint(BaseObject.getObjectFromId(id) == obj) -- true\\n```","params":[{"name":"id","desc":"","lua_type":"number"}],"returns":[{"desc":"","lua_type":"BaseObject?"}],"function_type":"static","tags":["static"],"source":{"line":150,"path":"lib/baseobject/src/init.lua"}},{"name":"isDestroyed","desc":"Checks whether or not the object is destroyed.\\n\\n```lua\\nlocal obj = BaseObject.new()\\n\\nprint(BaseObject.isDestroyed(obj)) -- false\\n\\nobj:Destroy()\\n\\nprint(BaseObject.isDestroyed(obj)) -- true\\n```","params":[{"name":"self","desc":"","lua_type":"BaseObject"}],"returns":[{"desc":"","lua_type":"boolean"}],"function_type":"static","tags":["static"],"source":{"line":169,"path":"lib/baseobject/src/init.lua"}},{"name":"new","desc":"Constructs a new BaseObject\\n\\n\\n\\n```lua\\nlocal obj = BaseObject.new({\\n\\tX = 1,\\n\\tY = 2,\\n})\\n\\nobj.Z = 3\\n\\nprint(obj.X, obj.Y, obj.Z) -- 1, 2, 3\\n```\\n\\n```lua\\nlocal SuperClass = setmetatable({}, BaseObject)\\nSuperClass.__index = SuperClass\\nSuperClass.ClassName = \\"SuperClass\\"\\n\\nfunction SuperClass.new()\\n\\tlocal self = setmetatable(BaseObject.new(), SuperClass)\\n\\treturn self\\nend\\n\\nfunction SuperClass:Destroy() -- Overwrite the BaseObject Destroy method\\n\\tgetmetatable(SuperClass).Destroy(self) -- If you overwrite the BaseObject Destroy method you need to have this line to call the original.\\nend\\n\\nfunction SuperClass:Print()\\n\\tprint(\\"Hello, World!\\")\\nend\\n\\nreturn SuperClass\\n```","params":[{"name":"tbl","desc":"Table to construct the BaseObject with","lua_type":"{ [any]: any }?"}],"returns":[{"desc":"","lua_type":"BaseObject"}],"function_type":"static","tags":["static"],"source":{"line":214,"path":"lib/baseobject/src/init.lua"}},{"name":"Destroy","desc":"Marks the Object as Destroyed, fires the Destroyed Signal, cleans up\\nthe BaseObject, and sets the metatable to nil/a special locked MT.\\n:::caution Overriding\\nIf you override this method, you need to make sure you call\\n`getmetatable(self).Destroy(self)` to call the superclass methods.\\n```lua\\nfunction MyCustomClass:Destroy()\\n\\tgetmetatable(SuperClass).Destroy(self) -- calls the superclass method to clean up events, tasks, etc..\\nend\\n```","params":[],"returns":[],"function_type":"method","source":{"line":246,"path":"lib/baseobject/src/init.lua"}},{"name":"GetId","desc":"Returns the ID of the BaseObject\\nCan be used to fetch the object with BaseObject.getObjectFromId(id)","params":[],"returns":[{"desc":"","lua_type":"number\\n"}],"function_type":"method","source":{"line":278,"path":"lib/baseobject/src/init.lua"}},{"name":"IsA","desc":"Returns true if the given object is of a given class.\\nTakes a class name or class object.","params":[{"name":"classOrClassName","desc":"","lua_type":"{[any]: any} | string"}],"returns":[{"desc":"","lua_type":"boolean\\n"}],"function_type":"method","source":{"line":286,"path":"lib/baseobject/src/init.lua"}},{"name":"GetTask","desc":"Fetches the task with the given ID if it exists.\\n\\n```lua\\nlocal obj = BaseObject.new()\\n\\nlocal part = Instance.new(\\"Part\\")\\n\\nobj:AddTask(part, nil, \\"Test\\")\\n\\nprint(obj:GetTask(\\"Test\\") == part) -- true\\n```","params":[{"name":"taskId","desc":"","lua_type":"any"}],"returns":[{"desc":"","lua_type":"Task?"}],"function_type":"method","source":{"line":318,"path":"lib/baseobject/src/init.lua"}},{"name":"AddTask","desc":"Adds a task to the janitor. If a taskId is provided, it will be used as the\\nkey for the task in the janitor and can then be fetched later with :GetTask().\\nIf an ID is provided and there already exists a task with that ID, it will\\nclean up the existing task and then replace the index with the new one.\\nIt will return the task that was added/given.\\n\\n```lua\\nlocal obj = BaseObject.new()\\n\\nlocal task = obj:AddTask(function()\\n\\tprint(\\"Hello, World!\\")\\nend)\\n\\nobj:Destroy() -- Prints \\"Hello, World!\\"\\n```","params":[{"name":"task","desc":"","lua_type":"Task"},{"name":"taskCleanupMethod","desc":"(if none is given it will try to infer; Passing true tells it to call it as a function)","lua_type":"(string | true | nil)?"},{"name":"taskId","desc":"","lua_type":"any?"}],"returns":[{"desc":"The task that was given","lua_type":"Task"}],"function_type":"method","source":{"line":343,"path":"lib/baseobject/src/init.lua"}},{"name":"AddPromise","desc":"Adds a promise to the janitor. Similar to :AddTask(). Returns the same Promise\\nthat was given to it.\\n\\n```lua\\nlocal prom = Promise.delay(math.random(10))\\n\\nlocal obj = BaseObject.new()\\nobj:AddPromise(prom)\\n\\ntask.wait(math.random(10))\\n\\nobj:Destroy() -- Cancels the promise if it hasn\'t resolved yet\\n```","params":[{"name":"prom","desc":"","lua_type":"Promise"}],"returns":[{"desc":"","lua_type":"Promise"}],"function_type":"method","source":{"line":365,"path":"lib/baseobject/src/init.lua"}},{"name":"RemoveTask","desc":"Removes a task from the janitor. Cleans the task as if :DoCleaning was called.\\nIf dontClean is true, it will not clean up the task, it will just remove\\nit from the janitor.\\n\\n```lua\\nlocal obj = BaseObject.new()\\n\\nlocal task = obj:AddTask(function()\\n\\tprint(\\"Hello, World!\\")\\nend, nil, \\"Test\\")\\n\\nobj:RemoveTask(\\"Test\\") -- Prints \\"Hello, World!\\"\\n```","params":[{"name":"taskId","desc":"","lua_type":"any"},{"name":"dontClean","desc":"","lua_type":"boolean?"}],"returns":[],"function_type":"method","source":{"line":388,"path":"lib/baseobject/src/init.lua"}},{"name":"RemoveTaskNoClean","desc":"Removes a task from the janitor without cleaning it.\\n\\n```lua\\nlocal obj = BaseObject.new()\\n\\nlocal task = obj:AddTask(function()\\n\\tprint(\\"Hello, World!\\")\\nend, nil, \\"Test\\")\\n\\nobj:RemoveTaskNoClean(\\"Test\\") -- Does NOT print \\"Hello, World!\\"\\n```","params":[{"name":"taskId","desc":"","lua_type":"any"}],"returns":[],"function_type":"method","source":{"line":409,"path":"lib/baseobject/src/init.lua"}},{"name":"FireSignal","desc":"Fires the signal with the given name, if it exists.\\nEquivalent to calling `:GetSignal(signalName):Fire(...)` except this does not require\\nthe signal to exist first.\\n\\n```lua\\nlocal obj = BaseObject.new()\\nlocal SignalName = \\"Test\\"\\n\\nobj:RegisterSignal(SignalName)\\n\\nobj:GetSignal(SignalName):Connect(print)\\n\\nobj:FireSignal(SignalName, \\"Hello, World!\\") -- Fires the signal with the argument \\"Hello, World!\\"\\n```","params":[{"name":"signalName","desc":"The name of the signal to fire","lua_type":"string"},{"name":"...","desc":"Arguments to pass to the signal","lua_type":"any"}],"returns":[],"function_type":"method","source":{"line":435,"path":"lib/baseobject/src/init.lua"}},{"name":"RegisterSignal","desc":"Marks a signal with the given name as registered. Does not actually\\nbuild a new signal, it sets the index to a SignalMarker to identify\\nit as registered so that it can be fetched later.","params":[{"name":"signalName","desc":"Name of signal to register","lua_type":"string"}],"returns":[],"function_type":"method","source":{"line":448,"path":"lib/baseobject/src/init.lua"}},{"name":"HasSignal","desc":"Checks whether or not a signal with the given name is registered.\\n\\n```lua\\nlocal obj = BaseObject.new()\\n\\nlocal SignalName = \\"Test\\"\\n\\nprint(obj:HasSignal(SignalName)) -- false\\n\\nobj:RegisterSignal(SignalName)\\n\\nprint(obj:HasSignal(SignalName)) -- true\\n```","params":[{"name":"signalName","desc":"","lua_type":"string"}],"returns":[{"desc":"","lua_type":"boolean\\n"}],"function_type":"method","source":{"line":476,"path":"lib/baseobject/src/init.lua"}},{"name":"GetSignal","desc":"Fetches a signal with the given name. Creates the Signal JIT.","params":[{"name":"signalName","desc":"","lua_type":"string"}],"returns":[{"desc":"","lua_type":"Signal"}],"function_type":"method","source":{"line":485,"path":"lib/baseobject/src/init.lua"}},{"name":"GetDestroyedSignal","desc":"Returns a signal that fires when the object is destroyed. Creates the signal JIT.\\nKept for backwards compatibility.\\n\\n```lua\\nlocal obj = BaseObject.new()\\n\\nobj:GetDestroyedSignal():Connect(function()\\n\\tprint(\\"Object Destroyed!\\")\\nend)\\n\\nobj:Destroy() -- Prints \\"Object Destroyed!\\"\\n```","params":[],"returns":[{"desc":"","lua_type":"Signal\\n"}],"function_type":"method","source":{"line":516,"path":"lib/baseobject/src/init.lua"}},{"name":"BindToInstance","desc":"Binds the object to the given instance. When the object is destroyed, it will\\ndestroy the instance. When the instance is destroyed, it will destroy the object.\\n\\n```lua\\nlocal obj = BaseObject.new()\\nlocal part = Instance.new(\\"Part\\")\\nobj:BindToInstance(part)\\n\\ndo -- setup prints on destroy\\n\\tobj:AddTask(function()\\n\\t\\tprint(\\"Object Destroyed!\\")\\n\\tend)\\n\\n\\tpart.Destroying:Connect(function()\\n\\t\\tprint(\\"Part Destroyed!\\")\\n\\tend)\\nend\\n\\nlocal X = if math.random(1,2) == 1 then obj or part\\nX:Destroy() -- Prints \\"Object Destroyed!\\" and \\"Part Destroyed!\\" (Destroying one will destroy the other)\\n```","params":[{"name":"obj","desc":"","lua_type":"Instance"},{"name":"destroyOnNilParent","desc":"Whether or not to destroy the object when the parent is nil\'d","lua_type":"boolean?"}],"returns":[{"desc":"Disconnects the binding","lua_type":"function"}],"function_type":"method","source":{"line":556,"path":"lib/baseobject/src/init.lua"}}],"properties":[{"name":"ClassName","desc":"","lua_type":"string","readonly":true,"source":{"line":134,"path":"lib/baseobject/src/init.lua"}}],"types":[{"name":"BaseObject","desc":"","lua_type":"BaseObject","source":{"line":128,"path":"lib/baseobject/src/init.lua"}}],"name":"BaseObject","desc":"BaseObject provides interface methods for three core features:\\n- Object Destruction via adding a :Destroy() method and IsDestroyed flag property,\\n- Task Management across the objects lifetime by providing a janitor internally,\\n- and Signal Management by providing interfaces to Register, Get, and Fire signals easily.\\n\\n\\nDestroy Behavior:\\n* When a BaseObject instance is destroyed, it\'s `IsDestroyed` property is set to true, and it\'s `Destroyed` signal is fired.\\n* It\'s metatable is set to a metatable that will error when any of it\'s methods or metamethods are called.\\n\\nYou should check `IsDestroyed` before calling any methods on a BaseObject instance if you are not sure if it has been destroyed or not.","source":{"line":19,"path":"lib/baseobject/src/init.lua"}}')}}]);
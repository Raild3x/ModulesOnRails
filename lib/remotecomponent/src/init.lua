--[=[
	@class RemoteComponent

	RemoteComponent is a component extension that allows you to easily give
	networking capabilities to your components.

	You can access the server-side component from the client by using the .Server index
	on the component. You can access the client-side component from the server by using
	the .Client index on the component.

	:::caution Fast tagging and untagging
	You can encounter issues if you untag and then retag again quickly or unparent and
	reparent to the same location on the server. This is because the server will rebuild the
	component, but the client will not recognize that there was a change as collectionservice
	wont think anything is different and their remotes can become desynced.
	:::

	:::caution RemoteComponent Usage Limitations
	Accessing `.Server` or `.Client` is only safe to do so once the client has completed its 
	extension 'Starting' cycle and began its `:Start()` method
	:::

	:::caution Yielding accidents
	When using RemoteComponent, you *must* have both a client and server component. If you do not,
	then the client will yield until the server component is created. If only one side extends RemoteComponent,
	then you may encounter infinite yields.
	:::
]=]

--[=[
	@interface RemoteComponent
	@within RemoteComponent
	.Client table? -- Only availible on the server. Set this to a table to expose it to the client.
	.Server table? -- Only availible on the client. The indices of this are inferred from the server.

	```lua
	-- MyComponent.server.lua
	local MyComponent = Component.new {
		Tag = "MyComponent",
		Ancestors = {workspace},
		Extensions = {RemoteComponent},
	}

	MyComponent.Client = {
		TestProperty = NetWire.createProperty(0),
		TestSignal = NetWire.createEvent(),
	}

	function MyComponent.Client:TestMethod(player: Player)
		return ("Hello from the server!")
	end
	```

	```lua
	-- MyComponent.client.lua
	local MyComponent = Component.new {
		Tag = "MyComponent",
		Ancestors = {workspace},
		Extensions = {RemoteComponent},
	}

	function MyComponent:Start()
		self.Server:TestMethod():andThen(print)
	end
	```
]=]

local IS_SERVER = game:GetService("RunService"):IsServer()

--// Imports //--
local Packages = script.Parent
local Comm = require(Packages.Comm)
local Symbol = require(Packages.Symbol)
local Promise = require(Packages.Promise)
local TableUtil = require(Packages.RailUtil).Table

--// Constants //--
local KEY_INTERNALPROMISE = Symbol("InternalPromise")
local SERVER_REMOTE_COUNT = "SRC"
local TIMEOUT = 30

Comm = if IS_SERVER then Comm.ServerComm else Comm.ClientComm

--------------------------------------------------------------------------------
	--// Extension //--
--------------------------------------------------------------------------------
local RemoteComponentExtension = {}

function RemoteComponentExtension.Starting(component)
	local objectInstance = component.Instance
	local nameSpace = component.RemoteNamespace or component.Tag
	if IS_SERVER then
		if component.Client then
			component.Client = TableUtil.Copy(component.Client, true) -- Makes a deep copy of the Client table

			if objectInstance:FindFirstChild(nameSpace) then
				warn("RemoteComponent: Namespace "..nameSpace.." already exists, overwriting")
				objectInstance[nameSpace]:Destroy()
			end
			component._serverComm = Comm.new(objectInstance, nameSpace)

			local totalRemotes = 0
			for k, v in pairs(component.Client) do
				totalRemotes += 1
				if type(v) == "function" then
					component._serverComm:WrapMethod(component.Client, k)
				elseif tostring(v):find("SIGNAL_MARKER") then -- Allow Wire.createSignal()
					component.Client[k] = component._serverComm:CreateSignal(k)
				elseif type(v) == "table" and tostring(v[1]):find("PROPERTY_MARKER") then  -- Allow Wire.createProperty()
					component.Client[k] = component._serverComm:CreateProperty(k, v[2])
				end
			end
			component.Client.Server = component

			objectInstance[nameSpace]:SetAttribute(SERVER_REMOTE_COUNT, totalRemotes)
		else
			warn(nameSpace.." extends RemoteComponent but is missing a Client table!")
		end

	else
		-- if objectInstance:FindFirstChild(nameSpace) then
		-- 	assert(not objectInstance:FindFirstChild(nameSpace):GetAttribute("ClientComponentReady"), "Client Component already initialized!")
		-- end

		component[KEY_INTERNALPROMISE] = Promise.new(function(resolve, _, onCancel)
			local instanceFolder = objectInstance:WaitForChild(nameSpace)

			if not instanceFolder:GetAttribute(SERVER_REMOTE_COUNT) then
				instanceFolder:GetAttributeChangedSignal(SERVER_REMOTE_COUNT):Wait()
			end

			-- Fetch number of existing remotes on client
			local function GetRemotes()
				local rfFolder = instanceFolder:FindFirstChild("RF")
				local reFolder = instanceFolder:FindFirstChild("RE")
				local rpFolder = instanceFolder:FindFirstChild("RP")

				local r = 0
				if rfFolder then
					r += #rfFolder:GetChildren()
				end
				if reFolder then
					r += #reFolder:GetChildren()
				end
				if rpFolder then
					r += #rpFolder:GetChildren()
				end
				return r
			end

			-- Wait for the server to replicate all the remotes
			while GetRemotes() < instanceFolder:GetAttribute(SERVER_REMOTE_COUNT) do
				task.wait()
			end

			resolve()
		end)
		:andThen(function()
			local usePromises = if component.UsePromisesForMethods == nil then true else component.UsePromisesForMethods
			local clientComm = Comm.new(objectInstance, usePromises, nameSpace)
			component._clientComm = clientComm
			component.Server = clientComm:BuildObject()
		end)
		:timeout(TIMEOUT, "[TimeOut] Failed to initialize RemoteComponent "..nameSpace)
		
		local status, err = component[KEY_INTERNALPROMISE]:awaitStatus()
		if status == Promise.Status.Rejected then
			error(err)
		elseif status == Promise.Status.Cancelled then
			error("RemoteComponent "..nameSpace.." was cancelled before it could initialize.")
		end
	end
end

function RemoteComponentExtension.Stopping(component)
	local target = IS_SERVER and "_serverComm" or "_clientComm"
	if component[target] then component[target]:Destroy() end
	if component[KEY_INTERNALPROMISE] then
		component[KEY_INTERNALPROMISE]:cancel()
	end
end

return RemoteComponentExtension

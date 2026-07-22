--[=[
	@class RemoteComponent

	RemoteComponent is a component extension that allows you to easily give
	networking capabilities to your components.

	You can access the server-side component from the client by using the `.Server` index
	on the component. You can access the client-side component from the server by using
	the `.Client` index on the component.

	```lua
	-- MyComponent.server.lua
	local MyComponent = Component.new {
		Tag = "MyComponent",
		Ancestors = {workspace},
		Extensions = {RemoteComponent},
	}

	MyComponent.Client = {
		TestProperty = RemoteComponent.createProperty(0),
		TestSignal = RemoteComponent.createEvent(),
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

	## Extension remotes

	Other component extensions can contribute their own remotes to a component
	without owning its `Client` table. Declare `RemoteComponent` as a dependency
	and register in your `Constructing` hook (dependency ordering guarantees this
	runs after RemoteComponent's `Constructing` and before its `Starting`). Access
	the built remotes from your `Starting` hook onward via [RemoteComponent.getRemotes].

	The extension module is shared across both realms. `addRemotes` only does work
	on the server; on the client it is a no-op, because the client recovers these
	remotes from their replicated names rather than from registration.

	```lua
	local RunService = game:GetService("RunService")

	local WeaponExtension = {}
	WeaponExtension.Extensions = {RemoteComponent}

	function WeaponExtension.Constructing(component)
		-- Runs on both realms; the client call is a no-op.
		RemoteComponent.addRemotes(component, "Weapon", {
			Ammo = RemoteComponent.createProperty(30),   -- RP: server -> client state
			Hit = RemoteComponent.createEvent(),          -- RE: server -> client event
			Shoot = function(self, player, target)         -- RF: client -> server method
				-- `self` is the server sub-object (carries `.Server`); `player` is injected.
				self.Ammo:Set(player, self.Ammo:Get(player) - 1)
				return true
			end,
		})
	end
	```

	### Server usage

	```lua
	function WeaponExtension.Starting(component)
		if not RunService:IsServer() then return end
		local remotes = RemoteComponent.getRemotes(component, "Weapon")
		remotes.Ammo:SetTop(30)
		remotes.Hit:FireAll(Vector3.zero)
		-- remotes.Server == component  (server-only back-reference)
	end
	```

	### Client usage

	On the client the sub-object holds the same keys, but as *client-side* objects:
	methods return Promises and **must be called with `:`** (Comm's method wrapper
	consumes the first `self` argument, so a dot-call would drop the real
	arguments — RemoteComponent guards against this and raises a clear error rather
	than silently sending the wrong request), signals expose `:Connect`, and
	properties expose `:Get` / `:Observe`. There is no `.Server` back-reference in
	the client sub-object.

	```lua
	function WeaponExtension.Starting(component)
		if RunService:IsServer() then return end
		local remotes = RemoteComponent.getRemotes(component, "Weapon")

		print("ammo:", remotes.Ammo:Get())               -- property: read
		remotes.Ammo:Observe(function(ammo) --[[ ... ]] end) -- property: observe
		remotes.Hit:Connect(function(hitPosition) --[[ ... ]] end) -- event: connect

		remotes:Shoot(someTarget)                          -- method: colon call, returns a Promise
			:andThen(function(didFire) --[[ ... ]] end)
	end
	```

	### Internal vs exposed

	Registered remotes are *internal* by default: their names are prefixed with the
	namespace under the hood, and they are reachable only through `getRemotes`, so
	two extensions can never collide. Pass `{exposed = true}` to instead merge the
	remotes flat onto the component's `Client`/`Server` surface (like the fork's
	`Methods` feature) — collisions with the author's remotes or another extension's
	exposed remotes raise a hard error at registration time. Exposed remotes are
	*not* returned by `getRemotes`; on the client they live flat on `component.Server`
	(same colon-call/Promise rules):

	```lua
	-- server: RemoteComponent.addRemotes(component, "Weapon", { Reload = fn }, { exposed = true })
	-- client:
	component.Server:Reload():andThen(print)   -- flat on .Server, not in getRemotes
	```

	Registration is only valid before the component's remotes are built: the window
	opens in `Constructing` and closes when RemoteComponent's `Starting` runs.
	Because a component with registered remotes no longer needs its own `Client`
	table, RemoteComponent will build a namespace for it even when `Client` is nil.
]=]

--[=[
	@interface RemoteComponent
	@within RemoteComponent
	.Client table? -- Only available on the server. Set this to a table to expose it to the client.
	.Server table? -- Only available on the client. The indices of this are inferred from the server.
]=]

local IS_SERVER = game:GetService("RunService"):IsServer()

--// Imports //--
local Packages = script.Parent
local CommPackage = require(Packages.Comm)
local Symbol = require(Packages.Symbol)
local Promise = require(Packages.Promise)
local NetWire = require(Packages.NetWire)
local TableUtil = require(Packages.RailUtil).Table
local Namespacing = require(script.Namespacing)
local ClientMethodGuard = require(script.ClientMethodGuard)

--// Constants //--
local KEY_INTERNALPROMISE = Symbol("InternalPromise")
local KEY_REMOTE_REGISTRY = Symbol("RemoteRegistry")
local SERVER_REMOTE_COUNT = "SRC"
local TIMEOUT = 30
local DELIMITER = Namespacing.DELIMITER

--// Types //--
type RemoteDefs = { [string]: any }
type AddRemotesOpts = { exposed: boolean? }

-- Lazily creates the per-instance remote registry. Shared shape on both sides;
-- only the server populates `registrations`, both derive `built` in Starting.
local function getOrCreateRegistry(component)
	local registry = component[KEY_REMOTE_REGISTRY]
	if not registry then
		registry = { registrations = {}, built = nil, sealed = false }
		component[KEY_REMOTE_REGISTRY] = registry
	end
	return registry
end

-- Constructs a single Comm remote object from a NetWire marker table. `remoteName`
-- is the (possibly prefixed) name given to Comm; returns nil for an unknown marker.
local function buildMarkerRemote(serverComm, remoteName: string, marker: { any }): any?
	local markerType = tostring(marker[1])
	if markerType:find("UNRELIABLE_SIGNAL_MARKER") then
		return serverComm:CreateSignal(remoteName, true, table.unpack(marker, 2))
	elseif markerType:find("SIGNAL_MARKER") then
		return serverComm:CreateSignal(remoteName, false, table.unpack(marker, 2))
	elseif markerType:find("PROPERTY_MARKER") then
		return serverComm:CreateProperty(remoteName, table.unpack(marker, 2))
	end
	return nil
end

--------------------------------------------------------------------------------
--// Extension //--
--------------------------------------------------------------------------------
local RemoteComponentExtension = {}

--[=[
	@within RemoteComponent
	@function createEvent () -> MARKER
	Redirects to NetWire.createEvent
]=]
RemoteComponentExtension.createEvent = NetWire.createEvent

--[=[
	@within RemoteComponent
	@function createUnreliableEvent () -> MARKER
	Redirects to NetWire.createUnreliableEvent
]=]
RemoteComponentExtension.createUnreliableEvent = NetWire.createUnreliableEvent

--[=[
	@within RemoteComponent
	@function createProperty (initialValue: any) -> MARKER
	Redirects to NetWire.createProperty
]=]
RemoteComponentExtension.createProperty = NetWire.createProperty

--[=[
	@within RemoteComponent
	@function addRemotes
	@server

	Registers a set of remote definitions under an extension `namespace`, to be
	built alongside the component's own `Client` remotes. Call this from a
	dependent extension's `Constructing` hook (declare `.Extensions = {RemoteComponent}`
	so ordering is guaranteed). `defs` has the same shape as a component's `Client`
	table (functions become server methods; `createEvent`/`createProperty` markers
	become signals/properties).

	By default the remotes are *internal*: they live under `namespace` and are
	retrieved with [RemoteComponent.getRemotes]. Pass `{exposed = true}` to instead
	merge them flat onto the component's `Client`/`Server` surface (errors on any
	name collision). No-op on the client — the client derives everything from the
	replicated remote names.
]=]
function RemoteComponentExtension.addRemotes(
	component: any,
	namespace: string,
	defs: RemoteDefs,
	opts: AddRemotesOpts?
): ()
	if not IS_SERVER then
		return
	end

	if type(namespace) ~= "string" or namespace == "" then
		error("RemoteComponent.addRemotes: namespace must be a non-empty string", 2)
	end
	if Namespacing.isNamespaced(namespace) then
		error(`RemoteComponent.addRemotes: namespace '{namespace}' may not contain '{DELIMITER}'`, 2)
	end
	if type(defs) ~= "table" then
		error(`RemoteComponent.addRemotes('{namespace}'): defs must be a table`, 2)
	end

	local registry = getOrCreateRegistry(component)
	if registry.sealed then
		error(
			`RemoteComponent.addRemotes('{namespace}'): remotes for {tostring(component.Instance)} were already built; register during your extension's Constructing hook`,
			2
		)
	end
	if registry.registrations[namespace] then
		error(`RemoteComponent.addRemotes: namespace '{namespace}' is already registered`, 2)
	end

	local exposed = opts ~= nil and opts.exposed == true

	for key, value in defs do
		if type(key) ~= "string" then
			error(`RemoteComponent.addRemotes('{namespace}'): remote keys must be strings`, 2)
		end
		if Namespacing.isNamespaced(key) then
			error(`RemoteComponent.addRemotes('{namespace}'): remote key '{key}' may not contain '{DELIMITER}'`, 2)
		end
		if key == "Server" then
			error(`RemoteComponent.addRemotes('{namespace}'): 'Server' is a reserved key`, 2)
		end
		if type(value) ~= "function" and type(value) ~= "table" then
			error(`RemoteComponent.addRemotes('{namespace}'): remote '{key}' must be a function or a marker`, 2)
		end
	end

	if exposed then
		for key in defs do
			if component.Client ~= nil and component.Client[key] ~= nil then
				error(
					`RemoteComponent.addRemotes('{namespace}'): exposed remote '{key}' collides with an existing key on the component's Client table`,
					2
				)
			end
			for otherNamespace, reg in registry.registrations do
				if reg.exposed and reg.defs[key] ~= nil then
					error(
						`RemoteComponent.addRemotes('{namespace}'): exposed remote '{key}' collides with exposed remote '{key}' from namespace '{otherNamespace}'`,
						2
					)
				end
			end
		end
	end

	registry.registrations[namespace] = { defs = defs, exposed = exposed }
end

--[=[
	@within RemoteComponent
	@function getRemotes

	Returns the isolated sub-object for an extension's internal remotes (the ones
	registered without `exposed = true`). Valid from the registering extension's
	`Starting` hook onward, on both the server and the client. On the server the
	sub-object carries a `.Server` back-reference to the component, mirroring
	`Client.Server`.
]=]
function RemoteComponentExtension.getRemotes(component: any, namespace: string): { [string]: any }
	local registry = component[KEY_REMOTE_REGISTRY]
	local built = registry and registry.built
	if not built then
		error(
			`RemoteComponent.getRemotes('{namespace}'): remotes have not been built yet; valid from your extension's Starting hook onward`,
			2
		)
	end
	local sub = built[namespace]
	if not sub then
		error(
			`RemoteComponent.getRemotes: no internal remotes under namespace '{namespace}' (exposed remotes live flat on component.Client/component.Server)`,
			2
		)
	end
	return sub
end

-- Initialize the per-instance remote registry before any remotes are built, so
-- dependent extensions can register during their own Constructing hook.
function RemoteComponentExtension.Constructing(component)
	getOrCreateRegistry(component)
end

-- Initialize the Remotes prior to 'Start
function RemoteComponentExtension.Starting(component)
	local objectInstance = component.Instance
	local nameSpace = component.RemoteNamespace or component.Tag .. "_RemoteComponent"
	if IS_SERVER then
		local Comm = CommPackage.ServerComm
		local registry = getOrCreateRegistry(component)
		registry.sealed = true -- closes the registration window; late addRemotes errors

		if component.Client == nil and next(registry.registrations) == nil then
			warn(nameSpace .. " extends RemoteComponent but is missing a Client table!")
			return
		end

		component.Client = TableUtil.Copy(component.Client or {}, true) -- Makes a deep copy of the Client table

		-- Merge exposed extension remotes flat onto the Client table so they build
		-- unprefixed alongside the author's own remotes.
		for namespace, reg in registry.registrations do
			if not reg.exposed then
				continue
			end
			for key, value in reg.defs do
				if component.Client[key] ~= nil then
					error(
						`RemoteComponent: exposed remote '{key}' from namespace '{namespace}' collides with an existing Client key`
					)
				end
				component.Client[key] = value
			end
		end

		if objectInstance:FindFirstChild(nameSpace) then
			warn("RemoteComponent: Namespace " .. nameSpace .. " already exists, overwriting")
			objectInstance[nameSpace]:Destroy()
		end
		component._serverComm = Comm.new(objectInstance, nameSpace)

		local totalRemotes = 0

		-- Author + exposed remotes (unprefixed, flat on component.Client).
		for k, v in pairs(component.Client) do
			if Namespacing.isNamespaced(k) then
				error(`RemoteComponent: Client key '{k}' may not contain '{DELIMITER}'`)
			end
			totalRemotes += 1
			if type(v) == "function" then
				component._serverComm:WrapMethod(component.Client, k, nil, { NetWire.PromiseConversionMiddleware })
			elseif type(v) == "table" then
				local built = buildMarkerRemote(component._serverComm, k, v)
				if built ~= nil then
					component.Client[k] = built
				end
			end
		end
		component.Client.Server = component

		-- Internal (namespaced) extension remotes: prefixed names, isolated sub-objects.
		registry.built = {}
		for namespace, reg in registry.registrations do
			if reg.exposed then
				continue
			end
			local sub = {}
			registry.built[namespace] = sub
			for key, value in reg.defs do
				totalRemotes += 1
				local remoteName = Namespacing.join(namespace, key)
				if type(value) == "function" then
					sub[key] = value
					component._serverComm:BindFunction(remoteName, function(...)
						return value(sub, ...)
					end, nil, { NetWire.PromiseConversionMiddleware })
				else
					sub[key] = buildMarkerRemote(component._serverComm, remoteName, value)
				end
			end
			sub.Server = component
		end

		objectInstance[nameSpace]:SetAttribute(SERVER_REMOTE_COUNT, totalRemotes)
	else
		local Comm = CommPackage.ClientComm
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
				local usePromises = if component.UsePromisesForMethods == nil
					then true
					else component.UsePromisesForMethods
				local clientComm = Comm.new(objectInstance, usePromises, nameSpace)
				component._clientComm = clientComm

				local inboundMiddleware = { NetWire.PromiseConversionMiddleware }
				local flat, byNamespace = Namespacing.splitBuiltObject(clientComm:BuildObject(inboundMiddleware))
				component.Server = flat
				ClientMethodGuard.apply(flat, "Server")

				local registry = getOrCreateRegistry(component)
				registry.sealed = true
				registry.built = byNamespace
				for namespace, sub in byNamespace do
					ClientMethodGuard.apply(sub, namespace)
				end
			end)
			:timeout(TIMEOUT, "[TimeOut] Failed to initialize RemoteComponent " .. nameSpace)

		local status, err = component[KEY_INTERNALPROMISE]:awaitStatus()
		if status == Promise.Status.Rejected then
			error(err)
		elseif status == Promise.Status.Cancelled then
			error("RemoteComponent " .. nameSpace .. " was cancelled before it could initialize.")
		end
	end
end

function RemoteComponentExtension.Stopping(component)
	local commCore = if IS_SERVER then component._serverComm else component._clientComm
	if commCore then
		commCore:Destroy()
	end

	local commObj = if IS_SERVER then component.Client else component.Server
	if commObj then
		for _, remoteObj in commObj do
			if typeof(remoteObj) == "table" and remoteObj.Destroy and remoteObj ~= component then
				remoteObj:Destroy()
			end
		end
	end

	-- Internal remotes live in the registry's sub-objects, not in Client. On the
	-- client, ClientComm:Destroy already tore down the underlying remote objects.
	local registry = component[KEY_REMOTE_REGISTRY]
	if IS_SERVER and registry and registry.built then
		for _, sub in registry.built do
			for _, remoteObj in sub do
				if typeof(remoteObj) == "table" and remoteObj.Destroy and remoteObj ~= component then
					remoteObj:Destroy()
				end
			end
		end
	end

	if component[KEY_INTERNALPROMISE] then
		component[KEY_INTERNALPROMISE]:cancel()
	end
end

return RemoteComponentExtension

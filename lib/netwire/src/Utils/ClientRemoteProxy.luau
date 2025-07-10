-- Logan Hunt [Raildex]
-- Sep 17, 2023
--[=[
    @class ClientRemoteProxy
    @client
    @ignore
]=]
local Packages = script.Parent.Parent.Parent
local Promise = require(Packages.Promise) ---@module Promise
local Signal = require(Packages.Signal) ---@module Signal
local NetWireTypes = require(script.Parent.Parent.NetWireTypes)

--------------------------------------------------------------------------------
-- CONSTANTS
--------------------------------------------------------------------------------

local RemoteTypes = {
	Function = "RF",
	Event = "RE",
	Property = "RP",
}

--------------------------------------------------------------------------------
-- TYPE DEFINITIONS
--------------------------------------------------------------------------------

type Promise<T...> = NetWireTypes.Promise<T...>
type Connection = NetWireTypes.Connection

--------------------------------------------------------

local FakeRemote = {}
FakeRemote.ClassName = "FakeRemote"
FakeRemote.__index = FakeRemote
FakeRemote.__call = function(self, ...)
	if not self._Type then
		return Promise.reject("Remote is not ready")
	elseif self._Type ~= RemoteTypes.Function then
		error("Attempted to call a non-function Remote")
	end
	return self._Remote(...)
end

function FakeRemote.is(obj)
	return typeof(obj) == "table" and getmetatable(obj) == FakeRemote
end

function FakeRemote.new()
	local self = setmetatable({
		Test = "A",
		_Type = nil, -- RF, RE, RP
		_Remote = nil,
		_ExpectedType = nil,
		Changed = Signal.new(),
	}, FakeRemote)

	return self
end

function FakeRemote:Destroy()
	if self._TempSig then
		self._TempSig:Destroy()
	end
	if typeof(self._Remote) == "table" and self._Remote.Destroy then
		self._Remote:Destroy()
	end
end

function FakeRemote:_SetRemote(remote: any, type: string)
	assert(not self._Remote, "Remote already set")
	self._Remote = remote
	self._Type = type
	assert(not self._ExpectedType or self._Type == self._ExpectedType, "Remote type mismatch")

	if self._Type == RemoteTypes.Event then
		self._Remote:Connect(function(...)
			self.Changed:Fire(...)
		end)
	end

	if self._RegisterSig then
		self._RegisterSig:Fire()
	end
end

--------------------------------------------------------
-- RemoteEvent Proxies

function FakeRemote:Connect(fn: (...any) -> ()): Connection
	self._ExpectedType = RemoteTypes.Event
	if not self._Type then
		return self.Changed:Connect(fn)
	end
	assert(self._Type == RemoteTypes.Event, "Attempted to connect to a non-event Remote")
	return self._Remote:Connect(fn)
end

function FakeRemote:Fire(...)
	if not self._Type then
		return warn("Remote is not ready, discarding :Fire request.")
	end
	assert(self._Type == RemoteTypes.Event, "Attempted to fire a non-event Remote")
	return self._Remote:Fire(...)
end

--------------------------------------------------------
-- RemoteProperty Proxies

function FakeRemote:IsReady(): boolean
	self._ExpectedType = RemoteTypes.Property
	if self.Type == nil then
		return false
	end
	assert(self._Type == RemoteTypes.Property, "Attempted to check if a non-property Remote is ready")
	return self._Remote:IsReady()
end

function FakeRemote:OnReady(): Promise<...any>
	self._ExpectedType = RemoteTypes.Property
	if self._Type == nil then
		if not self._RegisterSig then
			self._RegisterSig = Signal.new()
		end
		return Promise.fromEvent(self._RegisterSig):andThen(function()
			return self._Remote:OnReady()
		end)
	end
	assert(self._Type == RemoteTypes.Property, "Attempted to check if a non-property Remote is ready")
	return self._Remote:OnReady()
end

function FakeRemote:Get(): any?
	self._ExpectedType = RemoteTypes.Property
	if not self._Type then
		warn("Remote is not ready, returning nil.")
		return nil
	end
	assert(self._Type == RemoteTypes.Property, "Attempted to Get a non-property Remote")
	return self._Remote:Get()
end

function FakeRemote:Observe(observer: (v: any) -> ()): Connection
	self._ExpectedType = RemoteTypes.Property
	if not self._Type then
		if not self._RegisterSig then
			self._RegisterSig = Signal.new()
		end
		local cn
		cn = self._RegisterSig:Once(function()
			cn = self._Remote:Observe(observer)
		end)

		local rCn = {}
		rCn.Connected = true
		rCn.Disconnect = function()
			cn:Disconnect()
			rCn.Connected = false
		end
		return rCn :: Connection
	end
	assert(self._Type == RemoteTypes.Property, "Attempted to Get a non-property Remote")
	return self._Remote:Observe(observer)
end

return FakeRemote

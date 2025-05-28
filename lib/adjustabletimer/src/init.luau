-- May 23, 2025
--[=[
@class AdjustableTimer
The AdjustableTimer class provides a flexible timer system that allows for pausing, resuming, adjusting time scales, and tracking elapsed time. 
It is designed to be serialized and unserialized for replication and storage across systems. Use in conjunction with the `AdjustableTimerManager` for
easy replication of timers from server to clients.

### Example Usage
```lua
local timer = AdjustableTimer.new()
timer:Resume() -- Start the timer
task.wait(5) -- Simulate some elapsed time
print(timer:GetElapsedTime())
```
]=]

--// Imports //--
local function getTime()
	return workspace:GetServerTimeNow()
end

export type ActionType = "ChangeProgressRate" | "Pause" | "Resume" | "ChangeStartTime"
type SerializedAdjustableTimer = {
	startTime: number,
	timeScale: number,
	paused: boolean,
	pauseTime: number?,
	totalPausedDuration: number,
}

local function notifyChanged(self, actionType: ActionType, ...)
	for _, callback in self._OnChangedFns do
		task.spawn(callback, actionType, ...)
	end
end

--------------------------------------------------------------------------------
--// CLASS //--
--------------------------------------------------------------------------------

local AdjustableTimer = {}
AdjustableTimer.ClassName = "AdjustableTimer"
AdjustableTimer.__index = AdjustableTimer

--[=[
    Creates a new AdjustableTimer instance. Takes an optional configuration table.
    
    - `TimeScale`: The initial time scale for the timer. *Defaults to 1*.
    - `StartTime`: The initial start time of the timer. *Defaults to the current server time (via workspace:GetServerTimeNow())*.

    ```lua
    local timer = AdjustableTimer.new()
    timer:Resume() -- Start the timer
    ```
    :::important Starting the Timer
    Timers are initialized in a paused state by default. You need to call `:Resume()` to start the timer.
    :::
]=]
function AdjustableTimer.new(config: {
	TimeScale: number?,
	StartTime: number?,
}?): AdjustableTimer
	local self = setmetatable({}, AdjustableTimer)

	config = config or {}
	assert(type(config) == "table", "AdjustableTimer config must be a table")

	self._TimeScale = config.TimeScale or 1
	self._StartTime = config.StartTime or getTime()
	self._Paused = true
	self._PauseTime = if self._Paused then self._StartTime else nil
	self._TotalPausedDuration = 0

	self._OnChangedFns = {}

	return self
end

--[=[
	Serializes the timer into a saveable/network-safe table.
	```lua
	local serializedData = timer:Serialize()
	```
]=]
function AdjustableTimer:Serialize(): SerializedAdjustableTimer
	return {
		startTime = self._StartTime,
		timeScale = self._TimeScale,
		paused = self._Paused,
		pauseTime = self._PauseTime,
		totalPausedDuration = self._TotalPausedDuration,
	}
end

--[=[
	Unserializes a table into an AdjustableTimer instance.
	```lua
	local timer = AdjustableTimer.Unserialize(serializedData)
	```
]=]
function AdjustableTimer.Unserialize(data: SerializedAdjustableTimer): AdjustableTimer
	local self = setmetatable({}, AdjustableTimer)

	self._TimeScale = data.timeScale
	self._StartTime = data.startTime
	self._Paused = data.paused
	self._PauseTime = data.pauseTime
	self._TotalPausedDuration = data.totalPausedDuration

	self._OnChangedFns = {}

	return self
end

--[=[
	Gets the elapsed time that the timer has been running unpaused.
	@return number -- The elapsed time in seconds.

	```lua
	print(timer:GetElapsedTime())
	```
]=]
function AdjustableTimer:GetElapsedTime(): number
	local effectiveNow = if self:IsPaused() then self._PauseTime else getTime()
	return (effectiveNow - self._StartTime - self._TotalPausedDuration) * self._TimeScale
end


--[=[
    @method Pause
    @within AdjustableTimer
    @return AdjustableTimer
    Pauses the timer. Returns the timer for chaining.

    ```lua
    timer:Pause()
    ```
]=]
function AdjustableTimer:Pause(_pauseTime: number?)
	if not self:IsPaused() then
		self._PauseTime = _pauseTime or getTime()
		self._Paused = true
		notifyChanged(self, "Pause", self._PauseTime)
	end
    return self
end

--[=[
    @method Resume
    @within AdjustableTimer
    @return AdjustableTimer
    Resumes the timer. Returns the timer for chaining.

    ```lua
    timer:Resume()
    ```
]=]
function AdjustableTimer:Resume(_resumeTime: number?)
	if self:IsPaused() then
		local now = _resumeTime or getTime()
		self._TotalPausedDuration += now - self._PauseTime
		self._Paused = false
		self._PauseTime = nil
		notifyChanged(self, "Resume", now)
	end
end

--[=[
	Returns whether or not the timer is paused.
	```lua
	print(timer:IsPaused())
	```
]=]
function AdjustableTimer:IsPaused(): boolean
	return self._Paused
end

--[=[
	Changes how fast the timer progresses every unpaused second.
	`2` means the timer will progress twice as fast, `0.5` means it will progress half as fast.
	@param newRate number -- The new rate at with time will progress.
	```lua
	timer:SetTimeScale(2)
	```
]=]
function AdjustableTimer:SetTimeScale(newRate: number, _newRateChangeTime: number?)
	local now = _newRateChangeTime or getTime()
	local effectiveNow = if self:IsPaused() then self._PauseTime else now

	-- Calculate the elapsed time at the current rate
	local elapsedTime = (effectiveNow - self._StartTime - self._TotalPausedDuration) * self._TimeScale

	-- Adjust StartTime to reflect the new rate
	self._StartTime = effectiveNow - (elapsedTime / newRate)

	-- Update the time scale and last rate change time
	self._TimeScale = newRate

	notifyChanged(self, "ChangeProgressRate", newRate, now)
    return self
end

--[=[
	Gets the current time scale of the timer. Represents how fast the timer progresses every unpaused second.
	`2` means the timer will progress twice as fast, `0.5` means it will progress half as fast.
	@return number -- The current progress rate.
]=]
function AdjustableTimer:GetTimeScale(): number
	return self._TimeScale
end

--[=[
	Adds progress to the timer in raw seconds.
	@param seconds number -- The number of seconds to add.
	@param useTimeScale boolean? -- Whether to apply the current time scale to the given seconds (default is false).

	```lua
	local time = AdjustableTimer.new():Resume()
	print(timer:GetElapsedTime()) -- 0
	timer:AddElapsedTime(10)
	print(timer:GetElapsedTime()) -- 10
	timer:SetTimeScale(2)
	timer:AddElapsedTime(5, true)
	print(timer:GetElapsedTime()) -- 20
	```
]=]
function AdjustableTimer:AddElapsedTime(seconds: number, useTimeScale: boolean?)
	useTimeScale = if useTimeScale == nil then false else useTimeScale
	if useTimeScale then
		seconds = seconds / self._TimeScale
	end
	self._StartTime -= seconds
	notifyChanged(self, "ChangeStartTime", self._StartTime)
    return self
end

--[=[
	Sets the elapsed time of the timer in raw seconds.
	@param seconds number -- The elapsed time to set.
	```lua
	timer:SetElapsedTime(30)
	```
]=]
function AdjustableTimer:SetElapsedTime(seconds: number)
	local effectiveNow = if self:IsPaused() then self._PauseTime else getTime()
	self._StartTime = effectiveNow - seconds
	notifyChanged(self, "ChangeStartTime", self._StartTime)
    return self
end

--[=[
	Sets the time at which the timer started. This will affect the elapsed time calculation.
	The timestamp should be relative to `workspace:GetServerTimeNow()`.
	Does not account for time scale or paused state.
	```lua
	timer:SetStartTime(workspace:GetServerTimeNow() - 60) -- Set start time to 60 seconds ago
	```
]=]
function AdjustableTimer:SetStartTime(timestamp: number)
	if self._StartTime ~= timestamp then
		self._StartTime = timestamp
		notifyChanged(self, "ChangeStartTime", self._StartTime)
	end
    return self
end

--[=[
	@private
	Registers a callback to be invoked when the timer changes.
	@param callback function -- The callback function to register.
	@return function -- A function to disconnect the callback.
	```lua
	local disconnect = timer:OnChanged(function(actionType, ...)
		print("Timer changed:", actionType, ...)
	end)
	```
]=]
function AdjustableTimer:OnChanged(callback: (actionType: ActionType, ...any) -> ()): () -> ()
	table.insert(self._OnChangedFns, callback)
	return function()
		local idx = table.find(self._OnChangedFns, callback)
		if idx then
			table.remove(self._OnChangedFns, idx)
		end
	end
end

export type AdjustableTimer = typeof(AdjustableTimer.new())

return AdjustableTimer
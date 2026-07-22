--!strict
--[[
	Tests for PlayerProfileManager: DataStore key claiming, wipe locks,
	WipeProfile, and _endProfileSession. Uses the tiniest framework.

	Wipe-lock tests inject an in-memory fake MemoryStore hash map into the
	manager's WipeLockManager so they run deterministically without
	MemoryStoreService access.
]]

return function(t: tiniest)
	local describe = t.describe
	local test = t.test
	local expect = t.expect
	local before_each = t.before_each
	local after_each = t.after_each

	local PPM = require(script.Parent)

	local TEST_SCHEMA = {
		__VERSION = "1.0.0",
		Coins = 0,
		Level = 1,
	}

	local function contains(value: any, substring: string): boolean
		return string.find(tostring(value), substring, 1, true) ~= nil
	end

	-- In-memory stand-in for a MemoryStore hash map (WipeLockMap surface).
	local function makeFakeLockMap()
		local store: { [string]: any } = {}
		return {
			UpdateAsync = function(_, key: string, transform: (any) -> any, _ttl: number)
				local newValue = transform(store[key])
				if newValue ~= nil then
					store[key] = newValue
				end
				return newValue
			end,
			GetAsync = function(_, key: string)
				return store[key]
			end,
			RemoveAsync = function(_, key: string)
				store[key] = nil
			end,
		}
	end

	local keyCounter = 0
	local function newManager(): any
		keyCounter += 1
		local manager: any = PPM.new {
			DataStoreKey = `PPM_Spec_{keyCounter}`,
			DefaultDataSchema = TEST_SCHEMA,
			UseMock = true,
		}
		manager._wipeLockManager._wipeLockMap = makeFakeLockMap()
		return manager
	end

	describe("PlayerProfileManager key claiming", function()
		test("rejects a duplicate active DataStoreKey", function()
			local manager = newManager()
			local key = manager._dataStoreKey
			expect(function()
				PPM.new {
					DataStoreKey = key,
					DefaultDataSchema = TEST_SCHEMA,
					UseMock = true,
				}
			end).fails_with("DataStoreKey")
			manager:Destroy()
		end)

		test("keeps the original claim after a failed duplicate", function()
			local manager = newManager()
			local key = manager._dataStoreKey
			local function makeDuplicate()
				PPM.new {
					DataStoreKey = key,
					DefaultDataSchema = TEST_SCHEMA,
					UseMock = true,
				}
			end
			expect(makeDuplicate).fails()
			-- The failed claim must not have released the original manager's key.
			expect(makeDuplicate).fails()
			manager:Destroy()
		end)

		test("releases the key on Destroy", function()
			local manager = newManager()
			local key = manager._dataStoreKey
			manager:Destroy()
			local reclaimed: any = PPM.new {
				DataStoreKey = key,
				DefaultDataSchema = TEST_SCHEMA,
				UseMock = true,
			}
			reclaimed:Destroy()
		end)
	end)

	describe("PlayerProfileManager wipe locks", function()
		local manager: any

		before_each(function()
			manager = newManager()
		end)

		after_each(function()
			manager:Destroy()
		end)

		test("AcquireLock succeeds first and fails while held", function()
			expect(manager._wipeLockManager:AcquireLock(1)).is_true()
			expect(manager._wipeLockManager:AcquireLock(1)).never_is_true()
		end)

		test("IsLocked reflects lock state", function()
			expect(manager._wipeLockManager:IsLocked(1)).never_is_true()
			manager._wipeLockManager:AcquireLock(1)
			expect(manager._wipeLockManager:IsLocked(1)).is_true()
		end)

		test("ReleaseLock clears the lock and is safe to repeat", function()
			manager._wipeLockManager:AcquireLock(1)
			manager._wipeLockManager:ReleaseLock(1)
			expect(manager._wipeLockManager:IsLocked(1)).never_is_true()
			manager._wipeLockManager:ReleaseLock(1) -- must not error
		end)

		test("locks for different userIds are independent", function()
			expect(manager._wipeLockManager:AcquireLock(1)).is_true()
			expect(manager._wipeLockManager:AcquireLock(2)).is_true()
			expect(manager._wipeLockManager:IsLocked(1)).is_true()
			expect(manager._wipeLockManager:IsLocked(2)).is_true()
		end)

		test("managers with different DataStoreKeys have isolated locks", function()
			local other = newManager()
			expect(manager._wipeLockManager:AcquireLock(12345)).is_true()
			expect(other._wipeLockManager:AcquireLock(12345)).is_true()
			other:Destroy()
		end)
	end)

	describe("PlayerProfileManager.WipeProfile", function()
		local manager: any

		before_each(function()
			manager = newManager()
		end)

		after_each(function()
			manager:Destroy()
		end)

		test("rejects a zero userId", function()
			local success, result = manager:WipeProfile(0):await()
			expect(success).never_is_true()
			expect(contains(result, "Invalid userId")).is_true()
		end)

		test("rejects a non-integer userId", function()
			local success, result = manager:WipeProfile(1.5):await()
			expect(success).never_is_true()
			expect(contains(result, "Invalid userId")).is_true()
		end)

		test("rejects while the profile is loading", function()
			manager._LoadingPlayers[12345] = true
			local success, result = manager:WipeProfile(12345):await()
			expect(success).never_is_true()
			expect(contains(result, "currently loading")).is_true()
			manager._LoadingPlayers[12345] = nil
		end)

		test("rejects when the wipe lock is already held", function()
			manager._wipeLockManager:AcquireLock(12345)
			local success, result = manager:WipeProfile(12345):await()
			expect(success).never_is_true()
			expect(contains(result, "delete already in progress")).is_true()
		end)

		test("wipes an inactive profile and releases the lock", function()
			local success = manager:WipeProfile(12345):await()
			expect(success).is_true()
			-- Lock must be free again after the wipe completes.
			expect(manager._wipeLockManager:AcquireLock(12345)).is_true()
		end)
	end)

	describe("PlayerProfileManager.PromiseSave", function()
		local Signal = require(script.Parent.Parent.Signal) :: any
		local manager: any

		before_each(function()
			manager = newManager()
		end)

		after_each(function()
			manager:Destroy()
		end)

		-- Minimal Profile stand-in: Save() "persists" Data on the next tick.
		local function makeMockProfile()
			local profile: any
			profile = {
				Data = {},
				OnAfterSave = Signal.new(),
				OnSessionEnd = Signal.new(),
				Save = function()
					task.defer(function()
						profile.OnAfterSave:Fire(profile.Data)
					end)
				end,
				EndSession = function() end,
			}
			return profile
		end

		test("rejects when the profile is not loaded", function()
			local success, err = manager:PromiseSave(123):await()
			expect(success).never_is_true()
			expect(contains(err, "No loaded profile")).is_true()
		end)

		test("resolves once a save is confirmed", function()
			manager._PlayerProfileStorage[123] = makeMockProfile()
			local success = manager:PromiseSave(123):await()
			expect(success).is_true()
			manager._PlayerProfileStorage[123] = nil
		end)

		test("waits for a persisted snapshot that satisfies the predicate", function()
			local profile = makeMockProfile()
			manager._PlayerProfileStorage[123] = profile

			local promise = manager:PromiseSave(123, function(lastSaved)
				return lastSaved.Flag == true
			end)

			-- First save does not satisfy the predicate.
			profile.OnAfterSave:Fire { Flag = false }
			expect(promise:getStatus()).is("Started")

			profile.OnAfterSave:Fire { Flag = true }
			local success = promise:await()
			expect(success).is_true()
			manager._PlayerProfileStorage[123] = nil
		end)

		test("rejects when the session ends before confirmation", function()
			local profile = makeMockProfile()
			profile.Save = function() end -- swallow the save so nothing confirms
			manager._PlayerProfileStorage[123] = profile

			local promise = manager:PromiseSave(123)
			profile.OnSessionEnd:Fire()

			local success, err = promise:await()
			expect(success).never_is_true()
			expect(contains(err, "session ended")).is_true()
			manager._PlayerProfileStorage[123] = nil
		end)
	end)

	describe("PlayerProfileManager._endProfileSession", function()
		local manager: any

		before_each(function()
			manager = newManager()
		end)

		after_each(function()
			manager:Destroy()
		end)

		test("fires PlayerProfileReleasing, calls EndSession, and clears storage", function()
			local releasedUserId: number? = nil
			manager.PlayerProfileReleasing:Connect(function(userId: number)
				releasedUserId = userId
			end)

			local endSessionCalled = false
			local mockProfile = {
				EndSession = function()
					endSessionCalled = true
				end,
			}

			manager._PlayerProfileStorage[123] = mockProfile
			manager:_endProfileSession(123, mockProfile, "test")

			expect(releasedUserId).is(123)
			expect(endSessionCalled).is_true()
			expect(manager._PlayerProfileStorage[123]).never_exists()
		end)
	end)
end

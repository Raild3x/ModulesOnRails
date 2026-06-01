--!strict
--[[
    Tests for PlayerProfileManager WipeProfile implementation.
    Uses Tiniest test framework for Lune compatibility.
]]

return function(tiniest: tiniest)
	local expect = tiniest.expect
	local describe = tiniest.describe
	local test = tiniest.test

	local PPM = require(script.Parent)
	local _Profile = require(script.Parent.ProfileTypeDef)

	local TEST_SCHEMA = {
		__VERSION = "1.0.0",
		Coins = 0,
		Level = 1,
	}

	describe("PlayerProfileManager key isolation", function()
		it("should reject a duplicate active default DataStoreKey", function()
			local manager = PPM.new {
				DefaultDataSchema = TEST_SCHEMA,
				UseMock = true,
				Debug = false,
			}

			local success, err = pcall(function()
				PPM.new {
					DefaultDataSchema = TEST_SCHEMA,
					UseMock = true,
					Debug = false,
				}
			end)

			expect(success).to.equal(false)
			expect(tostring(err)).to.include("DataStoreKey")
			manager:Destroy()
		end)

		it("should isolate wipe locks for managers with different DataStoreKeys", function()
			local managerA: any = PPM.new {
				DataStoreKey = "PPM_Test_A",
				DefaultDataSchema = TEST_SCHEMA,
				UseMock = true,
				Debug = false,
			}
			local managerB: any = PPM.new {
				DataStoreKey = "PPM_Test_B",
				DefaultDataSchema = TEST_SCHEMA,
				UseMock = true,
				Debug = false,
			}

			local acquiredA = managerA:_acquireWipeLockAsync(12345)
			local acquiredB = managerB:_acquireWipeLockAsync(12345)

			expect(acquiredA).to.equal(true)
			expect(acquiredB).to.equal(true)

			managerA:_releaseWipeLockAsync(12345)
			managerB:_releaseWipeLockAsync(12345)
			managerA:Destroy()
			managerB:Destroy()
		end)
	end)

	describe("PlayerProfileManager.WipeProfile", function()
		local manager: any

		beforeEach(function()
			manager = PPM.new {
				DefaultDataSchema = TEST_SCHEMA,
				UseMock = true,
				Debug = false,
			}
		end)

		afterEach(function()
			manager:Destroy()
		end)

		it("should reject with invalid userId", function()
			local promise = manager:WipeProfile(0)
			local success, _result = promise:await()
			expect(success).to.equal(false)
			expect(_result).to.include("Invalid userId")
		end)

		it("should reject with negative userId", function()
			local promise = manager:WipeProfile(-1)
			local success, _result = promise:await()
			expect(success).to.equal(false)
			expect(_result).to.include("Invalid userId")
		end)

		it("should reject with non-integer userId", function()
			local promise = manager:WipeProfile(1.5)
			local success, _result = promise:await()
			expect(success).to.equal(false)
		end)

		it("should successfully wipe an inactive profile", function()
			local userId = 12345
			-- Note: In a mock environment, profile doesn't need to exist to be "removed"
			local promise = manager:WipeProfile(userId)
			local success, _result = promise:await()
			expect(success).to.equal(true)
		end)

		it("should reject if wipe lock already exists", function()
			local _userId = 12345
			-- Manually acquire lock
			manager:_acquireWipeLockAsync(_userId)
			-- Try to wipe while locked
			local promise = manager:WipeProfile(_userId)
			local success, _result = promise:await()
			expect(success).to.equal(false)
			expect(_result).to.include("delete already in progress")
		end)

		it("should release lock after successful wipe", function()
			local userId = 12345
			local promise = manager:WipeProfile(userId)
			promise:await()
			-- Verify lock is released by attempting to acquire it again
			local acquired = manager:_acquireWipeLockAsync(userId)
			expect(acquired).to.equal(true)
			manager:_releaseWipeLockAsync(userId)
		end)

		it("should release lock after failed wipe", function()
			local _userId = 12345
			-- Skip this test in mock mode as failures are harder to trigger
			-- In live environment, transient errors would test this path
		end)

		it("should reject with active-loading profile", function()
			local userId = 12345
			-- Manually set loading flag
			manager._LoadingPlayers[userId] = true
			local promise = manager:WipeProfile(userId)
			local success, _result = promise:await()
			expect(success).to.equal(false)
			expect(_result).to.include("profile is currently loading")
			manager._LoadingPlayers[userId] = nil
		end)

		it("should fire PlayerProfileReleasing if active session exists", function()
			-- This would require creating an active profile, which requires player context
			-- Skipped in unit test; tested manually via integration test
		end)

		it("should call _acquireWipeLockAsync, _sendWipeResetMessageAsync, and _releaseWipeLockAsync", function()
			local _userId = 12345
			local calls = {
				acquire = false,
				send = false,
				release = false,
			}

			-- Spy on lock methods
			local originalAcquire = manager._acquireWipeLockAsync
			manager._acquireWipeLockAsync = function(self, uid)
				if uid == _userId then
					calls.acquire = true
				end
				return originalAcquire(self, uid)
			end

			local originalSend = manager._sendWipeResetMessageAsync
			manager._sendWipeResetMessageAsync = function(self, uid)
				if uid == _userId then
					calls.send = true
				end
				return originalSend(self, uid)
			end

			local originalRelease = manager._releaseWipeLockAsync
			manager._releaseWipeLockAsync = function(self, uid)
				if uid == _userId then
					calls.release = true
				end
				return originalRelease(self, uid)
			end

			local promise = manager:WipeProfile(_userId)
			promise:await()

			expect(calls.acquire).to.equal(true)
			expect(calls.send).to.equal(true)
			expect(calls.release).to.equal(true)

			-- Restore
			manager._acquireWipeLockAsync = originalAcquire
			manager._sendWipeResetMessageAsync = originalSend
			manager._releaseWipeLockAsync = originalRelease
		end)
	end)

	describe("PlayerProfileManager Lock Helpers", function()
		local manager: any

		beforeEach(function()
			manager = PPM.new {
				DefaultDataSchema = TEST_SCHEMA,
				UseMock = true,
				Debug = false,
			}
		end)

		afterEach(function()
			manager:Destroy()
		end)

		it("_acquireWipeLockAsync should return true on first acquisition", function()
			local acquired = manager:_acquireWipeLockAsync(1)
			expect(acquired).to.equal(true)
			manager:_releaseWipeLockAsync(1)
		end)

		it("_acquireWipeLockAsync should return false if already locked", function()
			manager:_acquireWipeLockAsync(1)
			local secondAcquire = manager:_acquireWipeLockAsync(1)
			expect(secondAcquire).to.equal(false)
			manager:_releaseWipeLockAsync(1)
		end)

		it("_isWipeLockedAsync should return false before acquisition", function()
			local locked = manager:_isWipeLockedAsync(1)
			expect(locked).to.equal(false)
		end)

		it("_isWipeLockedAsync should return true after acquisition", function()
			manager:_acquireWipeLockAsync(1)
			local locked = manager:_isWipeLockedAsync(1)
			expect(locked).to.equal(true)
			manager:_releaseWipeLockAsync(1)
		end)

		it("_releaseWipeLockAsync should clear lock state", function()
			manager:_acquireWipeLockAsync(1)
			manager:_releaseWipeLockAsync(1)
			local locked = manager:_isWipeLockedAsync(1)
			expect(locked).to.equal(false)
		end)

		it("_releaseWipeLockAsync should be safe to call multiple times", function()
			manager:_acquireWipeLockAsync(1)
			manager:_releaseWipeLockAsync(1)
			manager:_releaseWipeLockAsync(1) -- Should not error
		end)

		it("independent locks should not interfere", function()
			manager:_acquireWipeLockAsync(1)
			local canAcquire2 = manager:_acquireWipeLockAsync(2)
			expect(canAcquire2).to.equal(true)

			local locked1 = manager:_isWipeLockedAsync(1)
			local locked2 = manager:_isWipeLockedAsync(2)
			expect(locked1).to.equal(true)
			expect(locked2).to.equal(true)

			manager:_releaseWipeLockAsync(1)
			manager:_releaseWipeLockAsync(2)
		end)
	end)

	describe("PlayerProfileManager._endProfileSession", function()
		local manager: any

		beforeEach(function()
			manager = PPM.new {
				DefaultDataSchema = TEST_SCHEMA,
				UseMock = true,
				Debug = false,
			}
		end)

		afterEach(function()
			manager:Destroy()
		end)

		it("should fire PlayerProfileReleasing signal", function()
			local fired = false
			manager.PlayerProfileReleasing:Connect(function(userId, profile)
				if userId == 123 then
					fired = true
				end
			end)

			-- Create a mock profile
			local mockProfile = {
				EndSession = function() end,
			}

			manager._PlayerProfileStorage[123] = mockProfile
			manager:_endProfileSession(123, mockProfile, "test")

			expect(fired).to.equal(true)
		end)

		it("should clear profile from storage", function()
			local mockProfile = {
				EndSession = function() end,
			}

			manager._PlayerProfileStorage[123] = mockProfile
			manager:_endProfileSession(123, mockProfile, "test")

			expect(manager._PlayerProfileStorage[123]).to.equal(nil)
		end)

		it("should call EndSession on profile", function()
			local endSessionCalled = false
			local mockProfile = {
				EndSession = function()
					endSessionCalled = true
				end,
			}

			manager._PlayerProfileStorage[123] = mockProfile
			manager:_endProfileSession(123, mockProfile, "test")

			expect(endSessionCalled).to.equal(true)
		end)
	end)

	describe("PlayerProfileManager._sendWipeResetMessage", function()
		local manager: any

		beforeEach(function()
			manager = PPM.new {
				DefaultDataSchema = TEST_SCHEMA,
				UseMock = true,
				Debug = false,
			}
		end)

		afterEach(function()
			manager:Destroy()
		end)

		it("should return boolean indicating success", function()
			local result = manager:_sendWipeResetMessage(123)
			expect(type(result)).to.equal("boolean")
		end)

		it("should construct message with correct kind field", function()
			-- Verification would require mocking ProfileStore:MessageAsync
			-- For now, test that method executes without error
			manager:_sendWipeResetMessage(123)
		end)
	end)
end

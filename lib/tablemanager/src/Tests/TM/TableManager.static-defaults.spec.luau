--!strict
--[[
	Coverage of the class-level static default config: the `Default*` props and
	the `SetDefaults` setter that overrides them.

	These statics are read once, at construction time, whenever the matching
	`TableManagerConfig` field is omitted, so changing a default affects only
	TableManagers created afterwards. The statics are PROCESS-GLOBAL, so every
	test snapshots the four defaults up front and restores them afterwards even
	if the body throws -- otherwise a mutation here would silently change the
	behavior of every later spec in the run.
]]

return function(t: tiniest)
	local TableManager = require("../../TableManager")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	-- Runs `body`, always restoring the four static defaults afterwards even if
	-- `body` throws, then re-raises any error so the test still fails.
	local function withRestoredDefaults(body: () -> ())
		local snapshot = {
			ListenerFireMode = TableManager.DefaultListenerFireMode,
			SignalFireMode = TableManager.DefaultSignalFireMode,
			FlushMode = TableManager.DefaultFlushMode,
			DuplicateReferenceMode = TableManager.DefaultDuplicateReferenceMode,
		}

		local ok, err = pcall(body)

		TableManager.SetDefaults(snapshot)

		if not ok then
			error(err, 0)
		end
	end

	describe("initial defaults", function()
		test("match the documented values", function()
			expect(TableManager.DefaultListenerFireMode).is("bindable")
			expect(TableManager.DefaultSignalFireMode).is("bindable")
			expect(TableManager.DefaultFlushMode).is("immediate")
			expect(TableManager.DefaultDuplicateReferenceMode).is("allow")
		end)
	end)

	describe("SetDefaults partial application", function()
		test("only changes the fields that are provided", function()
			withRestoredDefaults(function()
				TableManager.SetDefaults({ FlushMode = "coalesced" })

				expect(TableManager.DefaultFlushMode).is("coalesced") -- changed
				expect(TableManager.DefaultListenerFireMode).is("bindable") -- untouched
				expect(TableManager.DefaultSignalFireMode).is("bindable") -- untouched
				expect(TableManager.DefaultDuplicateReferenceMode).is("allow") -- untouched
			end)
		end)

		test("is case-insensitive and stores lowercase", function()
			withRestoredDefaults(function()
				TableManager.SetDefaults({ SignalFireMode = "Deferred" })
				expect(TableManager.DefaultSignalFireMode).is("deferred")
			end)
		end)
	end)

	describe("SignalFireMode default", function()
		test("a manager created after the change uses the new default", function()
			withRestoredDefaults(function()
				TableManager.SetDefaults({ SignalFireMode = "deferred" })

				local manager = TableManager.new({ health = 100 })
				local fired: { any } = {}
				local conn = manager.ValueChanged:Connect(function(_path, newValue)
					table.insert(fired, newValue)
				end)

				manager:Set("health", 50)
				expect(#fired).is(0) -- deferred: nothing synchronous

				task.wait()
				expect(#fired).is(1)

				conn:Disconnect()
				manager:Destroy()
			end)
		end)

		test("a manager created before the change is unaffected", function()
			withRestoredDefaults(function()
				-- Built while the default is still "bindable" (synchronous here).
				local manager = TableManager.new({ health = 100 })
				local fired: { any } = {}
				local conn = manager.ValueChanged:Connect(function(_path, newValue)
					table.insert(fired, newValue)
				end)

				TableManager.SetDefaults({ SignalFireMode = "deferred" })

				manager:Set("health", 50)
				expect(#fired).is(1) -- construction-time read: still immediate

				conn:Disconnect()
				manager:Destroy()
			end)
		end)

		test("an explicit config value overrides a changed default", function()
			withRestoredDefaults(function()
				TableManager.SetDefaults({ SignalFireMode = "deferred" })

				local manager = TableManager.new({ health = 100 }, { SignalFireMode = "immediate" })
				local fired: { any } = {}
				local conn = manager.ValueChanged:Connect(function(_path, newValue)
					table.insert(fired, newValue)
				end)

				manager:Set("health", 50)
				expect(#fired).is(1) -- explicit config wins over the default

				conn:Disconnect()
				manager:Destroy()
			end)
		end)
	end)

	describe("ListenerFireMode default", function()
		test("defers Observe's initial fire on a manager created after the change", function()
			withRestoredDefaults(function()
				TableManager.SetDefaults({ ListenerFireMode = "deferred" })

				local manager = TableManager.new({ health = 100 })
				local fired: { any } = {}
				manager:Observe("health", function(newValue)
					table.insert(fired, newValue)
				end)

				expect(#fired).is(0) -- deferred: initial fire scheduled, not run

				task.wait()
				expect(#fired).is(1)

				manager:Destroy()
			end)
		end)

		test("an explicit config value overrides a changed default", function()
			withRestoredDefaults(function()
				TableManager.SetDefaults({ ListenerFireMode = "deferred" })

				local manager = TableManager.new({ health = 100 }, { ListenerFireMode = "immediate" })
				local fired: { any } = {}
				manager:Observe("health", function(newValue)
					table.insert(fired, newValue)
				end)

				expect(#fired).is(1) -- immediate initial fire

				manager:Destroy()
			end)
		end)
	end)

	describe("FlushMode default", function()
		test("coalesced default collapses repeated changes on a new manager", function()
			withRestoredDefaults(function()
				TableManager.SetDefaults({ FlushMode = "coalesced" })

				local manager = TableManager.new({ health = 100 })
				local fireCount = 0
				local conn = manager.ValueChanged:Connect(function()
					fireCount += 1
				end)

				manager:Set("health", 75)
				manager:Set("health", 50)
				expect(fireCount).is(0) -- nothing synchronous under coalesced flushing

				task.wait()
				expect(fireCount).is(1) -- collapsed into a single flush

				conn:Disconnect()
				manager:Destroy()
			end)
		end)
	end)

	describe("DuplicateReferenceMode default", function()
		test("copy default clones shared references on a new manager", function()
			withRestoredDefaults(function()
				TableManager.SetDefaults({ DuplicateReferenceMode = "copy" })

				local manager = TableManager.new({ a = { value = 1 }, b = { value = 2 } })
				manager.Proxy.b = manager.Proxy.a

				expect(manager.Raw.b).never_is(manager.Raw.a) -- independent clone
				manager.Proxy.a.value = 99
				expect(manager.Proxy.b.value).is(1)

				manager:Destroy()
			end)
		end)

		test("default allow shares identity", function()
			withRestoredDefaults(function()
				-- Default is "allow"; assert it explicitly rather than assuming.
				expect(TableManager.DefaultDuplicateReferenceMode).is("allow")

				local manager = TableManager.new({ a = { value = 1 }, b = { value = 2 } })
				manager.Proxy.b = manager.Proxy.a

				expect(manager.Raw.b).is(manager.Raw.a) -- shared identity

				manager:Destroy()
			end)
		end)
	end)

	describe("validation", function()
		test("rejects an unrecognized mode string", function()
			withRestoredDefaults(function()
				expect(function()
					TableManager.SetDefaults({ FlushMode = "banana" :: any })
				end).fails_with('Invalid FlushMode "banana"')
			end)
		end)

		test("rejects a non-string mode value", function()
			withRestoredDefaults(function()
				expect(function()
					TableManager.SetDefaults({ SignalFireMode = 42 :: any })
				end).fails_with("SignalFireMode must be a string")
			end)
		end)

		test("rejects a non-table argument", function()
			withRestoredDefaults(function()
				expect(function()
					(TableManager :: any).SetDefaults("nope")
				end).fails_with("SetDefaults expects a table")
			end)
		end)

		test("leaves the default unchanged after a rejected value", function()
			withRestoredDefaults(function()
				pcall(function()
					TableManager.SetDefaults({ ListenerFireMode = "nonsense" :: any })
				end)
				expect(TableManager.DefaultListenerFireMode).is("bindable")
			end)
		end)
	end)
end

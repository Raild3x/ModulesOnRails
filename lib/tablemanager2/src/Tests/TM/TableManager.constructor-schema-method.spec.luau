--!strict

return function(t: tiniest)
	local TableManager = require("../../TableManager")
	local T = require("../../../T")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("Method: new", function()
		test("creates a manager with initial data", function()
			local manager = TableManager.new {
				player = { health = 100, level = 5 },
				settings = { volume = 80 },
			}

			expect(manager).exists()
			expect(manager.Proxy).exists()
			expect(manager.Proxy.player).exists()
			expect(manager.Proxy.player.health).is(100)

			manager:Destroy()
		end)

		test("re-exports T module for schema helpers", function()
			expect(type(TableManager.T)).is("table")
			expect(type(TableManager.T.interface)).is("function")
			expect(type(TableManager.T.GetMeta)).is("function")
		end)

		test("validates initial data against schema at creation", function()
			local ok, err = pcall(function()
				TableManager.new({ value = "bad" }, {
					Schema = T.interface { value = T.number },
				})
			end)

			expect(ok).is(false)
			expect(type(err)).is("string")
		end)

		test("calls OnValidationFailed for invalid initial data", function()
			local failures = 0
			local capturedPath = ""
			local capturedMessage = ""

			local ok = pcall(function()
				TableManager.new({ value = "bad" }, {
					Schema = T.interface { value = T.number },
					OnValidationFailed = function(path, _value, err)
						failures += 1
						capturedPath = table.concat(path, ".")
						capturedMessage = err
					end,
				})
			end)

			expect(ok).is(false)
			expect(failures).is(1)
			expect(capturedPath).is("")
			expect(type(capturedMessage)).is("string")
		end)

		test("default duplicate mode (allow) permits multi-location references", function()
			local manager = TableManager.new {
				a = { value = 1 },
				b = { value = 2 },
			}

			manager.Proxy.b = manager.Proxy.a

			-- Both paths now share the SAME identity; the proxy graph reports the
			-- single primary anchor ("a", established first), so GetProxy at "b"
			-- resolves to the same proxy as "a".
			expect(manager.Proxy.b).is(manager.Proxy.a)
			expect(manager.Proxy.b.value).is(1)
			expect(manager.Raw.b).is(manager.Raw.a)

			manager:Destroy()
		end)

		test("DuplicateReferenceMode allow permits duplicate references (explicit)", function()
			local manager = TableManager.new({
				a = { value = 1 },
				b = { value = 2 },
			}, {
				DuplicateReferenceMode = "allow",
			})

			manager.Proxy.b = manager.Proxy.a

			expect(manager.Proxy.b).is(manager.Proxy.a)
			expect(manager.Proxy.b.value).is(1)

			manager:Destroy()
		end)

		test("DuplicateReferenceMode copy writes a fresh clone instead of sharing identity", function()
			local manager = TableManager.new({
				a = { value = 1 },
				b = { value = 2 },
			}, {
				DuplicateReferenceMode = "copy",
			})

			manager.Proxy.b = manager.Proxy.a

			-- The write succeeded, but "b" got an INDEPENDENT clone, not the same
			-- identity as "a" — mutating one must not affect the other.
			expect(manager.Raw.b).never_is(manager.Raw.a)
			expect(manager.Proxy.b.value).is(1)

			manager.Proxy.a.value = 99
			expect(manager.Proxy.b.value).is(1)

			manager:Destroy()
		end)

		test("default allow: removing one of two shared locations leaves the other intact", function()
			-- Multi-location references are a supported feature under the default
			-- ("allow"). After b and a share one table, removing a must leave that
			-- table live at b with no corruption — the edge the old error-default
			-- existed to forbid.
			local manager = TableManager.new {
				a = { value = 1 },
				b = { value = 2 },
			}

			manager.Proxy.b = manager.Proxy.a
			expect(manager.Raw.b).is(manager.Raw.a)

			manager.Proxy.a = nil

			expect(manager.Raw.a).is(nil)
			expect(manager:Get({ "b", "value" })).is(1)
			-- The surviving location is still writable and reads back correctly.
			manager.Proxy.b.value = 7
			expect(manager:Get({ "b", "value" })).is(7)

			manager:Destroy()
		end)

		test("allows unschemed paths to remain permissive", function()
			local failures = 0
			local manager = TableManager.new({
				player = { health = 100, mana = 50 },
			}, {
				Schema = T.interface {
					player = T.interface {
						health = T.number,
					},
				},
				OnValidationFailed = function()
					failures += 1
				end,
			})

			manager.Proxy.player.mana = 10
			expect(manager.Proxy.player.mana).is(10)
			expect(failures).is(0)

			manager:Destroy()
		end)
	end)
end

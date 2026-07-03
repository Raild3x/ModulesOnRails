--!strict
--[[
	Coverage for every public `BaseReplicator` method (discovery statics,
	hierarchy, tags, identity, lifecycle), exercised through `ServerReplicator`
	instances (the concrete subclass) since `BaseReplicator` itself is never
	constructed directly. `Player` targets aren't relevant here -- every
	replicator below uses `ReplicationTargets = {}` and a `FakeManager` (no
	real diffing needed for identity/hierarchy/discovery behavior).
]]

return function(t: tiniest)
	local BaseReplicator = require("../Shared/BaseReplicator")
	local ServerReplicator = require("../Server/ServerReplicator")
	local ClientReplicator = require("../Client/ClientReplicator")
	local FlatCodec = require("../Shared/Serialization/FlatCodec")
	local FakeManager = require("./Helpers/FakeManager")
	local SpecUtils = require("./Helpers/SpecUtils")

	local describe = t.describe
	local test = t.test
	local expect = t.expect

	local uniqueToken = SpecUtils.uniqueToken
	local getTokenName = SpecUtils.getTokenName

	local function newTop(label: string, tags: { [string]: any }?)
		return ServerReplicator.new {
			Namespace = uniqueToken(label),
			Data = FakeManager.new(),
			ReplicationTargets = {},
			Tags = tags,
		}
	end

	-- Every describe block below (except "BaseReplicator.ListenerFireMode") was
	-- written assuming synchronous ForEach/OnNew/ReplicatorCreated dispatch, from
	-- before ListenerFireMode existed. Force "immediate" so they keep passing
	-- regardless of the environment's Workspace.SignalBehavior (the default,
	-- "bindable", mirrors that setting and can defer). This runs at collection
	-- time, before any test body executes, so it's in effect for the whole file.
	BaseReplicator.SetListenerFireMode("immediate")

	--------------------------------------------------------------------------------

	describe("BaseReplicator.GetFromId", function()
		test("returns nil for an id that was never used", function()
			expect(BaseReplicator.GetFromId(-999999)).is(nil)
		end)

		test("returns the replicator that was just created with that id", function()
			local replicator = newTop("GetFromIdBasic")
			expect(BaseReplicator.GetFromId(replicator.Id)).is(replicator)
			replicator:Destroy()
		end)

		test("returns nil after the replicator with that id is destroyed", function()
			local replicator = newTop("GetFromIdAfterDestroy")
			local id = replicator.Id
			replicator:Destroy()
			expect(BaseReplicator.GetFromId(id)).is(nil)
		end)

		test("distinguishes between two different replicators' ids", function()
			local a = newTop("GetFromIdA")
			local b = newTop("GetFromIdB")
			expect(BaseReplicator.GetFromId(a.Id)).is(a)
			expect(BaseReplicator.GetFromId(b.Id)).is(b)
			expect(a.Id == b.Id).is(false)
			a:Destroy()
			b:Destroy()
		end)

		test("works for a child replicator's id, not just top-level ones", function()
			local parent = newTop("GetFromIdParent")
			local child = ServerReplicator.new {
				Namespace = uniqueToken("GetFromIdChild"),
				Data = FakeManager.new(),
				Parent = parent,
			}
			expect(BaseReplicator.GetFromId(child.Id)).is(child)
			child:Destroy()
			parent:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("BaseReplicator.GenerateId", function()
		test("returns a number", function()
			expect(type(BaseReplicator.GenerateId())).is("number")
		end)

		test("consecutive calls return different values", function()
			local a = BaseReplicator.GenerateId()
			local b = BaseReplicator.GenerateId()
			expect(a == b).is(false)
		end)

		test("ids are monotonically increasing", function()
			local a = BaseReplicator.GenerateId()
			local b = BaseReplicator.GenerateId()
			expect(b > a).is_true()
		end)

		test("calling it many times in a row never repeats a value", function()
			local seen: { [number]: boolean } = {}
			for _ = 1, 50 do
				local id = BaseReplicator.GenerateId()
				expect(seen[id]).is(nil)
				seen[id] = true
			end
		end)

		test("is what ServerReplicator.new() uses internally to assign Id", function()
			local before = BaseReplicator.GenerateId()
			local replicator = newTop("GenerateIdUsage")
			expect(replicator.Id > before).is_true()
			replicator:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("BaseReplicator.GetAll", function()
		test("with no condition, includes a freshly created replicator", function()
			local replicator = newTop("GetAllNoCondition")
			local all = BaseReplicator.GetAll()
			expect(table.find(all, replicator) ~= nil).is_true()
			replicator:Destroy()
		end)

		test("filters by ReplicationToken, returning only replicators using it", function()
			local tokenA = uniqueToken("GetAllTokenA")
			local tokenB = uniqueToken("GetAllTokenB")
			local a = ServerReplicator.new { Namespace = tokenA, Data = FakeManager.new(), ReplicationTargets = {} }
			local b = ServerReplicator.new { Namespace = tokenB, Data = FakeManager.new(), ReplicationTargets = {} }

			local resultsA = BaseReplicator.GetAll(tokenA)
			expect(#resultsA).is(1)
			expect(resultsA[1]).is(a)

			a:Destroy()
			b:Destroy()
		end)

		test("filters by token name string", function()
			local token = uniqueToken("GetAllStringToken")
			local replicator =
				ServerReplicator.new { Namespace = token, Data = FakeManager.new(), ReplicationTargets = {} }

			local results = BaseReplicator.GetAll(getTokenName(token))
			expect(#results).is(1)
			expect(results[1]).is(replicator)

			replicator:Destroy()
		end)

		test("filters by a tags table (superset match)", function()
			local replicator = newTop("GetAllTags", { Kind = "Boss" })
			local other = newTop("GetAllTagsOther", { Kind = "Minion" })

			local results = BaseReplicator.GetAll { Kind = "Boss" }
			expect(table.find(results, replicator) ~= nil).is_true()
			expect(table.find(results, other) ~= nil).never_is_true()

			replicator:Destroy()
			other:Destroy()
		end)

		test("filters by a custom function condition", function()
			local replicator = newTop("GetAllFunction")
			local results = BaseReplicator.GetAll(function(r)
				return r.Id == replicator.Id
			end)
			expect(#results).is(1)
			expect(results[1]).is(replicator)
			replicator:Destroy()
		end)

		test("returns an empty list when nothing matches", function()
			local results = BaseReplicator.GetAll("ThisTokenNameWasNeverRegistered")
			expect(#results).is(0)
		end)
	end)

	--------------------------------------------------------------------------------

	describe("BaseReplicator.ForEach", function()
		test("runs immediately for an existing matching replicator", function()
			local replicator = newTop("ForEachExisting")
			local seen: { any } = {}
			local disconnect = BaseReplicator.ForEach(replicator.Namespace, function(r)
				table.insert(seen, r)
			end)
			expect(table.find(seen, replicator) ~= nil).is_true()
			disconnect()
			replicator:Destroy()
		end)

		test("runs again for a future matching replicator created after the call", function()
			local token = uniqueToken("ForEachFuture")
			local seen: { any } = {}
			local disconnect = BaseReplicator.ForEach(getTokenName(token), function(r)
				table.insert(seen, r)
			end)
			local replicator =
				ServerReplicator.new { Namespace = token, Data = FakeManager.new(), ReplicationTargets = {} }
			expect(#seen).is(1)
			expect(seen[1]).is(replicator)
			disconnect()
			replicator:Destroy()
		end)

		test("the returned disconnect stops it from firing for further future replicators", function()
			local token = uniqueToken("ForEachDisconnect")
			local count = 0
			local disconnect = BaseReplicator.ForEach(getTokenName(token), function()
				count += 1
			end)
			disconnect()
			local replicator =
				ServerReplicator.new { Namespace = token, Data = FakeManager.new(), ReplicationTargets = {} }
			expect(count).is(0)
			replicator:Destroy()
		end)

		test("respects a tag condition", function()
			local seen: { any } = {}
			local disconnect = BaseReplicator.ForEach({ Kind = "ForEachTagMatch" }, function(r)
				table.insert(seen, r)
			end)
			local matching = newTop("ForEachTagYes", { Kind = "ForEachTagMatch" })
			local nonMatching = newTop("ForEachTagNo", { Kind = "Other" })
			expect(table.find(seen, matching) ~= nil).is_true()
			expect(table.find(seen, nonMatching) ~= nil).never_is_true()
			disconnect()
			matching:Destroy()
			nonMatching:Destroy()
		end)

		test("does not run for a non-matching token", function()
			local tokenA = uniqueToken("ForEachTokenA")
			local tokenB = uniqueToken("ForEachTokenB")
			local count = 0
			local disconnect = BaseReplicator.ForEach(getTokenName(tokenA), function()
				count += 1
			end)
			local replicator =
				ServerReplicator.new { Namespace = tokenB, Data = FakeManager.new(), ReplicationTargets = {} }
			expect(count).is(0)
			disconnect()
			replicator:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("BaseReplicator.PromiseFirst", function()
		test("resolves immediately when a match already exists", function()
			local replicator = newTop("PromiseFirstExisting")
			local promise = BaseReplicator.PromiseFirst(replicator.Namespace)
			expect(promise:getStatus()).is("Resolved")
			replicator:Destroy()
		end)

		test("stays pending when nothing matches yet", function()
			local token = uniqueToken("PromiseFirstPending")
			local promise = BaseReplicator.PromiseFirst(getTokenName(token))
			expect(promise:getStatus()).is("Started")
		end)

		test("resolves once a future matching replicator is created", function()
			local token = uniqueToken("PromiseFirstFuture")
			local promise = BaseReplicator.PromiseFirst(getTokenName(token))
			local replicator =
				ServerReplicator.new { Namespace = token, Data = FakeManager.new(), ReplicationTargets = {} }
			expect(promise:getStatus()).is("Resolved")
			replicator:Destroy()
		end)

		test("works with a tag condition", function()
			local promise = BaseReplicator.PromiseFirst { Kind = "PromiseFirstTagMatch" }
			expect(promise:getStatus()).is("Started")
			local replicator = newTop("PromiseFirstTag", { Kind = "PromiseFirstTagMatch" })
			expect(promise:getStatus()).is("Resolved")
			replicator:Destroy()
		end)

		test("works with a custom function condition", function()
			local replicator = newTop("PromiseFirstFunctionExisting")
			local promise = BaseReplicator.PromiseFirst(function(r)
				return r.Id == replicator.Id
			end)
			expect(promise:getStatus()).is("Resolved")
			replicator:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("BaseReplicator.GetFirst", function()
		test("returns nil when nothing matches", function()
			expect(BaseReplicator.GetFirst("ThisTokenNameWasNeverRegisteredEither")).is(nil)
		end)

		test("returns a match by token name", function()
			local replicator = newTop("GetFirstToken")
			expect(BaseReplicator.GetFirst(replicator.Namespace)).is(replicator)
			replicator:Destroy()
		end)

		test("returns a match by tag condition", function()
			local replicator = newTop("GetFirstTag", { Kind = "GetFirstTagMatch" })
			expect(BaseReplicator.GetFirst { Kind = "GetFirstTagMatch" }).is(replicator)
			replicator:Destroy()
		end)

		test("returns a match by custom function condition", function()
			local replicator = newTop("GetFirstFunction")
			local found = BaseReplicator.GetFirst(function(r)
				return r.Id == replicator.Id
			end)
			expect(found).is(replicator)
			replicator:Destroy()
		end)

		test("does not wait for a future match -- nil now even if one is created right after", function()
			local token = uniqueToken("GetFirstNoWait")
			expect(BaseReplicator.GetFirst(getTokenName(token))).is(nil)
			local replicator =
				ServerReplicator.new { Namespace = token, Data = FakeManager.new(), ReplicationTargets = {} }
			replicator:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("BaseReplicator.OnNew", function()
		test("fires for a future replicator with a matching token", function()
			local token = uniqueToken("OnNewTest")
			local seen: { any } = {}
			local disconnect = BaseReplicator.OnNew(getTokenName(token), function(replicator)
				table.insert(seen, replicator)
			end)

			local replicator =
				ServerReplicator.new { Namespace = token, Data = FakeManager.new(), ReplicationTargets = {} }

			expect(#seen).is(1)
			expect(seen[1]).is(replicator)

			disconnect()
			replicator:Destroy()
		end)

		test("fires once per new matching replicator, not just the first", function()
			local token = uniqueToken("OnNewMultiple")
			local count = 0
			local disconnect = BaseReplicator.OnNew(getTokenName(token), function()
				count += 1
			end)

			local a = ServerReplicator.new { Namespace = token, Data = FakeManager.new(), ReplicationTargets = {} }
			local b = ServerReplicator.new { Namespace = token, Data = FakeManager.new(), ReplicationTargets = {} }
			expect(count).is(2)

			disconnect()
			a:Destroy()
			b:Destroy()
		end)

		test("multiple independent listeners for the same token both fire", function()
			local token = uniqueToken("OnNewMultipleListeners")
			local countA, countB = 0, 0
			local disconnectA = BaseReplicator.OnNew(getTokenName(token), function()
				countA += 1
			end)
			local disconnectB = BaseReplicator.OnNew(getTokenName(token), function()
				countB += 1
			end)

			local replicator =
				ServerReplicator.new { Namespace = token, Data = FakeManager.new(), ReplicationTargets = {} }
			expect(countA).is(1)
			expect(countB).is(1)

			disconnectA()
			disconnectB()
			replicator:Destroy()
		end)

		test("disconnecting stops future firing", function()
			local token = uniqueToken("OnNewDisconnect")
			local count = 0
			local disconnect = BaseReplicator.OnNew(getTokenName(token), function()
				count += 1
			end)
			disconnect()

			local replicator =
				ServerReplicator.new { Namespace = token, Data = FakeManager.new(), ReplicationTargets = {} }
			expect(count).is(0)
			replicator:Destroy()
		end)

		test("does not fire for a replicator registered under a different token", function()
			local tokenA = uniqueToken("OnNewTokenA")
			local tokenB = uniqueToken("OnNewTokenB")
			local count = 0
			local disconnect = BaseReplicator.OnNew(getTokenName(tokenA), function()
				count += 1
			end)

			local replicator =
				ServerReplicator.new { Namespace = tokenB, Data = FakeManager.new(), ReplicationTargets = {} }
			expect(count).is(0)

			disconnect()
			replicator:Destroy()
		end)

		test("accepts a tag-table condition and fires only for matching replicators", function()
			local seen: { any } = {}
			local disconnect = BaseReplicator.OnNew({ Kind = "OnNewTagMatch" }, function(r)
				table.insert(seen, r)
			end)
			local matching = newTop("OnNewTagYes", { Kind = "OnNewTagMatch" })
			local nonMatching = newTop("OnNewTagNo", { Kind = "Other" })
			expect(table.find(seen, matching) ~= nil).is_true()
			expect(table.find(seen, nonMatching) ~= nil).never_is_true()
			disconnect()
			matching:Destroy()
			nonMatching:Destroy()
		end)

		test("accepts a predicate condition and fires when the predicate returns true", function()
			-- Captures a tag value fixed up front, not the replicator identity
			-- itself: under "immediate" dispatch the predicate runs synchronously
			-- inside `newTop`/`ServerReplicator.new`, before it could return and
			-- be assigned to a local, so a `target == r` predicate would always
			-- see `target` as its pre-assignment (nil) value.
			local wantedMarker = uniqueToken("OnNewPredicateTarget")
			local seen: { any } = {}
			local disconnect = BaseReplicator.OnNew(function(r)
				return r.Tags.Marker == wantedMarker
			end, function(r)
				table.insert(seen, r)
			end)
			local other = newTop("OnNewPredicateOther")
			expect(#seen).is(0)
			local target = newTop("OnNewPredicateTarget", { Marker = wantedMarker })
			expect(#seen).is(1)
			expect(seen[1]).is(target)
			disconnect()
			other:Destroy()
			target:Destroy()
		end)

		test("a throwing listener does not prevent sibling listeners from firing", function()
			local token = uniqueToken("OnNewIsolation")
			local safeCount = 0
			local disconnectBad = BaseReplicator.OnNew(getTokenName(token), function()
				error("intentional error")
			end)
			local disconnectGood = BaseReplicator.OnNew(getTokenName(token), function()
				safeCount += 1
			end)
			local replicator =
				ServerReplicator.new { Namespace = token, Data = FakeManager.new(), ReplicationTargets = {} }
			-- task.spawn isolates each listener; the good one still fires
			expect(safeCount).is(1)
			disconnectBad()
			disconnectGood()
			replicator:Destroy()
		end)

		test("anonymous replicator does NOT fire a string-condition OnNew listener", function()
			local count = 0
			local disconnect = BaseReplicator.OnNew("SomeNamespace", function()
				count += 1
			end)
			local anon = ServerReplicator.new { Data = FakeManager.new(), ReplicationTargets = {} }
			expect(count).is(0)
			disconnect()
			anon:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------

	-- Every test here restores "immediate" before returning, since every other
	-- describe block in this file depends on it.
	describe("BaseReplicator.ListenerFireMode", function()
		test('"deferred" mode defers ForEach/OnNew firing to the next resumption cycle', function()
			BaseReplicator.SetListenerFireMode("deferred")
			local token = uniqueToken("FireModeDeferredFuture")
			local forEachCount, onNewCount = 0, 0
			local disconnectForEach = BaseReplicator.ForEach(getTokenName(token), function()
				forEachCount += 1
			end)
			local disconnectOnNew = BaseReplicator.OnNew(getTokenName(token), function()
				onNewCount += 1
			end)

			local replicator =
				ServerReplicator.new { Namespace = token, Data = FakeManager.new(), ReplicationTargets = {} }
			expect(forEachCount).is(0) -- nothing has run synchronously yet
			expect(onNewCount).is(0)

			task.wait()
			expect(forEachCount).is(1)
			expect(onNewCount).is(1)

			disconnectForEach()
			disconnectOnNew()
			replicator:Destroy()
			BaseReplicator.SetListenerFireMode("immediate")
		end)

		test('"deferred" mode also defers ForEach\'s already-existing-matches loop', function()
			BaseReplicator.SetListenerFireMode("immediate")
			local replicator = newTop("FireModeDeferredExisting")
			BaseReplicator.SetListenerFireMode("deferred")

			local seen: { any } = {}
			local disconnect = BaseReplicator.ForEach(replicator.Namespace, function(r)
				table.insert(seen, r)
			end)
			expect(#seen).is(0) -- nothing has run synchronously yet

			task.wait()
			expect(table.find(seen, replicator) ~= nil).is_true()

			disconnect()
			replicator:Destroy()
			BaseReplicator.SetListenerFireMode("immediate")
		end)

		test('"bindable" mode mirrors the current Workspace.SignalBehavior', function()
			BaseReplicator.SetListenerFireMode("bindable")
			local token = uniqueToken("FireModeBindable")
			local count = 0
			local disconnect = BaseReplicator.OnNew(getTokenName(token), function()
				count += 1
			end)

			local replicator =
				ServerReplicator.new { Namespace = token, Data = FakeManager.new(), ReplicationTargets = {} }
			task.wait() -- covers both Immediate (already fired) and Deferred SignalBehavior
			expect(count).is(1)

			disconnect()
			replicator:Destroy()
			BaseReplicator.SetListenerFireMode("immediate")
		end)

		test('"bindable" mode also applies to ForEach\'s already-existing-matches loop', function()
			BaseReplicator.SetListenerFireMode("immediate")
			-- Two pre-existing matches: the second dispatch consumes the cached
			-- SignalBehavior probe instead of re-probing.
			local replicatorA = newTop("FireModeBindableExisting")
			local replicatorB = ServerReplicator.new {
				Namespace = replicatorA.Token,
				Data = FakeManager.new(),
				ReplicationTargets = {},
			}
			BaseReplicator.SetListenerFireMode("bindable")

			local seen: { any } = {}
			local disconnect = BaseReplicator.ForEach(replicatorA.Namespace, function(r)
				table.insert(seen, r)
			end)

			task.wait() -- covers both Immediate (already fired) and Deferred SignalBehavior
			expect(table.find(seen, replicatorA) ~= nil).is_true()
			expect(table.find(seen, replicatorB) ~= nil).is_true()

			disconnect()
			replicatorA:Destroy()
			replicatorB:Destroy()
			BaseReplicator.SetListenerFireMode("immediate")
		end)

		test('"immediate" mode runs ForEach/OnNew synchronously', function()
			local token = uniqueToken("FireModeImmediate")
			local count = 0
			local disconnect = BaseReplicator.OnNew(getTokenName(token), function()
				count += 1
			end)
			local replicator =
				ServerReplicator.new { Namespace = token, Data = FakeManager.new(), ReplicationTargets = {} }
			expect(count).is(1)
			disconnect()
			replicator:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("Namespace ownership ledger (TOKEN)", function()
		test("TOKEN() claims a name exclusively; raw-string replicator with same name throws", function()
			local token = uniqueToken("LedgerRawBlock")
			local name = getTokenName(token)
			local ok, err = pcall(function()
				ServerReplicator.new { Namespace = name, Data = FakeManager.new(), ReplicationTargets = {} }
			end)
			expect(ok).is(false)
			expect(typeof(err) == "string" and string.find(err, "ReplicationToken") ~= nil).is_true()
		end)

		test("TOKEN() on a name with live raw-string replicators throws", function()
			local name = "LedgerTokenAfterRaw#" .. tostring(math.random(1e9))
			local r = ServerReplicator.new { Namespace = name, Data = FakeManager.new(), ReplicationTargets = {} }
			local ok, err = pcall(function()
				ServerReplicator.TOKEN(name)
			end)
			expect(ok).is(false)
			expect(typeof(err) == "string" and string.find(err, "raw-string", 1, true) ~= nil).is_true()
			r:Destroy()
		end)

		test("TOKEN.destroy() frees the name; the name can then be used as a raw string", function()
			local token = uniqueToken("LedgerDestroyFrees")
			local name = getTokenName(token)
			ServerReplicator.TOKEN.destroy(token)
			-- After destroy, raw-string use is allowed again
			local r = ServerReplicator.new { Namespace = name, Data = FakeManager.new(), ReplicationTargets = {} }
			expect(r.Namespace).is(name)
			r:Destroy()
		end)

		test("TOKEN.destroy() throws when a replicator still uses the namespace", function()
			local token = uniqueToken("LedgerDestroyInUse")
			local r = ServerReplicator.new { Namespace = token, Data = FakeManager.new(), ReplicationTargets = {} }
			local ok, err = pcall(function()
				ServerReplicator.TOKEN.destroy(token)
			end)
			expect(ok).is(false)
			expect(typeof(err) == "string" and string.find(err, "destroy") ~= nil).is_true()
			r:Destroy()
			-- Now succeeds
			ServerReplicator.TOKEN.destroy(token)
		end)

		test("TOKEN.destroy() throws on an already-destroyed token", function()
			local token = uniqueToken("LedgerDoubleDestroy")
			ServerReplicator.TOKEN.destroy(token)
			local ok, _ = pcall(function()
				ServerReplicator.TOKEN.destroy(token)
			end)
			expect(ok).is(false)
		end)

		test("destroy → re-claim: after destroy, TOKEN() can claim the name again", function()
			local token = uniqueToken("LedgerReClaim")
			local name = getTokenName(token)
			ServerReplicator.TOKEN.destroy(token)
			local token2 = ServerReplicator.TOKEN(name)
			expect(getTokenName(token2)).is(name)
			ServerReplicator.TOKEN.destroy(token2)
		end)

		test("multiple live replicators with the same token: all must be destroyed before TOKEN.destroy", function()
			local token = uniqueToken("LedgerMultiLive")
			local r1 = ServerReplicator.new { Namespace = token, Data = FakeManager.new(), ReplicationTargets = {} }
			local r2 = ServerReplicator.new { Namespace = token, Data = FakeManager.new(), ReplicationTargets = {} }
			r1:Destroy()
			local ok, _ = pcall(function()
				ServerReplicator.TOKEN.destroy(token)
			end)
			expect(ok).is(false)
			r2:Destroy()
			ServerReplicator.TOKEN.destroy(token) -- now succeeds
		end)
	end)

	--------------------------------------------------------------------------------

	describe("BaseReplicator.Namespace", function()
		test("matches the registered token's name for a top-level replicator", function()
			local token = uniqueToken("GetTokenNameTop")
			local replicator =
				ServerReplicator.new { Namespace = token, Data = FakeManager.new(), ReplicationTargets = {} }
			expect(replicator.Namespace).is(getTokenName(token))
			replicator:Destroy()
		end)

		test("matches for a child replicator", function()
			local parent = newTop("GetTokenNameParent")
			local childNamespace = uniqueToken("GetTokenNameChild")
			local child = ServerReplicator.new { Namespace = childNamespace, Data = FakeManager.new(), Parent = parent }
			expect(child.Namespace).is(getTokenName(childNamespace))
			child:Destroy()
			parent:Destroy()
		end)

		test("distinguishes two different namespaces", function()
			local a = newTop("GetTokenNameA")
			local b = newTop("GetTokenNameB")
			expect(a.Namespace == b.Namespace).is(false)
			a:Destroy()
			b:Destroy()
		end)

		test("matches on the client-side mirror too", function()
			local message = FlatCodec.BuildMessage { FlatCodec.CreateItem(50001, nil, "GetTokenNameClient", {}, {}) };
			(ClientReplicator :: any)._HandleMessage(message)
			local mirrored = BaseReplicator.GetFromId(50001) :: any
			expect(mirrored.Namespace).is("GetTokenNameClient");
			(ClientReplicator :: any)._HandleMessage(FlatCodec.BuildMessage { FlatCodec.DestroyItem(50001) })
		end)

		test("is unchanged after the replicator is reparented", function()
			local token = uniqueToken("GetTokenNameAfterReparent")
			local top = newTop("GetTokenNameOtherTop")
			local otherTop = newTop("GetTokenNameOtherTop2")
			local child = ServerReplicator.new { Namespace = token, Data = FakeManager.new(), Parent = top }
			child:SetParent(otherTop)
			expect(child.Namespace).is(getTokenName(token))
			child:Destroy()
			top:Destroy()
			otherTop:Destroy()
		end)

		test("is nil for an anonymous replicator (no Namespace given)", function()
			local replicator = ServerReplicator.new { Data = FakeManager.new(), ReplicationTargets = {} }
			expect(replicator.Namespace).is(nil)
			replicator:Destroy()
		end)

		test("plain string Namespace works without a token", function()
			-- Each test run appends a unique suffix to avoid ledger conflicts.
			local name = "PlainNs#" .. tostring(math.random(1e9))
			local r = ServerReplicator.new { Namespace = name, Data = FakeManager.new(), ReplicationTargets = {} }
			expect(r.Namespace).is(name)
			r:Destroy()
		end)

		test("anonymous replicator round-trips through encode/decode with empty namespace", function()
			local message = FlatCodec.BuildMessage { FlatCodec.CreateItem(50099, nil, "", {}, {}) };
			(ClientReplicator :: any)._HandleMessage(message)
			local mirrored = BaseReplicator.GetFromId(50099) :: any
			expect(mirrored.Namespace).is(nil);
			(ClientReplicator :: any)._HandleMessage(FlatCodec.BuildMessage { FlatCodec.DestroyItem(50099) })
		end)
	end)

	--------------------------------------------------------------------------------

	describe("BaseReplicator.IsTopLevel", function()
		test("true for a replicator created with ReplicationTargets", function()
			local replicator = newTop("IsTopLevelTrue")
			expect(replicator:IsTopLevel()).is_true()
			replicator:Destroy()
		end)

		test("false for a direct child", function()
			local parent = newTop("IsTopLevelParent")
			local child = ServerReplicator.new {
				Namespace = uniqueToken("IsTopLevelChild"),
				Data = FakeManager.new(),
				Parent = parent,
			}
			expect(child:IsTopLevel()).is(false)
			child:Destroy()
			parent:Destroy()
		end)

		test("false for a grandchild", function()
			local top = newTop("IsTopLevelGrandparent")
			local child = ServerReplicator.new {
				Namespace = uniqueToken("IsTopLevelMidChild"),
				Data = FakeManager.new(),
				Parent = top,
			}
			local grandchild = ServerReplicator.new {
				Namespace = uniqueToken("IsTopLevelGrandchild"),
				Data = FakeManager.new(),
				Parent = child,
			}
			expect(grandchild:IsTopLevel()).is(false)
			grandchild:Destroy()
			child:Destroy()
			top:Destroy()
		end)

		test("true for a client-side mirror built from a Create item with no ParentId", function()
			local message = FlatCodec.BuildMessage { FlatCodec.CreateItem(50002, nil, "IsTopLevelClientTop", {}, {}) };
			(ClientReplicator :: any)._HandleMessage(message)
			expect((BaseReplicator.GetFromId(50002) :: any):IsTopLevel()).is_true();
			(ClientReplicator :: any)._HandleMessage(FlatCodec.BuildMessage { FlatCodec.DestroyItem(50002) })
		end)

		test("false for a client-side mirror built from a Create item with a ParentId", function()
			local message = FlatCodec.BuildMessage {
				FlatCodec.CreateItem(50003, nil, "IsTopLevelClientTop2", {}, {}),
				FlatCodec.CreateItem(50004, 50003, "IsTopLevelClientChild", {}, {}),
			};
			(ClientReplicator :: any)._HandleMessage(message)
			expect((BaseReplicator.GetFromId(50004) :: any):IsTopLevel()).is(false);
			(ClientReplicator :: any)._HandleMessage(FlatCodec.BuildMessage { FlatCodec.DestroyItem(50003) })
		end)
	end)

	--------------------------------------------------------------------------------

	describe("BaseReplicator.GetParent", function()
		test("nil for a top-level replicator", function()
			local replicator = newTop("GetParentTop")
			expect(replicator:GetParent()).is(nil)
			replicator:Destroy()
		end)

		test("returns the immediate parent for a child", function()
			local parent = newTop("GetParentParent")
			local child = ServerReplicator.new {
				Namespace = uniqueToken("GetParentChild"),
				Data = FakeManager.new(),
				Parent = parent,
			}
			expect(child:GetParent()).is(parent)
			child:Destroy()
			parent:Destroy()
		end)

		test("returns the immediate parent, not the grandparent, for a grandchild", function()
			local top = newTop("GetParentGrandparent")
			local child = ServerReplicator.new {
				Namespace = uniqueToken("GetParentMidChild"),
				Data = FakeManager.new(),
				Parent = top,
			}
			local grandchild = ServerReplicator.new {
				Namespace = uniqueToken("GetParentGrandchild"),
				Data = FakeManager.new(),
				Parent = child,
			}
			expect(grandchild:GetParent()).is(child)
			expect(grandchild:GetParent()).never_is(top)
			grandchild:Destroy()
			child:Destroy()
			top:Destroy()
		end)

		test("reflects the new parent after SetParent", function()
			local topA = newTop("GetParentTopA")
			local topB = newTop("GetParentTopB")
			local child = ServerReplicator.new {
				Namespace = uniqueToken("GetParentSwapChild"),
				Data = FakeManager.new(),
				Parent = topA,
			}
			child:SetParent(topB)
			expect(child:GetParent()).is(topB)
			child:Destroy()
			topA:Destroy()
			topB:Destroy()
		end)

		test("on the client-side mirror, matches the server's parent identity by Id", function()
			local message = FlatCodec.BuildMessage {
				FlatCodec.CreateItem(50005, nil, "GetParentClientTop", {}, {}),
				FlatCodec.CreateItem(50006, 50005, "GetParentClientChild", {}, {}),
			};
			(ClientReplicator :: any)._HandleMessage(message)
			local child = BaseReplicator.GetFromId(50006) :: any
			expect(child:GetParent().Id).is(50005);
			(ClientReplicator :: any)._HandleMessage(FlatCodec.BuildMessage { FlatCodec.DestroyItem(50005) })
		end)
	end)

	--------------------------------------------------------------------------------

	describe("BaseReplicator.GetChildren", function()
		test("empty for a replicator with no children", function()
			local replicator = newTop("GetChildrenEmpty")
			expect(#replicator:GetChildren()).is(0)
			replicator:Destroy()
		end)

		test("contains exactly the direct children, not grandchildren", function()
			local parent = newTop("GetChildrenParent")
			local child = ServerReplicator.new {
				Namespace = uniqueToken("GetChildrenChild"),
				Data = FakeManager.new(),
				Parent = parent,
			}
			local grandchild = ServerReplicator.new {
				Namespace = uniqueToken("GetChildrenGrandchild"),
				Data = FakeManager.new(),
				Parent = child,
			}
			local children = parent:GetChildren()
			expect(#children).is(1)
			expect(children[1]).is(child)
			grandchild:Destroy()
			child:Destroy()
			parent:Destroy()
		end)

		test("reflects a newly added child on a fresh call", function()
			local parent = newTop("GetChildrenFresh")
			expect(#parent:GetChildren()).is(0)
			local child = ServerReplicator.new {
				Namespace = uniqueToken("GetChildrenFreshChild"),
				Data = FakeManager.new(),
				Parent = parent,
			}
			expect(#parent:GetChildren()).is(1)
			child:Destroy()
			parent:Destroy()
		end)

		test("no longer contains a child after that child is destroyed", function()
			local parent = newTop("GetChildrenAfterDestroy")
			local child = ServerReplicator.new {
				Namespace = uniqueToken("GetChildrenAfterDestroyChild"),
				Data = FakeManager.new(),
				Parent = parent,
			}
			child:Destroy()
			expect(#parent:GetChildren()).is(0)
			parent:Destroy()
		end)

		test("returns every sibling when there are multiple children", function()
			local parent = newTop("GetChildrenSiblings")
			local childA = ServerReplicator.new {
				Namespace = uniqueToken("GetChildrenSiblingA"),
				Data = FakeManager.new(),
				Parent = parent,
			}
			local childB = ServerReplicator.new {
				Namespace = uniqueToken("GetChildrenSiblingB"),
				Data = FakeManager.new(),
				Parent = parent,
			}
			local children = parent:GetChildren()
			expect(#children).is(2)
			expect(table.find(children, childA) ~= nil).is_true()
			expect(table.find(children, childB) ~= nil).is_true()
			childA:Destroy()
			childB:Destroy()
			parent:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("BaseReplicator.GetDescendants", function()
		test("empty for a leaf replicator", function()
			local replicator = newTop("GetDescendantsLeaf")
			expect(#replicator:GetDescendants()).is(0)
			replicator:Destroy()
		end)

		test("includes children and grandchildren", function()
			local top = newTop("GetDescendantsTop")
			local child = ServerReplicator.new {
				Namespace = uniqueToken("GetDescendantsChild"),
				Data = FakeManager.new(),
				Parent = top,
			}
			local grandchild = ServerReplicator.new {
				Namespace = uniqueToken("GetDescendantsGrandchild"),
				Data = FakeManager.new(),
				Parent = child,
			}
			local descendants = top:GetDescendants()
			expect(table.find(descendants, child) ~= nil).is_true()
			expect(table.find(descendants, grandchild) ~= nil).is_true()
			grandchild:Destroy()
			child:Destroy()
			top:Destroy()
		end)

		test("count matches the total subtree size excluding self", function()
			local top = newTop("GetDescendantsCount")
			local childA = ServerReplicator.new {
				Namespace = uniqueToken("GetDescendantsCountA"),
				Data = FakeManager.new(),
				Parent = top,
			}
			local childB = ServerReplicator.new {
				Namespace = uniqueToken("GetDescendantsCountB"),
				Data = FakeManager.new(),
				Parent = top,
			}
			local grandchild = ServerReplicator.new {
				Namespace = uniqueToken("GetDescendantsCountGrandchild"),
				Data = FakeManager.new(),
				Parent = childA,
			}
			expect(#top:GetDescendants()).is(3)
			grandchild:Destroy()
			childA:Destroy()
			childB:Destroy()
			top:Destroy()
		end)

		test("updates after a new descendant is added", function()
			local top = newTop("GetDescendantsUpdate")
			expect(#top:GetDescendants()).is(0)
			local child = ServerReplicator.new {
				Namespace = uniqueToken("GetDescendantsUpdateChild"),
				Data = FakeManager.new(),
				Parent = top,
			}
			expect(#top:GetDescendants()).is(1)
			child:Destroy()
			top:Destroy()
		end)

		test("shrinks after a descendant subtree is destroyed", function()
			local top = newTop("GetDescendantsShrink")
			local child = ServerReplicator.new {
				Namespace = uniqueToken("GetDescendantsShrinkChild"),
				Data = FakeManager.new(),
				Parent = top,
			}
			local grandchild = ServerReplicator.new {
				Namespace = uniqueToken("GetDescendantsShrinkGrandchild"),
				Data = FakeManager.new(),
				Parent = child,
			}
			expect(#top:GetDescendants()).is(2)
			grandchild:Destroy()
			expect(#top:GetDescendants()).is(1)
			child:Destroy()
			top:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("BaseReplicator.FindFirstChild", function()
		test("non-recursive finds a direct child matching tags", function()
			local parent = newTop("FindFirstChildDirect")
			local child = ServerReplicator.new {
				Namespace = uniqueToken("FindFirstChildDirectChild"),
				Data = FakeManager.new(),
				Parent = parent,
				Tags = { Name = "Target" },
			}
			expect(parent:FindFirstChild { Name = "Target" }).is(child)
			child:Destroy()
			parent:Destroy()
		end)

		test("non-recursive returns nil for a grandchild", function()
			local top = newTop("FindFirstChildNonRecursive")
			local child = ServerReplicator.new {
				Namespace = uniqueToken("FindFirstChildMid"),
				Data = FakeManager.new(),
				Parent = top,
			}
			local grandchild = ServerReplicator.new {
				Namespace = uniqueToken("FindFirstChildGrandchild"),
				Data = FakeManager.new(),
				Parent = child,
				Tags = { Name = "Grandchild" },
			}
			expect(top:FindFirstChild { Name = "Grandchild" }).is(nil)
			grandchild:Destroy()
			child:Destroy()
			top:Destroy()
		end)

		test("recursive=true finds a grandchild", function()
			local top = newTop("FindFirstChildRecursive")
			local child = ServerReplicator.new {
				Namespace = uniqueToken("FindFirstChildRecursiveMid"),
				Data = FakeManager.new(),
				Parent = top,
			}
			local grandchild = ServerReplicator.new {
				Namespace = uniqueToken("FindFirstChildRecursiveGrandchild"),
				Data = FakeManager.new(),
				Parent = child,
				Tags = { Name = "Grandchild" },
			}
			expect(top:FindFirstChild({ Name = "Grandchild" }, true)).is(grandchild)
			grandchild:Destroy()
			child:Destroy()
			top:Destroy()
		end)

		test("returns nil when nothing matches even recursively", function()
			local top = newTop("FindFirstChildNoMatch")
			local child = ServerReplicator.new {
				Namespace = uniqueToken("FindFirstChildNoMatchChild"),
				Data = FakeManager.new(),
				Parent = top,
			}
			expect(top:FindFirstChild({ Name = "Nonexistent" }, true)).is(nil)
			child:Destroy()
			top:Destroy()
		end)

		test("matches via a custom function condition", function()
			local top = newTop("FindFirstChildFunction")
			local child = ServerReplicator.new {
				Namespace = uniqueToken("FindFirstChildFunctionChild"),
				Data = FakeManager.new(),
				Parent = top,
			}
			local found = top:FindFirstChild(function(r)
				return r.Id == child.Id
			end)
			expect(found).is(child)
			child:Destroy()
			top:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("BaseReplicator.PromiseFirstChild", function()
		test("resolves immediately if a matching child already exists", function()
			local parent = newTop("PromiseFirstChildExisting")
			local child = ServerReplicator.new {
				Namespace = uniqueToken("PromiseFirstChildExistingChild"),
				Data = FakeManager.new(),
				Parent = parent,
				Tags = { Name = "Target" },
			}
			local promise = parent:PromiseFirstChild { Name = "Target" }
			expect(promise:getStatus()).is("Resolved")
			child:Destroy()
			parent:Destroy()
		end)

		test("is pending if no matching child exists yet", function()
			local parent = newTop("PromiseFirstChildPending")
			local promise = parent:PromiseFirstChild { Name = "Target" }
			expect(promise:getStatus()).is("Started")
			parent:Destroy()
		end)

		test("resolves once a future matching child is added", function()
			local parent = newTop("PromiseFirstChildFuture")
			local promise = parent:PromiseFirstChild { Name = "Target" }
			local child = ServerReplicator.new {
				Namespace = uniqueToken("PromiseFirstChildFutureChild"),
				Data = FakeManager.new(),
				Parent = parent,
				Tags = { Name = "Target" },
			}
			expect(promise:getStatus()).is("Resolved")
			child:Destroy()
			parent:Destroy()
		end)

		test("does not resolve for a child added to a DIFFERENT parent", function()
			local parentA = newTop("PromiseFirstChildScopeA")
			local parentB = newTop("PromiseFirstChildScopeB")
			local promise = parentA:PromiseFirstChild { Name = "Target" }
			local child = ServerReplicator.new {
				Namespace = uniqueToken("PromiseFirstChildScopeBChild"),
				Data = FakeManager.new(),
				Parent = parentB,
				Tags = { Name = "Target" },
			}
			expect(promise:getStatus()).is("Started")
			child:Destroy()
			parentA:Destroy()
			parentB:Destroy()
		end)

		test("resolves with no condition at all -- the first child ever added", function()
			local parent = newTop("PromiseFirstChildNoCondition")
			local promise = parent:PromiseFirstChild()
			local child = ServerReplicator.new {
				Namespace = uniqueToken("PromiseFirstChildNoConditionChild"),
				Data = FakeManager.new(),
				Parent = parent,
			}
			expect(promise:getStatus()).is("Resolved")
			child:Destroy()
			parent:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("BaseReplicator.HasTags", function()
		test("true when every given tag matches", function()
			local replicator = newTop("IsSupersetTrue", { A = 1, B = 2 })
			expect(replicator:HasTags { A = 1, B = 2 }).is_true()
			replicator:Destroy()
		end)

		test("true for an empty given-tags table (trivial superset)", function()
			local replicator = newTop("IsSupersetEmpty", { A = 1 })
			expect(replicator:HasTags {}).is_true()
			replicator:Destroy()
		end)

		test("false when a given tag's value differs", function()
			local replicator = newTop("IsSupersetValueDiffers", { A = 1 })
			expect(replicator:HasTags { A = 99 }).is(false)
			replicator:Destroy()
		end)

		test("false when a given tag is missing entirely", function()
			local replicator = newTop("IsSupersetMissing", { A = 1 })
			expect(replicator:HasTags { A = 1, C = 3 }).is(false)
			replicator:Destroy()
		end)

		test("true when the replicator has extra tags beyond the given ones", function()
			local replicator = newTop("IsSupersetExtra", { A = 1, B = 2 })
			expect(replicator:HasTags { A = 1 }).is_true()
			replicator:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("BaseReplicator.IsSubsetOfTags", function()
		test("true when the replicator's tags are all present in a larger given set", function()
			local replicator = newTop("IsSubsetLarger", { A = 1, B = 2 })
			expect(replicator:IsSubsetOfTags { A = 1, B = 2, C = 3 }).is_true()
			replicator:Destroy()
		end)

		test("true when the replicator has no tags at all", function()
			local replicator = newTop("IsSubsetNoTags")
			expect(replicator:IsSubsetOfTags {}).is_true()
			expect(replicator:IsSubsetOfTags { A = 1 }).is_true()
			replicator:Destroy()
		end)

		test("false when the given set is missing one of the replicator's tags", function()
			local replicator = newTop("IsSubsetMissing", { A = 1, B = 2 })
			expect(replicator:IsSubsetOfTags { A = 1 }).is(false)
			replicator:Destroy()
		end)

		test("false when a shared key's value differs", function()
			local replicator = newTop("IsSubsetValueDiffers", { A = 1 })
			expect(replicator:IsSubsetOfTags { A = 2 }).is(false)
			replicator:Destroy()
		end)

		test("true for an exact match", function()
			local replicator = newTop("IsSubsetExact", { A = 1, B = 2 })
			expect(replicator:IsSubsetOfTags { A = 1, B = 2 }).is_true()
			replicator:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("BaseReplicator.Destroy", function()
		test("removes the replicator from GetFromId", function()
			local replicator = newTop("DestroyRemovesFromGetFromId")
			local id = replicator.Id
			replicator:Destroy()
			expect(BaseReplicator.GetFromId(id)).is(nil)
		end)

		test("detaches the replicator from its parent's GetChildren", function()
			local parent = newTop("DestroyDetaches")
			local child = ServerReplicator.new {
				Namespace = uniqueToken("DestroyDetachesChild"),
				Data = FakeManager.new(),
				Parent = parent,
			}
			child:Destroy()
			expect(#parent:GetChildren()).is(0)
			parent:Destroy()
		end)

		test("fires ChildRemoved on the former parent", function()
			local parent = newTop("DestroyFiresChildRemoved")
			local child = ServerReplicator.new {
				Namespace = uniqueToken("DestroyFiresChildRemovedChild"),
				Data = FakeManager.new(),
				Parent = parent,
			}
			local removed: any = nil
			parent.ChildRemoved:Connect(function(r)
				removed = r
			end)
			child:Destroy()
			expect(removed).is(child)
			parent:Destroy()
		end)

		test("children survive parent destruction: discoverable and reparented to ServerReplicator.None", function()
			local parent = newTop("DestroyNoCascade")
			local child = ServerReplicator.new {
				Namespace = uniqueToken("DestroyNoCascadeChild"),
				Data = FakeManager.new(),
				Parent = parent,
			}
			parent:Destroy()
			expect(BaseReplicator.GetFromId(child.Id)).is(child)
			expect(child:GetParent()).is(ServerReplicator.None)
			expect(child:IsTopLevel()).is(false)
			child:Destroy()
		end)

		test("children orphaned to None are not treated as top-level replicators", function()
			local parent = newTop("DestroyOrphanNotTopLevel")
			local child = ServerReplicator.new {
				Namespace = uniqueToken("DestroyOrphanNotTopLevelChild"),
				Data = FakeManager.new(),
				Parent = parent,
			}
			parent:Destroy()
			expect(child:IsTopLevel()).is(false)
			expect(child:GetParent()).is(ServerReplicator.None)
			child:Destroy()
		end)

		test("grandchildren ride along to None when their immediate parent is the one destroyed", function()
			local top = newTop("DestroyGrandchildRideAlong")
			local child = ServerReplicator.new {
				Namespace = uniqueToken("DestroyGrandchildRideAlongChild"),
				Data = FakeManager.new(),
				Parent = top,
			}
			local grandchild = ServerReplicator.new {
				Namespace = uniqueToken("DestroyGrandchildRideAlongGrand"),
				Data = FakeManager.new(),
				Parent = child,
			}
			top:Destroy()
			-- child relocated to None; grandchild still under child
			expect(child:GetParent()).is(ServerReplicator.None)
			expect(grandchild:GetParent()).is(child)
			expect(BaseReplicator.GetFromId(grandchild.Id)).is(grandchild)
			grandchild:Destroy()
			child:Destroy()
		end)

		test("ChildAdded fires on None and ChildRemoved fires on parent when a child is orphaned", function()
			local parent = newTop("DestroyOrphanSignals")
			local child = ServerReplicator.new {
				Namespace = uniqueToken("DestroyOrphanSignalsChild"),
				Data = FakeManager.new(),
				Parent = parent,
			}
			local addedToNone: any = nil
			local removedFromParent: any = nil
			ServerReplicator.None.ChildAdded:Connect(function(r)
				addedToNone = r
			end)
			parent.ChildRemoved:Connect(function(r)
				removedFromParent = r
			end)
			parent:Destroy()
			expect(removedFromParent).is(child)
			expect(addedToNone).is(child)
			child:Destroy()
		end)

		test("destroying a child leaves the parent and siblings unaffected", function()
			local parent = newTop("DestroySiblingsUnaffected")
			local childA = ServerReplicator.new {
				Namespace = uniqueToken("DestroySiblingA"),
				Data = FakeManager.new(),
				Parent = parent,
			}
			local childB = ServerReplicator.new {
				Namespace = uniqueToken("DestroySiblingB"),
				Data = FakeManager.new(),
				Parent = parent,
			}
			childA:Destroy()
			expect(BaseReplicator.GetFromId(parent.Id)).is(parent)
			expect(#parent:GetChildren()).is(1)
			expect(parent:GetChildren()[1]).is(childB)
			childB:Destroy()
			parent:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("BaseReplicator.PromiseFromId", function()
		test("resolves immediately for an already-existing id", function()
			local replicator = newTop("PromiseFromIdExisting")
			local promise = BaseReplicator.PromiseFromId(replicator.Id)
			expect(promise:getStatus()).is("Resolved")
			expect(promise:expect()).is(replicator)
			replicator:Destroy()
		end)

		test("resolves once a replicator with that id is created later", function()
			-- Wire-created client replicators carry an explicit id, so the id can
			-- be known (and waited on) before the replicator exists.
			local promise = BaseReplicator.PromiseFromId(60001)
			expect(promise:getStatus()).is("Started")

			;(ClientReplicator :: any)._HandleMessage(
				FlatCodec.BuildMessage { FlatCodec.CreateItem(60001, nil, "PromiseFromIdFuture", {}, {}) }
			)

			expect(promise:getStatus()).is("Resolved")
			expect((promise:expect() :: any).Id).is(60001)

			;(ClientReplicator :: any)._HandleMessage(FlatCodec.BuildMessage { FlatCodec.DestroyItem(60001) })
		end)

		test("does not resolve for a different newly-created replicator", function()
			local promise = BaseReplicator.PromiseFromId(60002)
			local other = newTop("PromiseFromIdOther")
			expect(promise:getStatus()).is("Started")
			promise:cancel()
			other:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("BaseReplicator generalized iteration (__iter)", function()
		test("iterating a base-metatable replicator walks every live replicator in the realm", function()
			-- `__iter` lives on the BaseReplicator table, and metamethod lookup is
			-- raw: it only engages for objects whose DIRECT metatable is
			-- BaseReplicator (subclass instances re-metatable to their subclass).
			local replicator = newTop("IterFindsMe")
			local bare = BaseReplicator.new({
				Id = 60041,
				Manager = FakeManager.new(),
			} :: any)

			local found = false
			for id, r in bare :: any do
				if r == replicator then
					expect(id).is(replicator.Id)
					found = true
				end
			end
			expect(found).is_true()

			bare:Destroy()
			replicator:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("BaseReplicator search-condition validation", function()
		test("GetAll with an unsupported condition type errors", function()
			expect(function()
				BaseReplicator.GetAll(123 :: any)
			end).fails()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("redundant wire SetParent (client-side)", function()
		test("a SetParent item naming the current parent is a no-op", function()
			-- The server guards its own SetParent calls, but a redundant item
			-- arriving over the wire must not double-insert into child lists or
			-- re-fire hierarchy signals.
			(ClientReplicator :: any)._HandleMessage(FlatCodec.BuildMessage {
				FlatCodec.CreateItem(60011, nil, "RedundantSetParentTop", {}, {}),
				FlatCodec.CreateItem(60012, 60011, "RedundantSetParentChild", {}, {}),
			})
			local parent = BaseReplicator.GetFromId(60011) :: any
			local child = BaseReplicator.GetFromId(60012) :: any
			expect(child:GetParent()).is(parent)

			local parentChangedFired = false
			child.ParentChanged:Connect(function()
				parentChangedFired = true
			end)

			;(ClientReplicator :: any)._HandleMessage(
				FlatCodec.BuildMessage { FlatCodec.SetParentItem(60012, 60011) }
			)

			expect(parentChangedFired).is(false)
			expect(child:GetParent()).is(parent)
			expect(#parent:GetChildren()).is(1)

			;(ClientReplicator :: any)._HandleMessage(FlatCodec.BuildMessage { FlatCodec.DestroyItem(60011) })
		end)

		test("a SetParent item can adopt a previously top-level replicator", function()
			-- Both created parentless; the wire then parents A under B, so the
			-- reparent bookkeeping runs with no old parent to detach from.
			(ClientReplicator :: any)._HandleMessage(FlatCodec.BuildMessage {
				FlatCodec.CreateItem(60013, nil, "AdoptTopLevelChild", {}, {}),
				FlatCodec.CreateItem(60014, nil, "AdoptTopLevelParent", {}, {}),
			})
			local child = BaseReplicator.GetFromId(60013) :: any
			local parent = BaseReplicator.GetFromId(60014) :: any
			expect(child:GetParent()).is(nil)

			;(ClientReplicator :: any)._HandleMessage(
				FlatCodec.BuildMessage { FlatCodec.SetParentItem(60013, 60014) }
			)

			expect(child:GetParent()).is(parent)
			expect(parent:GetChildren()[1]).is(child)

			;(ClientReplicator :: any)._HandleMessage(FlatCodec.BuildMessage { FlatCodec.DestroyItem(60014) })
		end)
	end)

	--------------------------------------------------------------------------------

	describe("BaseReplicator._SetParentRefs to nil (detach)", function()
		test("detaching clears both sides and fires ChildRemoved/ParentChanged", function()
			local parent = newTop("DetachParent")
			local child = ServerReplicator.new {
				Namespace = uniqueToken("DetachChild"),
				Data = FakeManager.new(),
				Parent = parent,
			}

			local removed: any = nil
			local parentChanged = false
			parent.ChildRemoved:Connect(function(r)
				removed = r
			end)
			child.ParentChanged:Connect(function()
				parentChanged = true
			end)

			-- The wire never expresses "no parent", so exercise the bookkeeping
			-- seam directly: pure child-list/signal maintenance by contract.
			;(child :: any):_SetParentRefs(nil)

			expect(child:GetParent()).is(nil)
			expect(#parent:GetChildren()).is(0)
			expect(removed).is(child)
			expect(parentChanged).is_true()

			child:Destroy()
			parent:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("BaseReplicator.GetTokenName (deprecated)", function()
		test("returns the namespace name for a named replicator", function()
			local token = uniqueToken("DeprecatedGetTokenName")
			local replicator =
				ServerReplicator.new { Namespace = token, Data = FakeManager.new(), ReplicationTargets = {} }
			expect((replicator :: any):GetTokenName()).is(getTokenName(token))
			replicator:Destroy()
		end)

		test("returns an empty string for an anonymous replicator", function()
			local anonymous = ServerReplicator.new { Data = FakeManager.new(), ReplicationTargets = {} }
			expect((anonymous :: any):GetTokenName()).is("")
			anonymous:Destroy()
		end)
	end)
end

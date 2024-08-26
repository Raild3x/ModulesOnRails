-- Authors: Logan Hunt (Raildex)
-- April 03, 2024
--[=[
    @class TableReplicator.spec
    @ignore

    A test suite for the TableReplicator class.
]=]

--// Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

--// Imports //--
local Import = require(ReplicatedStorage.Orion.Import)
local TableManager = Import("TableManager")
local Signal = Import("Signal")
local Promise = Import("Promise")

local IS_SERVER = RunService:IsServer()

local function traceback(level: number?)
    local str = debug.traceback()

    local startString = "PAUSE"
    local startIdx = string.find(str, startString)
    if not startIdx then
        startString = "traceback"
        startIdx = string.find(str, startString)
    end
    startIdx += #startString + 1

    local endString = "ReplicatedStorage.Orion.node_modules.@supersocial.testez"
    local endIdx = string.find(str, endString) - 2

    return string.sub(str, startIdx, endIdx)
end

local sig = Signal.new()
local function PAUSE(maximumDelay: number?)
    return Promise.fromEvent(sig):timeout(maximumDelay or 6, "[PAUSE Timed-Out] | "..traceback()):catch(warn):expect()
end

local function RESUME(...)
    sig:Fire(...)
end

return function ()
    if not RunService:IsRunning() then return warn("TableReplicator.spec must be run in an active game") end
    local TableReplicator = Import("TableReplicator")
    local NetWire = Import("NetWire")

    local TEST_COUNT = 0
    local TOKEN_NAME = "Test"
    local TOKEN
    local LISTENER_CONN

    local wire
    if IS_SERVER then
        wire = NetWire.Server("TableReplicator.spec")
        wire.TestComplete = NetWire.createEvent()
    else
        wire = NetWire.Client("TableReplicator.spec")
    end

    local passed = nil
    local tm, tr
    beforeEach(function()
        passed = nil
        TEST_COUNT += 1
        TOKEN_NAME = "Test_"..TEST_COUNT
        print("Running Test", TEST_COUNT)
        if IS_SERVER then
            TOKEN = TableReplicator.newClassToken(TOKEN_NAME)
            tm = TableManager.new({})
            tr = TableReplicator.new({
                ClassToken = TOKEN,
                TableManager = tm,
				Tags = {Test = 60},
                ReplicationTargets = "All",
            })
        else
            TableReplicator.promiseFirstReplicator(TOKEN_NAME, true):andThen(function(replicator, manager)
                tr = replicator
                tm = manager
            end):timeout(10, `Failed to get replicator<{TOKEN_NAME}> in time!`):catch(warn):expect()
        end
    end)

    afterEach(function()
        if IS_SERVER then
            local tr_ref = tr
            local tm_ref = tm
            local tokenName_ref = TOKEN_NAME
            Promise.fromEvent(wire.TestComplete, function(_, tokenName)
                return tokenName == tokenName_ref
            end):andThen(function()
                print(" Destroying replicator...", tokenName_ref)
                tr_ref:Destroy()
                tm_ref:Destroy()
            end)
        else
            wire.TestComplete:Fire(TOKEN_NAME)
            print("Marking Test Complete...", TOKEN_NAME)
        end
        tm = nil
        tr = nil
    end)

    --------------------------------------------------------------------------------
        --// Test Cases //--
    --------------------------------------------------------------------------------

    describe("Iteration", function()
        it("using the iter metamethod should properly iterate all existing replicators", function()
            for _, replicator in TableReplicator do
                expect(replicator).to.be.ok()
                passed = true
            end
            expect(passed).to.be.ok()
        end)
    end)

    describe("Constructor", function()
        it("should create a new TableReplicator", function()
            if IS_SERVER then
                expect(tr).to.be.ok()
                tm:Set("Egg", 1)
            else
                expect(tr).to.be.ok()
                task.wait()
                expect(tm:Get("Egg")).to.equal(1)
            end
        end)

        it("should allow a string classtoken, but warn about it", function()
            
        end)
    end)

    describe("TableManager Replication", function()

        it("Should be replicating to ALL active clients", function()
            if not IS_SERVER then return end -- Server only test
            expect(tr:IsReplicatingToAll()).to.equal(true)

            if #tr:GetActiveReplicationTargets() == 0 then
                tr.AddedActivePlayer:Once(function()
                    RESUME()
                end)
                PAUSE()
            end

            expect(#tr:GetActiveReplicationTargets() > 0).to.equal(true)
        end)

        it("Should stop replicating to ALL clients", function()
            if not IS_SERVER then return end
            
            if #tr:GetActiveReplicationTargets() == 0 then
                tr.AddedActivePlayer:Once(function()
                    RESUME()
                end)
                PAUSE()
            end

            tr:DestroyFor("All")

            expect(#tr:GetActiveReplicationTargets() <= 0).to.equal(true)
        end)

        it("should listen for changes", function()
            if IS_SERVER then
                expect(tr).to.be.ok()
                tm:Set("Egg", {
                    Age = 0,
                })
                task.wait(2)
                tm:Set("Egg", {
                    Age = 1,
                })
                --print("SERVER EGG ", tr, tm)
            else
                expect(tr).to.be.ok()
                expect(tm).to.be.ok()
                if tm:Get("Egg.Age") == 1 then
                    passed = true
                    warn("Test case succeeded too early")
                end
                tm:ListenToValueChange("Egg", function(v)
                    expect(v.Age).to.equal(1)
                    passed = true
                    RESUME()
                end)
                --print("CLIENT EGG ", tr, tm)
                PAUSE()
                expect(passed).to.be.ok()
            end
        end)

		it("Should listen for nested changes", function()
			if IS_SERVER then
				tm:Set("YourMom",{
					IsHot = true,
				})
				task.wait(2)
				tm:Set("YourMom.IsHot", false)
			else
				if tm:Get("YourMom.IsHot") == false then
                    passed = true
                    warn("Test case succeeded too early")
                end
				tm:ListenToValueChange("YourMom", function(description)
                    passed = description.IsHot == false
                    RESUME()
                end)
				PAUSE()
				expect(passed).to.be.ok()
			end
		end)
    end)

	describe("IsTopLevel", function()
        local newToken = IS_SERVER and TableReplicator.newClassToken("TopLevelTest")

		it("Should be top level", function()
			expect(tr:IsTopLevel()).to.equal(true)
		end)
		
		it("Shouldn't be top level", function()
			if IS_SERVER then
				local child = TableReplicator.new({
					ClassToken = newToken,
					TableManager = TableManager.new({}),
					Parent = tr
				})

				expect(not child:IsTopLevel()).to.equal(true)
			else
				local success, child = tr:PromiseFirstChild("TopLevelTest"):timeout(10, "Failed to get child replicator in time!"):await()
				expect(success and child and true).to.equal(true)
				expect(not child:IsTopLevel()).to.equal(true)
			end
		end)
	end)

	describe("Children", function()
		local newToken = if IS_SERVER then TableReplicator.newClassToken("ChildTest") else "ChildTest"
        
		it("Should have a child added already", function()
			if IS_SERVER then
				local child = TableReplicator.new({
					ClassToken = newToken,
					TableManager = TableManager.new({}),
					Parent = tr,
				})
                expect(child:GetParent()).to.equal(tr)
                expect(#tr:GetChildren() > 0).to.equal(true)
			else
                task.wait(1)
				print(TableReplicator.getAll(newToken), #TableReplicator.getAll(newToken) > 0)
				expect(#TableReplicator.getAll(newToken) > 0).to.equal(true)
				expect(#tr:GetChildren() > 0).to.equal(true)
			end
		end)

		it("Should detect child added", function()
			if IS_SERVER then
				local childTR = TableReplicator.new({
					ClassToken = newToken,
					TableManager = TableManager.new({}),
					Parent = TableReplicator.None,
				})
				task.wait(2)
				childTR:SetParent(tr)
			else
				if #tr:GetChildren() > 0 then
					passed = true
					warn("Test case succeeded too early")
				end
				tr:GetSignal("ChildAdded"):Connect(function(childReplicator)
					passed = childReplicator ~= nil
					RESUME()
				end)

				PAUSE()
				expect(passed).to.be.ok()
			end
		end)

        it("Should find first child of Class", function()
            if IS_SERVER then
                local childTR = TableReplicator.new({
					ClassToken = newToken,
					TableManager = TableManager.new({}),
					Parent = TableReplicator.None,
				})
				task.wait(2)
				childTR:SetParent(tr)
                expect(tr:FindFirstChild(newToken)).to.be.ok()
                local result = tr:PromiseFirstChild(newToken):timeout(10, "Failed to get child replicator of class in time!"):catch(warn):await()
                expect(result).to.equal(true)
            else
                expect(tr:FindFirstChild(newToken)).to.be.ok()
                local result = tr:PromiseFirstChild(newToken):timeout(10, "Failed to get child replicator of class in time!"):catch(warn):await()
                expect(result).to.equal(true)
            end
        end)

        it("Should find first child with tags", function()
            local testTags = {["Test"] = 420}
            if IS_SERVER then
                local childTR = TableReplicator.new({
					ClassToken = newToken,
					TableManager = TableManager.new({}),
                    Tags = testTags,
					Parent = TableReplicator.None,
				})
				task.wait(2)
				childTR:SetParent(tr)
                expect(tr:FindFirstChild(testTags)).to.be.ok()
                local result = tr:PromiseFirstChild(testTags):timeout(10, "Failed to get child replicator with tags in time!"):catch(warn):await()
                expect(result).to.equal(true)
            else
                expect(tr:FindFirstChild(testTags)).to.be.ok()
                local result = tr:PromiseFirstChild(testTags):timeout(10, "Failed to get child replicator with tags in time!"):catch(warn):await()
                expect(result).to.equal(true)
            end
        end)

        it("Should find first child of class with tags", function()
            local testTags = {["Test"] = 420}

            local function compareChild(childReplicator)
                return childReplicator:GetTokenName() == "ChildTest" and childReplicator:ContainsAllTags(testTags)
            end

            if IS_SERVER then
                local childTR = TableReplicator.new({
					ClassToken = newToken,
					TableManager = TableManager.new({}),
                    Tags = testTags,
					Parent = TableReplicator.None,
				})
				task.wait(2)
				childTR:SetParent(tr)
                expect(tr:FindFirstChild(compareChild)).to.be.ok()
                local result = tr:PromiseFirstChild(compareChild):timeout(10, "Failed to get child replicator of class with tags in time!"):catch(warn):expect()
                expect(result).to.be.ok()
            else
                expect(tr:FindFirstChild(compareChild)).to.be.ok()
                local result = tr:PromiseFirstChild(compareChild):timeout(10, "Failed to get child replicator of class with tags in time!"):catch(warn):expect()
                expect(result).to.be.ok()
            end
        end)
	end)

	describe("Tags", function()
		it(`Should have the "Test" tag`, function()
			expect(tr:GetTag("Test")).to.equal(60)
            expect(tr:GetTags()["Test"]).to.equal(60)
		end)

		it("Should be a subset/superset of tags", function()
			expect(tr:ContainsAllTags({Test = 60})).to.equal(true)
			expect(tr:IsSubsetOfTags({Test = 60, Test2 = 25})).to.equal(true)
		end)

		it("Should not be a subset/superset of tags", function()
			expect(not tr:ContainsAllTags({Test = 60, Test2 = 25})).to.equal(true)
			expect(not tr:IsSubsetOfTags({Test2 = 25})).to.equal(true)
		end)
	end)

    describe("Network Inheritance", function()
            
    end)


    --// Writen by Jacob Carey on 4/4/24 <3
    --// I had to prove to kaden that im better by writing more unit tests than he did :3
    --// Dont snitch to tati she hates me >_<
    describe("Destroy", function()
        it("should destroy the replicator", function()
            if IS_SERVER then
                task.wait(1)
                tr:Destroy()
                task.wait(1)
                expect(tr.IsDestroyed).to.equal(true)
            else
                if not tr then return warn("Replicator not found!") end
                tr:GetDestroyedSignal():Connect(function()
                    passed = true
                    RESUME()
                end)
                if not tr.IsDestroyed then
                    PAUSE()
                else
                    passed = true
                end
                expect(passed).to.be.ok()
            end
        end)
    end)


    describe("Remote Functions/Signals", function()

        FOCUS()
        
        it("Should handle remote functions", function()
            if IS_SERVER then
                local TR_Client = {}

                function TR_Client:TestFunction(player: Player, name: string)
                    local manager = self:GetTableManager()
                    return "Hello "..name.."!"
                end

                local ntr = TableReplicator.new({
                    ClassToken = "Test",
                    TableManager = TableManager.new({}),
                    ReplicationTargets = "All",
                    Client = TR_Client,
                })

                
                local ntr2 = TableReplicator.new({
                    ClassToken = "Test",
                    TableManager = TableManager.new({}),
                    ReplicationTargets = "All",
                    Client = TR_Client,
                })

            else
                tr.Server:TestFunction("Logan"):andThen(function(result)
                    passed = result == "Hello Logan!"
                    RESUME()
                end)
                PAUSE()
                expect(passed).to.be.ok()
            end
        end)

        it("Should handle remote signals", function()
            if IS_SERVER then
                local TR_Client = {
                    TestSignal = NetWire.createEvent()
                }

                local ntr = TableReplicator.new({
                    ClassToken = "Test",
                    TableManager = TableManager.new({}),
                    ReplicationTargets = "All",
                    Client = TR_Client,
                })

                ntr.Client.TestSignal:Connect(function()
                    passed = true
                    RESUME()
                end)

                -- this should warn that it wasnt declared in the initial client table, but still make it?
                ntr.Client.TestSignal2:Connect()
                ntr.Client.TestSignal3 = NetWire.createEvent()

                
                ntr.Server.TestSignal:FireAll()
            else

                local testSignal = tr.Server.TestSignal
                testSignal:Connect(function()
                    passed = true
                    RESUME()
                end)

                testSignal:Fire()

                PAUSE()
                expect(passed).to.be.ok()
            end
            -- if IS_SERVER then
            --     tr:RegisterRemoteSignal("TestSignal")

            --     local remoteSignal = tr:GetRemoteSignal("TestSignal")
            --     expect(remoteSignal).to.be.ok()

            --     remoteSignal:Connect(function()
            --         passed = true
            --         RESUME()
            --     end)

            --     task.wait(1)
            --     remoteSignal:FireAll()

            --     PAUSE()
            --     expect(passed).to.be.ok()
            -- else
                
            --     local remoteSignal = tr:GetRemoteSignal("TestSignal")
            --     expect(remoteSignal).to.be.ok()
            --     remoteSignal:Connect(function()
            --         passed = true
            --         remoteSignal:Fire()
            --         RESUME()
            --     end)

            --     PAUSE()
            --     expect(passed).to.be.ok()
            -- end
        end)
    end)

    --------------------------------------------------------------------------------
        --// Data Request //--
    --------------------------------------------------------------------------------
    task.defer(function()
        if not IS_SERVER then
            print("[Requesting server data...")
            TableReplicator.requestServerData():andThen(function()
                print("...Server data received]")
            end)
        end
    end)
end
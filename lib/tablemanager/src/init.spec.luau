-- Authors: Logan Hunt (Raildex), Kaden Fennema
-- March 29, 2024
--[=[
    @class TableManager.spec
    @ignore

    This is a test suite for the TableManager class.
]=]

--// Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

--// Imports //--
local Packages = script.Parent.Parent

local ROOT_TABLE_PATH = {}

local function ArraysMatch(arr1, arr2): boolean
    for i, v in ipairs(arr1) do
        if v ~= arr2[i] then
            return false
        end
    end
    return true
end

--------------------------------------------------------------------------------
    --// Tester //--
--------------------------------------------------------------------------------

return function ()
    -- if RunService:IsRunning() then
    --     warn("TableManager.spec is disabled while game is running")
    --     return
    -- end

    local Janitor = require(Packages.Janitor)
    local TableManager = require(script.Parent)

    local tm: TableManager.TableManager
    local KEY = "KEY"
    local VALUE = "TEST_STRING"
    local passed: boolean?

    local KEY1 = "KEY1"
    local KEY2 = "KEY2"
    local KEY3 = "KEY3"
    local PATH1 = {KEY1, KEY2, KEY3}
    local PATH2 = {KEY1, KEY2}

    local function MarkAsPassed()
        passed = true
    end

    beforeEach(function()
        tm = TableManager.new()
        KEY = "KEY"
        passed = nil
    end)

    afterEach(function()
        tm:Destroy()
    end)

    describe("Constructor", function()

        it("should properly create a new TableManager", function()
            expect(tm).to.be.ok()
            expect(tm).to.be.a("table")
            expect(tm:IsA(TableManager)).to.equal(true)

            expect(function()
                TableManager.new("Hello")
            end).to.throw()
        end)

        it("should be equivalent to calling the TableManager class", function()
            tm:Destroy()
            tm = TableManager {
                Value = 5
            }
            expect(tm).to.be.ok()
            expect(tm).to.be.a("table")
            expect(tm:IsA(TableManager)).to.equal(true)
        end)

        it("should return the same TableManager if given the same table", function()
            local tbl = {}
            expect(TableManager.new(tbl)).to.equal(TableManager.new(tbl))
        end)
    end)

    describe("Signals", function()
        
    end)

    describe("Set/Get", function()
        beforeEach(function()
            tm:SetValue(KEY, VALUE)
        end)

        it(`should return the value set to {KEY}`, function()
            expect(tm:Get(KEY)).to.equal(VALUE)
            expect(tm:Get({KEY})).to.equal(VALUE)
        end)

        it("should fetch nested values properly", function()
            tm:SetValue(KEY, {
                NESTED = VALUE
            })
            KEY = "KEY.NESTED"
            expect(tm:Get(KEY)).to.equal(VALUE)
            expect(tm:Get(string.split(KEY, "."))).to.equal(VALUE)
        end)

        it("should return the value for [Instance]", function()
            KEY = Instance.new("Part")
            tm:SetValue(KEY, VALUE)
            expect(tm:Get(KEY)).to.equal(VALUE)
            expect(tm:Get({KEY})).to.equal(VALUE)
        end)

        it("should work as an alias for Array Get/Set", function()
            tm:Set(KEY, {"A", "B", "C"})
            expect(tm:Get(KEY, 1)).to.equal("A")
            expect(tm:Get(KEY, 2)).to.equal("B")
            
            tm:Set(KEY, 2, "D")
            expect(tm:Get(KEY, 2)).to.equal("D")
            
            tm:Set({KEY, 3}, "Z")
            expect(tm:Get({KEY, 3})).to.equal("Z")
        end)
    end)

    describe("Increment", function()
        local defaultVal = 0
        beforeEach(function()
            tm:SetValue(KEY, defaultVal)
        end)

        it("Should increment the value set to KEY", function()
            local number = tm:Increment(KEY, 50)
            expect(tm:Get(KEY)).to.equal(number)
            expect(number).to.equal(50)

            number = tm:Increment(KEY, -100)
            expect(tm:Get(KEY)).to.equal(number)
            expect(number).to.equal(-50)
        end)

        it("Should increment the values in an array", function()
            tm:SetValue(KEY, {4, 5, 6})
            tm:Increment(KEY, 1, 10)
            tm:Increment(KEY, {2, 3}, 20)
            expect(tm:Get(KEY, 1)).to.equal(14)
            expect(tm:Get(KEY, 2)).to.equal(25)
            expect(tm:Get(KEY, 3)).to.equal(26)
        end)

        it("Should increment every value in the array", function()
            tm:SetValue(KEY, {4, 5, 6})

            tm:Increment(KEY, '#', 10)
            expect(tm:Get(KEY, 1)).to.equal(14)
            expect(tm:Get(KEY, 2)).to.equal(15)
            expect(tm:Get(KEY, 3)).to.equal(16)
        end)
    end)

    describe("Mutate", function()
        beforeEach(function()
            tm:SetValue(KEY, 0)
        end)

        it("Should mutate the data at KEY", function()
            local number = tm:Mutate(KEY, function(currentValue)
                return currentValue+1
            end)

            expect(tm:Get(KEY)).to.equal(number)
            expect(tm:Get({KEY})).to.equal(number)
        end)

        it("Should mutate the values in an array", function()
            tm:SetValue(KEY, {4, 5, 6})
            tm:Mutate(KEY, {2,3}, function(currentValue)
                return currentValue*2
            end)

            expect(tm:Get(KEY, 1)).to.equal(4)
            expect(tm:Get(KEY, 2)).to.equal(10)
            expect(tm:Get(KEY, 3)).to.equal(12)
        end)
    end)

    describe("ArrayInsert", function()
        beforeEach(function()
            tm:SetValue(KEY, {"A", "B", "C"})
        end)

        it("Should insert the value at the specified index and shift", function()
            tm:ArrayInsert(KEY, 2, "D")
            expect(tm:Get(KEY, 2)).to.equal("D")
            expect(tm:Get(KEY, 3)).to.equal("B")
        end)

        it("Should insert to the end of the array if an index is not given", function()
            tm:ArrayInsert(KEY, "D")
            expect(tm:Get(KEY, 4)).to.equal("D")
        end)
    end)

    describe("ArrayRemove", function()
        beforeEach(function()
            tm:SetValue(KEY, {"A", "B", "C", "D"})
        end)

        it("Should remove the value at the specified index and shift down values", function()
            local removedValue = tm:ArrayRemove(KEY, 3)
            expect(removedValue).to.equal("C")
            expect(tm:Get(KEY, 3)).to.equal("D")
            expect(tm:Get(KEY, 2)).to.equal("B")
        end)

        it("Should remove the last value if no index is specified", function()
            local removedValue = tm:ArrayRemove(KEY)
            expect(removedValue).to.equal("D")
            expect(tm:Get(KEY, 3)).to.equal("C")
            expect(tm:Get(KEY, 4)).to.equal(nil)
        end)
    end)

    describe("ArrayRemoveFirstValue", function()
        beforeEach(function()
            tm:SetValue(KEY, {"D", "A", "B", "A", "C"})
        end)
        
        it("Should remove the first value and shift down values", function()
            local removedIdx = tm:ArrayRemoveFirstValue(KEY, "A")
            expect(removedIdx).to.be.ok()
            expect(tm:Get(KEY, 1)).to.equal("D")
            expect(tm:Get(KEY, 2)).to.equal("B")
            expect(tm:Get(KEY, 3)).to.equal("A")
            local removedIdx2 = tm:ArrayRemoveFirstValue(KEY, "A")
            expect(removedIdx2).to.be.ok()
            expect(tm:Get(KEY, 1)).to.equal("D")
            expect(tm:Get(KEY, 2)).to.equal("B")
            expect(tm:Get(KEY, 3)).to.equal("C")
            local removedIdx3 = tm:ArrayRemoveFirstValue(KEY, "A")
            expect(removedIdx3).to.equal(nil)
        end)
    end)

    describe("ToTableState", function()
        beforeEach(function()
            tm:SetValue(KEY, 100)
        end)
        it("Should create a TableState and perform the methods as intended", function()
            local testPath = KEY
            local tableState = tm:ToTableState(testPath)
            tableState:Increment(20)
            expect(tm:Get(KEY)).to.equal(120)
            tableState:Increment(10)
            expect(tm:Get(KEY)).to.equal(130)
            tableState:Set(200)
            expect(tm:Get(KEY)).to.equal(200)
        end)
    end)

    describe("Observe", function()
        beforeEach(function()
            tm:SetValue(KEY, 0)
        end)

        it("Should fire when the value changes", function()
            expect(passed).to.never.be.ok()
            tm:Observe(KEY, function(newValue, oldValue)
                passed = newValue == 5 and oldValue == 0
            end)

            tm:Set(KEY, 5)
            task.wait()
            expect(passed).to.be.ok()
        end)

        it("Should fire when the value changes due to a parent table changing", function()
            tm:SetValue(KEY, {
                Child = {
                    Value = 0,
                },
            })

            expect(passed).to.never.be.ok()
            tm:Observe(`{KEY}.Child.Value`, function(newValue, oldValue)
                passed = newValue == 5 and oldValue == 0
            end)

            tm:Set(`{KEY}.Child`, {
                Value = 5,
            })
            task.wait()
            expect(passed).to.be.ok()
        end)
        
        it("Should fire when a child value changes", function()
            tm:SetValue(KEY, {
                Child = {
                    Value = 0,
                },
            })

            expect(passed).to.never.be.ok()
            tm:Observe(`{KEY}.Child`, function(newValue, oldValue)
                passed = newValue.Value == 5 and oldValue.Value == 0
            end)

            tm:Set(`{KEY}.Child.Value`, 5)
            task.wait()
            expect(passed).to.be.ok()
        end)

        it("Should not fire if the value is nil or set to nil", function()
            passed = true
            tm:Set(KEY, nil)
            tm:Observe(KEY, function(newValue, _)
                if newValue then return end
                passed = false
            end)
            
            tm:Set(KEY, 5)
            task.wait()
            expect(passed).to.be.ok()
            tm:Set(KEY, nil)
            task.wait()
            expect(passed).to.be.ok()
        end)

        it("Should fire if the value is nil or set to nil when the flag is true", function()
            passed = false
            tm:Set(KEY, nil)
            tm:Observe(KEY, function(newValue, _)
                if newValue ~= nil then return end
                passed = true
            end, true)

            expect(passed).to.be.ok()
            passed = false
            tm:Set(KEY, 5)
            tm:Set(KEY, nil)
            task.wait()
            expect(passed).to.be.ok()
        end)

        it("Should recieve the last known non nil value for the oldValue", function()
            tm:Observe(KEY, function(newValue, oldValue)
                passed = newValue == 10 and oldValue == 5
            end)

            tm:Set(KEY, 5)
            tm:Set(KEY, nil)
            tm:Set(KEY, 10)
            task.wait()
            expect(passed).to.be.ok()
        end)
    end)

    describe("SetManyValues", function()
        beforeEach(function()
            tm:SetValue(KEY, {
                Logan = 1,
                Kaden = -1,
                Marcus = 9_000
            })
        end)

        it("Should setup multiple values in a dict", function()
            tm:SetManyValues(KEY, {
                Logan = 10,
                Kaden = 2
            })

            expect(ArraysMatch(tm:Get(KEY), {
                Logan = 10,
                Kaden = 2,
                Marcus = 9_000
            })).to.be.ok()

            tm:SetManyValues(KEY, {
                Kaden = -50,
                Marcus = 1_000
            })
            expect(ArraysMatch(tm:Get(KEY), {
                Logan = 10,
                Kaden = -50,
                Marcus = 1_000
            })).to.be.ok()
        end)
    end)

    describe("ListenToArraySet", function()
        beforeEach(function()
            tm:SetValue(KEY, {"A", "B", "C"})
        end)

        it("Should fire when a value is set in the array", function()
            tm:ListenToArraySet(KEY, function(index, newValue, oldValue)
                passed = index == 2 and newValue == "D" and oldValue == "B"
            end)

            expect(passed).to.equal(nil)
            tm:ArraySet(KEY, 2, "D")
            task.wait()
            expect(passed).to.be.ok()
        end)
    end)
    
    describe("ListenToArrayInsert", function()
        beforeEach(function()
            tm:SetValue(KEY, {"A", "B", "C"})
        end)

        it("Should fire when a value is inserted into the array", function()
            tm:ListenToArrayInsert(KEY, function(index, value)
                passed = index == 2 and value == "D"
            end)

            expect(passed).to.equal(nil)
            tm:ArrayInsert(KEY, 2, "D")
            task.wait()
            expect(passed).to.be.ok()
        end)
    end)

    describe("ListenToArrayRemove", function()
        beforeEach(function()
            tm:SetValue(KEY, {"A", "B", "C"})
        end)

        it("Should fire when a value is removed from the array", function()
            tm:ListenToArrayRemove(KEY, function(index, value)
                passed = index == 2 and value == "B"
            end)

            expect(passed).to.equal(nil)
            tm:ArrayRemove(KEY, 2)
            task.wait()
            expect(passed).to.be.ok()
        end)
    end)

    describe("ListenToValueChange", function()

        beforeEach(function()
            tm:SetValue(KEY1, {
                [KEY2] = {
                    [KEY3] = 0
                }
            })
        end)

        it("Should fire when the value changes", function()
            tm:ListenToValueChange(PATH1, function(newValue, oldValue)
                passed = newValue
            end)

            expect(passed).to.equal(nil)
            tm:SetValue(PATH1, 10)
            task.wait()
            expect(passed).to.equal(10)
            tm:Increment(PATH1, 5)
            task.wait()
            expect(passed).to.equal(15)
        end)

        it("Should fire the parent table listeners when the value changes", function()
            tm:ListenToValueChange(PATH2, function(newValue, oldValue)
                passed = true
            end)

            expect(passed).to.equal(nil)
            tm:SetValue(PATH1, 5)
            task.wait()
            expect(passed).to.be.ok()
        end)

        it("Should fire the when the value changes due to a parent table changing", function()
            tm:ListenToValueChange({KEY1, KEY2, KEY3}, function(newValue, oldValue)
                passed = true
            end)

            expect(passed).to.equal(nil)
            tm:SetValue({KEY1, KEY2}, {
                [KEY3] = 5,
                Test = 20,
            })
            task.wait()
            expect(passed).to.be.ok()
        end)
    end)

    describe("PromiseValue", function()
        
        it("should resolve when the value meets the criterion", function()
            tm:SetValue(KEY, 5)

            passed = false
            tm:PromiseValue(KEY, function(value)
                return value == 5
            end):now():andThen(function(value)
                passed = value == 5
            end)
            expect(passed).to.be.ok()


            passed = nil
            tm:PromiseValue(KEY, function(value)
                return value == 10
            end):andThen(function(value)
                passed = value == 10
            end)

            expect(passed).to.equal(nil)
            tm:SetValue(KEY, 15)
            task.wait()
            expect(passed).to.equal(nil)
            tm:SetValue(KEY, 10)
            task.wait()
            expect(passed).to.be.ok()
        end)

        it("should resolve when the value exists", function()
            tm:PromiseValue(KEY):andThen(MarkAsPassed)
    
            expect(passed).to.equal(nil)
            tm:SetValue(KEY, 5)
            task.wait()
            expect(passed).to.be.ok()
        end)
    
        it("should cancel when the tableManager is destroyed", function()
            tm:PromiseValue(KEY):finally(MarkAsPassed)
    
            expect(passed).to.equal(nil)
            tm:Destroy()
            task.wait()
            expect(passed).to.be.ok()
        end)
    end)




    describe("ListenToKeyChange", function()

        it("should fire when the key changes", function()
            tm:ListenToKeyChange(ROOT_TABLE_PATH, function(keyChanged: string, newValue: any, oldValue: any)
                passed = keyChanged == KEY and newValue == 5 and oldValue == nil
            end)

            expect(passed).to.equal(nil)
            tm:SetValue(KEY, 5)
            task.wait()
            expect(passed).to.be.ok()
        end)

        it("should fire when a nested table of a key changes", function()
            tm:SetValue(KEY, {
                Value = 10
            })

            tm:ListenToKeyChange(ROOT_TABLE_PATH, function(keyChanged: string, newValue: any, oldValue: any)
                MarkAsPassed()
            end)

            tm:SetValue(KEY .. ".Value", 5)
            task.wait()
            expect(passed).to.be.ok()
        end)

        it("Should fire when an array key is set", function()
            tm:Set(KEY, {
                Array = {5, 10, 15}
            })
            tm:ListenToKeyChange(ROOT_TABLE_PATH, function(keyChanged: string, newValue: any, oldValue: any)
                MarkAsPassed()
            end)

            expect(passed).to.never.be.ok()
            tm:Set(`{KEY}.Array`, {1,2}, 40)
            task.wait()
            expect(passed).to.be.ok()
        end)

        it("Should fire when an array value is inserted", function()
            tm:Set(KEY, {
                Array = {5, 10, 15}
            })
            tm:ListenToKeyChange(ROOT_TABLE_PATH, function(keyChanged: string, newValue: any, oldValue: any)
                MarkAsPassed()
            end)

            expect(passed).to.never.be.ok()
            tm:ArrayInsert(`{KEY}.Array`, 69)
            task.wait()
            expect(passed).to.be.ok()
        end)

        it("Should fire when an array value is removed", function()
            tm:Set(KEY, {
                Array = {5, 10, 15}
            })
            tm:ListenToKeyChange(ROOT_TABLE_PATH, function(keyChanged: string, newValue: any, oldValue: any)
                MarkAsPassed()
            end)

            expect(passed).to.never.be.ok()
            tm:ArraySet(`{KEY}.Array`, {1,3}, nil)
            task.wait()
            expect(passed).to.be.ok()
        end)
    end)

    describe("ListenToNewKey", function()
        it("should fire only when a new key is added", function()
            tm:ListenToNewKey(ROOT_TABLE_PATH, function(newKey: string, newValue: any)
                passed = newKey == KEY and newValue == 5
            end)

            expect(passed).to.equal(nil)
            tm:SetValue(KEY, 5)
            task.wait()
            expect(passed).to.be.ok()
            tm:SetValue(KEY, 10)
            task.wait()
            expect(passed).to.be.ok()
        end)

        it("Should fire when a child value changes", function()
            tm:Set(KEY, {
                Child = {},
            })

            local listenerKey = `{KEY}.Child`
            tm:ListenToNewKey(listenerKey, function(newKey: string, newValue: any)
                passed = newKey == listenerKey and newValue.Value == 5
            end)

            expect(passed).to.never.be.ok()
            tm:Set(`{KEY}.Child.Value`, 5)
            task.wait()
            expect(passed).to.be.ok()
        end)

        it("Should fire when the parent table changes it's value", function()
            tm:Set(KEY, {
                Child = {},
            })

            local listenerKey = `{KEY}.Child`
            tm:ListenToNewKey(listenerKey, function(newKey: string, newValue: any)
                passed = newKey == listenerKey and newValue.Value == 5
            end)

            expect(passed).to.never.be.ok()
            tm:Set(listenerKey, {
                Value = 5
            })
            task.wait()
            expect(passed).to.be.ok()
        end)
    end)

    describe("ListenToRemoveKey", function()
        
        it("Should fire only when a key is removed", function()
            tm:SetValue(KEY, 5)

            local connection = tm:ListenToRemoveKey(ROOT_TABLE_PATH, function(removedKey: string, lastValue: any)
                passed = removedKey == KEY and lastValue == 5
            end)

            expect(passed).to.equal(nil)
            tm:SetValue(KEY, nil)
            task.wait()
            expect(passed).to.be.ok()
            tm:SetValue(KEY, 5)
            task.wait()
            expect(passed).to.be.ok()

            -- test disconnection
            passed = nil
            connection:Disconnect()
            tm:SetValue(KEY, nil)
            task.wait()
            expect(passed).to.equal(nil)
        end)

        it("Should fire when a key is unset from a parent table change", function()
            tm:Set(KEY1, {
                [KEY2] = {
                    [KEY3] = 5
                }
            })

            tm:ListenToRemoveKey({KEY1, KEY2}, function(removedKey: string, lastValue: any)
                passed = removedKey == KEY3 and lastValue == 5
            end)

            expect(passed).to.equal(nil)
            tm:SetValue({KEY1}, 10)
            task.wait()
            expect(passed).to.be.ok()
        end)
    end)

    ------------------------------------------------------------------------------------------------

    describe("ToFusionState", function()
        local Fusion = require(Packages.Fusion)
        local peek = Fusion.peek

        local scope = Fusion.scoped({Fusion})

        beforeEach(function()
            tm:SetValue(KEY, 0)
        end)

        afterAll(function()
            Fusion.doCleanup(scope)
        end)

        it("Should return the same fusion state for path", function()
            local state1, state2 = tm:ToFusionState(KEY), tm:ToFusionState({KEY})
            expect(state1).to.equal(state2)
            expect(peek(state1)).to.equal(peek(state2))
        end)

        it("Should contain the proper value of the key after it has been changed", function()
            local state = tm:ToFusionState(KEY)
            task.wait()
            expect(peek(state)).to.equal(0)

            tm:SetValue(KEY, 50)
            task.wait()
            expect(peek(state)).to.equal(50)

            tm:Increment(KEY, 100)
            task.wait()
            expect(peek(state)).to.equal(150)
        end)

        it("Should contain the proper value of the key after it has been changed in a nested table", function()
            tm:SetValue(KEY, {
                Nested = 0
            })

            local NestedKey = KEY .. ".Nested"

            local state = tm:ToFusionState(NestedKey)
            task.wait()
            expect(peek(state)).to.equal(0)

            tm:SetValue(NestedKey, 50)
            task.wait()
            expect(peek(state)).to.equal(50)

            tm:SetValue(KEY, {
                Nested = 100
            })
            task.wait()
            expect(peek(state)).to.equal(100)

            tm:Increment(NestedKey, 100)
            task.wait()
            expect(peek(state)).to.equal(200)
        end)

        it("Should change when an array change is made", function()
            tm:SetValue(KEY, {1, 2, 3})

            local state = tm:ToFusionState(KEY)

            Fusion.Observer(scope, state):onChange(function()
                passed = true
            end)

            tm:ArraySet(KEY, 2, 10)
            
            task.wait()
            expect(peek(state)[2]).to.equal(10)
            expect(passed).to.be.ok()

            passed = nil
            tm:ArrayInsert(KEY, 2, 20)
            task.wait()
            expect(peek(state)[2]).to.equal(20)
            expect(peek(state)[3]).to.equal(10)
            expect(peek(state)).to.equal(tm:Get(KEY))
            expect(passed).to.be.ok()
        end)

        -- it("Should set the value in TM if we set the value from the state", function()
            
        -- end)
        
    end)
    

end

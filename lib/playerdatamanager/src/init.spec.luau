

return function()

    local PlayerDataManager = require(script.Parent)

    describe("PlayerDataManager", function()

        it("should be a table", function()
            expect(PlayerDataManager).to.be.a("table")
        end)

        it("should return the same table if new is called multiple times", function()
            local pdm1 = PlayerDataManager.new()
            local pdm2 = PlayerDataManager.new()
            expect(pdm1).to.equal(pdm2)
        end)

    end)

end

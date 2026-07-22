-- Authors: Logan Hunt (Raildex)
-- July 17, 2024
-- THIS FILE IS OUTDATED AND NO LONGER MAINTAINED. TESTS MAY NOT WORK AS INTENDED.

type table = {[any]: any}


return function ()
    local Roam = require(script.Parent) ---@module Roam
    Roam.Debug = true

    local ServiceCount = 0
    local function MakeTestService(config: table?)
        config = config or {}
        assert(config, "Config is nil")
        ServiceCount += 1
        config.Name = config.Name or `Service{ServiceCount}`

        local service = Roam.createService(config)
        service.DidInit = false
        service.DidStart = false

        service.RoamInit = function()
            service.DidInit = true
        end

        service.RoamStart = function()
            service.DidStart = true
        end

        return service
    end

    describe(".createService", function()
        it("should create a service", function()
            local service1 = MakeTestService()
            expect(service1).to.be.ok()
        end)

        it("should create a service with required services", function()
            local service1 = MakeTestService()

            local service2 = MakeTestService({
                RequiredServices = {service1},
            })
            expect(service2).to.be.ok()
        end)

        it("should be able to fetch the service by name", function()
            local service1 = MakeTestService()
            expect(Roam.getService(Roam.getNameFromService(service1))).to.equal(service1)
        end)

        it("should error if services have the same name", function()
            local service1 = MakeTestService()
            expect(function()
                MakeTestService({
                    Name = Roam.getNameFromService(service1),
                })
            end).to.throw()
        end)
    end)

    describe(".start", function()
        it("should start services in the proper order", function()

            local service1 = MakeTestService()
            
            local service2 = MakeTestService({
                RequiredServices = {service1},
            })
            print("Service1", Roam.getNameFromService(service1))
            print("Service2", Roam.getNameFromService(service2))

            service1.RoamInit = function()
                assert(not service2.DidInit, "Service2 already initialized")
            end

            service2.RoamInit = function()
                assert(service1.DidInit, "Service1 did not init first")
            end
            
            local success = Roam.start():await()
            expect(success).to.be.ok()
        end)
    end)
end
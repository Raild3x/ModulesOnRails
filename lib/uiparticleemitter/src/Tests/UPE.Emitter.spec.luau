--[[
	Emitter component coverage: spawning, caps, pooling, lifecycle (idle /
	active / draining / dead), Enabled handling, and destruction semantics.

	Determinism pattern: the emitter connects to a real RunService signal, so
	tests call :Stop() right after spawning (killing the live connection)
	and then drive the private :_Step(dt) manually to simulate time. Never
	yield between spawning and :Stop(), or real frames may interleave.
]]

return function(tiniest)
	local Fusion = require("../../Fusion")
	local UIParticleEmitter = require(script.Parent.Parent :: any) :: any

	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

	-- Long default lifetime so stray real frames between calls can't expire
	-- particles; tests that need expiry override LifeTime themselves.
	local SAFE_LIFETIME = 60

	local function setup(props: { [string]: any }?)
		local gui = Instance.new("ScreenGui")
		gui.Name = "UPE_TestGui"
		gui.Parent = game:GetService("StarterGui")
		local scope = Fusion.scoped(Fusion)

		local emitterProps: { [string]: any } = {
			Parent = gui,
			LifeTime = SAFE_LIFETIME,
		}
		for key, value in props or {} do
			emitterProps[key] = value
		end

		local emitter = UIParticleEmitter(scope, emitterProps)
		local function cleanup()
			emitter:Clear()
			Fusion.doCleanup(scope)
			gui:Destroy()
		end
		return emitter, scope, gui, cleanup
	end

	local function getFolder(gui: ScreenGui): Folder?
		return gui:FindFirstChild("UIParticles") :: Folder?
	end

	describe("spawning", function()
		test("Fire spawns particles into a per-emitter folder", function()
			local emitter, _, gui, cleanup = setup()
			emitter:Fire { Amount = 10 }
			emitter:Stop()

			expect(emitter:GetParticleCount()).is(10)
			local folder = getFolder(gui)
			expect(folder).exists()
			expect(#(folder :: Folder):GetChildren()).is(10)
			cleanup()
		end)

		test("Fire with no config uses Rate as the amount", function()
			local emitter, _, _, cleanup = setup { Rate = 7 }
			emitter:Fire()
			emitter:Stop()
			expect(emitter:GetParticleCount()).is(7)
			cleanup()
		end)

		test("image particles are ImageLabels", function()
			local emitter, _, gui, cleanup = setup()
			emitter:Fire { Amount = 1, Image = "rbxassetid://123" }
			emitter:Stop()

			local child = (getFolder(gui) :: Folder):GetChildren()[1]
			expect(child:IsA("ImageLabel")).is_true()
			expect((child :: ImageLabel).Image).is("rbxassetid://123")
			cleanup()
		end)

		test("constant SizeScale bakes into the spawn size", function()
			local emitter, _, gui, cleanup = setup { Size = Vector2.new(10, 10), SizeScale = 2 }
			emitter:Fire { Amount = 1 }
			emitter:Stop()

			local child = (getFolder(gui) :: Folder):GetChildren()[1] :: GuiObject
			expect(child.Size).is(UDim2.fromOffset(20, 20))
			cleanup()
		end)

		test("SizeScale sequences animate size over lifetime", function()
			local emitter, _, gui, cleanup = setup {
				Size = Vector2.new(10, 10),
				SizeScale = NumberSequence.new(1, 2),
				LifeTime = 1,
				TimeScale = 1,
			}
			emitter:Fire { Amount = 1 }
			emitter:Stop()

			local child = (getFolder(gui) :: Folder):GetChildren()[1] :: GuiObject
			expect(child.Size).is(UDim2.fromOffset(10, 10))
			emitter:_Step(0.5)
			expect(child.Size).is(UDim2.fromOffset(15, 15))
			cleanup()
		end)

		test("Fire spawn-area overrides position particles within the area", function()
			local emitter, _, _, cleanup = setup()
			emitter:Fire {
				Amount = 5,
				SpawnAreaAbsolutePosition = Vector2.new(300, 400),
				SpawnAreaSize = UDim2.fromOffset(50, 50),
				SpawnAreaAnchorPoint = Vector2.new(0.5, 0.5),
			}
			emitter:Stop()

			expect(emitter:GetParticleCount()).is(5)
			for _, particle in emitter._particles do
				expect(particle.Position.X >= 275 and particle.Position.X <= 325).is_true()
				expect(particle.Position.Y >= 375 and particle.Position.Y <= 425).is_true()
			end
			cleanup()
		end)

		test("non-positive lifetimes are dropped", function()
			local emitter, _, _, cleanup = setup()
			emitter:Fire { Amount = 3, LifeTime = 0 }
			expect(emitter:GetParticleCount()).is(0)
			cleanup()
		end)

		test("Fire without a parent warns once and spawns nothing", function()
			local scope = Fusion.scoped(Fusion)
			local emitter = UIParticleEmitter(scope, {})
			expect(function()
				emitter:Fire { Amount = 1 }
			end).warns()
			expect(function()
				emitter:Fire { Amount = 1 }
			end).never_warns()
			expect(emitter:GetParticleCount()).is(0)
			Fusion.doCleanup(scope)
		end)
	end)

	describe("nested parent spawn area (regression)", function()
		-- The emitter's UI is parented a level below a Frame with a fixed
		-- (offset-based) size, so its AbsoluteSize/AbsolutePosition differ
		-- from the ScreenGui's own -- exposing any fallback path that mixes
		-- ui.Size/ui.Position up with the LayerCollector's AbsoluteSize.
		local function setupNested(sizeScale: Vector2)
			local gui = Instance.new("ScreenGui")
			gui.Parent = game:GetService("StarterGui")

			local container = Instance.new("Frame")
			container.Size = UDim2.fromOffset(400, 300)
			container.BackgroundTransparency = 1
			container.Parent = gui

			local scope = Fusion.scoped(Fusion)
			local emitter = UIParticleEmitter(scope, {
				Parent = container,
				LifeTime = SAFE_LIFETIME,
				SpawnAreaAnchorPoint = Vector2.new(0.5, 0.5),
				SpawnAreaPosition = UDim2.fromScale(0.5, 0.5),
				SpawnAreaSize = UDim2.fromScale(sizeScale.X, sizeScale.Y),
			})

			local function cleanup()
				emitter:Clear()
				Fusion.doCleanup(scope)
				gui:Destroy()
			end
			return emitter, cleanup
		end

		-- Bounds check plus a spread check: a buggy fallback that collapses
		-- containerSize to (0, 0) would put every particle at exactly
		-- `center`, which a bounds-only check wouldn't catch.
		local function assertParticlesWithin(emitter, center: Vector2, size: Vector2)
			local half = size / 2
			local first = emitter._particles[1].Position
			local allSame = true
			for _, particle in emitter._particles do
				local pos = particle.Position
				expect(pos.X >= center.X - half.X - 0.01).is_true()
				expect(pos.X <= center.X + half.X + 0.01).is_true()
				expect(pos.Y >= center.Y - half.Y - 0.01).is_true()
				expect(pos.Y <= center.Y + half.Y + 0.01).is_true()
				if pos ~= first then
					allSame = false
				end
			end
			expect(allSame).never_is_true()
		end

		test("size falls back to the UI's own AbsoluteSize when only Position is overridden", function()
			local emitter, cleanup = setupNested(Vector2.new(0.5, 0.5))
			expect(emitter.UI.AbsoluteSize).is(Vector2.new(200, 150))

			emitter:Fire { Amount = 20, SpawnAreaAbsolutePosition = Vector2.new(5000, 5000) }
			emitter:Stop()
			expect(emitter:GetParticleCount()).is(20)

			assertParticlesWithin(emitter, Vector2.new(5000, 5000), Vector2.new(200, 150))
			cleanup()
		end)

		test("position falls back to the UI's own AbsolutePosition when only Size is overridden", function()
			local emitter, cleanup = setupNested(Vector2.new(0.5, 0.5))
			local expectedCenter = emitter.UI.AbsolutePosition + emitter.UI.AbsoluteSize / 2

			emitter:Fire { Amount = 20, SpawnAreaSize = UDim2.fromOffset(60, 60) }
			emitter:Stop()
			expect(emitter:GetParticleCount()).is(20)

			assertParticlesWithin(emitter, expectedCenter, Vector2.new(60, 60))
			cleanup()
		end)
	end)

	describe("MaxParticles", function()
		test("explicit cap drops excess spawns", function()
			local emitter, _, _, cleanup = setup { MaxParticles = 5 }
			emitter:Fire { Amount = 20 }
			emitter:Stop()
			expect(emitter:GetParticleCount()).is(5)
			cleanup()
		end)

		test("default cap is 500", function()
			local emitter, _, _, cleanup = setup()
			emitter:Fire { Amount = 600 }
			emitter:Stop()
			expect(emitter:GetParticleCount()).is(500)
			cleanup()
		end)
	end)

	describe("pooling", function()
		test("expired particles are hidden and reused, not destroyed", function()
			local emitter, _, gui, cleanup = setup { LifeTime = 1 }
			emitter:Fire { Amount = 3 }
			emitter:Stop()
			emitter:_Step(2)

			expect(emitter:GetParticleCount()).is(0)
			local folder = getFolder(gui) :: Folder
			expect(#folder:GetChildren()).is(3)
			for _, child in folder:GetChildren() do
				expect((child :: GuiObject).Visible).never_is_true()
			end

			-- Refiring reuses the pooled instances rather than creating more
			emitter:Fire { Amount = 3 }
			emitter:Stop()
			expect(emitter:GetParticleCount()).is(3)
			expect(#folder:GetChildren()).is(3)
			cleanup()
		end)

		test("pool shrinks when MaxParticles decreases", function()
			local gui = Instance.new("ScreenGui")
			gui.Parent = game:GetService("StarterGui")
			local scope = Fusion.scoped(Fusion)
			local maxParticles = scope:Value(3)
			local emitter = UIParticleEmitter(scope, {
				Parent = gui,
				LifeTime = 1,
				MaxParticles = maxParticles,
			})

			emitter:Fire { Amount = 5 }
			emitter:Stop()
			expect(emitter:GetParticleCount()).is(3)
			emitter:_Step(2)
			local folder = getFolder(gui) :: Folder
			expect(#folder:GetChildren()).is(3)

			-- With the cap lowered, dying particles no longer fit in the pool
			maxParticles:set(1)
			emitter:Fire { Amount = 1 }
			emitter:Stop()
			expect(emitter:GetParticleCount()).is(1)
			emitter:_Step(2)
			expect(#folder:GetChildren()).is(2)

			Fusion.doCleanup(scope)
			gui:Destroy()
		end)

		test("Clear recycles live particles into the pool", function()
			local emitter, _, gui, cleanup = setup()
			emitter:Fire { Amount = 4 }
			emitter:Stop()
			emitter:Clear()

			expect(emitter:GetParticleCount()).is(0)
			local folder = getFolder(gui) :: Folder
			expect(#folder:GetChildren()).is(4)
			for _, child in folder:GetChildren() do
				expect((child :: GuiObject).Visible).never_is_true()
			end
			cleanup()
		end)
	end)

	describe("shared pool", function()
		-- Two emitters parented under the same LayerCollector share a single
		-- UIParticles folder and instance pool.
		local function setupPair(props: { [string]: any }?)
			local gui = Instance.new("ScreenGui")
			gui.Parent = game:GetService("StarterGui")

			local function make()
				local scope = Fusion.scoped(Fusion)
				local emitterProps: { [string]: any } = { Parent = gui, LifeTime = SAFE_LIFETIME }
				for key, value in props or {} do
					emitterProps[key] = value
				end
				return UIParticleEmitter(scope, emitterProps), scope
			end

			local a, aScope = make()
			local b, bScope = make()
			local function cleanup()
				a:Clear()
				b:Clear()
				Fusion.doCleanup(aScope)
				Fusion.doCleanup(bScope)
				gui:Destroy()
			end
			return a, aScope, b, bScope, gui, cleanup
		end

		local function countFolders(gui: ScreenGui): number
			local n = 0
			for _, child in gui:GetChildren() do
				if child.Name == "UIParticles" then
					n += 1
				end
			end
			return n
		end

		test("emitters on the same LayerCollector share one folder", function()
			local a, _, b, _, gui, cleanup = setupPair()
			a:Fire { Amount = 2 }
			a:Stop()
			b:Fire { Amount = 3 }
			b:Stop()

			expect(countFolders(gui)).is(1)
			expect(#(getFolder(gui) :: Folder):GetChildren()).is(5)
			cleanup()
		end)

		test("idle instances released by one emitter are reused by another", function()
			local a, _, b, _, gui, cleanup = setupPair { LifeTime = 1 }

			-- a spawns 3, then lets them die back into the shared pool.
			a:Fire { Amount = 3 }
			a:Stop()
			a:_Step(2)
			expect(a:GetParticleCount()).is(0)
			local folder = getFolder(gui) :: Folder
			expect(#folder:GetChildren()).is(3)

			-- b reuses those 3 idle instances in place -- no new instances.
			b:Fire { Amount = 3 }
			b:Stop()
			expect(b:GetParticleCount()).is(3)
			expect(#folder:GetChildren()).is(3)
			cleanup()
		end)

		test("the shared folder is torn down only when the last emitter dies", function()
			local a, aScope, b, bScope, gui, _ = setupPair { CleanupParticlesImmediately = true }
			a:Fire { Amount = 1 }
			a:Stop()
			b:Fire { Amount = 1 }
			b:Stop()
			local folder = getFolder(gui) :: Folder
			expect(folder.Parent).exists()

			-- Destroying one emitter leaves the shared folder alive for the other.
			Fusion.doCleanup(bScope)
			expect(folder.Parent).exists()

			-- Destroying the last one releases the shared resources.
			Fusion.doCleanup(aScope)
			expect(folder.Parent).never_exists()
			gui:Destroy()
		end)
	end)

	describe("stepping", function()
		test("particles move under simulation when stepped", function()
			local emitter, _, gui, cleanup = setup {
				Velocity = Vector2.new(100, 0),
				Gravity = 0,
				Drag = 0,
			}
			emitter:Fire { Amount = 1 }
			emitter:Stop()

			local child = (getFolder(gui) :: Folder):GetChildren()[1] :: GuiObject
			local before = child.Position.X.Offset
			emitter:_Step(1)
			expect(child.Position.X.Offset > before).is_true()
			cleanup()
		end)

		test("TimeScale = 0 freezes lifetime and motion", function()
			local emitter, _, _, cleanup = setup { LifeTime = 1, TimeScale = 0 }
			emitter:Fire { Amount = 1 }
			emitter:Stop()
			emitter:_Step(5)
			expect(emitter:GetParticleCount()).is(1)
			cleanup()
		end)

		test("Stop halts the update loop", function()
			local emitter, _, _, cleanup = setup()
			emitter:Fire { Amount = 1 }
			emitter:Stop()
			expect(emitter._connection).never_exists()
			cleanup()
		end)
	end)

	describe("Enabled", function()
		test("constant Enabled = true spawns continuously", function()
			-- Rate 4 -> exact 0.25s spawn interval (binary-exact), so one
			-- 1-second step spawns exactly 4.
			local emitter, _, _, cleanup = setup { Enabled = true, Rate = 4 }
			emitter:Stop()
			emitter:_Step(1)
			expect(emitter:GetParticleCount()).is(4)
			cleanup()
		end)

		test("Enabled = nil constructs without error and stays idle", function()
			local emitter, _, _, cleanup = setup()
			expect(emitter:GetParticleCount()).is(0)
			expect(emitter._connection).never_exists()
			cleanup()
		end)

		test("Enabled as a Fusion Value starts the emitter when set", function()
			local gui = Instance.new("ScreenGui")
			gui.Parent = game:GetService("StarterGui")
			local scope = Fusion.scoped(Fusion)
			local enabled = scope:Value(false)
			local emitter = UIParticleEmitter(scope, {
				Parent = gui,
				LifeTime = SAFE_LIFETIME,
				Enabled = enabled,
				Rate = 4,
			})
			expect(emitter:GetParticleCount()).is(0)

			enabled:set(true)
			emitter:Stop()
			emitter:_Step(1)
			expect(emitter:GetParticleCount()).is(4)

			-- Disabling stops spawning; existing particles keep simulating
			enabled:set(false)
			emitter:_Step(1)
			expect(emitter:GetParticleCount()).is(4)

			emitter:Clear()
			Fusion.doCleanup(scope)
			gui:Destroy()
		end)
	end)

	describe("Visible", function()
		test("toggling a Visible state hides live particles", function()
			local gui = Instance.new("ScreenGui")
			gui.Parent = game:GetService("StarterGui")
			local scope = Fusion.scoped(Fusion)
			local visible = scope:Value(true)
			local emitter = UIParticleEmitter(scope, {
				Parent = gui,
				LifeTime = SAFE_LIFETIME,
				Visible = visible,
			})
			emitter:Fire { Amount = 2 }
			emitter:Stop()

			visible:set(false)
			for _, child in (getFolder(gui) :: Folder):GetChildren() do
				expect((child :: GuiObject).Visible).never_is_true()
			end
			visible:set(true)
			for _, child in (getFolder(gui) :: Folder):GetChildren() do
				expect((child :: GuiObject).Visible).is_true()
			end

			emitter:Clear()
			Fusion.doCleanup(scope)
			gui:Destroy()
		end)
	end)

	describe("destruction", function()
		test("particles outlive the scope by default, then drain", function()
			local emitter, scope, gui, _ = setup()
			emitter:Fire { Amount = 5 }
			emitter:Stop()
			local folder = getFolder(gui) :: Folder

			Fusion.doCleanup(scope)

			-- Spawning is dead, but the particles live on
			expect(emitter:GetParticleCount()).is(5)
			expect(#folder:GetChildren()).is(5)
			emitter:Fire { Amount = 3 }
			expect(emitter:GetParticleCount()).is(5)

			-- Draining: once the last particle expires everything cleans up
			emitter:_Step(SAFE_LIFETIME + 1)
			expect(emitter:GetParticleCount()).is(0)
			expect(folder.Parent).never_exists()
			expect(emitter._connection).never_exists()
			gui:Destroy()
		end)

		test("CleanupParticlesImmediately destroys particles with the scope", function()
			local emitter, scope, gui, _ = setup { CleanupParticlesImmediately = true }
			emitter:Fire { Amount = 5 }
			emitter:Stop()
			local folder = getFolder(gui) :: Folder

			Fusion.doCleanup(scope)

			expect(emitter:GetParticleCount()).is(0)
			expect(folder.Parent).never_exists()
			expect(emitter._connection).never_exists()
			gui:Destroy()
		end)

		test("destroying the UI directly also ends the emitter", function()
			local emitter, scope, gui, _ = setup { CleanupParticlesImmediately = true }
			emitter:Fire { Amount = 2 }
			emitter:Stop()

			emitter.UI:Destroy()
			expect(emitter:GetParticleCount()).is(0)
			emitter:Fire { Amount = 1 }
			expect(emitter:GetParticleCount()).is(0)

			Fusion.doCleanup(scope)
			gui:Destroy()
		end)
	end)

	describe("entry point", function()
		test("Presets.Confetti returns a props table and overrides win", function()
			local props = UIParticleEmitter.Presets.Confetti { Rate = 30, Seed = 5 }
			expect(props.Rate).is(30)
			expect(typeof(props.Size)).is("function")
			expect(typeof(props.Color3)).is("function")
			expect(typeof(props.Size())).is("Vector2")
			expect(typeof(props.Color3())).is("Color3")
			expect(typeof(props.LifeTime)).is("NumberRange")
		end)

		test("the story module has the UI Labs shape", function()
			local story = require("../UIParticleEmitter.story") :: any
			expect(story).is_a("table")
			expect(typeof(story.story)).is("function")
			expect(story.controls).is_a("table")
			expect(story.fusion).exists()
		end)

		test("the nested-parent story module has the UI Labs shape", function()
			local story = require("../UIParticleEmitterNestedParent.story") :: any
			expect(story).is_a("table")
			expect(typeof(story.story)).is("function")
			expect(story.controls).is_a("table")
			expect(story.fusion).exists()
		end)
	end)
end

--[[
	Sequence evaluation coverage: NumberSequence and ColorSequence sampling at
	edge times, exact keypoints, and mid-segment interpolation.
]]

return function(tiniest)
	local SequenceUtil = require("../SequenceUtil")

	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

	local function approx(a: number, b: number): boolean
		return math.abs(a - b) < 1e-6
	end

	describe("EvaluateNumberSequence", function()
		local sequence = NumberSequence.new {
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.5, 10),
			NumberSequenceKeypoint.new(1, 4),
		}

		test("returns the first keypoint at time <= 0", function()
			expect(SequenceUtil.EvaluateNumberSequence(sequence, 0)).is(0)
			expect(SequenceUtil.EvaluateNumberSequence(sequence, -1)).is(0)
		end)

		test("returns the last keypoint at time >= 1", function()
			expect(SequenceUtil.EvaluateNumberSequence(sequence, 1)).is(4)
			expect(SequenceUtil.EvaluateNumberSequence(sequence, 2)).is(4)
		end)

		test("returns exact values at interior keypoints", function()
			expect(approx(SequenceUtil.EvaluateNumberSequence(sequence, 0.5), 10)).is_true()
		end)

		test("linearly interpolates between keypoints", function()
			expect(approx(SequenceUtil.EvaluateNumberSequence(sequence, 0.25), 5)).is_true()
			expect(approx(SequenceUtil.EvaluateNumberSequence(sequence, 0.75), 7)).is_true()
		end)

		test("handles a single-keypoint pair sequence", function()
			local flat = NumberSequence.new(3)
			expect(SequenceUtil.EvaluateNumberSequence(flat, 0.5)).is(3)
		end)
	end)

	describe("EvaluateColorSequence", function()
		local black = Color3.new(0, 0, 0)
		local white = Color3.new(1, 1, 1)
		local sequence = ColorSequence.new(black, white)

		test("returns the first keypoint at time <= 0", function()
			expect(SequenceUtil.EvaluateColorSequence(sequence, 0)).is(black)
			expect(SequenceUtil.EvaluateColorSequence(sequence, -0.5)).is(black)
		end)

		test("returns the last keypoint at time >= 1", function()
			expect(SequenceUtil.EvaluateColorSequence(sequence, 1)).is(white)
			expect(SequenceUtil.EvaluateColorSequence(sequence, 1.5)).is(white)
		end)

		test("lerps between keypoints", function()
			local mid = SequenceUtil.EvaluateColorSequence(sequence, 0.5)
			expect(approx(mid.R, 0.5)).is_true()
			expect(approx(mid.G, 0.5)).is_true()
			expect(approx(mid.B, 0.5)).is_true()
		end)

		test("respects interior keypoint times", function()
			local red = Color3.new(1, 0, 0)
			local blue = Color3.new(0, 0, 1)
			local threeKey = ColorSequence.new {
				ColorSequenceKeypoint.new(0, red),
				ColorSequenceKeypoint.new(0.8, blue),
				ColorSequenceKeypoint.new(1, blue),
			}
			local atKeypoint = SequenceUtil.EvaluateColorSequence(threeKey, 0.8)
			expect(approx(atKeypoint.B, 1)).is_true()
			expect(approx(atKeypoint.R, 0)).is_true()

			local mid = SequenceUtil.EvaluateColorSequence(threeKey, 0.4)
			expect(approx(mid.R, 0.5)).is_true()
			expect(approx(mid.B, 0.5)).is_true()
		end)
	end)
end

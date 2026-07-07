--!strict
-- Authors: Logan Hunt (Raildex)
-- July 06, 2026
--[[
	Pure evaluation of Roblox NumberSequence / ColorSequence values at a
	normalized time (0-1). Keypoint envelopes are intentionally ignored;
	values are linearly interpolated between keypoints.
]]

local SequenceUtil = {}

--[=[
	@within UIParticleEmitter
	@function EvaluateNumberSequence
	@private
	@param sequence NumberSequence -- The sequence to evaluate
	@param time number -- Normalized time from 0 to 1
	@return number -- The linearly interpolated value

	Evaluates a NumberSequence at a given time. Keypoint envelopes are ignored.
]=]
function SequenceUtil.EvaluateNumberSequence(sequence: NumberSequence, time: number): number
	local keypoints = sequence.Keypoints

	if time <= 0 then
		return keypoints[1].Value
	end
	if time >= 1 then
		return keypoints[#keypoints].Value
	end

	for i = 1, #keypoints - 1 do
		local curr = keypoints[i]
		local nextKeypoint = keypoints[i + 1]

		if time >= curr.Time and time <= nextKeypoint.Time then
			local alpha = (time - curr.Time) / (nextKeypoint.Time - curr.Time)
			return curr.Value + (nextKeypoint.Value - curr.Value) * alpha
		end
	end

	return keypoints[#keypoints].Value
end

--[=[
	@within UIParticleEmitter
	@function EvaluateColorSequence
	@private
	@param sequence ColorSequence -- The sequence to evaluate
	@param time number -- Normalized time from 0 to 1
	@return Color3 -- The linearly interpolated color

	Evaluates a ColorSequence at a given time.
]=]
function SequenceUtil.EvaluateColorSequence(sequence: ColorSequence, time: number): Color3
	local keypoints = sequence.Keypoints

	if time <= 0 then
		return keypoints[1].Value
	end
	if time >= 1 then
		return keypoints[#keypoints].Value
	end

	for i = 1, #keypoints - 1 do
		local curr = keypoints[i]
		local nextKeypoint = keypoints[i + 1]

		if time >= curr.Time and time <= nextKeypoint.Time then
			local alpha = (time - curr.Time) / (nextKeypoint.Time - curr.Time)
			return curr.Value:Lerp(nextKeypoint.Value, alpha)
		end
	end

	return keypoints[#keypoints].Value
end

return SequenceUtil

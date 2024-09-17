--!strict
-- Authors: Logan Hunt (Raildex)
-- Date Created: July 7, 2022
-- Last Updated: May 12, 2023
-- Version: 1.0.4
--[=[
	@class ProbabilityDistributor

	ProbabilityDistributor is a class that allows you pick a random item from a table of weighted items.
	The given WeightsTable must be in the format of:
	```lua
	{
		Weight: Weight;
		Value: any;
	}
	```
	Where `Weight` is a number, NumberRange or a function that returns a number or NumberRange, and Value is any value.
	The Weights are calculated during object construction. Even if the return value of your functions change, the
	weights will not. If you want to take advantage of updated weights, you must create a new ProbabilityDistributor.
	If a NumberRange is detected as a weight, it will generate a random INTEGER between the min and max values of
	the Range. If you need more granular control over the weights, you can pass a function that returns a number/NumberRange.

	[Example]
	```lua
	local WeightTable = {
		{Value = "A", Weight = 100};
		{Value = "B", Weight = 50};
		{Value = "C", Weight = 25};
		{Value = "D", Weight = 25};
	}

	local Distributor: ProbabilityDistributor<string> = ProbabilityDistributor.new(WeightTable)

	local randomValue = Distributor:Roll() --// Has a 50% chance of returning "A", 25% chance of returning "B", and a 12.5% chance for "C" and "D".
	print(randomValue)
	```
]=]

--[[
    [API]
		.new(weights: {WeightedItem<T>}, randomOrSeed: (Random | number)?) -> ProbabilityDistributor<T>
		:Roll(luck: number?) -> T
		:Clone() -> ProbabilityDistributor<T>
		:Sample(numOfSamples: number?, luck: number?) -> {[T]: number}
]]

--[=[
    @type Weight number | NumberRange | () -> (number | NumberRange)
    @within ProbabilityDistributor
    A valid input for the weight of an item in the WeightsTable. Allows for functions
    to be passed in to generate a weight on the fly. If a NumberRange is given in, it will
    generate a random INTEGER between the min and max values of the Range.
]=]
type Weight = number | NumberRange | () -> (number | NumberRange)

--[=[
    @interface WeightedItem<T>
    .Weight Weight
    .Value T
    @within ProbabilityDistributor
    The format weights and an associated value must be in.
]=]
export type WeightedItem<T> = {
	Weight: Weight;
	Value: T;
}

--[=[
    @type WeightedArray<T> {WeightedItem<T>}
    @within ProbabilityDistributor
    A valid input for the WeightsTable.
]=]
export type WeightedArray<T> = {WeightedItem<T>}


export type ProbabilityDistributor<T> = {
	new: (weights: {WeightedItem<T>}, randomOrSeed: (Random | number)?) -> ProbabilityDistributor<T>;
	Roll: (self: ProbabilityDistributor<T>, luck: number?) -> T;
	Clone: (self: ProbabilityDistributor<T>) -> ProbabilityDistributor<T>;
	Sample: (self: ProbabilityDistributor<T>, numOfSamples: number?, luck: number?) -> {[T]: number};
}

--------------------------------------------------------------------------------
	--// Class //--
--------------------------------------------------------------------------------

local ProbabilityDistributor = {}
ProbabilityDistributor.ClassName = "ProbabilityDistributor"
ProbabilityDistributor.__index = ProbabilityDistributor
ProbabilityDistributor.__call = function(t, ...): ProbabilityDistributor<any> | any
	if t == ProbabilityDistributor then
		return ProbabilityDistributor.new(...)
	end
	return t:Roll(...)
end

--[=[
	Constructs a new ProbabilityDistributor

	@param weights -- A table of weights to distribute.

	@param randomOrSeed -- An optional random number generator to use for the rolls. If a number is passed, it will be used as the seed for a new random number generator. If nothing is passed, it will create a new Random and use the current time as the seed.
	
	@return ProbabilityDistributor<T> -- A new probability distributor of type T. Where T is the type of the value of the weighted item.
]=]
function ProbabilityDistributor.new<T>(weights: {WeightedItem<T>}, randomOrSeed: (Random | number)?): ProbabilityDistributor<T>
	assert(type(weights) == "table", "Weights must be a table.")

	local self = setmetatable({
		NumberGenerator = if typeof(randomOrSeed) == "Random" then
			randomOrSeed
		else
			Random.new(randomOrSeed);

		MaxRepetitions = 100;
		OrderedWeights = {};
		TotalWeight = 0;
	}, ProbabilityDistributor)

	for i, item in pairs(weights) do
		local weight = item.Weight
		if typeof(weight) == "function" then
			weight = weight()
		end
		if typeof(weight) == "NumberRange" then
			weight = math.random(weight.Min, weight.Max)
		end
		assert(type(weight) == "number", "Resultant Weight must be a number.")

		self.TotalWeight += weight
		table.insert(self.OrderedWeights, {
			Weight = weight;
			Value = item.Value;
			Order = i;
		})
	end

	table.sort(self.OrderedWeights, function(a, b)
		return a.Weight > b.Weight
	end)
	
	return self :: any
end


--[=[
    Rolls the probability distributor for a weighted item.

    @param luck -- [Optional] A number between 0 and 1 that determines how lucky the roll is. The number acts as a chance that it rerolls the item for a better version. 'Better'ness is determined by the initial order of the weights table.

    @return T -- The value of the item that was rolled.
]=]
function ProbabilityDistributor:Roll<T>(luck: number?): T
	local NumberGenerator: Random = self.NumberGenerator

	local totalWeight = self.TotalWeight
	local orderedWeights: {WeightedItem<T> & {Order: number}} = self.OrderedWeights

	luck = luck or 0
	assert(luck >= 0 and luck <= 1, "Luck must be between 0 and 1. (inclusive)")

	local repetitions, maxRepetitions = 0, self.MaxRepetitions
	local bestIdx, bestItem = -1, nil
	repeat
		repetitions += 1
		local randomV = math.clamp((NumberGenerator:NextNumber() * totalWeight), 0, totalWeight)

		local runningTotal = 0
		for i = 1, #orderedWeights do 
			local item = orderedWeights[i]
			--print("Distribution:", w, ("%.1f"):format( (getValue(w)/totalWeight)*100 ) )

			runningTotal += item.Weight :: number
			if randomV <= runningTotal then
				if item.Order > bestIdx then
					bestIdx = item.Order
					bestItem = item
				end
				break
			end
		end
	until math.random() >= luck :: number or repetitions >= maxRepetitions
	
	return bestItem.Value
end


--[=[
    Clones the probability distributor.

    @return ProbabilityDistributor<T> -- A new probability distributor of type T. Where T is the type of the value of the weighted item.
]=]
function ProbabilityDistributor:Clone<T>(): ProbabilityDistributor<T>
	local copy = table.clone(self)
	copy.NumberGenerator = copy.NumberGenerator:Clone()
	return copy
end


--[=[
    Samples the probability distributor to show the distribution of the rolls.

    @param numOfSamples -- The number of samples to take. Defaults to 10,000.

    @param luck -- The luck to use for the rolls. Defaults to 0.

    @return {[T]: number} -- A table of the items that were rolled and how many times they were rolled.
]=]
function ProbabilityDistributor:Sample<T>(numOfSamples: number?, luck: number?): {[T]: number}
	numOfSamples = numOfSamples or 10_000
	local sampleTracker = {}
	for i = 1, numOfSamples :: number do
		local item = self:Roll(luck)
		sampleTracker[item] = (sampleTracker[item] or 0) + 1
	end
	return sampleTracker
end



return table.freeze(ProbabilityDistributor)
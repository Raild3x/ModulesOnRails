--!strict
--[=[
	A/B timing core for NavMesh prototypes, following the audited bench method (bench.md).
	Every variant runs on every workload:
	- rounds are interleaved, with the variant order rotated each round;
	- each round keeps the best of `Reps` repetitions;
	- the result is the median over rounds.
	Each variant's output is fingerprinted and must match the first variant (the baseline) on
	every workload. Prints `[R]` and `[CHECK]` lines for `ab.py`, and `[MARK]` breadcrumbs;
	every loop checks the deadline.
]=]

export type Variant = { Name: string, Run: (input: any) -> any }
export type Workload = { Name: string, Input: any, Reps: number? }
export type Options = {
	Variants: { Variant },
	Workloads: { Workload },
	Fingerprint: (output: any) -> string,
	Rounds: number,
	Clock: () -> number,
	Yield: () -> (),
	Deadline: number,
}

local function median(xs: { number }): number
	local s = table.clone(xs)
	table.sort(s)
	return s[(#s + 1) // 2]
end

return function(o: Options)
	local times: { [string]: { number } } = {}
	local prints: { [string]: string } = {}
	local count = #o.Variants
	for round = 1, o.Rounds do
		for k = 0, count - 1 do
			local variant = o.Variants[(round + k - 1) % count + 1]
			for _, workload in o.Workloads do
				if o.Clock() > o.Deadline then
					print("[MARK] deadline hit")
					return
				end
				local best, output = math.huge, nil
				for _ = 1, workload.Reps or 3 do
					local t0 = o.Clock()
					output = variant.Run(workload.Input)
					best = math.min(best, o.Clock() - t0)
				end
				local key = `{workload.Name}|{variant.Name}`
				if prints[key] == nil then
					prints[key] = o.Fingerprint(output)
				end
				times[key] = times[key] or {}
				table.insert(times[key], best * 1000)
				o.Yield()
			end
		end
		print(`[MARK] round {round}`)
	end
	for _, workload in o.Workloads do
		for _, variant in o.Variants do
			local key = `{workload.Name}|{variant.Name}`
			print(string.format("[R] %s | %s | %.3f", workload.Name, variant.Name, median(times[key])))
		end
		local base = prints[`{workload.Name}|{o.Variants[1].Name}`]
		for i = 2, count do
			local name = o.Variants[i].Name
			local ok = prints[`{workload.Name}|{name}`] == base
			print(`[CHECK] {workload.Name} | {name} | {if ok then "same" else "DIFFERENT"}`)
		end
	end
	print("[MARK] done")
end

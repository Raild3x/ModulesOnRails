--!strict
-- Negative control for the A/B harness: a variant whose output differs from the baseline in
-- one element must be reported DIFFERENT (and fail ab.py); an identical one must read "same".
return function(env: any)
	env.AB {
		Variants = {
			{
				Name = "base",
				Run = function(n: number)
					return table.create(n, 1)
				end,
			},
			{
				Name = "same",
				Run = function(n: number)
					return table.create(n, 1)
				end,
			},
			{
				Name = "wrong",
				Run = function(n: number)
					local out = table.create(n, 1)
					out[n] = 2
					return out
				end,
			},
		},
		Workloads = { { Name = "control", Input = 100, Reps = 1 } },
		Fingerprint = function(out: { number }): string
			return table.concat(out, ",")
		end,
		Rounds = 1,
		Clock = env.Clock,
		Yield = env.Yield,
		Deadline = env.Deadline,
	}
end

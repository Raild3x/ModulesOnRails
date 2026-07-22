--!strict
--[=[
	@class tiniest_coverage

	A tiniest plugin that attributes recorded coverage to individual tests and
	exposes the raw hit buffer for the coverage orchestrator to persist.

	It is repo-agnostic: it consumes only the emitted `_cov` runtime module
	(passed as `options.runtime`) and the tiniest plugin hooks. Per-test
	attribution uses a delta scan of the dense counter array in `after_test`,
	which is O(total_slots) per test with storage proportional to probes touched.
]=]

export type Runtime = {
	hits: { number },
	total: number,
	map_sha: string,
	new_baseline: () -> { number },
	delta: ({ number }) -> { number },
}

export type Options = {
	runtime: Runtime,
	enable_per_test: boolean?,
}

export type PerTest = {
	id: string,
	status: string,
	probes: { number },
}

export type CoverageResult = {
	hits: { number },
	total: number,
	map_sha: string,
	per_test: { PerTest },
}

local tiniest_coverage = {}

function tiniest_coverage.configure(options: Options)
	local runtime = options.runtime
	assert(runtime ~= nil, "tiniest_coverage: options.runtime is required")
	local enable_per_test = options.enable_per_test ~= false
	local baseline = runtime.new_baseline()
	local per_test: { PerTest } = {}

	local self: any = { is_tiniest_plugin = true }

	function self.before_run(_tests: any, _run_options: any)
		assert(
			runtime.map_sha ~= nil and runtime.map_sha ~= "",
			"coverage runtime not loaded -- running uninstrumented code?"
		)
		-- Attribute module-load / require-time hits to a synthetic pseudo-test.
		local changed = runtime.delta(baseline)
		if enable_per_test and #changed > 0 then
			table.insert(per_test, { id = "<module load>", status = "pass", probes = changed })
		end
	end

	function self.after_test(test: any, result: any, _run_options: any)
		local changed = runtime.delta(baseline)
		if enable_per_test then
			table.insert(per_test, {
				id = table.concat(test.labels, " > "),
				status = result.status,
				probes = changed,
			})
		end
		result.coverage_probes_hit = #changed
	end

	function self.after_run(run_result: any, _run_options: any)
		run_result.coverage = {
			hits = runtime.hits,
			total = runtime.total,
			map_sha = runtime.map_sha,
			per_test = per_test,
		} :: CoverageResult
	end

	function self.add_line_items(run_result: any, _options: any, add_line_item: any)
		local cov = run_result.coverage
		if cov == nil then
			return
		end
		local hit = 0
		for i = 1, cov.total do
			if cov.hits[i] > 0 then
				hit += 1
			end
		end
		add_line_item("Coverage", string.format("%d/%d probes hit (raw)", hit, cov.total))
	end

	return self
end

return tiniest_coverage

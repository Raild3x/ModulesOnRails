-- From dphfox/tiniest, licensed under BSD
--!strict

local tiniest_plugin = require("./tiniest_plugin")
local tiniest = require("./tiniest")
local tiniest_quote = require("./tiniest_quote")
type Test = tiniest.Test
type TestRunResult = tiniest.TestRunResult
type RunResult = tiniest.RunResult

type PrettyResult = {
	test: Test,
	result: TestRunResult,
	crumbs: string,
	icon: string,
	annotations: string,
}

type TreeNode = {
	label: string,
	children: { TreeNode },
	children_by_label: { [string]: TreeNode },
	pretty: PrettyResult?,
	status: ("pass" | "fail")?,
	duration: number?,
}

export type Options = {
	plugins: nil | { tiniest_plugin.Plugin },
	disable_emoji: boolean?,
	disable_unicode: boolean?,
	disable_colour: boolean?,
	disable_output: nil | {
		after_run: boolean?,
	},
	format: ("flat" | "tree")?,
	trim_duplicate_trace: boolean?,
}

local tiniest_pretty = {}

function tiniest_pretty.configure(options: Options)
	if options.disable_unicode then
		options.disable_emoji = true
	end

	local format = options.format or "flat"

	local plugins = tiniest_plugin.configure(options.plugins)

	local function string_len(text: string)
		if options.disable_unicode then
			return string.len(text)
		else
			return utf8.len(text) or string.len(text)
		end
	end
	local status_icons = {
		pass = if options.disable_emoji then "[PASS]" else "✅",
		fail = if options.disable_emoji then "[FAIL]" else "❌",
	}
	local crumb_trail = if options.disable_unicode then " > " else " ▸ "
	local divider = if options.disable_unicode then "=" else "═"
	local margin_line = if options.disable_unicode then "|" else "│"
	local tree_marker = if options.disable_unicode then "> " else "▸ "
	local TREE_INDENT_UNIT = "  "

	local paint = {}
	do
		local function ansi_mode(...)
			if options.disable_colour then
				return ""
			else
				return `{string.char(27)}[{table.concat({ ... }, ";")}m`
			end
		end
		local DIM = ansi_mode("2")
		local PASS = ansi_mode("1", "32")
		local PASS_DIM = ansi_mode("2", "32")
		local FAIL = ansi_mode("1", "31")
		local FAIL_DIM = ansi_mode("2", "31")
		local TRACE = ansi_mode("1", "34")
		local TRACE_DIM = ansi_mode("2", "34")
		local NUMBER = ansi_mode("1", "36")
		local STRING = ansi_mode("1", "33")
		local KEYWORD = ansi_mode("1", "35")
		local RESET = ansi_mode("0")

		function paint.dim(text: string): string
			return DIM .. text .. RESET
		end

		function paint.pass(text: string): string
			return PASS .. text .. RESET
		end

		function paint.pass_dim(text: string): string
			return PASS_DIM .. text .. RESET
		end

		function paint.fail(text: string): string
			return FAIL .. text .. RESET
		end

		function paint.fail_dim(text: string): string
			return FAIL_DIM .. text .. RESET
		end

		function paint.trace(text: string): string
			return TRACE .. text .. RESET
		end

		function paint.trace_dim(text: string): string
			return TRACE_DIM .. text .. RESET
		end

		function paint.number(text: string): string
			return NUMBER .. text .. RESET
		end

		function paint.string(text: string): string
			return STRING .. text .. RESET
		end

		function paint.keyword(text: string): string
			return KEYWORD .. text .. RESET
		end
	end

	local LINE_LENGTH = 80
	local full_width_divider = paint.dim(string.rep(divider, LINE_LENGTH))
	local function title(text: string): string
		local no_ansi = text:gsub(`{string.char(27)}.-m`, "")
		local divider_count = (LINE_LENGTH - string_len(no_ansi) - 2) / 2
		local divider_lhs = string.rep(divider, math.ceil(divider_count))
		local divider_rhs = string.rep(divider, math.floor(divider_count))
		return paint.dim(divider_lhs) .. " " .. text .. " " .. paint.dim(divider_rhs)
	end
	local function syntax(snippet: string): string
		snippet = snippet
			:gsub("0?[xXbB]?%d*%.?%d*[eE]?%-?%d+", paint.number)
			:gsub('".-"', paint.string)
			:gsub("'.-'", paint.string)
			:gsub("function", paint.keyword)
			:gsub("end", paint.keyword)
			:gsub("true", paint.keyword)
			:gsub("false", paint.keyword)
			:gsub("nil", paint.keyword)
			:gsub("%-%-.-\n", paint.dim)
		return snippet
	end
	local function indent(passage: string, indentation: string): string
		passage = passage:gsub("\n", "\n" .. indentation)
		return passage
	end

	-- Duplicated from tiniest_time.luau's local format_duration: tiniest_time.luau already requires
	-- this module (for the Options type), so requiring it back here would be a circular require.
	-- Keep the thresholds/rounding in sync by hand if either one changes.
	local function format_tree_duration(seconds: number): string
		local SECOND = 1
		local MILLISECOND = SECOND / 1000
		local MICROSECOND = MILLISECOND / 1000
		local micro_suffix = if options.disable_unicode then "u" else "µ"

		if seconds < 100 * MICROSECOND then
			return `{math.ceil(seconds / MICROSECOND * 100) / 100}{micro_suffix}s`
		elseif seconds < 100 * MILLISECOND then
			return `{math.ceil(seconds / MILLISECOND * 100) / 100}ms`
		else
			return `{math.ceil(seconds * 100) / 100}s`
		end
	end

	local function build_tree(pretty_results: { PrettyResult }): TreeNode
		local root: TreeNode = {
			label = "",
			children = {},
			children_by_label = {},
		}
		for _, pretty in pretty_results do
			local labels = pretty.test.labels
			local node = root
			for index = 1, #labels - 1 do
				local label = labels[index]
				local child = node.children_by_label[label]
				if child == nil then
					child = {
						label = label,
						children = {},
						children_by_label = {},
					} :: TreeNode
					node.children_by_label[label] = child
					table.insert(node.children, child)
				end
				node = child :: TreeNode
			end
			local leaf: TreeNode = {
				label = labels[#labels],
				children = {},
				children_by_label = {},
				pretty = pretty,
			}
			table.insert(node.children, leaf)
		end
		return root
	end

	-- Computes node.status/node.duration bottom-up. Group duration is the sum of every child's
	-- duration, but only if ALL children have one - one timing-less leaf blanks the aggregate for
	-- every ancestor, rather than showing a misleading partial sum.
	local function aggregate_tree(node: TreeNode): ()
		if node.pretty ~= nil then
			node.status = node.pretty.result.status
			local duration = (node.pretty.result :: any).duration
			if typeof(duration) == "number" then
				node.duration = duration
			end
			return
		end

		local status: "pass" | "fail" = "pass"
		local duration_sum = 0
		local has_all_durations = true
		for _, child in node.children do
			aggregate_tree(child)
			if child.status == "fail" then
				status = "fail"
			end
			if child.duration ~= nil then
				duration_sum += child.duration
			else
				has_all_durations = false
			end
		end
		node.status = status
		if has_all_durations then
			node.duration = duration_sum
		end
	end

	local function render_tree(node: TreeNode, depth: number, lines: { string }): ()
		local indent_str = string.rep(TREE_INDENT_UNIT, depth)
		local status = node.status :: "pass" | "fail"

		if node.pretty ~= nil then
			-- Leaves don't get a tree_marker like group lines do, so without an extra indent unit
			-- here they'd visually align with their parent group's label instead of nesting under it.
			local leaf_indent = indent_str .. TREE_INDENT_UNIT
			table.insert(lines, `{leaf_indent}{node.pretty.icon} {paint[status](node.label)}{node.pretty.annotations}`)
			return
		end

		local annotation = ""
		if node.duration ~= nil then
			annotation = paint.dim(` - {format_tree_duration(node.duration)}`)
		end
		local marker = if depth > 0 then tree_marker else ""
		table.insert(lines, `{indent_str}{marker}{status_icons[status]} {paint[status](node.label)}{annotation}`)
		for _, child in node.children do
			render_tree(child, depth + 1, lines)
		end
	end

	-- Counts how many trailing lines are identical across every line array given (e.g. shared
	-- framework frames that appear at the bottom of every failing test's stack trace). Returns 0
	-- if there are fewer than two traces to compare, since "duplicate" requires something to be
	-- duplicated against.
	local function common_suffix_line_count(line_arrays: { { string } }): number
		if #line_arrays < 2 then
			return 0
		end
		local shortest = line_arrays[1]
		for _, lines in line_arrays do
			if #lines < #shortest then
				shortest = lines
			end
		end
		local count = 0
		while count < #shortest do
			local line = shortest[#shortest - count]
			for _, lines in line_arrays do
				if lines[#lines - count] ~= line then
					return count
				end
			end
			count += 1
		end
		return count
	end

	local self = {}
	self.is_tiniest_plugin = true

	function self.format_run(run_result: RunResult): string
		local lines = {}

		local pretty_results: { PrettyResult } = {}
		for _, test in run_result.tests do
			local result = run_result.individual[test]
			local painted_labels = table.clone(test.labels)
			for index, label in painted_labels do
				local style = result.status .. if index < #painted_labels then "_dim" else ""
				painted_labels[index] = paint[style](label)
			end
			local annotations = ""
			local function add_annotation(annotation: string): ()
				annotations ..= ` - {annotation}`
			end
			plugins.notify("add_annotations", result, options, add_annotation)
			local pretty = {
				test = test,
				result = result,
				crumbs = table.concat(painted_labels, paint[(result.status .. "_dim") :: any](crumb_trail)),
				icon = status_icons[result.status],
				annotations = paint.dim(annotations),
			} :: PrettyResult
			table.insert(pretty_results, pretty)
		end

		if run_result.status_tally.fail > 0 then
			table.insert(lines, title(`Errors from {run_result.status_tally.fail} test(s)`))
			table.insert(lines, "")

			local trace_lines_by_pretty: { [PrettyResult]: { string } } = {}
			local all_trace_lines: { { string } } = {}
			for _, pretty in pretty_results do
				if pretty.result.status == "fail" then
					local trace_lines = (pretty.result.error.trace:gsub("\n+$", "")):split("\n")
					trace_lines_by_pretty[pretty] = trace_lines
					table.insert(all_trace_lines, trace_lines)
				end
			end
			local shared_suffix_count = if options.trim_duplicate_trace
				then common_suffix_line_count(all_trace_lines)
				else 0

			for _, pretty in pretty_results do
				if pretty.result.status == "pass" then
					continue
				end
				table.insert(lines, `{pretty.icon} {pretty.crumbs}`)
				table.insert(lines, paint.trace(pretty.result.error.message))
				local code = pretty.result.error.code
				if code ~= nil then
					local num_length = string_len(code.line)
					local empty_margin = string.rep(" ", num_length + 1) .. paint.dim(margin_line) .. " "
					table.insert(lines, empty_margin)
					table.insert(
						lines,
						`{paint.dim(`{code.line} {margin_line}`)} {indent(syntax(code.snippet), empty_margin)}`
					)
					table.insert(lines, empty_margin)
				end
				local ctx = (pretty.result :: any).error.context
				if ctx ~= nil and #ctx > 0 then
					local max_label_len = 0
					for _, entry in ctx do
						local len = string_len(entry.label)
						if len > max_label_len then
							max_label_len = len
						end
					end
					table.insert(lines, paint.fail_dim("Context:"))
					for _, entry in ctx do
						local padding = string.rep(" ", max_label_len - string_len(entry.label))
						local label_part = paint.dim(entry.label .. padding)
						table.insert(lines, `  {label_part} {paint.dim(margin_line)} {tiniest_quote(entry.value)}`)
					end
					table.insert(lines, "")
				end
				local trace_lines = trace_lines_by_pretty[pretty]
				local trim_count = math.min(shared_suffix_count, #trace_lines - 1)
				local visible_lines = table.move(trace_lines, 1, #trace_lines - trim_count, 1, {})
				table.insert(lines, paint.trace_dim(table.concat(visible_lines, "\n")))
				table.insert(lines, "")
			end

			if shared_suffix_count > 0 then
				local shared_lines = table.move(
					all_trace_lines[1],
					#all_trace_lines[1] - shared_suffix_count + 1,
					#all_trace_lines[1],
					1,
					{}
				)
				table.insert(
					lines,
					paint.dim(`{shared_suffix_count} shared stack frame(s) omitted from each trace above:`)
				)
				table.insert(lines, paint.trace_dim(table.concat(shared_lines, "\n")))
				table.insert(lines, "")
			end
		end

		local line_items = {}
		local function add_line_items(key: string, value: string): ()
			table.insert(line_items, `{paint.dim(key .. ":")} {value}`)
		end
		plugins.notify("add_line_items", run_result, options, add_line_items)

		table.insert(lines, title(`Status of {#pretty_results} test(s)`))
		table.insert(lines, "")

		if format == "tree" then
			local root = build_tree(pretty_results)
			for _, top_level_node in root.children do
				aggregate_tree(top_level_node)
				render_tree(top_level_node, 0, lines)
			end
		else
			for _, pretty in pretty_results do
				table.insert(lines, `{pretty.icon} {pretty.crumbs}{pretty.annotations}`)
			end
		end
		table.insert(lines, "")
		table.insert(
			lines,
			title(
				`{paint.pass(`{run_result.status_tally.pass} passed`)}, {paint.fail(
					`{run_result.status_tally.fail} failed`
				)}, {paint.dim(`{run_result.status_tally.skipped} skipped`)}`
			)
		)
		if #line_items > 0 then
			table.insert(lines, "")
			for _, line_item in line_items do
				table.insert(lines, line_item)
			end
			table.insert(lines, "")
			table.insert(lines, full_width_divider)
		end

		return table.concat(lines, "\n")
	end

	function self.after_run(run_result: RunResult, _): ()
		if options.disable_output and options.disable_output.after_run then
			return
		end
		print(self.format_run(run_result))
	end

	return self
end

return tiniest_pretty

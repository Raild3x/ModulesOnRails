//! Instrumentation: splice probe calls into source by pure text insertion.
//!
//! Existing bytes are never modified or reordered, so `const`, comments and
//! strings cannot be corrupted. Probe calls are inserted at full_moon byte
//! offsets; a per-file header binds the `_COV*` locals to the emitted runtime.

use crate::model::Probe;

struct Edit {
    offset: usize,
    order: i32,
    text: String,
}

// Emission order at a shared byte offset (lower = earlier in output). Wrapper
// nesting: at a shared START, outer (shallower) opens first; at a shared END,
// inner (deeper) closes first. Point inserts sit between closes and opens.
const ORDER_LOOP_INIT: i32 = 0; // `local __covLn = 0;` before the loop stmt
const ORDER_FN: i32 = 1; // fn-entry probe
const ORDER_STMT: i32 = 2; // statement / arm probe
const ORDER_LOOP_INC: i32 = 3; // `__covLn += 1;` at the loop body top
const ORDER_LOOP_EXIT: i32 = 5; // `; _COVL(n, __covLn)` after the loop stmt

fn loop_counter(id: u32) -> String {
    format!("__covL{}", id)
}

// A decision wraps the whole condition (depth 0); its operand conditions nest
// one level inside (depth 1).
fn wrapper_depth(kind: &str) -> i32 {
    match kind {
        "decision" => 0,
        _ => 1, // cond
    }
}

/// Splices probe calls into `src`. Statement/fn probes are point inserts;
/// decision/cond probes wrap their expression (open at start, `)` at end).
pub fn splice_file(src: &str, probes: &[Probe], line_starts: &[usize]) -> String {
    let mut edits: Vec<Edit> = Vec::with_capacity(probes.len());
    for p in probes {
        match p.kind {
            "decision" | "cond" => {
                let end = match p.end_byte {
                    Some(e) => e,
                    None => continue,
                };
                let depth = wrapper_depth(p.kind);
                let call = if p.kind == "decision" { "_COVD" } else { "_COVC" };
                // Open: shallower first (ascending). Close: deeper first, and
                // all closes precede point inserts and opens at the same offset.
                edits.push(Edit {
                    offset: p.byte,
                    order: 1000 + depth,
                    text: format!("{}({}, ", call, p.id),
                });
                edits.push(Edit {
                    offset: end,
                    order: -100 - depth,
                    text: ")".to_string(),
                });
            }
            "loop" => {
                let (body_byte, end) = match (p.body_byte, p.end_byte) {
                    (Some(b), Some(e)) => (b, e),
                    _ => continue,
                };
                let counter = loop_counter(p.id);
                // Per-entry counter, reset each time the loop is reached.
                edits.push(Edit {
                    offset: p.byte,
                    order: ORDER_LOOP_INIT,
                    text: format!("local {} = 0; ", counter),
                });
                // One increment per iteration, at the top of the body.
                edits.push(Edit {
                    offset: body_byte,
                    order: ORDER_LOOP_INC,
                    text: format!("{} += 1; ", counter),
                });
                // Classify the entry's iteration count (0 / 1 / many) after exit.
                edits.push(Edit {
                    offset: end,
                    order: ORDER_LOOP_EXIT,
                    text: format!("; _COVL({}, {})", p.id, counter),
                });
            }
            "fn" => edits.push(Edit {
                offset: p.byte,
                order: ORDER_FN,
                text: probe_text(p, src, line_starts),
            }),
            _ => edits.push(Edit {
                offset: p.byte,
                order: ORDER_STMT,
                text: probe_text(p, src, line_starts),
            }),
        }
    }
    // Build left-to-right; at equal offsets emit in `order`. Stable sort keeps
    // sibling wrappers (same depth, same offset) in source/allocation order.
    edits.sort_by(|a, b| a.offset.cmp(&b.offset).then(a.order.cmp(&b.order)));

    let mut out = String::with_capacity(src.len() + edits.len() * 16);
    let mut prev = 0usize;
    for e in &edits {
        out.push_str(&src[prev..e.offset]);
        out.push_str(&e.text);
        prev = e.offset;
    }
    out.push_str(&src[prev..]);
    out
}

fn probe_text(p: &Probe, src: &str, line_starts: &[usize]) -> String {
    if p.first_on_line && p.line >= 1 && p.line <= line_starts.len() {
        // The anchor is first on its line: the indentation already sits before
        // `byte`. Emit the probe on its own line, re-copying the indentation so
        // the original statement keeps its column.
        let indent = &src[line_starts[p.line - 1]..p.byte];
        format!("_COV({});\n{}", p.id, indent)
    } else {
        // Shares a line with earlier tokens: inline form. The trailing `;`
        // defuses the `(`-starts-a-call ambiguity.
        format!("_COV({}); ", p.id)
    }
}

/// The require path from a source file to the emitted `_cov` module, which sits
/// at `<source_root>/_cov.luau`. Uses Luau string-require semantics.
///
/// A root `init.luau` is special: it *represents* the source root directory, and
/// Roblox's instance-tree require resolves its `./` to the script's siblings (one
/// level above the directory it represents) rather than its children. `@self`
/// names "the directory this module represents" identically under both file and
/// instance semantics, so it is the only spelling that finds `_cov` in both
/// pipelines.
pub fn cov_require_path(rel: &str, source_root: &str) -> String {
    let prefix = format!("{}/", source_root);
    let within = rel.strip_prefix(&prefix).unwrap_or(rel);
    let depth = within.matches('/').count();
    let file_name = within.rsplit('/').next().unwrap_or(within);
    if depth == 0 {
        if file_name == "init.luau" || file_name == "init.lua" {
            "@self/_cov".to_string()
        } else {
            "./_cov".to_string()
        }
    } else {
        format!("{}_cov", "../".repeat(depth))
    }
}

/// The single header line prepended to each instrumented file.
pub fn header_line(cov_path: &str) -> String {
    format!(
        "local __covrt=require(\"{}\");local _COV=__covrt.cov;local _COVD=__covrt.covd;local _COVC=__covrt.covd;local _COVL=__covrt.covl; --!tm-coverage-instrumented\n",
        cov_path
    )
}

/// Source of the emitted `_cov.luau` runtime module.
pub fn cov_module(total_slots: u32, map_sha: &str) -> String {
    format!(
        r#"--!nocheck
-- Emitted by coverage-engine; do not edit.
local TOTAL = {total}
local hits = table.create(TOTAL, 0)
local rt = {{ hits = hits, total = TOTAL, map_sha = "{sha}" }}
function rt.cov(i) hits[i] += 1 end
function rt.covd(i, v) if v then hits[i] += 1 else hits[i + 1] += 1 end return v end
function rt.covl(i, n) if n == 0 then hits[i] += 1 elseif n == 1 then hits[i + 1] += 1 else hits[i + 2] += 1 end end
function rt.new_baseline() return table.create(TOTAL, 0) end
function rt.delta(prev)
	local changed = {{}}
	for i = 1, TOTAL do
		local h = hits[i]
		if h ~= prev[i] then
			table.insert(changed, i)
			prev[i] = h
		end
	end
	return changed
end
_G.__TM_COVERAGE_RT__ = rt
return rt
"#,
        total = total_slots,
        sha = map_sha
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::collect::Collector;
    use crate::parse;

    /// Collect + splice, as run_instrument does (minus the header).
    fn splice(src: &str, conditions: bool) -> String {
        let ast = parse::parse(src).expect("test source must parse");
        let line_starts = parse::line_starts(src);
        let mut c = Collector::new(src, line_starts.clone(), "src/t.luau".to_string(), 1, conditions);
        c.collect_ast(ast.nodes());
        let out = splice_file(src, &c.probes, &line_starts);
        // Everything we emit must survive the same verify pass the engine runs.
        let body = format!("{}{}", header_line("./_cov"), out);
        assert!(parse::parse(&body).is_ok(), "spliced output must re-parse:\n{}", body);
        out
    }

    #[test]
    fn first_on_line_probe_keeps_the_statement_column() {
        let out = splice("do\n\tlocal a = 1\nend\n", false);
        assert!(out.starts_with("_COV(1);\ndo\n"), "got:\n{}", out);
        assert!(out.contains("\t_COV(2);\n\tlocal a = 1"), "got:\n{}", out);
    }

    #[test]
    fn inline_probe_is_used_after_code_on_the_same_line() {
        let out = splice("local a = 1 local b = 2\n", false);
        assert!(out.contains("local a = 1 _COV(2); local b = 2"), "got:\n{}", out);
    }

    #[test]
    fn decision_wraps_the_condition() {
        let out = splice("if c then\n\tprint(1)\nend\n", false);
        assert!(out.contains("if _COVD(2, c) then"), "got:\n{}", out);
    }

    #[test]
    fn compound_condition_nests_cond_wrappers_inside_the_decision() {
        let out = splice("if a and b then\n\tprint(1)\nend\n", true);
        assert!(
            out.contains("if _COVD(2, _COVC(4, a) and _COVC(6, b)) then"),
            "got:\n{}",
            out
        );
    }

    #[test]
    fn loop_gets_init_increment_and_exit_splices() {
        let out = splice("for i = 1, 3 do\n\tprint(i)\nend\n", false);
        assert!(out.contains("local __covL3 = 0; "), "got:\n{}", out);
        assert!(out.contains("__covL3 += 1; "), "got:\n{}", out);
        assert!(out.contains("; _COVL(3, __covL3)"), "got:\n{}", out);
        // Init precedes the loop keyword; exit follows the loop's `end`.
        assert!(out.find("local __covL3").unwrap() < out.find("for i").unwrap());
        assert!(out.rfind("; _COVL(3").unwrap() > out.rfind("end").unwrap());
    }

    #[test]
    fn splice_is_deterministic() {
        let src = "if a and b then\n\tfor i = 1, 2 do\n\t\tprint(i)\n\tend\nend\n";
        assert_eq!(splice(src, true), splice(src, true));
    }

    #[test]
    fn cov_require_path_climbs_to_the_source_root() {
        // A root init represents the source root itself; `@self` is the only
        // spelling that resolves to its children in both pipelines.
        assert_eq!(cov_require_path("src/init.luau", "src"), "@self/_cov");
        assert_eq!(cov_require_path("src/root.luau", "src"), "./_cov");
        assert_eq!(cov_require_path("src/util/deep.luau", "src"), "../_cov");
        assert_eq!(cov_require_path("src/a/b/c.luau", "src"), "../../_cov");
    }

    #[test]
    fn header_line_binds_the_runtime_and_carries_the_marker() {
        let h = header_line("../_cov");
        assert!(h.contains("require(\"../_cov\")"));
        assert!(h.contains("--!tm-coverage-instrumented"));
        assert!(h.ends_with('\n'));
    }

    #[test]
    fn cov_module_embeds_totals_and_sha_and_parses() {
        let m = cov_module(7, "abc123");
        assert!(m.contains("local TOTAL = 7"));
        assert!(m.contains("map_sha = \"abc123\""));
        assert!(parse::parse(&m).is_ok());
    }
}

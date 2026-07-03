//! Serialized data model for `map.json` (schema `tm-coverage-map/1`).
//!
//! Dense integer probe ids are a runtime encoding only; cross-run stability is
//! carried by the `site` key (`<kind>:<relpath>:<line>:<col>`) plus the file
//! `sha256`. Kind strings are an open set so later metrics slot in without a
//! schema break.

use serde::Serialize;

pub const MAP_SCHEMA: &str = "tm-coverage-map/1";
pub const ENGINE_VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Serialize)]
pub struct CoverageMap {
    pub schema: &'static str,
    pub engine_version: &'static str,
    pub package: String,
    pub package_dir: String,
    pub generated_at: String,
    pub options: MapOptions,
    pub total_slots: u32,
    pub files: Vec<FileMap>,
}

#[derive(Serialize)]
pub struct MapOptions {
    pub conditions: bool,
    /// Const-candidate detection is opt-in; the field (and per-file
    /// `const_candidates`) is omitted when off so existing maps/goldens and the
    /// embedded map sha stay byte-identical.
    #[serde(skip_serializing_if = "is_false")]
    pub detect_const: bool,
}

fn is_false(b: &bool) -> bool {
    !*b
}

#[derive(Serialize)]
pub struct FileMap {
    pub path: String,
    pub sha256: String,
    pub original_lines: usize,
    pub probes: Vec<Probe>,
    pub gates: Vec<Gate>,
    pub dead: Vec<Dead>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub const_candidates: Vec<ConstCandidate>,
}

/// A `local` declaration (or `local function`) whose names are never
/// reassigned, so the statement could use `const`. Informational only — never
/// part of coverage denominators.
#[derive(Serialize, Clone)]
pub struct ConstCandidate {
    /// "local" | "local_function"
    pub kind: &'static str,
    /// Every name in the declaration (all must be clean for it to be emitted).
    pub names: Vec<String>,
    pub line: usize,
    pub col: usize,
    /// Cross-run-stable key: `const:<relpath>:<line>:<col>`.
    pub site: String,
}

/// One instrumentation site. `kind` ∈ { stmt, fn, decision, cond, arm, ... }.
/// Kind-specific fields are optional and omitted when absent.
#[derive(Serialize, Clone)]
pub struct Probe {
    pub id: u32,
    pub kind: &'static str,
    pub line: usize,
    pub col: usize,
    pub end_line: usize,
    /// 0-based byte offset of the site's anchor in the original source; the
    /// splice point used by `instrument`. For wrapper probes (decision/cond)
    /// this is the start of the wrapped expression.
    pub byte: usize,
    /// Whether the anchor is the first non-whitespace token on its line.
    pub first_on_line: bool,
    /// Enclosing function probe id, if any.
    #[serde(rename = "fn", skip_serializing_if = "Option::is_none")]
    pub fn_id: Option<u32>,
    pub site: String,

    // fn-specific
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub params: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_private: Option<bool>,

    // decision/cond-specific (wrapper probes)
    /// End byte of the wrapped expression (close-paren splice point). For a
    /// `loop` probe, the byte just after the loop statement (the `_COVL` splice).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub end_byte: Option<usize>,
    /// loop-specific: byte at the top of the loop body (per-iteration increment
    /// splice point).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub body_byte: Option<usize>,
    /// Slot recording the false outcome (== id + 1 for wrapper probes).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub false_id: Option<u32>,
    /// "if" | "elseif" | "while" | "repeat" for decisions.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ctx: Option<&'static str>,
    /// Whether an `if`/`elseif` decision has a matching `else` block.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub has_else: Option<bool>,
    /// Source text of the wrapped condition (for report snippets).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub src: Option<String>,
}

impl Probe {
    pub fn new(id: u32, kind: &'static str, line: usize, col: usize, end_line: usize, byte: usize, first_on_line: bool, rel_path: &str, fn_id: Option<u32>) -> Self {
        Probe {
            id,
            kind,
            line,
            col,
            end_line,
            byte,
            first_on_line,
            fn_id,
            site: format!("{}:{}:{}:{}", site_tag(kind), rel_path, line, col),
            name: None,
            params: None,
            is_private: None,
            end_byte: None,
            body_byte: None,
            false_id: None,
            ctx: None,
            has_else: None,
            src: None,
        }
    }
}

fn site_tag(kind: &str) -> &'static str {
    match kind {
        "stmt" => "stmt",
        "fn" => "fn",
        "decision" => "dec",
        "cond" => "cond",
        "arm" => "arm",
        "loop" => "loop",
        _ => "site",
    }
}

#[derive(Serialize, Clone)]
pub struct Gate {
    pub marker: String,
    pub note: String,
    pub line: usize,
    pub scope: [usize; 2],
}

/// A span the analyzer proved unreachable (statements after a terminal
/// `error(...)`, or the untaken arm of a constant condition). Excluded from the
/// denominators and reported separately. `scope` is an inclusive line range.
#[derive(Serialize, Clone)]
pub struct Dead {
    pub reason: String,
    pub scope: [usize; 2],
}

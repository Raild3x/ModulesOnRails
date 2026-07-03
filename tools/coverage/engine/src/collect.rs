//! Recursive AST walker producing coverage probes.
//!
//! M0 emits `stmt` and `fn` probes. The walker descends through every block —
//! including anonymous function bodies nested in expressions — so enclosing-
//! function context is always correct. Decision/arm/condition probes slot into
//! `collect_stmt` / dedicated hooks in later milestones.

use full_moon::ast::luau::{ConstAssignment, ConstFunction};
use full_moon::ast::{
    AnonymousFunction, Assignment, Block, Call, Expression, Field, FunctionArgs, FunctionBody,
    FunctionCall, FunctionDeclaration, FunctionName, LastStmt, LocalAssignment, LocalFunction,
    Parameter, Prefix, Stmt, Suffix, TableConstructor, Var, VarExpression,
};
use full_moon::node::Node;
use full_moon::tokenizer::{Position, TokenReference};

use crate::model::{Dead, Gate, Probe};
use crate::parse::first_on_line;

/// Environment gates: code the edit-mode Studio harness (run-in-roblox) cannot
/// reach, so an uncovered unit behind one reads as expected, not a test gap.
/// Detected on AST condition tokens (never comments/strings), and scoped to the
/// guarded arm so the whole gated body -- not just the marker line -- drops out.
const ENV_GATES: &[(&str, &str)] = &[
    (":IsRunning(", "RunService:IsRunning() is false in edit mode"),
    (":IsRunMode(", "RunService:IsRunMode() is false in edit mode"),
    (".Stepped:", "RunService.Stepped does not fire in edit mode"),
];

pub struct Collector<'s> {
    src: &'s str,
    line_starts: Vec<usize>,
    rel_path: String,
    pub probes: Vec<Probe>,
    pub gates: Vec<Gate>,
    pub dead: Vec<Dead>,
    next_id: u32,
    fn_stack: Vec<u32>,
    conditions: bool,
}

impl<'s> Collector<'s> {
    pub fn new(src: &'s str, line_starts: Vec<usize>, rel_path: String, start_id: u32, conditions: bool) -> Self {
        Collector {
            src,
            line_starts,
            rel_path,
            probes: Vec::new(),
            gates: Vec::new(),
            dead: Vec::new(),
            next_id: start_id,
            fn_stack: Vec::new(),
            conditions,
        }
    }

    /// The next dense id the collector would allocate (== 1 + last used).
    pub fn next_id(&self) -> u32 {
        self.next_id
    }

    fn alloc(&mut self) -> u32 {
        let id = self.next_id;
        self.next_id += 1;
        id
    }

    fn cur_fn(&self) -> Option<u32> {
        self.fn_stack.last().copied()
    }

    /// The true byte span of an expression, computed from min/max token
    /// positions. full_moon's end_position() undercounts for expressions ending
    /// in a delimiter token (e.g. `t[k]` stops before `]`).
    fn expr_span(&self, expr: &Expression) -> Option<(Position, usize, usize)> {
        let toks: Vec<&TokenReference> = expr.tokens().collect();
        let start = toks.first().and_then(|t| t.start_position())?;
        let end_byte = toks
            .iter()
            .filter_map(|t| t.end_position())
            .map(|p| p.bytes())
            .max()
            .unwrap_or_else(|| start.bytes());
        let end_line = toks
            .iter()
            .filter_map(|t| t.end_position())
            .map(|p| p.line())
            .max()
            .unwrap_or_else(|| start.line());
        Some((start, end_byte, end_line))
    }

    fn wrapper_probe(&mut self, kind: &'static str, start: Position, end_byte: usize, end_line: usize) -> u32 {
        let id = self.alloc();
        let _false_id = self.alloc(); // reserve id + 1
        let byte = start.bytes();
        let line = start.line();
        let col = start.character();
        let fol = first_on_line(self.src, byte, line, &self.line_starts);
        let mut probe = Probe::new(id, kind, line, col, end_line, byte, fol, &self.rel_path, self.cur_fn());
        probe.end_byte = Some(end_byte);
        probe.false_id = Some(id + 1);
        probe.src = Some(self.src.get(byte..end_byte).unwrap_or("").trim().to_string());
        self.probes.push(probe);
        id
    }

    /// Records a decision probe wrapping `cond` (two slots: true, false), then,
    /// if condition coverage is enabled and the condition is a compound
    /// and/or expression, a condition probe per leaf operand.
    fn push_decision(&mut self, cond: &Expression, ctx: &'static str, has_else: Option<bool>) {
        let (start, end_byte, end_line) = match self.expr_span(cond) {
            Some(s) => s,
            None => return,
        };
        self.wrapper_probe("decision", start, end_byte, end_line);
        if let Some(p) = self.probes.last_mut() {
            p.ctx = Some(ctx);
            p.has_else = has_else;
        }

        if self.conditions {
            let mut operands: Vec<&Expression> = Vec::new();
            collect_bool_operands(cond, &mut operands);
            if operands.len() >= 2 {
                for op in operands {
                    if let Some((s, eb, el)) = self.expr_span(op) {
                        self.wrapper_probe("cond", s, eb, el);
                    }
                }
            }
        }
    }

    /// If `cond` mentions an env-gate marker (scanning significant tokens only,
    /// so comments and strings never match), returns the marker, its note, and
    /// the condition's start line.
    fn condition_gate(&self, cond: &Expression) -> Option<(String, String, usize)> {
        let text: String = cond.tokens().map(|t| t.token().to_string()).collect();
        for (marker, note) in ENV_GATES {
            if text.contains(marker) {
                let line = self
                    .expr_span(cond)
                    .map(|(s, _, _)| s.line())
                    .or_else(|| cond.start_position().map(|p| p.line()))
                    .unwrap_or(0);
                return Some((marker.to_string(), note.to_string(), line));
            }
        }
        None
    }

    fn block_end_line(block: &Block) -> Option<usize> {
        block.tokens().filter_map(|t| t.end_position()).map(|p| p.line()).max()
    }

    /// Records a gate spanning the guarded arm: from the condition line through
    /// the last line of `block`, so the decision probe and every body site fall
    /// inside the scope.
    fn push_gate(&mut self, marker: String, note: String, cond_line: usize, block: &Block) {
        let end = Self::block_end_line(block).unwrap_or(cond_line).max(cond_line);
        self.gates.push(Gate { marker, note, line: cond_line, scope: [cond_line, end] });
    }

    fn push_probe(&mut self, kind: &'static str, anchor: Position, end_line: usize) -> u32 {
        let id = self.alloc();
        let byte = anchor.bytes();
        let line = anchor.line();
        let col = anchor.character();
        let fol = first_on_line(self.src, byte, line, &self.line_starts);
        let probe = Probe::new(id, kind, line, col, end_line, byte, fol, &self.rel_path, self.cur_fn());
        self.probes.push(probe);
        id
    }

    // -- entry ------------------------------------------------------------

    pub fn collect_ast(&mut self, block: &Block) {
        self.collect_block(block);
    }

    fn collect_block(&mut self, block: &Block) {
        let stmts: Vec<&Stmt> = block.stmts().collect();

        // Dead code: a terminal `error(...)` makes every later statement in this
        // block unreachable. (return/break/continue are Luau LastStmts, so they
        // can never be followed by more statements -- only error() can.)
        let terminal = stmts.iter().position(|s| is_terminal_error_stmt(s));

        for stmt in &stmts {
            self.collect_stmt(stmt);
        }
        if let Some(last) = block.last_stmt() {
            self.collect_last_stmt(last);
        }

        if let Some(ti) = terminal {
            let start = if ti + 1 < stmts.len() {
                stmts[ti + 1].start_position().map(|p| p.line())
            } else {
                block.last_stmt().and_then(|l| l.start_position()).map(|p| p.line())
            };
            if let Some(start) = start {
                let end = block
                    .tokens()
                    .filter_map(|t| t.end_position())
                    .map(|p| p.line())
                    .max()
                    .unwrap_or(start);
                self.push_dead(start, end, "unreachable after error(...)");
            }
        }
    }

    /// Emits a loop probe (3 slots: zero / one / many iterations) after
    /// collecting the body. `start` is the loop keyword; `end_byte`/`end_line`
    /// mark just past the loop's terminator (the `end` token, or the `until`
    /// condition for `repeat`) -- taken from the loop node itself, since
    /// `Stmt::end_position()` is unreliable for typed generic-for variables. The
    /// body's first statement probe marks where the per-iteration increment
    /// splices. Skips loops with an empty body (nothing to count).
    fn emit_loop(&mut self, ctx: &'static str, start: Position, end_byte: usize, end_line: usize, body: &Block) {
        let body_start_idx = self.probes.len();
        self.collect_block(body);
        let body_byte = self.probes[body_start_idx..]
            .iter()
            .find(|p| p.kind == "stmt")
            .map(|p| p.byte);
        let body_byte = match body_byte {
            Some(b) => b,
            None => return,
        };
        let id = self.alloc();
        self.alloc(); // id + 1 (exactly one iteration)
        self.alloc(); // id + 2 (many iterations)
        let byte = start.bytes();
        let line = start.line();
        let col = start.character();
        let fol = first_on_line(self.src, byte, line, &self.line_starts);
        let mut probe = Probe::new(id, "loop", line, col, end_line, byte, fol, &self.rel_path, self.cur_fn());
        probe.body_byte = Some(body_byte);
        probe.end_byte = Some(end_byte);
        probe.ctx = Some(ctx);
        self.probes.push(probe);
    }

    /// Byte-after and line of a loop's terminating `end` token.
    fn end_token_pos(t: &TokenReference) -> Option<(usize, usize)> {
        t.end_position().map(|p| (p.bytes(), p.line()))
    }

    fn push_dead(&mut self, start: usize, end: usize, reason: &str) {
        if end < start {
            return;
        }
        self.dead.push(Dead { reason: reason.to_string(), scope: [start, end] });
    }

    /// Marks a constant-condition arm dead: `if false then <A>` kills A;
    /// `if true then A else <B>` kills B (and any elseif arms); `while false`
    /// kills the loop body.
    fn mark_dead_block(&mut self, block: &Block, reason: &str) {
        if let Some((s, e)) = block_range(block) {
            self.push_dead(s, e, reason);
        }
    }

    fn collect_last_stmt(&mut self, last: &LastStmt) {
        if let (Some(start), Some(end)) = (last.start_position(), last.end_position()) {
            self.push_probe("stmt", start, end.line());
        }
        if let LastStmt::Return(ret) = last {
            for expr in ret.returns() {
                self.walk_expr(expr);
            }
        }
    }

    fn collect_stmt(&mut self, stmt: &Stmt) {
        // Executable statements get a stmt probe at their own anchor. Type-only
        // statements are erased at runtime, so they are neither probed nor
        // counted (they would be unhittable and inflate the denominator).
        if is_executable_stmt(stmt) {
            if let (Some(start), Some(end)) = (stmt.start_position(), stmt.end_position()) {
                self.push_probe("stmt", start, end.line());
            }
        }

        // Full span of a loop statement, for the loop probe's enclosing splices.
        let loop_span = match stmt {
            Stmt::NumericFor(_) | Stmt::GenericFor(_) | Stmt::While(_) | Stmt::Repeat(_) => {
                match (stmt.start_position(), stmt.end_position()) {
                    (Some(s), Some(e)) => Some((s, e)),
                    _ => None,
                }
            }
            _ => None,
        };

        match stmt {
            Stmt::FunctionDeclaration(decl) => self.collect_function_decl(decl),
            Stmt::LocalFunction(lf) => self.collect_local_function(lf),
            Stmt::ConstFunction(cf) => self.collect_const_function(cf),
            Stmt::Assignment(a) => self.collect_assignment(a),
            Stmt::LocalAssignment(la) => self.collect_local_assignment(la),
            Stmt::ConstAssignment(ca) => self.collect_const_assignment(ca),
            Stmt::If(if_stmt) => {
                let has_else = if_stmt.else_block().is_some();
                self.push_decision(if_stmt.condition(), "if", Some(has_else));
                if let Some((m, n, l)) = self.condition_gate(if_stmt.condition()) {
                    self.push_gate(m, n, l, if_stmt.block());
                }
                match const_bool(if_stmt.condition()) {
                    Some(false) => self.mark_dead_block(if_stmt.block(), "arm of a constant `if false`"),
                    Some(true) => {
                        // The then-arm always runs, so every alternative is dead.
                        if let Some(elseifs) = if_stmt.else_if() {
                            for ei in elseifs {
                                self.mark_dead_block(ei.block(), "unreachable after constant `if true`");
                            }
                        }
                        if let Some(eb) = if_stmt.else_block() {
                            self.mark_dead_block(eb, "else of a constant `if true`");
                        }
                    }
                    None => {}
                }
                self.walk_expr(if_stmt.condition());
                self.collect_block(if_stmt.block());
                if let Some(elseifs) = if_stmt.else_if() {
                    for ei in elseifs {
                        self.push_decision(ei.condition(), "elseif", Some(false));
                        if let Some((m, n, l)) = self.condition_gate(ei.condition()) {
                            self.push_gate(m, n, l, ei.block());
                        }
                        self.walk_expr(ei.condition());
                        self.collect_block(ei.block());
                    }
                }
                if let Some(else_block) = if_stmt.else_block() {
                    self.collect_block(else_block);
                }
            }
            Stmt::While(w) => {
                self.push_decision(w.condition(), "while", None);
                if let Some((m, n, l)) = self.condition_gate(w.condition()) {
                    self.push_gate(m, n, l, w.block());
                }
                if const_bool(w.condition()) == Some(false) {
                    self.mark_dead_block(w.block(), "body of a constant `while false`");
                }
                self.walk_expr(w.condition());
                match (loop_span, Self::end_token_pos(w.end_token())) {
                    (Some((s, _)), Some((eb, el))) => self.emit_loop("while", s, eb, el, w.block()),
                    _ => self.collect_block(w.block()),
                }
            }
            Stmt::Repeat(r) => {
                // repeat has no `end`; it terminates at the `until` condition.
                let repeat_end = self.expr_span(r.until()).map(|(_, eb, el)| (eb, el));
                match (loop_span, repeat_end) {
                    (Some((s, _)), Some((eb, el))) => self.emit_loop("repeat", s, eb, el, r.block()),
                    _ => self.collect_block(r.block()),
                }
                self.push_decision(r.until(), "repeat", None);
                if let Some((m, n, l)) = self.condition_gate(r.until()) {
                    self.push_gate(m, n, l, r.block());
                }
                self.walk_expr(r.until());
            }
            Stmt::NumericFor(nf) => match (loop_span, Self::end_token_pos(nf.end_token())) {
                (Some((s, _)), Some((eb, el))) => self.emit_loop("for", s, eb, el, nf.block()),
                _ => self.collect_block(nf.block()),
            },
            Stmt::GenericFor(gf) => match (loop_span, Self::end_token_pos(gf.end_token())) {
                (Some((s, _)), Some((eb, el))) => self.emit_loop("for", s, eb, el, gf.block()),
                _ => self.collect_block(gf.block()),
            },
            Stmt::Do(d) => self.collect_block(d.block()),
            Stmt::FunctionCall(fc) => self.walk_function_call(fc),
            Stmt::CompoundAssignment(ca) => self.walk_expr(ca.rhs()),
            _ => {} // type declarations etc.: no executable sub-blocks in v1
        }
    }

    // -- functions --------------------------------------------------------

    fn body_anchor(body: &FunctionBody) -> Option<(Position, usize)> {
        if let Some(first) = body.block().stmts().next() {
            first.start_position().map(|p| (p, p.line()))
        } else if let Some(last) = body.block().last_stmt() {
            last.start_position().map(|p| (p, p.line()))
        } else {
            let t = body.end_token();
            t.start_position().map(|p| (p, p.line()))
        }
    }

    fn enter_function(&mut self, name: Option<String>, is_private: bool, body: &FunctionBody) {
        if let Some((anchor, end_line)) = Self::body_anchor(body) {
            let id = self.push_probe("fn", anchor, end_line);
            if let Some(p) = self.probes.last_mut() {
                p.name = name;
                p.params = Some(param_names(body));
                p.is_private = Some(is_private);
            }
            self.fn_stack.push(id);
            self.collect_block(body.block());
            self.fn_stack.pop();
        } else {
            self.collect_block(body.block());
        }
    }

    fn collect_function_decl(&mut self, decl: &FunctionDeclaration) {
        let (name, is_private) = function_name_str(decl.name());
        self.enter_function(Some(name), is_private, decl.body());
    }

    fn collect_local_function(&mut self, lf: &LocalFunction) {
        let name = token_text(lf.name());
        let is_private = true; // local binding
        self.enter_function(Some(format!("local {}", name)), is_private, lf.body());
    }

    fn collect_const_function(&mut self, cf: &ConstFunction) {
        let name = token_text(cf.name());
        self.enter_function(Some(format!("const {}", name)), true, cf.body());
    }

    fn collect_assignment(&mut self, a: &Assignment) {
        let vars: Vec<&Var> = a.variables().iter().collect();
        for (i, expr) in a.expressions().iter().enumerate() {
            let lhs_name = vars.get(i).map(|v| var_name(v));
            self.collect_valued_expr(expr, lhs_name);
        }
    }

    fn collect_local_assignment(&mut self, la: &LocalAssignment) {
        let names: Vec<String> = la.names().iter().map(token_text).collect();
        for (i, expr) in la.expressions().iter().enumerate() {
            let n = names.get(i).map(|s| format!("local {}", s));
            self.collect_valued_expr(expr, n);
        }
    }

    fn collect_const_assignment(&mut self, ca: &ConstAssignment) {
        let names: Vec<String> = ca.names().iter().map(token_text).collect();
        for (i, expr) in ca.expressions().iter().enumerate() {
            let n = names.get(i).map(|s| format!("const {}", s));
            self.collect_valued_expr(expr, n);
        }
    }

    /// An RHS expression that has a known binding name — if it is a function,
    /// name the function after the binding; otherwise walk it generically.
    fn collect_valued_expr(&mut self, expr: &Expression, name: Option<String>) {
        if let Expression::Function(anon) = expr {
            let is_private = name.as_deref().map(is_private_name).unwrap_or(true);
            self.enter_function(name, is_private, anon.body());
        } else {
            self.walk_expr(expr);
        }
    }

    // -- expression walk (find nested/anonymous functions) ----------------

    fn walk_anonymous(&mut self, anon: &AnonymousFunction) {
        self.enter_function(None, true, anon.body());
    }

    fn walk_expr(&mut self, expr: &Expression) {
        match expr {
            Expression::Function(anon) => self.walk_anonymous(anon),
            Expression::BinaryOperator { lhs, rhs, .. } => {
                self.walk_expr(lhs);
                self.walk_expr(rhs);
            }
            Expression::Parentheses { expression, .. } => self.walk_expr(expression),
            Expression::UnaryOperator { expression, .. } => self.walk_expr(expression),
            Expression::TypeAssertion { expression, .. } => self.walk_expr(expression),
            Expression::FunctionCall(fc) => self.walk_function_call(fc),
            Expression::TableConstructor(tc) => self.walk_table(tc),
            Expression::Var(v) => self.walk_var(v),
            _ => {} // Number/String/Symbol/If/InterpolatedString: no nested blocks in v1
        }
    }

    fn walk_var(&mut self, v: &Var) {
        if let Var::Expression(ve) = v {
            self.walk_var_expression(ve);
        }
    }

    fn walk_var_expression(&mut self, ve: &VarExpression) {
        self.walk_prefix(ve.prefix());
        for s in ve.suffixes() {
            self.walk_suffix(s);
        }
    }

    fn walk_function_call(&mut self, fc: &FunctionCall) {
        self.walk_prefix(fc.prefix());
        for s in fc.suffixes() {
            self.walk_suffix(s);
        }
    }

    fn walk_prefix(&mut self, prefix: &Prefix) {
        if let Prefix::Expression(e) = prefix {
            self.walk_expr(e);
        }
    }

    fn walk_suffix(&mut self, suffix: &Suffix) {
        match suffix {
            Suffix::Call(call) => match call {
                Call::AnonymousCall(args) => self.walk_function_args(args),
                Call::MethodCall(mc) => self.walk_function_args(mc.args()),
                _ => {}
            },
            Suffix::Index(idx) => {
                // Index::Brackets holds an expression (e.g. t[f()])
                if let full_moon::ast::Index::Brackets { expression, .. } = idx {
                    self.walk_expr(expression);
                }
            }
            _ => {}
        }
    }

    fn walk_function_args(&mut self, args: &FunctionArgs) {
        match args {
            FunctionArgs::Parentheses { arguments, .. } => {
                for e in arguments {
                    self.walk_expr(e);
                }
            }
            FunctionArgs::TableConstructor(tc) => self.walk_table(tc),
            _ => {}
        }
    }

    fn walk_table(&mut self, tc: &TableConstructor) {
        for field in tc.fields() {
            match field {
                Field::ExpressionKey { key, value, .. } => {
                    self.walk_expr(key);
                    self.walk_expr(value);
                }
                Field::NameKey { value, .. } => self.walk_expr(value),
                Field::NoKey(e) => self.walk_expr(e),
                _ => {}
            }
        }
    }
}

/// Decomposes a boolean condition into its leaf operands by splitting on
/// `and`/`or` (descending through parentheses). `not X`, comparisons, calls and
/// atoms are leaves. Produces operands in source order.
fn collect_bool_operands<'a>(expr: &'a Expression, out: &mut Vec<&'a Expression>) {
    match expr {
        Expression::BinaryOperator { lhs, binop, rhs } => {
            let op = binop.token().token().to_string();
            if op == "and" || op == "or" {
                collect_bool_operands(lhs, out);
                collect_bool_operands(rhs, out);
            } else {
                out.push(expr);
            }
        }
        Expression::Parentheses { expression, .. } => collect_bool_operands(expression, out),
        _ => out.push(expr),
    }
}

/// Whether `stmt` is a bare `error(...)` call -- an unconditional throw, after
/// which the rest of the block is unreachable.
fn is_terminal_error_stmt(stmt: &Stmt) -> bool {
    if let Stmt::FunctionCall(fc) = stmt {
        if let Prefix::Name(t) = fc.prefix() {
            if t.token().to_string() == "error" {
                return matches!(fc.suffixes().next(), Some(Suffix::Call(_)));
            }
        }
    }
    false
}

/// The boolean value of a constant condition (`true`/`false`, through parens),
/// or None if it is not a literal boolean.
fn const_bool(expr: &Expression) -> Option<bool> {
    match expr {
        Expression::Symbol(t) => match t.token().to_string().trim() {
            "true" => Some(true),
            "false" => Some(false),
            _ => None,
        },
        Expression::Parentheses { expression, .. } => const_bool(expression),
        _ => None,
    }
}

/// Inclusive first/last source line spanned by a block's significant tokens, or
/// None for an empty block.
fn block_range(block: &Block) -> Option<(usize, usize)> {
    let mut min = usize::MAX;
    let mut max = 0usize;
    for t in block.tokens() {
        if let Some(p) = t.start_position() {
            min = min.min(p.line());
        }
        if let Some(p) = t.end_position() {
            max = max.max(p.line());
        }
    }
    if max == 0 {
        None
    } else {
        Some((min, max))
    }
}

/// Type declarations (`type`, `export type`, `type function`) are erased at
/// runtime and are not executable, so they receive no statement probe.
fn is_executable_stmt(stmt: &Stmt) -> bool {
    !matches!(
        stmt,
        Stmt::TypeDeclaration(_)
            | Stmt::ExportedTypeDeclaration(_)
            | Stmt::TypeFunction(_)
            | Stmt::ExportedTypeFunction(_)
    )
}

// -- naming helpers -------------------------------------------------------

fn token_text(t: &TokenReference) -> String {
    t.token().to_string()
}

fn is_private_name(name: &str) -> bool {
    // strip a "local "/"const " prefix, then look at the last dotted/colon segment
    let core = name
        .strip_prefix("local ")
        .or_else(|| name.strip_prefix("const "))
        .unwrap_or(name);
    if name.starts_with("local ") || name.starts_with("const ") {
        return true;
    }
    let last = core.rsplit(['.', ':']).next().unwrap_or(core);
    last.starts_with('_')
}

fn function_name_str(name: &FunctionName) -> (String, bool) {
    let parts: Vec<String> = name.names().iter().map(token_text).collect();
    let joined = parts.join(".");
    if let Some(method) = name.method_name() {
        let m = token_text(method);
        let is_private = m.starts_with('_');
        (format!("{}:{}", joined, m), is_private)
    } else {
        let is_private = parts.last().map(|s| s.starts_with('_')).unwrap_or(false);
        (joined, is_private)
    }
}

/// Build a name from a node's significant tokens (excludes leading/trailing
/// trivia such as doc comments, which `Display` would otherwise splice in).
fn node_token_name<N: Node>(n: &N) -> String {
    n.tokens().map(|t| t.token().to_string()).collect::<String>()
}

fn var_name(v: &Var) -> String {
    match v {
        Var::Name(t) => token_text(t),
        _ => node_token_name(v),
    }
}

fn param_names(body: &FunctionBody) -> Vec<String> {
    body.parameters()
        .iter()
        .map(|p| match p {
            Parameter::Name(t) => token_text(t),
            Parameter::Ellipsis(_) => "...".to_string(),
            _ => format!("{}", p).trim().to_string(),
        })
        .collect()
}

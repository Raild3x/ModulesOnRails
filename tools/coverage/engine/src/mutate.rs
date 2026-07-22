//! Mutation-testing support: enumerate mutation sites from the AST and apply
//! a single mutant by byte-range replacement.
//!
//! Enumeration walks value expressions only, so type annotations, strings and
//! comments can never yield a mutant. Application follows the instrument.rs
//! discipline — read, edit, reassemble, **reparse** — but replaces bytes
//! instead of inserting, so it lives behind its own sha guard: the target
//! file's hash must match what enumeration recorded, or the mutant tables are
//! stale.
//!
//! Operator set v1 (one mutant per site):
//!   ror  `==`<->`~=`, `<`<->`<=`, `>`<->`>=`
//!   lor  `and`<->`or`
//!   aor  `+`<->`-`, `*`<->`/`     (`..`, `//`, `%`, `^`, unary `-` skipped)
//!   not  `not X` -> `X`
//!   lit  `true`<->`false`; number `0`->`1`, otherwise ->`0`

use std::path::Path;

use full_moon::ast::luau::ConstAssignment;
use full_moon::ast::{
    Assignment, Block, Call, Expression, Field, FunctionArgs, FunctionBody, FunctionCall,
    FunctionDeclaration, LastStmt, LocalAssignment, Prefix, Stmt, Suffix, TableConstructor, UnOp,
    Var, VarExpression,
};
use full_moon::node::Node;
use full_moon::tokenizer::TokenReference;
use serde::{Deserialize, Serialize};

use crate::parse;

pub const MUTANTS_SCHEMA: &str = "tm-coverage-mutants/1";

#[derive(Serialize, Deserialize, Clone)]
pub struct Mutant {
    pub id: u32,
    pub op: String,
    pub line: usize,
    pub col: usize,
    /// Byte range of the replaced token(s) in the original source.
    pub byte_start: usize,
    pub byte_end: usize,
    pub original: String,
    pub replacement: String,
    /// Cross-run-stable key: `mut:<op>:<relpath>:<line>:<col>`.
    pub site: String,
}

#[derive(Serialize, Deserialize)]
pub struct MutantFile {
    pub path: String,
    /// sha256 of the file enumeration saw; apply refuses on mismatch.
    pub sha256: String,
    pub mutants: Vec<Mutant>,
}

#[derive(Serialize, Deserialize)]
pub struct MutantsDoc {
    pub schema: String,
    pub engine_version: String,
    pub package: String,
    pub total: u32,
    pub files: Vec<MutantFile>,
}

/// Enumerates every mutant in a parsed file, allocating dense ids from
/// `start_id`. Returns the mutants and the next free id.
pub fn collect_file(block: &Block, rel_path: &str, start_id: u32) -> (Vec<Mutant>, u32) {
    let mut c = MutantCollector { rel_path, next_id: start_id, mutants: Vec::new() };
    c.walk_block(block);
    let next = c.next_id;
    (c.mutants, next)
}

/// The pure splice: replaces the mutant's byte range and verifies both the
/// span contents and that the result still parses.
pub fn apply_to_src(src: &str, m: &Mutant) -> Result<String, (i32, String)> {
    let span = src.get(m.byte_start..m.byte_end);
    if span != Some(m.original.as_str()) {
        return Err((
            1,
            format!(
                "span mismatch for mutant {} (expected {:?}, found {:?}) -- stale mutants.json?",
                m.id,
                m.original,
                span.unwrap_or("<out of range>")
            ),
        ));
    }
    let mutated = format!("{}{}{}", &src[..m.byte_start], m.replacement, &src[m.byte_end..]);
    if let Err(errs) = parse::parse(&mutated) {
        let msg = errs.iter().map(|e| e.to_string()).collect::<Vec<_>>().join("; ");
        return Err((3, format!("mutant {} does not parse: {}", m.id, msg)));
    }
    Ok(mutated)
}

/// Applies mutant `id` in place under `root`, guarded by the recorded sha.
pub fn apply(doc: &MutantsDoc, id: u32, root: &Path) -> Result<String, (i32, String)> {
    let (file, mutant) = doc
        .files
        .iter()
        .find_map(|f| f.mutants.iter().find(|m| m.id == id).map(|m| (f, m)))
        .ok_or_else(|| (1, format!("no mutant with id {}", id)))?;

    let path = root.join(&file.path);
    let src = std::fs::read_to_string(&path).map_err(|e| (1, format!("cannot read {}: {}", path.display(), e)))?;
    let sha = parse::sha256_hex(src.as_bytes());
    if sha != file.sha256 {
        return Err((1, format!("sha mismatch for {} -- stale mutants.json or unrestored mutant?", file.path)));
    }

    let mutated = apply_to_src(&src, mutant)?;
    std::fs::write(&path, mutated).map_err(|e| (1, format!("cannot write {}: {}", path.display(), e)))?;
    Ok(file.path.clone())
}

fn binop_swap(text: &str) -> Option<(&'static str, &'static str)> {
    Some(match text {
        "==" => ("ror", "~="),
        "~=" => ("ror", "=="),
        "<" => ("ror", "<="),
        "<=" => ("ror", "<"),
        ">" => ("ror", ">="),
        ">=" => ("ror", ">"),
        "and" => ("lor", "or"),
        "or" => ("lor", "and"),
        "+" => ("aor", "-"),
        "-" => ("aor", "+"),
        "*" => ("aor", "/"),
        "/" => ("aor", "*"),
        _ => return None,
    })
}

struct MutantCollector<'s> {
    rel_path: &'s str,
    next_id: u32,
    mutants: Vec<Mutant>,
}

impl<'s> MutantCollector<'s> {
    fn push(&mut self, op: &'static str, tok: &TokenReference, replacement: String) {
        let (start, end) = match (tok.start_position(), tok.end_position()) {
            (Some(s), Some(e)) => (s, e),
            _ => return,
        };
        let id = self.next_id;
        self.next_id += 1;
        self.mutants.push(Mutant {
            id,
            op: op.to_string(),
            line: start.line(),
            col: start.character(),
            byte_start: start.bytes(),
            byte_end: end.bytes(),
            original: tok.token().to_string(),
            replacement,
            site: format!("mut:{}:{}:{}:{}", op, self.rel_path, start.line(), start.character()),
        });
    }

    // -- statements ---------------------------------------------------------

    fn walk_block(&mut self, block: &Block) {
        for stmt in block.stmts() {
            self.walk_stmt(stmt);
        }
        if let Some(LastStmt::Return(ret)) = block.last_stmt() {
            for expr in ret.returns() {
                self.walk_expr(expr);
            }
        }
    }

    fn walk_stmt(&mut self, stmt: &Stmt) {
        match stmt {
            Stmt::LocalAssignment(la) => self.local_assignment(la),
            Stmt::ConstAssignment(ca) => self.const_assignment(ca),
            Stmt::Assignment(a) => self.assignment(a),
            Stmt::CompoundAssignment(ca) => {
                self.walk_write_var(ca.lhs());
                self.walk_expr(ca.rhs());
            }
            Stmt::LocalFunction(lf) => self.function_body(lf.body()),
            Stmt::ConstFunction(cf) => self.function_body(cf.body()),
            Stmt::FunctionDeclaration(fd) => self.function_decl(fd),
            Stmt::FunctionCall(fc) => self.walk_function_call(fc),
            Stmt::Do(d) => self.walk_block(d.block()),
            Stmt::If(if_stmt) => {
                self.walk_expr(if_stmt.condition());
                self.walk_block(if_stmt.block());
                if let Some(elseifs) = if_stmt.else_if() {
                    for ei in elseifs {
                        self.walk_expr(ei.condition());
                        self.walk_block(ei.block());
                    }
                }
                if let Some(else_block) = if_stmt.else_block() {
                    self.walk_block(else_block);
                }
            }
            Stmt::While(w) => {
                self.walk_expr(w.condition());
                self.walk_block(w.block());
            }
            Stmt::Repeat(r) => {
                self.walk_block(r.block());
                self.walk_expr(r.until());
            }
            Stmt::NumericFor(nf) => {
                self.walk_expr(nf.start());
                self.walk_expr(nf.end());
                if let Some(step) = nf.step() {
                    self.walk_expr(step);
                }
                self.walk_block(nf.block());
            }
            Stmt::GenericFor(gf) => {
                for expr in gf.expressions() {
                    self.walk_expr(expr);
                }
                self.walk_block(gf.block());
            }
            _ => {} // type declarations etc.: no value expressions
        }
    }

    fn local_assignment(&mut self, la: &LocalAssignment) {
        for expr in la.expressions() {
            self.walk_expr(expr);
        }
    }

    fn const_assignment(&mut self, ca: &ConstAssignment) {
        for expr in ca.expressions() {
            self.walk_expr(expr);
        }
    }

    fn assignment(&mut self, a: &Assignment) {
        for var in a.variables() {
            self.walk_write_var(var);
        }
        for expr in a.expressions() {
            self.walk_expr(expr);
        }
    }

    /// An assignment target: only its computed parts (bracket indices, call
    /// prefixes) contain value expressions.
    fn walk_write_var(&mut self, var: &Var) {
        if let Var::Expression(ve) = var {
            self.walk_var_expression(ve);
        }
    }

    fn function_decl(&mut self, fd: &FunctionDeclaration) {
        self.function_body(fd.body());
    }

    fn function_body(&mut self, body: &FunctionBody) {
        self.walk_block(body.block());
    }

    // -- expressions ----------------------------------------------------------

    fn walk_expr(&mut self, expr: &Expression) {
        match expr {
            Expression::BinaryOperator { lhs, binop, rhs } => {
                let tok = binop.token();
                if let Some((op, repl)) = binop_swap(tok.token().to_string().as_str()) {
                    self.push(op, tok, repl.to_string());
                }
                self.walk_expr(lhs);
                self.walk_expr(rhs);
            }
            Expression::UnaryOperator { unop, expression } => {
                if let UnOp::Not(tok) = unop {
                    self.push("not", tok, String::new());
                }
                self.walk_expr(expression);
            }
            Expression::Symbol(tok) => {
                let text = tok.token().to_string();
                match text.trim() {
                    "true" => self.push("lit", tok, "false".to_string()),
                    "false" => self.push("lit", tok, "true".to_string()),
                    _ => {}
                }
            }
            Expression::Number(tok) => {
                let text = tok.token().to_string();
                let repl = if text.trim() == "0" { "1" } else { "0" };
                self.push("lit", tok, repl.to_string());
            }
            Expression::Function(anon) => self.function_body(anon.body()),
            Expression::Parentheses { expression, .. } => self.walk_expr(expression),
            Expression::TypeAssertion { expression, .. } => self.walk_expr(expression),
            Expression::FunctionCall(fc) => self.walk_function_call(fc),
            Expression::TableConstructor(tc) => self.walk_table(tc),
            Expression::Var(v) => {
                if let Var::Expression(ve) = v {
                    self.walk_var_expression(ve);
                }
            }
            Expression::IfExpression(ie) => {
                self.walk_expr(ie.condition());
                self.walk_expr(ie.if_expression());
                if let Some(elseifs) = ie.else_if_expressions() {
                    for ei in elseifs {
                        self.walk_expr(ei.condition());
                        self.walk_expr(ei.expression());
                    }
                }
                self.walk_expr(ie.else_expression());
            }
            Expression::InterpolatedString(is) => {
                for e in is.expressions() {
                    self.walk_expr(e);
                }
            }
            _ => {} // String: never mutated
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parse;

    fn muts(src: &str) -> Vec<Mutant> {
        let ast = parse::parse(src).expect("test source must parse");
        let (mutants, _) = collect_file(ast.nodes(), "src/t.luau", 1);
        mutants
    }

    fn pairs(src: &str) -> Vec<(String, String)> {
        muts(src).into_iter().map(|m| (m.original, m.replacement)).collect()
    }

    #[test]
    fn relational_operators_swap_with_their_boundary_partner() {
        assert_eq!(pairs("return a == b\n"), vec![("==".into(), "~=".into())]);
        assert_eq!(pairs("return a ~= b\n"), vec![("~=".into(), "==".into())]);
        assert_eq!(pairs("return a < b\n"), vec![("<".into(), "<=".into())]);
        assert_eq!(pairs("return a <= b\n"), vec![("<=".into(), "<".into())]);
        assert_eq!(pairs("return a > b\n"), vec![(">".into(), ">=".into())]);
        assert_eq!(pairs("return a >= b\n"), vec![(">=".into(), ">".into())]);
    }

    #[test]
    fn logical_and_arithmetic_operators_swap() {
        assert_eq!(pairs("return a and b\n"), vec![("and".into(), "or".into())]);
        assert_eq!(pairs("return a or b\n"), vec![("or".into(), "and".into())]);
        assert_eq!(pairs("return a + b\n"), vec![("+".into(), "-".into())]);
        assert_eq!(pairs("return a * b\n"), vec![("*".into(), "/".into())]);
    }

    #[test]
    fn concat_modulo_power_and_unary_minus_are_skipped() {
        assert!(muts("return a .. b\n").is_empty());
        assert!(muts("return a % b\n").is_empty());
        assert!(muts("return a ^ b\n").is_empty());
        assert!(muts("return -a\n").is_empty());
    }

    #[test]
    fn not_is_dropped_and_booleans_flip() {
        let m = muts("return not a\n");
        assert_eq!(m.len(), 1);
        assert_eq!(m[0].op, "not");
        assert_eq!(m[0].original, "not");
        assert_eq!(m[0].replacement, "");

        assert_eq!(pairs("return true\n"), vec![("true".into(), "false".into())]);
        assert_eq!(pairs("return false\n"), vec![("false".into(), "true".into())]);
    }

    #[test]
    fn numbers_mutate_to_zero_and_zero_to_one() {
        assert_eq!(pairs("return 5\n"), vec![("5".into(), "0".into())]);
        assert_eq!(pairs("return 0\n"), vec![("0".into(), "1".into())]);
        assert_eq!(pairs("return 0x10\n"), vec![("0x10".into(), "0".into())]);
    }

    #[test]
    fn type_annotations_strings_and_comments_yield_no_mutants() {
        // Only the value `1` is a site; the annotation, string and comment are not.
        let m = muts("local x: number = 1\nlocal s = \"a + b\" -- c < d\n");
        assert_eq!(m.len(), 1);
        assert_eq!(m[0].original, "1");
        // Type-only statements carry no sites at all.
        assert!(muts("type T = { n: number }\nexport type U = number\n").is_empty());
    }

    #[test]
    fn byte_spans_slice_the_original_token_exactly() {
        let src = "if a <= b and not c then\n\treturn a + 1\nend\n";
        for m in muts(src) {
            assert_eq!(&src[m.byte_start..m.byte_end], m.original, "span of {}", m.site);
        }
    }

    #[test]
    fn every_mutant_reparses_when_applied() {
        let src = "local M = {}\nfunction M.go(n: number): number\n\tif n > 0 and n ~= 5 then\n\t\treturn n - 1\n\tend\n\twhile not M.done do\n\t\tn += 2 * n\n\tend\n\treturn if n == 0 then 0 else n\nend\nreturn M\n";
        let mutants = muts(src);
        assert!(mutants.len() >= 8, "expected a rich mutant set, got {}", mutants.len());
        for m in &mutants {
            let mutated = apply_to_src(src, m).unwrap_or_else(|e| panic!("{} failed: {:?}", m.site, e));
            assert_ne!(mutated, src, "{} must change the source", m.site);
        }
    }

    #[test]
    fn ids_are_dense_and_sites_stable_across_runs() {
        let src = "return a < b and c + 1 or not d\n";
        let a = muts(src);
        let b = muts(src);
        let ids: Vec<u32> = a.iter().map(|m| m.id).collect();
        assert_eq!(ids, (1..=a.len() as u32).collect::<Vec<_>>());
        let sa: Vec<&str> = a.iter().map(|m| m.site.as_str()).collect();
        let sb: Vec<&str> = b.iter().map(|m| m.site.as_str()).collect();
        assert_eq!(sa, sb);
        assert!(sa.iter().all(|s| s.starts_with("mut:")));
    }

    #[test]
    fn a_second_file_continues_id_allocation() {
        let ast = parse::parse("return 1\n").unwrap();
        let (first, next) = collect_file(ast.nodes(), "src/a.luau", 1);
        assert_eq!(first.len(), 1);
        let (second, _) = collect_file(ast.nodes(), "src/b.luau", next);
        assert_eq!(second[0].id, next);
    }

    #[test]
    fn apply_rejects_a_stale_span() {
        let src = "return a + b\n";
        let mut m = muts(src).remove(0);
        m.byte_start += 1;
        m.byte_end += 1;
        let err = apply_to_src(src, &m).unwrap_err();
        assert_eq!(err.0, 1);
        assert!(err.1.contains("span mismatch"));
    }

    #[test]
    fn conditions_inside_loops_calls_and_tables_are_reached() {
        let m = muts("for i = 1, n - 1 do\n\tf({ ok = x > 0 }, t[i + 1])\nend\nrepeat\n\tg()\nuntil a or b\n");
        let ops: Vec<&str> = m.iter().map(|x| x.op.as_str()).collect();
        // n - 1 (aor), 1 twice? -> lit for `1`s, x > 0 (ror), i + 1 (aor), a or b (lor)
        assert!(ops.contains(&"aor"));
        assert!(ops.contains(&"ror"));
        assert!(ops.contains(&"lor"));
        assert!(ops.contains(&"lit"));
    }
}

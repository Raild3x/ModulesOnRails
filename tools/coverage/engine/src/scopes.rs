//! Const-candidate analysis: `local` declarations (including `local function`)
//! whose names are never reassigned, so the statement could use `const`.
//!
//! A standalone second pass over the AST, deliberately separate from
//! `Collector`: its walk order and id allocation are pinned by golden files,
//! so this walker carries zero risk to instrumentation. Reassignment in Luau
//! can only happen in `Assignment` / `CompoundAssignment` statements (plus the
//! `function f()` sugar for `f = function() end`), which makes this a pure
//! statement walk over a lexical scope stack.
//!
//! Scope rules: one scope per block; bindings take effect in statement order
//! (no hoisting), and a `local`'s RHS is walked before its names bind, so
//! `local x = x` reads the outer `x`. Function bodies push onto the same
//! stack, so a closure writing an upvalue resolves lexically to the outer
//! declaration and disqualifies it. Interior mutation (`t.x = 1`, `t[k] += v`)
//! is a read of the base name — `const` forbids rebinding, not mutation.

use std::collections::HashMap;

use full_moon::ast::luau::{ConstAssignment, ConstFunction};
use full_moon::ast::{
    Assignment, Block, Call, Expression, Field, FunctionArgs, FunctionBody, FunctionCall,
    FunctionDeclaration, GenericFor, LastStmt, LocalAssignment, LocalFunction, NumericFor,
    Parameter, Prefix, Stmt, Suffix, TableConstructor, Var, VarExpression,
};
use full_moon::node::Node;
use full_moon::tokenizer::TokenReference;

use crate::model::ConstCandidate;

/// Scans a parsed file and returns its const candidates in source order.
pub fn scan(block: &Block, rel_path: &str) -> Vec<ConstCandidate> {
    let mut s = ConstScan {
        rel_path: rel_path.to_string(),
        decls: Vec::new(),
        scopes: Vec::new(),
    };
    s.enter_scope();
    s.walk_block(block);
    s.exit_scope();
    s.emit()
}

/// One binding statement (or param list / loop-var list). `eligible` is false
/// for anything that can never become `const`: params, loop vars, existing
/// `const`s, and initializer-less locals — they are tracked only so shadow
/// resolution stays correct.
struct Decl {
    kind: &'static str,
    names: Vec<String>,
    reassigned: Vec<bool>,
    eligible: bool,
    line: usize,
    col: usize,
}

struct ConstScan {
    rel_path: String,
    decls: Vec<Decl>,
    /// name -> (decl index, name index within the decl), innermost last.
    scopes: Vec<HashMap<String, (usize, usize)>>,
}

impl ConstScan {
    fn enter_scope(&mut self) {
        self.scopes.push(HashMap::new());
    }

    fn exit_scope(&mut self) {
        self.scopes.pop();
    }

    fn push_and_bind(&mut self, kind: &'static str, names: Vec<String>, eligible: bool, line: usize, col: usize) {
        let idx = self.decls.len();
        let scope = self.scopes.last_mut().expect("binding outside any scope");
        for (i, n) in names.iter().enumerate() {
            scope.insert(n.clone(), (idx, i));
        }
        let reassigned = vec![false; names.len()];
        self.decls.push(Decl { kind, names, reassigned, eligible, line, col });
    }

    fn resolve(&self, name: &str) -> Option<(usize, usize)> {
        for scope in self.scopes.iter().rev() {
            if let Some(&hit) = scope.get(name) {
                return Some(hit);
            }
        }
        None
    }

    /// Marks a write to `name`. Unresolved names are globals: ignored.
    fn mark_reassigned(&mut self, name: &str) {
        if let Some((d, i)) = self.resolve(name) {
            self.decls[d].reassigned[i] = true;
        }
    }

    fn emit(self) -> Vec<ConstCandidate> {
        let ConstScan { rel_path, decls, .. } = self;
        let mut out: Vec<ConstCandidate> = decls
            .into_iter()
            .filter(|d| d.eligible && d.reassigned.iter().all(|r| !r))
            .map(|d| ConstCandidate {
                kind: d.kind,
                site: format!("const:{}:{}:{}", rel_path, d.line, d.col),
                names: d.names,
                line: d.line,
                col: d.col,
            })
            .collect();
        out.sort_by_key(|c| (c.line, c.col));
        out
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

    fn scoped_block(&mut self, block: &Block) {
        self.enter_scope();
        self.walk_block(block);
        self.exit_scope();
    }

    fn walk_stmt(&mut self, stmt: &Stmt) {
        match stmt {
            Stmt::LocalAssignment(la) => self.local_assignment(la),
            Stmt::ConstAssignment(ca) => self.const_assignment(ca),
            Stmt::Assignment(a) => self.assignment(a),
            Stmt::CompoundAssignment(ca) => {
                self.walk_expr(ca.rhs());
                self.write_var(ca.lhs());
            }
            Stmt::LocalFunction(lf) => self.local_function(lf),
            Stmt::ConstFunction(cf) => self.const_function(cf),
            Stmt::FunctionDeclaration(fd) => self.function_decl(fd),
            Stmt::FunctionCall(fc) => self.walk_function_call(fc),
            Stmt::Do(d) => self.scoped_block(d.block()),
            Stmt::If(if_stmt) => {
                self.walk_expr(if_stmt.condition());
                self.scoped_block(if_stmt.block());
                if let Some(elseifs) = if_stmt.else_if() {
                    for ei in elseifs {
                        self.walk_expr(ei.condition());
                        self.scoped_block(ei.block());
                    }
                }
                if let Some(else_block) = if_stmt.else_block() {
                    self.scoped_block(else_block);
                }
            }
            Stmt::While(w) => {
                self.walk_expr(w.condition());
                self.scoped_block(w.block());
            }
            Stmt::Repeat(r) => {
                // `until` sees the body's locals, so it walks inside the scope.
                self.enter_scope();
                self.walk_block(r.block());
                self.walk_expr(r.until());
                self.exit_scope();
            }
            Stmt::NumericFor(nf) => self.numeric_for(nf),
            Stmt::GenericFor(gf) => self.generic_for(gf),
            _ => {} // type declarations etc.: no bindings, no writes
        }
    }

    fn local_assignment(&mut self, la: &LocalAssignment) {
        for expr in la.expressions() {
            self.walk_expr(expr);
        }
        let names: Vec<String> = la.names().iter().map(token_text).collect();
        // `const` requires an initializer, so `local x` + a later `x = 1` can
        // never become const (and the later write marks it anyway).
        let eligible = !la.expressions().is_empty();
        let (line, col) = node_pos(la);
        self.push_and_bind("local", names, eligible, line, col);
    }

    fn const_assignment(&mut self, ca: &ConstAssignment) {
        for expr in ca.expressions() {
            self.walk_expr(expr);
        }
        let names: Vec<String> = ca.names().iter().map(token_text).collect();
        let (line, col) = node_pos(ca);
        self.push_and_bind("const", names, false, line, col);
    }

    fn assignment(&mut self, a: &Assignment) {
        for expr in a.expressions() {
            self.walk_expr(expr);
        }
        for var in a.variables() {
            self.write_var(var);
        }
    }

    fn write_var(&mut self, var: &Var) {
        match var {
            Var::Name(t) => self.mark_reassigned(&token_text(t)),
            // `t.x = 1` / `t[k] = v` mutate interior state: a read of the base
            // name, not a rebind. Walk only for nested function bodies.
            Var::Expression(ve) => self.walk_var_expression(ve),
            _ => {}
        }
    }

    fn local_function(&mut self, lf: &LocalFunction) {
        // The name binds before the body: self-recursion is a read.
        let (line, col) = node_pos(lf);
        self.push_and_bind("local_function", vec![token_text(lf.name())], true, line, col);
        self.function_body(lf.body());
    }

    fn const_function(&mut self, cf: &ConstFunction) {
        let (line, col) = node_pos(cf);
        self.push_and_bind("const", vec![token_text(cf.name())], false, line, col);
        self.function_body(cf.body());
    }

    fn function_decl(&mut self, fd: &FunctionDeclaration) {
        let name = fd.name();
        let dotted: Vec<&TokenReference> = name.names().iter().collect();
        if dotted.len() == 1 && name.method_name().is_none() {
            // `function f() end` is sugar for `f = function() end` — a write.
            self.mark_reassigned(&token_text(dotted[0]));
        }
        self.function_body(fd.body());
    }

    fn function_body(&mut self, body: &FunctionBody) {
        self.enter_scope();
        let params: Vec<String> = body
            .parameters()
            .iter()
            .filter_map(|p| match p {
                Parameter::Name(t) => Some(token_text(t)),
                _ => None, // `...` is not a name
            })
            .collect();
        if !params.is_empty() {
            let (line, col) = node_pos(body);
            self.push_and_bind("param", params, false, line, col);
        }
        self.walk_block(body.block());
        self.exit_scope();
    }

    fn numeric_for(&mut self, nf: &NumericFor) {
        self.walk_expr(nf.start());
        self.walk_expr(nf.end());
        if let Some(step) = nf.step() {
            self.walk_expr(step);
        }
        self.enter_scope();
        let (line, col) = node_pos(nf);
        self.push_and_bind("loop_var", vec![token_text(nf.index_variable())], false, line, col);
        self.walk_block(nf.block());
        self.exit_scope();
    }

    fn generic_for(&mut self, gf: &GenericFor) {
        for expr in gf.expressions() {
            self.walk_expr(expr);
        }
        self.enter_scope();
        let names: Vec<String> = gf.names().iter().map(token_text).collect();
        let (line, col) = node_pos(gf);
        self.push_and_bind("loop_var", names, false, line, col);
        self.walk_block(gf.block());
        self.exit_scope();
    }

    // -- expressions (find nested function bodies; writes can't occur here) --

    fn walk_expr(&mut self, expr: &Expression) {
        match expr {
            Expression::Function(anon) => self.function_body(anon.body()),
            Expression::BinaryOperator { lhs, rhs, .. } => {
                self.walk_expr(lhs);
                self.walk_expr(rhs);
            }
            Expression::Parentheses { expression, .. } => self.walk_expr(expression),
            Expression::UnaryOperator { expression, .. } => self.walk_expr(expression),
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
            _ => {} // Number/String/Symbol: no nested bodies
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

fn token_text(t: &TokenReference) -> String {
    t.token().to_string()
}

fn node_pos<N: Node>(n: &N) -> (usize, usize) {
    n.start_position().map(|p| (p.line(), p.character())).unwrap_or((0, 0))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parse;

    fn candidates(src: &str) -> Vec<ConstCandidate> {
        let ast = parse::parse(src).expect("test source must parse");
        scan(ast.nodes(), "src/t.luau")
    }

    /// Comma-joined names of each candidate declaration, in source order.
    fn names(src: &str) -> Vec<String> {
        candidates(src).iter().map(|c| c.names.join(",")).collect()
    }

    #[test]
    fn never_reassigned_local_is_a_candidate() {
        let cs = candidates("local a = 1\nprint(a)\n");
        assert_eq!(cs.len(), 1);
        assert_eq!(cs[0].kind, "local");
        assert_eq!(cs[0].names, vec!["a"]);
        assert_eq!((cs[0].line, cs[0].col), (1, 1));
        assert_eq!(cs[0].site, "const:src/t.luau:1:1");
    }

    #[test]
    fn reassigned_local_is_not_a_candidate() {
        assert!(names("local a = 1\na = 2\n").is_empty());
    }

    #[test]
    fn compound_assignment_disqualifies() {
        assert!(names("local a = 1\na += 1\n").is_empty());
    }

    #[test]
    fn interior_mutation_does_not_disqualify() {
        assert_eq!(names("local t = {}\nt.x = 1\nt[1] = 2\nt.y += 1\n"), vec!["t"]);
    }

    #[test]
    fn reassigning_an_inner_shadow_keeps_the_outer_candidate() {
        let cs = candidates("local x = 1\ndo\n\tlocal x = 2\n\tx = 3\nend\nprint(x)\n");
        assert_eq!(cs.len(), 1);
        assert_eq!(cs[0].line, 1);
    }

    #[test]
    fn bindings_take_effect_in_statement_order() {
        // `x = 1` runs before `local x` exists: a global write, not a reassign.
        assert_eq!(names("x = 1\nlocal x = 2\n"), vec!["x"]);
    }

    #[test]
    fn local_rhs_reads_the_outer_binding() {
        // `local x = x` reads the (global) outer x; the new local is clean.
        assert_eq!(names("local x = x\n"), vec!["x"]);
        // And a same-named outer local is read, not written.
        assert_eq!(names("local y = 1\ndo\n\tlocal y = y\nend\n"), vec!["y", "y"]);
    }

    #[test]
    fn closure_writing_an_upvalue_disqualifies_it() {
        let cs = candidates("local n = 0\nlocal function bump()\n\tn += 1\nend\nbump()\n");
        assert_eq!(cs.len(), 1);
        assert_eq!(cs[0].kind, "local_function");
        assert_eq!(cs[0].names, vec!["bump"]);
    }

    #[test]
    fn local_function_recursion_is_a_read() {
        let src = "local function f(x)\n\tif x > 0 then\n\t\treturn f(x - 1)\n\tend\n\treturn 0\nend\n";
        assert_eq!(names(src), vec!["f"]);
    }

    #[test]
    fn rebinding_a_local_function_disqualifies_it() {
        assert!(names("local function f() end\nf = nil\n").is_empty());
    }

    #[test]
    fn function_declaration_sugar_is_a_write() {
        // `function f() end` == `f = function() end`.
        assert!(names("local f = function() end\nfunction f() end\n").is_empty());
        // Dotted declarations mutate interior state of the base: not a rebind.
        assert_eq!(names("local M = {}\nfunction M.foo() end\nfunction M:bar() end\n"), vec!["M"]);
    }

    #[test]
    fn params_and_loop_vars_are_never_reported() {
        assert_eq!(names("local function f(a, b)\n\treturn a + b\nend\n"), vec!["f"]);
        assert!(names("for i = 1, 3 do\n\tprint(i)\nend\nfor k, v in pairs({}) do\n\tprint(k, v)\nend\n").is_empty());
    }

    #[test]
    fn writing_a_loop_var_does_not_leak_to_an_outer_local() {
        assert_eq!(names("local i = 1\nfor i = 1, 3 do\n\ti = 2\nend\nprint(i)\n"), vec!["i"]);
    }

    #[test]
    fn initializer_less_local_is_never_a_candidate() {
        // `const` requires an initializer.
        assert!(names("local x\nx = 1\nprint(x)\n").is_empty());
        assert!(names("local x\nprint(x)\n").is_empty());
    }

    #[test]
    fn multi_name_declaration_needs_every_name_clean() {
        assert!(names("local a, b = f()\nb = 2\n").is_empty());
        assert_eq!(names("local a, b = f()\nprint(a, b)\n"), vec!["a,b"]);
    }

    #[test]
    fn existing_const_declarations_are_not_reported() {
        assert!(names("const c = 1\nprint(c)\n").is_empty());
        assert!(names("const function g() end\ng()\n").is_empty());
    }

    #[test]
    fn writes_inside_nested_expression_functions_are_found() {
        // A closure buried in a table constructor still disqualifies `n`.
        let src = "local n = 0\nlocal t = { go = function()\n\tn = 1\nend }\nprint(t)\n";
        assert_eq!(names(src), vec!["t"]);
    }

    #[test]
    fn repeat_until_sees_body_locals() {
        // The `until` expression can reference body locals; a closure there
        // that writes one must resolve to the body decl, not an outer one.
        let src = "local done = false\nrepeat\n\tlocal x = 1\nuntil (function()\n\tx = 2\n\treturn true\nend)()\nprint(done)\n";
        assert_eq!(names(src), vec!["done"]);
    }
}

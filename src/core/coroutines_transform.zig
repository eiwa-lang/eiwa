//! Fase C (P1/P2): stackless coroutine AST transform.
//!
//! Rewrites Eiwa suspension points into the stackless machinery declared in
//! `src/std/coroutines.ei` (Scheduler + StackTask + generated Continuation).
//!
//! For a suspend function body:
//!   `val t = task { block }`       ->  `val __taskN = StackTask<T>(false, null, null)`
//!                                      `Scheduler.schedule(__TaskBlockN(__taskN, <captured...>))`
//!                                      `val t = __taskN`
//!   `val x = <recv>.await()`       ->  `if (!<recv>.done) { Scheduler.run() }`
//!                                      `val x = <recv>.result!!`
//!   `return <recv>.await()`        ->  poll + `return <recv>.result!!`
//!   `val x = task { ... }.await()` ->  machinery + poll + result
//!   await as an operand            ->  hoisted into a preceding `val __awaitN = ...`
//!
//! Each `task { block }` produces a generated continuation type
//! `type __TaskBlockN(val task: StackTask<T>, var <captured>: <T>, ...) : Continuation`
//! whose `resume()` splices the rewritten block (captured free vars turned into
//! `this.<name>` field accesses), writes the result, marks done and reschedules
//! the waiter chain. Generated types are registered via `inferTypeDecl` and
//! appended to the module's `program.statements` after the imports so the LLVM
//! emitter declares/emits them (struct, ctor, vtable, bodies).
//!
//! The transformed function is re-validated via `inferFunDecl` so every
//! generated identifier/call gets resolved types and c_names.

const std = @import("std");
const compat = @import("compat.zig");
const ArrayList = compat.ArrayList;
const ast = @import("ast.zig");
const ASTNode = ast.ASTNode;
const tc_core = @import("type_checker/core.zig");
const TypeChecker = tc_core.TypeChecker;
const ModuleRegistry = tc_core.ModuleRegistry;
const infer_decl = @import("type_checker/infer_decl.zig");
const ts = @import("type_system.zig");
const EiwaType = ts.EiwaType;

const ASTTypeRef = ast.ASTTypeRef;

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn transformProgram(allocator: std.mem.Allocator, registry: *ModuleRegistry) !void {
    for (registry.ordered_modules.items) |path| {
        const mod = registry.modules.get(path) orelse continue;
        try transformModule(allocator, mod.checker, mod.ast_root);
    }
}

fn transformModule(allocator: std.mem.Allocator, checker: *TypeChecker, module: *ASTNode) !void {
    if (module.data != .program) return;

    var counter: usize = 0;
    var generated = ArrayList(*ASTNode).init(allocator);
    defer generated.deinit();

    for (module.data.program.statements) |stmt| {
        if (stmt.data == .fun_decl) {
            // Transform any function whose body contains task{}/await — even
            // when it is NOT suspend (e.g. `main` with a bare `task {}` that is
            // never awaited still needs the machinery + a final scheduler drain).
            // rewriteFunctionBody's hasTaskOrAwait guard filters the rest.
            try transformFunction(allocator, checker, stmt, &counter, &generated);
        } else if (stmt.data == .type_decl) {
            const t = &stmt.data.type_decl;
            var type_rewritten = false;
            for (t.methods) |m_node| {
                if (m_node.data != .fun_decl) continue;
                if (!m_node.data.fun_decl.is_suspend) continue;
                if (try rewriteFunctionBody(allocator, checker, m_node, &counter, &generated)) type_rewritten = true;
            }
            if (type_rewritten) {
                // Re-infer the whole type so method bodies (with the generated
                // machinery) get resolved types in the class scope (`this`).
                try clearResolvedTypes(allocator, stmt);
                var t2: EiwaType = undefined;
                checker.pass = .validation;
                try infer_decl.inferTypeDecl(checker, stmt, &checker.global_scope, &t2);
            }
        } else if (stmt.data == .object_decl) {
            const o = &stmt.data.object_decl;
            var obj_rewritten = false;
            for (o.members) |member| {
                if (member.data != .fun_decl) continue;
                if (!member.data.fun_decl.is_suspend) continue;
                if (try rewriteFunctionBody(allocator, checker, member, &counter, &generated)) obj_rewritten = true;
            }
            if (obj_rewritten) {
                try clearResolvedTypes(allocator, stmt);
                var t3: EiwaType = undefined;
                checker.pass = .validation;
                try infer_decl.inferObjectDecl(checker, stmt, &checker.global_scope, &t3);
            }
        } else if (stmt.data == .test_decl) {
            // A `test "..." { }` block may contain task{}/await() directly
            // (no surrounding suspend fun). Rewrite its body statements and
            // re-infer so the generated machinery resolves.
            const td = &stmt.data.test_decl;
            if (td.body.data == .block) {
                var test_stmts = ArrayList(*ASTNode).init(allocator);
                defer test_stmts.deinit();
                const before = generated.items.len;
                try rewriteStatements(allocator, checker, td.body.data.block.statements, &counter, &generated, &test_stmts, false);
                if (generated.items.len > before or test_stmts.items.len != td.body.data.block.statements.len) {
                    // Drain the scheduler at the end of the test so
                    // fire-and-forget tasks (never awaited) still run.
                    try test_stmts.append(mkExprStmt(mkCall(mkGetExpr(mkIdent("Scheduler"), "run"), &.{})));
                    td.body.data.block.statements = try test_stmts.toOwnedSlice();
                    try clearResolvedTypes(allocator, stmt);
                    checker.pass = .validation;
                    _ = try checker.inferNode(stmt, &checker.global_scope);
                } else {
                    td.body.data.block.statements = try test_stmts.toOwnedSlice();
                }
            }
        }
    }

    // Collect continuation types produced during re-inference (monomorphized
    // generic instantiations such as `StackTask<Int>`, registered by
    // `monomorphizeClass` while `resolveTypeRef` runs inside the transform).
    var mono_types = ArrayList(*ASTNode).init(allocator);
    defer mono_types.deinit();
    for (checker.monomorphized_nodes.items) |mono| {
        if (mono.data != .type_decl) continue;
        if (containsNode(generated.items, mono)) continue;
        try mono_types.append(mono);
    }

    if (generated.items.len == 0 and mono_types.items.len == 0) return;

    // Splice generated types into program statements right after the imports
    // (mirrors the splice `core_validate` performs for monomorphized nodes).
    // Monomorphized types (e.g. `StackTask<Int>`) come FIRST: a generated
    // continuation's ctor evaluates body-field initializers that call those
    // ctors, and `declareType` emits ctor bodies inline — so the callee type
    // must be declared before the continuation that references it.
    var insert_idx: usize = 0;
    for (module.data.program.statements, 0..) |s, i| {
        if (s.data == .import_stmt) insert_idx = i + 1;
    }
    const old = module.data.program.statements;
    const extra = generated.items.len + mono_types.items.len;
    const new_stmts = try allocator.alloc(*ASTNode, old.len + extra);
    @memcpy(new_stmts[0..insert_idx], old[0..insert_idx]);
    @memcpy(new_stmts[insert_idx..][0..mono_types.items.len], mono_types.items);
    @memcpy(new_stmts[insert_idx + mono_types.items.len ..][0..generated.items.len], generated.items);
    @memcpy(new_stmts[insert_idx + extra ..], old[insert_idx..]);
    module.data.program.statements = new_stmts;
}

fn containsNode(nodes: []const *ASTNode, target: *ASTNode) bool {
    for (nodes) |n| {
        if (n == target) return true;
    }
    return false;
}

/// Rewrites a suspend function's body: `task {}`/`.await()` constructs become
/// machinery + generated continuation types. Returns true when the body was
/// actually rewritten. Does NOT re-validate — callers decide how to re-infer
/// (top-level functions vs type methods need different scopes).
fn rewriteFunctionBody(
    allocator: std.mem.Allocator,
    checker: *TypeChecker,
    node: *ASTNode,
    counter: *usize,
    generated: *ArrayList(*ASTNode),
) !bool {
    var f = &node.data.fun_decl;
    if (f.body.data != .block) return false;
    if (!hasTaskOrAwait(f.body)) return false;

    var new_stmts = ArrayList(*ASTNode).init(allocator);
    defer new_stmts.deinit();
    try rewriteStatements(allocator, checker, f.body.data.block.statements, counter, generated, &new_stmts, false);
    // `fun main()`: drain the scheduler before returning so fire-and-forget
    // tasks (`task {}` never awaited) still run. run() no-ops on empty queue.
    if (std.mem.eql(u8, f.name, "main")) {
        try new_stmts.append(mkExprStmt(mkCall(mkGetExpr(mkIdent("Scheduler"), "run"), &.{})));
    }
    const rewritten = try new_stmts.toOwnedSlice();
    f.body.data.block.statements = rewritten;
    return true;
}

/// Rewrites a top-level suspend function and re-validates it so the generated
/// machinery resolves. Only bodies that actually contain `task {}`/`.await()`
/// constructs are rewritten.
fn transformFunction(
    allocator: std.mem.Allocator,
    checker: *TypeChecker,
    node: *ASTNode,
    counter: *usize,
    generated: *ArrayList(*ASTNode),
) !void {
    if (!try rewriteFunctionBody(allocator, checker, node, counter, generated)) return;

    // Re-validate so every generated identifier/call gets resolved types.
    try clearResolvedTypes(allocator, node);
    var t: EiwaType = undefined;
    checker.pass = .validation;
    try infer_decl.inferFunDecl(checker, node, &checker.global_scope, &t);
}

/// True if the subtree contains a `task { ... }` call or an `.await()` call
/// (suspension points this transform handles). Lambda bodies are task/coroutine
/// boundaries and are not considered.
fn hasTaskOrAwait(node: *ASTNode) bool {
    switch (node.data) {
        .call_expr => |c| {
            if (isTaskCall(node) or isAwaitCall(node)) return true;
            if (hasTaskOrAwait(c.callee)) return true;
            for (c.arguments) |a| {
                if (hasTaskOrAwait(a)) return true;
            }
        },
        .lambda_expr => return false,
        .block => |b| {
            for (b.statements) |s| {
                if (hasTaskOrAwait(s)) return true;
            }
        },
        .binary_expr => |b| return hasTaskOrAwait(b.left) or hasTaskOrAwait(b.right),
        .unary_expr => |u| return hasTaskOrAwait(u.operand),
        .get_expr => |g| return hasTaskOrAwait(g.object),
        .set_expr => |s| return hasTaskOrAwait(s.object) or hasTaskOrAwait(s.value),
        .if_expr => |i| {
            if (hasTaskOrAwait(i.condition)) return true;
            if (hasTaskOrAwait(i.then_branch)) return true;
            if (i.else_branch) |e| {
                if (hasTaskOrAwait(e)) return true;
            }
        },
        .while_stmt => |w| return hasTaskOrAwait(w.condition) or hasTaskOrAwait(w.body),
        .for_stmt => |f| return hasTaskOrAwait(f.iterable) or hasTaskOrAwait(f.body),
        .return_stmt => |r| return if (r.value) |v| hasTaskOrAwait(v) else false,
        .assignment => |a| return hasTaskOrAwait(a.value),
        .index_expr => |i| return hasTaskOrAwait(i.object) or hasTaskOrAwait(i.index),
        .index_set_expr => |i| return hasTaskOrAwait(i.object) or hasTaskOrAwait(i.index) or hasTaskOrAwait(i.value),
        .try_stmt => |t| {
            if (hasTaskOrAwait(t.body)) return true;
            for (t.catches) |cb| {
                if (hasTaskOrAwait(cb.body)) return true;
            }
        },
        .throw_stmt => |t| return hasTaskOrAwait(t.expr),
        .when_expr => |w| {
            if (w.subject) |s| {
                if (hasTaskOrAwait(s)) return true;
            }
            for (w.cases) |case| {
                for (case.conds) |cond| {
                    if (hasTaskOrAwait(cond)) return true;
                }
                if (hasTaskOrAwait(case.body)) return true;
            }
        },
        .named_arg => |na| return hasTaskOrAwait(na.value),
        .array_literal => |al| {
            for (al.elements) |e| {
                if (hasTaskOrAwait(e)) return true;
            }
        },
        .map_literal => |ml| {
            for (ml.elements) |e| {
                if (hasTaskOrAwait(e)) return true;
            }
        },
        .var_decl => |v| return if (v.initializer) |init| hasTaskOrAwait(init) else false,
        else => {},
    }
    return false;
}

// ---------------------------------------------------------------------------
// Pattern detection
// ---------------------------------------------------------------------------

/// `task { ... }` — a call to the `@Coroutine` function `task`.
fn isTaskCall(node: *ASTNode) bool {
    if (node.data != .call_expr) return false;
    const c = &node.data.call_expr;
    if (c.callee.data != .identifier) return false;
    return std.mem.eql(u8, c.callee.data.identifier.name, "task");
}

/// `<recv>.await()` — a call whose callee is a get_expr named "await".
fn isAwaitCall(node: *ASTNode) bool {
    if (node.data != .call_expr) return false;
    const c = &node.data.call_expr;
    if (c.callee.data != .get_expr) return false;
    return std.mem.eql(u8, c.callee.data.get_expr.name, "await");
}

// ---------------------------------------------------------------------------
// Statement rewriting (recursive)
// ---------------------------------------------------------------------------

fn rewriteStatements(
    allocator: std.mem.Allocator,
    checker: *TypeChecker,
    stmts: []const *ASTNode,
    counter: *usize,
    generated: *ArrayList(*ASTNode),
    out: *ArrayList(*ASTNode),
    coop: bool,
) anyerror!void {
    for (stmts) |stmt| {
        const handled = try rewriteStatement(allocator, checker, stmt, counter, generated, out, coop);
        if (!handled) try out.append(stmt);
    }
}

/// Rewrites a single statement. Returns true when the statement was fully
/// replaced (the original must not be appended); false when the (possibly
/// mutated) statement should be kept.
fn rewriteStatement(
    allocator: std.mem.Allocator,
    checker: *TypeChecker,
    stmt: *ASTNode,
    counter: *usize,
    generated: *ArrayList(*ASTNode),
    out: *ArrayList(*ASTNode),
    coop: bool,
) !bool {
    switch (stmt.data) {
        .var_decl => |*v| {
            if (v.initializer) |init| {
                if (isTaskCall(init)) {
                    const gen = try rewriteTaskCall(allocator, checker, stmt, init, counter, generated);
                    try out.appendSlice(gen);
                    return true;
                }
                if (isAwaitCall(init)) {
                    const recv = init.data.call_expr.callee.data.get_expr.object;
                    if (isTaskCall(recv)) {
                        const gen = try rewriteTaskAwaitCall(allocator, checker, stmt, init, counter, generated, coop);
                        try out.appendSlice(gen);
                        return true;
                    }
                    const gen = try rewriteAwaitCall(allocator, checker, stmt, init, coop);
                    try out.appendSlice(gen);
                    return true;
                }
                if (containsAwait(init)) {
                    var preamble = ArrayList(*ASTNode).init(allocator);
                    defer preamble.deinit();
                    if (try hoistAwaitsFromExpr(allocator, checker, init, counter, &preamble)) {
                        try rewritePreamble(allocator, checker, &preamble, counter, generated, out, coop);
                        try out.append(stmt);
                        return true;
                    }
                }
            }
            return false;
        },
        .return_stmt => |*r| {
            if (r.value) |val| {
                if (isAwaitCall(val)) {
                    const recv = val.data.call_expr.callee.data.get_expr.object;
                    if (isTaskCall(recv)) {
                        const gen = try rewriteReturnTaskAwait(allocator, checker, stmt, val, counter, generated);
                        try out.appendSlice(gen);
                        return true;
                    }
                    const gen = try rewriteReturnAwait(allocator, checker, stmt, val);
                    try out.appendSlice(gen);
                    return true;
                }
                if (containsAwait(val)) {
                    var preamble = ArrayList(*ASTNode).init(allocator);
                    defer preamble.deinit();
                    if (try hoistAwaitsFromExpr(allocator, checker, val, counter, &preamble)) {
                        try rewritePreamble(allocator, checker, &preamble, counter, generated, out, coop);
                        try out.append(stmt);
                        return true;
                    }
                }
            }
            return false;
        },
        .block => |*b| {
            var new_stmts = ArrayList(*ASTNode).init(allocator);
            defer new_stmts.deinit();
            try rewriteStatements(allocator, checker, b.statements, counter, generated, &new_stmts, coop);
            b.statements = try new_stmts.toOwnedSlice();
            return false;
        },
        .if_expr => |*i| {
            if (containsAwait(i.condition)) {
                var preamble = ArrayList(*ASTNode).init(allocator);
                defer preamble.deinit();
                if (try hoistAwaitsFromExpr(allocator, checker, i.condition, counter, &preamble)) {
                    try rewritePreamble(allocator, checker, &preamble, counter, generated, out, coop);
                }
            }
            try rewriteBranch(allocator, checker, i.then_branch, counter, generated, coop);
            if (i.else_branch) |e| {
                try rewriteBranch(allocator, checker, e, counter, generated, coop);
            }
            return false;
        },
        .while_stmt => |*w| {
            if (containsAwait(w.condition)) {
                var preamble = ArrayList(*ASTNode).init(allocator);
                defer preamble.deinit();
                if (try hoistAwaitsFromExpr(allocator, checker, w.condition, counter, &preamble)) {
                    try rewritePreamble(allocator, checker, &preamble, counter, generated, out, coop);
                }
            }
            try rewriteBranch(allocator, checker, w.body, counter, generated, coop);
            return false;
        },
        .for_stmt => |*f| {
            try rewriteBranch(allocator, checker, f.iterable, counter, generated, coop);
            try rewriteBranch(allocator, checker, f.body, counter, generated, coop);
            return false;
        },
        .try_stmt => |*t| {
            try rewriteBranch(allocator, checker, t.body, counter, generated, coop);
            for (t.catches) |*cb| {
                try rewriteBranch(allocator, checker, cb.body, counter, generated, coop);
            }
            return false;
        },
        else => {
            if (stmt.data == .call_expr and isTaskCall(stmt)) {
                const gen = try rewriteBareTaskCall(allocator, checker, stmt, stmt, counter, generated);
                try out.appendSlice(gen);
                return true;
            }
            if (containsAwait(stmt)) {
                var preamble = ArrayList(*ASTNode).init(allocator);
                defer preamble.deinit();
                if (try hoistAwaitsFromExpr(allocator, checker, stmt, counter, &preamble)) {
                    try rewritePreamble(allocator, checker, &preamble, counter, generated, out, coop);
                    try out.append(stmt);
                    return true;
                }
            }
            return false;
        },
    }
}

/// Rewrites a branch that may be a block or a single statement.
fn rewriteBranch(
    allocator: std.mem.Allocator,
    checker: *TypeChecker,
    branch: *ASTNode,
    counter: *usize,
    generated: *ArrayList(*ASTNode),
    coop: bool,
) anyerror!void {
    if (branch.data == .block) {
        var new_stmts = ArrayList(*ASTNode).init(allocator);
        defer new_stmts.deinit();
        try rewriteStatements(allocator, checker, branch.data.block.statements, counter, generated, &new_stmts, coop);
        branch.data.block.statements = try new_stmts.toOwnedSlice();
        return;
    }
    var out = ArrayList(*ASTNode).init(allocator);
    defer out.deinit();
    const handled = try rewriteStatement(allocator, checker, branch, counter, generated, &out, coop);
    if (handled) {
        if (out.items.len == 1) {
            branch.* = out.items[0].*;
        }
    }
}

/// Rewrites a hoisted await preamble (a list of `val __awaitN = <recv>.await()`
/// statements produced by `hoistAwaitsFromExpr`) into poll or cooperative-await
/// form depending on `coop`.
fn rewritePreamble(
    allocator: std.mem.Allocator,
    checker: *TypeChecker,
    preamble: *ArrayList(*ASTNode),
    counter: *usize,
    generated: *ArrayList(*ASTNode),
    out: *ArrayList(*ASTNode),
    coop: bool,
) anyerror!void {
    for (preamble.items) |stmt| {
        const handled = try rewriteStatement(allocator, checker, stmt, counter, generated, out, coop);
        if (!handled) try out.append(stmt);
    }
}

/// True if the subtree contains an `.await()` call (suspension point). Lambda
/// bodies are task/coroutine boundaries and are not considered.
fn containsAwait(node: *ASTNode) bool {
    switch (node.data) {
        .call_expr => |c| {
            if (isAwaitCall(node)) return true;
            if (containsAwait(c.callee)) return true;
            for (c.arguments) |a| {
                if (containsAwait(a)) return true;
            }
        },
        .lambda_expr => return false,
        .block => |b| {
            for (b.statements) |s| {
                if (containsAwait(s)) return true;
            }
        },
        .binary_expr => |b| return containsAwait(b.left) or containsAwait(b.right),
        .unary_expr => |u| return containsAwait(u.operand),
        .get_expr => |g| return containsAwait(g.object),
        .set_expr => |s| return containsAwait(s.object) or containsAwait(s.value),
        .if_expr => |i| {
            if (containsAwait(i.condition)) return true;
            if (containsAwait(i.then_branch)) return true;
            if (i.else_branch) |e| {
                if (containsAwait(e)) return true;
            }
        },
        .while_stmt => |w| return containsAwait(w.condition) or containsAwait(w.body),
        .for_stmt => |f| return containsAwait(f.iterable) or containsAwait(f.body),
        .return_stmt => |r| return if (r.value) |v| containsAwait(v) else false,
        .assignment => |a| return containsAwait(a.value),
        .index_expr => |i| return containsAwait(i.object) or containsAwait(i.index),
        .index_set_expr => |i| return containsAwait(i.object) or containsAwait(i.index) or containsAwait(i.value),
        .try_stmt => |t| {
            if (containsAwait(t.body)) return true;
            for (t.catches) |cb| {
                if (containsAwait(cb.body)) return true;
            }
        },
        .throw_stmt => |t| return containsAwait(t.expr),
        .when_expr => |w| {
            if (w.subject) |s| {
                if (containsAwait(s)) return true;
            }
            for (w.cases) |case| {
                for (case.conds) |cond| {
                    if (containsAwait(cond)) return true;
                }
                if (containsAwait(case.body)) return true;
            }
        },
        .named_arg => |na| return containsAwait(na.value),
        .array_literal => |al| {
            for (al.elements) |e| {
                if (containsAwait(e)) return true;
            }
        },
        .map_literal => |ml| {
            for (ml.elements) |e| {
                if (containsAwait(e)) return true;
            }
        },
        .var_decl => |v| return if (v.initializer) |init| containsAwait(init) else false,
        else => {},
    }
    return false;
}

/// A free variable captured by a `task { }` block, promoted to a field of the
/// generated continuation. Mutable `var` captures are re-boxed at the ctor call
/// site so the emitter double-derefs and passes the value (not the box pointer).
const CapturedVar = struct {
    name: []const u8,
    type_ref: *const ASTTypeRef,
    is_boxed: bool,
};

/// Collects the free variables referenced by a task block (the lambda body
/// statement list): identifiers with a resolved type that are NOT declared
/// inside the block and NOT global symbols.
fn collectCaptures(
    allocator: std.mem.Allocator,
    checker: *TypeChecker,
    body: []const *ASTNode,
) ![]CapturedVar {
    var locals = std.StringHashMap(void).init(allocator);
    defer locals.deinit();

    for (body) |s| {
        try collectLocalDecls(allocator, s, &locals);
    }

    var captures = ArrayList(CapturedVar).init(allocator);
    for (body) |s| {
        try collectFreeIdents(allocator, checker, s, &locals, &captures);
    }
    return captures.toOwnedSlice();
}

/// Records names declared inside the subtree (var_decl, for loop item, lambda
/// params, catch vars) so they are not treated as free.
fn collectLocalDecls(allocator: std.mem.Allocator, node: *ASTNode, locals: *std.StringHashMap(void)) !void {
    switch (node.data) {
        .var_decl => |v| {
            try locals.put(v.name, {});
            if (v.initializer) |init| try collectLocalDecls(allocator, init, locals);
        },
        .for_stmt => |f| {
            try locals.put(f.item_name, {});
            try collectLocalDecls(allocator, f.iterable, locals);
            try collectLocalDecls(allocator, f.body, locals);
        },
        .lambda_expr => |l| {
            for (l.params) |p| {
                try locals.put(p.name, {});
            }
            for (l.body) |b| {
                try collectLocalDecls(allocator, b, locals);
            }
        },
        .block => |b| {
            for (b.statements) |s| {
                try collectLocalDecls(allocator, s, locals);
            }
        },
        .try_stmt => |t| {
            try collectLocalDecls(allocator, t.body, locals);
            for (t.catches) |cb| {
                if (cb.var_name) |vn| try locals.put(vn, {});
                try collectLocalDecls(allocator, cb.body, locals);
            }
        },
        .if_expr => |i| {
            try collectLocalDecls(allocator, i.condition, locals);
            try collectLocalDecls(allocator, i.then_branch, locals);
            if (i.else_branch) |e| try collectLocalDecls(allocator, e, locals);
        },
        .while_stmt => |w| {
            try collectLocalDecls(allocator, w.condition, locals);
            try collectLocalDecls(allocator, w.body, locals);
        },
        .binary_expr => |b| {
            try collectLocalDecls(allocator, b.left, locals);
            try collectLocalDecls(allocator, b.right, locals);
        },
        .unary_expr => |u| try collectLocalDecls(allocator, u.operand, locals),
        .get_expr => |g| try collectLocalDecls(allocator, g.object, locals),
        .set_expr => |s| {
            try collectLocalDecls(allocator, s.object, locals);
            try collectLocalDecls(allocator, s.value, locals);
        },
        .assignment => |a| try collectLocalDecls(allocator, a.value, locals),
        .call_expr => |c| {
            try collectLocalDecls(allocator, c.callee, locals);
            for (c.arguments) |arg| {
                try collectLocalDecls(allocator, arg, locals);
            }
        },
        .return_stmt => |r| if (r.value) |v| try collectLocalDecls(allocator, v, locals),
        .index_expr => |i| {
            try collectLocalDecls(allocator, i.object, locals);
            try collectLocalDecls(allocator, i.index, locals);
        },
        .index_set_expr => |i| {
            try collectLocalDecls(allocator, i.object, locals);
            try collectLocalDecls(allocator, i.index, locals);
            try collectLocalDecls(allocator, i.value, locals);
        },
        .when_expr => |w| {
            if (w.subject) |s| try collectLocalDecls(allocator, s, locals);
            for (w.cases) |case| {
                for (case.conds) |cond| try collectLocalDecls(allocator, cond, locals);
                try collectLocalDecls(allocator, case.body, locals);
            }
        },
        else => {},
    }
}

/// Collects free identifiers (captures) from the block: identifiers that are
/// not declared locally, not globals, not class properties, and not `this`.
fn collectFreeIdents(
    allocator: std.mem.Allocator,
    checker: *TypeChecker,
    node: *ASTNode,
    locals: *std.StringHashMap(void),
    captures: *ArrayList(CapturedVar),
) !void {
    switch (node.data) {
        .identifier => |i| {
            if (i.resolved_c_name != null and i.is_class_property) return;
            if (std.mem.eql(u8, i.name, "this")) return;
            if (locals.contains(i.name)) return;
            if (isGlobalName(checker, i.name)) return;
            const rt = node.resolved_type orelse return;
            try addCapture(allocator, captures, i.name, rt, i.is_boxed);
        },
        .assignment => |a| {
            // P3: capture the assignment target too (e.g. `caught = 99` inside
            // the task block mutates a captured var).
            if (!locals.contains(a.name) and !isGlobalName(checker, a.name)) {
                const rt = node.resolved_type orelse return;
                try addCapture(allocator, captures, a.name, rt, a.is_boxed);
            }
            try collectFreeIdents(allocator, checker, a.value, locals, captures);
        },
        .lambda_expr => return,
        .block => |b| {
            for (b.statements) |s| {
                try collectFreeIdents(allocator, checker, s, locals, captures);
            }
        },
        .var_decl => |v| {
            if (v.initializer) |init| try collectFreeIdents(allocator, checker, init, locals, captures);
        },
        .call_expr => |c| {
            try collectFreeIdents(allocator, checker, c.callee, locals, captures);
            for (c.arguments) |arg| {
                try collectFreeIdents(allocator, checker, arg, locals, captures);
            }
        },
        .binary_expr => |b| {
            try collectFreeIdents(allocator, checker, b.left, locals, captures);
            try collectFreeIdents(allocator, checker, b.right, locals, captures);
        },
        .unary_expr => |u| try collectFreeIdents(allocator, checker, u.operand, locals, captures),
        .get_expr => |g| try collectFreeIdents(allocator, checker, g.object, locals, captures),
        .set_expr => |s| {
            try collectFreeIdents(allocator, checker, s.object, locals, captures);
            try collectFreeIdents(allocator, checker, s.value, locals, captures);
        },
        .if_expr => |i| {
            try collectFreeIdents(allocator, checker, i.condition, locals, captures);
            try collectFreeIdents(allocator, checker, i.then_branch, locals, captures);
            if (i.else_branch) |e| try collectFreeIdents(allocator, checker, e, locals, captures);
        },
        .while_stmt => |w| {
            try collectFreeIdents(allocator, checker, w.condition, locals, captures);
            try collectFreeIdents(allocator, checker, w.body, locals, captures);
        },
        .for_stmt => |f| {
            try collectFreeIdents(allocator, checker, f.iterable, locals, captures);
            try collectFreeIdents(allocator, checker, f.body, locals, captures);
        },
        .return_stmt => |r| if (r.value) |v| try collectFreeIdents(allocator, checker, v, locals, captures),
        .try_stmt => |t| {
            try collectFreeIdents(allocator, checker, t.body, locals, captures);
            for (t.catches) |cb| {
                try collectFreeIdents(allocator, checker, cb.body, locals, captures);
            }
        },
        .throw_stmt => |t| try collectFreeIdents(allocator, checker, t.expr, locals, captures),
        .index_expr => |i| {
            try collectFreeIdents(allocator, checker, i.object, locals, captures);
            try collectFreeIdents(allocator, checker, i.index, locals, captures);
        },
        .index_set_expr => |i| {
            try collectFreeIdents(allocator, checker, i.object, locals, captures);
            try collectFreeIdents(allocator, checker, i.index, locals, captures);
            try collectFreeIdents(allocator, checker, i.value, locals, captures);
        },
        .when_expr => |w| {
            if (w.subject) |s| try collectFreeIdents(allocator, checker, s, locals, captures);
            for (w.cases) |case| {
                for (case.conds) |cond| try collectFreeIdents(allocator, checker, cond, locals, captures);
                try collectFreeIdents(allocator, checker, case.body, locals, captures);
            }
        },
        .array_literal => |al| {
            for (al.elements) |e| try collectFreeIdents(allocator, checker, e, locals, captures);
        },
        .map_literal => |ml| {
            for (ml.elements) |e| try collectFreeIdents(allocator, checker, e, locals, captures);
        },
        .named_arg => |na| try collectFreeIdents(allocator, checker, na.value, locals, captures),
        else => {},
    }
}

fn addCapture(
    allocator: std.mem.Allocator,
    captures: *ArrayList(CapturedVar),
    name: []const u8,
    rt: *const EiwaType,
    is_boxed: bool,
) !void {
    for (captures.items) |c| {
        if (std.mem.eql(u8, c.name, name)) return;
    }
    try captures.append(.{
        .name = name,
        .type_ref = try typeRefForEiwaType(allocator, rt),
        .is_boxed = is_boxed,
    });
}

/// True if `name` refers to a global symbol (type, object, contract, skill,
/// enum, function, alias, or generic function) rather than a local variable.
fn isGlobalName(checker: *TypeChecker, name: []const u8) bool {
    if (checker.classes_ast.contains(name)) return true;
    if (checker.objects_ast.contains(name)) return true;
    if (checker.contracts_ast.contains(name)) return true;
    if (checker.skills_ast.contains(name)) return true;
    if (checker.enums_ast.contains(name)) return true;
    if (checker.functions_ast.contains(name)) return true;
    if (checker.generic_functions_ast.contains(name)) return true;
    if (checker.global_scope.lookupFunctions(name) != null) return true;
    if (checker.alias_map.get(name)) |aliased| {
        if (!std.mem.eql(u8, aliased, name)) return isGlobalName(checker, aliased);
        return true;
    }
    return false;
}

/// Rewrites captured variable references inside the task block into
/// `this.<name>` field accesses (reads, assignment targets, set_expr values).
fn rewriteCapturedRefs(allocator: std.mem.Allocator, captures: []const CapturedVar, node: *ASTNode) !void {
    switch (node.data) {
        .identifier => |*i| {
            for (captures) |c| {
                if (std.mem.eql(u8, i.name, c.name)) {
                    const captured_name = i.name;
                    node.data = .{ .get_expr = .{
                        .object = mkIdent("this"),
                        .name = captured_name,
                        .is_safe = false,
                        .is_boxed = c.is_boxed,
                    } };
                    return;
                }
            }
        },
        .assignment => |*a| {
            // Rewrite references inside the value first (same rationale as
            // rewritePromotedRefs: a bare `acc` in the RHS would resolve to
            // the class property and emit the box pointer, not the value).
            try rewriteCapturedRefs(allocator, captures, a.value);
            for (captures) |c| {
                if (std.mem.eql(u8, a.name, c.name)) {
                    // `caught = 99` -> `this.caught = 99`
                    const assignment_name = a.name;
                    const assignment_value = a.value;
                    node.data = .{ .set_expr = .{
                        .object = mkIdent("this"),
                        .name = assignment_name,
                        .value = assignment_value,
                        .is_safe = false,
                        .is_boxed = c.is_boxed,
                    } };
                    return;
                }
            }
        },
        .lambda_expr => return,
        .block => |b| {
            for (b.statements) |s| {
                try rewriteCapturedRefs(allocator, captures, s);
            }
        },
        .var_decl => |v| {
            if (v.initializer) |init| try rewriteCapturedRefs(allocator, captures, init);
        },
        .call_expr => |c| {
            try rewriteCapturedRefs(allocator, captures, c.callee);
            for (c.arguments) |arg| {
                try rewriteCapturedRefs(allocator, captures, arg);
            }
        },
        .binary_expr => |b| {
            try rewriteCapturedRefs(allocator, captures, b.left);
            try rewriteCapturedRefs(allocator, captures, b.right);
        },
        .unary_expr => |u| try rewriteCapturedRefs(allocator, captures, u.operand),
        .get_expr => |g| try rewriteCapturedRefs(allocator, captures, g.object),
        .set_expr => |s| {
            try rewriteCapturedRefs(allocator, captures, s.object);
            try rewriteCapturedRefs(allocator, captures, s.value);
        },
        .if_expr => |i| {
            try rewriteCapturedRefs(allocator, captures, i.condition);
            try rewriteCapturedRefs(allocator, captures, i.then_branch);
            if (i.else_branch) |e| try rewriteCapturedRefs(allocator, captures, e);
        },
        .while_stmt => |w| {
            try rewriteCapturedRefs(allocator, captures, w.condition);
            try rewriteCapturedRefs(allocator, captures, w.body);
        },
        .for_stmt => |f| {
            try rewriteCapturedRefs(allocator, captures, f.iterable);
            try rewriteCapturedRefs(allocator, captures, f.body);
        },
        .return_stmt => |r| if (r.value) |v| try rewriteCapturedRefs(allocator, captures, v),
        .try_stmt => |t| {
            try rewriteCapturedRefs(allocator, captures, t.body);
            for (t.catches) |cb| {
                try rewriteCapturedRefs(allocator, captures, cb.body);
            }
        },
        .throw_stmt => |t| try rewriteCapturedRefs(allocator, captures, t.expr),
        .index_expr => |i| {
            try rewriteCapturedRefs(allocator, captures, i.object);
            try rewriteCapturedRefs(allocator, captures, i.index);
        },
        .index_set_expr => |i| {
            try rewriteCapturedRefs(allocator, captures, i.object);
            try rewriteCapturedRefs(allocator, captures, i.index);
            try rewriteCapturedRefs(allocator, captures, i.value);
        },
        .when_expr => |w| {
            if (w.subject) |s| try rewriteCapturedRefs(allocator, captures, s);
            for (w.cases) |case| {
                for (case.conds) |cond| try rewriteCapturedRefs(allocator, captures, cond);
                try rewriteCapturedRefs(allocator, captures, case.body);
            }
        },
        .array_literal => |al| {
            for (al.elements) |e| try rewriteCapturedRefs(allocator, captures, e);
        },
        .map_literal => |ml| {
            for (ml.elements) |e| try rewriteCapturedRefs(allocator, captures, e);
        },
        .named_arg => |na| try rewriteCapturedRefs(allocator, captures, na.value),
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Hoisting awaits used as operands
// ---------------------------------------------------------------------------

/// Hoists every `.await()` inside `expr` into `val __awaitN = <recv>.await()`
/// preamble statements, replacing the await call with an identifier reference.
/// Returns true when at least one await was hoisted.
fn hoistAwaitsFromExpr(
    allocator: std.mem.Allocator,
    checker: *TypeChecker,
    expr: *ASTNode,
    counter: *usize,
    preamble: *ArrayList(*ASTNode),
) !bool {
    var hoisted = false;
    try hoistAwaitsWalk(allocator, checker, expr, counter, preamble, &hoisted);
    return hoisted;
}

fn hoistAwaitsWalk(
    allocator: std.mem.Allocator,
    checker: *TypeChecker,
    node: *ASTNode,
    counter: *usize,
    preamble: *ArrayList(*ASTNode),
    hoisted: *bool,
) !void {
    if (isAwaitCall(node)) {
        const name = try std.fmt.allocPrint(allocator, "__await{d}", .{counter.*});
        counter.* += 1;
        const copy = try allocator.create(ASTNode);
        copy.* = node.*;
        const await_result = node.resolved_type;
        try clearResolvedTypes(allocator, copy);
        const decl = mkVarDecl(name, copy);
        // Preserve the await result type so the machinery can type the
        // cooperative-await marker (the copy's own types were cleared).
        if (await_result) |rt| decl.resolved_type = rt;
        try preamble.append(decl);
        node.data = .{ .identifier = .{
            .name = name,
            .resolved_c_name = null,
        } };
        hoisted.* = true;
        return;
    }
    switch (node.data) {
        .call_expr => |*c| {
            if (isTaskCall(node)) return; // task blocks are boundaries
            try hoistAwaitsWalk(allocator, checker, c.callee, counter, preamble, hoisted);
            for (c.arguments) |arg| {
                try hoistAwaitsWalk(allocator, checker, arg, counter, preamble, hoisted);
            }
        },
        .lambda_expr => return,
        .binary_expr => |*b| {
            try hoistAwaitsWalk(allocator, checker, b.left, counter, preamble, hoisted);
            try hoistAwaitsWalk(allocator, checker, b.right, counter, preamble, hoisted);
        },
        .unary_expr => |*u| try hoistAwaitsWalk(allocator, checker, u.operand, counter, preamble, hoisted),
        .get_expr => |*g| try hoistAwaitsWalk(allocator, checker, g.object, counter, preamble, hoisted),
        .set_expr => |*s| {
            try hoistAwaitsWalk(allocator, checker, s.object, counter, preamble, hoisted);
            try hoistAwaitsWalk(allocator, checker, s.value, counter, preamble, hoisted);
        },
        .index_expr => |*i| {
            try hoistAwaitsWalk(allocator, checker, i.object, counter, preamble, hoisted);
            try hoistAwaitsWalk(allocator, checker, i.index, counter, preamble, hoisted);
        },
        .index_set_expr => |*i| {
            try hoistAwaitsWalk(allocator, checker, i.object, counter, preamble, hoisted);
            try hoistAwaitsWalk(allocator, checker, i.index, counter, preamble, hoisted);
            try hoistAwaitsWalk(allocator, checker, i.value, counter, preamble, hoisted);
        },
        .array_literal => |*al| {
            for (al.elements) |e| {
                try hoistAwaitsWalk(allocator, checker, e, counter, preamble, hoisted);
            }
        },
        .map_literal => |*ml| {
            for (ml.elements) |e| {
                try hoistAwaitsWalk(allocator, checker, e, counter, preamble, hoisted);
            }
        },
        .named_arg => |*na| try hoistAwaitsWalk(allocator, checker, na.value, counter, preamble, hoisted),
        .var_decl => |*v| if (v.initializer) |init| try hoistAwaitsWalk(allocator, checker, init, counter, preamble, hoisted),
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Generated type construction
// ---------------------------------------------------------------------------

/// Builds the generated continuation type for a task block:
/// `type __TaskBlockN(val task: StackTask<T>, var <captured>: <T>, ...) : Continuation`
/// with `resume()`/`isDone()` methods, registers it and returns the type node.
fn buildTaskBlockType(
    allocator: std.mem.Allocator,
    checker: *TypeChecker,
    captures: []const CapturedVar,
    result_type: *const EiwaType,
    body: []const *ASTNode,
    counter: *usize,
    generated: *ArrayList(*ASTNode),
) !*ASTNode {
    const type_name = try std.fmt.allocPrint(allocator, "__TaskBlock{d}", .{counter.*});

    var props = ArrayList(ast.ClassProp).init(allocator);
    defer props.deinit();

    const task_ref = try typeRefWithArgs(allocator, "StackTask", &.{result_type});
    try props.append(.{
        .is_mut = false,
        .name = "task",
        .type_ref = task_ref,
    });

    for (captures) |c| {
        // Boxed captures hold the heap box pointer so writes inside the task
        // propagate back to the outer variable (shared mutable capture). The
        // type checker still types the field as the captured value type; the
        // emitter allocates/accesses it as a pointer via `is_boxed`.
        try props.append(.{
            .is_mut = true,
            .name = c.name,
            .type_ref = c.type_ref,
            .is_boxed = c.is_boxed,
        });
    }

    var methods = ArrayList(*ASTNode).init(allocator);
    defer methods.deinit();

    var body_fields = ArrayList(ast.ClassProp).init(allocator);
    defer body_fields.deinit();

    // Route: task bodies with a true suspension point (sleep/yield) become a
    // `switch(label)` state machine; bodies without one keep the single-shot
    // blocking-poll resume.
    //
    // NOTE: `.await()` does NOT trigger the state machine yet — awaits in
    // single-shot task bodies stay blocking-poll. Flipping this (adding
    // `containsAwait(s)` to the condition) exposes unexercised paths: the
    // composite `val r = task{...}.await()` machinery bind, and boxed captures
    // of promoted locals by nested tasks. Revisit incrementally per the doc
    // (Gap 1: awaits em single-shot), one green test at a time.
    var state_machine = false;
    for (body) |s| {
        if (containsTrueSuspend(s)) {
            state_machine = true;
            break;
        }
    }

    var resume_method: *ASTNode = undefined;
    if (state_machine) {
        const locals = try collectLocals(allocator, body);
        defer allocator.free(locals);
        for (locals) |l| {
            const default_init = defaultInitializerForTypeRef(allocator, l.type_ref) orelse
                return error.UnsupportedStateMachineLocal;
            try body_fields.append(.{
                .is_mut = true,
                .name = l.name,
                .type_ref = l.type_ref,
                .is_property = true,
                .initializer = default_init,
            });
        }
        // The state-machine dispatch reads `this.label`; its default is the
        // entry state (the label where the machine begins).
        var entry_label: usize = 0;
        resume_method = try buildResumeStateMachine(allocator, checker, captures, locals, body, result_type, counter, generated, &entry_label, &body_fields);
        try methods.append(resume_method);
        try body_fields.append(.{
            .is_mut = true,
            .name = "label",
            .type_ref = typeRefSimple("Int"),
            .is_property = true,
            .initializer = mkIntLit(@intCast(entry_label)),
        });
    } else {
        try methods.append(try buildResume(allocator, checker, captures, body, result_type, counter, generated));
    }
    try methods.append(try buildIsDone(allocator));

    const type_node = try allocator.create(ASTNode);
    type_node.* = .{
        .line = 0,
        .column = 0,
        .data = .{ .type_decl = .{
            .annotations = &.{},
            .name = type_name,
            .generic_params = &.{},
            .primary_constructor = try props.toOwnedSlice(),
            .methods = try methods.toOwnedSlice(),
            .resolved_c_name = null,
            .contracts = &.{"Continuation"},
            .skills = &.{},
            .body_fields = try body_fields.toOwnedSlice(),
        } },
    };

    try registerGeneratedType(checker, type_node, generated);
    return type_node;
}

/// `resume()`: the task block statements (captured refs -> `this.<name>`),
/// then write the result into `this.task.result`, mark done and reschedule the
/// waiter chain.
fn buildResume(
    allocator: std.mem.Allocator,
    checker: *TypeChecker,
    captures: []const CapturedVar,
    body: []const *ASTNode,
    result_type: *const EiwaType,
    counter: *usize,
    generated: *ArrayList(*ASTNode),
) !*ASTNode {
    // Rewrite the block: captured free vars become `this.<name>`, and nested
    // task/await constructs are recursively rewritten into machinery.
    for (body) |s| {
        try rewriteCapturedRefs(allocator, captures, s);
    }
    var rewritten = ArrayList(*ASTNode).init(allocator);
    defer rewritten.deinit();
    try rewriteStatements(allocator, checker, body, counter, generated, &rewritten, false);

    // Nodes rewritten above (captured refs -> `this.<name>`) keep stale resolved
    // types from the first validation pass. Clear them so re-inference descends
    // into the rewritten subtrees (e.g. the object `this` of `this.x`).
    for (rewritten.items) |s| {
        try clearResolvedTypes(allocator, s);
    }

    var stmts = ArrayList(*ASTNode).init(allocator);
    defer stmts.deinit();

    // The last rewritten statement is the block result; it becomes
    // `this.task.result = <last>` — UNLESS the block result is Void or the
    // last statement is a side-effect statement (assignment/set) that must be
    // executed, not consumed as a value.
    const is_void_result = result_type.* == .Void;
    const last_is_value = if (rewritten.items.len > 0) isValueStatement(rewritten.items[rewritten.items.len - 1]) else false;
    const has_result = !is_void_result and last_is_value;
    const result_expr = if (has_result) rewritten.pop() else null;

    // result store: this.task.result = <last> (only when the task has a value)
    const task_get = mkGetExpr(mkIdent("this"), "task");
    if (result_expr) |re| {
        const result_set = mkSetExpr(task_get, "result", re);
        try stmts.appendSlice(rewritten.items);
        try stmts.append(result_set);
    } else {
        try stmts.appendSlice(rewritten.items);
    }

    // this.task.done = true
    const done_set = mkSetExpr(mkGetExpr(mkIdent("this"), "task"), "done", mkBoolLit(true));
    try stmts.append(done_set);

    // Reschedule waiter chain (mirrors SpecBlockCont):
    //   var __waiter = this.task.waiters
    //   while (__waiter != null) {
    //       Scheduler.schedule(__waiter!!.cont)
    //       __waiter = __waiter!!.next
    //   }
    //   this.task.waiters = null
    const waiter_name = try std.fmt.allocPrint(allocator, "__waiter{d}", .{counter.*});
    const waiter_var = mkVarDecl(waiter_name, mkGetExpr(mkGetExpr(mkIdent("this"), "task"), "waiters"));
    waiter_var.data.var_decl.is_mut = true;
    try stmts.append(waiter_var);

    const while_body = mkBlock(&.{
        mkCall(
            mkGetExpr(mkIdent("Scheduler"), "schedule"),
            &.{ mkGetExpr(mkUnary(.bang_bang, mkIdent(waiter_name)), "cont") },
        ),
        mkAssign(waiter_name, mkGetExpr(mkUnary(.bang_bang, mkIdent(waiter_name)), "next")),
    });
    const while_stmt = mkWhile(
        mkBinary(.bang_eq, mkIdent(waiter_name), mkNullLit()),
        while_body,
    );
    try stmts.append(while_stmt);

    const waiters_null = mkSetExpr(mkGetExpr(mkIdent("this"), "task"), "waiters", mkNullLit());
    try stmts.append(waiters_null);

    const block_body = mkBlock(try stmts.toOwnedSlice());
    return mkFunDecl("resume", &.{}, block_body, false, &.{.kw_implement});
}

/// `isDone(): Bool = this.task.done`
fn buildIsDone(allocator: std.mem.Allocator) !*ASTNode {
    _ = allocator;
    const body = mkGetExpr(mkGetExpr(mkIdent("this"), "task"), "done");
    return mkFunDecl("isDone", &.{}, body, true, &.{.kw_implement});
}

/// Registers the generated type via `inferTypeDecl` (resolves c_name, defines
/// it in the global scope, registers methods) and appends it to the module's
/// generated list for splicing into `program.statements`.
fn registerGeneratedType(checker: *TypeChecker, type_node: *ASTNode, generated: *ArrayList(*ASTNode)) !void {
    var t: EiwaType = undefined;
    checker.pass = .validation;
    try infer_decl.inferTypeDecl(checker, type_node, &checker.global_scope, &t);
    try generated.append(type_node);
}

/// Returns the type of the task block result: the resolved type of the last
/// statement of the lambda body (or Void for an empty body).
fn blockReturnType(body: []const *ASTNode) *const EiwaType {
    if (body.len > 0) {
        if (body[body.len - 1].resolved_type) |rt| return rt;
    }
    return &defaultVoidType;
}

var defaultVoidType: EiwaType = .Void;

/// True when the statement produces a value usable as a task result (as
/// opposed to a side-effect statement like an assignment/set that must be
/// executed for its effect, not consumed as the block's value).
fn isValueStatement(node: *ASTNode) bool {
    switch (node.data) {
        .int_literal, .double_literal, .string_literal, .bool_literal, .identifier,
        .binary_expr, .unary_expr, .call_expr, .get_expr, .index_expr,
        .array_literal, .map_literal, .lambda_expr => return true,
        else => return false,
    }
}

// ---------------------------------------------------------------------------
// Fase J — true suspension state machines (sleep/yield inside task bodies)
//
// A task body containing a cooperative suspension primitive (`sleep`/`sleepMs`/
// `yield`) cannot run in a single `resume()` shot: it must suspend and be
// re-scheduled by the Scheduler (timer heap / ready queue). The body is split
// at those suspension points into a `switch(label)` state machine:
//
//   fun resume() {
//       while (true) {
//           if (this.label == L0) { <state L0> } else
//           if (this.label == L1) { <state L1> } else
//           ...
//           else { <done: result, done=true, reschedule waiters, return> }
//       }
//   }
//
// Every local declared in the body is promoted to a body field of the
// continuation, and every state transition is `this.label = <next>`.
// ---------------------------------------------------------------------------

/// A call to one of the cooperative suspension primitives (`sleep`/`sleepMs`/
/// `yield`). These are the points that must suspend the continuation. The
/// callee may be a bare identifier (`sleepMs(1)`) or an object method
/// (`Coroutine.sleepMs(1)`).
fn isSuspendPrimitiveCall(node: *ASTNode) bool {
    if (node.data != .call_expr) return false;
    const c = &node.data.call_expr;
    const name = switch (c.callee.data) {
        .get_expr => |g| g.name,
        .identifier => |i| i.name,
        else => return false,
    };
    return std.mem.eql(u8, name, "sleep") or
        std.mem.eql(u8, name, "sleepMs") or
        std.mem.eql(u8, name, "yield");
}

/// True if the subtree contains a cooperative suspension primitive. Task
/// blocks and lambda bodies are coroutine boundaries — their suspensions
/// belong to those inner continuations, not this one.
fn containsTrueSuspend(node: *ASTNode) bool {
    switch (node.data) {
        .call_expr => |c| {
            if (isTaskCall(node)) return false;
            if (isSuspendPrimitiveCall(node)) return true;
            if (containsTrueSuspend(c.callee)) return true;
            for (c.arguments) |a| {
                if (containsTrueSuspend(a)) return true;
            }
        },
        .lambda_expr => return false,
        .block => |b| {
            for (b.statements) |s| {
                if (containsTrueSuspend(s)) return true;
            }
        },
        .binary_expr => |b| return containsTrueSuspend(b.left) or containsTrueSuspend(b.right),
        .unary_expr => |u| return containsTrueSuspend(u.operand),
        .get_expr => |g| return containsTrueSuspend(g.object),
        .set_expr => |s| return containsTrueSuspend(s.object) or containsTrueSuspend(s.value),
        .if_expr => |i| {
            if (containsTrueSuspend(i.condition)) return true;
            if (containsTrueSuspend(i.then_branch)) return true;
            if (i.else_branch) |e| {
                if (containsTrueSuspend(e)) return true;
            }
        },
        .while_stmt => |w| return containsTrueSuspend(w.condition) or containsTrueSuspend(w.body),
        .for_stmt => |f| return containsTrueSuspend(f.iterable) or containsTrueSuspend(f.body),
        .return_stmt => |r| return if (r.value) |v| containsTrueSuspend(v) else false,
        .assignment => |a| return containsTrueSuspend(a.value),
        .index_expr => |i| return containsTrueSuspend(i.object) or containsTrueSuspend(i.index),
        .index_set_expr => |i| return containsTrueSuspend(i.object) or containsTrueSuspend(i.index) or containsTrueSuspend(i.value),
        .try_stmt => |t| {
            if (containsTrueSuspend(t.body)) return true;
            for (t.catches) |cb| {
                if (containsTrueSuspend(cb.body)) return true;
            }
        },
        .throw_stmt => |t| return containsTrueSuspend(t.expr),
        .when_expr => |w| {
            if (w.subject) |s| {
                if (containsTrueSuspend(s)) return true;
            }
            for (w.cases) |case| {
                for (case.conds) |cond| {
                    if (containsTrueSuspend(cond)) return true;
                }
                if (containsTrueSuspend(case.body)) return true;
            }
        },
        .named_arg => |na| return containsTrueSuspend(na.value),
        .array_literal => |al| {
            for (al.elements) |e| {
                if (containsTrueSuspend(e)) return true;
            }
        },
        .map_literal => |ml| {
            for (ml.elements) |e| {
                if (containsTrueSuspend(e)) return true;
            }
        },
        .var_decl => |v| return if (v.initializer) |init| containsTrueSuspend(init) else false,
        else => {},
    }
    return false;
}

/// Collects every local variable declared in the task body (recursively, but
/// not inside task/lambda boundaries) so they can be promoted to continuation
/// body fields. Vars bound directly to `task {}/await()` are excluded — the
/// machinery rewrite owns those (they become its own locals).
fn collectLocals(allocator: std.mem.Allocator, body: []const *ASTNode) ![]CapturedVar {
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    var out = ArrayList(CapturedVar).init(allocator);
    for (body) |s| {
        try collectLocalVars(allocator, s, &seen, &out);
    }
    return out.toOwnedSlice();
}

fn collectLocalVars(
    allocator: std.mem.Allocator,
    node: *ASTNode,
    seen: *std.StringHashMap(void),
    out: *ArrayList(CapturedVar),
) !void {
    switch (node.data) {
        .var_decl => |v| {
            if (v.initializer) |init| {
                if (isTaskCall(init) or isAwaitCall(init)) return;
            }
            if (!seen.contains(v.name)) {
                try seen.put(v.name, {});
                if (node.resolved_type) |rt| {
                    try out.append(.{
                        .name = v.name,
                        .type_ref = try typeRefForEiwaType(allocator, rt),
                        .is_boxed = false,
                    });
                }
            }
            if (v.initializer) |init| try collectLocalVars(allocator, init, seen, out);
        },
        .lambda_expr => return,
        .call_expr => |c| {
            if (isTaskCall(node)) return;
            try collectLocalVars(allocator, c.callee, seen, out);
            for (c.arguments) |a| try collectLocalVars(allocator, a, seen, out);
        },
        .block => |b| {
            for (b.statements) |s| try collectLocalVars(allocator, s, seen, out);
        },
        .if_expr => |i| {
            try collectLocalVars(allocator, i.condition, seen, out);
            try collectLocalVars(allocator, i.then_branch, seen, out);
            if (i.else_branch) |e| try collectLocalVars(allocator, e, seen, out);
        },
        .while_stmt => |w| {
            try collectLocalVars(allocator, w.condition, seen, out);
            try collectLocalVars(allocator, w.body, seen, out);
        },
        .for_stmt => |f| {
            try collectLocalVars(allocator, f.iterable, seen, out);
            try collectLocalVars(allocator, f.body, seen, out);
        },
        .return_stmt => |r| if (r.value) |v| try collectLocalVars(allocator, v, seen, out),
        .assignment => |a| try collectLocalVars(allocator, a.value, seen, out),
        .binary_expr => |b| {
            try collectLocalVars(allocator, b.left, seen, out);
            try collectLocalVars(allocator, b.right, seen, out);
        },
        .unary_expr => |u| try collectLocalVars(allocator, u.operand, seen, out),
        .get_expr => |g| try collectLocalVars(allocator, g.object, seen, out),
        .set_expr => |s| {
            try collectLocalVars(allocator, s.object, seen, out);
            try collectLocalVars(allocator, s.value, seen, out);
        },
        .index_expr => |i| {
            try collectLocalVars(allocator, i.object, seen, out);
            try collectLocalVars(allocator, i.index, seen, out);
        },
        .index_set_expr => |i| {
            try collectLocalVars(allocator, i.object, seen, out);
            try collectLocalVars(allocator, i.index, seen, out);
            try collectLocalVars(allocator, i.value, seen, out);
        },
        .try_stmt => |t| {
            try collectLocalVars(allocator, t.body, seen, out);
            for (t.catches) |cb| try collectLocalVars(allocator, cb.body, seen, out);
        },
        .throw_stmt => |t| try collectLocalVars(allocator, t.expr, seen, out),
        .when_expr => |w| {
            if (w.subject) |s| try collectLocalVars(allocator, s, seen, out);
            for (w.cases) |case| {
                for (case.conds) |cond| try collectLocalVars(allocator, cond, seen, out);
                try collectLocalVars(allocator, case.body, seen, out);
            }
        },
        .named_arg => |na| try collectLocalVars(allocator, na.value, seen, out),
        .array_literal => |al| {
            for (al.elements) |e| try collectLocalVars(allocator, e, seen, out);
        },
        .map_literal => |ml| {
            for (ml.elements) |e| try collectLocalVars(allocator, e, seen, out);
        },
        else => {},
    }
}

/// A default initializer for a promoted local's continuation field. Only
/// primitive/nullable types have a sensible zero-value; anything else means the
/// state-machine path cannot promote the local (unsupported for now).
fn defaultInitializerForTypeRef(allocator: std.mem.Allocator, ref: *const ASTTypeRef) ?*ASTNode {
    _ = allocator;
    if (ref.is_nullable or ref.union_types.len > 0) return mkNullLit();
    if (std.mem.eql(u8, ref.name, "Int")) return mkIntLit(0);
    if (std.mem.eql(u8, ref.name, "Double")) return mkDoubleLit(0.0);
    if (std.mem.eql(u8, ref.name, "Bool")) return mkBoolLit(false);
    if (std.mem.eql(u8, ref.name, "String")) return mkStringLit("");
    return null;
}

/// A default initializer for a continuation body field generated by the
/// machinery rewrite. Falls back to `StackTask<T>(false, null, null)` for
/// task-valued fields (they are always assigned before being read; the
/// initializer only needs to be type-correct). Null when unsupported.
fn fieldInitializerForTypeRef(allocator: std.mem.Allocator, ref: *const ASTTypeRef) !?*ASTNode {
    if (defaultInitializerForTypeRef(allocator, ref)) |d| return d;
    if (std.mem.eql(u8, ref.name, "StackTask")) {
        const ctor = mkCall(mkIdent("StackTask"), &.{ mkBoolLit(false), mkNullLit(), mkNullLit() });
        if (ref.generic_args.len > 0) {
            const type_args = try allocator.alloc(*const ASTTypeRef, ref.generic_args.len);
            @memcpy(type_args, ref.generic_args);
            ctor.data.call_expr.type_args = type_args;
        }
        return ctor;
    }
    return null;
}

/// Collects locals declared by the machinery rewrite (var_decls whose names are
/// not already promoted) so they can be promoted to continuation body fields.
/// The type is read from the var_decl's `type_ref` (set by the machinery
/// builders) or from its resolved type.
fn collectNewLocals(
    allocator: std.mem.Allocator,
    node: *ASTNode,
    promoted_names: *std.StringHashMap(void),
    out: *ArrayList(CapturedVar),
) !void {
    switch (node.data) {
        .var_decl => |v| {
            if (!promoted_names.contains(v.name)) {
                try promoted_names.put(v.name, {});
                const tr = if (v.type_ref) |t|
                    t
                else if (node.resolved_type) |rt|
                    try typeRefForEiwaType(allocator, rt)
                else
                    null;
                if (tr) |t| {
                    try out.append(.{
                        .name = v.name,
                        .type_ref = t,
                        .is_boxed = false,
                    });
                }
            }
            if (v.initializer) |init| try collectNewLocals(allocator, init, promoted_names, out);
        },
        .lambda_expr => return,
        .block => |b| {
            for (b.statements) |s| try collectNewLocals(allocator, s, promoted_names, out);
        },
        .call_expr => |c| {
            if (isTaskCall(node)) return;
            try collectNewLocals(allocator, c.callee, promoted_names, out);
            for (c.arguments) |a| try collectNewLocals(allocator, a, promoted_names, out);
        },
        .if_expr => |i| {
            try collectNewLocals(allocator, i.condition, promoted_names, out);
            try collectNewLocals(allocator, i.then_branch, promoted_names, out);
            if (i.else_branch) |e| try collectNewLocals(allocator, e, promoted_names, out);
        },
        .while_stmt => |w| {
            try collectNewLocals(allocator, w.condition, promoted_names, out);
            try collectNewLocals(allocator, w.body, promoted_names, out);
        },
        .for_stmt => |f| {
            try collectNewLocals(allocator, f.iterable, promoted_names, out);
            try collectNewLocals(allocator, f.body, promoted_names, out);
        },
        .return_stmt => |r| if (r.value) |v| try collectNewLocals(allocator, v, promoted_names, out),
        .assignment => |a| try collectNewLocals(allocator, a.value, promoted_names, out),
        .binary_expr => |b| {
            try collectNewLocals(allocator, b.left, promoted_names, out);
            try collectNewLocals(allocator, b.right, promoted_names, out);
        },
        .unary_expr => |u| try collectNewLocals(allocator, u.operand, promoted_names, out),
        .get_expr => |g| try collectNewLocals(allocator, g.object, promoted_names, out),
        .set_expr => |s| {
            try collectNewLocals(allocator, s.object, promoted_names, out);
            try collectNewLocals(allocator, s.value, promoted_names, out);
        },
        .index_expr => |i| {
            try collectNewLocals(allocator, i.object, promoted_names, out);
            try collectNewLocals(allocator, i.index, promoted_names, out);
        },
        .index_set_expr => |i| {
            try collectNewLocals(allocator, i.object, promoted_names, out);
            try collectNewLocals(allocator, i.index, promoted_names, out);
            try collectNewLocals(allocator, i.value, promoted_names, out);
        },
        .try_stmt => |t| {
            try collectNewLocals(allocator, t.body, promoted_names, out);
            for (t.catches) |cb| try collectNewLocals(allocator, cb.body, promoted_names, out);
        },
        .throw_stmt => |t| try collectNewLocals(allocator, t.expr, promoted_names, out),
        .when_expr => |w| {
            if (w.subject) |s| try collectNewLocals(allocator, s, promoted_names, out);
            for (w.cases) |case| {
                for (case.conds) |cond| try collectNewLocals(allocator, cond, promoted_names, out);
                try collectNewLocals(allocator, case.body, promoted_names, out);
            }
        },
        .named_arg => |na| try collectNewLocals(allocator, na.value, promoted_names, out),
        .array_literal => |al| {
            for (al.elements) |e| try collectNewLocals(allocator, e, promoted_names, out);
        },
        .map_literal => |ml| {
            for (ml.elements) |e| try collectNewLocals(allocator, e, promoted_names, out);
        },
        else => {},
    }
}

/// Rewrites references to promoted variables (captures + locals) into
/// `this.<name>` field accesses, and converts their `var` declarations into
/// `this.<name> = <init>` assignments. Like `rewriteCapturedRefs` but also
/// promotes locals declared inside the block (they must survive suspension).
fn rewritePromotedRefs(allocator: std.mem.Allocator, promoted: []const CapturedVar, node: *ASTNode) !void {
    switch (node.data) {
        .identifier => |*i| {
            for (promoted) |c| {
                if (std.mem.eql(u8, i.name, c.name)) {
                    const captured_name = i.name;
                    node.data = .{ .get_expr = .{
                        .object = mkIdent("this"),
                        .name = captured_name,
                        .is_safe = false,
                        .is_boxed = c.is_boxed,
                    } };
                    return;
                }
            }
        },
        .assignment => |*a| {
            // Rewrite references inside the value first (`acc = x + acc` must
            // become `this.acc = x + this.acc`), then convert the assignment
            // to a field set — otherwise a bare `acc` in the RHS would resolve
            // to the class property and emit the box pointer instead of the
            // boxed value.
            try rewritePromotedRefs(allocator, promoted, a.value);
            for (promoted) |c| {
                if (std.mem.eql(u8, a.name, c.name)) {
                    const assignment_name = a.name;
                    const assignment_value = a.value;
                    node.data = .{ .set_expr = .{
                        .object = mkIdent("this"),
                        .name = assignment_name,
                        .value = assignment_value,
                        .is_safe = false,
                        .is_boxed = c.is_boxed,
                    } };
                    return;
                }
            }
        },
        .var_decl => |*v| {
            if (v.initializer) |init| {
                if (isCoopAwaitCall(init)) {
                    // Cooperative-await marker: keep the var_decl (the machine
                    // builder consumes it), but still rewrite references inside
                    // its receiver so a composite `val r = __CoopAwait(__taskN)`
                    // becomes `val r = __CoopAwait(this.__taskN)`.
                    try rewritePromotedRefs(allocator, promoted, init);
                    return;
                }
                if (!isTaskCall(init) and !isAwaitCall(init)) {
                    // Rewrite references inside the initializer first (a local
                    // like `val inner = __taskN` must become `this.inner =
                    // this.__taskN`), then convert the var_decl to a field set.
                    try rewritePromotedRefs(allocator, promoted, init);
                    for (promoted) |c| {
                        if (std.mem.eql(u8, v.name, c.name)) {
                            const var_name = v.name;
                            const init_value = init;
                            node.data = .{ .set_expr = .{
                                .object = mkIdent("this"),
                                .name = var_name,
                                .value = init_value,
                                .is_safe = false,
                                .is_boxed = c.is_boxed,
                            } };
                            return;
                        }
                    }
                }
            }
        },
        .lambda_expr => return,
        .block => |b| {
            for (b.statements) |s| {
                try rewritePromotedRefs(allocator, promoted, s);
            }
        },
        .call_expr => |c| {
            try rewritePromotedRefs(allocator, promoted, c.callee);
            for (c.arguments) |arg| {
                try rewritePromotedRefs(allocator, promoted, arg);
            }
        },
        .binary_expr => |b| {
            try rewritePromotedRefs(allocator, promoted, b.left);
            try rewritePromotedRefs(allocator, promoted, b.right);
        },
        .unary_expr => |u| try rewritePromotedRefs(allocator, promoted, u.operand),
        .get_expr => |g| try rewritePromotedRefs(allocator, promoted, g.object),
        .set_expr => |s| {
            try rewritePromotedRefs(allocator, promoted, s.object);
            try rewritePromotedRefs(allocator, promoted, s.value);
        },
        .if_expr => |i| {
            try rewritePromotedRefs(allocator, promoted, i.condition);
            try rewritePromotedRefs(allocator, promoted, i.then_branch);
            if (i.else_branch) |e| try rewritePromotedRefs(allocator, promoted, e);
        },
        .while_stmt => |w| {
            try rewritePromotedRefs(allocator, promoted, w.condition);
            try rewritePromotedRefs(allocator, promoted, w.body);
        },
        .for_stmt => |f| {
            try rewritePromotedRefs(allocator, promoted, f.iterable);
            try rewritePromotedRefs(allocator, promoted, f.body);
        },
        .return_stmt => |r| if (r.value) |v| try rewritePromotedRefs(allocator, promoted, v),
        .try_stmt => |t| {
            try rewritePromotedRefs(allocator, promoted, t.body);
            for (t.catches) |cb| {
                try rewritePromotedRefs(allocator, promoted, cb.body);
            }
        },
        .throw_stmt => |t| try rewritePromotedRefs(allocator, promoted, t.expr),
        .index_expr => |i| {
            try rewritePromotedRefs(allocator, promoted, i.object);
            try rewritePromotedRefs(allocator, promoted, i.index);
        },
        .index_set_expr => |i| {
            try rewritePromotedRefs(allocator, promoted, i.object);
            try rewritePromotedRefs(allocator, promoted, i.index);
            try rewritePromotedRefs(allocator, promoted, i.value);
        },
        .when_expr => |w| {
            if (w.subject) |s| try rewritePromotedRefs(allocator, promoted, s);
            for (w.cases) |case| {
                for (case.conds) |cond| try rewritePromotedRefs(allocator, promoted, cond);
                try rewritePromotedRefs(allocator, promoted, case.body);
            }
        },
        .array_literal => |al| {
            for (al.elements) |e| try rewritePromotedRefs(allocator, promoted, e);
        },
        .map_literal => |ml| {
            for (ml.elements) |e| try rewritePromotedRefs(allocator, promoted, e);
        },
        .named_arg => |na| try rewritePromotedRefs(allocator, promoted, na.value),
        else => {},
    }
}

/// A single state of the generated state machine: a straight-line statement
/// list ending in a transition (`this.label = N`, a branch, a suspend, or the
/// final done block).
const MachineState = struct {
    label: usize,
    stmts: ArrayList(*ASTNode),
};

const Machine = struct {
    allocator: std.mem.Allocator,
    counter: *usize,
    states: ArrayList(MachineState),

    fn newState(self: *Machine) !usize {
        const label = self.counter.*;
        self.counter.* += 1;
        const stmts = ArrayList(*ASTNode).init(self.allocator);
        try self.states.append(.{ .label = label, .stmts = stmts });
        return label;
    }

    fn stateIdx(self: *Machine, label: usize) !usize {
        for (self.states.items, 0..) |s, i| {
            if (s.label == label) return i;
        }
        return error.StateNotFound;
    }

    fn append(self: *Machine, label: usize, node: *ASTNode) !void {
        const idx = try self.stateIdx(label);
        try self.states.items[idx].stmts.append(node);
    }
};

/// Builds the state machine for a statement list. `after` is the label control
/// flows to when the list completes. Returns the label where the list begins.
fn machineBuildStmts(m: *Machine, stmts: []const *ASTNode, after: usize) anyerror!usize {
    var k = after;
    var i: usize = stmts.len;
    while (i > 0) {
        i -= 1;
        k = try machineBuildStmt(m, stmts[i], k);
    }
    return k;
}

/// A branch may be a block or a single statement.
fn machineBuildBranch(m: *Machine, branch: *ASTNode, after: usize) anyerror!usize {
    if (branch.data == .block) return machineBuildStmts(m, branch.data.block.statements, after);
    return machineBuildStmt(m, branch, after);
}

fn machineBuildStmt(m: *Machine, stmt: *ASTNode, after: usize) anyerror!usize {
    switch (stmt.data) {
        .while_stmt => |w| {
            if (containsTrueSuspend(w.condition)) return error.SuspendInCondition;
            const lcond = try m.newState();
            const lbody = try machineBuildBranch(m, w.body, lcond);
            const then_block = mkBlock(&.{ mkSetExpr(mkIdent("this"), "label", mkIntLit(@intCast(lbody))) });
            const else_block = mkBlock(&.{ mkSetExpr(mkIdent("this"), "label", mkIntLit(@intCast(after))) });
            try m.append(lcond, mkIfElse(w.condition, then_block, else_block));
            return lcond;
        },
        .if_expr => |i| {
            if (containsTrueSuspend(i.condition)) return error.SuspendInCondition;
            const lthen = try machineBuildBranch(m, i.then_branch, after);
            const lelse = if (i.else_branch) |e| try machineBuildBranch(m, e, after) else after;
            const entry = try m.newState();
            const then_block = mkBlock(&.{ mkSetExpr(mkIdent("this"), "label", mkIntLit(@intCast(lthen))) });
            const else_block = mkBlock(&.{ mkSetExpr(mkIdent("this"), "label", mkIntLit(@intCast(lelse))) });
            try m.append(entry, mkIfElse(i.condition, then_block, else_block));
            return entry;
        },
        .call_expr => {
            if (isSuspendPrimitiveCall(stmt)) {
                const entry = try m.newState();
                try m.append(entry, try buildSuspendCall(stmt));
                try m.append(entry, mkSetExpr(mkIdent("this"), "label", mkIntLit(@intCast(after))));
                try m.append(entry, mkReturnVoid());
                return entry;
            }
            if (containsTrueSuspend(stmt)) return error.SuspendInOperand;
            const entry = try m.newState();
            try m.append(entry, stmt);
            try m.append(entry, mkSetExpr(mkIdent("this"), "label", mkIntLit(@intCast(after))));
            return entry;
        },
        .block => |b| return machineBuildStmts(m, b.statements, after),
        else => {
            // Cooperative await marker: `val x = __CoopAwait(<recv>)`.
            if (isCoopAwaitMarker(stmt)) {
                return machineBuildCoopAwait(m, stmt, after);
            }
            if (containsTrueSuspend(stmt)) return error.SuspendInOperand;
            const entry = try m.newState();
            try m.append(entry, stmt);
            try m.append(entry, mkSetExpr(mkIdent("this"), "label", mkIntLit(@intCast(after))));
            return entry;
        },
    }
}

/// Rewrites a suspension primitive call (`sleepMs(x)`/`sleep(x)`/`yield()`) into
/// the scheduler call the continuation uses to re-schedule itself.
fn buildSuspendCall(stmt: *ASTNode) anyerror!*ASTNode {
    const c = &stmt.data.call_expr;
    const gname = switch (c.callee.data) {
        .get_expr => |g| g.name,
        .identifier => |i| i.name,
        else => unreachable,
    };
    if (std.mem.eql(u8, gname, "yield")) {
        return mkCall(mkGetExpr(mkIdent("Scheduler"), "yield"), &.{ mkIdent("this") });
    }
    const ms_arg = if (std.mem.eql(u8, gname, "sleepMs"))
        c.arguments[0]
    else
        mkBinary(.slash, c.arguments[0], mkIntLit(1000000));
    return mkCall(mkGetExpr(mkIdent("Scheduler"), "sleep"), &.{ mkIdent("this"), ms_arg });
}

/// Assembles `resume()`: `while (true) { <if/else chain over states> }`.
fn assembleMachine(m: *Machine) *ASTNode {
    var chain: *ASTNode = mkBlock(&.{ mkReturnVoid() });
    var i: usize = m.states.items.len;
    while (i > 0) {
        i -= 1;
        const s = &m.states.items[i];
        const cond = mkBinary(.eq_eq, mkGetExpr(mkIdent("this"), "label"), mkIntLit(@intCast(s.label)));
        const body_block = mkBlock(s.stmts.items);
        chain = mkIfElse(cond, body_block, chain);
    }
    return mkWhile(mkBoolLit(true), mkBlock(&.{chain}));
}

/// Generates the state-machine `resume()` for a task body containing true
/// suspension points. Locals are promoted to body fields by the caller; locals
/// created during the machinery rewrite (`__taskN`/await-result binds) are
/// promoted here, appended to `body_fields`.
fn buildResumeStateMachine(
    allocator: std.mem.Allocator,
    checker: *TypeChecker,
    captures: []const CapturedVar,
    locals: []const CapturedVar,
    body: []const *ASTNode,
    result_type: *const EiwaType,
    counter: *usize,
    generated: *ArrayList(*ASTNode),
    entry_out: *usize,
    body_fields: *ArrayList(ast.ClassProp),
) !*ASTNode {
    // 1. Promote captures + locals to `this.<name>` (incl. var_decl → set).
    var promoted = ArrayList(CapturedVar).init(allocator);
    defer promoted.deinit();
    try promoted.appendSlice(captures);
    for (locals) |l| try promoted.append(l);
    for (body) |s| try rewritePromotedRefs(allocator, promoted.items, s);

    // 2. Rewrite nested task/await machinery. In state-machine mode (`coop`)
    //    awaits become cooperative markers; the machine builder splits them.
    var rewritten = ArrayList(*ASTNode).init(allocator);
    defer rewritten.deinit();
    try rewriteStatements(allocator, checker, body, counter, generated, &rewritten, true);
    for (rewritten.items) |s| try clearResolvedTypes(allocator, s);

    // 2b. Promote locals created by the machinery rewrite (task binds like
    //     `val __taskN = StackTask(...)`, `val inner = __taskN`, and the
    //     cooperative-await result vars). They are referenced across states,
    //     so they must survive suspension as body fields.
    var promoted_names = std.StringHashMap(void).init(allocator);
    defer promoted_names.deinit();
    for (promoted.items) |p| try promoted_names.put(p.name, {});
    var new_locals = ArrayList(CapturedVar).init(allocator);
    defer new_locals.deinit();
    for (rewritten.items) |s| try collectNewLocals(allocator, s, &promoted_names, &new_locals);
    for (new_locals.items) |nl| {
        const default_init = try fieldInitializerForTypeRef(allocator, nl.type_ref) orelse
            return error.UnsupportedStateMachineLocal;
        try body_fields.append(.{
            .is_mut = true,
            .name = nl.name,
            .type_ref = nl.type_ref,
            .is_property = true,
            .initializer = default_init,
        });
        try promoted.append(nl);
    }
    // Rewrite references to the newly promoted locals (`this.__taskN`,
    // `this.inner`, `this.__awaitN`), converting their var_decls to field sets.
    // NOTE: must rewrite with `promoted` (captures + locals + new_locals), NOT
    // just `new_locals`: the machinery created in step 2 generates NEW ctor args
    // (e.g. `__TaskBlock2(__task1, i)` for a nested task capturing a local `i`)
    // that reference promoted locals created by step 1's pass. Rewriting only
    // `new_locals` leaves a bare `i` in the nested ctor arg, which the emitter
    // then treats as a boxed capture and dereferences a null pointer.
    for (rewritten.items) |s| try rewritePromotedRefs(allocator, promoted.items, s);

    // 3. Split the trailing value statement (becomes the done state's result).
    const is_void_result = result_type.* == .Void;
    var leading = ArrayList(*ASTNode).init(allocator);
    defer leading.deinit();
    var trailing: ?*ASTNode = null;
    if (!is_void_result and rewritten.items.len > 0 and isValueStatement(rewritten.items[rewritten.items.len - 1])) {
        trailing = rewritten.pop();
    }
    try leading.appendSlice(rewritten.items);

    // 4. Build the state machine (reverse: done state first).
    var m = Machine{ .allocator = allocator, .counter = counter, .states = ArrayList(MachineState).init(allocator) };
    defer m.states.deinit();
    const done_label = try m.newState();
    const entry = try machineBuildStmts(&m, leading.items, done_label);
    entry_out.* = entry;

    // 5. Done state: result store, done=true, reschedule waiter chain.
    if (trailing) |tv| {
        try m.append(done_label, mkSetExpr(mkGetExpr(mkIdent("this"), "task"), "result", tv));
    }
    try m.append(done_label, mkSetExpr(mkGetExpr(mkIdent("this"), "task"), "done", mkBoolLit(true)));
    const waiter_name = try std.fmt.allocPrint(allocator, "__waiter{d}", .{counter.*});
    counter.* += 1;
    const waiter_var = mkVarDecl(waiter_name, mkGetExpr(mkGetExpr(mkIdent("this"), "task"), "waiters"));
    waiter_var.data.var_decl.is_mut = true;
    try m.append(done_label, waiter_var);
    const while_body = mkBlock(&.{
        mkCall(
            mkGetExpr(mkIdent("Scheduler"), "schedule"),
            &.{ mkGetExpr(mkUnary(.bang_bang, mkIdent(waiter_name)), "cont") },
        ),
        mkAssign(waiter_name, mkGetExpr(mkUnary(.bang_bang, mkIdent(waiter_name)), "next")),
    });
    try m.append(done_label, mkWhile(
        mkBinary(.bang_eq, mkIdent(waiter_name), mkNullLit()),
        while_body,
    ));
    try m.append(done_label, mkSetExpr(mkGetExpr(mkIdent("this"), "task"), "waiters", mkNullLit()));
    try m.append(done_label, mkReturnVoid());

    // 6. Assemble resume().
    const resume_body = assembleMachine(&m);
    return mkFunDecl("resume", &.{}, resume_body, false, &.{.kw_implement});
}

// ---------------------------------------------------------------------------
// Rewriting task/await call sites
// ---------------------------------------------------------------------------

/// `val t = task { block }` -> machinery + `val t = __taskN`.
/// Returns the sequence: `val __taskN = StackTask<T>(false, null, null)`,
/// `Scheduler.schedule(__TaskBlockN(__taskN, <captured...>))`, `val t = __taskN`.
fn rewriteTaskCall(
    allocator: std.mem.Allocator,
    checker: *TypeChecker,
    stmt: *ASTNode,
    task_call: *ASTNode,
    counter: *usize,
    generated: *ArrayList(*ASTNode),
) ![]*ASTNode {
    const v = &stmt.data.var_decl;
    const lambda = task_call.data.call_expr.arguments[0];
    if (lambda.data != .lambda_expr) return error.InvalidTaskCall;
    const body = lambda.data.lambda_expr.body;

    const captures = try collectCaptures(allocator, checker, body);
    const result_type = blockReturnType(body);

    const n = counter.*;
    counter.* += 1;

    const block_type = try buildTaskBlockType(allocator, checker, captures, result_type, body, counter, generated);

    var out = ArrayList(*ASTNode).init(allocator);
    defer out.deinit();

    const task_name = try std.fmt.allocPrint(allocator, "__task{d}", .{n});
    const ctor_call = mkCall(mkIdent("StackTask"), &.{ mkBoolLit(false), mkNullLit(), mkNullLit() });
    {
        const type_arg_refs = std.heap.page_allocator.alloc(*const ASTTypeRef, 1) catch unreachable;
        type_arg_refs[0] = try typeRefForEiwaType(allocator, result_type);
        ctor_call.data.call_expr.type_args = type_arg_refs;
    }
    const stack_task_ref = try typeRefWithArgs(allocator, "StackTask", &.{result_type});
    const task_var = mkVarDecl(task_name, ctor_call);
    task_var.data.var_decl.type_ref = stack_task_ref;
    try out.append(task_var);

    var ctor_args = ArrayList(*ASTNode).init(allocator);
    defer ctor_args.deinit();
    try ctor_args.append(mkIdent(task_name));
    for (captures) |c| {
        // Boxed captures pass the box pointer (the outer var's heap cell) so
        // writes inside the task's resume propagate back. Reads/writes of
        // `this.<name>` inside the resume are marked `is_boxed` for double-deref.
        var arg = mkIdent(c.name);
        arg.data.identifier.is_box_ref = c.is_boxed;
        try ctor_args.append(arg);
    }
    const block_ctor_call = mkCall(mkIdent(block_type.data.type_decl.name), ctor_args.items);
    const schedule_call = mkCall(mkGetExpr(mkIdent("Scheduler"), "schedule"), &.{block_ctor_call});
    try out.append(mkExprStmt(schedule_call));

    // `val t = __taskN`
    const bind = mkVarDecl(v.name, mkIdent(task_name));
    bind.data.var_decl.type_ref = stack_task_ref;
    try out.append(bind);

    return out.toOwnedSlice();
}

/// Rewrites a bare `task { ... }` expression statement (no `val x =` binding).
/// The task machinery is generated and scheduled, but the result binding is
/// dropped — the task is fire-and-forget. Without this a bare `task {}`
/// statement is left as a runtime call to `task<T>()`, which allocates a
/// StackTask but never schedules it, so the body never runs.
fn rewriteBareTaskCall(
    allocator: std.mem.Allocator,
    checker: *TypeChecker,
    stmt: *ASTNode,
    task_call: *ASTNode,
    counter: *usize,
    generated: *ArrayList(*ASTNode),
) ![]*ASTNode {
    var temp = ASTNode{
        .line = stmt.line,
        .column = stmt.column,
        .data = .{ .var_decl = .{
            .is_mut = false,
            .name = "__bare_task",
            .type_ref = null,
            .initializer = task_call,
        } },
    };
    const gen = try rewriteTaskCall(allocator, checker, &temp, task_call, counter, generated);
    // rewriteTaskCall returns [val __taskN = ...; Scheduler.schedule(...); val t = __taskN].
    // Drop the final binding for a bare statement.
    return gen[0 .. gen.len - 1];
}

/// `val x = task { block }.await()` -> machinery + poll + `val x = result`
/// (or, in cooperative mode, machinery + a `__CoopAwait` marker).
fn rewriteTaskAwaitCall(
    allocator: std.mem.Allocator,
    checker: *TypeChecker,
    stmt: *ASTNode,
    await_call: *ASTNode,
    counter: *usize,
    generated: *ArrayList(*ASTNode),
    coop: bool,
) ![]*ASTNode {
    const v = &stmt.data.var_decl;
    const recv = await_call.data.call_expr.callee.data.get_expr.object;

    var out = ArrayList(*ASTNode).init(allocator);
    defer out.deinit();

    const machinery = try rewriteTaskCall(allocator, checker, stmt, recv, counter, generated);
    // machinery's last element binds `val t = __taskN`; use that name for the await.
    const task_name = machinery[machinery.len - 1].data.var_decl.initializer.?.data.identifier.name;

    if (coop) {
        // The composite `val r = task { ... }.await()` binds `r` to the StackTask
        // in the machinery AND to the await result in the marker. Dropping the
        // machinery bind leaves `r` owned by the marker alone — otherwise the
        // promoted body field `this.r` takes the StackTask type and `r` on the
        // RHS of later statements (e.g. `sum = sum + r`) fails to resolve.
        const result_type = stmt.resolved_type orelse recv_result_type(recv);
        try out.appendSlice(machinery[0 .. machinery.len - 1]);
        try out.append(try mkCoopAwaitMarker(allocator, mkIdent(task_name), v.name, v.is_mut, result_type));
        return out.toOwnedSlice();
    }

    try out.appendSlice(machinery);
    const poll = buildPollStmt(mkIdent(task_name));
    try out.append(poll);

    const result_val = mkUnary(.bang_bang, mkGetExpr(mkIdent(task_name), "result"));
    const bind = mkVarDecl(v.name, result_val);
    bind.data.var_decl.is_mut = v.is_mut;
    try out.append(bind);

    return out.toOwnedSlice();
}

/// `val x = <recv>.await()` -> poll + `val x = <recv>.result!!`
/// (or, in cooperative mode, a `__CoopAwait` marker).
fn rewriteAwaitCall(
    allocator: std.mem.Allocator,
    checker: *TypeChecker,
    stmt: *ASTNode,
    await_call: *ASTNode,
    coop: bool,
) ![]*ASTNode {
    _ = checker;
    const v = &stmt.data.var_decl;
    const recv = await_call.data.call_expr.callee.data.get_expr.object;

    var out = ArrayList(*ASTNode).init(allocator);
    defer out.deinit();

    if (coop) {
        const result_type = stmt.resolved_type orelse recv_result_type(recv);
        try out.append(try mkCoopAwaitMarker(allocator, recv, v.name, v.is_mut, result_type));
        return out.toOwnedSlice();
    }

    try out.append(buildPollStmt(recv));
    const result_val = mkUnary(.bang_bang, mkGetExpr(recv, "result"));
    const bind = mkVarDecl(v.name, result_val);
    bind.data.var_decl.is_mut = v.is_mut;
    try out.append(bind);
    return out.toOwnedSlice();
}

/// `return <recv>.await()` -> poll + `return <recv>.result!!`.
fn rewriteReturnAwait(
    allocator: std.mem.Allocator,
    checker: *TypeChecker,
    stmt: *ASTNode,
    await_call: *ASTNode,
) ![]*ASTNode {
    _ = checker;
    _ = stmt;
    const recv = await_call.data.call_expr.callee.data.get_expr.object;

    var out = ArrayList(*ASTNode).init(allocator);
    defer out.deinit();

    try out.append(buildPollStmt(recv));
    const ret = mkReturn(mkUnary(.bang_bang, mkGetExpr(recv, "result")));
    try out.append(ret);
    return out.toOwnedSlice();
}

/// `return task { block }.await()` -> machinery + poll + `return result`.
fn rewriteReturnTaskAwait(
    allocator: std.mem.Allocator,
    checker: *TypeChecker,
    _stmt: *ASTNode,
    await_call: *ASTNode,
    counter: *usize,
    generated: *ArrayList(*ASTNode),
) ![]*ASTNode {
    _ = _stmt;
    const recv = await_call.data.call_expr.callee.data.get_expr.object;

    var out = ArrayList(*ASTNode).init(allocator);
    defer out.deinit();

    // reuse rewriteTaskCall machinery bound to a fresh temp, then poll + return.
    var temp_stmts = ArrayList(*ASTNode).init(allocator);
    defer temp_stmts.deinit();
    const temp_name = try std.fmt.allocPrint(allocator, "__rt{d}", .{counter.*});
    counter.* += 1;
    const temp_decl = mkVarDecl(temp_name, null);
    try temp_stmts.append(temp_decl);

    const machinery = try rewriteTaskCall(allocator, checker, temp_stmts.items[0], recv, counter, generated);
    try out.appendSlice(machinery);
    const task_name = machinery[machinery.len - 1].data.var_decl.initializer.?.data.identifier.name;

    try out.append(buildPollStmt(mkIdent(task_name)));
    const ret = mkReturn(mkUnary(.bang_bang, mkGetExpr(mkIdent(task_name), "result")));
    try out.append(ret);
    return out.toOwnedSlice();
}

/// `if (!<recv>.done) { Scheduler.run() }`
fn buildPollStmt(recv: *ASTNode) *ASTNode {
    // Run the scheduler until the awaited task is done — but NOT past it:
    // `while (!recv.done && Scheduler.runStep()) {}` drains only what is
    // needed to complete `recv`, leaving independent queued tasks for their
    // own await (they are not spuriously coupled to this one).
    const not_done = mkUnary(.bang, mkGetExpr(recv, "done"));
    const step_call = mkCall(mkGetExpr(mkIdent("Scheduler"), "runStep"), &.{});
    const cond = mkBinary(.and_and, not_done, step_call);
    const body = mkBlock(&.{});
    return mkWhile(cond, body);
}

// ---------------------------------------------------------------------------
// Cooperative await (waiter-chain) inside state-machine task bodies
//
// In a task body that contains a true suspension point (sleep/yield), an
// `await()` must NOT block-poll (that would block every other cooperative
// task). Instead it registers the caller's continuation as a waiter of the
// awaited task and suspends:
//
//   `val x = <recv>.await()`  ->  `val x = __CoopAwait(<recv>)`
//
// The machine builder splits this marker into two states:
//   guard: if (!<recv>.awaitCoop(this)) { this.label = <read>; return }
//          this.label = <read>
//   read:  this.<x> = <recv>.result!!   (fast path when already done)
//          this.label = <after>
// ---------------------------------------------------------------------------

/// True when a node is a call to the internal `__CoopAwait` marker function.
fn isCoopAwaitCall(node: *ASTNode) bool {
    if (node.data != .call_expr) return false;
    const callee = node.data.call_expr.callee;
    if (callee.data != .identifier) return false;
    return std.mem.eql(u8, callee.data.identifier.name, "__CoopAwait");
}

/// True when a statement is the cooperative-await marker
/// `val <name> = __CoopAwait(<recv>)`.
fn isCoopAwaitMarker(node: *ASTNode) bool {
    if (node.data != .var_decl) return false;
    const v = &node.data.var_decl;
    const init = v.initializer orelse return false;
    return isCoopAwaitCall(init);
}

/// The await result type for a receiver whose resolved type is `StackTask<T>`.
fn recv_result_type(recv: *ASTNode) ?*const EiwaType {
    if (recv.resolved_type) |rt| {
        const t = singleTypeArg(rt);
        if (t.* != .Void) return t;
    }
    return null;
}

/// Builds `val <name> = __CoopAwait(<recv>)`. The var's type is the await
/// result type (from the statement's resolved type or the receiver's resolved
/// `StackTask<T>`), so it can be promoted to a continuation body field with a
/// zero-value default.
fn mkCoopAwaitMarker(
    allocator: std.mem.Allocator,
    recv: *ASTNode,
    name: []const u8,
    is_mut: bool,
    result_type: ?*const EiwaType,
) !*ASTNode {
    const marker = mkVarDecl(name, mkCall(mkIdent("__CoopAwait"), &.{recv}));
    marker.data.var_decl.is_mut = is_mut;
    if (result_type) |t| {
        if (t.* != .Void) {
            marker.data.var_decl.type_ref = try typeRefForEiwaType(allocator, t);
        }
    }
    return marker;
}

/// Builds the two states for a cooperative await marker and returns the label
/// where the guard state begins.
fn machineBuildCoopAwait(m: *Machine, stmt: *ASTNode, after: usize) anyerror!usize {
    const v = &stmt.data.var_decl;
    const recv = v.initializer.?.data.call_expr.arguments[0];

    const guard_label = try m.newState();
    const read_label = try m.newState();

    // guard: if (!<recv>.awaitCoop(this)) { this.label = <read>; return }
    //        this.label = <read>
    const not_ready = mkUnary(.bang, mkCall(mkGetExpr(recv, "awaitCoop"), &.{mkIdent("this")}));
    const suspend_block = mkBlock(&.{
        mkSetExpr(mkIdent("this"), "label", mkIntLit(@intCast(read_label))),
        mkReturnVoid(),
    });
    const fall_block = mkBlock(&.{ mkSetExpr(mkIdent("this"), "label", mkIntLit(@intCast(read_label))) });
    try m.append(guard_label, mkIfElse(not_ready, suspend_block, fall_block));

    // read: this.<x> = <recv>.result!! ; this.label = <after>
    const result_get = mkUnary(.bang_bang, mkGetExpr(recv, "result"));
    try m.append(read_label, mkSetExpr(mkIdent("this"), v.name, result_get));
    try m.append(read_label, mkSetExpr(mkIdent("this"), "label", mkIntLit(@intCast(after))));

    return guard_label;
}

// ---------------------------------------------------------------------------
// Node builders
// ---------------------------------------------------------------------------

fn mkIdent(name: []const u8) *ASTNode {
    const n = std.heap.page_allocator.create(ASTNode) catch unreachable;
    n.* = .{
        .line = 0,
        .column = 0,
        .data = .{ .identifier = .{
            .name = name,
            .resolved_c_name = null,
        } },
    };
    return n;
}

fn mkIntLit(value: i64) *ASTNode {
    const n = std.heap.page_allocator.create(ASTNode) catch unreachable;
    n.* = .{
        .line = 0,
        .column = 0,
        .data = .{ .int_literal = value },
    };
    return n;
}

fn mkBoolLit(value: bool) *ASTNode {
    const n = std.heap.page_allocator.create(ASTNode) catch unreachable;
    n.* = .{
        .line = 0,
        .column = 0,
        .data = .{ .bool_literal = value },
    };
    return n;
}

fn mkNullLit() *ASTNode {
    const n = std.heap.page_allocator.create(ASTNode) catch unreachable;
    n.* = .{
        .line = 0,
        .column = 0,
        .data = .null_literal,
    };
    return n;
}

fn mkVarDecl(name: []const u8, initializer: ?*ASTNode) *ASTNode {
    const n = std.heap.page_allocator.create(ASTNode) catch unreachable;
    n.* = .{
        .line = 0,
        .column = 0,
        .data = .{ .var_decl = .{
            .is_mut = false,
            .name = name,
            .type_ref = null,
            .initializer = initializer,
        } },
    };
    return n;
}

fn mkExprStmt(expr: *ASTNode) *ASTNode {
    const n = std.heap.page_allocator.create(ASTNode) catch unreachable;
    const copy = std.heap.page_allocator.alloc(*ASTNode, 1) catch unreachable;
    copy[0] = expr;
    n.* = .{
        .line = 0,
        .column = 0,
        .data = .{ .block = .{ .statements = copy } },
    };
    return n;
}

fn mkCall(callee: *ASTNode, args: []const *ASTNode) *ASTNode {
    const n = std.heap.page_allocator.create(ASTNode) catch unreachable;
    const copy = std.heap.page_allocator.alloc(*ASTNode, args.len) catch unreachable;
    @memcpy(copy, args);
    n.* = .{
        .line = 0,
        .column = 0,
        .data = .{ .call_expr = .{
            .callee = callee,
            .arguments = copy,
        } },
    };
    return n;
}

fn mkGetExpr(object: *ASTNode, name: []const u8) *ASTNode {
    const n = std.heap.page_allocator.create(ASTNode) catch unreachable;
    n.* = .{
        .line = 0,
        .column = 0,
        .data = .{ .get_expr = .{
            .object = object,
            .name = name,
            .is_safe = false,
        } },
    };
    return n;
}

fn mkSetExpr(object: *ASTNode, name: []const u8, value: *ASTNode) *ASTNode {
    const n = std.heap.page_allocator.create(ASTNode) catch unreachable;
    n.* = .{
        .line = 0,
        .column = 0,
        .data = .{ .set_expr = .{
            .object = object,
            .name = name,
            .value = value,
            .is_safe = false,
        } },
    };
    return n;
}

fn mkAssign(name: []const u8, value: *ASTNode) *ASTNode {
    const n = std.heap.page_allocator.create(ASTNode) catch unreachable;
    n.* = .{
        .line = 0,
        .column = 0,
        .data = .{ .assignment = .{
            .name = name,
            .value = value,
        } },
    };
    return n;
}

fn mkBlock(statements: []const *ASTNode) *ASTNode {
    const n = std.heap.page_allocator.create(ASTNode) catch unreachable;
    const copy = std.heap.page_allocator.alloc(*ASTNode, statements.len) catch unreachable;
    @memcpy(copy, statements);
    n.* = .{
        .line = 0,
        .column = 0,
        .data = .{ .block = .{ .statements = copy } },
    };
    return n;
}

fn mkIf(condition: *ASTNode, then_branch: *ASTNode) *ASTNode {
    const n = std.heap.page_allocator.create(ASTNode) catch unreachable;
    n.* = .{
        .line = 0,
        .column = 0,
        .data = .{ .if_expr = .{
            .condition = condition,
            .then_branch = then_branch,
            .else_branch = null,
        } },
    };
    return n;
}

fn mkIfElse(condition: *ASTNode, then_branch: *ASTNode, else_branch: *ASTNode) *ASTNode {
    const n = std.heap.page_allocator.create(ASTNode) catch unreachable;
    n.* = .{
        .line = 0,
        .column = 0,
        .data = .{ .if_expr = .{
            .condition = condition,
            .then_branch = then_branch,
            .else_branch = else_branch,
        } },
    };
    return n;
}

fn mkDoubleLit(value: f64) *ASTNode {
    const n = std.heap.page_allocator.create(ASTNode) catch unreachable;
    n.* = .{
        .line = 0,
        .column = 0,
        .data = .{ .double_literal = value },
    };
    return n;
}

fn mkStringLit(value: []const u8) *ASTNode {
    const n = std.heap.page_allocator.create(ASTNode) catch unreachable;
    n.* = .{
        .line = 0,
        .column = 0,
        .data = .{ .string_literal = value },
    };
    return n;
}

fn mkWhile(condition: *ASTNode, body: *ASTNode) *ASTNode {
    const n = std.heap.page_allocator.create(ASTNode) catch unreachable;
    n.* = .{
        .line = 0,
        .column = 0,
        .data = .{ .while_stmt = .{
            .condition = condition,
            .body = body,
        } },
    };
    return n;
}

fn mkBinary(op: ast.TokenType, left: *ASTNode, right: *ASTNode) *ASTNode {
    const n = std.heap.page_allocator.create(ASTNode) catch unreachable;
    n.* = .{
        .line = 0,
        .column = 0,
        .data = .{ .binary_expr = .{
            .left = left,
            .op = op,
            .right = right,
        } },
    };
    return n;
}

fn mkUnary(op: ast.TokenType, operand: *ASTNode) *ASTNode {
    const n = std.heap.page_allocator.create(ASTNode) catch unreachable;
    n.* = .{
        .line = 0,
        .column = 0,
        .data = .{ .unary_expr = .{
            .operator = op,
            .operand = operand,
        } },
    };
    return n;
}

fn mkReturn(value: *ASTNode) *ASTNode {
    const n = std.heap.page_allocator.create(ASTNode) catch unreachable;
    n.* = .{
        .line = 0,
        .column = 0,
        .data = .{ .return_stmt = .{ .value = value } },
    };
    return n;
}

fn mkReturnVoid() *ASTNode {
    const n = std.heap.page_allocator.create(ASTNode) catch unreachable;
    n.* = .{
        .line = 0,
        .column = 0,
        .data = .{ .return_stmt = .{ .value = null } },
    };
    return n;
}

fn mkFunDecl(name: []const u8, params: []const ast.Param, body: *ASTNode, is_expr_body: bool, modifiers: []const ast.TokenType) *ASTNode {
    const n = std.heap.page_allocator.create(ASTNode) catch unreachable;
    n.* = .{
        .line = 0,
        .column = 0,
        .data = .{ .fun_decl = .{
            .annotations = &.{},
            .modifiers = modifiers,
            .name = name,
            .generic_params = &.{},
            .params = @constCast(params),
            .type_ref = if (std.mem.eql(u8, name, "isDone")) blk: {
                const tr = std.heap.page_allocator.create(ASTTypeRef) catch unreachable;
                tr.* = .{
                    .name = "Bool",
                    .generic_args = &.{},
                    .is_array = false,
                    .is_nullable = false,
                };
                break :blk tr;
            } else null,
            .body = body,
            .is_expr_body = is_expr_body,
            .resolved_c_name = null,
        } },
    };
    return n;
}

/// Clears resolved types so re-inference descends into rewritten subtrees.
/// NOTE: `expected_type` is intentionally PRESERVED: it is a type hint set by a
/// parent's inference (e.g. an array literal default `= []` materialized into a
/// call's arguments gets its `List<T>` expected type). Re-inference infers a
/// call's arguments BEFORE resolving the callee (infer_call.zig pre-loop), so
/// without the preserved hint an empty array literal would lose its expected
/// type and fail with "Cannot infer type of empty array literal".
fn clearResolvedTypes(allocator: std.mem.Allocator, node: *ASTNode) !void {
    node.resolved_type = null;
    switch (node.data) {
        .type_decl => |t| {
            for (t.primary_constructor) |prop| {
                if (prop.initializer) |init| try clearResolvedTypes(allocator, init);
            }
            for (t.methods) |m| {
                try clearResolvedTypes(allocator, m);
            }
        },
        .object_decl => |o| {
            for (o.members) |m| {
                try clearResolvedTypes(allocator, m);
            }
        },
        .test_decl => |td| {
            if (td.body.data == .block) {
                for (td.body.data.block.statements) |s| {
                    try clearResolvedTypes(allocator, s);
                }
            }
        },
        .fun_decl => |f| {
            if (f.body.data == .block) {
                for (f.body.data.block.statements) |s| {
                    try clearResolvedTypes(allocator, s);
                }
            }
        },
        .var_decl => |v| {
            if (v.initializer) |init| try clearResolvedTypes(allocator, init);
        },
        .call_expr => |c| {
            try clearResolvedTypes(allocator, c.callee);
            for (c.arguments) |arg| {
                try clearResolvedTypes(allocator, arg);
            }
        },
        .binary_expr => |b| {
            try clearResolvedTypes(allocator, b.left);
            try clearResolvedTypes(allocator, b.right);
        },
        .unary_expr => |u| try clearResolvedTypes(allocator, u.operand),
        .get_expr => |g| try clearResolvedTypes(allocator, g.object),
        .set_expr => |s| {
            try clearResolvedTypes(allocator, s.object);
            try clearResolvedTypes(allocator, s.value);
        },
        .block => |b| {
            for (b.statements) |s| {
                try clearResolvedTypes(allocator, s);
            }
        },
        .if_expr => |i| {
            try clearResolvedTypes(allocator, i.condition);
            try clearResolvedTypes(allocator, i.then_branch);
            if (i.else_branch) |e| try clearResolvedTypes(allocator, e);
        },
        .while_stmt => |w| {
            try clearResolvedTypes(allocator, w.condition);
            try clearResolvedTypes(allocator, w.body);
        },
        .for_stmt => |f| {
            try clearResolvedTypes(allocator, f.iterable);
            try clearResolvedTypes(allocator, f.body);
        },
        .return_stmt => |r| if (r.value) |v| try clearResolvedTypes(allocator, v),
        .assignment => |a| try clearResolvedTypes(allocator, a.value),
        .try_stmt => |t| {
            try clearResolvedTypes(allocator, t.body);
            for (t.catches) |cb| {
                try clearResolvedTypes(allocator, cb.body);
            }
        },
        .throw_stmt => |t| try clearResolvedTypes(allocator, t.expr),
        .index_expr => |i| {
            try clearResolvedTypes(allocator, i.object);
            try clearResolvedTypes(allocator, i.index);
        },
        .index_set_expr => |i| {
            try clearResolvedTypes(allocator, i.object);
            try clearResolvedTypes(allocator, i.index);
            try clearResolvedTypes(allocator, i.value);
        },
        .when_expr => |w| {
            if (w.subject) |s| try clearResolvedTypes(allocator, s);
            for (w.cases) |case| {
                for (case.conds) |cond| try clearResolvedTypes(allocator, cond);
                try clearResolvedTypes(allocator, case.body);
            }
        },
        .lambda_expr => |l| {
            for (l.body) |s| {
                try clearResolvedTypes(allocator, s);
            }
        },
        .named_arg => |na| try clearResolvedTypes(allocator, na.value),
        .array_literal => |al| {
            for (al.elements) |e| try clearResolvedTypes(allocator, e);
        },
        .map_literal => |ml| {
            for (ml.elements) |e| try clearResolvedTypes(allocator, e);
        },
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Type reference helpers
// ---------------------------------------------------------------------------

/// Builds an `ASTTypeRef` describing an `EiwaType`.
fn typeRefForEiwaType(allocator: std.mem.Allocator, t: *const EiwaType) !*const ASTTypeRef {
    switch (t.*) {
        .Int => return typeRefSimple("Int"),
        .Bool => return typeRefSimple("Bool"),
        .String => return typeRefSimple("String"),
        .Void => return typeRefSimple("Void"),
        .Double => return typeRefSimple("Double"),
        .Null => return typeRefSimple("Nothing?"),
        .Custom => |name| {
            return typeRefSimple(name);
        },
        .GenericInstance => |gi| {
            var args = ArrayList(*const ASTTypeRef).init(allocator);
            for (gi.type_args) |arg| {
                try args.append(try typeRefForEiwaType(allocator, arg));
            }
            const ref = try allocator.create(ASTTypeRef);
            ref.* = .{
                .name = gi.base_name,
                .generic_args = try args.toOwnedSlice(),
                .is_array = false,
                .is_nullable = false,
            };
            return ref;
        },
        .Union => |u| {
            var parts = ArrayList(*const ASTTypeRef).init(allocator);
            try parts.append(try typeRefForEiwaType(allocator, u.left));
            try parts.append(try typeRefForEiwaType(allocator, u.right));
            const ref = try allocator.create(ASTTypeRef);
            ref.* = .{
                .name = "",
                .generic_args = &.{},
                .is_array = false,
                .is_nullable = false,
                .union_types = try parts.toOwnedSlice(),
            };
            return ref;
        },
        else => return typeRefSimple("Int"),
    }
}

/// Builds `Name<T1, T2, ...>` type ref from a base name and resolved type args.
fn typeRefWithArgs(allocator: std.mem.Allocator, name: []const u8, args: []const *const EiwaType) !*const ASTTypeRef {
    var arg_refs = ArrayList(*const ASTTypeRef).init(allocator);
    for (args) |arg| {
        try arg_refs.append(try typeRefForEiwaType(allocator, arg));
    }
    const ref = try allocator.create(ASTTypeRef);
    ref.* = .{
        .name = name,
        .generic_args = try arg_refs.toOwnedSlice(),
        .is_array = false,
        .is_nullable = false,
    };
    return ref;
}

fn singleTypeArg(t: *const EiwaType) *const EiwaType {
    switch (t.*) {
        .GenericInstance => |gi| {
            if (gi.type_args.len > 0) return gi.type_args[0];
        },
        .Pointer => |e| return singleTypeArg(e),
        .Array => |e| return e,
        else => {},
    }
    return &defaultVoidType;
}

var typeRefInt = ASTTypeRef{ .name = "Int", .generic_args = &.{}, .is_array = false, .is_nullable = false };

fn typeRefSimple(name: []const u8) *const ASTTypeRef {
    const n = std.heap.page_allocator.create(ASTTypeRef) catch unreachable;
    n.* = .{
        .name = name,
        .generic_args = &.{},
        .is_array = false,
        .is_nullable = false,
    };
    return n;
}
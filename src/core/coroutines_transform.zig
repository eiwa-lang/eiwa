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
        if (stmt.data != .fun_decl) continue;
        if (!stmt.data.fun_decl.is_suspend) continue;
        try transformFunction(allocator, checker, stmt, &counter, &generated);
    }

    // Collect continuation types produced during re-inference (monomorphized
    // generic instantiations such as `StackTask<Int>`, registered by
    // `monomorphizeClass` while `resolveTypeRef` runs inside the transform).
    for (checker.monomorphized_nodes.items) |mono| {
        if (mono.data != .type_decl) continue;
        if (containsNode(generated.items, mono)) continue;
        try generated.append(mono);
    }

    if (generated.items.len == 0) return;

    // Splice generated types into program statements right after the imports
    // (mirrors the splice `core_validate` performs for monomorphized nodes).
    var insert_idx: usize = 0;
    for (module.data.program.statements, 0..) |s, i| {
        if (s.data == .import_stmt) insert_idx = i + 1;
    }
    const old = module.data.program.statements;
    const new_stmts = try allocator.alloc(*ASTNode, old.len + generated.items.len);
    @memcpy(new_stmts[0..insert_idx], old[0..insert_idx]);
    @memcpy(new_stmts[insert_idx..][0..generated.items.len], generated.items);
    @memcpy(new_stmts[insert_idx + generated.items.len ..], old[insert_idx..]);
    module.data.program.statements = new_stmts;
}

fn containsNode(nodes: []const *ASTNode, target: *ASTNode) bool {
    for (nodes) |n| {
        if (n == target) return true;
    }
    return false;
}

/// Rewrites a suspend function's body and re-validates it so the generated
/// machinery resolves. Only bodies that actually contain `task {}`/`.await()`
/// constructs are rewritten.
fn transformFunction(
    allocator: std.mem.Allocator,
    checker: *TypeChecker,
    node: *ASTNode,
    counter: *usize,
    generated: *ArrayList(*ASTNode),
) !void {
    var f = &node.data.fun_decl;
    if (f.body.data != .block) return;
    if (!hasTaskOrAwait(f.body)) return;

    var new_stmts = ArrayList(*ASTNode).init(allocator);
    defer new_stmts.deinit();
    try rewriteStatements(allocator, checker, f.body.data.block.statements, counter, generated, &new_stmts);
    f.body.data.block.statements = try new_stmts.toOwnedSlice();

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
) anyerror!void {
    for (stmts) |stmt| {
        const handled = try rewriteStatement(allocator, checker, stmt, counter, generated, out);
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
                        const gen = try rewriteTaskAwaitCall(allocator, checker, stmt, init, counter, generated);
                        try out.appendSlice(gen);
                        return true;
                    }
                    const gen = try rewriteAwaitCall(allocator, checker, stmt, init);
                    try out.appendSlice(gen);
                    return true;
                }
                if (containsAwait(init)) {
                    var preamble = ArrayList(*ASTNode).init(allocator);
                    defer preamble.deinit();
                    if (try hoistAwaitsFromExpr(allocator, checker, init, counter, &preamble)) {
                        try rewritePreamble(allocator, checker, &preamble, counter, generated, out);
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
                        try rewritePreamble(allocator, checker, &preamble, counter, generated, out);
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
            try rewriteStatements(allocator, checker, b.statements, counter, generated, &new_stmts);
            b.statements = try new_stmts.toOwnedSlice();
            return false;
        },
        .if_expr => |*i| {
            if (containsAwait(i.condition)) {
                var preamble = ArrayList(*ASTNode).init(allocator);
                defer preamble.deinit();
                if (try hoistAwaitsFromExpr(allocator, checker, i.condition, counter, &preamble)) {
                    try rewritePreamble(allocator, checker, &preamble, counter, generated, out);
                }
            }
            try rewriteBranch(allocator, checker, i.then_branch, counter, generated);
            if (i.else_branch) |e| {
                try rewriteBranch(allocator, checker, e, counter, generated);
            }
            return false;
        },
        .while_stmt => |*w| {
            if (containsAwait(w.condition)) {
                var preamble = ArrayList(*ASTNode).init(allocator);
                defer preamble.deinit();
                if (try hoistAwaitsFromExpr(allocator, checker, w.condition, counter, &preamble)) {
                    try rewritePreamble(allocator, checker, &preamble, counter, generated, out);
                }
            }
            try rewriteBranch(allocator, checker, w.body, counter, generated);
            return false;
        },
        .for_stmt => |*f| {
            try rewriteBranch(allocator, checker, f.iterable, counter, generated);
            try rewriteBranch(allocator, checker, f.body, counter, generated);
            return false;
        },
        .try_stmt => |*t| {
            try rewriteBranch(allocator, checker, t.body, counter, generated);
            for (t.catches) |*cb| {
                try rewriteBranch(allocator, checker, cb.body, counter, generated);
            }
            return false;
        },
        else => {
            if (containsAwait(stmt)) {
                var preamble = ArrayList(*ASTNode).init(allocator);
                defer preamble.deinit();
                if (try hoistAwaitsFromExpr(allocator, checker, stmt, counter, &preamble)) {
                    try rewritePreamble(allocator, checker, &preamble, counter, generated, out);
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
) anyerror!void {
    if (branch.data == .block) {
        var new_stmts = ArrayList(*ASTNode).init(allocator);
        defer new_stmts.deinit();
        try rewriteStatements(allocator, checker, branch.data.block.statements, counter, generated, &new_stmts);
        branch.data.block.statements = try new_stmts.toOwnedSlice();
        return;
    }
    var out = ArrayList(*ASTNode).init(allocator);
    defer out.deinit();
    const handled = try rewriteStatement(allocator, checker, branch, counter, generated, &out);
    if (handled) {
        if (out.items.len == 1) {
            branch.* = out.items[0].*;
        }
    }
}

/// Rewrites a hoisted await preamble (a list of `val __awaitN = <recv>.await()`
/// statements produced by `hoistAwaitsFromExpr`) into poll + result form.
fn rewritePreamble(
    allocator: std.mem.Allocator,
    checker: *TypeChecker,
    preamble: *ArrayList(*ASTNode),
    counter: *usize,
    generated: *ArrayList(*ASTNode),
    out: *ArrayList(*ASTNode),
) anyerror!void {
    for (preamble.items) |stmt| {
        const handled = try rewriteStatement(allocator, checker, stmt, counter, generated, out);
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
                    } };
                    return;
                }
            }
        },
        .assignment => |*a| {
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
                    } };
                    return;
                }
            }
            try rewriteCapturedRefs(allocator, captures, a.value);
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
        try clearResolvedTypes(allocator, copy);
        const decl = mkVarDecl(name, copy);
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
        try props.append(.{
            .is_mut = true,
            .name = c.name,
            .type_ref = c.type_ref,
        });
    }

    var methods = ArrayList(*ASTNode).init(allocator);
    defer methods.deinit();
    try methods.append(try buildResume(allocator, checker, captures, body, counter, generated));
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
    try rewriteStatements(allocator, checker, body, counter, generated, &rewritten);

    // Nodes rewritten above (captured refs -> `this.<name>`) keep stale resolved
    // types from the first validation pass. Clear them so re-inference descends
    // into the rewritten subtrees (e.g. the object `this` of `this.x`).
    for (rewritten.items) |s| {
        try clearResolvedTypes(allocator, s);
    }

    var stmts = ArrayList(*ASTNode).init(allocator);
    defer stmts.deinit();

    // The last rewritten statement is the block result; it becomes
    // `this.task.result = <last>`.
    const result_expr = if (rewritten.items.len > 0) rewritten.pop() else mkIntLit(0);

    // result store: this.task.result = <last>
    const task_get = mkGetExpr(mkIdent("this"), "task");
    const result_set = mkSetExpr(task_get, "result", result_expr);
    try stmts.appendSlice(rewritten.items);
    try stmts.append(result_set);

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
    const task_var = mkVarDecl(task_name, ctor_call);
    try out.append(task_var);

    var ctor_args = ArrayList(*ASTNode).init(allocator);
    defer ctor_args.deinit();
    try ctor_args.append(mkIdent(task_name));
    for (captures) |c| {
        var arg = mkIdent(c.name);
        if (c.is_boxed) arg.data.identifier.is_boxed = true;
        try ctor_args.append(arg);
    }
    const block_ctor_call = mkCall(mkIdent(block_type.data.type_decl.name), ctor_args.items);
    const schedule_call = mkCall(mkGetExpr(mkIdent("Scheduler"), "schedule"), &.{block_ctor_call});
    try out.append(mkExprStmt(schedule_call));

    // `val t = __taskN`
    const bind = mkVarDecl(v.name, mkIdent(task_name));
    try out.append(bind);

    return out.toOwnedSlice();
}

/// `val x = task { block }.await()` -> machinery + poll + `val x = result`.
fn rewriteTaskAwaitCall(
    allocator: std.mem.Allocator,
    checker: *TypeChecker,
    stmt: *ASTNode,
    await_call: *ASTNode,
    counter: *usize,
    generated: *ArrayList(*ASTNode),
) ![]*ASTNode {
    const v = &stmt.data.var_decl;
    const recv = await_call.data.call_expr.callee.data.get_expr.object;

    var out = ArrayList(*ASTNode).init(allocator);
    defer out.deinit();

    const machinery = try rewriteTaskCall(allocator, checker, stmt, recv, counter, generated);
    try out.appendSlice(machinery);
    // machinery's last element binds `val t = __taskN`; use that name for the poll.
    const task_name = machinery[machinery.len - 1].data.var_decl.initializer.?.data.identifier.name;

    const poll = buildPollStmt(mkIdent(task_name));
    try out.append(poll);

    const result_val = mkUnary(.bang_bang, mkGetExpr(mkIdent(task_name), "result"));
    const bind = mkVarDecl(v.name, result_val);
    bind.data.var_decl.is_mut = v.is_mut;
    try out.append(bind);

    return out.toOwnedSlice();
}

/// `val x = <recv>.await()` -> poll + `val x = <recv>.result!!`.
fn rewriteAwaitCall(
    allocator: std.mem.Allocator,
    checker: *TypeChecker,
    stmt: *ASTNode,
    await_call: *ASTNode,
) ![]*ASTNode {
    _ = checker;
    const v = &stmt.data.var_decl;
    const recv = await_call.data.call_expr.callee.data.get_expr.object;

    var out = ArrayList(*ASTNode).init(allocator);
    defer out.deinit();

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
    const cond = mkUnary(.bang, mkGetExpr(recv, "done"));
    const body = mkBlock(&.{
        mkExprStmt(mkCall(mkGetExpr(mkIdent("Scheduler"), "run"), &.{})),
    });
    return mkIf(cond, body);
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

fn clearResolvedTypes(allocator: std.mem.Allocator, node: *ASTNode) !void {
    node.resolved_type = null;
    node.expected_type = null;
    switch (node.data) {
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
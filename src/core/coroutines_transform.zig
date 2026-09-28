//! Stackless coroutine transform: entry + orchestration. Lowers `task {}`
//! /`await()` into Continuation state machines + Scheduler calls:
//!
//!   `val t = task { block }`       ->  schedule `__TaskBlockN`, `val t = __taskN`
//!   `val x = <recv>.await()`       ->  `if (!<recv>.done) { Scheduler.run() }`
//!   `return <recv>.await()`        ->  poll + `return <recv>.result!!`
//!   `val x = task { ... }.await()` ->  machinery + poll + result
//!   await as an operand            ->  hoisted `val __awaitN = ...`
//!
//! Generated types register via `inferTypeDecl`, then bodies re-validate via
//! `inferFunDecl` so every generated identifier resolves.

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
const syn = @import("coroutine_syntax.zig");
const cctx = @import("coroutine_ctx.zig");
const eng = @import("coroutine_engine.zig");
const Ctx = cctx.Ctx;
const clearResolvedTypes = cctx.clearResolvedTypes;

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn transformProgram(allocator: std.mem.Allocator, registry: *ModuleRegistry) !void {
    var counter: usize = 0;
    for (registry.ordered_modules.items) |path| {
        const mod = registry.modules.get(path) orelse continue;
        try transformModule(allocator, mod.checker, mod.ast_root, &counter);
    }
}

fn transformModule(allocator: std.mem.Allocator, checker: *TypeChecker, module: *ASTNode, counter: *usize) !void {
    if (module.data != .program) return;

    for (module.data.program.statements) |stmt| {
        switch (stmt.data) {
            .import_stmt, .fun_decl, .type_decl, .contract_decl, .skill_decl, .test_decl, .lib_decl, .object_decl, .enum_decl => {},
            else => {
                if (syn.hasTaskOrAwait(stmt)) {
                    checker.reportError(stmt.line, stmt.column, "TypeError: task {{}} and await() cannot be used in top-level statements (they would silently do nothing). Wrap them in fun main() {{ ... }}.", .{});
                    return error.TypeError;
                }
            },
        }
    }

    var generated = ArrayList(*ASTNode).init(allocator);
    defer generated.deinit();
    const ctx = Ctx{ .allocator = allocator, .checker = checker, .counter = counter, .generated = &generated };

    for (module.data.program.statements) |stmt| {
        if (stmt.data == .fun_decl) {
            // Even when NOT suspend: bare fire-and-forget tasks need the machinery.
            // rewriteFunctionBody's hasTaskOrAwait guard filters the rest.
            // Generic templates are skipped: they are never validated nor
            // emitted directly (their bodies carry no resolved types, so
            // capture collection would silently miss everything); each
            // monomorphized copy is a separate statement and is transformed.
            if (stmt.data.fun_decl.generic_params.len > 0) continue;
            try transformFunction(ctx, stmt);
        } else if (stmt.data == .type_decl) {
            const t = &stmt.data.type_decl;
            // Same as above: skip the unvalidated generic template; its
            // monomorphized copies are transformed as concrete types.
            if (t.generic_params.len > 0) continue;
            var type_rewritten = false;
            for (t.methods) |m_node| {
                if (m_node.data != .fun_decl) continue;
                if (try rewriteFunctionBody(ctx, m_node)) type_rewritten = true;
            }
            if (type_rewritten) {
                // Re-infer the whole type so method bodies (with the generated
                // machinery) get resolved types in the class scope (`this`).
                try clearResolvedTypes(ctx, stmt);
                var t2: EiwaType = undefined;
                checker.pass = .validation;
                try infer_decl.inferTypeDecl(checker, stmt, &checker.global_scope, &t2);
            }
        } else if (stmt.data == .object_decl) {
            const o = &stmt.data.object_decl;
            var obj_rewritten = false;
            for (o.members) |member| {
                if (member.data != .fun_decl) continue;
                if (try rewriteFunctionBody(ctx, member)) obj_rewritten = true;
            }
            if (obj_rewritten) {
                try clearResolvedTypes(ctx, stmt);
                var t3: EiwaType = undefined;
                checker.pass = .validation;
                try infer_decl.inferObjectDecl(checker, stmt, &checker.global_scope, &t3);
            }
        } else if (stmt.data == .test_decl) {
            // `test` blocks hold task/await directly (no enclosing fun).
            const td = &stmt.data.test_decl;
            if (td.body.data == .block) {
                var test_stmts = ArrayList(*ASTNode).init(allocator);
                defer test_stmts.deinit();
                const before = generated.items.len;
                try eng.rewriteStatements(ctx, td.body.data.block.statements, &test_stmts, false);
                if (generated.items.len > before or test_stmts.items.len != td.body.data.block.statements.len) {
                    try syn.appendSchedulerDrain(&test_stmts);
                    td.body.data.block.statements = try test_stmts.toOwnedSlice();
                    try clearResolvedTypes(ctx, stmt);
                    checker.pass = .validation;
                    _ = try checker.inferNode(stmt, &checker.global_scope);
                } else {
                    td.body.data.block.statements = try test_stmts.toOwnedSlice();
                }
            }
        }
    }

    // Continuation types produced during re-inference (e.g. `StackTask<Int>`).
    var mono_types = ArrayList(*ASTNode).init(allocator);
    defer mono_types.deinit();
    for (checker.monomorphized_nodes.items) |mono| {
        if (mono.data != .type_decl) continue;
        if (containsNode(generated.items, mono)) continue;
        try mono_types.append(mono);
    }

    if (generated.items.len == 0 and mono_types.items.len == 0) return;

    // Splice generated types right after the imports. Monomorphized types
    // come FIRST: continuations reference them, so they must declare first.
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

fn rewriteFunctionBody(ctx: Ctx, node: *ASTNode) !bool {
    var f = &node.data.fun_decl;
    if (f.body.data != .block) return false;
    if (!syn.hasTaskOrAwait(f.body)) return false;

    var new_stmts = ArrayList(*ASTNode).init(ctx.allocator);
    defer new_stmts.deinit();
    try eng.rewriteStatements(ctx, f.body.data.block.statements, &new_stmts, false);
    if (std.mem.eql(u8, f.name, "main")) {
        try syn.appendSchedulerDrain(&new_stmts);
    }
    const rewritten = try new_stmts.toOwnedSlice();
    f.body.data.block.statements = rewritten;
    return true;
}

fn transformFunction(ctx: Ctx, node: *ASTNode) !void {
    if (!try rewriteFunctionBody(ctx, node)) return;

    // Re-validate so every generated identifier/call gets resolved types.
    try clearResolvedTypes(ctx, node);
    var t: EiwaType = undefined;
    ctx.checker.pass = .validation;
    try infer_decl.inferFunDecl(ctx.checker, node, &ctx.checker.global_scope, &t);
}


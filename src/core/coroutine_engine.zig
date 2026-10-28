//! Lowers `task {}`/`await()` into Continuation state machines + Scheduler calls.

const std = @import("std");
const compat = @import("compat.zig");
const ArrayList = compat.ArrayList;
const ast = @import("ast.zig");
const ASTNode = ast.ASTNode;
const infer_decl = @import("type_checker/infer_decl.zig");
const ts = @import("type_system.zig");
const EiwaType = ts.EiwaType;
const syn = @import("coroutine_syntax.zig");
const cctx = @import("coroutine_ctx.zig");
const caps = @import("coroutine_captures.zig");
const Ctx = cctx.Ctx;
const CapturedVar = cctx.CapturedVar;
const outer_this_field = cctx.outer_this_field;
const clearResolvedTypes = cctx.clearResolvedTypes;

const ASTTypeRef = ast.ASTTypeRef;

pub fn rewriteStatements(ctx: Ctx, stmts: []const *ASTNode, out: *ArrayList(*ASTNode), coop: bool) anyerror!void {
    for (stmts) |stmt| {
        const handled = try rewriteStatement(ctx, stmt, out, coop);
        if (!handled) try out.append(stmt);
    }
}

/// Returns true when the statement was fully replaced and must not be appended.
pub fn rewriteStatement(ctx: Ctx, stmt: *ASTNode, out: *ArrayList(*ASTNode), coop: bool) !bool {
    // Hoist nested `task {}` first so every position composes (call args,
    // var initializers, return values, conditions). Direct shapes keep their
    // dedicated arms below and are skipped here.
    if (!isDirectTaskShape(stmt)) {
        var task_pre = ArrayList(*ASTNode).init(ctx.allocator);
        defer task_pre.deinit();
        var tasks_hoisted = false;
        try hoistTasksWalk(ctx, stmt, &task_pre, &tasks_hoisted);
        if (tasks_hoisted) try out.appendSlice(task_pre.items);
    }
    switch (stmt.data) {
        .var_decl => |*v| {
            if (v.initializer) |init| {
                if (syn.isTaskCall(init)) {
                    const gen = try rewriteTaskCall(ctx, stmt, init);
                    try out.appendSlice(gen);
                    return true;
                }
                if (syn.isAwaitCall(init)) {
                    const recv = init.data.call_expr.callee.data.get_expr.object;
                    if (syn.isTaskCall(recv)) {
                        const gen = try rewriteTaskAwaitCall(ctx, stmt, init, coop);
                        try out.appendSlice(gen);
                        return true;
                    }
                    const gen = try rewriteAwaitCall(ctx, stmt, init, coop);
                    try out.appendSlice(gen);
                    return true;
                }
                if (syn.containsAwait(init)) {
                    var preamble = ArrayList(*ASTNode).init(ctx.allocator);
                    defer preamble.deinit();
                    if (try hoistAwaitsFromExpr(ctx, init, &preamble)) {
                        try rewritePreamble(ctx, &preamble, out, coop);
                        try out.append(stmt);
                        return true;
                    }
                }
            }
            return false;
        },
        .assignment => |*a| {
            if (syn.isTaskCall(a.value)) {
                var temp_stmts = ArrayList(*ASTNode).init(ctx.allocator);
                defer temp_stmts.deinit();
                const temp_name = try std.fmt.allocPrint(ctx.allocator, "__task_tmp{d}", .{ctx.counter.*});
                ctx.counter.* += 1;
                const temp_decl = syn.mkVarDecl(temp_name, null);
                try temp_stmts.append(temp_decl);
                const gen = try rewriteTaskCall(ctx, temp_stmts.items[0], a.value);
                try out.appendSlice(gen);
                const task_name = gen[gen.len - 1].data.var_decl.initializer.?.data.identifier.name;
                const assign = syn.mkAssign(a.name, syn.mkIdent(task_name));
                assign.data.assignment.is_boxed = a.is_boxed;
                assign.data.assignment.is_class_property = a.is_class_property;
                assign.data.assignment.owner_type_c_name = a.owner_type_c_name;
                assign.resolved_type = stmt.resolved_type;
                try out.append(assign);
                return true;
            }
            if (syn.isAwaitCall(a.value) or syn.containsAwait(a.value)) {
                var preamble = ArrayList(*ASTNode).init(ctx.allocator);
                defer preamble.deinit();
                if (try hoistAwaitsFromExpr(ctx, a.value, &preamble)) {
                    try rewritePreamble(ctx, &preamble, out, coop);
                    try out.append(stmt);
                    return true;
                }
            }
            return false;
        },
        .return_stmt => |*r| {
            if (r.value) |val| {
                if (syn.isAwaitCall(val)) {
                    const recv = val.data.call_expr.callee.data.get_expr.object;
                    if (syn.isTaskCall(recv)) {
                        const gen = try rewriteReturnTaskAwait(ctx, stmt, val);
                        try out.appendSlice(gen);
                        return true;
                    }
                    const gen = try rewriteReturnAwait(ctx, stmt, val);
                    try out.appendSlice(gen);
                    return true;
                }
                if (syn.containsAwait(val)) {
                    var preamble = ArrayList(*ASTNode).init(ctx.allocator);
                    defer preamble.deinit();
                    if (try hoistAwaitsFromExpr(ctx, val, &preamble)) {
                        try rewritePreamble(ctx, &preamble, out, coop);
                        try out.append(stmt);
                        return true;
                    }
                }
            }
            return false;
        },
        .break_stmt => |b| {
            if (b.value) |val| {
                if (syn.containsAwait(val)) {
                    var preamble = ArrayList(*ASTNode).init(ctx.allocator);
                    defer preamble.deinit();
                    if (try hoistAwaitsFromExpr(ctx, val, &preamble)) {
                        try rewritePreamble(ctx, &preamble, out, coop);
                        try out.append(stmt);
                        return true;
                    }
                }
            }
            return false;
        },
        .block => |*b| {
            var new_stmts = ArrayList(*ASTNode).init(ctx.allocator);
            defer new_stmts.deinit();
            try rewriteStatements(ctx, b.statements, &new_stmts, coop);
            b.statements = try new_stmts.toOwnedSlice();
            return false;
        },
        .if_expr => |*i| {
            if (syn.containsAwait(i.condition)) {
                var preamble = ArrayList(*ASTNode).init(ctx.allocator);
                defer preamble.deinit();
                if (try hoistAwaitsFromExpr(ctx, i.condition, &preamble)) {
                    try rewritePreamble(ctx, &preamble, out, coop);
                }
            }
            try rewriteBranch(ctx, i.then_branch, coop);
            if (i.else_branch) |e| {
                try rewriteBranch(ctx, e, coop);
            }
            return false;
        },
        .while_stmt => |*w| {
            if (syn.containsAwait(w.condition)) {
                var preamble = ArrayList(*ASTNode).init(ctx.allocator);
                defer preamble.deinit();
                if (try hoistAwaitsFromExpr(ctx, w.condition, &preamble)) {
                    try rewritePreamble(ctx, &preamble, out, coop);
                }
            }
            try rewriteBranch(ctx, w.body, coop);
            return false;
        },
        .for_stmt => |*f| {
            if (f.collect) {
                ctx.checker.reportError(stmt.line, stmt.column, "TypeError: for used as a value is not supported inside suspend context yet.", .{});
                return error.TypeError;
            }
            if (syn.containsTrueSuspend(f.body) or syn.containsAwait(f.body) or syn.containsTrueSuspend(f.iterable) or syn.containsAwait(f.iterable)) {
                const n = ctx.counter.*;
                ctx.counter.* += 1;
                const arr_name = try std.fmt.allocPrint(ctx.allocator, "__for_arr{d}", .{n});
                const i_name = try std.fmt.allocPrint(ctx.allocator, "__for_i{d}", .{n});
                const len_name = try std.fmt.allocPrint(ctx.allocator, "__for_len{d}", .{n});

                const iter_type = f.iterable.resolved_type orelse (ctx.checker.inferNode(f.iterable, &ctx.checker.global_scope) catch null);

                const arr_decl = syn.mkVarDecl(arr_name, f.iterable);
                arr_decl.resolved_type = iter_type;
                if (iter_type) |rt| {
                    arr_decl.data.var_decl.type_ref = try syn.typeRefForEiwaType(ctx.allocator, rt);
                }
                if (!try rewriteStatement(ctx, arr_decl, out, coop)) {
                    try out.append(arr_decl);
                }

                const i_decl = syn.mkVarDecl(i_name, syn.mkIntLit(0));
                i_decl.data.var_decl.is_mut = true;
                i_decl.data.var_decl.type_ref = syn.typeRefSimple("Int");
                try out.append(i_decl);

                const len_expr = syn.mkGetExpr(syn.mkUnary(.bang_bang, syn.mkIdent(arr_name)), "length");

                const len_decl = syn.mkVarDecl(len_name, len_expr);
                len_decl.data.var_decl.type_ref = syn.typeRefSimple("Int");
                try out.append(len_decl);

                const cond = syn.mkBinary(.less, syn.mkIdent(i_name), syn.mkIdent(len_name));

                var while_stmts = ArrayList(*ASTNode).init(ctx.allocator);
                defer while_stmts.deinit();

                if (f.index_name) |idx_name| {
                    const idx_decl = syn.mkVarDecl(idx_name, syn.mkIdent(i_name));
                    idx_decl.data.var_decl.type_ref = syn.typeRefSimple("Int");
                    try while_stmts.append(idx_decl);
                }

                const item_val = syn.mkIndexExpr(syn.mkUnary(.bang_bang, syn.mkIdent(arr_name)), syn.mkIdent(i_name));
                const item_decl = syn.mkVarDecl(f.item_name, item_val);
                if (iter_type) |rt| {
                    if (rt.* == .Array) {
                        item_decl.resolved_type = rt.Array;
                        item_decl.data.var_decl.type_ref = try syn.typeRefForEiwaType(ctx.allocator, rt.Array);
                    }
                }
                try while_stmts.append(item_decl);

                if (f.body.data == .block) {
                    for (f.body.data.block.statements) |bs| {
                        try while_stmts.append(bs);
                    }
                } else {
                    try while_stmts.append(f.body);
                }

                const inc = syn.mkAssign(i_name, syn.mkBinary(.plus, syn.mkIdent(i_name), syn.mkIntLit(1)));
                try while_stmts.append(inc);

                const while_body = syn.mkBlock(try while_stmts.toOwnedSlice());
                const while_node = syn.mkWhile(cond, while_body);

                if (!try rewriteStatement(ctx, while_node, out, coop)) {
                    try out.append(while_node);
                }
                return true;
            }
            try rewriteBranch(ctx, f.iterable, coop);
            try rewriteBranch(ctx, f.body, coop);
            return false;
        },
        .try_stmt => |*t| {
            try rewriteBranch(ctx, t.body, coop);
            for (t.catches) |*cb| {
                try rewriteBranch(ctx, cb.body, coop);
            }
            return false;
        },
        else => {
            if (stmt.data == .call_expr and syn.isTaskCall(stmt)) {
                const gen = try rewriteBareTaskCall(ctx, stmt, stmt);
                try out.appendSlice(gen);
                return true;
            }
            if (syn.containsAwait(stmt)) {
                var preamble = ArrayList(*ASTNode).init(ctx.allocator);
                defer preamble.deinit();
                if (try hoistAwaitsFromExpr(ctx, stmt, &preamble)) {
                    try rewritePreamble(ctx, &preamble, out, coop);
                    try out.append(stmt);
                    return true;
                }
            }
            return false;
        },
    }
}

pub fn rewriteBranch(ctx: Ctx, branch: *ASTNode, coop: bool) anyerror!void {
    if (branch.data == .block) {
        var new_stmts = ArrayList(*ASTNode).init(ctx.allocator);
        defer new_stmts.deinit();
        try rewriteStatements(ctx, branch.data.block.statements, &new_stmts, coop);
        branch.data.block.statements = try new_stmts.toOwnedSlice();
        return;
    }
    var out = ArrayList(*ASTNode).init(ctx.allocator);
    defer out.deinit();
    const handled = try rewriteStatement(ctx, branch, &out, coop);
    if (handled) {
        if (out.items.len == 1) {
            branch.* = out.items[0].*;
        }
    }
}

pub fn rewritePreamble(ctx: Ctx, preamble: *ArrayList(*ASTNode), out: *ArrayList(*ASTNode), coop: bool) anyerror!void {
    for (preamble.items) |stmt| {
        const handled = try rewriteStatement(ctx, stmt, out, coop);
        if (!handled) try out.append(stmt);
    }
}

pub fn hoistAwaitsFromExpr(ctx: Ctx, expr: *ASTNode, preamble: *ArrayList(*ASTNode)) !bool {
    var hoisted = false;
    try hoistAwaitsWalk(ctx, expr, preamble, &hoisted);
    return hoisted;
}

pub fn hoistAwaitsWalk(ctx: Ctx, node: *ASTNode, preamble: *ArrayList(*ASTNode), hoisted: *bool) !void {
    try walkExpr(ctx, node, preamble, hoisted, awaitAction);
}

fn awaitAction(ctx: Ctx, node: *ASTNode, preamble: *ArrayList(*ASTNode), hoisted: *bool) !bool {
    if (syn.isAwaitCall(node)) {
        const name = try std.fmt.allocPrint(ctx.allocator, "__await{d}", .{ctx.counter.*});
        ctx.counter.* += 1;
        const copy = try ctx.allocator.create(ASTNode);
        copy.* = node.*;
        const await_result = node.resolved_type;
        copy.resolved_type = null;
        copy.expected_type = null;
        const decl = syn.mkVarDecl(name, copy);
        if (await_result) |rt| decl.resolved_type = rt;
        try preamble.append(decl);
        node.data = .{ .identifier = .{
            .name = name,
            .resolved_c_name = null,
        } };
        hoisted.* = true;
        return true;
    }
    if (syn.isTaskCall(node)) return true;
    return false;
}

fn taskAction(ctx: Ctx, node: *ASTNode, preamble: *ArrayList(*ASTNode), hoisted: *bool) !bool {
    if (syn.isTaskCall(node)) {
        const temp_name = try std.fmt.allocPrint(ctx.allocator, "__taskhoist{d}", .{ctx.counter.*});
        ctx.counter.* += 1;
        const temp_decl = syn.mkVarDecl(temp_name, null);
        temp_decl.line = node.line;
        temp_decl.column = node.column;
        const gen = try rewriteTaskCall(ctx, temp_decl, node);
        try preamble.appendSlice(gen);
        const task_name = gen[gen.len - 1].data.var_decl.initializer.?.data.identifier.name;
        const saved_rt = node.resolved_type;
        const saved_exp = node.expected_type;
        node.data = .{ .identifier = .{
            .name = task_name,
            .resolved_c_name = null,
        } };
        node.resolved_type = saved_rt;
        node.expected_type = saved_exp;
        hoisted.* = true;
        return true;
    }
    if (syn.isAwaitCall(node)) return true;
    return false;
}

fn walkExpr(ctx: Ctx, node: *ASTNode, preamble: *ArrayList(*ASTNode), hoisted: *bool, action: *const fn (Ctx, *ASTNode, *ArrayList(*ASTNode), *bool) anyerror!bool) !void {
    if (try action(ctx, node, preamble, hoisted)) return;
    switch (node.data) {
        .call_expr => |*c| {
            try walkExpr(ctx, c.callee, preamble, hoisted, action);
            for (c.arguments) |arg| {
                try walkExpr(ctx, arg, preamble, hoisted, action);
            }
        },
        .lambda_expr => return,
        .binary_expr => |*b| {
            try walkExpr(ctx, b.left, preamble, hoisted, action);
            try walkExpr(ctx, b.right, preamble, hoisted, action);
        },
        .unary_expr => |*u| try walkExpr(ctx, u.operand, preamble, hoisted, action),
        .get_expr => |*g| try walkExpr(ctx, g.object, preamble, hoisted, action),
        .set_expr => |*s| {
            try walkExpr(ctx, s.object, preamble, hoisted, action);
            try walkExpr(ctx, s.value, preamble, hoisted, action);
        },
        .index_expr => |*i| {
            try walkExpr(ctx, i.object, preamble, hoisted, action);
            try walkExpr(ctx, i.index, preamble, hoisted, action);
        },
        .index_set_expr => |*i| {
            try walkExpr(ctx, i.object, preamble, hoisted, action);
            try walkExpr(ctx, i.index, preamble, hoisted, action);
            try walkExpr(ctx, i.value, preamble, hoisted, action);
        },
        .array_literal => |*al| {
            for (al.elements) |e| {
                try walkExpr(ctx, e, preamble, hoisted, action);
            }
        },
        .string_template => |*st| {
            for (st.parts) |e| {
                try walkExpr(ctx, e, preamble, hoisted, action);
            }
        },
        .map_literal => |*ml| {
            for (ml.elements) |e| {
                try walkExpr(ctx, e, preamble, hoisted, action);
            }
        },
        .named_arg => |*na| try walkExpr(ctx, na.value, preamble, hoisted, action),
        .assignment => |*a| try walkExpr(ctx, a.value, preamble, hoisted, action),
        .var_decl => |*v| if (v.initializer) |init| try walkExpr(ctx, init, preamble, hoisted, action),
        .return_stmt => |*r| if (r.value) |v| try walkExpr(ctx, v, preamble, hoisted, action),
        .break_stmt => |*b| if (b.value) |v| try walkExpr(ctx, v, preamble, hoisted, action),
        else => {},
    }
}

fn isDirectTaskShape(stmt: *ASTNode) bool {
    if (syn.isTaskCall(stmt)) return true;
    switch (stmt.data) {
        .var_decl => |v| {
            if (v.initializer) |init| {
                if (syn.isTaskCall(init)) return true;
            }
        },
        .assignment => |a| {
            if (syn.isTaskCall(a.value)) return true;
        },
        else => {},
    }
    return false;
}

pub fn hoistTasksWalk(ctx: Ctx, node: *ASTNode, preamble: *ArrayList(*ASTNode), hoisted: *bool) !void {
    try walkExpr(ctx, node, preamble, hoisted, taskAction);
}

// ---------------------------------------------------------------------------
// Generated type construction
// ---------------------------------------------------------------------------

pub fn buildTaskBlockType(ctx: Ctx, captures: []const CapturedVar, result_type: *const EiwaType, body: []const *ASTNode) !*ASTNode {
    const type_name = try std.fmt.allocPrint(ctx.allocator, "__TaskBlock{d}", .{ctx.counter.*});

    var props = ArrayList(ast.ClassProp).init(ctx.allocator);
    defer props.deinit();

    const task_ref = try syn.typeRefWithArgs(ctx.allocator, "StackTask", &.{result_type});
    try props.append(.{
        .is_mut = false,
        .name = "task",
        .type_ref = task_ref,
    });

    for (captures) |c| {
        // Boxed captures share the heap box so writes propagate back.
        try props.append(.{
            .is_mut = true,
            .name = c.name,
            .type_ref = c.type_ref,
            .is_boxed = c.is_boxed,
        });
    }

    var methods = ArrayList(*ASTNode).init(ctx.allocator);
    defer methods.deinit();

    var body_fields = ArrayList(ast.ClassProp).init(ctx.allocator);
    defer body_fields.deinit();

    // NOTE: `.await()` alone does NOT trigger the state machine yet.
    var state_machine = false;
    for (body) |s| {
        if (syn.containsTrueSuspend(s)) {
            state_machine = true;
            break;
        }
    }
    if (!state_machine) {
        for (body) |s| {
            if (stmtHasSuspendCall(ctx, s)) {
                state_machine = true;
                break;
            }
        }
    }

    var work_body: []const *ASTNode = body;
    if (state_machine) {
        work_body = try narrowingFixupList(ctx, work_body);
        work_body = try expandSuspendCalls(ctx, work_body);
    }

    if (state_machine) {
        for (work_body) |s| {
            if (suspendConditionNode(s)) |bad| {
                if (bad.data == .if_expr or bad.data == .while_stmt) {
                    ctx.checker.reportError(bad.line, bad.column, "TypeError: suspend call in condition is not supported inside task blocks (suspend calls can only be used as separate statements).", .{});
                } else {
                    ctx.checker.reportError(bad.line, bad.column, "TypeError: suspend call as a value is not supported inside task blocks (suspend calls can only be used as separate statements).", .{});
                }
                return error.TypeError;
            }
        }
    }

    var resume_method: *ASTNode = undefined;
    if (state_machine) {
        const locals = try caps.collectPromotableLocals(ctx, work_body);
        defer ctx.allocator.free(locals);
        for (locals) |l| {
            const prop_type_ref = l.type_ref;
            // Keep the source nullability: the field is assigned before use
            // (program order). No placeholder initializer for types without a
            // zero value; the backend zero-fills and no read precedes a write.
            const default_init = syn.defaultInitializerForTypeRef(l.type_ref);
            try body_fields.append(.{
                .is_mut = true,
                .name = l.name,
                .type_ref = prop_type_ref,
                .is_property = true,
                .initializer = default_init,
            });
        }
        var entry_label: usize = 0;
        resume_method = try buildResumeStateMachine(ctx, captures, locals, work_body, result_type, &entry_label, &body_fields, false);
        try methods.append(resume_method);
        try body_fields.append(.{
            .is_mut = true,
            .name = "label",
            .type_ref = syn.typeRefSimple("Int"),
            .is_property = true,
            .initializer = syn.mkIntLit(@intCast(entry_label)),
        });
    } else {
        try methods.append(try buildResume(ctx, captures, work_body, result_type));
    }
    try methods.append(syn.buildIsDone());

    const type_node = try ctx.allocator.create(ASTNode);
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

    try registerGeneratedType(ctx, type_node);
    return type_node;
}

/// Completes a task: result store, done=true and waiter-chain drain under the
/// task lock, so no waiter registered by `awaitCoop` is orphaned.
pub fn buildCompletionStmts(ctx: Ctx, result: ?*ASTNode) !ArrayList(*ASTNode) {
    var out = ArrayList(*ASTNode).init(ctx.allocator);
    errdefer out.deinit();
    const task_get = syn.mkGetExpr(syn.mkIdent("this"), "task");
    const task_mutex = syn.mkGetExpr(task_get, "mutex");
    try out.append(syn.mkExprStmt(syn.mkCall(syn.mkGetExpr(task_mutex, "lock"), &.{})));
    if (result) |re| {
        try out.append(syn.mkSetExpr(task_get, "result", re));
    }
    try out.append(syn.mkSetExpr(task_get, "done", syn.mkBoolLit(true)));
    const waiter_name = try std.fmt.allocPrint(ctx.allocator, "__waiter{d}", .{ctx.counter.*});
    ctx.counter.* += 1;
    const waiter_var = syn.mkVarDecl(waiter_name, syn.mkGetExpr(task_get, "waiters"));
    waiter_var.data.var_decl.is_mut = true;
    try out.append(waiter_var);
    try out.append(syn.mkSetExpr(task_get, "waiters", syn.mkNullLit()));
    try out.append(syn.mkExprStmt(syn.mkCall(syn.mkGetExpr(task_mutex, "unlock"), &.{})));
    const while_body = syn.mkBlock(&.{
        syn.mkCall(
            syn.mkGetExpr(syn.mkIdent("Scheduler"), "scheduleState"),
            &.{
                syn.mkGetExpr(syn.mkUnary(.bang_bang, syn.mkIdent(waiter_name)), "cont"),
                syn.mkGetExpr(syn.mkUnary(.bang_bang, syn.mkIdent(waiter_name)), "excState"),
            },
        ),
        syn.mkAssign(waiter_name, syn.mkGetExpr(syn.mkUnary(.bang_bang, syn.mkIdent(waiter_name)), "next")),
    });
    try out.append(syn.mkWhile(
        syn.mkBinary(.bang_eq, syn.mkIdent(waiter_name), syn.mkNullLit()),
        while_body,
    ));
    return out;
}

/// Completion for suspend-callee machines: task result/done plus scheduling
/// the caller that drove this machine.
fn buildSuspendCompletionStmts(ctx: Ctx, result: ?*ASTNode) !ArrayList(*ASTNode) {
    var out = try buildCompletionStmts(ctx, result);
    errdefer out.deinit();
    const caller_get = syn.mkGetExpr(syn.mkIdent("this"), "caller");
    const not_null = syn.mkBinary(.bang_eq, caller_get, syn.mkNullLit());
    const schedule_call = syn.mkExprStmt(syn.mkCall(
        syn.mkGetExpr(syn.mkIdent("Scheduler"), "schedule"),
        &.{syn.mkUnary(.bang_bang, syn.mkGetExpr(syn.mkIdent("this"), "caller"))},
    ));
    try out.append(syn.mkIf(not_null, syn.mkBlock(&.{schedule_call})));
    return out;
}

/// Void results need no temp/target (a Void-typed temp would emit an invalid
/// void load in the backend).
fn isVoidRef(ref: *const ast.ASTTypeRef) bool {
    return ref.name.len == 4 and std.mem.eql(u8, ref.name, "Void") and !ref.is_nullable and ref.generic_args.len == 0;
}

fn suspendMarkerCall(node: *ASTNode) ?*ASTNode {
    const call = switch (node.data) {
        .var_decl => |v| v.initializer orelse return null,
        .call_expr => node,
        else => return null,
    };
    if (call.data != .call_expr) return null;
    const c = &call.data.call_expr;
    if (c.callee.data != .identifier) return null;
    if (!std.mem.eql(u8, c.callee.data.identifier.name, "__SuspendCall")) return null;
    return call;
}

fn suspendSiteOf(m: *Machine, marker: *ASTNode) ?*cctx.SuspendSite {
    for (m.ctx.suspend_sites.items) |*s| {
        if (s.marker == marker) return s;
    }
    return null;
}

/// Declare a nullable per-site machine slot and return its field name.
fn declareSuspendSlot(m: *Machine, machine: []const u8) ![]const u8 {
    const n = m.counter.*;
    m.counter.* += 1;
    const slot = try std.fmt.allocPrint(m.allocator, "__sm{d}", .{n});
    const slot_ref = syn.typeRefSimple(machine);
    const nullable_ref = try caps.makeNullableTypeRef(m.ctx, slot_ref);
    try m.fields.append(.{
        .is_mut = true,
        .name = slot,
        .type_ref = nullable_ref,
        .is_property = true,
        .initializer = syn.mkNullLit(),
    });
    return slot;
}

/// Emit the caller-side drive protocol for a suspend marker.
/// S_run constructs the callee machine, drives one resume, parks on S_done
/// and returns unconditionally. S_done runs exactly once: the callee
/// schedules its caller upon completion, whether it suspended or completed
/// synchronously. (Continuing inline on synchronous completion would race
/// with that schedule and run the continuation twice.)
fn buildSuspendProtocol(m: *Machine, site: *cctx.SuspendSite, target: ?[]const u8, after: usize) !usize {
    const slot = try declareSuspendSlot(m, site.machine);
    const s_run = try m.newState();
    const s_done = try m.newState();

    var ctor_args = ArrayList(*ASTNode).init(m.allocator);
    defer ctor_args.deinit();
    const handle_ctor = syn.mkCall(syn.mkIdent("StackTask"), &.{ syn.mkBoolLit(false), syn.mkNullLit(), syn.mkNullLit() });
    {
        const type_arg_refs = try m.allocator.alloc(*const ast.ASTTypeRef, 1);
        type_arg_refs[0] = site.result;
        handle_ctor.data.call_expr.type_args = type_arg_refs;
    }
    try ctor_args.append(handle_ctor);
    // Marker args: [receiver-or-null, real args...]. Only the first slot is
    // the receiver (dropped when null = free function); real null args pass
    // through untouched. `caller=this` always closes the list.
    const marker_call = site.marker.data.call_expr;
    var ai: usize = 0;
    for (marker_call.arguments) |a| {
        if (ai > 0 or a.data != .null_literal) try ctor_args.append(a);
        ai += 1;
    }
    try ctor_args.append(syn.mkIdent("this"));
    const ctor = syn.mkCall(syn.mkIdent(site.machine), ctor_args.items);
    try m.append(s_run, syn.mkSetExpr(syn.mkIdent("this"), slot, ctor));

    const sm = syn.mkUnary(.bang_bang, syn.mkGetExpr(syn.mkIdent("this"), slot));
    try m.append(s_run, syn.mkExprStmt(syn.mkCall(syn.mkGetExpr(sm, "resume"), &.{})));
    try m.append(s_run, syn.mkSetExpr(syn.mkIdent("this"), "label", syn.mkIntLit(@intCast(s_done))));
    try m.append(s_run, syn.mkReturnVoid());

    if (target) |t| {
        const task_get = syn.mkGetExpr(syn.mkUnary(.bang_bang, syn.mkGetExpr(syn.mkIdent("this"), slot)), "task");
        const result_get = syn.mkUnary(.bang_bang, syn.mkGetExpr(task_get, "result"));
        try m.append(s_done, syn.mkSetExpr(syn.mkIdent("this"), t, result_get));
    }
    try m.append(s_done, syn.mkSetExpr(syn.mkIdent("this"), "label", syn.mkIntLit(@intCast(after))));
    return s_run;
}

pub fn buildResume(ctx: Ctx, captures: []const CapturedVar, body: []const *ASTNode, result_type: *const EiwaType) !*ASTNode {
    for (body) |s| {
        try caps.rewriteCapturedRefs(ctx, captures, s);
    }
    var rewritten = ArrayList(*ASTNode).init(ctx.allocator);
    defer rewritten.deinit();
    try rewriteStatements(ctx, body, &rewritten, false);

    // Rewritten refs keep stale types; clear them so re-inference descends.
    for (rewritten.items) |s| {
        try clearResolvedTypes(ctx, s);
    }

    var stmts = ArrayList(*ASTNode).init(ctx.allocator);
    defer stmts.deinit();

    // The last statement is the block result, unless Void or side-effect-only.
    const is_void_result = result_type.* == .Void;
    const last_is_value = if (rewritten.items.len > 0) syn.isValueStatement(rewritten.items[rewritten.items.len - 1]) else false;
    const has_result = !is_void_result and last_is_value;
    const result_expr = if (has_result) rewritten.pop() else null;

    try stmts.appendSlice(rewritten.items);
    var completion = try buildCompletionStmts(ctx, result_expr);
    defer completion.deinit();
    try stmts.appendSlice(completion.items);

    const block_body = syn.mkBlock(try stmts.toOwnedSlice());
    return syn.mkFunDecl("resume", &.{}, block_body, false, &.{.kw_implement});
}

pub fn registerGeneratedType(ctx: Ctx, type_node: *ASTNode) !void {
    var t: EiwaType = undefined;
    ctx.checker.pass = .validation;
    try infer_decl.inferTypeDecl(ctx.checker, type_node, &ctx.checker.global_scope, &t);
    try ctx.generated.append(type_node);
}

// ---------------------------------------------------------------------------
// Suspension state machines: bodies with sleep/yield become a
// `switch(label)` dispatch over states; others stay single-shot.
// ---------------------------------------------------------------------------

const MachineState = struct {
    label: usize,
    stmts: ArrayList(*ASTNode),
};

const Machine = struct {
    allocator: std.mem.Allocator,
    counter: *usize,
    states: ArrayList(MachineState),
    ctx: Ctx,
    /// Extra fields declared while building states (per-site suspend-machine
    /// slots). Flushed into the generated type's body_fields by the caller.
    fields: *ArrayList(ast.ClassProp),
    /// Callee machines complete via caller-scheduling instead of the task
    /// waiter drain.
    is_callee: bool,

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

pub fn machineBuildStmts(m: *Machine, stmts: []const *ASTNode, after: usize) anyerror!usize {
    var k = after;
    var i: usize = stmts.len;
    while (i > 0) {
        i -= 1;
        k = try machineBuildStmt(m, stmts[i], k);
    }
    return k;
}

pub fn machineBuildBranch(m: *Machine, branch: *ASTNode, after: usize) anyerror!usize {
    if (branch.data == .block) return machineBuildStmts(m, branch.data.block.statements, after);
    return machineBuildStmt(m, branch, after);
}

pub fn machineBuildStmt(m: *Machine, stmt: *ASTNode, after: usize) anyerror!usize {
    if (stmt.data == .for_stmt and stmt.data.for_stmt.collect) return error.CollectForInSuspend;
    switch (stmt.data) {
        .while_stmt => |w| {
            if (syn.containsTrueSuspend(w.condition)) return error.SuspendInCondition;
            const lcond = try m.newState();
            const lbody = try machineBuildBranch(m, w.body, lcond);
            const then_block = syn.mkBlock(&.{syn.mkSetExpr(syn.mkIdent("this"), "label", syn.mkIntLit(@intCast(lbody)))});
            const else_block = syn.mkBlock(&.{syn.mkSetExpr(syn.mkIdent("this"), "label", syn.mkIntLit(@intCast(after)))});
            try m.append(lcond, syn.mkIfElse(w.condition, then_block, else_block));
            return lcond;
        },
        .if_expr => |i| {
            if (syn.containsTrueSuspend(i.condition)) return error.SuspendInCondition;
            const lthen = try machineBuildBranch(m, i.then_branch, after);
            const lelse = if (i.else_branch) |e| try machineBuildBranch(m, e, after) else after;
            const entry = try m.newState();
            const then_block = syn.mkBlock(&.{syn.mkSetExpr(syn.mkIdent("this"), "label", syn.mkIntLit(@intCast(lthen)))});
            const else_block = syn.mkBlock(&.{syn.mkSetExpr(syn.mkIdent("this"), "label", syn.mkIntLit(@intCast(lelse)))});
            try m.append(entry, syn.mkIfElse(i.condition, then_block, else_block));
            return entry;
        },
        .call_expr => {
            if (syn.isSuspendPrimitiveCall(stmt)) {
                const entry = try m.newState();
                // Set the label BEFORE suspending: another thread may resume
                // immediately and would otherwise re-run this state.
                try m.append(entry, syn.mkSetExpr(syn.mkIdent("this"), "label", syn.mkIntLit(@intCast(after))));
                try m.append(entry, try buildSuspendCall(stmt));
                try m.append(entry, syn.mkReturnVoid());
                return entry;
            }
            if (suspendMarkerCall(stmt)) |marker| {
                const site = suspendSiteOf(m, marker) orelse return error.SuspendMarkerLost;
                return try buildSuspendProtocol(m, site, null, after);
            }
            if (syn.containsTrueSuspend(stmt) or stmtHasSuspendCall(m.ctx, stmt)) {
                m.ctx.checker.reportError(stmt.line, stmt.column, "TypeError: suspend call as a value is not supported inside task blocks (suspend calls can only be used as separate statements).", .{});
                return error.TypeError;
            }
            const entry = try m.newState();
            try m.append(entry, stmt);
            try m.append(entry, syn.mkSetExpr(syn.mkIdent("this"), "label", syn.mkIntLit(@intCast(after))));
            return entry;
        },
        .var_decl => |v| {
            if (v.initializer) |init| {
                if (syn.isCoopAwaitMarker(stmt)) {
                    return machineBuildCoopAwait(m, stmt, after);
                }
                if (suspendMarkerCall(init) != null) {
                    const site = suspendSiteOf(m, init) orelse return error.SuspendMarkerLost;
                    return try buildSuspendProtocol(m, site, site.target, after);
                }
            }
            if (syn.containsTrueSuspend(stmt) or stmtHasSuspendCall(m.ctx, stmt)) {
                m.ctx.checker.reportError(stmt.line, stmt.column, "TypeError: suspend call as a value is not supported inside task blocks (suspend calls can only be used as separate statements).", .{});
                return error.TypeError;
            }
            const entry = try m.newState();
            try m.append(entry, stmt);
            try m.append(entry, syn.mkSetExpr(syn.mkIdent("this"), "label", syn.mkIntLit(@intCast(after))));
            return entry;
        },
        .return_stmt => {
            const r = &stmt.data.return_stmt;
            if (r.value) |val| {
                if (syn.containsTrueSuspend(val) or exprHasSuspendCall(m.ctx, val)) {
                    m.ctx.checker.reportError(val.line, val.column, "TypeError: suspend call as a value is not supported inside task blocks (suspend calls can only be used as separate statements).", .{});
                    return error.TypeError;
                }
            }
            const entry = try m.newState();
            var completion: ArrayList(*ASTNode) = undefined;
            if (m.is_callee) {
                completion = try buildSuspendCompletionStmts(m.ctx, r.value);
            } else {
                completion = try buildCompletionStmts(m.ctx, r.value);
            }
            defer completion.deinit();
            for (completion.items) |s| try m.append(entry, s);
            try m.append(entry, syn.mkReturnVoid());
            return entry;
        },
        .set_expr => |se| {
            if (suspendMarkerCall(se.value) != null) {
                const site = suspendSiteOf(m, se.value) orelse return error.SuspendMarkerLost;
                return try buildSuspendProtocol(m, site, site.target, after);
            }
            if (syn.containsTrueSuspend(stmt) or stmtHasSuspendCall(m.ctx, stmt)) {
                m.ctx.checker.reportError(stmt.line, stmt.column, "TypeError: suspend call as a value is not supported inside task blocks (suspend calls can only be used as separate statements).", .{});
                return error.TypeError;
            }
            const entry = try m.newState();
            try m.append(entry, stmt);
            try m.append(entry, syn.mkSetExpr(syn.mkIdent("this"), "label", syn.mkIntLit(@intCast(after))));
            return entry;
        },
        .block => |b| return machineBuildStmts(m, b.statements, after),
        .break_stmt => {
            return error.BreakInSuspendContext;
        },
        .try_stmt => return machineBuildTryStmt(m, stmt, after),
        else => {
            if (syn.isCoopAwaitMarker(stmt)) {
                return machineBuildCoopAwait(m, stmt, after);
            }
            if (suspendMarkerCall(stmt) != null) return error.SuspendMarkerLost;
            if (syn.containsTrueSuspend(stmt) or stmtHasSuspendCall(m.ctx, stmt)) {
                m.ctx.checker.reportError(stmt.line, stmt.column, "TypeError: suspend call as a value is not supported inside task blocks (suspend calls can only be used as separate statements).", .{});
                return error.TypeError;
            }
            const entry = try m.newState();
            try m.append(entry, stmt);
            try m.append(entry, syn.mkSetExpr(syn.mkIdent("this"), "label", syn.mkIntLit(@intCast(after))));
            return entry;
        },
    }
}

pub fn isStateSuspendOrReturn(node: *ASTNode) bool {
    switch (node.data) {
        .return_stmt => return true,
        .break_stmt => return true,
        .call_expr => |c| {
            if (c.callee.data == .get_expr) {
                const g = c.callee.data.get_expr;
                if (g.object.data == .identifier and std.mem.eql(u8, g.object.data.identifier.name, "Scheduler")) {
                    return true;
                }
            }
            return false;
        },
        else => return false,
    }
}

pub fn buildCatchStates(m: *Machine, catches: []const ast.CatchBlock, after: usize) ![]usize {
    const catch_labels = try m.allocator.alloc(usize, catches.len);
    for (catches, 0..) |cb, i| {
        catch_labels[i] = try machineBuildBranch(m, cb.body, after);
    }
    return catch_labels;
}

pub fn isLabelWrite(node: *ASTNode) bool {
    if (node.data != .set_expr) return false;
    const s = node.data.set_expr;
    return s.object.data == .identifier and
        std.mem.eql(u8, s.object.data.identifier.name, "this") and
        std.mem.eql(u8, s.name, "label");
}

pub fn wrapStatesWithCatches(m: *Machine, catches: []const ast.CatchBlock, from: usize, to: usize, catch_labels: []usize) !void {
    for (m.states.items[from..to]) |*state| {
        if (state.stmts.items.len == 0) continue;

        var has_suspend = false;
        for (state.stmts.items) |s| {
            if (isStateSuspendOrReturn(s)) {
                has_suspend = true;
                break;
            }
        }

        var user_stmts = ArrayList(*ASTNode).init(m.allocator);
        var term_stmts = ArrayList(*ASTNode).init(m.allocator);

        if (has_suspend) {
            for (state.stmts.items) |s| {
                if (isStateSuspendOrReturn(s) or isLabelWrite(s)) {
                    try term_stmts.append(s);
                } else {
                    try user_stmts.append(s);
                }
            }
        } else {
            for (state.stmts.items) |s| {
                try user_stmts.append(s);
            }
        }

        if (user_stmts.items.len > 0) {
            var synthetic_catches = ArrayList(ast.CatchBlock).init(m.allocator);
            for (catches, 0..) |cb, idx| {
                var catch_stmts = ArrayList(*ASTNode).init(m.allocator);
                if (cb.var_name) |vname| {
                    try catch_stmts.append(syn.mkSetExpr(syn.mkIdent("this"), vname, syn.mkIdent(vname)));
                }
                try catch_stmts.append(syn.mkSetExpr(syn.mkIdent("this"), "label", syn.mkIntLit(@intCast(catch_labels[idx]))));

                try synthetic_catches.append(.{
                    .var_name = cb.var_name,
                    .types = cb.types,
                    .body = syn.mkBlock(try catch_stmts.toOwnedSlice()),
                });
            }

            const wrapped_try = syn.mkTryStmt(
                syn.mkBlock(try user_stmts.toOwnedSlice()),
                try synthetic_catches.toOwnedSlice(),
            );

            state.stmts.clearRetainingCapacity();
            try state.stmts.append(wrapped_try);
            for (term_stmts.items) |term_node| {
                try state.stmts.append(term_node);
            }
        }
    }
}

pub fn machineBuildTryStmt(m: *Machine, stmt: *ASTNode, after: usize) anyerror!usize {
    const t = &stmt.data.try_stmt;

    const catch_labels = try buildCatchStates(m, t.catches, after);

    const states_before = m.states.items.len;
    const try_entry = try machineBuildBranch(m, t.body, after);
    const states_after = m.states.items.len;

    try wrapStatesWithCatches(m, t.catches, states_before, states_after, catch_labels);

    return try_entry;
}

pub fn buildSuspendCall(stmt: *ASTNode) anyerror!*ASTNode {
    const c = &stmt.data.call_expr;
    const gname = switch (c.callee.data) {
        .get_expr => |g| g.name,
        .identifier => |i| i.name,
        else => unreachable,
    };
    if (std.mem.eql(u8, gname, "yield")) {
        return syn.mkCall(syn.mkGetExpr(syn.mkIdent("Scheduler"), "yield"), &.{syn.mkIdent("this")});
    }
    if (std.mem.eql(u8, gname, "waitReadable")) {
        return syn.mkCall(syn.mkGetExpr(syn.mkIdent("Scheduler"), "waitReadable"), &.{ syn.mkIdent("this"), c.arguments[0] });
    }
    if (std.mem.eql(u8, gname, "waitWritable")) {
        return syn.mkCall(syn.mkGetExpr(syn.mkIdent("Scheduler"), "waitWritable"), &.{ syn.mkIdent("this"), c.arguments[0] });
    }
    const ms_arg = if (std.mem.eql(u8, gname, "sleepMs"))
        c.arguments[0]
    else
        syn.mkBinary(.slash, c.arguments[0], syn.mkIntLit(1000000));
    return syn.mkCall(syn.mkGetExpr(syn.mkIdent("Scheduler"), "sleep"), &.{ syn.mkIdent("this"), ms_arg });
}

pub fn assembleMachine(m: *Machine) *ASTNode {
    var chain: *ASTNode = syn.mkBlock(&.{syn.mkReturnVoid()});
    var i: usize = m.states.items.len;
    while (i > 0) {
        i -= 1;
        const s = &m.states.items[i];
        const cond = syn.mkBinary(.eq_eq, syn.mkGetExpr(syn.mkIdent("this"), "label"), syn.mkIntLit(@intCast(s.label)));
        const body_block = syn.mkBlock(s.stmts.items);
        chain = syn.mkIfElse(cond, body_block, chain);
    }
    return syn.mkWhile(syn.mkBoolLit(true), syn.mkBlock(&.{chain}));
}

/// Promotes locals created by the machinery rewrite to body fields and rewrites
/// their references. Uses the full promoted list: nested task ctor args may
/// reference earlier-promoted locals.
pub fn promoteMachineryLocals(ctx: Ctx, rewritten: []const *ASTNode, promoted: *ArrayList(CapturedVar), body_fields: *ArrayList(ast.ClassProp)) !void {
    var promoted_names = std.StringHashMap(void).init(ctx.allocator);
    defer promoted_names.deinit();
    for (promoted.items) |p| try promoted_names.put(p.name, {});
    var new_locals = ArrayList(CapturedVar).init(ctx.allocator);
    defer new_locals.deinit();
    for (rewritten) |s| try caps.collectMachineryLocals(ctx, s, &promoted_names, &new_locals);
    for (new_locals.items) |nl| {
        var prop_type_ref = nl.type_ref;
        var default_init = syn.defaultInitializerForTypeRef(nl.type_ref);
        if (default_init == null) {
                const nullable_ref = try caps.makeNullableTypeRef(ctx, nl.type_ref);
            prop_type_ref = nullable_ref;
            default_init = syn.mkNullLit();
        }
        try body_fields.append(.{
            .is_mut = true,
            .name = nl.name,
            .type_ref = prop_type_ref,
            .is_property = true,
            .initializer = default_init.?,
        });
        try promoted.append(nl);
    }
    for (rewritten) |s| try caps.rewritePromotedRefs(ctx, promoted.items, s);
}

/// Builds the state-machine `resume()`. Locals are promoted by the caller;
/// locals created by the machinery rewrite are promoted here.
pub fn buildResumeStateMachine(ctx: Ctx, captures: []const CapturedVar, locals: []const CapturedVar, body: []const *ASTNode, result_type: *const EiwaType, entry_out: *usize, body_fields: *ArrayList(ast.ClassProp), is_callee: bool) !*ASTNode {
    var promoted = ArrayList(CapturedVar).init(ctx.allocator);
    defer promoted.deinit();
    try promoted.appendSlice(captures);
    for (locals) |l| try promoted.append(l);
    for (body) |s| try caps.rewritePromotedRefs(ctx, promoted.items, s);

    // Awaits become cooperative markers in state-machine mode.
    var rewritten = ArrayList(*ASTNode).init(ctx.allocator);
    defer rewritten.deinit();
    try rewriteStatements(ctx, body, &rewritten, true);
    for (rewritten.items) |s| try clearResolvedTypes(ctx, s);

    try promoteMachineryLocals(ctx, rewritten.items, &promoted, body_fields);

    const is_void_result = result_type.* == .Void;
    var leading = ArrayList(*ASTNode).init(ctx.allocator);
    defer leading.deinit();
    var trailing: ?*ASTNode = null;
    if (!is_void_result and rewritten.items.len > 0 and syn.isValueStatement(rewritten.items[rewritten.items.len - 1])) {
        trailing = rewritten.pop();
        // F2: a suspension inside the result value cannot cooperatively
        // suspend from the done state — fail loud instead of silently
        // dropping the result (the pre-F2 silent-zero behavior).
        if (syn.containsTrueSuspend(trailing.?)) {
            ctx.checker.reportError(trailing.?.line, trailing.?.column, "TypeError: suspend call in task result value is not supported inside task blocks (suspend calls can only be used as separate statements).", .{});
            return error.TypeError;
        }
    }
    try leading.appendSlice(rewritten.items);

    var m = Machine{ .allocator = ctx.allocator, .counter = ctx.counter, .states = ArrayList(MachineState).init(ctx.allocator), .ctx = ctx, .fields = body_fields, .is_callee = is_callee };
    defer m.states.deinit();
    const done_label = try m.newState();
    const entry = try machineBuildStmts(&m, leading.items, done_label);
    entry_out.* = entry;

    var completion: ArrayList(*ASTNode) = undefined;
    if (is_callee) {
        completion = try buildSuspendCompletionStmts(ctx, trailing);
    } else {
        completion = try buildCompletionStmts(ctx, trailing);
    }
    defer completion.deinit();
    for (completion.items) |s| try m.append(done_label, s);
    try m.append(done_label, syn.mkReturnVoid());

    const resume_body = assembleMachine(&m);
    return syn.mkFunDecl("resume", &.{}, resume_body, false, &.{.kw_implement});
}

// ---------------------------------------------------------------------------
// Suspend-in-condition detection (G8)
// ---------------------------------------------------------------------------

/// Returns the innermost suspend-in-condition node, or null.
pub fn suspendConditionNode(node: *ASTNode) ?*ASTNode {
    switch (node.data) {
        .if_expr => |i| {
            if (syn.containsTrueSuspend(i.condition)) return node;
            if (suspendConditionNode(i.then_branch)) |found| return found;
            if (i.else_branch) |e| if (suspendConditionNode(e)) |found| return found;
            return null;
        },
        .while_stmt => |w| {
            if (syn.containsTrueSuspend(w.condition)) return node;
            return suspendConditionNode(w.body);
        },
        .block => |b| {
            for (b.statements) |s| if (suspendConditionNode(s)) |found| return found;
            return null;
        },
        .lambda_expr, .fun_decl => return null,
        .call_expr => |c| {
            if (syn.isTaskCall(node)) return null;
            if (suspendConditionNode(c.callee)) |found| return found;
            for (c.arguments) |a| if (suspendConditionNode(a)) |found| return found;
            return null;
        },
        .for_stmt => |f| {
            if (suspendConditionNode(f.iterable)) |found| return found;
            return suspendConditionNode(f.body);
        },
        .try_stmt => |t| {
            if (suspendConditionNode(t.body)) |found| return found;
            for (t.catches) |cb| if (suspendConditionNode(cb.body)) |found| return found;
            return null;
        },
        .when_expr => |w| {
            if (w.subject) |s| if (suspendConditionNode(s)) |found| return found;
            for (w.cases) |case| {
                for (case.conds) |cond| if (suspendConditionNode(cond)) |found| return found;
                if (suspendConditionNode(case.body)) |found| return found;
            }
            return null;
        },
        .var_decl => |v| {
            if (v.initializer) |init| {
                if (syn.isSuspendPrimitiveCall(init)) return node;
                return suspendConditionNode(init);
            }
            return null;
        },
        .return_stmt => |r| {
            if (r.value) |val| {
                if (syn.isSuspendPrimitiveCall(val)) return node;
                return suspendConditionNode(val);
            }
            return null;
        },
        .break_stmt => |b| {
            if (b.value) |val| return suspendConditionNode(val);
            return null;
        },
        .assignment => |a| {
            if (syn.isSuspendPrimitiveCall(a.value)) return node;
            return suspendConditionNode(a.value);
        },
        else => return null,
    }
}

// ---------------------------------------------------------------------------
// Suspend-function (CPS) machines: @Suspend through methods
//
// A call to a suspend-capable function from inside a state machine does not
// run inline (that would block the worker in poll()). Instead the callee body
// is compiled to its own Continuation type (`__Suspend_<cname>`, same shape
// as __TaskBlock plus a `caller` link). The caller constructs it, drives one
// resume, and suspends unless it completed synchronously; on completion the
// callee schedules its caller. Primitives keep their existing lowering.
// Calls from non-machine contexts (plain functions, single-shot tasks) keep
// the current blocking behavior.
// ---------------------------------------------------------------------------

pub const SuspendCallee = struct {
    node: *ASTNode, // fun_decl
    c_name: []const u8,
    recv_type_name: ?[]const u8, // static receiver type for methods
    is_method: bool,
};

fn hasSuspendAnnotation(annotations: []const ast.Annotation) bool {
    for (annotations) |ann| {
        if (std.mem.eql(u8, ann.name, "Suspend")) return true;
    }
    return false;
}

fn findFreeFn(ctx: Ctx, key: []const u8) ?*ASTNode {
    var it = ctx.registry.modules.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.checker.functions_ast.get(key)) |n| {
            if (n.data == .fun_decl) return n;
        }
    }
    return null;
}

fn findMethodFn(ctx: Ctx, type_name: []const u8, method_name: []const u8) ?*ASTNode {
    var it = ctx.registry.modules.iterator();
    while (it.next()) |entry| {
        const checker = entry.value_ptr.checker;
        if (checker.classes_ast.get(type_name)) |t| {
            if (t.data == .type_decl) {
                for (t.data.type_decl.methods) |m| {
                    if (m.data == .fun_decl and std.mem.eql(u8, m.data.fun_decl.name, method_name)) return m;
                }
            }
        }
        if (checker.objects_ast.get(type_name)) |o| {
            if (o.data == .object_decl) {
                for (o.data.object_decl.members) |m| {
                    if (m.data == .fun_decl and std.mem.eql(u8, m.data.fun_decl.name, method_name)) return m;
                }
            }
        }
        if (checker.contracts_ast.get(type_name)) |c| {
            if (c.data == .contract_decl) {
                for (c.data.contract_decl.methods) |m| {
                    if (m.data == .fun_decl and std.mem.eql(u8, m.data.fun_decl.name, method_name)) return m;
                }
            }
        }
    }
    return null;
}

/// Resolve a call to its suspend-capable declaration, if any. Returns null
/// for FFI/lib calls, unresolvable receivers and generic receivers (static
/// dispatch unclear) — those keep blocking behavior.
pub fn resolveSuspendCallee(ctx: Ctx, call_node: *ASTNode) ?SuspendCallee {
    if (call_node.data != .call_expr) return null;
    const c = &call_node.data.call_expr;
    switch (c.callee.data) {
        .identifier => |i| {
            const key = i.resolved_c_name orelse i.name;
            const n = findFreeFn(ctx, key) orelse findFreeFn(ctx, i.name) orelse return null;
            return .{ .node = n, .c_name = key, .recv_type_name = null, .is_method = false };
        },
        .get_expr => |g| {
            const recv = g.object.resolved_type orelse return null;
            const base = ts.extractBaseType(recv).*;
            const tname: []const u8 = switch (base) {
                .Custom => |n| n,
                // Generic receivers: static dispatch is unclear, keep blocking.
                else => return null,
            };
            const n = findMethodFn(ctx, tname, g.name) orelse return null;
            const cn = n.data.fun_decl.resolved_c_name orelse n.data.fun_decl.name;
            return .{ .node = n, .c_name = cn, .recv_type_name = tname, .is_method = true };
        },
        else => return null,
    }
}

/// Transitive check: does this function body suspend? True for @Suspend
/// primitives, await(), @Suspend-annotated calls and calls to functions whose
/// bodies suspend. Cycle-guarded via `visiting`.
const SuspendMode = enum { Any, UserOnly };

fn funBodySuspends(ctx: Ctx, fun_node: *ASTNode, visiting: *ArrayList(*ASTNode), mode: SuspendMode) bool {
    if (fun_node.data != .fun_decl) return false;
    const f = &fun_node.data.fun_decl;
    if (hasSuspendAnnotation(f.annotations)) return true;
    for (visiting.items) |v| {
        if (v == fun_node) return false;
    }
    visiting.append(fun_node) catch return false;
    defer _ = visiting.pop();
    switch (f.body.data) {
        .block => |b| return stmtsSuspend(ctx, b.statements, visiting, mode),
        else => return exprSuspends(ctx, f.body, visiting, mode),
    }
}

fn stmtsSuspend(ctx: Ctx, stmts: []const *ASTNode, visiting: *ArrayList(*ASTNode), mode: SuspendMode) bool {
    for (stmts) |s| {
        if (stmtSuspends(ctx, s, visiting, mode)) return true;
    }
    return false;
}

fn stmtSuspends(ctx: Ctx, node: *ASTNode, visiting: *ArrayList(*ASTNode), mode: SuspendMode) bool {
    switch (node.data) {
        .call_expr => return exprSuspends(ctx, node, visiting, mode),
        .var_decl => |v| {
            if (v.initializer) |init| return exprSuspends(ctx, init, visiting, mode);
            return false;
        },
        .assignment => |a| return exprSuspends(ctx, a.value, visiting, mode),
        .return_stmt => |r| {
            if (r.value) |val| return exprSuspends(ctx, val, visiting, mode);
            return false;
        },
        .break_stmt => |b| {
            if (b.value) |val| return exprSuspends(ctx, val, visiting, mode);
            return false;
        },
        .block => |b| return stmtsSuspend(ctx, b.statements, visiting, mode),
        .if_expr => |i| {
            if (exprSuspends(ctx, i.condition, visiting, mode)) return true;
            if (stmtSuspends(ctx, i.then_branch, visiting, mode)) return true;
            if (i.else_branch) |e| return stmtSuspends(ctx, e, visiting, mode);
            return false;
        },
        .while_stmt => |w| {
            if (exprSuspends(ctx, w.condition, visiting, mode)) return true;
            return stmtSuspends(ctx, w.body, visiting, mode);
        },
        .for_stmt => |f| {
            if (exprSuspends(ctx, f.iterable, visiting, mode)) return true;
            return stmtSuspends(ctx, f.body, visiting, mode);
        },
        .try_stmt => |t| {
            if (stmtSuspends(ctx, t.body, visiting, mode)) return true;
            for (t.catches) |cb| {
                if (stmtSuspends(ctx, cb.body, visiting, mode)) return true;
            }
            return false;
        },
        .when_expr => |w| {
            if (w.subject) |s| {
                if (exprSuspends(ctx, s, visiting, mode)) return true;
            }
            for (w.cases) |case| {
                for (case.conds) |cond| {
                    if (exprSuspends(ctx, cond, visiting, mode)) return true;
                }
                if (stmtSuspends(ctx, case.body, visiting, mode)) return true;
            }
            return false;
        },
        .throw_stmt => |t| return exprSuspends(ctx, t.expr, visiting, mode),
        // Closures are their own boundary (nested tasks lower separately,
        // plain closures keep blocking behavior).
        .lambda_expr, .fun_decl => return false,
        else => return exprSuspends(ctx, node, visiting, mode),
    }
}

/// Expression-level scan. Any suspend call anywhere inside counts (triggers a
/// machine); operand/condition legality is enforced separately by the pre-pass.
fn exprSuspends(ctx: Ctx, node: *ASTNode, visiting: *ArrayList(*ASTNode), mode: SuspendMode) bool {
    switch (node.data) {
        .call_expr => {
            if (mode == .UserOnly) {
                // Primitives, awaits and task creation keep their existing
                // lowering; only user suspend calls count here.
                if (syn.isSuspendPrimitiveCall(node)) return false;
                if (syn.isAwaitCall(node)) return false;
                if (syn.isTaskCall(node)) return false;
            } else {
                if (syn.isSuspendPrimitiveCall(node)) return true;
                if (syn.isAwaitCall(node)) return true;
                // task{} creation never suspends the encloser (its lambda is
                // a separate coroutine boundary).
                if (syn.isTaskCall(node)) return false;
            }
            const c = &node.data.call_expr;
            if (exprSuspends(ctx, c.callee, visiting, mode)) return true;
            for (c.arguments) |a| {
                if (exprSuspends(ctx, a, visiting, mode)) return true;
            }
            const cal = resolveSuspendCallee(ctx, node) orelse return false;
            if (hasSuspendAnnotation(cal.node.data.fun_decl.annotations)) return true;
            return funBodySuspends(ctx, cal.node, visiting, mode);
        },
        .lambda_expr, .fun_decl => return false,
        .binary_expr => |b| return exprSuspends(ctx, b.left, visiting, mode) or exprSuspends(ctx, b.right, visiting, mode),
        .unary_expr => |u| return exprSuspends(ctx, u.operand, visiting, mode),
        .get_expr => |g| return exprSuspends(ctx, g.object, visiting, mode),
        .set_expr => |s| return exprSuspends(ctx, s.object, visiting, mode) or exprSuspends(ctx, s.value, visiting, mode),
        .index_expr => |i| return exprSuspends(ctx, i.object, visiting, mode) or exprSuspends(ctx, i.index, visiting, mode),
        .index_set_expr => |i| return exprSuspends(ctx, i.object, visiting, mode) or exprSuspends(ctx, i.index, visiting, mode) or exprSuspends(ctx, i.value, visiting, mode),
        .assignment => |a| return exprSuspends(ctx, a.value, visiting, mode),
        .block => |b| return stmtsSuspend(ctx, b.statements, visiting, mode),
        .if_expr => |i| {
            if (exprSuspends(ctx, i.condition, visiting, mode)) return true;
            if (stmtSuspends(ctx, i.then_branch, visiting, mode)) return true;
            if (i.else_branch) |e| return stmtSuspends(ctx, e, visiting, mode);
            return false;
        },
        .string_template => |st| {
            for (st.parts) |p| {
                if (exprSuspends(ctx, p, visiting, mode)) return true;
            }
            return false;
        },
        .array_literal => |al| {
            for (al.elements) |e| {
                if (exprSuspends(ctx, e, visiting, mode)) return true;
            }
            return false;
        },
        .map_literal => |ml| {
            for (ml.elements) |e| {
                if (exprSuspends(ctx, e, visiting, mode)) return true;
            }
            return false;
        },
        .named_arg => |na| return exprSuspends(ctx, na.value, visiting, mode),
        .as_expr => |a| return exprSuspends(ctx, a.value, visiting, mode),
        .is_expr => |i| return exprSuspends(ctx, i.value, visiting, mode),
        .var_decl => |v| {
            if (v.initializer) |init| return exprSuspends(ctx, init, visiting, mode);
            return false;
        },
        .return_stmt => |r| {
            if (r.value) |val| return exprSuspends(ctx, val, visiting, mode);
            return false;
        },
        else => return false,
    }
}

/// Backstop scans for leftover user-suspend calls (the pre-pass either
/// lowers or rejects them, so these only fire on internal bugs).
fn stmtHasSuspendCall(ctx: Ctx, node: *ASTNode) bool {
    var visiting = ArrayList(*ASTNode).init(ctx.allocator);
    defer visiting.deinit();
    return stmtSuspends(ctx, node, &visiting, .UserOnly);
}

fn exprHasSuspendCall(ctx: Ctx, node: *ASTNode) bool {
    var visiting = ArrayList(*ASTNode).init(ctx.allocator);
    defer visiting.deinit();
    return exprSuspends(ctx, node, &visiting, .UserOnly);
}

/// Does this call suspend (primitively or transitively)? Used for machine
/// triggers. Allocates a fresh cycle guard per query.
pub fn callSuspends(ctx: Ctx, call_node: *ASTNode) bool {
    if (call_node.data != .call_expr) return false;
    if (syn.isSuspendPrimitiveCall(call_node)) return true;
    if (syn.isAwaitCall(call_node)) return true;
    if (syn.isTaskCall(call_node)) return false;
    const cal = resolveSuspendCallee(ctx, call_node) orelse return false;
    if (hasSuspendAnnotation(cal.node.data.fun_decl.annotations)) return true;
    var visiting = ArrayList(*ASTNode).init(ctx.allocator);
    defer visiting.deinit();
    return funBodySuspends(ctx, cal.node, &visiting, .Any);
}

fn libNameAnywhere(ctx: Ctx, name: []const u8) bool {
    var it = ctx.registry.modules.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.checker.libs_ast.contains(name)) return true;
    }
    return false;
}

/// Generate (or reuse) the state-machine type for a suspend callee.
fn ensureSuspendMachine(ctx: Ctx, callee: SuspendCallee) anyerror![]const u8 {
    const mname = try syn.suspendMachineName(ctx.allocator, callee.c_name);
    if (ctx.suspend_generated.contains(mname)) return mname;
    for (ctx.suspend_generating.items) |g| {
        if (std.mem.eql(u8, g, mname)) {
            ctx.checker.reportError(callee.node.line, callee.node.column, "TypeError: recursive suspend calls are not supported (function '{s}' calls itself through suspend).", .{callee.c_name});
            return error.TypeError;
        }
    }
    try ctx.suspend_generating.append(mname);
    defer _ = ctx.suspend_generating.pop();
    const t = try buildSuspendFnType(ctx, callee, mname);
    try ctx.generated.append(t);
    try ctx.suspend_generated.put(mname, {});
    return mname;
}

/// Rewrite implicit receiver field accesses (`builder` meaning
/// `this.builder`, flagged `is_class_property`) to `__recv.builder`.
/// Unlike `this`, this descends into lambdas: nested tasks capture `__recv`
/// by value like any other free variable.
fn rewritePropertyRefs(node: *ASTNode) void {
    switch (node.data) {
        .identifier => |*i| {
            if (i.is_class_property) {
                const name = i.name;
                node.data = .{ .get_expr = .{
                    .object = syn.mkIdent("__recv"),
                    .name = name,
                    .is_safe = false,
                    .is_boxed = false,
                } };
                node.resolved_type = null;
            }
            return;
        },
        .fun_decl => return,
        .call_expr => |*c| {
            rewritePropertyRefs(c.callee);
            for (c.arguments) |a| rewritePropertyRefs(a);
        },
        .binary_expr => |*b| {
            rewritePropertyRefs(b.left);
            rewritePropertyRefs(b.right);
        },
        .unary_expr => |*u| rewritePropertyRefs(u.operand),
        .get_expr => |*g| rewritePropertyRefs(g.object),
        .set_expr => |*s| {
            rewritePropertyRefs(s.object);
            rewritePropertyRefs(s.value);
        },
        .index_expr => |*i| {
            rewritePropertyRefs(i.object);
            rewritePropertyRefs(i.index);
        },
        .index_set_expr => |*i| {
            rewritePropertyRefs(i.object);
            rewritePropertyRefs(i.index);
            rewritePropertyRefs(i.value);
        },
        .block => |*b| {
            for (b.statements) |s| rewritePropertyRefs(s);
        },
        .var_decl => |*v| {
            if (v.initializer) |init| rewritePropertyRefs(init);
        },
        .assignment => |*a| rewritePropertyRefs(a.value),
        .return_stmt => |*r| {
            if (r.value) |val| rewritePropertyRefs(val);
        },
        .break_stmt => |*b| {
            if (b.value) |val| rewritePropertyRefs(val);
        },
        .if_expr => |*i| {
            rewritePropertyRefs(i.condition);
            rewritePropertyRefs(i.then_branch);
            if (i.else_branch) |e| rewritePropertyRefs(e);
        },
        .while_stmt => |*w| {
            rewritePropertyRefs(w.condition);
            rewritePropertyRefs(w.body);
        },
        .for_stmt => |*f| {
            rewritePropertyRefs(f.iterable);
            rewritePropertyRefs(f.body);
        },
        .try_stmt => |*t| {
            rewritePropertyRefs(t.body);
            for (t.catches) |*cb| rewritePropertyRefs(cb.body);
        },
        .throw_stmt => |*t| rewritePropertyRefs(t.expr),
        .string_template => |*st| {
            for (st.parts) |p| rewritePropertyRefs(p);
        },
        .array_literal => |*al| {
            for (al.elements) |e| rewritePropertyRefs(e);
        },
        .map_literal => |*ml| {
            for (ml.elements) |e| rewritePropertyRefs(e);
        },
        .named_arg => |*na| rewritePropertyRefs(na.value),
        .as_expr => |*a| rewritePropertyRefs(a.value),
        .is_expr => |*i| rewritePropertyRefs(i.value),
        .lambda_expr => |*l| {
            for (l.body) |s| rewritePropertyRefs(s);
        },
        else => {},
    }
}

/// Rewrite bare `this` to `__recv` (receiver is a keyword and cannot be
/// shadowed, so a flat rename is safe). Skips nested lambdas/functions.
fn rewriteThisToRecv(node: *ASTNode) void {
    switch (node.data) {
        .identifier => |*i| {
            if (std.mem.eql(u8, i.name, "this")) {
                i.name = "__recv";
                i.resolved_c_name = null;
            }
            return;
        },
        .lambda_expr, .fun_decl => return,
        .call_expr => |*c| {
            rewriteThisToRecv(c.callee);
            for (c.arguments) |a| rewriteThisToRecv(a);
        },
        .binary_expr => |*b| {
            rewriteThisToRecv(b.left);
            rewriteThisToRecv(b.right);
        },
        .unary_expr => |*u| rewriteThisToRecv(u.operand),
        .get_expr => |*g| rewriteThisToRecv(g.object),
        .set_expr => |*s| {
            rewriteThisToRecv(s.object);
            rewriteThisToRecv(s.value);
        },
        .index_expr => |*i| {
            rewriteThisToRecv(i.object);
            rewriteThisToRecv(i.index);
        },
        .index_set_expr => |*i| {
            rewriteThisToRecv(i.object);
            rewriteThisToRecv(i.index);
            rewriteThisToRecv(i.value);
        },
        .block => |*b| {
            for (b.statements) |s| rewriteThisToRecv(s);
        },
        .var_decl => |*v| {
            if (v.initializer) |init| rewriteThisToRecv(init);
        },
        .assignment => |*a| rewriteThisToRecv(a.value),
        .return_stmt => |*r| {
            if (r.value) |val| rewriteThisToRecv(val);
        },
        .break_stmt => |*b| {
            if (b.value) |val| rewriteThisToRecv(val);
        },
        .if_expr => |*i| {
            rewriteThisToRecv(i.condition);
            rewriteThisToRecv(i.then_branch);
            if (i.else_branch) |e| rewriteThisToRecv(e);
        },
        .while_stmt => |*w| {
            rewriteThisToRecv(w.condition);
            rewriteThisToRecv(w.body);
        },
        .for_stmt => |*f| {
            rewriteThisToRecv(f.iterable);
            rewriteThisToRecv(f.body);
        },
        .try_stmt => |*t| {
            rewriteThisToRecv(t.body);
            for (t.catches) |cb| rewriteThisToRecv(cb.body);
        },
        .throw_stmt => |*t| rewriteThisToRecv(t.expr),
        .string_template => |*st| {
            for (st.parts) |p| rewriteThisToRecv(p);
        },
        .array_literal => |*al| {
            for (al.elements) |e| rewriteThisToRecv(e);
        },
        .map_literal => |*ml| {
            for (ml.elements) |e| rewriteThisToRecv(e);
        },
        .named_arg => |*na| rewriteThisToRecv(na.value),
        .as_expr => |*a| rewriteThisToRecv(a.value),
        .is_expr => |*i| rewriteThisToRecv(i.value),
        else => {},
    }
}

fn buildSuspendFnType(ctx: Ctx, callee: SuspendCallee, mname: []const u8) anyerror!*ASTNode {
    const f = &callee.node.data.fun_decl;
    const result_type: *const EiwaType = calleeResultType(ctx, callee);

    // Clone with types preserved: nested suspend resolution needs receiver
    // types. The original keeps blocking semantics for non-machine callers.
    const body_src = try ctx.checker.cloneNodeWith(f.body, true);
    var body_stmts: []const *ASTNode = undefined;
    if (body_src.data == .block) {
        body_stmts = body_src.data.block.statements;
    } else {
        const single = try ctx.allocator.alloc(*ASTNode, 1);
        single[0] = body_src;
        body_stmts = single;
    }
    if (callee.is_method) {
        for (body_stmts) |s| rewriteThisToRecv(s);
        for (body_stmts) |s| rewritePropertyRefs(s);
    }
    const narrowed = try narrowingFixupList(ctx, body_stmts);
    const expanded = try expandSuspendCalls(ctx, narrowed);

    // Explicit ctor slots: params in decl order, then the receiver.
    // Anything else free (globals, enclosing locals) is rejected loudly.
    var explicit = ArrayList(CapturedVar).init(ctx.allocator);
    defer explicit.deinit();
    var param_names = std.StringHashMap(void).init(ctx.allocator);
    defer param_names.deinit();
    for (f.params) |p| {
        const pt = p.type_ref orelse {
            ctx.checker.reportError(callee.node.line, callee.node.column, "TypeError: suspend function '{s}' needs explicit parameter types.", .{f.name});
            return error.TypeError;
        };
        try explicit.append(.{ .name = p.name, .type_ref = pt, .is_boxed = false });
        try param_names.put(p.name, {});
    }
    if (callee.is_method) {
        try explicit.append(.{ .name = "__recv", .type_ref = syn.typeRefSimple(callee.recv_type_name.?), .is_boxed = false });
        try param_names.put("__recv", {});
    }
    const auto = try caps.collectCaptures(ctx, expanded);
    defer ctx.allocator.free(auto);
    for (auto) |c| {
        if (param_names.contains(c.name)) continue;
        // Globals (types, libs, functions) resolve in the generated type's
        // scope and need no capture.
        if (caps.isGlobalName(ctx, c.name)) continue;
        if (libNameAnywhere(ctx, c.name)) continue;
        ctx.checker.reportError(callee.node.line, callee.node.column, "TypeError: suspend function '{s}' references '{s}' from outside its parameters (globals and enclosing locals are not supported).", .{ f.name, c.name });
        return error.TypeError;
    }

    var props = ArrayList(ast.ClassProp).init(ctx.allocator);
    defer props.deinit();
    const task_ref = try syn.typeRefWithArgs(ctx.allocator, "StackTask", &.{result_type});
    try props.append(.{ .is_mut = false, .name = "task", .type_ref = task_ref });
    // Ctor order matches the call-site emission: [task, __recv?, params...,
    // caller]. __recv therefore comes before params in props.
    for (explicit.items) |c| {
        if (std.mem.eql(u8, c.name, "__recv")) {
            try props.append(.{ .is_mut = false, .name = c.name, .type_ref = c.type_ref });
        }
    }
    for (explicit.items) |c| {
        if (!std.mem.eql(u8, c.name, "__recv")) {
            try props.append(.{ .is_mut = false, .name = c.name, .type_ref = c.type_ref });
        }
    }
    try props.append(.{ .is_mut = false, .name = "caller", .type_ref = syn.typeRefSimple("Continuation") });

    var methods = ArrayList(*ASTNode).init(ctx.allocator);
    defer methods.deinit();
    var body_fields = ArrayList(ast.ClassProp).init(ctx.allocator);
    defer body_fields.deinit();

    const locals = try caps.collectPromotableLocals(ctx, expanded);
    defer ctx.allocator.free(locals);
    for (locals) |l| {
        const prop_type_ref = l.type_ref;
        const default_init = syn.defaultInitializerForTypeRef(l.type_ref);
        try body_fields.append(.{
            .is_mut = true,
            .name = l.name,
            .type_ref = prop_type_ref,
            .is_property = true,
            .initializer = default_init,
        });
    }
    var entry_label: usize = 0;
    const resume_method = try buildResumeStateMachine(ctx, explicit.items, locals, expanded, result_type, &entry_label, &body_fields, true);
    try methods.append(resume_method);
    try body_fields.append(.{
        .is_mut = true,
        .name = "label",
        .type_ref = syn.typeRefSimple("Int"),
        .is_property = true,
        .initializer = syn.mkIntLit(@intCast(entry_label)),
    });
    try methods.append(syn.buildIsDone());

    const type_node = try ctx.allocator.create(ASTNode);
    type_node.* = .{
        .line = 0,
        .column = 0,
        .data = .{ .type_decl = .{
            .annotations = &.{},
            .name = mname,
            .generic_params = &.{},
            .primary_constructor = try props.toOwnedSlice(),
            .methods = try methods.toOwnedSlice(),
            .resolved_c_name = null,
            .contracts = &.{"Continuation"},
            .skills = &.{},
            .body_fields = try body_fields.toOwnedSlice(),
        } },
    };

    try registerGeneratedType(ctx, type_node);
    return type_node;
}

/// Analyze a direct suspend call: resolve the callee, ensure its machine,
/// snapshot the result type. Returns null when the call must stay blocking
/// (unresolvable, FFI, generic receiver, bodyless contract method).
const SuspendCallInfo = struct {
    machine: []const u8,
    result: *const ast.ASTTypeRef,
    recv: ?*ASTNode,
    args: []const *ASTNode,
};

/// Callee result type: declared return type wins over block inference
/// (a trailing try/return reads as Void while the annotation contracts String).
fn calleeResultType(ctx: Ctx, callee: SuspendCallee) *const EiwaType {
    const f = &callee.node.data.fun_decl;
    if (f.type_ref) |tr| {
        if (ctx.checker.resolveTypeRef(tr)) |rt| return rt else |_| {}
    }
    if (f.body.data == .block) {
        return syn.blockReturnType(f.body.data.block.statements);
    }
    return f.body.resolved_type orelse &syn.defaultVoidType;
}

fn analyzeSuspendCall(ctx: Ctx, call_node: *ASTNode) anyerror!?SuspendCallInfo {
    if (!callSuspends(ctx, call_node)) return null;
    if (syn.isSuspendPrimitiveCall(call_node)) return null;
    if (syn.isAwaitCall(call_node)) return null;
    const cal = resolveSuspendCallee(ctx, call_node) orelse return null;
    if (cal.node.data != .fun_decl) return null;
    const f = &cal.node.data.fun_decl;
    // Bodyless declarations (contracts, FFI) stay blocking.
    switch (f.body.data) {
        .block => {},
        else => {},
    }
    if (f.generic_params.len > 0) return null;
    const c = &call_node.data.call_expr;
    for (c.arguments) |a| {
        if (syn.isAwaitCall(a) or syn.containsTrueSuspend(a) or callSuspends(ctx, a)) {
            ctx.checker.reportError(a.line, a.column, "TypeError: suspend call as a value is not supported inside task blocks (suspend calls can only be used as separate statements).", .{});
            return error.TypeError;
        }
    }
    const mname = try ensureSuspendMachine(ctx, cal);
    const result_ref = try syn.typeRefForEiwaType(ctx.allocator, calleeResultType(ctx, cal));
    var recv: ?*ASTNode = null;
    if (c.callee.data == .get_expr) {
        recv = c.callee.data.get_expr.object;
    }
    return .{ .machine = mname, .result = result_ref, .recv = recv, .args = c.arguments };
}

fn suspendOperandError(ctx: Ctx, node: *ASTNode) anyerror {
    ctx.checker.reportError(node.line, node.column, "TypeError: suspend call as a value is not supported inside task blocks (suspend calls can only be used as separate statements).", .{});
    return error.TypeError;
}

fn suspendConditionError(ctx: Ctx, node: *ASTNode) anyerror {
    ctx.checker.reportError(node.line, node.column, "TypeError: suspend call in condition is not supported inside task blocks (suspend calls can only be used as separate statements).", .{});
    return error.TypeError;
}

/// Hoist user suspend calls nested inside an expression into preamble
/// `val __suspendN = __SuspendCall(...)` markers (inner-first, left-to-right
/// so evaluation order and arg cleaning match `analyzeSuspendCall`).
/// Returns true when anything was hoisted; `expr` is rewritten in place.
/// Lambdas are a coroutine boundary and are never entered. Void results have
/// no value to substitute and are left for statement-level handling.
fn hoistSuspendsFromExpr(ctx: Ctx, expr: *ASTNode, preamble: *ArrayList(*ASTNode)) !bool {
    var hoisted = false;
    try hoistSuspendsWalk(ctx, expr, preamble, &hoisted);
    return hoisted;
}

fn hoistSuspendsWalk(ctx: Ctx, node: *ASTNode, preamble: *ArrayList(*ASTNode), hoisted: *bool) anyerror!void {
    switch (node.data) {
        .lambda_expr, .fun_decl => return,
        .call_expr => {
            const c = &node.data.call_expr;
            try hoistSuspendsWalk(ctx, c.callee, preamble, hoisted);
            for (c.arguments) |arg| {
                try hoistSuspendsWalk(ctx, arg, preamble, hoisted);
            }
            if (syn.isTaskCall(node) or syn.isAwaitCall(node) or syn.isSuspendPrimitiveCall(node)) return;
            if (!callSuspends(ctx, node)) return;
            const info = try analyzeSuspendCall(ctx, node) orelse return;
            if (isVoidRef(info.result)) return;
            const n = ctx.counter.*;
            ctx.counter.* += 1;
            const tmp = try std.fmt.allocPrint(ctx.allocator, "__suspend{d}", .{n});
            const marker = try syn.mkSuspendCallMarker(ctx.allocator, info.recv, info.args);
            try ctx.suspend_sites.append(.{ .marker = marker, .machine = info.machine, .result = info.result, .target = tmp });
            const decl = syn.mkVarDecl(tmp, marker);
            decl.data.var_decl.type_ref = info.result;
            decl.line = node.line;
            decl.column = node.column;
            try preamble.append(decl);
            const saved_line = node.line;
            const saved_col = node.column;
            node.data = .{ .identifier = .{ .name = tmp, .resolved_c_name = null } };
            node.line = saved_line;
            node.column = saved_col;
            node.resolved_type = null;
            node.expected_type = null;
            hoisted.* = true;
        },
        .binary_expr => |*b| {
            try hoistSuspendsWalk(ctx, b.left, preamble, hoisted);
            try hoistSuspendsWalk(ctx, b.right, preamble, hoisted);
        },
        .unary_expr => |*u| try hoistSuspendsWalk(ctx, u.operand, preamble, hoisted),
        .get_expr => |*g| try hoistSuspendsWalk(ctx, g.object, preamble, hoisted),
        .set_expr => |*s| {
            try hoistSuspendsWalk(ctx, s.object, preamble, hoisted);
            try hoistSuspendsWalk(ctx, s.value, preamble, hoisted);
        },
        .index_expr => |*i| {
            try hoistSuspendsWalk(ctx, i.object, preamble, hoisted);
            try hoistSuspendsWalk(ctx, i.index, preamble, hoisted);
        },
        .index_set_expr => |*i| {
            try hoistSuspendsWalk(ctx, i.object, preamble, hoisted);
            try hoistSuspendsWalk(ctx, i.index, preamble, hoisted);
            try hoistSuspendsWalk(ctx, i.value, preamble, hoisted);
        },
        .array_literal => |*al| {
            for (al.elements) |e| try hoistSuspendsWalk(ctx, e, preamble, hoisted);
        },
        .string_template => |*st| {
            for (st.parts) |e| try hoistSuspendsWalk(ctx, e, preamble, hoisted);
        },
        .map_literal => |*ml| {
            for (ml.elements) |e| try hoistSuspendsWalk(ctx, e, preamble, hoisted);
        },
        .named_arg => |*na| try hoistSuspendsWalk(ctx, na.value, preamble, hoisted),
        .assignment => |*a| try hoistSuspendsWalk(ctx, a.value, preamble, hoisted),
        .as_expr => |*a| try hoistSuspendsWalk(ctx, a.value, preamble, hoisted),
        else => {},
    }
}

/// Hoist suspends from a call's receiver/args only (not the call itself).
/// Used by direct statement paths so `analyzeSuspendCall` sees clean args.
/// Appends hoisted temps to `preamble`, returns true when anything hoisted.
fn hoistCallSubs(ctx: Ctx, call_node: *ASTNode, preamble: *ArrayList(*ASTNode)) !bool {
    if (call_node.data != .call_expr) return false;
    const c = &call_node.data.call_expr;
    var any = false;
    // Receiver object (method calls): `getConn().read()`.
    if (c.callee.data == .get_expr) {
        var h = false;
        try hoistSuspendsWalk(ctx, c.callee.data.get_expr.object, preamble, &h);
        any = any or h;
    } else {
        var h = false;
        try hoistSuspendsWalk(ctx, c.callee, preamble, &h);
        any = any or h;
    }
    for (c.arguments) |arg| {
        var h = false;
        try hoistSuspendsWalk(ctx, arg, preamble, &h);
        any = any or h;
    }
    return any;
}

/// Hoist nested suspends from `node` into `out`, appending preamble temps.
/// Returns true when anything was hoisted (caller then appends its statement
/// and returns). Single source of truth for the P1 operand/condition hoist.
fn hoistPreamble(ctx: Ctx, node: *ASTNode, out: *ArrayList(*ASTNode)) !bool {
    var preamble = ArrayList(*ASTNode).init(ctx.allocator);
    defer preamble.deinit();
    if (try hoistSuspendsFromExpr(ctx, node, &preamble)) {
        try out.appendSlice(preamble.items);
        return true;
    }
    return false;
}

/// Hoist a call's receiver/args into `out` (not the call itself), so direct
/// statement paths (`val x = f(g())`) see clean args in `analyzeSuspendCall`.
fn hoistSubsInto(ctx: Ctx, call_node: *ASTNode, out: *ArrayList(*ASTNode)) !void {
    var sub = ArrayList(*ASTNode).init(ctx.allocator);
    defer sub.deinit();
    if (try hoistCallSubs(ctx, call_node, &sub)) {
        try out.appendSlice(sub.items);
    }
}

/// Pure detection for operand/condition positions: any suspend call found
/// inside errors (operands cannot suspend mid-expression). Never expands.
fn forbidSuspendExpr(ctx: Ctx, node: *ASTNode, in_condition: bool) anyerror!void {
    if (exprHasSuspendCall(ctx, node)) {
        if (in_condition) return suspendConditionError(ctx, node);
        return suspendOperandError(ctx, node);
    }
}

/// Expand one statement: lower supported suspend-call positions to markers,
/// reject the rest. Appends output to `out` (return needs two statements).
fn expandSuspendStmt(ctx: Ctx, stmt: *ASTNode, out: *ArrayList(*ASTNode)) anyerror!void {
    switch (stmt.data) {
        .var_decl => {
            const v = &stmt.data.var_decl;
            if (v.initializer) |init| {
                // `val pr = waitReadable(fd[, timeout])`: readiness waits have
                // no meaningful timeout in suspend context (close wakes them
                // via HUP, like the existing bare-statement lowering which
                // already drops the timeout). Split into a bare cooperative
                // wait plus a ready result.
                if (init.data == .call_expr and syn.isSuspendPrimitiveCall(init)) {
                    const cname = switch (init.data.call_expr.callee.data) {
                        .get_expr => |g| g.name,
                        .identifier => |i| i.name,
                        else => "",
                    };
                    if (std.mem.eql(u8, cname, "waitReadable") or std.mem.eql(u8, cname, "waitWritable")) {
                        v.initializer = syn.mkIntLit(1);
                        v.type_ref = syn.typeRefSimple("Int");
                        try out.append(init);
                        try out.append(stmt);
                        return;
                    }
                }
                if (init.data == .call_expr and callSuspends(ctx, init)) {
                    if (syn.isSuspendPrimitiveCall(init)) {
                        try out.append(stmt);
                        return;
                    }
                    // Nested suspends in receiver/args hoist first
                    // (`val x = f(g())` evaluates `g()` before `f()`).
                    if (!syn.isAwaitCall(init) and !syn.isTaskCall(init)) {
                        try hoistSubsInto(ctx, init, out);
                    }
                    const info = try analyzeSuspendCall(ctx, init) orelse {
                        try out.append(stmt);
                        return;
                    };
                    if (isVoidRef(info.result)) {
                        const marker = try syn.mkSuspendCallMarker(ctx.allocator, info.recv, info.args);
                        try ctx.suspend_sites.append(.{ .marker = marker, .machine = info.machine, .result = info.result, .target = null });
                        try out.append(marker);
                        return;
                    }
                    const marker = try syn.mkSuspendCallMarker(ctx.allocator, info.recv, info.args);
                    try ctx.suspend_sites.append(.{ .marker = marker, .machine = info.machine, .result = info.result, .target = v.name });
                    v.initializer = marker;
                    v.type_ref = info.result;
                    try out.append(stmt);
                    return;
                }
                // Operand hoist (P1): `val x = "PONG:" + f()` where f()
                // suspends becomes `val __sN = f()` + `val x = "PONG:" + __sN`.
                // Same transparent pattern as `hoistAwaitsFromExpr`.
                if (exprHasSuspendCall(ctx, init)) {
                    if (try hoistPreamble(ctx, init, out)) {
                        try out.append(stmt);
                        return;
                    }
                }
                try forbidSuspendExpr(ctx, init, false);
            }
            try out.append(stmt);
        },
        .call_expr => {
            // Primitives, awaits and task creation keep their existing
            // lowering downstream; only user suspend calls are expanded here.
            if (syn.isSuspendPrimitiveCall(stmt) or syn.isAwaitCall(stmt) or syn.isTaskCall(stmt)) {
                try out.append(stmt);
                return;
            }
            if (callSuspends(ctx, stmt)) {
                try hoistSubsInto(ctx, stmt, out);
                const info = try analyzeSuspendCall(ctx, stmt) orelse {
                    try out.append(stmt);
                    return;
                };
                const marker = try syn.mkSuspendCallMarker(ctx.allocator, info.recv, info.args);
                try ctx.suspend_sites.append(.{ .marker = marker, .machine = info.machine, .result = info.result, .target = null });
                try out.append(marker);
                return;
            }
            // Sync outer with suspend args: `print(f())` hoists `f()`.
            if (exprHasSuspendCall(ctx, stmt)) {
                if (try hoistPreamble(ctx, stmt, out)) {
                    try out.append(stmt);
                    return;
                }
            }
            try forbidSuspendExpr(ctx, stmt, false);
            try out.append(stmt);
        },
        .return_stmt => {
            const r = &stmt.data.return_stmt;
            if (r.value) |val| {
                if (val.data == .call_expr and callSuspends(ctx, val) and !syn.isSuspendPrimitiveCall(val)) {
                    try hoistSubsInto(ctx, val, out);
                    const info = try analyzeSuspendCall(ctx, val) orelse {
                        try out.append(stmt);
                        return;
                    };
                    const n = ctx.counter.*;
                    ctx.counter.* += 1;
                    const tmp_name = try std.fmt.allocPrint(ctx.allocator, "__sret{d}", .{n});
                    const marker = try syn.mkSuspendCallMarker(ctx.allocator, info.recv, info.args);
                    try ctx.suspend_sites.append(.{ .marker = marker, .machine = info.machine, .result = info.result, .target = tmp_name });
                    const tmp_decl = syn.mkVarDecl(tmp_name, marker);
                    tmp_decl.data.var_decl.type_ref = info.result;
                    try out.append(tmp_decl);
                    r.value = syn.mkIdent(tmp_name);
                    try out.append(stmt);
                    return;
                }
                if (exprHasSuspendCall(ctx, val)) {
                    if (try hoistPreamble(ctx, val, out)) {
                        try out.append(stmt);
                        return;
                    }
                }
                try forbidSuspendExpr(ctx, val, false);
            }
            try out.append(stmt);
        },
        .if_expr => {
            const i = &stmt.data.if_expr;
            // `if` condition runs once: safe to hoist suspends before it.
            if (exprHasSuspendCall(ctx, i.condition)) {
                if (try hoistPreamble(ctx, i.condition, out)) {
                    try expandSuspendBranch(ctx, i.then_branch);
                    if (i.else_branch) |e| try expandSuspendBranch(ctx, e);
                    try out.append(stmt);
                    return;
                }
            }
            try forbidSuspendExpr(ctx, i.condition, true);
            try expandSuspendBranch(ctx, i.then_branch);
            if (i.else_branch) |e| try expandSuspendBranch(ctx, e);
            try out.append(stmt);
        },
        .while_stmt => {
            const w = &stmt.data.while_stmt;
            try forbidSuspendExpr(ctx, w.condition, true);
            try expandSuspendBranch(ctx, w.body);
            try out.append(stmt);
        },
        .for_stmt => {
            const f = &stmt.data.for_stmt;
            // Iterable runs once before the loop: safe to hoist.
            if (exprHasSuspendCall(ctx, f.iterable)) {
                if (try hoistPreamble(ctx, f.iterable, out)) {
                    if (exprHasSuspendCall(ctx, f.body)) {
                        return suspendOperandError(ctx, f.body);
                    }
                    try out.append(stmt);
                    return;
                }
            }
            try forbidSuspendExpr(ctx, f.iterable, true);
            if (exprHasSuspendCall(ctx, f.body)) {
                return suspendOperandError(ctx, f.body);
            }
            try out.append(stmt);
        },
        .try_stmt => {
            const t = &stmt.data.try_stmt;
            try expandSuspendBranch(ctx, t.body);
            for (t.catches) |*cb| try expandSuspendBranch(ctx, cb.body);
            try out.append(stmt);
        },
        .when_expr => {
            const w = &stmt.data.when_expr;
            // Subject runs once: safe to hoist. Case conds run until match,
            // so they stay rejected (hoisting all would change semantics).
            if (w.subject) |s| {
                if (exprHasSuspendCall(ctx, s)) {
                    if (try hoistPreamble(ctx, s, out)) {
                        for (w.cases) |*case| {
                            for (case.conds) |cond| try forbidSuspendExpr(ctx, cond, true);
                            try expandSuspendBranch(ctx, case.body);
                        }
                        try out.append(stmt);
                        return;
                    }
                }
                try forbidSuspendExpr(ctx, s, true);
            }
            for (w.cases) |*case| {
                for (case.conds) |cond| try forbidSuspendExpr(ctx, cond, true);
                try expandSuspendBranch(ctx, case.body);
            }
            try out.append(stmt);
        },
        .block => {
            const b = &stmt.data.block;
            var block_out = ArrayList(*ASTNode).init(ctx.allocator);
            defer block_out.deinit();
            for (b.statements) |s| try expandSuspendStmt(ctx, s, &block_out);
            b.statements = try block_out.toOwnedSlice();
            try out.append(stmt);
        },
        .assignment => {
            const a = &stmt.data.assignment;
            if (a.value.data == .call_expr and callSuspends(ctx, a.value) and !syn.isSuspendPrimitiveCall(a.value)) {
                try hoistSubsInto(ctx, a.value, out);
                const info = try analyzeSuspendCall(ctx, a.value) orelse {
                    try out.append(stmt);
                    return;
                };
                const marker = try syn.mkSuspendCallMarker(ctx.allocator, info.recv, info.args);
                try ctx.suspend_sites.append(.{ .marker = marker, .machine = info.machine, .result = info.result, .target = a.name });
                a.value = marker;
                try out.append(stmt);
                return;
            }
            if (exprHasSuspendCall(ctx, a.value)) {
                if (try hoistPreamble(ctx, a.value, out)) {
                    try out.append(stmt);
                    return;
                }
                return suspendOperandError(ctx, a.value);
            }
            try out.append(stmt);
        },
        .break_stmt => {
            const b = &stmt.data.break_stmt;
            if (b.value) |val| {
                if (exprHasSuspendCall(ctx, val)) {
                    if (try hoistPreamble(ctx, val, out)) {
                        try out.append(stmt);
                        return;
                    }
                }
                try forbidSuspendExpr(ctx, val, false);
            }
            try out.append(stmt);
        },
        .throw_stmt => {
            const t = &stmt.data.throw_stmt;
            if (exprHasSuspendCall(ctx, t.expr)) {
                if (try hoistPreamble(ctx, t.expr, out)) {
                    try out.append(stmt);
                    return;
                }
            }
            try forbidSuspendExpr(ctx, t.expr, false);
            try out.append(stmt);
        },
        .lambda_expr, .fun_decl => try out.append(stmt),
        else => {
            if (exprHasSuspendCall(ctx, stmt)) {
                if (try hoistPreamble(ctx, stmt, out)) {
                    try out.append(stmt);
                    return;
                }
            }
            try forbidSuspendExpr(ctx, stmt, false);
            try out.append(stmt);
        },
    }
}

/// Expand a branch in place. A single-statement branch that splits in two
/// (the return case) is wrapped in a block, preserving source position.
fn expandSuspendBranch(ctx: Ctx, branch: *ASTNode) anyerror!void {
    var branch_out = ArrayList(*ASTNode).init(ctx.allocator);
    defer branch_out.deinit();
    if (branch.data == .block) {
        const b = &branch.data.block;
        for (b.statements) |s| try expandSuspendStmt(ctx, s, &branch_out);
        b.statements = try branch_out.toOwnedSlice();
        return;
    }
    const line = branch.line;
    const col = branch.column;
    try expandSuspendStmt(ctx, branch, &branch_out);
    if (branch_out.items.len == 1) {
        branch.* = branch_out.items[0].*;
        return;
    }
    const blk = syn.mkBlock(try branch_out.toOwnedSlice());
    blk.line = line;
    blk.column = col;
    branch.* = blk.*;
}

/// Pre-pass: lower supported suspend-call positions to `__SuspendCall`
/// markers (consumed by the state machine builder), reject the rest loudly.
/// Runs before locals promotion so marker temps become machine fields.
pub fn expandSuspendCalls(ctx: Ctx, body: []const *ASTNode) anyerror![]*ASTNode {
    var out = ArrayList(*ASTNode).init(ctx.allocator);
    defer out.deinit();
    for (body, 0..) |st, idx| {
        // A trailing bare suspend call is the block's value: lower it through
        // a temp so the machine drives the protocol and the trailing
        // identifier feeds task/callee completion. Void calls need no temp
        // (a Void-typed temp/ident would emit an invalid void load).
        if (idx == body.len - 1 and st.data == .call_expr and callSuspends(ctx, st) and !syn.isSuspendPrimitiveCall(st) and !syn.isAwaitCall(st) and !syn.isTaskCall(st)) {
            const info = try analyzeSuspendCall(ctx, st) orelse {
                try expandSuspendStmt(ctx, st, &out);
                continue;
            };
            if (isVoidRef(info.result)) {
                const marker = try syn.mkSuspendCallMarker(ctx.allocator, info.recv, info.args);
                try ctx.suspend_sites.append(.{ .marker = marker, .machine = info.machine, .result = info.result, .target = null });
                try out.append(marker);
                continue;
            }
            const n = ctx.counter.*;
            ctx.counter.* += 1;
            const tmp_name = try std.fmt.allocPrint(ctx.allocator, "__strail{d}", .{n});
            const marker = try syn.mkSuspendCallMarker(ctx.allocator, info.recv, info.args);
            try ctx.suspend_sites.append(.{ .marker = marker, .machine = info.machine, .result = info.result, .target = tmp_name });
            const tmp_decl = syn.mkVarDecl(tmp_name, marker);
            tmp_decl.data.var_decl.type_ref = info.result;
            try out.append(tmp_decl);
            // Bare identifier: a value statement, so the machine's trailing
            // logic feeds it to completion.
            try out.append(syn.mkIdent(tmp_name));
            continue;
        }
        try expandSuspendStmt(ctx, st, &out);
    }
    return out.toOwnedSlice();
}

/// Preserve null-narrowing across field promotion.
///
/// Machine bodies promote locals to fields, and flow narrowing only tracks
/// scope variables — `if (c == null) return` stops narrowing `this.c` in
/// later states. This rewrite aliases the narrowed value into a fresh local
/// (`val __narrowN = c`) wherever the checker has narrowed it, so the alias
/// (non-null from declaration) survives promotion. Semantics are unchanged:
/// aliases copy the current value of `val` bindings, substitution stops at
/// shadowing re-declarations and never enters lambdas. Shapes: guard-return,
/// if/else null dispatch, and `while (v != null)` bodies.
fn narrowingFixupList(ctx: Ctx, stmts: []const *ASTNode) anyerror![]*ASTNode {
    var out = ArrayList(*ASTNode).init(ctx.allocator);
    defer out.deinit();
    var i: usize = 0;
    while (i < stmts.len) : (i += 1) {
        const s = stmts[i];
        if (s.data == .if_expr) {
            const e = &s.data.if_expr;
            try narrowingFixupBranch(ctx, e.then_branch);
            if (e.else_branch) |eb| try narrowingFixupBranch(ctx, eb);
            if (isNullCheck(e.condition)) |nc| {
                if (nc.negated) {
                    try aliasBranchTop(ctx, e.then_branch, .{ .bang = nc.name });
                } else {
                    if (e.else_branch) |eb| {
                        try aliasBranchTop(ctx, eb, .{ .bang = nc.name });
                    }
                    if (e.else_branch == null and branchAlwaysReturns(e.then_branch) and !hasVarDecl(stmts, nc.name)) {
                        const alias = try freshAlias(ctx);
                        try out.append(s);
                        const gdecl = syn.mkVarDecl(alias, syn.mkUnary(.bang_bang, syn.mkIdent(nc.name)));
                        if (firstUseType(stmts[i + 1 ..], nc.name)) |t| {
                            gdecl.data.var_decl.type_ref = try aliasAnn(ctx, t);
                        }
                        try out.append(gdecl);
                        var j = i + 1;
                        while (j < stmts.len) : (j += 1) {
                            if (declaresName(stmts[j], nc.name)) break;
                            try substituteNode(ctx, stmts[j], nc.name, alias);
                        }
                        continue;
                    }
                }
            }
            if (isIsCheck(e.condition)) |ic| {
                if (!ic.negated) {
                    try aliasBranchTop(ctx, e.then_branch, .{ .cast = .{ .name = ic.name, .target = ic.target } });
                } else {
                    if (e.else_branch) |eb| {
                        try aliasBranchTop(ctx, eb, .{ .cast = .{ .name = ic.name, .target = ic.target } });
                    }
                }
            }
            try out.append(s);
            continue;
        }
        if (s.data == .while_stmt) {
            const w = &s.data.while_stmt;
            if (isNullCheck(w.condition)) |nc| {
                if (nc.negated) {
                    try aliasBranchTop(ctx, w.body, .{ .bang = nc.name });
                }
            }
            try narrowingFixupBranch(ctx, w.body);
            try out.append(s);
            continue;
        }
        if (s.data == .block) {
            const b = &s.data.block;
            b.statements = try narrowingFixupList(ctx, b.statements);
            try out.append(s);
            continue;
        }
        if (s.data == .try_stmt) {
            const t = &s.data.try_stmt;
            try narrowingFixupBranch(ctx, t.body);
            for (t.catches) |*cb| try narrowingFixupBranch(ctx, cb.body);
            try out.append(s);
            continue;
        }
        try out.append(s);
    }
    return out.toOwnedSlice();
}

fn narrowingFixupBranch(ctx: Ctx, branch: *ASTNode) anyerror!void {
    if (branch.data == .block) {
        const b = &branch.data.block;
        b.statements = try narrowingFixupList(ctx, b.statements);
        return;
    }
    var single = [_]*ASTNode{branch};
    const done = try narrowingFixupList(ctx, single[0..]);
    if (done.len == 1) {
        branch.* = done[0].*;
    } else {
        branch.* = syn.mkBlock(done).*;
    }
}

/// Narrowing alias init kinds: non-null assertion for null checks,
/// checked cast for `is` checks (both runtime-verified, sound wherever the
/// checker narrowed the source).
const AliasInit = union(enum) {
    bang: []const u8,
    cast: struct {
        name: []const u8,
        target: *const ast.ASTTypeRef,
    },
};

/// Insert a narrowing alias at the top of a branch and rewrite later uses.
/// Single-statement branches are wrapped in a block first.
fn aliasBranchTop(ctx: Ctx, branch: *ASTNode, init: AliasInit) anyerror!void {
    const alias = try freshAlias(ctx);
    const name = switch (init) {
        .bang => |n| n,
        .cast => |c| c.name,
    };
    const init_expr = switch (init) {
        .bang => |n| syn.mkUnary(.bang_bang, syn.mkIdent(n)),
        .cast => |c| syn.mkAs(syn.mkIdent(c.name), c.target),
    };
    var probe = [_]*ASTNode{branch};
    const ann = switch (init) {
        .bang => if (firstUseType(probe[0..], name)) |t| try aliasAnn(ctx, t) else null,
        .cast => |c| c.target,
    };
    if (branch.data != .block) {
        const decl = syn.mkVarDecl(alias, init_expr);
        if (ann) |a| decl.data.var_decl.type_ref = a;
        const wrapped = syn.mkBlock(&.{ decl, branch });
        branch.* = wrapped.*;
    } else {
        const b = &branch.data.block;
        if (hasVarDecl(b.statements, name)) return;
        const decl = syn.mkVarDecl(alias, init_expr);
        if (ann) |a| decl.data.var_decl.type_ref = a;
        const new_list = try ctx.allocator.alloc(*ASTNode, b.statements.len + 1);
        new_list[0] = decl;
        @memcpy(new_list[1..], b.statements);
        b.statements = new_list;
    }
    // Rewrite uses after the inserted declaration.
    const stmts = branch.data.block.statements[1..];
    for (stmts) |st| {
        if (declaresName(st, name)) break;
        try substituteNode(ctx, st, name, alias);
    }
}

/// True when `var <name>` is declared in this list (narrowing never
/// applies to vars, so aliasing them would turn today's compile error into
/// a runtime throw — skip instead).
fn hasVarDecl(stmts: []const *ASTNode, name: []const u8) bool {
    for (stmts) |st| {
        if (st.data == .var_decl and std.mem.eql(u8, st.data.var_decl.name, name)) {
            if (st.data.var_decl.is_mut) return true;
        }
    }
    return false;
}

/// Narrowed type snapshot for an alias: first use of `name` in range.
fn firstUseType(stmts: []const *ASTNode, name: []const u8) ?*const EiwaType {
    for (stmts) |st| {
        if (findUseType(st, name)) |t| return t;
    }
    return null;
}

fn findUseType(node: *ASTNode, name: []const u8) ?*const EiwaType {
    switch (node.data) {
        .identifier => |i| {
            if (std.mem.eql(u8, i.name, name)) {
                if (node.resolved_type) |t| return t;
            }
            return null;
        },
        .lambda_expr, .fun_decl => return null,
        .call_expr => |c| {
            if (findUseType(c.callee, name)) |t| return t;
            for (c.arguments) |a| {
                if (findUseType(a, name)) |t| return t;
            }
            return null;
        },
        .binary_expr => |b| {
            if (findUseType(b.left, name)) |t| return t;
            return findUseType(b.right, name);
        },
        .unary_expr => |u| return findUseType(u.operand, name),
        .get_expr => |g| return findUseType(g.object, name),
        .set_expr => |se| {
            if (findUseType(se.object, name)) |t| return t;
            return findUseType(se.value, name);
        },
        .block => |b| {
            for (b.statements) |st| {
                if (declaresName(st, name)) return null;
                if (findUseType(st, name)) |t| return t;
            }
            return null;
        },
        .var_decl => |v| {
            if (v.initializer) |init| {
                if (findUseType(init, name)) |t| return t;
            }
            return null;
        },
        .return_stmt => |r| {
            if (r.value) |val| return findUseType(val, name);
            return null;
        },
        else => return null,
    }
}

/// Annotation for a narrowing alias from an observed EiwaType: named and
/// nullable-preserving (a raw union conversion yields an empty-name union
/// typeref that misbehaves in field position).
fn aliasAnn(ctx: Ctx, t: *const EiwaType) !*const ast.ASTTypeRef {
    switch (t.*) {
        .Union => |u| {
            if (u.right.* == .Null) {
                const inner = try aliasAnn(ctx, u.left);
                return try caps.makeNullableTypeRef(ctx, inner);
            }
            return try syn.typeRefForEiwaType(ctx.allocator, t);
        },
        else => return try syn.typeRefForEiwaType(ctx.allocator, t),
    }
}

fn freshAlias(ctx: Ctx) ![]const u8 {
    const n = ctx.counter.*;
    ctx.counter.* += 1;
    return std.fmt.allocPrint(ctx.allocator, "__narrow{d}", .{n});
}

const NullCheck = struct {
    name: []const u8,
    negated: bool,
};

/// `v is T` (negated=false) or `v is! T` (negated=true) on an identifier.
const IsCheck = struct {
    name: []const u8,
    target: *const ast.ASTTypeRef,
    negated: bool,
};

fn isIsCheck(node: *ASTNode) ?IsCheck {
    if (node.data != .is_expr) return null;
    const e = &node.data.is_expr;
    if (e.value.data != .identifier) return null;
    return .{ .name = e.value.data.identifier.name, .target = e.type_ref, .negated = e.is_not };
}

/// `v == null` (negated=false) or `v != null` (negated=true) on an identifier.
fn isNullCheck(node: *ASTNode) ?NullCheck {
    if (node.data != .binary_expr) return null;
    const b = &node.data.binary_expr;
    const is_eq = b.op == .eq_eq;
    const is_ne = b.op == .bang_eq;
    if (!is_eq and !is_ne) return null;
    if (b.left.data == .identifier and b.right.data == .null_literal) {
        return .{ .name = b.left.data.identifier.name, .negated = is_ne };
    }
    if (b.right.data == .identifier and b.left.data == .null_literal) {
        return .{ .name = b.right.data.identifier.name, .negated = is_ne };
    }
    return null;
}

fn branchAlwaysReturns(node: *ASTNode) bool {
    if (node.data == .block) {
        const b = &node.data.block;
        if (b.statements.len == 0) return false;
        return lastStmtReturns(b.statements[b.statements.len - 1]);
    }
    return lastStmtReturns(node);
}

fn lastStmtReturns(node: *ASTNode) bool {
    return switch (node.data) {
        .return_stmt => true,
        .block => |b| b.statements.len > 0 and lastStmtReturns(b.statements[b.statements.len - 1]),
        else => false,
    };
}

/// Substitute identifier uses (not declarations), stopping at shadowing.
fn substituteIdent(ctx: Ctx, stmts: []const *ASTNode, name: []const u8, alias: []const u8) anyerror!void {
    for (stmts) |st| {
        if (declaresName(st, name)) return;
        try substituteNode(ctx, st, name, alias);
    }
}

fn declaresName(node: *ASTNode, name: []const u8) bool {
    switch (node.data) {
        .var_decl => |v| return std.mem.eql(u8, v.name, name),
        .for_stmt => |f| {
            if (f.index_name) |idx| {
                if (std.mem.eql(u8, idx, name)) return true;
            }
            return std.mem.eql(u8, f.item_name, name);
        },
        else => return false,
    }
}

fn substituteNode(ctx: Ctx, node: *ASTNode, name: []const u8, alias: []const u8) anyerror!void {
    switch (node.data) {
        .identifier => |*i| {
            if (std.mem.eql(u8, i.name, name)) {
                i.name = alias;
                i.resolved_c_name = null;
            }
            return;
        },
        .lambda_expr, .fun_decl => return,
        .call_expr => |*c| {
            try substituteNode(ctx, c.callee, name, alias);
            for (c.arguments) |a| try substituteNode(ctx, a, name, alias);
        },
        .binary_expr => |*b| {
            try substituteNode(ctx, b.left, name, alias);
            try substituteNode(ctx, b.right, name, alias);
        },
        .unary_expr => |*u| try substituteNode(ctx, u.operand, name, alias),
        .get_expr => |*g| try substituteNode(ctx, g.object, name, alias),
        .set_expr => |*s| {
            try substituteNode(ctx, s.object, name, alias);
            try substituteNode(ctx, s.value, name, alias);
        },
        .index_expr => |*i| {
            try substituteNode(ctx, i.object, name, alias);
            try substituteNode(ctx, i.index, name, alias);
        },
        .index_set_expr => |*i| {
            try substituteNode(ctx, i.object, name, alias);
            try substituteNode(ctx, i.index, name, alias);
            try substituteNode(ctx, i.value, name, alias);
        },
        .block => |*b| {
            for (b.statements) |st| {
                if (declaresName(st, name)) return;
                try substituteNode(ctx, st, name, alias);
            }
        },
        .var_decl => |*v| {
            if (v.initializer) |init| try substituteNode(ctx, init, name, alias);
        },
        .assignment => |*a| try substituteNode(ctx, a.value, name, alias),
        .return_stmt => |*r| {
            if (r.value) |val| try substituteNode(ctx, val, name, alias);
        },
        .break_stmt => |*b| {
            if (b.value) |val| try substituteNode(ctx, val, name, alias);
        },
        .if_expr => |*i| {
            try substituteNode(ctx, i.condition, name, alias);
            try substituteNode(ctx, i.then_branch, name, alias);
            if (i.else_branch) |e| try substituteNode(ctx, e, name, alias);
        },
        .while_stmt => |*w| {
            try substituteNode(ctx, w.condition, name, alias);
            try substituteNode(ctx, w.body, name, alias);
        },
        .for_stmt => |*f| {
            if (declaresName(node, name)) return;
            try substituteNode(ctx, f.iterable, name, alias);
            try substituteNode(ctx, f.body, name, alias);
        },
        .try_stmt => |*t| {
            try substituteNode(ctx, t.body, name, alias);
            for (t.catches) |*cb| try substituteNode(ctx, cb.body, name, alias);
        },
        .throw_stmt => |*t| try substituteNode(ctx, t.expr, name, alias),
        .string_template => |*st| {
            for (st.parts) |p| try substituteNode(ctx, p, name, alias);
        },
        .array_literal => |*al| {
            for (al.elements) |e| try substituteNode(ctx, e, name, alias);
        },
        .map_literal => |*ml| {
            for (ml.elements) |e| try substituteNode(ctx, e, name, alias);
        },
        .named_arg => |*na| try substituteNode(ctx, na.value, name, alias),
        .as_expr => |*a| try substituteNode(ctx, a.value, name, alias),
        .is_expr => |*i| try substituteNode(ctx, i.value, name, alias),
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Rewriting task/await call sites
// ---------------------------------------------------------------------------

/// `val t = task { block }` -> machinery + `val t = __taskN`.
/// Rejects constructs a state machine cannot lower: `break`, value-`for`,
/// value-`try`. Nested lambda/task bodies lower separately.
const TaskRejectKind = enum { @"break", collect_for, try_value };

pub fn taskNodeHas(node: *ASTNode, kind: TaskRejectKind) ?*ASTNode {
    switch (node.data) {
        .break_stmt => |b| {
            if (kind == .@"break") return node;
            if (b.value) |val| return taskNodeHas(val, kind);
            return null;
        },
        .lambda_expr, .fun_decl => return null,
        .call_expr => |c| {
            if (syn.isTaskCall(node)) return null;
            if (taskNodeHas(c.callee, kind)) |found| return found;
            for (c.arguments) |a| if (taskNodeHas(a, kind)) |found| return found;
            return null;
        },
        .block => |b| {
            for (b.statements) |s| if (taskNodeHas(s, kind)) |found| return found;
            return null;
        },
        .if_expr => |i| {
            if (taskNodeHas(i.then_branch, kind)) |found| return found;
            if (i.else_branch) |e| if (taskNodeHas(e, kind)) |found| return found;
            return null;
        },
        .while_stmt => |w| return taskNodeHas(w.body, kind),
        .for_stmt => |f| {
            if (kind == .collect_for and f.collect) return node;
            if (taskNodeHas(f.iterable, kind)) |found| return found;
            return taskNodeHas(f.body, kind);
        },
        .try_stmt => |t| {
            if (kind == .try_value and t.is_value) return node;
            if (taskNodeHas(t.body, kind)) |found| return found;
            for (t.catches) |c| if (taskNodeHas(c.body, kind)) |found| return found;
            return null;
        },
        .when_expr => |w| {
            for (w.cases) |c| if (taskNodeHas(c.body, kind)) |found| return found;
            return null;
        },
        .var_decl => |v| {
            if (v.initializer) |init| return taskNodeHas(init, kind);
            return null;
        },
        .return_stmt => |r| {
            if (r.value) |val| return taskNodeHas(val, kind);
            return null;
        },
        .assignment => |a| return taskNodeHas(a.value, kind),
        else => return null,
    }
}

pub fn rewriteTaskCall(ctx: Ctx, stmt: *ASTNode, task_call: *ASTNode) ![]*ASTNode {
    const v = &stmt.data.var_decl;
    const has_disp = task_call.data.call_expr.arguments.len > 1;
    const disp_node = if (has_disp) task_call.data.call_expr.arguments[0] else null;
    const lambda = if (has_disp) task_call.data.call_expr.arguments[1] else task_call.data.call_expr.arguments[0];
    if (lambda.data != .lambda_expr) return error.InvalidTaskCall;
    const body = lambda.data.lambda_expr.body;

    for (body) |bstmt| {
        if (taskNodeHas(bstmt, .@"break")) |brk| {
            ctx.checker.reportError(brk.line, brk.column, "TypeError: 'leave' is not supported inside task blocks (synchronous code only).", .{});
            return error.TypeError;
        }
        if (taskNodeHas(bstmt, .collect_for)) |cf| {
            ctx.checker.reportError(cf.line, cf.column, "TypeError: for used as a value is not supported inside task blocks yet.", .{});
            return error.TypeError;
        }
        if (taskNodeHas(bstmt, .try_value)) |tv| {
            ctx.checker.reportError(tv.line, tv.column, "TypeError: try used as a value is not supported inside task blocks yet.", .{});
            return error.TypeError;
        }
    }

    const outer_this_t = caps.findOuterThisType(ctx, body);
    if (outer_this_t != null) {
        try caps.rewriteOuterThisRefs(ctx, body);
    }

    const captures_pre = try caps.collectCaptures(ctx, body);
    var captures = captures_pre;
    if (outer_this_t) |ot| {
        var extended = ArrayList(CapturedVar).init(ctx.allocator);
        try extended.appendSlice(captures_pre);
        try extended.append(.{
            .name = outer_this_field,
            .type_ref = try syn.typeRefForEiwaType(ctx.allocator, ot),
            .is_boxed = false,
        });
        captures = try extended.toOwnedSlice();
    }
    const result_type = syn.blockReturnType(body);

    const n = ctx.counter.*;
    ctx.counter.* += 1;

    const block_type = try buildTaskBlockType(ctx, captures, result_type, body);

    var out = ArrayList(*ASTNode).init(ctx.allocator);
    defer out.deinit();

    const task_name = try std.fmt.allocPrint(ctx.allocator, "__task{d}", .{n});
    const ctor_call = syn.mkCall(syn.mkIdent("StackTask"), &.{ syn.mkBoolLit(false), syn.mkNullLit(), syn.mkNullLit() });
    {
        const type_arg_refs = std.heap.page_allocator.alloc(*const ASTTypeRef, 1) catch unreachable;
        type_arg_refs[0] = try syn.typeRefForEiwaType(ctx.allocator, result_type);
        ctor_call.data.call_expr.type_args = type_arg_refs;
    }
    const stack_task_ref = try syn.typeRefWithArgs(ctx.allocator, "StackTask", &.{result_type});
    const task_var = syn.mkVarDecl(task_name, ctor_call);
    task_var.data.var_decl.type_ref = stack_task_ref;
    try out.append(task_var);

    var ctor_args = ArrayList(*ASTNode).init(ctx.allocator);
    defer ctor_args.deinit();
    try ctor_args.append(syn.mkIdent(task_name));
    for (captures) |c| {
        var arg = syn.mkIdent(c.name);
        if (std.mem.eql(u8, c.name, outer_this_field)) {
            arg = syn.mkIdent("this");
        } else {
            arg.data.identifier.is_box_ref = c.is_boxed;
        }
        try ctor_args.append(arg);
    }
    const block_ctor_call = syn.mkCall(syn.mkIdent(block_type.data.type_decl.name), ctor_args.items);
    if (disp_node) |dn| {
        try out.append(syn.mkExprStmt(syn.mkCall(syn.mkGetExpr(dn, "ensureStarted"), &.{})));
    }
    const schedule_call = if (disp_node) |dn|
        syn.mkCall(syn.mkGetExpr(syn.mkGetExpr(dn, "scheduler"), "schedule"), &.{block_ctor_call})
    else
        syn.mkCall(syn.mkGetExpr(syn.mkIdent("Scheduler"), "schedule"), &.{block_ctor_call});
    try out.append(syn.mkExprStmt(schedule_call));

    const bind = syn.mkVarDecl(v.name, syn.mkIdent(task_name));
    bind.data.var_decl.is_mut = v.is_mut;
    bind.data.var_decl.type_ref = stack_task_ref;
    try out.append(bind);

    return out.toOwnedSlice();
}

/// Fire-and-forget `task {}`: generates and schedules the machinery, drops the
/// result binding. Without this the body would allocate a task but never run.
pub fn rewriteBareTaskCall(ctx: Ctx, stmt: *ASTNode, task_call: *ASTNode) ![]*ASTNode {
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
    const gen = try rewriteTaskCall(ctx, &temp, task_call);
    return gen[0 .. gen.len - 1];
}

pub fn rewriteTaskAwaitCall(ctx: Ctx, stmt: *ASTNode, await_call: *ASTNode, coop: bool) ![]*ASTNode {
    const v = &stmt.data.var_decl;
    const recv = await_call.data.call_expr.callee.data.get_expr.object;

    var out = ArrayList(*ASTNode).init(ctx.allocator);
    defer out.deinit();

    const machinery = try rewriteTaskCall(ctx, stmt, recv);
    const task_name = machinery[machinery.len - 1].data.var_decl.initializer.?.data.identifier.name;

    if (coop) {
        // Dropping the machinery bind would leave `r` typed as StackTask.
        const result_type = stmt.resolved_type orelse syn.awaitResultType(recv);
        try out.appendSlice(machinery[0 .. machinery.len - 1]);
        try out.append(try syn.mkCoopAwaitMarker(ctx.allocator, syn.mkIdent(task_name), v.name, v.is_mut, result_type));
        return out.toOwnedSlice();
    }

    try out.appendSlice(machinery);
    const poll = syn.buildPollStmt(syn.mkIdent(task_name));
    try out.append(poll);

    const result_val = syn.mkUnary(.bang_bang, syn.mkGetExpr(syn.mkIdent(task_name), "result"));
    const bind = syn.mkVarDecl(v.name, result_val);
    bind.data.var_decl.is_mut = v.is_mut;
    const res_type = resolveAwaitBindingType(stmt, await_call, recv, v);
    if (res_type) |t| {
        if (t.* != .Void) {
            bind.data.var_decl.type_ref = try syn.typeRefForEiwaType(ctx.allocator, t);
            bind.resolved_type = t;
            result_val.resolved_type = t;
        }
    } else if (v.type_ref) |tr| {
        bind.data.var_decl.type_ref = tr;
    }
    try out.append(bind);

    return out.toOwnedSlice();
}

pub fn resolveAwaitBindingType(stmt: *ASTNode, await_call: *ASTNode, recv: *ASTNode, v: anytype) ?*const EiwaType {
    if (await_call.resolved_type) |at| {
        if (at.* != .Void) return at;
    }
    if (stmt.resolved_type) |st| {
        if (st.* != .Void) return st;
    }
    if (syn.awaitResultType(recv)) |rt| {
        if (rt.* != .Void) return rt;
    }
    if (v.type_ref) |tr| {
        if (tr.resolved_type) |trt| {
            if (trt.* != .Void) return trt;
        }
    }
    return stmt.resolved_type orelse await_call.resolved_type orelse syn.awaitResultType(recv);
}

pub fn rewriteAwaitCall(ctx: Ctx, stmt: *ASTNode, await_call: *ASTNode, coop: bool) ![]*ASTNode {
    const v = &stmt.data.var_decl;
    const recv = await_call.data.call_expr.callee.data.get_expr.object;

    var out = ArrayList(*ASTNode).init(ctx.allocator);
    defer out.deinit();

    if (coop) {
        const result_type = resolveAwaitBindingType(stmt, await_call, recv, v);
        try out.append(try syn.mkCoopAwaitMarker(ctx.allocator, recv, v.name, v.is_mut, result_type));
        return out.toOwnedSlice();
    }

    try out.append(syn.buildPollStmt(recv));
    const result_val = syn.mkUnary(.bang_bang, syn.mkGetExpr(recv, "result"));
    const bind = syn.mkVarDecl(v.name, result_val);
    bind.data.var_decl.is_mut = v.is_mut;
    const res_type = resolveAwaitBindingType(stmt, await_call, recv, v);
    if (res_type) |t| {
        if (t.* != .Void) {
            bind.data.var_decl.type_ref = try syn.typeRefForEiwaType(ctx.allocator, t);
            bind.resolved_type = t;
            result_val.resolved_type = t;
        }
    } else if (v.type_ref) |tr| {
        bind.data.var_decl.type_ref = tr;
    }
    try out.append(bind);
    return out.toOwnedSlice();
}

pub fn rewriteReturnAwait(ctx: Ctx, stmt: *ASTNode, await_call: *ASTNode) ![]*ASTNode {
    _ = stmt;
    const recv = await_call.data.call_expr.callee.data.get_expr.object;

    var out = ArrayList(*ASTNode).init(ctx.allocator);
    defer out.deinit();

    try out.append(syn.buildPollStmt(recv));
    const ret = syn.mkReturn(syn.mkUnary(.bang_bang, syn.mkGetExpr(recv, "result")));
    try out.append(ret);
    return out.toOwnedSlice();
}

pub fn rewriteReturnTaskAwait(ctx: Ctx, _stmt: *ASTNode, await_call: *ASTNode) ![]*ASTNode {
    _ = _stmt;
    const recv = await_call.data.call_expr.callee.data.get_expr.object;

    var out = ArrayList(*ASTNode).init(ctx.allocator);
    defer out.deinit();

    var temp_stmts = ArrayList(*ASTNode).init(ctx.allocator);
    defer temp_stmts.deinit();
    const temp_name = try std.fmt.allocPrint(ctx.allocator, "__rt{d}", .{ctx.counter.*});
    ctx.counter.* += 1;
    const temp_decl = syn.mkVarDecl(temp_name, null);
    try temp_stmts.append(temp_decl);

    const machinery = try rewriteTaskCall(ctx, temp_stmts.items[0], recv);
    try out.appendSlice(machinery);
    const task_name = machinery[machinery.len - 1].data.var_decl.initializer.?.data.identifier.name;

    try out.append(syn.buildPollStmt(syn.mkIdent(task_name)));
    const ret = syn.mkReturn(syn.mkUnary(.bang_bang, syn.mkGetExpr(syn.mkIdent(task_name), "result")));
    try out.append(ret);
    return out.toOwnedSlice();
}

pub fn machineBuildCoopAwait(m: *Machine, stmt: *ASTNode, after: usize) anyerror!usize {
    const v = &stmt.data.var_decl;
    const raw_recv = v.initializer.?.data.call_expr.arguments[0];
    const recv = if (raw_recv.data == .get_expr and raw_recv.data.get_expr.object.data == .identifier and std.mem.eql(u8, raw_recv.data.get_expr.object.data.identifier.name, "this"))
        syn.mkUnary(.bang_bang, raw_recv)
    else
        raw_recv;

    const guard_label = try m.newState();
    const read_label = try m.newState();

    const not_ready = syn.mkUnary(.bang, syn.mkCall(syn.mkGetExpr(recv, "awaitCoop"), &.{syn.mkIdent("this")}));
    const suspend_block = syn.mkBlock(&.{
        syn.mkSetExpr(syn.mkIdent("this"), "label", syn.mkIntLit(@intCast(read_label))),
        syn.mkReturnVoid(),
    });
    const fall_block = syn.mkBlock(&.{syn.mkSetExpr(syn.mkIdent("this"), "label", syn.mkIntLit(@intCast(read_label)))});
    try m.append(guard_label, syn.mkIfElse(not_ready, suspend_block, fall_block));

    const result_get = syn.mkUnary(.bang_bang, syn.mkGetExpr(recv, "result"));
    try m.append(read_label, syn.mkSetExpr(syn.mkIdent("this"), v.name, result_get));
    try m.append(read_label, syn.mkSetExpr(syn.mkIdent("this"), "label", syn.mkIntLit(@intCast(after))));

    return guard_label;
}

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
        return;
    }
    switch (node.data) {
        .call_expr => |*c| {
            if (syn.isTaskCall(node)) return; // task blocks are boundaries
            try hoistAwaitsWalk(ctx, c.callee, preamble, hoisted);
            for (c.arguments) |arg| {
                try hoistAwaitsWalk(ctx, arg, preamble, hoisted);
            }
        },
        .lambda_expr => return,
        .binary_expr => |*b| {
            try hoistAwaitsWalk(ctx, b.left, preamble, hoisted);
            try hoistAwaitsWalk(ctx, b.right, preamble, hoisted);
        },
        .unary_expr => |*u| try hoistAwaitsWalk(ctx, u.operand, preamble, hoisted),
        .get_expr => |*g| try hoistAwaitsWalk(ctx, g.object, preamble, hoisted),
        .set_expr => |*s| {
            try hoistAwaitsWalk(ctx, s.object, preamble, hoisted);
            try hoistAwaitsWalk(ctx, s.value, preamble, hoisted);
        },
        .index_expr => |*i| {
            try hoistAwaitsWalk(ctx, i.object, preamble, hoisted);
            try hoistAwaitsWalk(ctx, i.index, preamble, hoisted);
        },
        .index_set_expr => |*i| {
            try hoistAwaitsWalk(ctx, i.object, preamble, hoisted);
            try hoistAwaitsWalk(ctx, i.index, preamble, hoisted);
            try hoistAwaitsWalk(ctx, i.value, preamble, hoisted);
        },
        .array_literal => |*al| {
            for (al.elements) |e| {
                try hoistAwaitsWalk(ctx, e, preamble, hoisted);
            }
        },
        .string_template => |*st| {
            for (st.parts) |e| {
                try hoistAwaitsWalk(ctx, e, preamble, hoisted);
            }
        },
        .map_literal => |*ml| {
            for (ml.elements) |e| {
                try hoistAwaitsWalk(ctx, e, preamble, hoisted);
            }
        },
        .named_arg => |*na| try hoistAwaitsWalk(ctx, na.value, preamble, hoisted),
        .assignment => |*a| try hoistAwaitsWalk(ctx, a.value, preamble, hoisted),
        .var_decl => |*v| if (v.initializer) |init| try hoistAwaitsWalk(ctx, init, preamble, hoisted),
        else => {},
    }
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

    if (state_machine) {
        for (body) |s| {
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
        const locals = try caps.collectPromotableLocals(ctx, body);
        defer ctx.allocator.free(locals);
        for (locals) |l| {
            var prop_type_ref = l.type_ref;
            var default_init = syn.defaultInitializerForTypeRef(l.type_ref);
            if (default_init == null) {
                const nullable_ref = try caps.makeNullableTypeRef(ctx, l.type_ref);
                prop_type_ref = nullable_ref;
                default_init = syn.mkNullLit();
            }
            try body_fields.append(.{
                .is_mut = true,
                .name = l.name,
                .type_ref = prop_type_ref,
                .is_property = true,
                .initializer = default_init.?,
            });
        }
        var entry_label: usize = 0;
        resume_method = try buildResumeStateMachine(ctx, captures, locals, body, result_type, &entry_label, &body_fields);
        try methods.append(resume_method);
        try body_fields.append(.{
            .is_mut = true,
            .name = "label",
            .type_ref = syn.typeRefSimple("Int"),
            .is_property = true,
            .initializer = syn.mkIntLit(@intCast(entry_label)),
        });
    } else {
        try methods.append(try buildResume(ctx, captures, body, result_type));
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
            syn.mkGetExpr(syn.mkIdent("Scheduler"), "schedule"),
            &.{syn.mkGetExpr(syn.mkUnary(.bang_bang, syn.mkIdent(waiter_name)), "cont")},
        ),
        syn.mkAssign(waiter_name, syn.mkGetExpr(syn.mkUnary(.bang_bang, syn.mkIdent(waiter_name)), "next")),
    });
    try out.append(syn.mkWhile(
        syn.mkBinary(.bang_eq, syn.mkIdent(waiter_name), syn.mkNullLit()),
        while_body,
    ));
    return out;
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
            if (syn.containsTrueSuspend(stmt)) return error.SuspendInOperand;
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
            if (syn.containsTrueSuspend(stmt)) return error.SuspendInOperand;
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
pub fn buildResumeStateMachine(ctx: Ctx, captures: []const CapturedVar, locals: []const CapturedVar, body: []const *ASTNode, result_type: *const EiwaType, entry_out: *usize, body_fields: *ArrayList(ast.ClassProp)) !*ASTNode {
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
    }
    try leading.appendSlice(rewritten.items);

    var m = Machine{ .allocator = ctx.allocator, .counter = ctx.counter, .states = ArrayList(MachineState).init(ctx.allocator) };
    defer m.states.deinit();
    const done_label = try m.newState();
    const entry = try machineBuildStmts(&m, leading.items, done_label);
    entry_out.* = entry;

    var completion = try buildCompletionStmts(ctx, trailing);
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

    const outer_this_t = caps.findOuterThisType(body);
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

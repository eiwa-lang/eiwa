const std = @import("std");
const compat = @import("compat.zig");
const ArrayList = compat.ArrayList;
const ast = @import("ast.zig");
const ASTNode = ast.ASTNode;
const ASTTypeRef = ast.ASTTypeRef;
const ts = @import("type_system.zig");
const EiwaType = ts.EiwaType;

pub fn isTaskCall(node: *ASTNode) bool {
    if (node.data != .call_expr) return false;
    const c = &node.data.call_expr;
    if (c.callee.data != .identifier) return false;
    return std.mem.eql(u8, c.callee.data.identifier.name, "task");
}

pub fn isAwaitCall(node: *ASTNode) bool {
    if (node.data != .call_expr) return false;
    const c = &node.data.call_expr;
    if (c.callee.data != .get_expr) return false;
    return std.mem.eql(u8, c.callee.data.get_expr.name, "await");
}

pub fn blockReturnType(body: []const *ASTNode) *const EiwaType {
    if (body.len > 0) {
        if (body[body.len - 1].resolved_type) |rt| return rt;
    }
    return &defaultVoidType;
}

pub var defaultVoidType: EiwaType = .Void;

pub fn isValueStatement(node: *ASTNode) bool {
    switch (node.data) {
        .int_literal, .double_literal, .string_literal, .string_template, .bool_literal, .identifier, .binary_expr, .unary_expr, .call_expr, .get_expr, .index_expr, .array_literal, .map_literal, .lambda_expr => return true,
        else => return false,
    }
}

pub fn isSuspendPrimitiveCall(node: *ASTNode) bool {
    if (node.data != .call_expr) return false;
    const c = &node.data.call_expr;
    const name = switch (c.callee.data) {
        .get_expr => |g| g.name,
        .identifier => |i| i.name,
        else => return false,
    };
    return std.mem.eql(u8, name, "sleep") or
        std.mem.eql(u8, name, "sleepMs") or
        std.mem.eql(u8, name, "yield") or
        std.mem.eql(u8, name, "waitReadable") or
        std.mem.eql(u8, name, "waitWritable");
}

pub fn buildPollStmt(recv: *ASTNode) *ASTNode {
    const not_done = mkUnary(.bang, mkGetExpr(recv, "done"));
    const step_call = mkCall(mkGetExpr(mkIdent("Scheduler"), "runStep"), &.{});
    const not_step = mkUnary(.bang, step_call);
    const sleep_call = mkCall(mkGetExpr(mkIdent("Coroutine"), "sleepMs"), &.{mkIntLit(1)});
    const if_stmt = mkIf(not_step, mkBlock(&.{mkExprStmt(sleep_call)}));
    const body = mkBlock(&.{if_stmt});
    return mkWhile(not_done, body);
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

pub fn isCoopAwaitCall(node: *ASTNode) bool {
    if (node.data != .call_expr) return false;
    const callee = node.data.call_expr.callee;
    if (callee.data != .identifier) return false;
    return std.mem.eql(u8, callee.data.identifier.name, "__CoopAwait");
}

pub fn isCoopAwaitMarker(node: *ASTNode) bool {
    if (node.data != .var_decl) return false;
    const v = &node.data.var_decl;
    const init = v.initializer orelse return false;
    return isCoopAwaitCall(init);
}

pub fn recv_result_type(recv: *ASTNode) ?*const EiwaType {
    if (recv.resolved_type) |rt| {
        const t = singleTypeArg(rt);
        if (t.* != .Void) return t;
    }
    return null;
}

pub fn mkCoopAwaitMarker(
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

pub fn mkIdent(name: []const u8) *ASTNode {
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

pub fn mkIntLit(value: i64) *ASTNode {
    const n = std.heap.page_allocator.create(ASTNode) catch unreachable;
    n.* = .{
        .line = 0,
        .column = 0,
        .data = .{ .int_literal = value },
    };
    return n;
}

pub fn mkBoolLit(value: bool) *ASTNode {
    const n = std.heap.page_allocator.create(ASTNode) catch unreachable;
    n.* = .{
        .line = 0,
        .column = 0,
        .data = .{ .bool_literal = value },
    };
    return n;
}

pub fn mkArrayLit(elements: []const *ASTNode) *ASTNode {
    const n = std.heap.page_allocator.create(ASTNode) catch unreachable;
    n.* = .{
        .line = 0,
        .column = 0,
        .data = .{ .array_literal = .{
            .elements = elements,
        } },
    };
    return n;
}

pub fn mkTryStmt(body: *ASTNode, catches: []const ast.CatchBlock) *ASTNode {
    const n = std.heap.page_allocator.create(ASTNode) catch unreachable;
    n.* = .{
        .line = 0,
        .column = 0,
        .data = .{ .try_stmt = .{
            .body = body,
            .catches = @constCast(catches),
        } },
    };
    return n;
}

pub fn mkNullLit() *ASTNode {
    const n = std.heap.page_allocator.create(ASTNode) catch unreachable;
    n.* = .{
        .line = 0,
        .column = 0,
        .data = .null_literal,
    };
    return n;
}

pub fn mkVarDecl(name: []const u8, initializer: ?*ASTNode) *ASTNode {
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

pub fn mkExprStmt(expr: *ASTNode) *ASTNode {
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

pub fn mkCall(callee: *ASTNode, args: []const *ASTNode) *ASTNode {
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

pub fn mkGetExpr(object: *ASTNode, name: []const u8) *ASTNode {
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

pub fn mkSetExpr(object: *ASTNode, name: []const u8, value: *ASTNode) *ASTNode {
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

pub fn mkIndexExpr(object: *ASTNode, index: *ASTNode) *ASTNode {
    const n = std.heap.page_allocator.create(ASTNode) catch unreachable;
    n.* = .{
        .line = 0,
        .column = 0,
        .data = .{ .index_expr = .{
            .object = object,
            .index = index,
        } },
    };
    return n;
}

pub fn mkAssign(name: []const u8, value: *ASTNode) *ASTNode {
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

pub fn mkBlock(statements: []const *ASTNode) *ASTNode {
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

pub fn mkIf(condition: *ASTNode, then_branch: *ASTNode) *ASTNode {
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

pub fn mkIfElse(condition: *ASTNode, then_branch: *ASTNode, else_branch: *ASTNode) *ASTNode {
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

pub fn mkDoubleLit(value: f64) *ASTNode {
    const n = std.heap.page_allocator.create(ASTNode) catch unreachable;
    n.* = .{
        .line = 0,
        .column = 0,
        .data = .{ .double_literal = value },
    };
    return n;
}

pub fn mkStringLit(value: []const u8) *ASTNode {
    const n = std.heap.page_allocator.create(ASTNode) catch unreachable;
    n.* = .{
        .line = 0,
        .column = 0,
        .data = .{ .string_literal = value },
    };
    return n;
}

pub fn mkWhile(condition: *ASTNode, body: *ASTNode) *ASTNode {
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

pub fn mkBinary(op: ast.TokenType, left: *ASTNode, right: *ASTNode) *ASTNode {
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

pub fn mkUnary(op: ast.TokenType, operand: *ASTNode) *ASTNode {
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

pub fn mkReturn(value: *ASTNode) *ASTNode {
    const n = std.heap.page_allocator.create(ASTNode) catch unreachable;
    n.* = .{
        .line = 0,
        .column = 0,
        .data = .{ .return_stmt = .{ .value = value } },
    };
    return n;
}

pub fn mkReturnVoid() *ASTNode {
    const n = std.heap.page_allocator.create(ASTNode) catch unreachable;
    n.* = .{
        .line = 0,
        .column = 0,
        .data = .{ .return_stmt = .{ .value = null } },
    };
    return n;
}

pub fn mkFunDecl(name: []const u8, params: []const ast.Param, body: *ASTNode, is_expr_body: bool, modifiers: []const ast.TokenType) *ASTNode {
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

pub fn typeRefForEiwaType(allocator: std.mem.Allocator, t: *const EiwaType) !*const ASTTypeRef {
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
        .Array => |elem_t| {
            const elem_ref = try typeRefForEiwaType(allocator, elem_t);
            const args = try allocator.alloc(*const ASTTypeRef, 1);
            args[0] = elem_ref;
            const ref = try allocator.create(ASTTypeRef);
            ref.* = .{
                .name = "NativeArray",
                .generic_args = args,
                .is_array = false,
                .is_nullable = false,
            };
            return ref;
        },
        .Pointer => |elem_t| {
            if (elem_t.* == .Void) return typeRefSimple("Pointer");
            const elem_ref = try typeRefForEiwaType(allocator, elem_t);
            const args = try allocator.alloc(*const ASTTypeRef, 1);
            args[0] = elem_ref;
            const ref = try allocator.create(ASTTypeRef);
            ref.* = .{
                .name = "Pointer",
                .generic_args = args,
                .is_array = false,
                .is_nullable = false,
            };
            return ref;
        },
        .GenericParam => |gp| return typeRefSimple(gp),
        .Function => |f| {
            var params = ArrayList(*const ASTTypeRef).init(allocator);
            for (f.params) |p| {
                try params.append(try typeRefForEiwaType(allocator, p));
            }
            const ret_ref = try typeRefForEiwaType(allocator, f.return_type);
            const rec_ref = if (f.receiver) |r| try typeRefForEiwaType(allocator, r) else null;
            const ref = try allocator.create(ASTTypeRef);
            ref.* = .{
                .name = "",
                .generic_args = try params.toOwnedSlice(),
                .is_function = true,
                .is_array = false,
                .return_type = ret_ref,
                .receiver_type = rec_ref,
                .is_nullable = false,
            };
            return ref;
        },
        .Unknown => return typeRefSimple("Int"),
    }
}

pub fn typeRefWithArgs(allocator: std.mem.Allocator, name: []const u8, args: []const *const EiwaType) !*const ASTTypeRef {
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

pub fn singleTypeArg(t: *const EiwaType) *const EiwaType {
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

pub fn typeRefSimple(name: []const u8) *const ASTTypeRef {
    const n = std.heap.page_allocator.create(ASTTypeRef) catch unreachable;
    n.* = .{
        .name = name,
        .generic_args = &.{},
        .is_array = false,
        .is_nullable = false,
    };
    return n;
}

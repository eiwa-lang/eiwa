const std = @import("std");
const ast = @import("../ast.zig");
const core = @import("core.zig");
const compat = @import("../compat.zig");

const ArrayList = compat.ArrayList;

const ASTNode = core.ASTNode;
const TypeChecker = core.TypeChecker;
const Scope = core.Scope;
const EiwaType = core.EiwaType;

pub fn inferIfExpr(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    const i = node.data.if_expr;
    const cond_type = try self.inferNode(i.condition, scope);
    if (!core.isBool(cond_type)) {
        self.reportError(node.line, node.column, "TypeError: if condition must be Bool, found {}.", .{cond_type.*});
        return error.TypeError;
    }
    
    var then_scope = scope;
    var local_then_scope: Scope = undefined;
    var has_smart_cast = false;
    
    if (i.condition.data == .is_expr) {
        const is_e = i.condition.data.is_expr;
        if (is_e.is_not == false and is_e.value.data == .identifier) {
            const var_name = is_e.value.data.identifier.name;
            const target_t = try self.resolveTypeRef(is_e.type_ref);
            
            local_then_scope = Scope.init(self.allocator, scope);
            try local_then_scope.define(var_name, target_t, false, false);
            then_scope = &local_then_scope;
            has_smart_cast = true;
        }
    }

    // Value position: explicit flag or a non-Void expectation (call args,
    // annotated slots). An explicit `Void` expectation stays statement-like.
    const need = i.is_value or (node.expected_type != null and node.expected_type.?.* != .Void);
    if (need) {
        markTrailingValue(i.then_branch, true);
        if (i.else_branch) |else_b| markTrailingValue(else_b, true);
    }

    const then_type = try inferBranchAsExpression(self, i.then_branch, then_scope);
    if (has_smart_cast) {
        local_then_scope.deinit();
    }

    if (i.else_branch) |else_b| {
        const else_type = try inferBranchAsExpression(self, else_b, scope);
        if (then_type) |tt| {
            if (else_type) |et| {
                if (node.expected_type) |exp_t| {
                    if (!self.isCompatible(exp_t, tt)) {
                        self.reportError(i.then_branch.line, i.then_branch.column, "TypeError: if branch has type {} which is incompatible with expected type {}.", .{ tt.*, exp_t.* });
                        return error.TypeError;
                    }
                    if (!self.isCompatible(exp_t, et)) {
                        self.reportError(else_b.line, else_b.column, "TypeError: if branch has type {} which is incompatible with expected type {}.", .{ et.*, exp_t.* });
                        return error.TypeError;
                    }
                    t.* = exp_t.*;
                } else if (self.isCompatible(tt, et) or self.isCompatible(et, tt)) {
                    t.* = tt.*;
                } else if (need) {
                    // `if (c) v else null` in value position types as `T?`.
                    const nn = if (tt.* == .Null) et else if (et.* == .Null) tt else null;
                    if (nn) |non_null| {
                        if (non_null.* == .Void) {
                            t.* = .Void;
                        } else if (core.isNullable(non_null)) {
                            t.* = non_null.*;
                        } else {
                            const left_t = try self.allocator.create(EiwaType);
                            left_t.* = non_null.*;
                            const right_t = try self.allocator.create(EiwaType);
                            right_t.* = .Null;
                            t.* = .{ .Union = .{ .left = left_t, .right = right_t } };
                        }
                    } else {
                        t.* = .Void;
                    }
                } else {
                    t.* = .Void;
                }
            } else {
                t.* = tt.*;
            }
        } else if (else_type) |et| {
            t.* = et.*;
        } else {
            t.* = .Void;
        }
    } else {
        if (!need) {
            t.* = .Void;
            return;
        }
        // `if` without `else` in value position is the block short-ternary.
        const tt = then_type orelse {
            t.* = .Void;
            return;
        };
        if (tt.* == .Void) {
            self.reportError(node.line, node.column, "TypeError: if without else in value position cannot yield Void.", .{});
            return error.TypeError;
        }
        if (core.isNullable(tt)) {
            if (node.expected_type) |exp_t| {
                if (!self.isCompatible(exp_t, tt)) {
                    self.reportError(node.line, node.column, "TypeError: if branch has type {} which is incompatible with expected type {}.", .{ tt.*, exp_t.* });
                    return error.TypeError;
                }
            }
            t.* = tt.*;
        } else {
            const left_t = try self.allocator.create(EiwaType);
            left_t.* = tt.*;
            const right_t = try self.allocator.create(EiwaType);
            right_t.* = .Null;
            const nullable = EiwaType{ .Union = .{ .left = left_t, .right = right_t } };
            if (node.expected_type) |exp_t| {
                if (!self.isCompatible(exp_t, &nullable)) {
                    self.reportError(node.line, node.column, "TypeError: if branch has type {} which is incompatible with expected type {}.", .{ nullable, exp_t.* });
                    return error.TypeError;
                }
            }
            t.* = nullable;
        }
    }
}

pub fn inferWhileStmt(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    const w = node.data.while_stmt;
    const cond_type = try self.inferNode(w.condition, scope);
    if (!core.isBool(cond_type)) {
        self.reportError(node.line, node.column, "TypeError: while condition must be Bool, found {}.", .{cond_type.*});
        return error.TypeError;
    }
    var loop_scope = Scope.init(self.allocator, scope);
    loop_scope.is_loop_boundary = true;
    defer loop_scope.deinit();
    _ = try self.inferNode(w.body, &loop_scope);
    t.* = .Void;
}

pub fn inferBreakStmt(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    // The innermost loop/lambda/function boundary wins (Rust-style).
    var curr: ?*const Scope = scope;
    var in_loop = false;
    var in_lambda = false;
    while (curr) |s| {
        if (s.is_loop_boundary) {
            in_loop = true;
            break;
        }
        if (s.is_lambda_boundary) {
            in_lambda = true;
            break;
        }
        if (s.is_function_boundary) {
            break;
        }
        curr = s.parent;
    }
    const b = node.data.break_stmt;
    if (in_loop) {
        // Loop target: the value is only checked here (a collecting `for`
        // appends it at emission); bare break is just Void.
        if (b.value) |v| {
            _ = try self.inferNode(v, scope);
        }
        t.* = .Void;
        return;
    }
    if (in_lambda) {
        // Lambda target: local exit with an optional value (the `return`
        // forbidden by ADR 53). Compatibility with the lambda return type is
        // checked at the end of lambda inference (only flagged nodes).
        var nb = b;
        nb.is_lambda_break = true;
        node.data.break_stmt = nb;
        if (b.value) |v| {
            const vt = try self.inferNode(v, scope);
            t.* = vt.*;
            return;
        }
        t.* = .Void;
        return;
    }
    self.reportError(node.line, node.column, "TypeError: 'leave' is only allowed inside a loop or lambda.", .{});
    return error.TypeError;
}

pub fn inferForStmt(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    const f = node.data.for_stmt;
    var iter_type = try self.inferNode(f.iterable, scope);

    var is_mutable_list = false;
    var is_list = false;
    if (iter_type.* == .GenericInstance) {
        if (std.mem.eql(u8, iter_type.GenericInstance.base_name, "MutableList")) {
            is_mutable_list = true;
        } else if (std.mem.eql(u8, iter_type.GenericInstance.base_name, "List")) {
            is_list = true;
        }
    } else if (iter_type.* == .Custom) {
        if (std.mem.indexOf(u8, iter_type.Custom, "MutableList") != null) {
            is_mutable_list = true;
        } else if (std.mem.indexOf(u8, iter_type.Custom, "List") != null) {
            is_list = true;
        }
    }
    
    if (is_mutable_list) {
        const get_list = try self.allocator.create(ASTNode);
        get_list.* = .{ .line = node.line, .column = node.column, .resolved_type = null, .data = .{ .get_expr = .{ .object = f.iterable, .name = "list", .is_safe = false } } };
        _ = try self.inferNode(get_list, scope);

        const get_items = try self.allocator.create(ASTNode);
        get_items.* = .{ .line = node.line, .column = node.column, .resolved_type = null, .data = .{ .get_expr = .{ .object = get_list, .name = "items", .is_safe = false } } };
        _ = try self.inferNode(get_items, scope);

        node.data.for_stmt.iterable = get_items;
        iter_type = get_items.resolved_type.?;
    } else if (is_list) {
        const get_expr = try self.allocator.create(ASTNode);
        get_expr.* = .{ .line = node.line, .column = node.column, .resolved_type = null, .data = .{ .get_expr = .{ .object = f.iterable, .name = "items", .is_safe = false } } };
        
        _ = try self.inferNode(get_expr, scope);
        
        node.data.for_stmt.iterable = get_expr;
        iter_type = get_expr.resolved_type.?;
    }
    
    if (iter_type.* != .Array) {
        // Value-collecting over Map is not supported yet.
        if (f.collect and mapForKind(iter_type) != null) {
            self.reportError(node.line, node.column, "TypeError: for used as a value over Map is not supported yet.", .{});
            return error.TypeError;
        }
        if (try desugarMapFor(self, node, scope, t, iter_type)) return;
        self.reportError(node.line, node.column, "TypeError: for loop iterable must be an Array, List or Map, found {}.", .{iter_type.*});
        return error.TypeError;
    }

    var for_scope = Scope.init(self.allocator, scope);
    for_scope.is_loop_boundary = true;
    defer for_scope.deinit();

    if (f.index_name) |idx_name| {
        const int_type = try self.allocator.create(EiwaType);
        int_type.* = .Int;
        try for_scope.define(idx_name, int_type, false, false);
    }
    try for_scope.define(f.item_name, iter_type.Array, false, false);

    if (f.collect) {
        try inferForCollect(self, node, &for_scope, t);
        return;
    }

    _ = try self.inferNode(f.body, &for_scope);
    t.* = .Void;
}

/// Infers a value-positioned `for`: the body trailing type gives the
/// collected element (`T` collected, `T?` with null-skip, `Void` rejected).
/// Result is `List<T>`, built exactly like an array literal.
fn inferForCollect(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    const f = node.data.for_stmt;
    // Only the trailing statement yields; earlier ones are effects. Nested
    // value positions mark themselves during inference below.
    markTrailingValue(f.body, true);
    const body_t = try self.inferBlockAsExpression(f.body, scope);
    // A Void (or diverging) body in value position is an error, mirroring
    // the `if`-value Void Safety rule — except against an explicit `Void`
    // expectation, which is statement intent (`val x: Void = for ...`).
    const vt = body_t orelse {
        if (node.expected_type) |exp_t| {
            if (exp_t.* == .Void) {
                node.data.for_stmt.collect = false;
                t.* = .Void;
                return;
            }
        }
        self.reportError(node.line, node.column, "TypeError: for used as a value with a Void body.", .{});
        return error.TypeError;
    };
    if (vt.* == .Void) {
        if (node.expected_type) |exp_t| {
            if (exp_t.* == .Void) {
                node.data.for_stmt.collect = false;
                t.* = .Void;
                return;
            }
        }
        self.reportError(node.line, node.column, "TypeError: for used as a value with a Void body.", .{});
        return error.TypeError;
    }

    // The collected List, built exactly like an array literal so downstream
    // (emitter struct lookup, generic unification) resolves it unchanged.
    const list_t = try self.makeListType(vt, node.line, node.column);
    if (node.expected_type) |exp| {
        if (!self.isCompatible(exp, list_t)) {
            if (core.isNullable(vt)) {
                self.reportError(node.line, node.column, "TypeError: for with null iterations is incompatible with expected {}. Annotate List<T?> to collect nullables.", .{exp.*});
            } else {
                self.reportError(node.line, node.column, "TypeError: for used as a value yields {} but expected {}.", .{ list_t.*, exp.* });
            }
            return error.TypeError;
        }
        t.* = exp.*;
        try checkForBreakValues(self, f.body, vt);
        return;
    }

    t.* = list_t.*;
    try checkForBreakValues(self, f.body, vt);
}

/// Verifies `break v` values inside a collecting `for` body against the
/// iteration type. Stops at nested loop/lambda/function boundaries.
fn checkForBreakValues(self: *TypeChecker, node: *ASTNode, accept: *const EiwaType) anyerror!void {
    switch (node.data) {
        .block => |b| {
            for (b.statements) |s| try checkForBreakValues(self, s, accept);
        },
        .if_expr => |i| {
            try checkForBreakValues(self, i.then_branch, accept);
            if (i.else_branch) |e| try checkForBreakValues(self, e, accept);
        },
        .try_stmt => |ts| {
            try checkForBreakValues(self, ts.body, accept);
            for (ts.catches) |c| try checkForBreakValues(self, c.body, accept);
        },
        .when_expr => |w| {
            for (w.cases) |c| try checkForBreakValues(self, c.body, accept);
        },
        .while_stmt, .for_stmt, .lambda_expr, .fun_decl => {},
        .break_stmt => |b| {
            if (b.value) |v| {
                const bt = v.resolved_type orelse return;
                if (!self.isCompatible(accept, bt) and !self.isCompatible(bt, accept)) {
                    self.reportError(node.line, node.column, "TypeError: leave value type {} is incompatible with for element type {}.", .{ bt.*, accept.* });
                    return error.TypeError;
                }
            }
        },
        else => {},
    }
}

/// Projection of the loop item for map-like iterables (Phase 75).
/// `.map` binds the whole `Node<K, V>`; `.keys`/`.values` bind `.key`/`.value`.
const MapForKind = enum { map, keys, values };

/// Detects `Map`/`MutableMap` (whole entry) and the lazy views
/// `MapKeys`/`MapValues` (key/value projection). Returns null otherwise.
fn mapForKind(iter_type: *const EiwaType) ?MapForKind {
    if (iter_type.* == .GenericInstance) {
        const bn = iter_type.GenericInstance.base_name;
        if (std.mem.eql(u8, bn, "Map") or std.mem.eql(u8, bn, "MutableMap")) return .map;
        if (std.mem.eql(u8, bn, "MapKeys")) return .keys;
        if (std.mem.eql(u8, bn, "MapValues")) return .values;
        return null;
    } else if (iter_type.* == .Custom) {
        const n = iter_type.Custom;
        if (std.mem.indexOf(u8, n, "_MapKeys_") != null) return .keys;
        if (std.mem.indexOf(u8, n, "_MapValues_") != null) return .values;
        if (std.mem.indexOf(u8, n, "_MutableMap_") != null) return .map;
        if (std.mem.indexOf(u8, n, "_Map_") != null) return .map;
        return null;
    }
    return null;
}

fn mkDesugarNode(self: *TypeChecker, line: usize, col: usize, data: ast.ASTNodeType) anyerror!*ASTNode {
    const n = try self.allocator.create(ASTNode);
    n.* = .{ .line = line, .column = col, .resolved_type = null, .data = data };
    return n;
}

fn mkDesugarIdent(self: *TypeChecker, line: usize, col: usize, name: []const u8) anyerror!*ASTNode {
    return try mkDesugarNode(self, line, col, .{ .identifier = .{ .name = name, .resolved_c_name = null } });
}

fn mkDesugarGet(self: *TypeChecker, line: usize, col: usize, object: *ASTNode, name: []const u8) anyerror!*ASTNode {
    return try mkDesugarNode(self, line, col, .{ .get_expr = .{ .object = object, .name = name, .is_safe = false } });
}

/// True when a `for` body has a `break` targeting the `for` itself.
/// Stops at nested loop/lambda/function boundaries.
fn mapForBodyHasBreak(node: *ASTNode) bool {
    switch (node.data) {
        .block => |b| {
            for (b.statements) |s| if (mapForBodyHasBreak(s)) return true;
            return false;
        },
        .if_expr => |i| {
            if (mapForBodyHasBreak(i.then_branch)) return true;
            if (i.else_branch) |e| return mapForBodyHasBreak(e);
            return false;
        },
        .try_stmt => |ts| {
            if (mapForBodyHasBreak(ts.body)) return true;
            for (ts.catches) |c| if (mapForBodyHasBreak(c.body)) return true;
            return false;
        },
        .when_expr => |w| {
            for (w.cases) |c| if (mapForBodyHasBreak(c.body)) return true;
            return false;
        },
        .while_stmt, .for_stmt, .lambda_expr, .fun_decl => return false,
        .break_stmt => return true,
        else => return false,
    }
}

/// Rewrites every `for`-targeting `break` into `{ __brk = true; break }`.
/// Without the flag, the emitter's `br` would only leave the inner
/// chain-walk `while`, and the outer bucket-walk `while` would continue.
fn wrapMapForBreaks(allocator: std.mem.Allocator, node: *ASTNode, brk_name: []const u8) anyerror!void {
    switch (node.data) {
        .block => |b| {
            for (b.statements) |s| try wrapMapForBreaks(allocator, s, brk_name);
        },
        .if_expr => |i| {
            try wrapMapForBreaks(allocator, i.then_branch, brk_name);
            if (i.else_branch) |e| try wrapMapForBreaks(allocator, e, brk_name);
        },
        .try_stmt => |ts| {
            try wrapMapForBreaks(allocator, ts.body, brk_name);
            for (ts.catches) |c| try wrapMapForBreaks(allocator, c.body, brk_name);
        },
        .when_expr => |w| {
            for (w.cases) |c| try wrapMapForBreaks(allocator, c.body, brk_name);
        },
        .while_stmt, .for_stmt, .lambda_expr, .fun_decl => {},
        .break_stmt => |b| {
            const set_flag = try allocator.create(ASTNode);
            set_flag.* = .{ .line = node.line, .column = node.column, .resolved_type = null, .data = .{ .assignment = .{ .name = brk_name, .value = try allocator.create(ASTNode) } } };
            set_flag.data.assignment.value.* = .{ .line = node.line, .column = node.column, .resolved_type = null, .data = .{ .bool_literal = true } };
            const new_brk = try allocator.create(ASTNode);
            new_brk.* = .{ .line = node.line, .column = node.column, .resolved_type = null, .data = .{ .break_stmt = .{ .value = b.value, .is_lambda_break = b.is_lambda_break } } };
            var stmts = try allocator.alloc(*ASTNode, 2);
            stmts[0] = set_flag;
            stmts[1] = new_brk;
            node.data = .{ .block = .{ .statements = stmts } };
        },
        else => {},
    }
}

/// Desugars `for (map)` / `for (map.keys())` / `for (map.values())` into a
/// zero-allocation nested `while` walk over the hash buckets, mirroring the
/// bucket walk in `Set.mut` (`src/std/collections.ei`)
/// The generated tree uses only `while`/`block`/decls the coroutine
/// transform and the LLVM emitter already support (incl. suspend in body),
/// so no emitter or transform changes are needed. Returns true when the
/// iterable was map-like (node rewritten to `.block` and inferred).
fn desugarMapFor(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType, iter_type: *const EiwaType) anyerror!bool {
    const kind = mapForKind(iter_type) orelse return false;
    const f = node.data.for_stmt;
    const line = node.line;
    const col = node.column;

    const buckets_name = try std.fmt.allocPrint(self.allocator, "__for_map_{d}_{d}_buckets", .{ line, col });
    const b_name = try std.fmt.allocPrint(self.allocator, "__for_map_{d}_{d}_b", .{ line, col });
    const i_name = try std.fmt.allocPrint(self.allocator, "__for_map_{d}_{d}_i", .{ line, col });
    const curr_name = try std.fmt.allocPrint(self.allocator, "__for_map_{d}_{d}_curr", .{ line, col });
    const node_name = try std.fmt.allocPrint(self.allocator, "__for_map_{d}_{d}_node", .{ line, col });

    // val __buckets = <iter>.entries.items
    const get_entries = try mkDesugarGet(self, line, col, f.iterable, "entries");
    const get_items = try mkDesugarGet(self, line, col, get_entries, "items");
    const val_buckets = try mkDesugarNode(self, line, col, .{ .var_decl = .{ .is_mut = false, .name = buckets_name, .type_ref = null, .initializer = get_items } });

    // var __b = 0
    const zero_b = try mkDesugarNode(self, line, col, .{ .int_literal = 0 });
    const var_b = try mkDesugarNode(self, line, col, .{ .var_decl = .{ .is_mut = true, .name = b_name, .type_ref = null, .initializer = zero_b } });

    // var __i = 0 (only with `i, entry ->`)
    var var_i: ?*ASTNode = null;
    if (f.index_name != null) {
        const zero_i = try mkDesugarNode(self, line, col, .{ .int_literal = 0 });
        var_i = try mkDesugarNode(self, line, col, .{ .var_decl = .{ .is_mut = true, .name = i_name, .type_ref = null, .initializer = zero_i } });
    }

    // Early-exit flag so `break` also leaves the outer bucket-walk `while`.
    var brk_name: ?[]const u8 = null;
    if (mapForBodyHasBreak(f.body)) {
        brk_name = try std.fmt.allocPrint(self.allocator, "__for_map_{d}_{d}_brk", .{ line, col });
        try wrapMapForBreaks(self.allocator, f.body, brk_name.?);
    }

    // var __curr = __buckets[__b]
    const buckets_ident = try mkDesugarIdent(self, line, col, buckets_name);
    const b_ident_idx = try mkDesugarIdent(self, line, col, b_name);
    const bucket_access = try mkDesugarNode(self, line, col, .{ .index_expr = .{ .object = buckets_ident, .index = b_ident_idx } });
    const var_curr = try mkDesugarNode(self, line, col, .{ .var_decl = .{ .is_mut = true, .name = curr_name, .type_ref = null, .initializer = bucket_access } });

    // val __node = __curr!! (non-null Node; the only `!!` in the expansion,
    // used as a val initializer only — safe across suspend splits).
    // val <item> = __node[.key|.value|<self>]
    const curr_ident_item = try mkDesugarIdent(self, line, col, curr_name);
    const unwrapped = try mkDesugarNode(self, line, col, .{ .unary_expr = .{ .operator = .bang_bang, .operand = curr_ident_item } });
    const val_node = try mkDesugarNode(self, line, col, .{ .var_decl = .{ .is_mut = false, .name = node_name, .type_ref = null, .initializer = unwrapped } });
    const node_ident_item = try mkDesugarIdent(self, line, col, node_name);
    var item_init: *ASTNode = node_ident_item;
    if (kind == .keys) {
        item_init = try mkDesugarGet(self, line, col, node_ident_item, "key");
    } else if (kind == .values) {
        item_init = try mkDesugarGet(self, line, col, node_ident_item, "value");
    }
    const val_item = try mkDesugarNode(self, line, col, .{ .var_decl = .{ .is_mut = false, .name = f.item_name, .type_ref = null, .initializer = item_init } });

    // [val <index> = __i] + [...body...] + [__i = __i + 1] + [__curr = __node.next]
    // NOTE: the advance reads `.next` off the non-null `__node` val, never a
    // get on a `!!` result: `curr!!.next` mis-infers when re-checked inside a
    // resumed coroutine state (boxed nullable var).
    var inner = ArrayList(*ASTNode).init(self.allocator);
    try inner.append(val_node);
    try inner.append(val_item);
    if (f.index_name) |idx_name| {
        const i_ident = try mkDesugarIdent(self, line, col, i_name);
        const val_idx = try mkDesugarNode(self, line, col, .{ .var_decl = .{ .is_mut = false, .name = idx_name, .type_ref = null, .initializer = i_ident } });
        try inner.append(val_idx);
    }
    if (f.body.data == .block) {
        for (f.body.data.block.statements) |stmt| try inner.append(stmt);
    } else {
        try inner.append(f.body);
    }
    if (f.index_name != null) {
        const i_lhs = try mkDesugarIdent(self, line, col, i_name);
        const one = try mkDesugarNode(self, line, col, .{ .int_literal = 1 });
        const incr = try mkDesugarNode(self, line, col, .{ .binary_expr = .{ .left = i_lhs, .op = .plus, .right = one } });
        const incr_i = try mkDesugarNode(self, line, col, .{ .assignment = .{ .name = i_name, .value = incr } });
        try inner.append(incr_i);
    }
    const curr_ident_next = try mkDesugarIdent(self, line, col, node_name);
    const get_next = try mkDesugarGet(self, line, col, curr_ident_next, "next");
    const advance_curr = try mkDesugarNode(self, line, col, .{ .assignment = .{ .name = curr_name, .value = get_next } });
    try inner.append(advance_curr);

    const inner_body = try mkDesugarNode(self, line, col, .{ .block = .{ .statements = try inner.toOwnedSlice() } });
    const curr_ident_cond = try mkDesugarIdent(self, line, col, curr_name);
    const null_lit = try mkDesugarNode(self, line, col, .{ .null_literal = {} });
    const curr_cond = try mkDesugarNode(self, line, col, .{ .binary_expr = .{ .left = curr_ident_cond, .op = .bang_eq, .right = null_lit } });
    const inner_while = try mkDesugarNode(self, line, col, .{ .while_stmt = .{ .condition = curr_cond, .body = inner_body } });

    var outer_body_list = ArrayList(*ASTNode).init(self.allocator);
    try outer_body_list.append(var_curr);
    try outer_body_list.append(inner_while);

    // __b = __b + 1
    const b_ident_incr = try mkDesugarIdent(self, line, col, b_name);
    const one_b = try mkDesugarNode(self, line, col, .{ .int_literal = 1 });
    const incr_b_expr = try mkDesugarNode(self, line, col, .{ .binary_expr = .{ .left = b_ident_incr, .op = .plus, .right = one_b } });
    const incr_b = try mkDesugarNode(self, line, col, .{ .assignment = .{ .name = b_name, .value = incr_b_expr } });
    try outer_body_list.append(incr_b);
    const outer_body = try mkDesugarNode(self, line, col, .{ .block = .{ .statements = try outer_body_list.toOwnedSlice() } });

    // while (__b < __buckets.length [&& !__brk]) { ... }
    const b_ident_cond = try mkDesugarIdent(self, line, col, b_name);
    const buckets_ident_len = try mkDesugarIdent(self, line, col, buckets_name);
    const get_len = try mkDesugarGet(self, line, col, buckets_ident_len, "length");
    const len_cond = try mkDesugarNode(self, line, col, .{ .binary_expr = .{ .left = b_ident_cond, .op = .less, .right = get_len } });
    var outer_cond: *ASTNode = len_cond;
    if (brk_name) |bn| {
        const brk_ident = try mkDesugarIdent(self, line, col, bn);
        const not_brk = try mkDesugarNode(self, line, col, .{ .unary_expr = .{ .operator = .bang, .operand = brk_ident } });
        outer_cond = try mkDesugarNode(self, line, col, .{ .binary_expr = .{ .left = len_cond, .op = .and_and, .right = not_brk } });
    }
    const outer_while = try mkDesugarNode(self, line, col, .{ .while_stmt = .{ .condition = outer_cond, .body = outer_body } });

    var outer = ArrayList(*ASTNode).init(self.allocator);
    try outer.append(val_buckets);
    try outer.append(var_b);
    if (var_i) |vi| try outer.append(vi);
    if (brk_name) |bn| {
        const false_lit = try mkDesugarNode(self, line, col, .{ .bool_literal = false });
        const var_brk = try mkDesugarNode(self, line, col, .{ .var_decl = .{ .is_mut = true, .name = bn, .type_ref = null, .initializer = false_lit } });
        try outer.append(var_brk);
    }
    try outer.append(outer_while);
    const stmts = try outer.toOwnedSlice();

    node.data = .{ .block = .{ .statements = stmts } };
    const bt = try self.checkBlock(stmts, scope);
    t.* = bt.*;
    return true;
}

pub fn inferReturnStmt(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    var curr: ?*const Scope = scope;
    var inside_lambda = false;
    while (curr) |s| {
        if (s.is_lambda_boundary) {
            inside_lambda = true;
            break;
        }
        if (s.is_function_boundary) {
            break;
        }
        curr = s.parent;
    }
    if (inside_lambda) {
        self.reportError(node.line, node.column, "TypeError: 'return' is not allowed inside a lambda or task block. Use the trailing expression to return a value.", .{});
        return error.TypeError;
    }

    const r = node.data.return_stmt;
    if (r.value) |v| {
        markTrailingValue(v, true);
        const ret_type = try self.inferNode(v, scope);
        t.* = ret_type.*;
        // A value returned from a non-Void function must match the declared
        // return type (Void declarations keep legacy behavior: the value is
        // discarded by the backend, e.g. synthetic `funPointer` trampolines).
        if (self.current_fn_return) |decl| {
            if (decl.* != .Void and !self.isCompatible(decl, ret_type)) {
                self.reportError(node.line, node.column, "TypeError: Expected {} but found {} in return statement.", .{ decl.*, ret_type.* });
                return error.TypeError;
            }
        }
        return;
    }
    t.* = .Void;
    if (self.current_fn_return) |decl| {
        if (decl.* != .Void) {
            self.reportError(node.line, node.column, "TypeError: Missing return value in function with return type {}.", .{decl.*});
            return error.TypeError;
        }
    }
}

/// Verifies lambda-targeting `break`s against the lambda return type:
/// valued breaks must be compatible, bare breaks require a `Void` lambda.
pub fn checkLambdaBreaks(self: *TypeChecker, stmts: []const *ASTNode, body_type: *const EiwaType) anyerror!void {
    for (stmts) |stmt| {
        try checkLambdaBreakNode(self, stmt, body_type);
    }
}

fn checkLambdaBreakNode(self: *TypeChecker, node: *ASTNode, body_type: *const EiwaType) anyerror!void {
    switch (node.data) {
        .block => |b| {
            for (b.statements) |s| try checkLambdaBreakNode(self, s, body_type);
        },
        .if_expr => |i| {
            try checkLambdaBreakNode(self, i.then_branch, body_type);
            if (i.else_branch) |e| try checkLambdaBreakNode(self, e, body_type);
        },
        .try_stmt => |ts| {
            try checkLambdaBreakNode(self, ts.body, body_type);
            for (ts.catches) |c| try checkLambdaBreakNode(self, c.body, body_type);
        },
        .when_expr => |w| {
            for (w.cases) |c| try checkLambdaBreakNode(self, c.body, body_type);
        },
        .while_stmt, .for_stmt, .lambda_expr, .fun_decl => {},
        .break_stmt => |b| {
            if (!b.is_lambda_break) return;
            if (b.value) |v| {
                const vt = v.resolved_type orelse return;
                if (!self.isCompatible(body_type, vt) and !self.isCompatible(vt, body_type)) {
                    self.reportError(node.line, node.column, "TypeError: leave value type {} is incompatible with lambda return type {}.", .{ vt.*, body_type.* });
                    return error.TypeError;
                }
            } else {
                if (body_type.* != .Void) {
                    self.reportError(node.line, node.column, "TypeError: bare 'leave' in lambda requires a Void lambda; use 'leave value' to return a value.", .{});
                    return error.TypeError;
                }
            }
        },
        else => {},
    }
}

/// Marks a trailing `for`/`if`/`when`/`try` as value-positioned: `for`
/// collects, `if`/`when` propagate to their own branches, bare `try` yields
/// `T?`. Applied to a block's last statement, or directly to a bare node.
pub fn markTrailingValue(node: *ASTNode, need: bool) void {
    switch (node.data) {
        .for_stmt => |*f| f.collect = need,
        .if_expr => |*i| i.is_value = need,
        .when_expr => |*w| w.is_value = need,
        .try_stmt => |*t| {
            t.is_value = need;
            if (need) {
                markTrailingValue(t.body, true);
                for (t.catches) |c| markTrailingValue(c.body, true);
            }
        },
        .block => |b| {
            if (b.statements.len > 0) markTrailingValue(b.statements[b.statements.len - 1], need);
        },
        else => {},
    }
}

pub fn checkBlock(self: *TypeChecker, block: []const *ASTNode, parent_scope: *Scope) anyerror!*const EiwaType {
    var local_scope = Scope.init(self.allocator, parent_scope);
    defer local_scope.deinit();

    for (block) |stmt| {
        _ = try self.inferNode(stmt, &local_scope);
    }

    const t = try self.allocator.create(EiwaType);
    t.* = .Void;
    return t;
}

/// Definite-return analysis for block-bodied functions with a declared return type
pub fn bodyGuaranteesReturn(node: *ASTNode) bool {
    if (node.data != .block) return stmtGuaranteesReturn(node);
    const stmts = node.data.block.statements;
    if (stmts.len == 0) return false;
    return stmtGuaranteesReturn(stmts[stmts.len - 1]);
}

fn stmtGuaranteesReturn(node: *ASTNode) bool {
    switch (node.data) {
        .return_stmt => return true,
        .throw_stmt => return true,
        .block => |b| {
            if (b.statements.len == 0) return false;
            return stmtGuaranteesReturn(b.statements[b.statements.len - 1]);
        },
        .if_expr => |i| {
            const e = i.else_branch orelse return false;
            return stmtGuaranteesReturn(i.then_branch) and stmtGuaranteesReturn(e);
        },
        .when_expr => |w| {
            var has_else = false;
            for (w.cases) |c| {
                if (c.is_else) has_else = true;
                if (!stmtGuaranteesReturn(c.body)) return false;
            }
            return has_else;
        },
        .try_stmt => |t| {
            // Normal completion follows the body; exceptional completion
            // follows a catch (or propagates when uncaught, which also never
            // falls through). Zero catches is vacuously covered.
            if (!stmtGuaranteesReturn(t.body)) return false;
            for (t.catches) |c| {
                if (!stmtGuaranteesReturn(c.body)) return false;
            }
            return true;
        },
        else => return false,
    }
}

pub fn inferBranchAsExpression(self: *TypeChecker, branch: *ASTNode, scope: *Scope) anyerror!?*const EiwaType {
    if (branch.data != .block) return try self.inferNode(branch, scope);
    return try inferBlockAsExpression(self, branch, scope);
}

pub fn inferBlockAsExpression(self: *TypeChecker, block_node: *ASTNode, scope: *Scope) anyerror!?*const EiwaType {
    const b = block_node.data.block;
    var local_scope = Scope.init(self.allocator, scope);
    defer local_scope.deinit();

    var last: ?*ASTNode = null;
    var last_type: ?*const EiwaType = null;
    for (b.statements) |stmt| {
        last = stmt;
        last_type = try self.inferNode(stmt, &local_scope);
    }

    const t = try self.allocator.create(EiwaType);
    if (last) |l| {
        if (l.data == .return_stmt or l.data == .throw_stmt) {
            t.* = .Void;
            block_node.resolved_type = t;
            return null;
        }
    }
    if (last_type) |lt| {
        t.* = lt.*;
    } else {
        t.* = .Void;
    }
    block_node.resolved_type = t;
    return t;
}

pub fn inferThrowStmt(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    const expr = node.data.throw_stmt.expr;
    const expr_type = try self.inferNode(expr, scope);

    const throwable_type = self.resolveTypeName("Throwable", false) catch {
        self.reportError(node.line, node.column, "TypeError: Contract 'Throwable' must be declared in std.core.", .{});
        return error.TypeError;
    };

    const expr_base = core.extractBaseType(expr_type);
    var conforms = false;
    if (expr_base.* == .Custom) {
        const throwable_base = core.extractBaseType(throwable_type);
        conforms = self.conformsTo(expr_base.Custom, throwable_base.Custom);
    }
    if (!conforms) {
        self.reportError(node.line, node.column, "TypeError: Can only throw values of types implementing the 'Throwable' contract, found {}.", .{expr_type.*});
        return error.TypeError;
    }

    t.* = .Void;
}

/// `Null` absorbs into a nullable; otherwise identical or incompatible.
fn unifyTryCatchBranch(self: *TypeChecker, a: *const EiwaType, b: *const EiwaType) anyerror!?*const EiwaType {
    if (a.* == .Null) return try nullableTryBranch(self, b);
    if (b.* == .Null) return try nullableTryBranch(self, a);
    if (self.isCompatible(a, b) and self.isCompatible(b, a)) return a;
    return null;
}

fn nullableTryBranch(self: *TypeChecker, t: *const EiwaType) anyerror!*const EiwaType {
    if (core.isNullable(t)) return t;
    const left_t = try self.allocator.create(EiwaType);
    left_t.* = t.*;
    const right_t = try self.allocator.create(EiwaType);
    right_t.* = .Null;
    const wrapped = try self.allocator.create(EiwaType);
    wrapped.* = .{ .Union = .{ .left = left_t, .right = right_t } };
    return wrapped;
}

fn prepareCatchScope(self: *TypeChecker, node: *ASTNode, c: ast.CatchBlock, catch_scope: *Scope) anyerror!void {
    const throwable_type = self.resolveTypeName("Throwable", false) catch {
        self.reportError(node.line, node.column, "TypeError: Contract 'Throwable' must be declared in std.core.", .{});
        return error.TypeError;
    };
    const throwable_base = core.extractBaseType(throwable_type);

    if (c.var_name) |var_name| {
        var var_type: *const EiwaType = throwable_type;
        if (c.types.len == 1) {
            var_type = try self.resolveTypeRef(c.types[0]);
        }
        try catch_scope.define(var_name, var_type, false, false);

        for (c.types) |tr| {
            const target_t = try self.resolveTypeRef(tr);
            const target_base = core.extractBaseType(target_t);
            if (target_base.* == .Custom) {
                const is_contract = self.contracts_ast.contains(target_base.Custom);
                if (!is_contract and !self.conformsTo(target_base.Custom, throwable_base.Custom)) {
                    self.reportError(node.line, node.column, "TypeError: Catch block type must be a contract or a type implementing 'Throwable', found {}.", .{target_t.*});
                    return error.TypeError;
                }
            }
        }
    }
}

pub fn inferTryStmt(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    const ts = node.data.try_stmt;
    // Value position: explicit flag or a non-Void expectation (annotated
    // slots, `return`). An explicit `Void` expectation stays statement-like.
    const need = ts.is_value or (node.expected_type != null and node.expected_type.?.* != .Void);
    if (!need) {
        _ = try self.inferNode(ts.body, scope);

        for (ts.catches) |c| {
            var catch_scope = Scope.init(self.allocator, scope);
            defer catch_scope.deinit();
            try prepareCatchScope(self, node, c, &catch_scope);

            _ = try self.inferNode(c.body, &catch_scope);
        }

        t.* = .Void;
        return;
    }

    // Value try/catch: infer body and catches, then unify.
    markTrailingValue(ts.body, true);
    var unified: ?*const EiwaType = null;
    if (try inferBlockAsExpression(self, ts.body, scope)) |bt| {
        if (bt.* == .Void) {
            self.reportError(node.line, node.column, "TypeError: try/catch in value position cannot yield Void.", .{});
            return error.TypeError;
        }
        unified = bt;
    }
    for (ts.catches) |c| {
        var catch_scope = Scope.init(self.allocator, scope);
        defer catch_scope.deinit();
        try prepareCatchScope(self, node, c, &catch_scope);

        markTrailingValue(c.body, true);
        if (try inferBlockAsExpression(self, c.body, &catch_scope)) |ct| {
            if (ct.* == .Void) {
                self.reportError(node.line, node.column, "TypeError: try/catch in value position cannot yield Void.", .{});
                return error.TypeError;
            }
            if (unified) |u| {
                unified = try unifyTryCatchBranch(self, u, ct) orelse {
                    self.reportError(node.line, node.column, "TypeError: try/catch branches have incompatible types {} and {}.", .{ u.*, ct.* });
                    return error.TypeError;
                };
            } else {
                unified = ct;
            }
        }
    }
    var final = unified orelse {
        self.reportError(node.line, node.column, "TypeError: try/catch in value position cannot yield Void.", .{});
        return error.TypeError;
    };
    if (ts.catches.len == 0) {
        // Bare `try`: the exception path yields null → nullable wrap with
        // flattening. With catches, unmatched exceptions rethrow.
        final = try nullableTryBranch(self, final);
    }
    if (node.expected_type) |exp_t| {
        if (!self.isCompatible(exp_t, final)) {
            self.reportError(node.line, node.column, "TypeError: try/catch has type {} which is incompatible with expected type {}.", .{ final.*, exp_t.* });
            return error.TypeError;
        }
    }
    t.* = final.*;
}

// ---------------------------------------------------------------------------
// Definite-return analysis (`bodyGuaranteesReturn`) regression guard.
//
// A block-bodied function with a declared non-Void return type must execute
// `return`/`throw` on every path — otherwise the backend emits a zero/null
// placeholder that surfaces as a NullPointerException (or a silent wrong
// value) far from the bug. Pure AST tests, no stdlib required.
// ---------------------------------------------------------------------------

/// Minimal AST constructors shared with `infer_decl` regression tests.
pub fn mkBlock(slot: *ASTNode, stmts: []const *ASTNode) *ASTNode {
    slot.* = .{ .line = 1, .column = 1, .data = .{ .block = .{ .statements = stmts } } };
    return slot;
}

pub fn mkRet(slot: *ASTNode, value: ?*ASTNode) *ASTNode {
    slot.* = .{ .line = 1, .column = 1, .data = .{ .return_stmt = .{ .value = value } } };
    return slot;
}

pub fn mkIntLit(slot: *ASTNode) *ASTNode {
    slot.* = .{ .line = 1, .column = 1, .data = .{ .int_literal = 1 } };
    return slot;
}

test "guarantee: empty body and trailing values never return" {
    const testing = std.testing;
    var empty_slot: ASTNode = undefined;
    try testing.expect(!bodyGuaranteesReturn(mkBlock(&empty_slot, &[_]*ASTNode{})));

    // A trailing expression is NOT an implicit return (Kotlin-style: block
    // bodies require explicit `return`).
    var lit_slot: ASTNode = undefined;
    const lit = mkIntLit(&lit_slot);
    var trail_slot: ASTNode = undefined;
    const trail_stmts = [_]*ASTNode{lit};
    try testing.expect(!bodyGuaranteesReturn(mkBlock(&trail_slot, &trail_stmts)));
}

test "guarantee: return and throw terminate" {
    const testing = std.testing;
    var lit_slot: ASTNode = undefined;
    const lit = mkIntLit(&lit_slot);

    var ret_slot: ASTNode = undefined;
    const ret_stmts = [_]*ASTNode{mkRet(&ret_slot, lit)};
    var ret_blk_slot: ASTNode = undefined;
    try testing.expect(bodyGuaranteesReturn(mkBlock(&ret_blk_slot, &ret_stmts)));

    var bare_slot: ASTNode = undefined;
    const bare_stmts = [_]*ASTNode{mkRet(&bare_slot, null)};
    var bare_blk_slot: ASTNode = undefined;
    // Terminates control flow (missing-value arity is checked elsewhere).
    try testing.expect(bodyGuaranteesReturn(mkBlock(&bare_blk_slot, &bare_stmts)));

    var thr_slot: ASTNode = undefined;
    thr_slot = .{ .line = 1, .column = 1, .data = .{ .throw_stmt = .{ .expr = lit } } };
    const thr_stmts = [_]*ASTNode{&thr_slot};
    var thr_blk_slot: ASTNode = undefined;
    try testing.expect(bodyGuaranteesReturn(mkBlock(&thr_blk_slot, &thr_stmts)));
}

test "guarantee: if needs else with both sides returning" {
    const testing = std.testing;
    var cond_slot: ASTNode = undefined;
    cond_slot = .{ .line = 1, .column = 1, .data = .{ .bool_literal = true } };
    var lit_slot: ASTNode = undefined;
    const lit = mkIntLit(&lit_slot);

    var then_ret_slot: ASTNode = undefined;
    const then_ret_stmts = [_]*ASTNode{mkRet(&then_ret_slot, lit)};
    var then_slot: ASTNode = undefined;
    const then_blk = mkBlock(&then_slot, &then_ret_stmts);
    var else_ret_slot: ASTNode = undefined;
    const else_ret_stmts = [_]*ASTNode{mkRet(&else_ret_slot, lit)};
    var else_slot: ASTNode = undefined;
    const else_blk = mkBlock(&else_slot, &else_ret_stmts);

    var both_slot: ASTNode = undefined;
    both_slot = .{ .line = 1, .column = 1, .data = .{ .if_expr = .{ .condition = &cond_slot, .then_branch = then_blk, .else_branch = else_blk } } };
    try testing.expect(stmtGuaranteesReturn(&both_slot));

    var no_else_slot: ASTNode = undefined;
    no_else_slot = .{ .line = 1, .column = 1, .data = .{ .if_expr = .{ .condition = &cond_slot, .then_branch = then_blk, .else_branch = null } } };
    try testing.expect(!stmtGuaranteesReturn(&no_else_slot));

    var else_expr_slot: ASTNode = undefined;
    else_expr_slot = .{ .line = 1, .column = 1, .data = .{ .if_expr = .{ .condition = &cond_slot, .then_branch = then_blk, .else_branch = lit } } };
    try testing.expect(!stmtGuaranteesReturn(&else_expr_slot));
}

test "guarantee: when needs else with every case returning" {
    const testing = std.testing;
    var lit_slot: ASTNode = undefined;
    const lit = mkIntLit(&lit_slot);
    var ret_slot: ASTNode = undefined;
    const ret_stmts = [_]*ASTNode{mkRet(&ret_slot, lit)};
    var body_slot: ASTNode = undefined;
    const body_blk = mkBlock(&body_slot, &ret_stmts);

    const full_cases = [_]ast.WhenCase{
        .{ .conds = &[_]*ASTNode{}, .body = body_blk, .is_else = false },
        .{ .conds = &[_]*ASTNode{}, .body = body_blk, .is_else = true },
    };
    var full_slot: ASTNode = undefined;
    full_slot = .{ .line = 1, .column = 1, .data = .{ .when_expr = .{ .subject = null, .cases = &full_cases } } };
    try testing.expect(stmtGuaranteesReturn(&full_slot));

    const no_else_cases = [_]ast.WhenCase{
        .{ .conds = &[_]*ASTNode{}, .body = body_blk, .is_else = false },
    };
    var no_else_slot: ASTNode = undefined;
    no_else_slot = .{ .line = 1, .column = 1, .data = .{ .when_expr = .{ .subject = null, .cases = &no_else_cases } } };
    try testing.expect(!stmtGuaranteesReturn(&no_else_slot));

    const hole_cases = [_]ast.WhenCase{
        .{ .conds = &[_]*ASTNode{}, .body = lit, .is_else = false },
        .{ .conds = &[_]*ASTNode{}, .body = body_blk, .is_else = true },
    };
    var hole_slot: ASTNode = undefined;
    hole_slot = .{ .line = 1, .column = 1, .data = .{ .when_expr = .{ .subject = null, .cases = &hole_cases } } };
    try testing.expect(!stmtGuaranteesReturn(&hole_slot));
}

test "guarantee: try needs body and every catch returning" {
    const testing = std.testing;
    var lit_slot: ASTNode = undefined;
    const lit = mkIntLit(&lit_slot);
    var ret_slot: ASTNode = undefined;
    const ret_stmts = [_]*ASTNode{mkRet(&ret_slot, lit)};
    var body_slot: ASTNode = undefined;
    const body_blk = mkBlock(&body_slot, &ret_stmts);
    var catch_ret_slot: ASTNode = undefined;
    const catch_ret_stmts = [_]*ASTNode{mkRet(&catch_ret_slot, lit)};
    var catch_body_slot: ASTNode = undefined;
    const catch_blk = mkBlock(&catch_body_slot, &catch_ret_stmts);

    const catches = [_]ast.CatchBlock{
        .{ .var_name = null, .types = &[_]*const ast.ASTTypeRef{}, .body = catch_blk },
    };
    var full_slot: ASTNode = undefined;
    full_slot = .{ .line = 1, .column = 1, .data = .{ .try_stmt = .{ .body = body_blk, .catches = &catches } } };
    try testing.expect(stmtGuaranteesReturn(&full_slot));

    // Bare `try` whose body returns: normal completion is the body's
    // (return), exceptional completion propagates — never falls through.
    var bare_slot: ASTNode = undefined;
    bare_slot = .{ .line = 1, .column = 1, .data = .{ .try_stmt = .{ .body = body_blk, .catches = &[_]ast.CatchBlock{} } } };
    try testing.expect(stmtGuaranteesReturn(&bare_slot));

    var expr_body_slot: ASTNode = undefined;
    const expr_stmts = [_]*ASTNode{lit};
    const expr_blk = mkBlock(&expr_body_slot, &expr_stmts);
    var expr_slot: ASTNode = undefined;
    expr_slot = .{ .line = 1, .column = 1, .data = .{ .try_stmt = .{ .body = expr_blk, .catches = &catches } } };
    try testing.expect(!stmtGuaranteesReturn(&expr_slot));
}

test "guarantee: loops, lambdas and nested functions never guarantee" {
    const testing = std.testing;
    var lit_slot: ASTNode = undefined;
    const lit = mkIntLit(&lit_slot);
    var ret_slot: ASTNode = undefined;
    const ret_stmts = [_]*ASTNode{mkRet(&ret_slot, lit)};
    var blk_slot: ASTNode = undefined;
    const blk = mkBlock(&blk_slot, &ret_stmts);
    var cond_slot: ASTNode = undefined;
    cond_slot = .{ .line = 1, .column = 1, .data = .{ .bool_literal = true } };

    // A `return` only inside a loop body does not guarantee (may not run).
    var while_slot: ASTNode = undefined;
    while_slot = .{ .line = 1, .column = 1, .data = .{ .while_stmt = .{ .condition = &cond_slot, .body = blk } } };
    try testing.expect(!stmtGuaranteesReturn(&while_slot));

    var for_slot: ASTNode = undefined;
    for_slot = .{ .line = 1, .column = 1, .data = .{ .for_stmt = .{ .item_name = "x", .iterable = lit, .body = blk } } };
    try testing.expect(!stmtGuaranteesReturn(&for_slot));

    // Lambda bodies are boundaries: their trailing value is the lambda's,
    // not the enclosing function's.
    var lam_ret_slot: ASTNode = undefined;
    const lam_stmts = [_]*ASTNode{mkRet(&lam_ret_slot, lit)};
    var lam_slot: ASTNode = undefined;
    lam_slot = .{ .line = 1, .column = 1, .data = .{ .lambda_expr = .{ .params = &[_]ast.Param{}, .body = &lam_stmts } } };
    try testing.expect(!stmtGuaranteesReturn(&lam_slot));

    var nested_slot: ASTNode = undefined;
    nested_slot = .{ .line = 1, .column = 1, .data = .{ .fun_decl = .{
        .annotations = &[_]ast.Annotation{},
        .modifiers = &[_]ast.TokenType{},
        .name = "inner",
        .generic_params = &[_][]const u8{},
        .params = &[_]ast.Param{},
        .type_ref = null,
        .body = blk,
        .is_expr_body = false,
        .resolved_c_name = null,
    } } };
    try testing.expect(!stmtGuaranteesReturn(&nested_slot));
}


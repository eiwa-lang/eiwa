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
        t.* = .Void;
    }
}

pub fn inferWhileStmt(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    const w = node.data.while_stmt;
    const cond_type = try self.inferNode(w.condition, scope);
    if (!core.isBool(cond_type)) {
        self.reportError(node.line, node.column, "TypeError: while condition must be Bool, found {}.", .{cond_type.*});
        return error.TypeError;
    }
    _ = try self.inferNode(w.body, scope);
    t.* = .Void;
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
        if (try desugarMapFor(self, node, scope, t, iter_type)) return;
        self.reportError(node.line, node.column, "TypeError: for loop iterable must be an Array, List or Map, found {}.", .{iter_type.*});
        return error.TypeError;
    }
    
    var for_scope = Scope.init(self.allocator, scope);
    defer for_scope.deinit();
    
    if (f.index_name) |idx_name| {
        const int_type = try self.allocator.create(EiwaType);
        int_type.* = .Int;
        try for_scope.define(idx_name, int_type, false, false);
    }
    try for_scope.define(f.item_name, iter_type.Array, false, false);
    
    _ = try self.inferNode(f.body, &for_scope);
    t.* = .Void;
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

    // while (__b < __buckets.length) { ... }
    const b_ident_cond = try mkDesugarIdent(self, line, col, b_name);
    const buckets_ident_len = try mkDesugarIdent(self, line, col, buckets_name);
    const get_len = try mkDesugarGet(self, line, col, buckets_ident_len, "length");
    const outer_cond = try mkDesugarNode(self, line, col, .{ .binary_expr = .{ .left = b_ident_cond, .op = .less, .right = get_len } });
    const outer_while = try mkDesugarNode(self, line, col, .{ .while_stmt = .{ .condition = outer_cond, .body = outer_body } });

    var outer = ArrayList(*ASTNode).init(self.allocator);
    try outer.append(val_buckets);
    try outer.append(var_b);
    if (var_i) |vi| try outer.append(vi);
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
        const ret_type = try self.inferNode(v, scope);
        t.* = ret_type.*;
        return;
    }
    t.* = .Void;
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

pub fn inferTryStmt(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    const ts = node.data.try_stmt;
    _ = try self.inferNode(ts.body, scope);

    const throwable_type = self.resolveTypeName("Throwable", false) catch {
        self.reportError(node.line, node.column, "TypeError: Contract 'Throwable' must be declared in std.core.", .{});
        return error.TypeError;
    };
    const throwable_base = core.extractBaseType(throwable_type);

    for (ts.catches) |c| {
        var catch_scope = Scope.init(self.allocator, scope);
        defer catch_scope.deinit();

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

        _ = try self.inferNode(c.body, &catch_scope);
    }

    t.* = .Void;
}


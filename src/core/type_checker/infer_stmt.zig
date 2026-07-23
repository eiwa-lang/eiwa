const std = @import("std");
const ast = @import("../ast.zig");
const core = @import("core.zig");

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

    const then_type = try self.inferNode(i.then_branch, then_scope);
    if (has_smart_cast) {
        local_then_scope.deinit();
    }

    if (i.else_branch) |else_b| {
        const else_type = try self.inferNode(else_b, scope);
        if (!self.isCompatible(then_type, else_type) and !self.isCompatible(else_type, then_type)) {
            self.reportError(node.line, node.column, "TypeError: if branches have incompatible types: {} and {}.", .{ then_type.*, else_type.* });
            return error.TypeError;
        }
        t.* = then_type.*;
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
    
    var is_list = false;
    if (iter_type.* == .GenericInstance and (std.mem.eql(u8, iter_type.GenericInstance.base_name, "List") or std.mem.eql(u8, iter_type.GenericInstance.base_name, "MutableList"))) {
        is_list = true;
    } else if (iter_type.* == .Custom) {
        if (std.mem.indexOf(u8, iter_type.Custom, "List") != null) {
            is_list = true;
        }
    }
    
    if (is_list) {
        const get_expr = try self.allocator.create(ASTNode);
        get_expr.* = .{ .line = node.line, .column = node.column, .resolved_type = null, .data = .{ .get_expr = .{ .object = f.iterable, .name = "items", .is_safe = false } } };
        
        _ = try self.inferNode(get_expr, scope);
        
        node.data.for_stmt.iterable = get_expr;
        iter_type = get_expr.resolved_type.?;
    }
    
    if (iter_type.* != .Array) {
        self.reportError(node.line, node.column, "TypeError: for loop iterable must be an Array or List, found {}.", .{iter_type.*});
        return error.TypeError;
    }
    
    var for_scope = Scope.init(self.allocator, scope);
    defer for_scope.deinit();
    
    try for_scope.define(f.item_name, iter_type.Array, false, false);
    
    _ = try self.inferNode(f.body, &for_scope);
    t.* = .Void;
}

pub fn inferReturnStmt(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
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


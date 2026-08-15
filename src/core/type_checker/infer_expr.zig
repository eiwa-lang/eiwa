const std = @import("std");
const compat = @import("../compat.zig");
const ArrayList = compat.ArrayList;
const ast = @import("../ast.zig");
const core = @import("core.zig");
const type_system = @import("../type_system.zig");

const ASTNode = core.ASTNode;
const TypeChecker = core.TypeChecker;
const Scope = core.Scope;
const EiwaType = core.EiwaType;
const extractBaseType = core.extractBaseType;
const isNullable = core.isNullable;

pub const inferCallExpr = @import("infer_call.zig").inferCallExpr;
pub const inferGetExpr = @import("infer_member.zig").inferGetExpr;
pub const inferSetExpr = @import("infer_member.zig").inferSetExpr;
pub const inferIndexExpr = @import("infer_member.zig").inferIndexExpr;
pub const inferIndexSetExpr = @import("infer_member.zig").inferIndexSetExpr;
pub const inferArrayLiteral = @import("infer_literal.zig").inferArrayLiteral;
pub const inferMapLiteral = @import("infer_literal.zig").inferMapLiteral;


fn isValidType(self: *TypeChecker, t: *const EiwaType) bool {
    switch (t.*) {
        .Int, .Bool, .String, .Void, .Null => return true,
        .Pointer => |elem| return isValidType(self, elem),
        .Array => |elem| return isValidType(self, elem),
        .Custom => |name| {
            var actual_name = name;
            if (std.mem.endsWith(u8, actual_name, "Opt")) {
                actual_name = actual_name[0 .. actual_name.len - 3];
            }
            return self.classes_ast.contains(actual_name) or self.global_scope.lookupVariable(actual_name) != null;
        },
        .Union => |u| return isValidType(self, u.left) and isValidType(self, u.right),
        else => return false,
    }
}

pub fn inferAssignment(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    const a = &node.data.assignment;
    var assigned_type: *const EiwaType = undefined;
    if (scope.lookupVariableSymbol(a.name)) |vs| {
        a.value.expected_type = vs.eiwa_type;
        a.value.resolved_type = null;
        assigned_type = try self.inferNode(a.value, scope);
        if (!vs.is_mut) {
            self.reportError(node.line, node.column, "TypeError: Cannot reassign constant variable '{s}'.", .{a.name});
            return error.TypeError;
        }
        const expected = vs.eiwa_type;
        if (!self.isCompatible(expected, assigned_type)) {
            self.reportError(node.line, node.column, "TypeError: Expected {} but found {} when reassigning variable '{s}'.", .{ expected.*, assigned_type.*, a.name });
            return error.TypeError;
        }
        a.is_boxed = vs.is_boxed;

        var cap_scope: ?*Scope = scope;
        var cap_crossed = false;
        var cap_target: ?*Scope = null;
        while (cap_scope) |s| {
            if (s.symbols.contains("this")) break;
            if (s.symbols.contains(a.name)) {
                cap_target = s;
                break;
            }
            if (s.is_function_boundary) cap_crossed = true;
            cap_scope = s.parent;
        }
        if (cap_crossed) {
            if (cap_target) |ts_scope| {
                if (ts_scope.symbols.getPtr(a.name)) |sym_ptr| {
                    var sym = sym_ptr.*;
                    if (sym.variable) |v| {
                        if (v.is_mut) {
                            var new_v = v;
                            new_v.is_boxed = true;
                            sym.variable = new_v;
                            a.is_boxed = true;
                            if (v.decl_node) |decl| {
                                decl.data.var_decl.is_boxed = true;
                            }
                            sym_ptr.* = sym;
                        }
                    }
                }
            }
        }

        if (self.current_class_props) |props| {
            if (props.contains(a.name)) {
                var curr: ?*Scope = scope;
                while (curr) |s| {
                    if (s.symbols.contains("this")) {
                        a.is_class_property = true;
                        a.owner_type_c_name = self.current_type_c_name;
                        break;
                    }
                    if (s.symbols.contains(a.name)) {
                        break;
                    }
                    curr = s.parent;
                }
            }
        }
    } else {
        self.reportError(node.line, node.column, "TypeError: Undeclared variable '{s}'.", .{a.name});
        return error.TypeError;
    }
    t.* = assigned_type.*;
}

pub fn inferUnaryExpr(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    const u = node.data.unary_expr;
    const op_type = try self.inferNode(u.operand, scope);
    
    if (u.operator == .bang_bang) {
        t.* = extractBaseType(op_type).*;
    } else if (u.operator == .bang) {
        if (op_type.* != .Bool) {
            self.reportError(node.line, node.column, "TypeError: Operator '!' requires a Bool operand, but got {}.", .{op_type.*});
            return error.TypeError;
        }
        t.* = .Bool;
    } else if (u.operator == .minus) {
        if (op_type.* != .Int and op_type.* != .Double) {
            self.reportError(node.line, node.column, "TypeError: Operator '-' requires an Int or Double operand, but got {}.", .{op_type.*});
            return error.TypeError;
        }
        t.* = op_type.*;
    } else {
        self.reportError(node.line, node.column, "TypeError: Unknown unary operator.", .{});
        return error.TypeError;
    }
}

pub fn inferBinaryExpr(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    const b = node.data.binary_expr;
    const left_type = try self.inferNode(b.left, scope);
    const right_type = try self.inferNode(b.right, scope);

    if (b.op == .elvis) {
        const l_base = extractBaseType(left_type);
        if (!self.isCompatible(l_base, right_type)) {
            self.reportError(node.line, node.column, "TypeError: Elvis right-hand side {} is incompatible with left base type {}.", .{ right_type.*, l_base.* });
            return error.TypeError;
        }
        t.* = l_base.*;
        return;
    }

    switch (b.op) {
        .plus => {
            if (left_type.* == .Int and right_type.* == .Int) {
                t.* = .Int;
            } else if ((left_type.* == .Int or left_type.* == .Double) and (right_type.* == .Int or right_type.* == .Double)) {
                t.* = .Double;
            } else if (std.meta.activeTag(left_type.*) == .Pointer and right_type.* == .Int) {
                t.* = left_type.*;
            } else {
                const get_expr_node = try self.allocator.create(ASTNode);
                get_expr_node.* = .{
                    .line = node.line,
                    .column = node.column,
                    .resolved_type = null,
                    .data = .{ .get_expr = .{ .object = b.left, .name = "plus", .is_safe = false } },
                };

                var args = try self.allocator.alloc(*ASTNode, 1);
                args[0] = b.right;

                node.data = .{ .call_expr = .{ .callee = get_expr_node, .arguments = args } };
                try inferCallExpr(self, node, scope, t);
            }
        },
        .minus => {
            if (left_type.* == .Int and right_type.* == .Int) {
                t.* = .Int;
            } else if ((left_type.* == .Int or left_type.* == .Double) and (right_type.* == .Int or right_type.* == .Double)) {
                t.* = .Double;
            } else if (std.meta.activeTag(left_type.*) == .Pointer and std.meta.activeTag(right_type.*) == .Pointer) {
                t.* = .Int;
            } else {
                const get_expr_node = try self.allocator.create(ASTNode);
                get_expr_node.* = .{ .line = node.line, .column = node.column, .resolved_type = null, .data = .{ .get_expr = .{ .object = b.left, .name = "minus", .is_safe = false } } };

                var args = try self.allocator.alloc(*ASTNode, 1);
                args[0] = b.right;

                node.data = .{ .call_expr = .{ .callee = get_expr_node, .arguments = args } };
                try inferCallExpr(self, node, scope, t);
            }
        },
        .star => {
            if ((left_type.* == .Int or left_type.* == .Double) and (right_type.* == .Int or right_type.* == .Double)) {
                if (left_type.* == .Double or right_type.* == .Double) {
                    t.* = .Double;
                } else {
                    t.* = .Int;
                }
            } else {
                const get_expr_node = try self.allocator.create(ASTNode);
                get_expr_node.* = .{ .line = node.line, .column = node.column, .resolved_type = null, .data = .{ .get_expr = .{ .object = b.left, .name = "times", .is_safe = false } } };

                var args = try self.allocator.alloc(*ASTNode, 1);
                args[0] = b.right;

                node.data = .{ .call_expr = .{ .callee = get_expr_node, .arguments = args } };
                try inferCallExpr(self, node, scope, t);
            }
        },
        .slash => {
            if ((left_type.* == .Int or left_type.* == .Double) and (right_type.* == .Int or right_type.* == .Double)) {
                if (left_type.* == .Double or right_type.* == .Double) {
                    t.* = .Double;
                } else {
                    t.* = .Int;
                }
            } else {
                const get_expr_node = try self.allocator.create(ASTNode);
                get_expr_node.* = .{ .line = node.line, .column = node.column, .resolved_type = null, .data = .{ .get_expr = .{ .object = b.left, .name = "div", .is_safe = false } } };

                var args = try self.allocator.alloc(*ASTNode, 1);
                args[0] = b.right;

                node.data = .{ .call_expr = .{ .callee = get_expr_node, .arguments = args } };
                try inferCallExpr(self, node, scope, t);
            }
        },
        .eq_eq, .bang_eq, .less, .greater, .less_eq, .greater_eq, .and_and, .or_or => {
            t.* = .Bool;
        },
        .kw_of => {
            const node_ident = try self.allocator.create(ASTNode);
            node_ident.* = .{ .line = node.line, .column = node.column, .expected_type = node.expected_type, .resolved_type = null, .data = .{ .identifier = .{ .name = "Node", .resolved_c_name = null } } };
            
            const null_lit = try self.allocator.create(ASTNode);
            null_lit.* = .{ .line = node.line, .column = node.column, .resolved_type = null, .data = .null_literal };
            
            var args = try self.allocator.alloc(*ASTNode, 3);
            args[0] = b.left;
            args[1] = b.right;
            args[2] = null_lit;
            
            node.data = .{ .call_expr = .{ .callee = node_ident, .arguments = args } };
            try inferCallExpr(self, node, scope, t);
        },
        else => return error.TypeError,
    }
}

pub fn inferIdentifier(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    var i = &node.data.identifier;
    if (self.alias_map.get(i.name)) |c_name| {
        i.resolved_c_name = c_name;
    }
    if (scope.lookupVariableSymbol(i.name)) |vs| {
        i.is_boxed = vs.is_boxed;
        if (self.current_class_props) |props| {
            if (props.contains(i.name)) {
                var curr: ?*Scope = scope;
                while (curr) |s| {
                    if (s.symbols.contains("this")) {
                        i.is_class_property = true;
                        i.owner_type_c_name = self.current_type_c_name;
                        break;
                    }
                    if (s.symbols.contains(i.name)) {
                        break;
                    }
                    curr = s.parent;
                }
            }
        }
        t.* = vs.eiwa_type.*;

        // Detect variable capture
        var curr: ?*Scope = scope;
        var captured = false;
        while (curr) |s| {
            if (s.symbols.contains(i.name)) {
                break;
            }
            if (s.is_function_boundary) {
                captured = true;
            }
            curr = s.parent;
        }

        if (captured) {
            var lookup_scope: ?*Scope = scope;
            while (lookup_scope) |s| {
                if (s.symbols.getPtr(i.name)) |sym_ptr| {
                    var sym = sym_ptr.*;
                    if (sym.variable) |v| {
                        if (v.is_mut) {
                            var new_v = v;
                            new_v.is_boxed = true;
                            sym.variable = new_v;
                            i.is_boxed = true;
                            if (v.decl_node) |decl| {
                                decl.data.var_decl.is_boxed = true;
                            }
                            sym_ptr.* = sym;
                        }
                        break;
                    }
                }
                lookup_scope = s.parent;
            }
        }
    } else {
        if (self.alias_map.get(i.name)) |c_name| {
            t.* = .{ .Custom = c_name };
            return;
        }
        self.reportError(node.line, node.column, "TypeError: Undeclared variable '{s}'.", .{i.name});
        return error.TypeError;
    }
}

/// True when `val as target` is a numeric conversion (Int <-> Double).
fn isNumericCast(val: EiwaType, target: EiwaType) bool {
    const is_num = struct {
        fn f(t: EiwaType) bool {
            return switch (t) {
                .Int, .Double => true,
                .Custom => |n| std.mem.eql(u8, n, "core_Int") or std.mem.eql(u8, n, "core_Double") or std.mem.eql(u8, n, "Int") or std.mem.eql(u8, n, "Double"),
                else => false,
            };
        }
    }.f;
    return is_num(val) and is_num(target);
}

pub fn inferAsExpr(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    const a = node.data.as_expr;
    const val_type = try self.inferNode(a.value, scope);
    const target_type = try self.resolveTypeRef(a.type_ref);

    const base_val = extractBaseType(val_type);
    const base_target = extractBaseType(target_type);

    if (base_val.* == .Custom and base_target.* == .Custom) {
        const is_upcast = self.conformsTo(base_val.Custom, base_target.Custom);
        const is_downcast = self.conformsTo(base_target.Custom, base_val.Custom);
        if (!is_upcast and !is_downcast) {
            self.reportError(node.line, node.column, "TypeError: Incompatible types for cast: cannot cast {s} to {s}.", .{ base_val.Custom, base_target.Custom });
            return error.TypeError;
        }
    } else if (base_val.* == .Pointer and (base_target.* == .Custom or base_target.* == .String)) {
        // Reinterpret a raw pointer as a `type` (memory view): the value stays a
        // pointer, but field access reads/writes at the type's C layout offsets.
        // No runtime conversion.
    } else if (isNumericCast(base_val.*, base_target.*)) {
        // Numeric cast (Int <-> Double, etc.): a real runtime conversion.
    } else {
        const is_zero_to_ptr = base_val.* == .Int and base_target.* == .Pointer;
        const is_compat = is_zero_to_ptr or self.isCompatible(target_type, val_type) or (base_val.* == .Union and self.isCompatible(base_val, base_target));
        if (!is_compat) {
            self.reportError(node.line, node.column, "TypeError: Cannot cast {} to {}.", .{ val_type.*, target_type.* });
            return error.TypeError;
        }
    }

    t.* = target_type.*;
}

pub fn inferIsExpr(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    const i = node.data.is_expr;
    const val_type = try self.inferNode(i.value, scope);
    const target_type = try self.resolveTypeRef(i.type_ref);

    const is_compat = self.isCompatible(target_type, val_type) or self.isCompatible(val_type, target_type);
    const base_val = extractBaseType(val_type);
    const base_target = extractBaseType(target_type);
    const is_ptr_to_type_check = base_val.* == .Pointer and (base_target.* == .Custom or base_target.* == .String);
    if (!is_compat and !is_ptr_to_type_check) {
        const val_name = if (base_val.* == .Custom) base_val.Custom else @tagName(base_val.*);
        const target_name = if (base_target.* == .Custom) base_target.Custom else @tagName(base_target.*);
        self.reportError(node.line, node.column, "TypeError: Incompatible types for type check: {s} does not conform to {s}.", .{ val_name, target_name });
        return error.TypeError;
    }

    t.* = .Bool;
}

pub fn inferTernaryExpr(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    const ternary_node = node.data.ternary_expr;
    const cond_type = try self.inferNode(ternary_node.condition, scope);
    
    if (!core.isBool(cond_type)) {
        self.reportError(node.line, node.column, "TypeError: Ternary condition must be Bool, found {}.", .{cond_type.*});
        return error.TypeError;
    }
    
    const then_type = try self.inferNode(ternary_node.then_branch, scope);
    
    if (ternary_node.else_branch) |else_b| {
        const else_type = try self.inferNode(else_b, scope);
        
        if (self.isCompatible(then_type, else_type)) {
            t.* = then_type.*;
        } else if (self.isCompatible(else_type, then_type)) {
            t.* = else_type.*;
        } else {
            self.reportError(node.line, node.column, "TypeError: Ternary branches have incompatible types: {} and {}.", .{ then_type.*, else_type.* });
            return error.TypeError;
        }
    } else {
        // Short ternary
        if (then_type.* == .Void) {
            self.reportError(node.line, node.column, "TypeError: Short ternary positive branch cannot be Void.", .{});
            return error.TypeError;
        }
        
        if (core.isNullable(then_type)) {
            t.* = then_type.*;
        } else {
            const left_t = try self.allocator.create(EiwaType);
            left_t.* = then_type.*;
            const right_t = try self.allocator.create(EiwaType);
            right_t.* = .Null;
            t.* = .{ .Union = .{
                .left = left_t,
                .right = right_t,
            } };
        }
    }
}

pub fn inferLambdaExpr(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    const l = &node.data.lambda_expr;
    const old_props = self.current_class_props;
    defer self.current_class_props = old_props;
    
    var expected_params: ?[]const *const EiwaType = null;
    var expected_receiver: ?*const EiwaType = null;
    var expected_return: ?*const EiwaType = null;
    
    if (node.expected_type) |exp| {
        const exp_base = extractBaseType(exp);
        if (exp_base.* == .Function) {
            expected_params = exp_base.Function.params;
            expected_receiver = exp_base.Function.receiver;
            expected_return = exp_base.Function.return_type;
        }
    }
    
    var receiver_scope: ?Scope = null;
    var parent_scope = scope;
    if (expected_receiver) |rec| {
        receiver_scope = Scope.init(self.allocator, scope);
        try receiver_scope.?.define("this", rec, false, false);
        
        const rec_base = extractBaseType(rec);
        if (rec_base.* == .Custom) {
            const actual_name = self.alias_map.get(rec_base.Custom) orelse rec_base.Custom;
            if (self.classes_ast.get(actual_name)) |cn| {
                const type_decl = cn.data.type_decl;
                for (type_decl.primary_constructor) |prop| {
                    if (prop.is_property) {
                        const prop_t = try self.resolveTypeRef(prop.type_ref);
                        try receiver_scope.?.define(prop.name, prop_t, prop.is_mut, false);
                    }
                }
                for (type_decl.methods) |method| {
                    if (method.data == .fun_decl) {
                        const m_decl = method.data.fun_decl;
                        var param_types = ArrayList(*const EiwaType).init(self.allocator);
                        for (m_decl.params) |p| {
                            const p_t = if (p.type_ref) |tr| try self.resolveTypeRef(tr) else try self.resolveTypeName("Void", false);
                            try param_types.append(p_t);
                        }
                        const ret_t = if (m_decl.type_ref) |tr| try self.resolveTypeRef(tr) else try self.resolveTypeName("Void", false);
                         const fn_type = try self.allocator.create(EiwaType);
                         fn_type.* = .{ .Function = .{
                             .params = try param_types.toOwnedSlice(),
                             .return_type = ret_t,
                             .c_name = m_decl.resolved_c_name orelse m_decl.name,
                             .receiver = rec,
                         } };
                        try receiver_scope.?.define(m_decl.name, fn_type, false, true);
                    }
                }
            }
        }
        parent_scope = &receiver_scope.?;
    }
    
    var lambda_scope = Scope.init(self.allocator, parent_scope);
    lambda_scope.is_function_boundary = true;
    defer lambda_scope.deinit();
    defer {
        if (receiver_scope) |*rs| {
            rs.deinit();
        }
    }
    
    var param_types = ArrayList(*const EiwaType).init(self.allocator);
    
    if (l.params.len > 0) {
        for (l.params, 0..) |p, i| {
            var p_type: *const EiwaType = undefined;
            if (p.type_ref) |tr| {
                p_type = try self.resolveTypeRef(tr);
            } else if (expected_params) |exp_ps| {
                if (i < exp_ps.len) {
                    p_type = exp_ps[i];
                } else {
                    self.reportError(node.line, node.column, "TypeError: Lambda has more parameters than expected function type.", .{});
                    return error.TypeError;
                }
            } else {
                self.reportError(node.line, node.column, "TypeError: Cannot infer parameter type without expected function type context. Please specify type for '{s}'.", .{p.name});
                return error.TypeError;
            }
            try lambda_scope.define(p.name, p_type, false, false);
            try param_types.append(p_type);
        }
    } else {
        if (expected_params) |exp_ps| {
            if (exp_ps.len == 1) {
                const it_type = exp_ps[0];
                try lambda_scope.define("it", it_type, false, false);
                try param_types.append(it_type);
            }
        }
    }
    
    var lambda_class_props = std.StringHashMap(void).init(self.allocator);
    defer lambda_class_props.deinit();
    if (expected_receiver) |rec| {
        const rec_base = extractBaseType(rec);
        if (rec_base.* == .Custom) {
            const actual_name = self.alias_map.get(rec_base.Custom) orelse rec_base.Custom;
            if (self.classes_ast.get(actual_name)) |cn| {
                const type_decl = cn.data.type_decl;
                for (type_decl.primary_constructor) |prop| {
                    if (prop.is_property) {
                        try lambda_class_props.put(prop.name, {});
                    }
                }
            }
        }
        self.current_class_props = &lambda_class_props;
    }
    
    var body_type: *const EiwaType = undefined;
    if (l.body.len == 0) {
        const void_t = try self.allocator.create(EiwaType);
        void_t.* = .Void;
        body_type = void_t;
    } else {
        var last_t: ?*const EiwaType = null;
        for (l.body) |stmt| {
            last_t = try self.inferNode(stmt, &lambda_scope);
        }
        body_type = last_t.?;
    }
    
    if (expected_return) |exp_ret| {
        if (exp_ret.* != .Void and !self.isCompatible(exp_ret, body_type)) {
            self.reportError(node.line, node.column, "TypeError: Lambda return type {} is incompatible with expected return type {}.", .{ body_type.*, exp_ret.* });
            return error.TypeError;
        }
    }
    
    const fn_t = try self.allocator.create(EiwaType);
    fn_t.* = .{ .Function = .{
        .params = try param_types.toOwnedSlice(),
        .return_type = body_type,
        .receiver = expected_receiver,
        .c_name = "",
    } };
    t.* = fn_t.*;
}


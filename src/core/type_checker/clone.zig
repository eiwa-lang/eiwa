const std = @import("std");
const ast = @import("../ast.zig");
const type_system = @import("../type_system.zig");
const core = @import("core.zig");

const ASTNode = ast.ASTNode;
const TypeChecker = core.TypeChecker;
const EiwaType = type_system.EiwaType;

pub fn cloneTypeRef(self: *TypeChecker, ref: *const ast.ASTTypeRef) anyerror!*ast.ASTTypeRef {
    const new_ref = try self.allocator.create(ast.ASTTypeRef);
    var name = ref.name;
    if (self.alias_map.get(ref.name)) |aliased| {
        name = aliased;
    }
    
    var generic_args = try self.allocator.alloc(*const ast.ASTTypeRef, ref.generic_args.len);
    for (ref.generic_args, 0..) |arg, i| {
        generic_args[i] = try self.cloneTypeRef(arg);
    }

    var union_types = try self.allocator.alloc(*const ast.ASTTypeRef, ref.union_types.len);
    for (ref.union_types, 0..) |arg, i| {
        union_types[i] = try self.cloneTypeRef(arg);
    }

    new_ref.* = .{
        .name = name,
        .generic_args = generic_args,
        .union_types = union_types,
        .is_array = ref.is_array,
        .is_nullable = ref.is_nullable,
        .is_function = ref.is_function,
        .receiver_type = if (ref.receiver_type) |rec| try self.cloneTypeRef(rec) else null,
        .return_type = if (ref.return_type) |ret| try self.cloneTypeRef(ret) else null,
    };
    return new_ref;
}

pub fn cloneNode(self: *TypeChecker, node: *ASTNode) anyerror!*ASTNode {
    return self.cloneNodeWith(node, false);
}

/// Deep clone that optionally preserves resolved types (for coroutine
/// machine generation, which must resolve nested suspend calls in the copy).
pub fn cloneNodeWith(self: *TypeChecker, node: *ASTNode, preserve_types: bool) anyerror!*ASTNode {
    const new_node = try self.allocator.create(ASTNode);
    new_node.* = node.*;
    if (!preserve_types) {
        new_node.resolved_type = null;
    }
    
    switch (node.data) {
        .block => |b| {
            var new_stmts = try self.allocator.alloc(*ASTNode, b.statements.len);
            for (b.statements, 0..) |stmt, i| {
                new_stmts[i] = try self.cloneNodeWith(stmt, preserve_types);
            }
            new_node.data = .{ .block = .{ .statements = new_stmts, .is_value = b.is_value } };
        },
        .binary_expr => |b| {
            new_node.data = .{ .binary_expr = .{
                .left = try self.cloneNodeWith(b.left, preserve_types),
                .op = b.op,
                .right = try self.cloneNodeWith(b.right, preserve_types),
            }};
        },
        .call_expr => |c| {
            var new_args = try self.allocator.alloc(*ASTNode, c.arguments.len);
            for (c.arguments, 0..) |arg, i| {
                new_args[i] = try self.cloneNodeWith(arg, preserve_types);
            }
            var new_type_args = try self.allocator.alloc(*const ast.ASTTypeRef, c.type_args.len);
            for (c.type_args, 0..) |type_arg, i| {
                new_type_args[i] = try self.cloneTypeRef(type_arg);
            }
            new_node.data = .{ .call_expr = .{
                .callee = try self.cloneNodeWith(c.callee, preserve_types),
                .arguments = new_args,
                .type_args = new_type_args,
            }};
        },
        .get_expr => |g| {
            new_node.data = .{ .get_expr = .{
                .object = try self.cloneNodeWith(g.object, preserve_types),
                .name = g.name,
                .is_safe = g.is_safe,
            }};
        },
        .return_stmt => |r| {
            var val: ?*ASTNode = null;
            if (r.value) |v| val = try self.cloneNodeWith(v, preserve_types);
            new_node.data = .{ .return_stmt = .{ .value = val } };
        },
        .break_stmt => |b| {
            var val: ?*ASTNode = null;
            if (b.value) |v| val = try self.cloneNodeWith(v, preserve_types);
            new_node.data = .{ .break_stmt = .{ .value = val, .is_lambda_break = b.is_lambda_break } };
        },
        .throw_stmt => |t| {
            new_node.data = .{ .throw_stmt = .{ .expr = try self.cloneNodeWith(t.expr, preserve_types) } };
        },
        .var_decl => |v| {
            var val: ?*ASTNode = null;
            if (v.initializer) |init| val = try self.cloneNodeWith(init, preserve_types);
            const ref = if (v.type_ref) |tr| try self.cloneTypeRef(tr) else null;
            new_node.data = .{ .var_decl = .{
                .is_mut = v.is_mut,
                .name = v.name,
                .type_ref = ref,
                .initializer = val,
            }};
        },
        .set_expr => |s| {
            new_node.data = .{ .set_expr = .{
                .object = try self.cloneNodeWith(s.object, preserve_types),
                .name = s.name,
                .value = try self.cloneNodeWith(s.value, preserve_types),
                .is_safe = s.is_safe,
            }};
        },
        .if_expr => |i| {
            var el: ?*ASTNode = null;
            if (i.else_branch) |e| el = try self.cloneNodeWith(e, preserve_types);
            new_node.data = .{ .if_expr = .{
                .condition = try self.cloneNodeWith(i.condition, preserve_types),
                .then_branch = try self.cloneNodeWith(i.then_branch, preserve_types),
                .else_branch = el,
                .is_value = i.is_value,
            }};
        },
        .while_stmt => |w| {
            new_node.data = .{ .while_stmt = .{
                .condition = try self.cloneNodeWith(w.condition, preserve_types),
                .body = try self.cloneNodeWith(w.body, preserve_types),
            }};
        },
        .array_literal => |a| {
            var new_elems = try self.allocator.alloc(*ASTNode, a.elements.len);
            for (a.elements, 0..) |el, i| {
                new_elems[i] = try self.cloneNodeWith(el, preserve_types);
            }
            new_node.data = .{ .array_literal = .{ .elements = new_elems } };
        },
        .string_template => |st| {
            var new_parts = try self.allocator.alloc(*ASTNode, st.parts.len);
            for (st.parts, 0..) |part, i| {
                new_parts[i] = try self.cloneNodeWith(part, preserve_types);
            }
            new_node.data = .{ .string_template = .{ .parts = new_parts } };
        },

        .unary_expr => |u| {
            new_node.data = .{ .unary_expr = .{
                .operator = u.operator,
                .operand = try self.cloneNodeWith(u.operand, preserve_types),
            }};
        },
        .assignment => |a| {
            new_node.data = .{ .assignment = .{
                .name = a.name,
                .value = try self.cloneNodeWith(a.value, preserve_types),
            }};
        },
        .index_expr => |i| {
            new_node.data = .{ .index_expr = .{
                .object = try self.cloneNodeWith(i.object, preserve_types),
                .index = try self.cloneNodeWith(i.index, preserve_types),
            }};
        },
        .named_arg => |na| {
            new_node.data = .{ .named_arg = .{
                .name = na.name,
                .value = try self.cloneNodeWith(na.value, preserve_types),
            }};
        },
        .index_set_expr => |i| {
            new_node.data = .{ .index_set_expr = .{
                .object = try self.cloneNodeWith(i.object, preserve_types),
                .index = try self.cloneNodeWith(i.index, preserve_types),
                .value = try self.cloneNodeWith(i.value, preserve_types),
            }};
        },
        .for_stmt => |f| {
            new_node.data = .{ .for_stmt = .{
                .index_name = f.index_name,
                .item_name = f.item_name,
                .iterable = try self.cloneNodeWith(f.iterable, preserve_types),
                .body = try self.cloneNodeWith(f.body, preserve_types),
                .collect = f.collect,
            }};
        },
        .ternary_expr => |t| {
            var el: ?*ASTNode = null;
            if (t.else_branch) |e| el = try self.cloneNodeWith(e, preserve_types);
            new_node.data = .{ .ternary_expr = .{
                .condition = try self.cloneNodeWith(t.condition, preserve_types),
                .then_branch = try self.cloneNodeWith(t.then_branch, preserve_types),
                .else_branch = el,
            }};
        },
        .as_expr => |a| {
            new_node.data = .{ .as_expr = .{
                .value = try self.cloneNodeWith(a.value, preserve_types),
                .type_ref = try self.cloneTypeRef(a.type_ref),
            }};
        },
        .is_expr => |i| {
            new_node.data = .{ .is_expr = .{
                .value = try self.cloneNodeWith(i.value, preserve_types),
                .type_ref = try self.cloneTypeRef(i.type_ref),
                .is_not = i.is_not,
            }};
        },
        .is_type_cond => |i| {
            new_node.data = .{ .is_type_cond = .{
                .type_ref = try self.cloneTypeRef(i.type_ref),
                .is_not = i.is_not,
            }};
        },
        .when_expr => |w| {
            var new_cases = try self.allocator.alloc(ast.WhenCase, w.cases.len);
            for (w.cases, 0..) |case, idx| {
                var new_conds = try self.allocator.alloc(*ASTNode, case.conds.len);
                for (case.conds, 0..) |cond, c_idx| {
                    new_conds[c_idx] = try self.cloneNodeWith(cond, preserve_types);
                }
                new_cases[idx] = .{
                    .conds = new_conds,
                    .body = try self.cloneNodeWith(case.body, preserve_types),
                    .is_else = case.is_else,
                };
            }
            var subject: ?*ASTNode = null;
            if (w.subject) |subj| subject = try self.cloneNodeWith(subj, preserve_types);
            new_node.data = .{ .when_expr = .{
                .subject = subject,
                .cases = new_cases,
                .is_value = w.is_value,
            }};
        },
        .lambda_expr => |l| {
            var new_params = try self.allocator.alloc(ast.Param, l.params.len);
            for (l.params, 0..) |p, i| {
                new_params[i] = .{
                    .name = p.name,
                    .type_ref = if (p.type_ref) |tr| try self.cloneTypeRef(tr) else null,
                    .initializer = if (p.initializer) |init| try self.cloneNodeWith(init, preserve_types) else null,
                    .is_varargs = p.is_varargs,
                    .annotations = p.annotations,
                };
            }
            var new_body = try self.allocator.alloc(*ASTNode, l.body.len);
            for (l.body, 0..) |stmt, i| {
                new_body[i] = try self.cloneNodeWith(stmt, preserve_types);
            }
            new_node.data = .{ .lambda_expr = .{
                .params = new_params,
                .body = new_body,
            } };
        },
        .try_stmt => |t| {
            var new_catches = try self.allocator.alloc(ast.CatchBlock, t.catches.len);
            for (t.catches, 0..) |c, idx| {
                new_catches[idx] = .{
                    .var_name = c.var_name,
                    .types = c.types,
                    .body = try self.cloneNodeWith(c.body, preserve_types),
                };
            }
            new_node.data = .{ .try_stmt = .{
                .body = try self.cloneNodeWith(t.body, preserve_types),
                .catches = new_catches,
                .is_value = t.is_value,
            }};
        },
        .fun_decl => |f| {
            var new_params = try self.allocator.alloc(ast.Param, f.params.len);
            for (f.params, 0..) |p, i| {
                new_params[i] = .{
                    .name = p.name,
                    .type_ref = if (p.type_ref) |tr| try self.cloneTypeRef(tr) else null,
                    .initializer = if (p.initializer) |init| try self.cloneNodeWith(init, preserve_types) else null,
                    .is_varargs = p.is_varargs,
                    .annotations = p.annotations,
                };
            }
            new_node.data = .{ .fun_decl = .{
                .annotations = f.annotations,
                .modifiers = f.modifiers,
                .name = f.name,
                .generic_params = f.generic_params,
                .params = new_params,
                .type_ref = if (f.type_ref) |tr| try self.cloneTypeRef(tr) else null,
                .body = try self.cloneNodeWith(f.body, preserve_types),
                .is_expr_body = f.is_expr_body,
                .resolved_c_name = null,
                .from_skill = f.from_skill,
                .is_loop_driver = f.is_loop_driver,
                .receiver_type = if (f.receiver_type) |rt| try self.cloneTypeRef(rt) else null,
            } };
        },
        else => {}, // For identifiers and literals, shallow copy is fine as long as we cleared resolved_type
    }
    
    return new_node;
}

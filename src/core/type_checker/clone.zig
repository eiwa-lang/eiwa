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
    
    new_ref.* = .{
        .name = name,
        .generic_args = generic_args,
        .is_array = ref.is_array,
        .is_nullable = ref.is_nullable,
        .is_function = ref.is_function,
        .receiver_type = if (ref.receiver_type) |rec| try self.cloneTypeRef(rec) else null,
        .return_type = if (ref.return_type) |ret| try self.cloneTypeRef(ret) else null,
    };
    return new_ref;
}

pub fn cloneNode(self: *TypeChecker, node: *ASTNode) anyerror!*ASTNode {
    const new_node = try self.allocator.create(ASTNode);
    new_node.* = node.*;
    new_node.resolved_type = null;
    
    switch (node.data) {
        .block => |b| {
            var new_stmts = try self.allocator.alloc(*ASTNode, b.statements.len);
            for (b.statements, 0..) |stmt, i| {
                new_stmts[i] = try self.cloneNode(stmt);
            }
            new_node.data = .{ .block = .{ .statements = new_stmts } };
        },
        .binary_expr => |b| {
            new_node.data = .{ .binary_expr = .{
                .left = try self.cloneNode(b.left),
                .op = b.op,
                .right = try self.cloneNode(b.right),
            }};
        },
        .call_expr => |c| {
            var new_args = try self.allocator.alloc(*ASTNode, c.arguments.len);
            for (c.arguments, 0..) |arg, i| {
                new_args[i] = try self.cloneNode(arg);
            }
            var new_type_args = try self.allocator.alloc(*const ast.ASTTypeRef, c.type_args.len);
            for (c.type_args, 0..) |type_arg, i| {
                new_type_args[i] = try self.cloneTypeRef(type_arg);
            }
            new_node.data = .{ .call_expr = .{
                .callee = try self.cloneNode(c.callee),
                .arguments = new_args,
                .type_args = new_type_args,
            }};
        },
        .get_expr => |g| {
            new_node.data = .{ .get_expr = .{
                .object = try self.cloneNode(g.object),
                .name = g.name,
                .is_safe = g.is_safe,
            }};
        },
        .return_stmt => |r| {
            var val: ?*ASTNode = null;
            if (r.value) |v| val = try self.cloneNode(v);
            new_node.data = .{ .return_stmt = .{ .value = val } };
        },
        .var_decl => |v| {
            var val: ?*ASTNode = null;
            if (v.initializer) |init| val = try self.cloneNode(init);
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
                .object = try self.cloneNode(s.object),
                .name = s.name,
                .value = try self.cloneNode(s.value),
                .is_safe = s.is_safe,
            }};
        },
        .if_expr => |i| {
            var el: ?*ASTNode = null;
            if (i.else_branch) |e| el = try self.cloneNode(e);
            new_node.data = .{ .if_expr = .{
                .condition = try self.cloneNode(i.condition),
                .then_branch = try self.cloneNode(i.then_branch),
                .else_branch = el,
            }};
        },
        .while_stmt => |w| {
            new_node.data = .{ .while_stmt = .{
                .condition = try self.cloneNode(w.condition),
                .body = try self.cloneNode(w.body),
            }};
        },
        .array_literal => |a| {
            var new_elems = try self.allocator.alloc(*ASTNode, a.elements.len);
            for (a.elements, 0..) |el, i| {
                new_elems[i] = try self.cloneNode(el);
            }
            new_node.data = .{ .array_literal = .{ .elements = new_elems } };
        },

        .unary_expr => |u| {
            new_node.data = .{ .unary_expr = .{
                .operator = u.operator,
                .operand = try self.cloneNode(u.operand),
            }};
        },
        .assignment => |a| {
            new_node.data = .{ .assignment = .{
                .name = a.name,
                .value = try self.cloneNode(a.value),
            }};
        },
        .index_expr => |i| {
            new_node.data = .{ .index_expr = .{
                .object = try self.cloneNode(i.object),
                .index = try self.cloneNode(i.index),
            }};
        },
        .named_arg => |na| {
            new_node.data = .{ .named_arg = .{
                .name = na.name,
                .value = try self.cloneNode(na.value),
            }};
        },
        .index_set_expr => |i| {
            new_node.data = .{ .index_set_expr = .{
                .object = try self.cloneNode(i.object),
                .index = try self.cloneNode(i.index),
                .value = try self.cloneNode(i.value),
            }};
        },
        .for_stmt => |f| {
            new_node.data = .{ .for_stmt = .{
                .item_name = f.item_name,
                .iterable = try self.cloneNode(f.iterable),
                .body = try self.cloneNode(f.body),
            }};
        },
        .ternary_expr => |t| {
            var el: ?*ASTNode = null;
            if (t.else_branch) |e| el = try self.cloneNode(e);
            new_node.data = .{ .ternary_expr = .{
                .condition = try self.cloneNode(t.condition),
                .then_branch = try self.cloneNode(t.then_branch),
                .else_branch = el,
            }};
        },
        .as_expr => |a| {
            new_node.data = .{ .as_expr = .{
                .value = try self.cloneNode(a.value),
                .type_ref = try self.cloneTypeRef(a.type_ref),
            }};
        },
        .is_expr => |i| {
            new_node.data = .{ .is_expr = .{
                .value = try self.cloneNode(i.value),
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
                    new_conds[c_idx] = try self.cloneNode(cond);
                }
                new_cases[idx] = .{
                    .conds = new_conds,
                    .body = try self.cloneNode(case.body),
                    .is_else = case.is_else,
                };
            }
            var subject: ?*ASTNode = null;
            if (w.subject) |subj| subject = try self.cloneNode(subj);
            new_node.data = .{ .when_expr = .{
                .subject = subject,
                .cases = new_cases,
            }};
        },
        .lambda_expr => |l| {
            var new_params = try self.allocator.alloc(ast.Param, l.params.len);
            for (l.params, 0..) |p, i| {
                new_params[i] = .{
                    .name = p.name,
                    .type_ref = if (p.type_ref) |tr| try self.cloneTypeRef(tr) else null,
                    .initializer = if (p.initializer) |init| try self.cloneNode(init) else null,
                };
            }
            var new_body = try self.allocator.alloc(*ASTNode, l.body.len);
            for (l.body, 0..) |stmt, i| {
                new_body[i] = try self.cloneNode(stmt);
            }
            new_node.data = .{ .lambda_expr = .{
                .params = new_params,
                .body = new_body,
            } };
        },
        .fun_decl => |f| {
            var new_params = try self.allocator.alloc(ast.Param, f.params.len);
            for (f.params, 0..) |p, i| {
                new_params[i] = .{
                    .name = p.name,
                    .type_ref = if (p.type_ref) |tr| try self.cloneTypeRef(tr) else null,
                    .initializer = if (p.initializer) |init| try self.cloneNode(init) else null,
                };
            }
            new_node.data = .{ .fun_decl = .{
                .annotations = f.annotations,
                .modifiers = f.modifiers,
                .name = f.name,
                .generic_params = f.generic_params,
                .params = new_params,
                .type_ref = if (f.type_ref) |tr| try self.cloneTypeRef(tr) else null,
                .body = try self.cloneNode(f.body),
                .is_expr_body = f.is_expr_body,
                .resolved_c_name = null,
            } };
        },
        else => {}, // For identifiers and literals, shallow copy is fine as long as we cleared resolved_type
    }
    
    return new_node;
}

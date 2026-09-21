const std = @import("std");
const compat = @import("compat.zig");
const ArrayList = compat.ArrayList;
const ast = @import("ast.zig");
const ASTNode = ast.ASTNode;
const ASTTypeRef = ast.ASTTypeRef;
const tc_core = @import("type_checker/core.zig");
const TypeChecker = tc_core.TypeChecker;

pub const Ctx = struct {
    allocator: std.mem.Allocator,
    checker: *TypeChecker,
    counter: *usize,
    generated: *ArrayList(*ASTNode),
};

/// A free variable captured by a `task {}` block. Mutable captures share the
/// heap box so writes inside the task propagate back to the outer variable.
pub const CapturedVar = struct {
    name: []const u8,
    type_ref: *const ASTTypeRef,
    is_boxed: bool,
};

pub const outer_this_field = "__outer_this";

/// Clears resolved types so re-inference descends into rewritten subtrees.
/// NOTE: `expected_type` is intentionally PRESERVED (e.g. empty array literal
/// hints); dropping it breaks inference of `= []` defaults.
pub fn clearResolvedTypes(ctx: Ctx, node: *ASTNode) !void {
    node.resolved_type = null;
    switch (node.data) {
        .type_decl => |t| {
            for (t.primary_constructor) |prop| {
                if (prop.initializer) |init| try clearResolvedTypes(ctx, init);
            }
            for (t.methods) |m| {
                try clearResolvedTypes(ctx, m);
            }
        },
        .object_decl => |o| {
            for (o.members) |m| {
                try clearResolvedTypes(ctx, m);
            }
        },
        .test_decl => |td| {
            if (td.body.data == .block) {
                for (td.body.data.block.statements) |s| {
                    try clearResolvedTypes(ctx, s);
                }
            }
        },
        .fun_decl => |f| {
            if (f.body.data == .block) {
                for (f.body.data.block.statements) |s| {
                    try clearResolvedTypes(ctx, s);
                }
            }
        },
        .var_decl => |v| {
            if (v.initializer) |init| try clearResolvedTypes(ctx, init);
        },
        .call_expr => |c| {
            try clearResolvedTypes(ctx, c.callee);
            for (c.arguments) |arg| {
                try clearResolvedTypes(ctx, arg);
            }
        },
        .binary_expr => |b| {
            try clearResolvedTypes(ctx, b.left);
            try clearResolvedTypes(ctx, b.right);
        },
        .unary_expr => |u| try clearResolvedTypes(ctx, u.operand),
        .get_expr => |g| try clearResolvedTypes(ctx, g.object),
        .set_expr => |s| {
            try clearResolvedTypes(ctx, s.object);
            try clearResolvedTypes(ctx, s.value);
        },
        .block => |b| {
            for (b.statements) |s| {
                try clearResolvedTypes(ctx, s);
            }
        },
        .if_expr => |i| {
            try clearResolvedTypes(ctx, i.condition);
            try clearResolvedTypes(ctx, i.then_branch);
            if (i.else_branch) |e| try clearResolvedTypes(ctx, e);
        },
        .while_stmt => |w| {
            try clearResolvedTypes(ctx, w.condition);
            try clearResolvedTypes(ctx, w.body);
        },
        .for_stmt => |f| {
            try clearResolvedTypes(ctx, f.iterable);
            try clearResolvedTypes(ctx, f.body);
        },
        .return_stmt => |r| if (r.value) |v| try clearResolvedTypes(ctx, v),
        .break_stmt => |b| if (b.value) |v| try clearResolvedTypes(ctx, v),
        .assignment => |a| try clearResolvedTypes(ctx, a.value),
        .try_stmt => |t| {
            try clearResolvedTypes(ctx, t.body);
            for (t.catches) |cb| {
                try clearResolvedTypes(ctx, cb.body);
            }
        },
        .throw_stmt => |t| try clearResolvedTypes(ctx, t.expr),
        .index_expr => |i| {
            try clearResolvedTypes(ctx, i.object);
            try clearResolvedTypes(ctx, i.index);
        },
        .index_set_expr => |i| {
            try clearResolvedTypes(ctx, i.object);
            try clearResolvedTypes(ctx, i.index);
            try clearResolvedTypes(ctx, i.value);
        },
        .when_expr => |w| {
            if (w.subject) |s| try clearResolvedTypes(ctx, s);
            for (w.cases) |case| {
                for (case.conds) |cond| try clearResolvedTypes(ctx, cond);
                try clearResolvedTypes(ctx, case.body);
            }
        },
        .lambda_expr => |l| {
            for (l.body) |s| {
                try clearResolvedTypes(ctx, s);
            }
        },
        .named_arg => |na| try clearResolvedTypes(ctx, na.value),
        .array_literal => |al| {
            for (al.elements) |e| try clearResolvedTypes(ctx, e);
        },
        .string_template => |st| {
            for (st.parts) |e| try clearResolvedTypes(ctx, e);
        },
        .map_literal => |ml| {
            for (ml.elements) |e| try clearResolvedTypes(ctx, e);
        },
        else => {},
    }
}

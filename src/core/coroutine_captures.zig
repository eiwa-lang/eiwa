const std = @import("std");
const compat = @import("compat.zig");
const ArrayList = compat.ArrayList;
const ast = @import("ast.zig");
const ASTNode = ast.ASTNode;
const ASTTypeRef = ast.ASTTypeRef;
const ts = @import("type_system.zig");
const EiwaType = ts.EiwaType;
const cctx = @import("coroutine_ctx.zig");
const Ctx = cctx.Ctx;
const CapturedVar = cctx.CapturedVar;
const syn = @import("coroutine_syntax.zig");

pub fn collectCaptures(ctx: Ctx, body: []const *ASTNode) ![]CapturedVar {
    var locals = std.StringHashMap(void).init(ctx.allocator);
    defer locals.deinit();

    for (body) |s| {
        try recordDeclaredNames(ctx, s, &locals);
    }

    var captures = ArrayList(CapturedVar).init(ctx.allocator);
    for (body) |s| {
        try collectFreeIdents(ctx, s, &locals, &captures);
    }
    return captures.toOwnedSlice();
}

pub fn recordDeclaredNames(ctx: Ctx, node: *ASTNode, locals: *std.StringHashMap(void)) !void {
    switch (node.data) {
        .var_decl => |v| {
            try locals.put(v.name, {});
            if (v.initializer) |init| try recordDeclaredNames(ctx, init, locals);
        },
        .for_stmt => |f| {
            if (f.index_name) |idx_name| try locals.put(idx_name, {});
            try locals.put(f.item_name, {});
            try recordDeclaredNames(ctx, f.iterable, locals);
            try recordDeclaredNames(ctx, f.body, locals);
        },
        .lambda_expr => |l| {
            try locals.put("it", {});
            try locals.put("this", {});
            for (l.params) |p| {
                try locals.put(p.name, {});
            }
            for (l.body) |b| {
                try recordDeclaredNames(ctx, b, locals);
            }
        },
        .block => |b| {
            for (b.statements) |s| {
                try recordDeclaredNames(ctx, s, locals);
            }
        },
        .try_stmt => |t| {
            try recordDeclaredNames(ctx, t.body, locals);
            for (t.catches) |cb| {
                if (cb.var_name) |vn| try locals.put(vn, {});
                try recordDeclaredNames(ctx, cb.body, locals);
            }
        },
        .if_expr => |i| {
            try recordDeclaredNames(ctx, i.condition, locals);
            try recordDeclaredNames(ctx, i.then_branch, locals);
            if (i.else_branch) |e| try recordDeclaredNames(ctx, e, locals);
        },
        .while_stmt => |w| {
            try recordDeclaredNames(ctx, w.condition, locals);
            try recordDeclaredNames(ctx, w.body, locals);
        },
        .binary_expr => |b| {
            try recordDeclaredNames(ctx, b.left, locals);
            try recordDeclaredNames(ctx, b.right, locals);
        },
        .unary_expr => |u| try recordDeclaredNames(ctx, u.operand, locals),
        .get_expr => |g| try recordDeclaredNames(ctx, g.object, locals),
        .set_expr => |s| {
            try recordDeclaredNames(ctx, s.object, locals);
            try recordDeclaredNames(ctx, s.value, locals);
        },
        .assignment => |a| try recordDeclaredNames(ctx, a.value, locals),
        .call_expr => |c| {
            try recordDeclaredNames(ctx, c.callee, locals);
            for (c.arguments) |arg| {
                try recordDeclaredNames(ctx, arg, locals);
            }
        },
        .return_stmt => |r| if (r.value) |v| try recordDeclaredNames(ctx, v, locals),
        .break_stmt => |b| if (b.value) |v| try recordDeclaredNames(ctx, v, locals),
        .index_expr => |i| {
            try recordDeclaredNames(ctx, i.object, locals);
            try recordDeclaredNames(ctx, i.index, locals);
        },
        .index_set_expr => |i| {
            try recordDeclaredNames(ctx, i.object, locals);
            try recordDeclaredNames(ctx, i.index, locals);
            try recordDeclaredNames(ctx, i.value, locals);
        },
        .when_expr => |w| {
            if (w.subject) |s| try recordDeclaredNames(ctx, s, locals);
            for (w.cases) |case| {
                for (case.conds) |cond| try recordDeclaredNames(ctx, cond, locals);
                try recordDeclaredNames(ctx, case.body, locals);
            }
        },
        else => {},
    }
}

pub fn collectFreeIdents(ctx: Ctx, node: *ASTNode, locals: *std.StringHashMap(void), captures: *ArrayList(CapturedVar)) !void {
    switch (node.data) {
        .identifier => |i| {
            if (i.resolved_c_name != null and i.is_class_property) return;
            if (std.mem.eql(u8, i.name, "this")) return;
            if (std.mem.eql(u8, i.name, "it")) return;
            if (locals.contains(i.name)) return;
            if (isGlobalName(ctx, i.name)) return;
            const rt = node.resolved_type orelse return;
            try addCapture(ctx, captures, i.name, rt, i.is_boxed);
        },
        .assignment => |a| {
            // P3: capture the assignment target too (e.g. `caught = 99` inside
            // the task block mutates a captured var).
            if (!locals.contains(a.name) and !isGlobalName(ctx, a.name)) {
                const rt = node.resolved_type orelse return;
                try addCapture(ctx, captures, a.name, rt, a.is_boxed);
            }
            try collectFreeIdents(ctx, a.value, locals, captures);
        },
        .lambda_expr => |l| {
            for (l.body) |s| {
                try collectFreeIdents(ctx, s, locals, captures);
            }
        },
        .block => |b| {
            for (b.statements) |s| {
                try collectFreeIdents(ctx, s, locals, captures);
            }
        },
        .var_decl => |v| {
            if (v.initializer) |init| try collectFreeIdents(ctx, init, locals, captures);
        },
        .call_expr => |c| {
            try collectFreeIdents(ctx, c.callee, locals, captures);
            for (c.arguments) |arg| {
                try collectFreeIdents(ctx, arg, locals, captures);
            }
        },
        .binary_expr => |b| {
            try collectFreeIdents(ctx, b.left, locals, captures);
            try collectFreeIdents(ctx, b.right, locals, captures);
        },
        .unary_expr => |u| try collectFreeIdents(ctx, u.operand, locals, captures),
        .get_expr => |g| try collectFreeIdents(ctx, g.object, locals, captures),
        .set_expr => |s| {
            try collectFreeIdents(ctx, s.object, locals, captures);
            try collectFreeIdents(ctx, s.value, locals, captures);
        },
        .if_expr => |i| {
            try collectFreeIdents(ctx, i.condition, locals, captures);
            try collectFreeIdents(ctx, i.then_branch, locals, captures);
            if (i.else_branch) |e| try collectFreeIdents(ctx, e, locals, captures);
        },
        .while_stmt => |w| {
            try collectFreeIdents(ctx, w.condition, locals, captures);
            try collectFreeIdents(ctx, w.body, locals, captures);
        },
        .for_stmt => |f| {
            try collectFreeIdents(ctx, f.iterable, locals, captures);
            try collectFreeIdents(ctx, f.body, locals, captures);
        },
        .return_stmt => |r| if (r.value) |v| try collectFreeIdents(ctx, v, locals, captures),
        .break_stmt => |b| if (b.value) |v| try collectFreeIdents(ctx, v, locals, captures),
        .try_stmt => |t| {
            try collectFreeIdents(ctx, t.body, locals, captures);
            for (t.catches) |cb| {
                try collectFreeIdents(ctx, cb.body, locals, captures);
            }
        },
        .throw_stmt => |t| try collectFreeIdents(ctx, t.expr, locals, captures),
        .index_expr => |i| {
            try collectFreeIdents(ctx, i.object, locals, captures);
            try collectFreeIdents(ctx, i.index, locals, captures);
        },
        .index_set_expr => |i| {
            try collectFreeIdents(ctx, i.object, locals, captures);
            try collectFreeIdents(ctx, i.index, locals, captures);
            try collectFreeIdents(ctx, i.value, locals, captures);
        },
        .when_expr => |w| {
            if (w.subject) |s| try collectFreeIdents(ctx, s, locals, captures);
            for (w.cases) |case| {
                for (case.conds) |cond| try collectFreeIdents(ctx, cond, locals, captures);
                try collectFreeIdents(ctx, case.body, locals, captures);
            }
        },
        .array_literal => |al| {
            for (al.elements) |e| try collectFreeIdents(ctx, e, locals, captures);
        },
        .string_template => |st| {
            for (st.parts) |e| try collectFreeIdents(ctx, e, locals, captures);
        },
        .map_literal => |ml| {
            for (ml.elements) |e| try collectFreeIdents(ctx, e, locals, captures);
        },
        .named_arg => |na| try collectFreeIdents(ctx, na.value, locals, captures),
        else => {},
    }
}

pub fn addCapture(ctx: Ctx, captures: *ArrayList(CapturedVar), name: []const u8, rt: *const EiwaType, is_boxed: bool) !void {
    for (captures.items) |c| {
        if (std.mem.eql(u8, c.name, name)) return;
    }
    try captures.append(.{
        .name = name,
        .type_ref = try syn.typeRefForEiwaType(ctx.allocator, rt),
        .is_boxed = is_boxed,
    });
}

pub fn isGlobalName(ctx: Ctx, name: []const u8) bool {
    if (ctx.checker.classes_ast.contains(name)) return true;
    if (ctx.checker.objects_ast.contains(name)) return true;
    if (ctx.checker.contracts_ast.contains(name)) return true;
    if (ctx.checker.skills_ast.contains(name)) return true;
    if (ctx.checker.enums_ast.contains(name)) return true;
    if (ctx.checker.functions_ast.contains(name)) return true;
    if (ctx.checker.generic_functions_ast.contains(name)) return true;
    if (ctx.checker.global_scope.lookupFunctions(name) != null) return true;
    if (ctx.checker.alias_map.get(name)) |aliased| {
        if (!std.mem.eql(u8, aliased, name)) return isGlobalName(ctx, aliased);
        return true;
    }
    return false;
}

pub fn rewriteCapturedRefs(ctx: Ctx, captures: []const CapturedVar, node: *ASTNode) !void {
    switch (node.data) {
        .identifier => |*i| {
            for (captures) |c| {
                if (std.mem.eql(u8, i.name, c.name)) {
                    const captured_name = i.name;
                    node.data = .{ .get_expr = .{
                        .object = syn.mkIdent("this"),
                        .name = captured_name,
                        .is_safe = false,
                        .is_boxed = c.is_boxed,
                    } };
                    return;
                }
            }
        },
        .assignment => |*a| {
            try rewriteCapturedRefs(ctx, captures, a.value);
            for (captures) |c| {
                if (std.mem.eql(u8, a.name, c.name)) {
                    const assignment_name = a.name;
                    const assignment_value = a.value;
                    node.data = .{ .set_expr = .{
                        .object = syn.mkIdent("this"),
                        .name = assignment_name,
                        .value = assignment_value,
                        .is_safe = false,
                        .is_boxed = c.is_boxed,
                    } };
                    return;
                }
            }
        },
        .lambda_expr => |l| {
            var inner_captures = ArrayList(CapturedVar).init(ctx.allocator);
            defer inner_captures.deinit();
            var inner_locals = std.StringHashMap(void).init(ctx.allocator);
            defer inner_locals.deinit();
            try inner_locals.put("it", {});
            try inner_locals.put("this", {});
            for (l.params) |p| try inner_locals.put(p.name, {});
            for (l.body) |s| try recordDeclaredNames(ctx, s, &inner_locals);

            for (captures) |c| {
                if (!inner_locals.contains(c.name)) {
                    try inner_captures.append(c);
                }
            }
            for (l.body) |s| {
                try rewriteCapturedRefs(ctx, inner_captures.items, s);
            }
        },
        .block => |b| {
            for (b.statements) |s| {
                try rewriteCapturedRefs(ctx, captures, s);
            }
        },
        .var_decl => |v| {
            if (v.initializer) |init| try rewriteCapturedRefs(ctx, captures, init);
        },
        .call_expr => |c| {
            try rewriteCapturedRefs(ctx, captures, c.callee);
            for (c.arguments) |arg| {
                try rewriteCapturedRefs(ctx, captures, arg);
            }
        },
        .binary_expr => |b| {
            try rewriteCapturedRefs(ctx, captures, b.left);
            try rewriteCapturedRefs(ctx, captures, b.right);
        },
        .unary_expr => |u| try rewriteCapturedRefs(ctx, captures, u.operand),
        .get_expr => |g| try rewriteCapturedRefs(ctx, captures, g.object),
        .set_expr => |s| {
            try rewriteCapturedRefs(ctx, captures, s.object);
            try rewriteCapturedRefs(ctx, captures, s.value);
        },
        .if_expr => |i| {
            try rewriteCapturedRefs(ctx, captures, i.condition);
            try rewriteCapturedRefs(ctx, captures, i.then_branch);
            if (i.else_branch) |e| try rewriteCapturedRefs(ctx, captures, e);
        },
        .while_stmt => |w| {
            try rewriteCapturedRefs(ctx, captures, w.condition);
            try rewriteCapturedRefs(ctx, captures, w.body);
        },
        .for_stmt => |f| {
            try rewriteCapturedRefs(ctx, captures, f.iterable);
            try rewriteCapturedRefs(ctx, captures, f.body);
        },
        .return_stmt => |r| if (r.value) |v| try rewriteCapturedRefs(ctx, captures, v),
        .break_stmt => |b| if (b.value) |v| try rewriteCapturedRefs(ctx, captures, v),
        .try_stmt => |t| {
            try rewriteCapturedRefs(ctx, captures, t.body);
            for (t.catches) |cb| {
                try rewriteCapturedRefs(ctx, captures, cb.body);
            }
        },
        .throw_stmt => |t| try rewriteCapturedRefs(ctx, captures, t.expr),
        .index_expr => |i| {
            try rewriteCapturedRefs(ctx, captures, i.object);
            try rewriteCapturedRefs(ctx, captures, i.index);
        },
        .index_set_expr => |i| {
            try rewriteCapturedRefs(ctx, captures, i.object);
            try rewriteCapturedRefs(ctx, captures, i.index);
            try rewriteCapturedRefs(ctx, captures, i.value);
        },
        .when_expr => |w| {
            if (w.subject) |s| try rewriteCapturedRefs(ctx, captures, s);
            for (w.cases) |case| {
                for (case.conds) |cond| try rewriteCapturedRefs(ctx, captures, cond);
                try rewriteCapturedRefs(ctx, captures, case.body);
            }
        },
        .array_literal => |al| {
            for (al.elements) |e| try rewriteCapturedRefs(ctx, captures, e);
        },
        .string_template => |st| {
            for (st.parts) |e| try rewriteCapturedRefs(ctx, captures, e);
        },
        .map_literal => |ml| {
            for (ml.elements) |e| try rewriteCapturedRefs(ctx, captures, e);
        },
        .named_arg => |na| try rewriteCapturedRefs(ctx, captures, na.value),
        else => {},
    }
}

pub fn collectPromotableLocals(ctx: Ctx, body: []const *ASTNode) ![]CapturedVar {
    var seen = std.StringHashMap(void).init(ctx.allocator);
    defer seen.deinit();
    var out = ArrayList(CapturedVar).init(ctx.allocator);
    for (body) |s| {
        try collectVarDecls(ctx, s, &seen, &out);
    }
    return out.toOwnedSlice();
}

pub fn typeRefForVarDecl(ctx: Ctx, node: *ASTNode) !*const ast.ASTTypeRef {
    const v = node.data.var_decl;
    if (v.type_ref) |tr| return tr;
    if (node.resolved_type) |rt| return try syn.typeRefForEiwaType(ctx.allocator, rt);
    if (v.initializer) |init| {
        if (init.resolved_type) |irt| return try syn.typeRefForEiwaType(ctx.allocator, irt);
        switch (init.data) {
            .string_literal, .string_template => return syn.typeRefSimple("String"),
            .bool_literal => return syn.typeRefSimple("Bool"),
            .double_literal => return syn.typeRefSimple("Double"),
            .int_literal => return syn.typeRefSimple("Int"),
            .call_expr => |c| {
                if (c.callee.data == .identifier) {
                    return syn.typeRefSimple(c.callee.data.identifier.name);
                }
            },
            .unary_expr => |u| {
                if (u.operand.resolved_type) |ort| {
                    if (ort.* == .Union and ort.Union.right.* == .Null) {
                        return try syn.typeRefForEiwaType(ctx.allocator, ort.Union.left);
                    }
                    return try syn.typeRefForEiwaType(ctx.allocator, ort);
                }
            },
            else => {},
        }
    }
    return syn.typeRefSimple("Any");
}

/// Zero-value for a promoted local's field; non-primitive/non-nullable types
/// cannot be promoted (unsupported for now).
pub fn makeNullableTypeRef(ctx: Ctx, ref: *const ASTTypeRef) !*const ASTTypeRef {
    const copy = try ctx.allocator.create(ASTTypeRef);
    copy.* = ref.*;
    copy.is_nullable = true;
    copy.resolved_type = null;
    return copy;
}

pub fn isScalarPrimitiveName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Int") or std.mem.eql(u8, name, "Double") or std.mem.eql(u8, name, "Bool");
}

pub fn collectVarDecls(ctx: Ctx, node: *ASTNode, seen: *std.StringHashMap(void), out: *ArrayList(CapturedVar)) !void {
    switch (node.data) {
        .var_decl => |v| {
            if (v.initializer) |init| {
                if (syn.isTaskCall(init) or syn.isAwaitCall(init)) return;
            }
            if (!seen.contains(v.name)) {
                try seen.put(v.name, {});
                const tr = try typeRefForVarDecl(ctx, node);
                try out.append(.{
                    .name = v.name,
                    .type_ref = tr,
                    .is_boxed = false,
                });
            }
            if (v.initializer) |init| try collectVarDecls(ctx, init, seen, out);
        },
        .lambda_expr => return,
        .call_expr => |c| {
            if (syn.isTaskCall(node)) return;
            try collectVarDecls(ctx, c.callee, seen, out);
            for (c.arguments) |a| try collectVarDecls(ctx, a, seen, out);
        },
        .block => |b| {
            for (b.statements) |s| try collectVarDecls(ctx, s, seen, out);
        },
        .if_expr => |i| {
            try collectVarDecls(ctx, i.condition, seen, out);
            try collectVarDecls(ctx, i.then_branch, seen, out);
            if (i.else_branch) |e| try collectVarDecls(ctx, e, seen, out);
        },
        .while_stmt => |w| {
            try collectVarDecls(ctx, w.condition, seen, out);
            try collectVarDecls(ctx, w.body, seen, out);
        },
        .for_stmt => |f| {
            try collectVarDecls(ctx, f.iterable, seen, out);
            if (f.index_name) |idx_name| {
                if (!seen.contains(idx_name)) {
                    try seen.put(idx_name, {});
                    try out.append(.{
                        .name = idx_name,
                        .type_ref = syn.typeRefSimple("Int"),
                        .is_boxed = false,
                    });
                }
            }
            if (!seen.contains(f.item_name)) {
                try seen.put(f.item_name, {});
                if (f.iterable.resolved_type) |rt| {
                    if (rt.* == .Array) {
                        try out.append(.{
                            .name = f.item_name,
                            .type_ref = try syn.typeRefForEiwaType(ctx.allocator, rt.Array),
                            .is_boxed = false,
                        });
                    }
                }
            }
            try collectVarDecls(ctx, f.body, seen, out);
        },
        .return_stmt => |r| if (r.value) |v| try collectVarDecls(ctx, v, seen, out),
        .break_stmt => |b| if (b.value) |v| try collectVarDecls(ctx, v, seen, out),
        .assignment => |a| try collectVarDecls(ctx, a.value, seen, out),
        .binary_expr => |b| {
            try collectVarDecls(ctx, b.left, seen, out);
            try collectVarDecls(ctx, b.right, seen, out);
        },
        .unary_expr => |u| try collectVarDecls(ctx, u.operand, seen, out),
        .get_expr => |g| try collectVarDecls(ctx, g.object, seen, out),
        .set_expr => |s| {
            try collectVarDecls(ctx, s.object, seen, out);
            try collectVarDecls(ctx, s.value, seen, out);
        },
        .index_expr => |i| {
            try collectVarDecls(ctx, i.object, seen, out);
            try collectVarDecls(ctx, i.index, seen, out);
        },
        .index_set_expr => |i| {
            try collectVarDecls(ctx, i.object, seen, out);
            try collectVarDecls(ctx, i.index, seen, out);
            try collectVarDecls(ctx, i.value, seen, out);
        },
        .try_stmt => |t| {
            try collectVarDecls(ctx, t.body, seen, out);
            for (t.catches) |cb| {
                if (cb.var_name) |vname| {
                    if (!seen.contains(vname)) {
                        try seen.put(vname, {});
                        const type_ref = if (cb.types.len > 0) cb.types[0] else syn.typeRefSimple("Exception");
                        try out.append(.{
                            .name = vname,
                            .type_ref = type_ref,
                            .is_boxed = false,
                        });
                    }
                }
                try collectVarDecls(ctx, cb.body, seen, out);
            }
        },
        .throw_stmt => |t| try collectVarDecls(ctx, t.expr, seen, out),
        .when_expr => |w| {
            if (w.subject) |s| try collectVarDecls(ctx, s, seen, out);
            for (w.cases) |case| {
                for (case.conds) |cond| try collectVarDecls(ctx, cond, seen, out);
                try collectVarDecls(ctx, case.body, seen, out);
            }
        },
        .named_arg => |na| try collectVarDecls(ctx, na.value, seen, out),
        .array_literal => |al| {
            for (al.elements) |e| try collectVarDecls(ctx, e, seen, out);
        },
        .string_template => |st| {
            for (st.parts) |e| try collectVarDecls(ctx, e, seen, out);
        },
        .map_literal => |ml| {
            for (ml.elements) |e| try collectVarDecls(ctx, e, seen, out);
        },
        else => {},
    }
}

pub fn collectMachineryLocals(ctx: Ctx, node: *ASTNode, promoted_names: *std.StringHashMap(void), out: *ArrayList(CapturedVar)) !void {
    switch (node.data) {
        .var_decl => |v| {
            if (!promoted_names.contains(v.name)) {
                try promoted_names.put(v.name, {});
                const tr = if (v.type_ref) |t|
                    t
                else if (node.resolved_type) |rt|
                    try syn.typeRefForEiwaType(ctx.allocator, rt)
                else
                    null;
                if (tr) |t| {
                    try out.append(.{
                        .name = v.name,
                        .type_ref = t,
                        .is_boxed = false,
                    });
                }
            }
            if (v.initializer) |init| try collectMachineryLocals(ctx, init, promoted_names, out);
        },
        .lambda_expr => return,
        .block => |b| {
            for (b.statements) |s| try collectMachineryLocals(ctx, s, promoted_names, out);
        },
        .call_expr => |c| {
            if (syn.isTaskCall(node)) return;
            try collectMachineryLocals(ctx, c.callee, promoted_names, out);
            for (c.arguments) |a| try collectMachineryLocals(ctx, a, promoted_names, out);
        },
        .if_expr => |i| {
            try collectMachineryLocals(ctx, i.condition, promoted_names, out);
            try collectMachineryLocals(ctx, i.then_branch, promoted_names, out);
            if (i.else_branch) |e| try collectMachineryLocals(ctx, e, promoted_names, out);
        },
        .while_stmt => |w| {
            try collectMachineryLocals(ctx, w.condition, promoted_names, out);
            try collectMachineryLocals(ctx, w.body, promoted_names, out);
        },
        .for_stmt => |f| {
            try collectMachineryLocals(ctx, f.iterable, promoted_names, out);
            if (f.index_name) |idx_name| {
                if (!promoted_names.contains(idx_name)) {
                    try promoted_names.put(idx_name, {});
                    try out.append(.{
                        .name = idx_name,
                        .type_ref = syn.typeRefSimple("Int"),
                        .is_boxed = false,
                    });
                }
            }
            if (!promoted_names.contains(f.item_name)) {
                try promoted_names.put(f.item_name, {});
                if (f.iterable.resolved_type) |rt| {
                    if (rt.* == .Array) {
                        try out.append(.{
                            .name = f.item_name,
                            .type_ref = try syn.typeRefForEiwaType(ctx.allocator, rt.Array),
                            .is_boxed = false,
                        });
                    }
                }
            }
            try collectMachineryLocals(ctx, f.body, promoted_names, out);
        },
        .return_stmt => |r| if (r.value) |v| try collectMachineryLocals(ctx, v, promoted_names, out),
        .break_stmt => |b| if (b.value) |v| try collectMachineryLocals(ctx, v, promoted_names, out),
        .assignment => |a| try collectMachineryLocals(ctx, a.value, promoted_names, out),
        .binary_expr => |b| {
            try collectMachineryLocals(ctx, b.left, promoted_names, out);
            try collectMachineryLocals(ctx, b.right, promoted_names, out);
        },
        .unary_expr => |u| try collectMachineryLocals(ctx, u.operand, promoted_names, out),
        .get_expr => |g| try collectMachineryLocals(ctx, g.object, promoted_names, out),
        .set_expr => |s| {
            try collectMachineryLocals(ctx, s.object, promoted_names, out);
            try collectMachineryLocals(ctx, s.value, promoted_names, out);
        },
        .index_expr => |i| {
            try collectMachineryLocals(ctx, i.object, promoted_names, out);
            try collectMachineryLocals(ctx, i.index, promoted_names, out);
        },
        .index_set_expr => |i| {
            try collectMachineryLocals(ctx, i.object, promoted_names, out);
            try collectMachineryLocals(ctx, i.index, promoted_names, out);
            try collectMachineryLocals(ctx, i.value, promoted_names, out);
        },
        .try_stmt => |t| {
            try collectMachineryLocals(ctx, t.body, promoted_names, out);
            for (t.catches) |cb| {
                if (cb.var_name) |vname| {
                    if (!promoted_names.contains(vname)) {
                        try promoted_names.put(vname, {});
                        const type_ref = if (cb.types.len > 0) cb.types[0] else syn.typeRefSimple("Exception");
                        try out.append(.{
                            .name = vname,
                            .type_ref = type_ref,
                            .is_boxed = false,
                        });
                    }
                }
                try collectMachineryLocals(ctx, cb.body, promoted_names, out);
            }
        },
        .throw_stmt => |t| try collectMachineryLocals(ctx, t.expr, promoted_names, out),
        .when_expr => |w| {
            if (w.subject) |s| try collectMachineryLocals(ctx, s, promoted_names, out);
            for (w.cases) |case| {
                for (case.conds) |cond| try collectMachineryLocals(ctx, cond, promoted_names, out);
                try collectMachineryLocals(ctx, case.body, promoted_names, out);
            }
        },
        .named_arg => |na| try collectMachineryLocals(ctx, na.value, promoted_names, out),
        .array_literal => |al| {
            for (al.elements) |e| try collectMachineryLocals(ctx, e, promoted_names, out);
        },
        .string_template => |st| {
            for (st.parts) |e| try collectMachineryLocals(ctx, e, promoted_names, out);
        },
        .map_literal => |ml| {
            for (ml.elements) |e| try collectMachineryLocals(ctx, e, promoted_names, out);
        },
        else => {},
    }
}

/// Rewrites references to promoted variables (captures + locals) into
/// `this.<name>` field accesses, and converts their `var` declarations into
/// `this.<name> = <init>` assignments. Like `rewriteCapturedRefs` but also
/// promotes locals declared inside the block (they must survive suspension).
pub fn rewritePromotedRefs(ctx: Ctx, promoted: []const CapturedVar, node: *ASTNode) !void {
    switch (node.data) {
        .identifier => |*i| {
            for (promoted) |c| {
                if (std.mem.eql(u8, i.name, c.name)) {
                    const captured_name = i.name;
                    node.data = .{ .get_expr = .{
                        .object = syn.mkIdent("this"),
                        .name = captured_name,
                        .is_safe = false,
                        .is_boxed = c.is_boxed,
                    } };
                    return;
                }
            }
        },
        .assignment => |*a| {
            try rewritePromotedRefs(ctx, promoted, a.value);
            for (promoted) |c| {
                if (std.mem.eql(u8, a.name, c.name)) {
                    const assignment_name = a.name;
                    const assignment_value = a.value;
                    node.data = .{ .set_expr = .{
                        .object = syn.mkIdent("this"),
                        .name = assignment_name,
                        .value = assignment_value,
                        .is_safe = false,
                        .is_boxed = c.is_boxed,
                    } };
                    return;
                }
            }
        },
        .var_decl => |*v| {
            if (v.initializer) |init| {
                if (syn.isCoopAwaitCall(init)) {
                    try rewritePromotedRefs(ctx, promoted, init);
                    return;
                }
                if (!syn.isTaskCall(init) and !syn.isAwaitCall(init)) {
                    try rewritePromotedRefs(ctx, promoted, init);
                    for (promoted) |c| {
                        if (std.mem.eql(u8, v.name, c.name)) {
                            const var_name = v.name;
                            const init_value = init;
                            node.data = .{ .set_expr = .{
                                .object = syn.mkIdent("this"),
                                .name = var_name,
                                .value = init_value,
                                .is_safe = false,
                                .is_boxed = c.is_boxed,
                            } };
                            return;
                        }
                    }
                }
            }
        },
        .lambda_expr => |l| {
            var inner_promoted = ArrayList(CapturedVar).init(ctx.allocator);
            defer inner_promoted.deinit();
            var inner_locals = std.StringHashMap(void).init(ctx.allocator);
            defer inner_locals.deinit();
            try inner_locals.put("it", {});
            try inner_locals.put("this", {});
            for (l.params) |p| try inner_locals.put(p.name, {});
            for (l.body) |s| try recordDeclaredNames(ctx, s, &inner_locals);

            for (promoted) |p| {
                if (!inner_locals.contains(p.name)) {
                    try inner_promoted.append(p);
                }
            }
            for (l.body) |s| {
                try rewritePromotedRefs(ctx, inner_promoted.items, s);
            }
        },
        .block => |b| {
            for (b.statements) |s| {
                try rewritePromotedRefs(ctx, promoted, s);
            }
        },
        .call_expr => |c| {
            try rewritePromotedRefs(ctx, promoted, c.callee);
            for (c.arguments) |arg| {
                try rewritePromotedRefs(ctx, promoted, arg);
            }
        },
        .binary_expr => |b| {
            try rewritePromotedRefs(ctx, promoted, b.left);
            try rewritePromotedRefs(ctx, promoted, b.right);
        },
        .unary_expr => |u| try rewritePromotedRefs(ctx, promoted, u.operand),
        .get_expr => |*g| {
            try rewritePromotedRefs(ctx, promoted, g.object);
            if (!g.is_safe and g.object.data == .get_expr and g.object.data.get_expr.object.data == .identifier and std.mem.eql(u8, g.object.data.get_expr.object.data.identifier.name, "this")) {
                const prop_name = g.object.data.get_expr.name;
                for (promoted) |c| {
                    if (std.mem.eql(u8, c.name, prop_name) and !c.type_ref.is_nullable and !isScalarPrimitiveName(c.type_ref.name)) {
                        g.object = syn.mkUnary(.bang_bang, g.object);
                        break;
                    }
                }
            }
        },
        .set_expr => |s| {
            try rewritePromotedRefs(ctx, promoted, s.object);
            try rewritePromotedRefs(ctx, promoted, s.value);
        },
        .index_expr => |*i| {
            try rewritePromotedRefs(ctx, promoted, i.object);
            try rewritePromotedRefs(ctx, promoted, i.index);
            if (i.object.data == .get_expr and i.object.data.get_expr.object.data == .identifier and std.mem.eql(u8, i.object.data.get_expr.object.data.identifier.name, "this")) {
                const prop_name = i.object.data.get_expr.name;
                for (promoted) |c| {
                    if (std.mem.eql(u8, c.name, prop_name) and !c.type_ref.is_nullable and !isScalarPrimitiveName(c.type_ref.name)) {
                        i.object = syn.mkUnary(.bang_bang, i.object);
                        break;
                    }
                }
            }
        },
        .if_expr => |i| {
            try rewritePromotedRefs(ctx, promoted, i.condition);
            try rewritePromotedRefs(ctx, promoted, i.then_branch);
            if (i.else_branch) |e| try rewritePromotedRefs(ctx, promoted, e);
        },
        .while_stmt => |w| {
            try rewritePromotedRefs(ctx, promoted, w.condition);
            try rewritePromotedRefs(ctx, promoted, w.body);
        },
        .for_stmt => |f| {
            try rewritePromotedRefs(ctx, promoted, f.iterable);
            try rewritePromotedRefs(ctx, promoted, f.body);
        },
        .return_stmt => |r| if (r.value) |v| try rewritePromotedRefs(ctx, promoted, v),
        .break_stmt => |b| if (b.value) |v| try rewritePromotedRefs(ctx, promoted, v),
        .try_stmt => |t| {
            try rewritePromotedRefs(ctx, promoted, t.body);
            for (t.catches) |cb| {
                try rewritePromotedRefs(ctx, promoted, cb.body);
            }
        },
        .throw_stmt => |t| try rewritePromotedRefs(ctx, promoted, t.expr),
        .index_set_expr => |i| {
            try rewritePromotedRefs(ctx, promoted, i.object);
            try rewritePromotedRefs(ctx, promoted, i.index);
            try rewritePromotedRefs(ctx, promoted, i.value);
        },
        .when_expr => |w| {
            if (w.subject) |s| try rewritePromotedRefs(ctx, promoted, s);
            for (w.cases) |case| {
                for (case.conds) |cond| try rewritePromotedRefs(ctx, promoted, cond);
                try rewritePromotedRefs(ctx, promoted, case.body);
            }
        },
        .array_literal => |al| {
            for (al.elements) |e| try rewritePromotedRefs(ctx, promoted, e);
        },
        .string_template => |st| {
            for (st.parts) |e| try rewritePromotedRefs(ctx, promoted, e);
        },
        .map_literal => |ml| {
            for (ml.elements) |e| try rewritePromotedRefs(ctx, promoted, e);
        },
        .named_arg => |na| try rewritePromotedRefs(ctx, promoted, na.value),
        else => {},
    }
}

pub fn findOuterThisType(ctx: Ctx, body: []const *ASTNode) ?*const EiwaType {
    const refs = findOuterScopeRefs(body);
    if (refs.this_type) |t| return t;
    // No explicit `this`: a bare outer property (`ticks`, `ticks = ...`)
    // still needs the receiver captured. Derive it from the property's
    // owner type; skip generic owners (their type args are unknown here).
    if (refs.prop_owner) |owner| {
        const actual = ctx.checker.alias_map.get(owner) orelse owner;
        if (ctx.checker.classes_ast.get(actual)) |class_node| {
            if (class_node.data != .type_decl) return null;
            if (class_node.data.type_decl.generic_params.len > 0) return null;
        } else if (ctx.checker.objects_ast.get(actual) == null) {
            return null;
        }
        const t = ctx.allocator.create(EiwaType) catch return null;
        t.* = .{ .Custom = actual };
        return t;
    }
    return null;
}

const OuterScopeRefs = struct {
    this_type: ?*const EiwaType = null,
    prop_owner: ?[]const u8 = null,

    fn complete(self: OuterScopeRefs) bool {
        return self.this_type != null and self.prop_owner != null;
    }
};

fn findOuterScopeRefs(body: []const *ASTNode) OuterScopeRefs {
    var refs = OuterScopeRefs{};
    for (body) |s| {
        findOuterScopeRefsInNode(s, &refs, true);
        if (refs.complete()) break;
    }
    return refs;
}

fn findOuterScopeRefsInNode(node: *ASTNode, refs: *OuterScopeRefs, record_this: bool) void {
    if (refs.complete()) return;
    switch (node.data) {
        .identifier => |i| {
            if (i.is_outer_this or (record_this and std.mem.eql(u8, i.name, "this"))) {
                if (refs.this_type == null) {
                    if (node.resolved_type) |rt| refs.this_type = rt;
                }
            } else if (record_this and i.is_class_property) {
                if (refs.prop_owner == null) {
                    if (i.owner_type_c_name) |o| refs.prop_owner = o;
                }
            }
        },
        .call_expr => |c| {
            if (syn.isTaskCall(node)) return;
            findOuterScopeRefsInNode(c.callee, refs, record_this);
            for (c.arguments) |a| findOuterScopeRefsInNode(a, refs, record_this);
        },
        .lambda_expr => |l| {
            var shadows_this = false;
            for (l.params) |p| {
                if (std.mem.eql(u8, p.name, "this")) shadows_this = true;
            }
            var inner_record = record_this and !shadows_this;
            if (lambdaReceiverType(node) != null) inner_record = false;
            for (l.body) |s| findOuterScopeRefsInNode(s, refs, inner_record);
        },
        .block => |b| {
            for (b.statements) |s| findOuterScopeRefsInNode(s, refs, record_this);
        },
        .var_decl => |v| {
            if (v.initializer) |init| findOuterScopeRefsInNode(init, refs, record_this);
        },
        .assignment => |a| {
            if (a.is_class_property) {
                if (refs.prop_owner == null) {
                    if (a.owner_type_c_name) |o| refs.prop_owner = o;
                }
            }
            findOuterScopeRefsInNode(a.value, refs, record_this);
        },
        .binary_expr => |b| {
            findOuterScopeRefsInNode(b.left, refs, record_this);
            findOuterScopeRefsInNode(b.right, refs, record_this);
        },
        .unary_expr => |u| findOuterScopeRefsInNode(u.operand, refs, record_this),
        .get_expr => |g| findOuterScopeRefsInNode(g.object, refs, record_this),
        .set_expr => |s| {
            findOuterScopeRefsInNode(s.object, refs, record_this);
            findOuterScopeRefsInNode(s.value, refs, record_this);
        },
        .if_expr => |i| {
            findOuterScopeRefsInNode(i.condition, refs, record_this);
            findOuterScopeRefsInNode(i.then_branch, refs, record_this);
            if (i.else_branch) |e| findOuterScopeRefsInNode(e, refs, record_this);
        },
        .while_stmt => |w| {
            findOuterScopeRefsInNode(w.condition, refs, record_this);
            findOuterScopeRefsInNode(w.body, refs, record_this);
        },
        .for_stmt => |f| {
            findOuterScopeRefsInNode(f.iterable, refs, record_this);
            findOuterScopeRefsInNode(f.body, refs, record_this);
        },
        .return_stmt => |r| {
            if (r.value) |v| findOuterScopeRefsInNode(v, refs, record_this);
        },
        .break_stmt => |b| {
            if (b.value) |v| findOuterScopeRefsInNode(v, refs, record_this);
        },
        .try_stmt => |t| {
            findOuterScopeRefsInNode(t.body, refs, record_this);
            for (t.catches) |cb| findOuterScopeRefsInNode(cb.body, refs, record_this);
        },
        .throw_stmt => |t| findOuterScopeRefsInNode(t.expr, refs, record_this),
        .when_expr => |w| {
            if (w.subject) |s| findOuterScopeRefsInNode(s, refs, record_this);
            for (w.cases) |case| {
                for (case.conds) |cond| findOuterScopeRefsInNode(cond, refs, record_this);
                findOuterScopeRefsInNode(case.body, refs, record_this);
            }
        },
        .array_literal => |al| {
            for (al.elements) |e| findOuterScopeRefsInNode(e, refs, record_this);
        },
        .string_template => |st| {
            for (st.parts) |e| findOuterScopeRefsInNode(e, refs, record_this);
        },
        .map_literal => |ml| {
            for (ml.elements) |e| findOuterScopeRefsInNode(e, refs, record_this);
        },
        .index_expr => |i| {
            findOuterScopeRefsInNode(i.object, refs, record_this);
            findOuterScopeRefsInNode(i.index, refs, record_this);
        },
        .index_set_expr => |i| {
            findOuterScopeRefsInNode(i.object, refs, record_this);
            findOuterScopeRefsInNode(i.index, refs, record_this);
            findOuterScopeRefsInNode(i.value, refs, record_this);
        },
        .named_arg => |na| findOuterScopeRefsInNode(na.value, refs, record_this),
        else => {},
    }
}

pub fn rewriteOuterThisRefs(ctx: Ctx, body: []const *ASTNode) !void {
    for (body) |s| try rewriteOuterThisInNode(ctx, s, false);
}

fn lambdaReceiverType(node: *ASTNode) ?*const EiwaType {
    if (node.resolved_type) |rt| {
        if (rt.* == .Function and rt.Function.receiver != null) return rt.Function.receiver;
    }
    return null;
}

pub fn rewriteOuterThisInNode(ctx: Ctx, node: *ASTNode, capture_only: bool) !void {
    switch (node.data) {
        .identifier => |i| {
            if (i.is_outer_this or (!capture_only and std.mem.eql(u8, i.name, "this"))) {
                node.data = .{ .get_expr = .{
                    .object = syn.mkIdent("this"),
                    .name = cctx.outer_this_field,
                    .is_safe = false,
                    .is_boxed = false,
                } };
                node.resolved_type = null;
            } else if (!capture_only and i.is_class_property) {
                node.data = .{ .get_expr = .{
                    .object = syn.mkGetExpr(syn.mkIdent("this"), cctx.outer_this_field),
                    .name = i.name,
                    .is_safe = false,
                    .is_boxed = false,
                } };
                node.resolved_type = null;
            }
            return;
        },
        .call_expr => |c| {
            if (syn.isTaskCall(node)) return;
            try rewriteOuterThisInNode(ctx, c.callee, capture_only);
            for (c.arguments) |a| {
                try rewriteOuterThisInNode(ctx, a, capture_only);
            }
            return;
        },
        .lambda_expr => |l| {
            for (l.params) |p| {
                if (std.mem.eql(u8, p.name, "this")) return;
            }
            const inner_only = capture_only or lambdaReceiverType(node) != null;
            for (l.body) |s| {
                try rewriteOuterThisInNode(ctx, s, inner_only);
            }
            return;
        },
        .block => |b| {
            for (b.statements) |s| {
                try rewriteOuterThisInNode(ctx, s, capture_only);
            }
            return;
        },
        .var_decl => |v| {
            if (v.initializer) |init| try rewriteOuterThisInNode(ctx, init, capture_only);
            return;
        },
        .assignment => |a| {
            try rewriteOuterThisInNode(ctx, a.value, capture_only);
            if (!capture_only and a.is_class_property) {
                const assignment_name = a.name;
                const assignment_value = a.value;
                node.data = .{ .set_expr = .{
                    .object = syn.mkGetExpr(syn.mkIdent("this"), cctx.outer_this_field),
                    .name = assignment_name,
                    .value = assignment_value,
                    .is_safe = false,
                    .is_boxed = false,
                } };
                node.resolved_type = null;
            }
            return;
        },
        .binary_expr => |b| {
            try rewriteOuterThisInNode(ctx, b.left, capture_only);
            try rewriteOuterThisInNode(ctx, b.right, capture_only);
            return;
        },
        .unary_expr => |u| {
            try rewriteOuterThisInNode(ctx, u.operand, capture_only);
            return;
        },
        .get_expr => |g| {
            try rewriteOuterThisInNode(ctx, g.object, capture_only);
            return;
        },
        .set_expr => |s| {
            try rewriteOuterThisInNode(ctx, s.object, capture_only);
            try rewriteOuterThisInNode(ctx, s.value, capture_only);
            return;
        },
        .if_expr => |i| {
            try rewriteOuterThisInNode(ctx, i.condition, capture_only);
            try rewriteOuterThisInNode(ctx, i.then_branch, capture_only);
            if (i.else_branch) |e| try rewriteOuterThisInNode(ctx, e, capture_only);
            return;
        },
        .while_stmt => |w| {
            try rewriteOuterThisInNode(ctx, w.condition, capture_only);
            try rewriteOuterThisInNode(ctx, w.body, capture_only);
            return;
        },
        .for_stmt => |f| {
            try rewriteOuterThisInNode(ctx, f.iterable, capture_only);
            try rewriteOuterThisInNode(ctx, f.body, capture_only);
            return;
        },
        .return_stmt => |r| {
            if (r.value) |v| try rewriteOuterThisInNode(ctx, v, capture_only);
            return;
        },
        .break_stmt => |b| {
            if (b.value) |v| try rewriteOuterThisInNode(ctx, v, capture_only);
            return;
        },
        .try_stmt => |t| {
            try rewriteOuterThisInNode(ctx, t.body, capture_only);
            for (t.catches) |cb| {
                try rewriteOuterThisInNode(ctx, cb.body, capture_only);
            }
            return;
        },
        .throw_stmt => |t| {
            try rewriteOuterThisInNode(ctx, t.expr, capture_only);
            return;
        },
        .when_expr => |w| {
            if (w.subject) |s| try rewriteOuterThisInNode(ctx, s, capture_only);
            for (w.cases) |case| {
                for (case.conds) |cond| try rewriteOuterThisInNode(ctx, cond, capture_only);
                try rewriteOuterThisInNode(ctx, case.body, capture_only);
            }
            return;
        },
        .array_literal => |al| {
            for (al.elements) |e| try rewriteOuterThisInNode(ctx, e, capture_only);
            return;
        },
        .string_template => |st| {
            for (st.parts) |e| try rewriteOuterThisInNode(ctx, e, capture_only);
            return;
        },
        .map_literal => |ml| {
            for (ml.elements) |e| try rewriteOuterThisInNode(ctx, e, capture_only);
            return;
        },
        .index_expr => |i| {
            try rewriteOuterThisInNode(ctx, i.object, capture_only);
            try rewriteOuterThisInNode(ctx, i.index, capture_only);
            return;
        },
        .index_set_expr => |i| {
            try rewriteOuterThisInNode(ctx, i.object, capture_only);
            try rewriteOuterThisInNode(ctx, i.index, capture_only);
            try rewriteOuterThisInNode(ctx, i.value, capture_only);
            return;
        },
        .named_arg => |na| {
            try rewriteOuterThisInNode(ctx, na.value, capture_only);
            return;
        },
        else => return,
    }
}

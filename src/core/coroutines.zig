const std = @import("std");
const ast = @import("./ast.zig");
const ASTNode = ast.ASTNode;
const tc_core = @import("type_checker/core.zig");
const ModuleRegistry = tc_core.ModuleRegistry;
const ts = @import("type_system.zig");

/// Coroutine detection pass (stackless coroutines, inference-based).
///
/// No `suspend_set` keyword: the compiler *infers* which functions can suspend_set by
/// finding calls to `@Suspend`-annotated stdlib functions (`await()`, `sleep()`,
/// `yield()`, `waitReadable()`, ...) and taking the transitive closure over the
/// call graph. `@Coroutine`-annotated functions (`task {}`) take a lambda that
/// is a coroutine body.
///
/// The pass runs after type checking and before emission. It marks:
///   - `fun_decl.is_suspend = true` on every function in the closure;
///   - `call_expr.is_suspend_call = true` on the actual suspension points.
///
/// Boundary rule: a suspension point inside a lambda passed to a `@Coroutine`
/// function (`task { ... }`) belongs to that lambda's own coroutine and does
/// NOT propagate to the enclosing function.
pub fn detectSuspendFunctions(
    allocator: std.mem.Allocator,
    registry: *ModuleRegistry,
    global_functions: *std.StringHashMap(*ASTNode),
) !void {
    // 1. Direct suspension primitives: functions with @Suspend annotation.
    var suspend_set = std.StringHashMap(void).init(allocator);
    defer suspend_set.deinit();

    var fn_it = global_functions.iterator();
    while (fn_it.next()) |entry| {
        const node = entry.value_ptr.*;
        if (node.data != .fun_decl) continue;
        if (hasAnnotation(node.data.fun_decl.annotations, "Suspend")) {
            try suspend_set.put(entry.key_ptr.*, {});
        }
    }

    // 2. Fixpoint: any function whose body calls a suspend_set function is suspend_set.
    var changed = true;
    while (changed) {
        changed = false;
        fn_it = global_functions.iterator();
        while (fn_it.next()) |entry| {
            const c_name = entry.key_ptr.*;
            const node = entry.value_ptr.*;
            if (node.data != .fun_decl) continue;
            if (suspend_set.contains(c_name)) continue;
            if (bodyCallsSuspend(node.data.fun_decl.body, registry, global_functions, &suspend_set, allocator)) {
                try suspend_set.put(c_name, {});
                changed = true;
            }
        }
    }

    // 3. Mark functions and their suspension points.
    fn_it = global_functions.iterator();
    while (fn_it.next()) |entry| {
        const node = entry.value_ptr.*;
        if (node.data != .fun_decl) continue;
        if (!suspend_set.contains(entry.key_ptr.*)) continue;
        node.data.fun_decl.is_suspend = true;
        try markSuspensionPoints(node.data.fun_decl.body, registry, global_functions, &suspend_set, allocator);
    }
}

fn hasAnnotation(annotations: []const ast.Annotation, name: []const u8) bool {
    for (annotations) |ann| {
        if (std.mem.eql(u8, ann.name, name)) return true;
    }
    return false;
}

fn resolveCalleeName(node: *ASTNode) ?[]const u8 {
    switch (node.data) {
        .identifier => |i| {
            if (i.resolved_c_name) |rcn| return rcn;
            if (node.resolved_type) |rt| {
                if (rt.* == .Function and rt.Function.c_name.len > 0) return rt.Function.c_name;
            }
            return null;
        },
        .get_expr => |g| {
            if (g.resolved_c_name) |rcn| return rcn;
            if (node.resolved_type) |rt| {
                if (rt.* == .Function and rt.Function.c_name.len > 0) return rt.Function.c_name;
            }
            return null;
        },
        else => return null,
    }
}

/// True when the resolved callee of a call is annotated `@Coroutine`.
fn isCoroutineCall(c: anytype, global_functions: *std.StringHashMap(*ASTNode)) bool {
    const c_name = resolveCalleeName(c.callee) orelse return false;
    const callee_node = global_functions.get(c_name) orelse return false;
    if (callee_node.data != .fun_decl) return false;
    return hasAnnotation(callee_node.data.fun_decl.annotations, "Coroutine");
}

/// True when the call targets a method declared `@Suspend`. Resolution is
/// declaration-based: the receiver type + method name are matched against the
/// class/contract/object methods in every registered module. This is required
/// because contract-typed receivers (e.g. `val t: Awaitable<T> = task { ... }`)
/// never carry a resolved c_name on the callee — only the return type.
fn isSuspendDecl(c: anytype, registry: *ModuleRegistry, global_functions: *std.StringHashMap(*ASTNode)) bool {
    if (c.callee.resolved_type) |rt| {
        if (rt.* == .Function and rt.Function.c_name.len > 0) {
            if (functionHasSuspend(global_functions, rt.Function.c_name)) return true;
        }
    }
    if (c.callee.data == .get_expr) {
        const g = c.callee.data.get_expr;
        const recv = g.object.resolved_type orelse return false;
        const base = ts.extractBaseType(recv).*;
        switch (base) {
            .Custom => |name| {
                if (findMethodHasSuspend(registry, name, g.name)) return true;
            },
            .GenericInstance => |gi| {
                if (findMethodHasSuspend(registry, gi.base_name, g.name)) return true;
            },
            else => {},
        }
    }
    return false;
}

fn functionHasSuspend(global_functions: *std.StringHashMap(*ASTNode), c_name: []const u8) bool {
    const node = global_functions.get(c_name) orelse return false;
    if (node.data != .fun_decl) return false;
    return hasAnnotation(node.data.fun_decl.annotations, "Suspend");
}

/// Searches every module for a type named `type_name` (class, contract or
/// object) and returns whether it declares a method `method_name` with `@Suspend`.
fn findMethodHasSuspend(registry: *ModuleRegistry, type_name: []const u8, method_name: []const u8) bool {
    var mod_it = registry.modules.iterator();
    while (mod_it.next()) |entry| {
        const checker = entry.value_ptr.checker;
        if (findInClass(checker, type_name, method_name)) return true;
        if (findInContract(checker, type_name, method_name)) return true;
        if (findInObject(checker, type_name, method_name)) return true;
    }
    return false;
}

fn findInClass(checker: *tc_core.TypeChecker, type_name: []const u8, method_name: []const u8) bool {
    const class_node = checker.classes_ast.get(type_name) orelse return false;
    if (class_node.data != .type_decl) return false;
    for (class_node.data.type_decl.methods) |method| {
        if (method.data == .fun_decl and std.mem.eql(u8, method.data.fun_decl.name, method_name)) {
            return hasAnnotation(method.data.fun_decl.annotations, "Suspend");
        }
    }
    return false;
}

fn findInContract(checker: *tc_core.TypeChecker, type_name: []const u8, method_name: []const u8) bool {
    const contract_node = checker.contracts_ast.get(type_name) orelse return false;
    if (contract_node.data != .contract_decl) return false;
    for (contract_node.data.contract_decl.methods) |method| {
        if (method.data == .fun_decl and std.mem.eql(u8, method.data.fun_decl.name, method_name)) {
            return hasAnnotation(method.data.fun_decl.annotations, "Suspend");
        }
    }
    return false;
}

fn findInObject(checker: *tc_core.TypeChecker, type_name: []const u8, method_name: []const u8) bool {
    const object_node = checker.objects_ast.get(type_name) orelse return false;
    if (object_node.data != .object_decl) return false;
    for (object_node.data.object_decl.members) |member| {
        if (member.data == .fun_decl and std.mem.eql(u8, member.data.fun_decl.name, method_name)) {
            return hasAnnotation(member.data.fun_decl.annotations, "Suspend");
        }
    }
    return false;
}

fn callIsSuspend(c: anytype, registry: *ModuleRegistry, global_functions: *std.StringHashMap(*ASTNode), suspend_set: *std.StringHashMap(void)) bool {
    if (isSuspendDecl(c, registry, global_functions)) return true;
    if (resolveCalleeName(c.callee)) |c_name| {
        if (suspend_set.contains(c_name)) return true;
    }
    return false;
}

fn bodyCallsSuspend(body: *ASTNode, registry: *ModuleRegistry, global_functions: *std.StringHashMap(*ASTNode), suspend_set: *std.StringHashMap(void), allocator: std.mem.Allocator) bool {
    var found = false;
    var vis = std.StringHashMap(void).init(allocator);
    defer vis.deinit();
    walkForSuspend(body, registry, global_functions, suspend_set, &vis, &found);
    return found;
}

fn walkForSuspend(node: *ASTNode, registry: *ModuleRegistry, global_functions: *std.StringHashMap(*ASTNode), suspend_set: *std.StringHashMap(void), vis: *std.StringHashMap(void), found: *bool) void {
    if (found.*) return;
    if (node.data == .call_expr) {
        const c = &node.data.call_expr;
        if (callIsSuspend(c, registry, global_functions, suspend_set)) {
            found.* = true;
            return;
        }
        if (isCoroutineCall(c, global_functions)) {
            // Suspension inside the spawned lambda belongs to that coroutine.
            return;
        }
    }
    walkChildren(node, registry, global_functions, suspend_set, vis, found);
}

fn walkChildren(node: *ASTNode, registry: *ModuleRegistry, global_functions: *std.StringHashMap(*ASTNode), suspend_set: *std.StringHashMap(void), vis: *std.StringHashMap(void), found: *bool) void {
    switch (node.data) {
        .call_expr => |c| {
            walkForSuspend(c.callee, registry, global_functions, suspend_set, vis, found);
            for (c.arguments) |arg| walkForSuspend(arg, registry, global_functions, suspend_set, vis, found);
        },
        .var_decl => |v| {
            if (v.initializer) |init| walkForSuspend(init, registry, global_functions, suspend_set, vis, found);
        },
        .fun_decl => |f| walkForSuspend(f.body, registry, global_functions, suspend_set, vis, found),
        .type_decl => |td| {
            for (td.methods) |m| walkForSuspend(m, registry, global_functions, suspend_set, vis, found);
        },
        .object_decl => |o| {
            for (o.members) |m| walkForSuspend(m, registry, global_functions, suspend_set, vis, found);
        },
        .lib_decl => |l| {
            for (l.functions) |f| walkForSuspend(f, registry, global_functions, suspend_set, vis, found);
        },
        .test_decl => |t| walkForSuspend(t.body, registry, global_functions, suspend_set, vis, found),
        .block => |b| {
            for (b.statements) |s| walkForSuspend(s, registry, global_functions, suspend_set, vis, found);
        },
        .unary_expr => |u| walkForSuspend(u.operand, registry, global_functions, suspend_set, vis, found),
        .binary_expr => |b| {
            walkForSuspend(b.left, registry, global_functions, suspend_set, vis, found);
            walkForSuspend(b.right, registry, global_functions, suspend_set, vis, found);
        },
        .if_expr => |i| {
            walkForSuspend(i.condition, registry, global_functions, suspend_set, vis, found);
            walkForSuspend(i.then_branch, registry, global_functions, suspend_set, vis, found);
            if (i.else_branch) |e| walkForSuspend(e, registry, global_functions, suspend_set, vis, found);
        },
        .ternary_expr => |t| {
            walkForSuspend(t.condition, registry, global_functions, suspend_set, vis, found);
            walkForSuspend(t.then_branch, registry, global_functions, suspend_set, vis, found);
            if (t.else_branch) |e| walkForSuspend(e, registry, global_functions, suspend_set, vis, found);
        },
        .index_expr => |i| {
            walkForSuspend(i.object, registry, global_functions, suspend_set, vis, found);
            walkForSuspend(i.index, registry, global_functions, suspend_set, vis, found);
        },
        .index_set_expr => |i| {
            walkForSuspend(i.object, registry, global_functions, suspend_set, vis, found);
            walkForSuspend(i.index, registry, global_functions, suspend_set, vis, found);
            walkForSuspend(i.value, registry, global_functions, suspend_set, vis, found);
        },
        .assignment => |a| walkForSuspend(a.value, registry, global_functions, suspend_set, vis, found),
        .get_expr => |g| walkForSuspend(g.object, registry, global_functions, suspend_set, vis, found),
        .set_expr => |s| {
            walkForSuspend(s.object, registry, global_functions, suspend_set, vis, found);
            walkForSuspend(s.value, registry, global_functions, suspend_set, vis, found);
        },
        .while_stmt => |w| {
            walkForSuspend(w.condition, registry, global_functions, suspend_set, vis, found);
            walkForSuspend(w.body, registry, global_functions, suspend_set, vis, found);
        },
        .for_stmt => |f| {
            walkForSuspend(f.iterable, registry, global_functions, suspend_set, vis, found);
            walkForSuspend(f.body, registry, global_functions, suspend_set, vis, found);
        },
        .return_stmt => |r| {
            if (r.value) |v| walkForSuspend(v, registry, global_functions, suspend_set, vis, found);
        },
        .as_expr => |a| walkForSuspend(a.value, registry, global_functions, suspend_set, vis, found),
        .is_expr => |i| walkForSuspend(i.value, registry, global_functions, suspend_set, vis, found),
        .try_stmt => |t| {
            walkForSuspend(t.body, registry, global_functions, suspend_set, vis, found);
            for (t.catches) |c| walkForSuspend(c.body, registry, global_functions, suspend_set, vis, found);
        },
        .throw_stmt => |t| walkForSuspend(t.expr, registry, global_functions, suspend_set, vis, found),
        .when_expr => |w| {
            if (w.subject) |s| walkForSuspend(s, registry, global_functions, suspend_set, vis, found);
            for (w.cases) |case| {
                for (case.conds) |cond| walkForSuspend(cond, registry, global_functions, suspend_set, vis, found);
                walkForSuspend(case.body, registry, global_functions, suspend_set, vis, found);
            }
        },
        .lambda_expr => |l| {
            for (l.body) |stmt| walkForSuspend(stmt, registry, global_functions, suspend_set, vis, found);
        },
        .named_arg => |na| walkForSuspend(na.value, registry, global_functions, suspend_set, vis, found),
        .array_literal => |al| {
            for (al.elements) |e| walkForSuspend(e, registry, global_functions, suspend_set, vis, found);
        },
        .map_literal => |ml| {
            for (ml.elements) |e| walkForSuspend(e, registry, global_functions, suspend_set, vis, found);
        },
        else => {},
    }
}

/// Marks `call_expr.is_suspend_call` on suspension points.
fn markSuspensionPoints(node: *ASTNode, registry: *ModuleRegistry, global_functions: *std.StringHashMap(*ASTNode), suspend_set: *std.StringHashMap(void), allocator: std.mem.Allocator) !void {
    var vis = std.StringHashMap(void).init(allocator);
    defer vis.deinit();
    try markWalk(node, registry, global_functions, suspend_set, &vis);
}

fn markWalk(node: *ASTNode, registry: *ModuleRegistry, global_functions: *std.StringHashMap(*ASTNode), suspend_set: *std.StringHashMap(void), vis: *std.StringHashMap(void)) !void {
    if (node.data == .call_expr) {
        const c = &node.data.call_expr;
        if (callIsSuspend(c, registry, global_functions, suspend_set)) {
            c.is_suspend_call = true;
        }
        if (isCoroutineCall(c, global_functions)) {
            // Suspension inside the spawned lambda belongs to that coroutine;
            // do not descend into its arguments.
            return;
        }
    }
    switch (node.data) {
        .call_expr => |c| {
            try markWalk(c.callee, registry, global_functions, suspend_set, vis);
            for (c.arguments) |arg| try markWalk(arg, registry, global_functions, suspend_set, vis);
        },
        .var_decl => |v| {
            if (v.initializer) |init| try markWalk(init, registry, global_functions, suspend_set, vis);
        },
        .fun_decl => |f| try markWalk(f.body, registry, global_functions, suspend_set, vis),
        .type_decl => |td| {
            for (td.methods) |m| try markWalk(m, registry, global_functions, suspend_set, vis);
        },
        .object_decl => |o| {
            for (o.members) |m| try markWalk(m, registry, global_functions, suspend_set, vis);
        },
        .lib_decl => |l| {
            for (l.functions) |f| try markWalk(f, registry, global_functions, suspend_set, vis);
        },
        .test_decl => |t| try markWalk(t.body, registry, global_functions, suspend_set, vis),
        .block => |b| {
            for (b.statements) |s| try markWalk(s, registry, global_functions, suspend_set, vis);
        },
        .unary_expr => |u| try markWalk(u.operand, registry, global_functions, suspend_set, vis),
        .binary_expr => |b| {
            try markWalk(b.left, registry, global_functions, suspend_set, vis);
            try markWalk(b.right, registry, global_functions, suspend_set, vis);
        },
        .if_expr => |i| {
            try markWalk(i.condition, registry, global_functions, suspend_set, vis);
            try markWalk(i.then_branch, registry, global_functions, suspend_set, vis);
            if (i.else_branch) |e| try markWalk(e, registry, global_functions, suspend_set, vis);
        },
        .ternary_expr => |t| {
            try markWalk(t.condition, registry, global_functions, suspend_set, vis);
            try markWalk(t.then_branch, registry, global_functions, suspend_set, vis);
            if (t.else_branch) |e| try markWalk(e, registry, global_functions, suspend_set, vis);
        },
        .index_expr => |i| {
            try markWalk(i.object, registry, global_functions, suspend_set, vis);
            try markWalk(i.index, registry, global_functions, suspend_set, vis);
        },
        .index_set_expr => |i| {
            try markWalk(i.object, registry, global_functions, suspend_set, vis);
            try markWalk(i.index, registry, global_functions, suspend_set, vis);
            try markWalk(i.value, registry, global_functions, suspend_set, vis);
        },
        .assignment => |a| try markWalk(a.value, registry, global_functions, suspend_set, vis),
        .get_expr => |g| try markWalk(g.object, registry, global_functions, suspend_set, vis),
        .set_expr => |s| {
            try markWalk(s.object, registry, global_functions, suspend_set, vis);
            try markWalk(s.value, registry, global_functions, suspend_set, vis);
        },
        .while_stmt => |w| {
            try markWalk(w.condition, registry, global_functions, suspend_set, vis);
            try markWalk(w.body, registry, global_functions, suspend_set, vis);
        },
        .for_stmt => |f| {
            try markWalk(f.iterable, registry, global_functions, suspend_set, vis);
            try markWalk(f.body, registry, global_functions, suspend_set, vis);
        },
        .return_stmt => |r| {
            if (r.value) |v| try markWalk(v, registry, global_functions, suspend_set, vis);
        },
        .as_expr => |a| try markWalk(a.value, registry, global_functions, suspend_set, vis),
        .is_expr => |i| try markWalk(i.value, registry, global_functions, suspend_set, vis),
        .try_stmt => |t| {
            try markWalk(t.body, registry, global_functions, suspend_set, vis);
            for (t.catches) |c| try markWalk(c.body, registry, global_functions, suspend_set, vis);
        },
        .throw_stmt => |t| try markWalk(t.expr, registry, global_functions, suspend_set, vis),
        .when_expr => |w| {
            if (w.subject) |s| try markWalk(s, registry, global_functions, suspend_set, vis);
            for (w.cases) |case| {
                for (case.conds) |cond| try markWalk(cond, registry, global_functions, suspend_set, vis);
                try markWalk(case.body, registry, global_functions, suspend_set, vis);
            }
        },
        .lambda_expr => |l| {
            for (l.body) |stmt| try markWalk(stmt, registry, global_functions, suspend_set, vis);
        },
        .named_arg => |na| try markWalk(na.value, registry, global_functions, suspend_set, vis),
        .array_literal => |al| {
            for (al.elements) |e| try markWalk(e, registry, global_functions, suspend_set, vis);
        },
        .map_literal => |ml| {
            for (ml.elements) |e| try markWalk(e, registry, global_functions, suspend_set, vis);
        },
        else => {},
    }
}
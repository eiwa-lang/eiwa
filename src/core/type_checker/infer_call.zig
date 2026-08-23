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

/// Returns the declared field type when `member_name` is a constructor
/// property or body field (NOT a method) of the concrete type `base_type`.
/// Used to give function-typed struct fields precedence over same-named
/// methods composed from auto-injected skills (e.g. `Scope.run(block)` must
/// not shadow a `val run: () -> Int` field).
fn lookupDeclaredField(self: *TypeChecker, base_type: *const EiwaType, member_name: []const u8) ?*const EiwaType {
    var name_opt: ?[]const u8 = null;
    switch (base_type.*) {
        .Custom => |n| name_opt = n,
        .GenericInstance => |gi| {
            const actual_gi_base = self.alias_map.get(gi.base_name) orelse gi.base_name;
            var mangled = ArrayList(u8).init(self.allocator);
            mangled.appendSlice(actual_gi_base) catch return null;
            mangled.appendSlice("_") catch return null;
            for (gi.type_args, 0..) |t_arg, idx| {
                if (idx > 0) mangled.appendSlice("_") catch return null;
                t_arg.formatSafe(mangled.writer()) catch return null;
            }
            name_opt = mangled.toOwnedSlice() catch return null;
        },
        else => return null,
    }
    if (name_opt == null) return null;
    const actual_name = self.alias_map.get(name_opt.?) orelse name_opt.?;
    var class_node_opt = self.classes_ast.get(actual_name);
    if (class_node_opt == null and self.registry != null) {
        var mod_it = self.registry.?.modules.iterator();
        while (mod_it.next()) |entry| {
            const mod_actual = entry.value_ptr.checker.alias_map.get(actual_name) orelse actual_name;
            if (entry.value_ptr.checker.classes_ast.get(mod_actual)) |bn| {
                class_node_opt = bn;
                break;
            }
        }
    }
    if (class_node_opt == null) return null;
    const c = class_node_opt.?.data.type_decl;
    for (c.primary_constructor) |prop| {
        if (std.mem.eql(u8, prop.name, member_name)) {
            return prop.resolved_type orelse (self.resolveTypeRef(prop.type_ref) catch null);
        }
    }
    for (c.body_fields) |prop| {
        if (std.mem.eql(u8, prop.name, member_name)) {
            return prop.resolved_type orelse (self.resolveTypeRef(prop.type_ref) catch null);
        }
    }
    return null;
}

fn createGetExprNode(self: *TypeChecker, obj_name: []const u8, resolved_c_name: ?[]const u8, member_name: []const u8, line: usize, column: usize) !*ASTNode {
    const obj_ident = try self.allocator.create(ASTNode);
    obj_ident.* = .{
        .line = line,
        .column = column,
        .resolved_type = null,
        .data = .{ .identifier = .{
            .name = obj_name,
            .resolved_c_name = resolved_c_name,
            .is_class_property = false,
            .is_boxed = false,
        } },
    };

    const get_expr_node = try self.allocator.create(ASTNode);
    get_expr_node.* = .{
        .line = line,
        .column = column,
        .resolved_type = null,
        .data = .{ .get_expr = .{
            .object = obj_ident,
            .name = member_name,
            .is_safe = false,
        } },
    };
    return get_expr_node;
}

pub fn substituteParam(self: *TypeChecker, target_node: *ASTNode, param_name: []const u8, replacement: *ASTNode) anyerror!void {
    switch (target_node.data) {
        .identifier => |*id| {
            if (std.mem.eql(u8, id.name, param_name)) {
                const cloned_repl = try self.cloneNode(replacement);
                target_node.data = cloned_repl.data;
                target_node.resolved_type = cloned_repl.resolved_type;
            }
        },
        .binary_expr => |*b| {
            try self.substituteParam(b.left, param_name, replacement);
            try self.substituteParam(b.right, param_name, replacement);
        },
        .unary_expr => |*u| {
            try self.substituteParam(u.operand, param_name, replacement);
        },
        .call_expr => |*c| {
            try self.substituteParam(c.callee, param_name, replacement);
            for (c.arguments) |arg| {
                try self.substituteParam(arg, param_name, replacement);
            }
        },
        .get_expr => |*g| {
            try self.substituteParam(g.object, param_name, replacement);
        },
        .index_expr => |*idx| {
            try self.substituteParam(idx.object, param_name, replacement);
            try self.substituteParam(idx.index, param_name, replacement);
        },
        .if_expr => |*i| {
            try self.substituteParam(i.condition, param_name, replacement);
            try self.substituteParam(i.then_branch, param_name, replacement);
            if (i.else_branch) |eb| try self.substituteParam(eb, param_name, replacement);
        },
        .ternary_expr => |*t| {
            try self.substituteParam(t.condition, param_name, replacement);
            try self.substituteParam(t.then_branch, param_name, replacement);
            if (t.else_branch) |eb| try self.substituteParam(eb, param_name, replacement);
        },
        .as_expr => |*a| {
            try self.substituteParam(a.value, param_name, replacement);
        },
        .is_expr => |*is_e| {
            try self.substituteParam(is_e.value, param_name, replacement);
        },
        .array_literal => |*arr| {
            for (arr.elements) |elem| {
                try self.substituteParam(elem, param_name, replacement);
            }
        },
        .named_arg => |*na| {
            try self.substituteParam(na.value, param_name, replacement);
        },
        else => {},
    }
}

/// True when any call argument is a named argument (`name = value`). Such
/// calls must be reordered by `resolveCallArguments` before reaching a backend,
/// otherwise named_arg nodes leak into the emitters.
fn hasNamedArgs(arguments: []const *ASTNode) bool {
    for (arguments) |arg| {
        if (arg.data == .named_arg) return true;
    }
    return false;
}

pub fn resolveCallArguments(self: *TypeChecker, node: *ASTNode, params: []const ast.Param, scope: *Scope) anyerror!void {
    var c = &node.data.call_expr;
    var has_named = false;
    for (c.arguments) |arg| {
        if (arg.data == .named_arg) {
            has_named = true;
            break;
        }
    }

    const has_varargs = params.len > 0 and params[params.len - 1].is_varargs;
    const varargs_idx: ?usize = if (has_varargs) params.len - 1 else null;

    if (!has_named and c.arguments.len == params.len and !has_varargs) return;

    var new_args = try self.allocator.alloc(?*ASTNode, params.len);
    for (new_args) |*slot| {
        slot.* = null;
    }

    // Positional args that land on the variadic parameter are collected here and
    // re-emitted as an array literal (`List<T>`) when the call is resolved.
    var varargs_buf = ArrayList(*ASTNode).init(self.allocator);

    var pos_i: usize = 0;
    for (c.arguments) |arg| {
        if (arg.data == .named_arg) {
            const name = arg.data.named_arg.name;
            const val = arg.data.named_arg.value;
            var param_match: ?usize = null;
            for (params, 0..) |p, pi| {
                if (std.mem.eql(u8, p.name, name)) {
                    param_match = pi;
                    break;
                }
            }
            if (param_match) |pi| {
                if (new_args[pi] != null) {
                    self.reportError(arg.line, arg.column, "TypeError: Duplicate argument provided for parameter '{s}'.", .{name});
                    return error.TypeError;
                }
                new_args[pi] = val;
            } else {
                self.reportError(arg.line, arg.column, "TypeError: Unknown parameter '{s}' in function call.", .{name});
                return error.TypeError;
            }
        } else {
            var target_slot: ?usize = null;
            if (arg.data == .lambda_expr) {
                var search_i: usize = pos_i;
                while (search_i < params.len) : (search_i += 1) {
                    if (new_args[search_i] == null) {
                        if (params[search_i].is_varargs) break;
                        if (params[search_i].type_ref) |tr| {
                            if (tr.is_function) {
                                target_slot = search_i;
                                break;
                            }
                        }
                    }
                }
            }

            if (target_slot == null) {
                while (pos_i < params.len and new_args[pos_i] != null) : (pos_i += 1) {}
                if (pos_i >= params.len) {
                    // Varargs overflow: the extra positional arg is collected into the List.
                    if (varargs_idx != null) {
                        try varargs_buf.append(arg);
                        continue;
                    }
                    self.reportError(arg.line, arg.column, "TypeError: Too many positional arguments in call.", .{});
                    return error.TypeError;
                }
                target_slot = pos_i;
            }

            // A positional arg landing directly on the variadic parameter is collected
            // into its List rather than passed as a scalar.
            if (varargs_idx) |vi| {
                if (target_slot.? == vi) {
                    try varargs_buf.append(arg);
                    if (target_slot.? == pos_i) pos_i += 1;
                    continue;
                }
            }

            new_args[target_slot.?] = arg;
            if (target_slot.? == pos_i) pos_i += 1;
        }
    }

    if (varargs_idx) |vi| {
        var elements = try self.allocator.alloc(*ASTNode, varargs_buf.items.len);
        for (varargs_buf.items, 0..) |item, i| {
            elements[i] = item;
        }

        // A named argument may have already provided the variadic List; merge it in.
        if (new_args[vi] != null and elements.len > 0) {
            const existing = new_args[vi].?;
            if (existing.data != .array_literal) {
                self.reportError(node.line, node.column, "TypeError: Cannot combine a named varargs argument with positional varargs arguments.", .{});
                return error.TypeError;
            }
            const merged = try self.allocator.alloc(*ASTNode, existing.data.array_literal.elements.len + elements.len);
            var mi: usize = 0;
            for (existing.data.array_literal.elements) |el| {
                merged[mi] = el;
                mi += 1;
            }
            for (elements) |el| {
                merged[mi] = el;
                mi += 1;
            }
            elements = merged;
        }

        if (new_args[vi] == null or elements.len > 0) {
            const list_node = try self.allocator.create(ASTNode);
            list_node.* = .{ .line = node.line, .column = node.column, .resolved_type = null, .data = .{ .array_literal = .{ .elements = elements } } };
            // Give the empty-list case a target type so `[]` infers as List<T>.
            const elem_t = try self.resolveTypeRef(params[vi].type_ref.?);
            list_node.expected_type = try self.makeListType(elem_t, node.line, node.column);
            _ = try self.inferNode(list_node, scope);
            new_args[vi] = list_node;
        }
    }

    for (params, 0..) |p, pi| {
        if (new_args[pi] == null) {
            if (p.initializer) |init_node| {
                const cloned = try self.cloneNode(init_node);
                for (params[0..pi], 0..) |prev_p, prev_i| {
                    if (new_args[prev_i]) |prev_arg| {
                        try self.substituteParam(cloned, prev_p.name, prev_arg);
                    }
                }
                // Propagate the declared param type so an empty default like
                // `params: List<String> = []` infers (mirrors every other
                // default-fill site).
                if (p.type_ref) |tr| {
                    cloned.expected_type = self.resolveTypeRef(tr) catch null;
                }
                _ = try self.inferNode(cloned, scope);
                new_args[pi] = cloned;
            } else {
                self.reportError(node.line, node.column, "TypeError: Missing argument for parameter '{s}'.", .{p.name});
                return error.TypeError;
            }
        }
    }

    var final_args = try self.allocator.alloc(*ASTNode, params.len);
    for (new_args, 0..) |opt_arg, i| {
        final_args[i] = opt_arg.?;
    }

    c.arguments = final_args;
}

/// Resolves the element type `T` of a variadic parameter declared as `T...`.
/// Returns null when the callee has no variadic parameter.
fn varargsElemType(self: *TypeChecker, fun_decl: anytype) ?*EiwaType {
    if (fun_decl.params.len == 0 or !fun_decl.params[fun_decl.params.len - 1].is_varargs) return null;
    const p = fun_decl.params[fun_decl.params.len - 1];
    if (p.type_ref) |tr| {
        return self.resolveTypeRef(tr) catch null;
    }
    return null;
}

pub fn canMatchOverload(self: *TypeChecker, node: *const ASTNode, fun_decl: anytype, f: anytype, scope: *Scope) bool {
    const c = &node.data.call_expr;
    const has_varargs = fun_decl.params.len > 0 and fun_decl.params[fun_decl.params.len - 1].is_varargs;
    // Varargs: any number of arguments beyond the fixed params is collected into the last List.
    if (c.arguments.len > f.params.len and !has_varargs) return false;

    var pos_i: usize = 0;
    var provided = ArrayList(bool).init(self.allocator);
    var pi_idx: usize = 0;
    while (pi_idx < fun_decl.params.len) : (pi_idx += 1) {
        provided.append(false) catch return false;
    }

    for (c.arguments) |arg| {
        if (arg.data == .named_arg) {
            const arg_name = arg.data.named_arg.name;
            const val_node = arg.data.named_arg.value;
            var match_idx: ?usize = null;
            for (fun_decl.params, 0..) |p, pi| {
                if (std.mem.eql(u8, p.name, arg_name)) {
                    match_idx = pi;
                    break;
                }
            }
            if (match_idx) |pi| {
                provided.items[pi] = true;
                if (val_node.resolved_type == null) {
                    _ = self.inferNode(val_node, scope) catch return false;
                }
                if (val_node.resolved_type) |vt| {
                    if (!self.isCompatible(f.params[pi], vt)) return false;
                }
            } else {
                return false;
            }
        } else if (arg.data == .lambda_expr) {
            var target_slot: ?usize = null;
            var search_i: usize = pos_i;
            while (search_i < f.params.len) : (search_i += 1) {
                if (!provided.items[search_i] and f.params[search_i].* == .Function) {
                    target_slot = search_i;
                    break;
                }
            }
            if (target_slot) |ts| {
                provided.items[ts] = true;
            } else {
                return false;
            }
        } else {
            while (pos_i < f.params.len and provided.items[pos_i]) : (pos_i += 1) {}
            if (pos_i >= f.params.len) {
                // Varargs overflow: the extra arg is collected into the last param's List<T>.
                if (!has_varargs) return false;
                if (arg.resolved_type == null) {
                    _ = self.inferNode(arg, scope) catch return false;
                }
                if (arg.resolved_type) |at| {
                    const elem_t = varargsElemType(self, fun_decl) orelse return false;
                    if (!self.isCompatible(elem_t, at)) return false;
                }
                continue;
            }
            provided.items[pos_i] = true;
            if (arg.resolved_type == null) {
                _ = self.inferNode(arg, scope) catch return false;
            }
            if (arg.resolved_type) |at| {
                // A positional arg for the variadic parameter is checked against its
                // element type `T`; the args are collected into the List at the call site.
                const expected = if (fun_decl.params[pos_i].is_varargs)
                    (varargsElemType(self, fun_decl) orelse return false)
                else
                    f.params[pos_i];
                if (!self.isCompatible(expected, at)) return false;
            }
            pos_i += 1;
        }
    }

    for (fun_decl.params, 0..) |p, pi| {
        if (!provided.items[pi] and p.initializer == null and !p.is_varargs) {
            return false;
        }
    }

    return true;
}

/// `funPointer { lambda }` lifts an inline lambda (typed params, no outer
/// capture — a C function pointer has no context) into a synthetic top-level
/// function and marks the call so the backend emits `&eiwa_cb_<mangled>` — the
/// address of a generated C trampoline that forwards to the Eiwa lambda
/// (Kotlin/Native `staticCFunction`). The expression's type is `Pointer`.
fn inferFunPointer(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) !bool {
    var c = &node.data.call_expr;
    if (c.arguments.len != 1) return false;

    const arg = c.arguments[0];
    if (arg.data != .lambda_expr) {
        self.reportError(node.line, node.column, "TypeError: functionPtr requires a lambda without captures.", .{});
        return error.TypeError;
    }

    // Lift the lambda into a synthetic top-level function so the existing
    // trampoline machinery handles it. It runs in the global scope, so any
    // capture of an outer variable surfaces as an unresolved-identifier error.
    const l = &arg.data.lambda_expr;
    const fn_name = try std.fmt.allocPrint(self.allocator, "__cblambda_{d}_{d}", .{ arg.line, arg.column });

    const lambda_params = try self.allocator.alloc(ast.Param, l.params.len);
    @memcpy(lambda_params, l.params);

    var body_stmts = try self.allocator.alloc(*ASTNode, l.body.len);
    for (l.body, 0..) |stmt, i| {
        if (i == l.body.len - 1 and l.body.len > 0) {
            const ret = try self.allocator.create(ASTNode);
            ret.* = .{ .line = stmt.line, .column = stmt.column, .resolved_type = null, .data = .{ .return_stmt = .{ .value = stmt } } };
            body_stmts[i] = ret;
        } else {
            body_stmts[i] = stmt;
        }
    }
    const block = try self.allocator.create(ASTNode);
    block.* = .{ .line = arg.line, .column = arg.column, .resolved_type = null, .data = .{ .block = .{ .statements = body_stmts } } };

    const fn_node = try self.allocator.create(ASTNode);
    fn_node.* = .{ .line = arg.line, .column = arg.column, .resolved_type = null, .data = .{ .fun_decl = .{
        .annotations = &.{},
        .modifiers = &.{},
        .name = fn_name,
        .generic_params = &.{},
        .params = lambda_params,
        .type_ref = null,
        .body = block,
        .is_expr_body = false,
        .resolved_c_name = fn_name,
    } } };

    try self.monomorphized_nodes.append(fn_node);
    _ = try self.inferNode(arg, scope);
    _ = try self.inferNode(fn_node, &self.global_scope);

    // The synthetic fun_decl infers `Void` from a block body; adopt the
    // lambda's actual return type so the emitted C signature matches.
    if (arg.resolved_type) |lambda_rt| {
        const lr = extractBaseType(lambda_rt);
        if (lr.* == .Function) {
            if (fn_node.resolved_type) |frt| {
                if (frt.* == .Function) {
                    @constCast(frt).Function.return_type = lr.Function.return_type;
                }
            }
        }
    }

    const fn_decl = &fn_node.data.fun_decl;
    const tramp_name = try std.fmt.allocPrint(self.allocator, "eiwa_cb_{s}", .{fn_decl.resolved_c_name orelse fn_decl.name});
    c.c_fn_ptr = tramp_name;
    try self.trampolines.put(tramp_name, fn_node);
    const inner_t = try self.allocator.create(EiwaType);
    inner_t.* = .Void;
    t.* = .{ .Pointer = inner_t };
    node.resolved_type = t;
    return true;
}

fn inferExplicitGenericMethodCall(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) !bool {
    var c = &node.data.call_expr;
    if (c.callee.data != .get_expr or c.type_args.len == 0) return false;

    const g = &c.callee.data.get_expr;
    _ = try self.inferNode(g.object, scope);
    if (g.object.resolved_type) |obj_type| {
        const base_type = extractBaseType(obj_type);
        if (base_type.* == .Custom) {
            const class_name = base_type.Custom;
            const actual_class_name = self.alias_map.get(class_name) orelse class_name;
            const methods_list: ?[]const *ASTNode = if (self.classes_ast.get(actual_class_name)) |cn| cn.data.type_decl.methods else if (self.objects_ast.get(actual_class_name)) |on| on.data.object_decl.members else null;
            if (methods_list) |methods| {
                for (methods) |method| {
                    if (method.data == .fun_decl and std.mem.eql(u8, method.data.fun_decl.name, g.name) and method.data.fun_decl.generic_params.len > 0) {
                        const method_decl = method.data.fun_decl;
                        if (method_decl.generic_params.len != c.type_args.len) {
                            self.reportError(node.line, node.column, "TypeError: Expected {} generic arguments for method '{s}', got {}.", .{method_decl.generic_params.len, g.name, c.type_args.len});
                            return error.TypeError;
                        }
                        var type_args = try self.allocator.alloc(*const EiwaType, c.type_args.len);
                        for (c.type_args, 0..) |type_ref, i| {
                            type_args[i] = try self.resolveTypeRef(type_ref);
                        }

                        var mangled = ArrayList(u8).init(self.allocator);
                        try mangled.appendSlice(class_name);
                        try mangled.appendSlice("_");
                        try mangled.appendSlice(g.name);
                        for (type_args) |type_arg| {
                            try mangled.appendSlice("_");
                            try type_arg.formatSafe(mangled.writer());
                        }
                        const final_mangled = try mangled.toOwnedSlice();
                        // Object methods are static: no receiver (unlike type methods).
                        const is_object = self.objects_ast.get(actual_class_name) != null;
                        try self.monomorphizeFunction(g.name, type_args, final_mangled, if (is_object) null else base_type);

                        const func_node = self.functions_ast.get(final_mangled) orelse {
                            self.reportError(node.line, node.column, "TypeError: Monomorphized function '{s}' not found (expected key: '{s}').", .{g.name, final_mangled});
                            return error.TypeError;
                        };
                        const actual_c_name = func_node.data.fun_decl.resolved_c_name orelse final_mangled;
                        const func_decl = func_node.data.fun_decl;
                        const ret_type = func_node.resolved_type.?.Function.return_type;

                        try resolveCallArguments(self, node, func_decl.params, scope);

                        for (c.arguments, 0..) |arg, arg_i| {
                            if (arg_i < func_decl.params.len) {
                                const param_type = if (func_decl.params[arg_i].type_ref) |tr| self.resolveTypeRef(tr) catch null else null;
                                if (param_type) |pt| {
                                    arg.expected_type = pt;
                                    if (arg.resolved_type == null) {
                                        _ = try self.inferNode(arg, scope);
                                    }
                                    if (!self.isCompatible(pt, arg.resolved_type.?)) {
                                        self.reportError(arg.line, arg.column, "TypeError: Expected {} but found {} for argument {}.", .{ pt.*, arg.resolved_type.?.*, arg_i + 1 });
                                        return error.TypeError;
                                    }
                                }
                            }
                        }

                        t.* = ret_type.*;
                        if (is_object) {
                            // Object methods are static: call without a receiver.
                            c.callee.data = .{ .identifier = .{
                                .name = g.name,
                                .resolved_c_name = actual_c_name,
                            } };
                            return true;
                        }
                        var call_args = try self.allocator.alloc(*ASTNode, c.arguments.len + 1);
                        call_args[0] = g.object;
                        for (c.arguments, 0..) |a, ai| {
                            call_args[ai + 1] = a;
                        }
                        c.arguments = call_args;
                        c.callee.data = .{ .identifier = .{
                            .name = g.name,
                            .resolved_c_name = actual_c_name,
                        } };
                        return true;
                    }
                }
            }
        }
    }
    self.reportError(node.line, node.column, "TypeError: Generic method '{s}' with type arguments not found.", .{g.name});
    return error.TypeError;
}

fn inferExplicitGenericCall(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) !bool {
    var c = &node.data.call_expr;
    if (c.callee.data != .identifier or c.type_args.len == 0) return false;

    const name = c.callee.data.identifier.name;
    const class_name = self.alias_map.get(name) orelse name;
    const class_node = self.classes_ast.get(class_name);
    if (class_node == null) {
        // Try as a generic function
        if (self.lookupGenericFunction(name) != null) {
            var type_args = try self.allocator.alloc(*const EiwaType, c.type_args.len);
            for (c.type_args, 0..) |type_ref, i| {
                type_args[i] = try self.resolveTypeRef(type_ref);
            }

            var mangled = ArrayList(u8).init(self.allocator);
            try mangled.appendSlice(name);
            for (type_args) |type_arg| {
                try mangled.appendSlice("_");
                try type_arg.formatSafe(mangled.writer());
            }
            const final_mangled = try mangled.toOwnedSlice();

            try self.monomorphizeFunction(name, type_args, final_mangled, null);

            const actual_c_name_3 = blk_3: {
                if (self.functions_ast.get(final_mangled)) |fn_node| {
                    if (fn_node.data.fun_decl.resolved_c_name) |rcn| break :blk_3 rcn;
                }
                break :blk_3 final_mangled;
            };
            const func_node = self.functions_ast.get(actual_c_name_3).?;
            const fun_decl = &func_node.data.fun_decl;
            const ret_type = func_node.resolved_type.?.Function.return_type;

            try resolveCallArguments(self, node, fun_decl.params, scope);

            for (c.arguments, 0..) |arg, arg_i| {
                if (arg_i < fun_decl.params.len) {
                    const param_type = if (fun_decl.params[arg_i].type_ref) |tr| self.resolveTypeRef(tr) catch null else null;
                    if (param_type) |pt| {
                        arg.expected_type = pt;
                        if (arg.resolved_type == null) {
                            _ = try self.inferNode(arg, scope);
                        }
                        if (!self.isCompatible(pt, arg.resolved_type.?)) {
                            self.reportError(arg.line, arg.column, "TypeError: Expected {} but found {} for argument {}.", .{ pt.*, arg.resolved_type.?.*, arg_i + 1 });
                            return error.TypeError;
                        }
                    }
                }
            }

            t.* = ret_type.*;
            c.callee.data.identifier.resolved_c_name = actual_c_name_3;
            return true;
        }
        self.reportError(node.line, node.column, "TypeError: Generic class '{s}' not found.", .{name});
        return error.TypeError;
    }
    const class_node_uw = class_node.?;
    const type_decl = class_node_uw.data.type_decl;
    if (type_decl.generic_params.len != c.type_args.len) {
        self.reportError(node.line, node.column, "TypeError: Expected {} generic arguments for '{s}', got {}.", .{ type_decl.generic_params.len, name, c.type_args.len });
        return error.TypeError;
    }

    var type_args = try self.allocator.alloc(*const EiwaType, c.type_args.len);
    for (c.type_args, 0..) |type_ref, i| {
        type_args[i] = try self.resolveTypeRef(type_ref);
    }

    const base_name = type_decl.resolved_c_name orelse class_name;
    var mangled = ArrayList(u8).init(self.allocator);
    try mangled.appendSlice(base_name);
    try mangled.appendSlice("_");
    for (type_args, 0..) |type_arg, i| {
        if (i > 0) try mangled.appendSlice("_");
        try type_arg.formatSafe(mangled.writer());
    }
    const final_mangled = try mangled.toOwnedSlice();

    try self.monomorphizeClass(base_name, type_args, final_mangled);
    const mono_node = self.classes_ast.get(final_mangled).?;
    const mono_decl = mono_node.data.type_decl;

    if (c.arguments.len < mono_decl.primary_constructor.len) {
        var new_args = try self.allocator.alloc(*ASTNode, mono_decl.primary_constructor.len);
        for (c.arguments, 0..) |arg, arg_i| {
            new_args[arg_i] = arg;
        }
        var i = c.arguments.len;
        while (i < mono_decl.primary_constructor.len) : (i += 1) {
            const prop = mono_decl.primary_constructor[i];
            if (prop.initializer) |init_node| {
                const cloned = try self.cloneNode(init_node);
                cloned.expected_type = prop.resolved_type orelse self.resolveTypeRef(prop.type_ref) catch null;
                new_args[i] = cloned;
                _ = try self.inferNode(cloned, scope);
            } else {
                self.reportError(node.line, node.column, "TypeError: Missing argument for generic constructor parameter '{s}' of '{s}' which has no default value.", .{ prop.name, name });
                return error.TypeError;
            }
        }
        c.arguments = new_args;
    } else if (c.arguments.len > mono_decl.primary_constructor.len) {
        self.reportError(node.line, node.column, "TypeError: Expected at most {} arguments for generic constructor of '{s}', got {}.", .{ mono_decl.primary_constructor.len, name, c.arguments.len });
        return error.TypeError;
    }

    for (c.arguments, 0..) |arg, arg_i| {
        const expected = mono_decl.primary_constructor[arg_i].resolved_type orelse try self.resolveTypeRef(mono_decl.primary_constructor[arg_i].type_ref);
        if (arg.resolved_type == null) {
            // Lambdas are not pre-inferred; give them the param type as context
            arg.expected_type = expected;
            _ = try self.inferNode(arg, scope);
        }
        if (arg.resolved_type == null or !self.isCompatible(expected, arg.resolved_type.?)) {
            self.reportError(arg.line, arg.column, "TypeError: Expected {} for argument {} of '{s}', got {}.", .{ expected.*, arg_i + 1, name, arg.resolved_type.?.* });
            return error.TypeError;
        }
    }

    const actual_mangled = self.alias_map.get(final_mangled) orelse final_mangled;
    t.* = .{ .Custom = actual_mangled };
    c.callee.data.identifier.resolved_c_name = actual_mangled;
    return true;
}

fn inferImplicitThisOrObjectCall(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType, name: []const u8) !bool {
    var c = &node.data.call_expr;
    if (scope.lookupVariable("this")) |_| {
        c.callee = try createGetExprNode(self, "this", null, name, node.line, node.column);
        try inferCallExpr(self, node, scope, t);
        return true;
    } else if (self.current_class_name) |class_name| {
        const actual_class_name = self.alias_map.get(class_name) orelse class_name;
        if (self.objects_ast.get(actual_class_name)) |obj_node| {
            const obj = obj_node.data.object_decl;
            for (obj.members) |m| {
                if (m.data == .fun_decl and std.mem.eql(u8, m.data.fun_decl.name, name)) {
                    c.callee = try createGetExprNode(self, class_name, actual_class_name, name, node.line, node.column);
                    try inferCallExpr(self, node, scope, t);
                    return true;
                }
            }
        }
    }
    return false;
}

pub fn inferCallExpr(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    var c = &node.data.call_expr;

    // `funPointer { lambda }` — build a C function pointer (trampoline) for an
    // inline lambda without captures.
    if (c.callee.data == .identifier and std.mem.eql(u8, c.callee.data.identifier.name, "funPointer")) {
        if (try inferFunPointer(self, node, scope, t)) return;
    }

    // 1. Infer all arguments that are NOT lambdas
    for (c.arguments) |arg| {
        if (arg.data != .lambda_expr) {
            _ = try self.inferNode(arg, scope);
        }
    }

    if (try inferExplicitGenericMethodCall(self, node, scope, t)) return;
    if (try inferExplicitGenericCall(self, node, scope, t)) return;

    if (c.callee.data == .identifier) {
        const name = c.callee.data.identifier.name;

        // Two-phase lookup for bare function calls:
        // 1. First try local scope (methods on `this`, lambdas with receiver) - Kotlin-style
        // 2. If no compatible match, fall back to global scope (top-level functions)
        // 3. If still no match, fall through to generic functions and variable lookup (handles constructors)
        var best_match: ?*const EiwaType = null;

        // Phase 1: Local scope (methods with receiver) - for lambdas with receiver and type methods
        if (scope.lookupFunctions(name)) |scope_overloads| {
            for (scope_overloads) |overload| {
                if (overload.* != .Function) continue;
                const f = overload.Function;
                if (f.receiver == null) continue; // Only consider methods (with receiver)
                const func_node = self.functions_ast.get(f.c_name) orelse continue;
                const fun_decl = func_node.data.fun_decl;
                
                if (canMatchOverload(self, node, &fun_decl, &f, scope)) {
                    best_match = overload;
                    break;
                }
            }
        }

        // Phase 2: Global functions (no receiver) - top-level functions
        if (best_match == null) {
            if (self.global_scope.lookupFunctions(name)) |global_overloads| {
                for (global_overloads) |overload| {
                    if (overload.* != .Function) continue;
                    const f = overload.Function;
                    if (f.receiver != null) continue; // Skip methods in global scope
                    const func_node = self.functions_ast.get(f.c_name) orelse continue;
                    const fun_decl = func_node.data.fun_decl;
                    
                    if (canMatchOverload(self, node, &fun_decl, &f, scope)) {
                        best_match = overload;
                        break;
                    }
                }
            }
        }

        // Phase 2.5: Scope functions without receiver (object companion methods, etc.)
        if (best_match == null) {
            if (scope.lookupFunctions(name)) |scope_overloads| {
                for (scope_overloads) |overload| {
                    if (overload.* != .Function) continue;
                    const f = overload.Function;
                    if (f.receiver != null) continue;

                    const func_node = self.functions_ast.get(f.c_name) orelse continue;
                    const fun_decl = func_node.data.fun_decl;
                    const has_varargs = fun_decl.params.len > 0 and fun_decl.params[fun_decl.params.len - 1].is_varargs;
                    if (c.arguments.len > f.params.len and !has_varargs) continue;

                    var has_defaults = true;
                    var i = c.arguments.len;
                    while (i < f.params.len) : (i += 1) {
                        if (fun_decl.params[i].initializer == null and !fun_decl.params[i].is_varargs) {
                            has_defaults = false;
                            break;
                        }
                    }
                    if (!has_defaults) continue;

                    var all_match = true;
                    for (c.arguments, 0..) |arg, arg_i| {
                        if (arg.data == .lambda_expr) {
                            if (arg_i >= f.params.len or f.params[arg_i].* != .Function) {
                                all_match = false;
                                break;
                            }
                        } else if (arg_i < f.params.len and !fun_decl.params[arg_i].is_varargs) {
                            if (!self.isCompatible(f.params[arg_i], arg.resolved_type.?)) {
                                all_match = false;
                                break;
                            }
                        } else {
                            // The arg maps to the variadic parameter: check the element type `T`.
                            const elem_t = varargsElemType(self, fun_decl) orelse {
                                all_match = false;
                                break;
                            };
                            if (!self.isCompatible(elem_t, arg.resolved_type.?)) {
                                all_match = false;
                                break;
                            }
                        }
                    }

                    if (all_match) {
                        best_match = overload;
                        break;
                    }
                }
            }
        }

        // Fast path: the callee was already resolved to a concrete function
        // symbol during the first validation pass (static object methods are
        // desugared from `get_expr` into an identifier with `resolved_c_name`).
        // Re-resolving by name fails on re-inference (the coroutines transform
        // re-runs inference over rewritten test/fun bodies), so trust the
        // existing binding.
        if (best_match == null) {
            if (c.callee.data.identifier.resolved_c_name) |rcn| {
                if (self.functions_ast.get(rcn)) |fn_node| {
                    if (fn_node.resolved_type) |ft| {
                        if (ft.* == .Function) {
                            best_match = ft;
                        }
                    }
                }
            }
        }

        if (best_match) |matched| {
            const f = matched.Function;
            const func_node = self.functions_ast.get(f.c_name).?;
            const fun_decl = func_node.data.fun_decl;
            
            try resolveCallArguments(self, node, fun_decl.params, scope);
            
            // Set expected types for all arguments (for C transpiler boxing)
            for (c.arguments, 0..) |arg, arg_i| {
                if (arg_i < f.params.len) {
                    arg.expected_type = f.params[arg_i];
                }
                if (arg.data == .lambda_expr) {
                    _ = try self.inferNode(arg, scope);
                }
            }

                // Double check compatibility of all arguments
                for (c.arguments, 0..) |arg, arg_i| {
                    if (!self.isCompatible(f.params[arg_i], arg.resolved_type.?)) {
                        self.reportError(node.line, node.column, "TypeError: Expected {} for argument {} but got {}.", .{ f.params[arg_i].*, arg_i + 1, arg.resolved_type.?.* });
                        return error.TypeError;
                    }
                }
            
            t.* = matched.Function.return_type.*;
            if (matched.Function.receiver) |rec| {
                const this_node = try self.allocator.create(ASTNode);
                this_node.* = .{
                    .line = c.callee.line,
                    .column = c.callee.column,
                    .resolved_type = rec,
                    .data = .{ .identifier = .{
                        .name = "this",
                        .resolved_c_name = null,
                        .is_class_property = false,
                        .is_boxed = false,
                    } },
                };
                
                const get_expr_node = try self.allocator.create(ASTNode);
                get_expr_node.* = .{
                    .line = c.callee.line,
                    .column = c.callee.column,
                    .resolved_type = matched,
                    .data = .{ .get_expr = .{
                        .object = this_node,
                        .name = name,
                        .is_safe = false,
                        .resolved_c_name = matched.Function.c_name,
                    } },
                };
                
                c.callee = get_expr_node;
            } else {
                c.callee.data = .{ .identifier = .{
                    .name = name,
                    .resolved_c_name = matched.Function.c_name,
                } };
            }
            return;
        }

        // Check for generic functions (not in regular scope because inferFunDecl returns early)
        if (c.type_args.len == 0) {
            if (self.lookupGenericFunction(name)) |gen_node| {
            const gen_decl = gen_node.data.fun_decl;
            if (gen_decl.generic_params.len > 0) {
                var type_args = try self.allocator.alloc(*const EiwaType, gen_decl.generic_params.len);

                var known_types = std.StringHashMap(*const EiwaType).init(self.allocator);
                defer known_types.deinit();
                for (gen_decl.generic_params) |param_name| {
                    for (gen_decl.params, 0..) |p, arg_i| {
                        if (arg_i < c.arguments.len and c.arguments[arg_i].data != .lambda_expr) {
                            if (p.type_ref) |tr| {
                                if (std.mem.eql(u8, tr.name, param_name) and tr.generic_args.len == 0) {
                                    if (c.arguments[arg_i].resolved_type) |rt| {
                                        try known_types.put(param_name, rt);
                                    }
                                }
                            }
                        }
                    }
                }
                for (c.arguments, gen_decl.params, 0..) |arg, p, arg_i| {
                    if (arg_i < c.arguments.len and arg.data == .lambda_expr and arg.resolved_type == null) {
                        if (p.type_ref) |tr| {
                            if (tr.is_function) {
                                // Bind the lambda's expected type with concrete params and an
                                // Unknown return so `it` resolves and any return type is accepted.
                                var exp_params = try self.allocator.alloc(*const EiwaType, tr.generic_args.len);
                                for (tr.generic_args, 0..) |fp, fpi| {
                                    if (known_types.get(fp.name)) |kt| {
                                        exp_params[fpi] = kt;
                                    } else {
                                        exp_params[fpi] = self.resolveTypeRef(fp) catch try self.resolveTypeName("Void", false);
                                    }
                                }
                                const unknown_t = try self.allocator.create(EiwaType);
                                unknown_t.* = .Unknown;
                                const exp_fn = try self.allocator.create(EiwaType);
                                exp_fn.* = .{ .Function = .{
                                    .params = exp_params,
                                    .return_type = unknown_t,
                                    .c_name = "",
                                } };
                                arg.expected_type = exp_fn;
                                _ = try self.inferNode(arg, scope);
                            }
                        }
                    }
                }

                for (gen_decl.generic_params, 0..) |param_name, i| {
                    var found_type: ?*const EiwaType = null;
                    for (gen_decl.params, 0..) |p, arg_i| {
                        if (arg_i < c.arguments.len) {
                            if (p.type_ref) |tr| {
                                if (std.mem.eql(u8, tr.name, param_name) and tr.generic_args.len == 0) {
                                    found_type = c.arguments[arg_i].resolved_type.?;
                                } else if (tr.is_function) {
                                    if (tr.return_type) |ret_tr| {
                                        if (std.mem.eql(u8, ret_tr.name, param_name) and ret_tr.generic_args.len == 0) {
                                            if (c.arguments[arg_i].resolved_type) |arg_t| {
                                                const base_arg = extractBaseType(arg_t);
                                                if (base_arg.* == .Function) {
                                                    found_type = base_arg.Function.return_type;
                                                }
                                            }
                                        }
                                    }
                                    if (found_type == null) {
                                        for (tr.generic_args, 0..) |param_tr, param_idx| {
                                            if (std.mem.eql(u8, param_tr.name, param_name) and param_tr.generic_args.len == 0) {
                                                if (c.arguments[arg_i].resolved_type) |arg_t| {
                                                    const base_arg = extractBaseType(arg_t);
                                                    if (base_arg.* == .Function and param_idx < base_arg.Function.params.len) {
                                                        found_type = base_arg.Function.params[param_idx];
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if (found_type == null) {
                        if (node.expected_type) |exp_t| {
                            found_type = exp_t;
                        }
                    }
                    type_args[i] = found_type orelse {
                        self.reportError(node.line, node.column, "TypeError: Could not infer generic parameter '{s}' for function '{s}'.", .{param_name, name});
                        return error.TypeError;
                    };
                }

                var mangled = ArrayList(u8).init(self.allocator);
                try mangled.appendSlice(name);
                for (type_args) |type_arg| {
                    try mangled.appendSlice("_");
                    try type_arg.formatSafe(mangled.writer());
                }
                const final_mangled = try mangled.toOwnedSlice();

                try self.monomorphizeFunction(name, type_args, final_mangled, null);

                const actual_c_name_2 = blk_2: {
                    if (self.functions_ast.get(final_mangled)) |fn_node| {
                        if (fn_node.data.fun_decl.resolved_c_name) |rcn| break :blk_2 rcn;
                    }
                    break :blk_2 final_mangled;
                };
                const func_node = self.functions_ast.get(actual_c_name_2).?;
                const func_decl = func_node.data.fun_decl;
                const ret_type = func_node.resolved_type.?.Function.return_type;

                if (c.arguments.len < func_decl.params.len) {
                    var new_args = try self.allocator.alloc(*ASTNode, func_decl.params.len);
                    for (c.arguments, 0..) |arg, arg_i| {
                        new_args[arg_i] = arg;
                    }
                    var i = c.arguments.len;
                    while (i < func_decl.params.len) : (i += 1) {
                        if (func_decl.params[i].initializer) |init_node| {
                            const cloned = try self.cloneNode(init_node);
                            if (func_decl.params[i].type_ref) |tr| {
                                cloned.expected_type = self.resolveTypeRef(tr) catch null;
                            }
                            new_args[i] = cloned;
                            _ = try self.inferNode(cloned, scope);
                        }
                    }
                    c.arguments = new_args;
                }

                for (c.arguments, 0..) |arg, arg_i| {
                    if (arg_i < func_decl.params.len) {
                        const param_type = if (func_decl.params[arg_i].type_ref) |tr| self.resolveTypeRef(tr) catch null else null;
                        if (param_type) |pt| {
                            arg.expected_type = pt;
                            if (arg.resolved_type == null) {
                                _ = try self.inferNode(arg, scope);
                            }
                            if (!self.isCompatible(pt, arg.resolved_type.?)) {
                                self.reportError(arg.line, arg.column, "TypeError: Expected {} but found {} for argument {}.", .{ pt.*, arg.resolved_type.?.*, arg_i + 1 });
                                return error.TypeError;
                            }
                        }
                    }
                }

                t.* = ret_type.*;
                c.callee.data.identifier.resolved_c_name = actual_c_name_2;
                return;
            }
            }
        }
        
        if (scope.lookupVariable(name)) |variable| {
            const var_base = extractBaseType(variable);
            if (var_base.* == .Function) {
                const f = var_base.Function;
                _ = try self.inferNode(c.callee, scope);
                const expected_args_count = f.params.len + (if (f.receiver != null) @as(usize, 1) else @as(usize, 0));
                if (c.arguments.len != expected_args_count) {
                    self.reportError(node.line, node.column, "TypeError: Expected {} arguments but got {}.", .{ expected_args_count, c.arguments.len });
                    return error.TypeError;
                }
                // Infer lambda arguments:
                for (c.arguments, 0..) |arg, arg_i| {
                    if (arg.data == .lambda_expr) {
                        const expected_arg_type = if (f.receiver != null) (if (arg_i == 0) f.receiver.? else f.params[arg_i - 1]) else f.params[arg_i];
                        arg.expected_type = expected_arg_type;
                        _ = try self.inferNode(arg, scope);
                    }
                }
                // Check argument compatibility:
                for (c.arguments, 0..) |arg, arg_i| {
                    const expected_arg_type = if (f.receiver != null) (if (arg_i == 0) f.receiver.? else f.params[arg_i - 1]) else f.params[arg_i];
                    if (!self.isCompatible(expected_arg_type, arg.resolved_type.?)) {
                        const act_base = extractBaseType(arg.resolved_type.?);
                        const exp_base = extractBaseType(expected_arg_type);
                        var is_mutable_list_mismatch = false;
                        if (act_base.* == .GenericInstance and std.mem.eql(u8, act_base.GenericInstance.base_name, "MutableList") and
                            exp_base.* == .GenericInstance and std.mem.eql(u8, exp_base.GenericInstance.base_name, "List"))
                        {
                            is_mutable_list_mismatch = true;
                        }
                        if (is_mutable_list_mismatch) {
                            self.reportError(node.line, node.column, "TypeError: Incompatible types: expected '{}', but got '{}'. Did you mean to call '.freeze()'?", .{ expected_arg_type.*, arg.resolved_type.?.* });
                        } else {
                            self.reportError(node.line, node.column, "TypeError: Expected {} for argument {} but got {}.", .{ expected_arg_type.*, arg_i + 1, arg.resolved_type.?.* });
                        }
                        return error.TypeError;
                    }
                }
                t.* = f.return_type.*;
                if (f.c_name.len > 0) {
                    c.callee.data.identifier.resolved_c_name = f.c_name;
                }
                return;
            } else if (variable.* == .Custom) {
                if (self.contracts_ast.contains(variable.Custom)) {
                    self.reportError(node.line, node.column, "TypeError: Cannot instantiate contract '{s}'. Contracts define behavior only and have no state.", .{name});
                    return error.TypeError;
                }
                if (self.objects_ast.contains(variable.Custom) and !self.classes_ast.contains(variable.Custom)) {
                    self.reportError(node.line, node.column, "TypeError: Cannot instantiate singleton object '{s}'. Access its members directly via '{s}.member'.", .{ name, name });
                    return error.TypeError;
                }
                const class_node = self.classes_ast.get(variable.Custom);
                if (class_node) |cn| {
                    const type_decl = cn.data.type_decl;
                    if (type_decl.generic_params.len > 0) {
                        var type_args = try self.allocator.alloc(*const EiwaType, type_decl.generic_params.len);
                        for (type_decl.generic_params, 0..) |g_param, i| {
                            var found_type: ?*const EiwaType = null;
                            if (node.expected_type) |exp_t| {
                                const exp_base = extractBaseType(exp_t);
                                if (exp_base.* == .GenericInstance and std.mem.eql(u8, exp_base.GenericInstance.base_name, name)) {
                                    if (i < exp_base.GenericInstance.type_args.len) {
                                        found_type = exp_base.GenericInstance.type_args[i];
                                    }
                                } else if (exp_base.* == .Custom) {
                                    const c_name = exp_base.Custom;
                                    var prefix_len: ?usize = null;
                                    if (std.mem.indexOf(u8, c_name, name)) |idx| {
                                        prefix_len = idx + name.len + 1;
                                    }
                                    if (prefix_len != null and prefix_len.? < c_name.len) {
                                        var inner = c_name[prefix_len.?..];
                                        if (std.mem.endsWith(u8, inner, "Opt")) {
                                            inner = inner[0 .. inner.len - 3];
                                        }
                                        if (type_decl.generic_params.len == 1) {
                                            if (std.mem.indexOf(u8, inner, "_or_")) |or_idx| {
                                                var raw_p1 = inner[0..or_idx];
                                                var raw_p2 = inner[or_idx + 4 ..];
                                                const t1 = (self.resolveTypeName(raw_p1, false) catch null) orelse (if (std.mem.startsWith(u8, raw_p1, "core_")) self.resolveTypeName(raw_p1[5..], false) catch null else null);
                                                const t2 = (self.resolveTypeName(raw_p2, false) catch null) orelse (if (std.mem.startsWith(u8, raw_p2, "core_")) self.resolveTypeName(raw_p2[5..], false) catch null else null);
                                                if (t1 != null and t2 != null) {
                                                    const union_t = try self.allocator.create(EiwaType);
                                                    union_t.* = .{ .Union = .{ .left = t1.?, .right = t2.? } };
                                                    found_type = union_t;
                                                }
                                            } else {
                                                found_type = self.resolveTypeName(inner, false) catch null;
                                            }
                                        } else {
                                            var split_idx: usize = 0;
                                            while (split_idx < inner.len) {
                                                const next_split = std.mem.indexOfPos(u8, inner, split_idx, "_");
                                                const part1 = if (next_split) |ns| inner[0..ns] else inner;
                                                const part2 = if (next_split) |ns| inner[ns + 1..] else "";
                                                const t1 = self.resolveTypeName(part1, false) catch null;
                                                const t2 = if (part2.len > 0) self.resolveTypeName(part2, false) catch null else null;
                                                if (t1 != null and t2 != null and isValidType(self, t1.?) and isValidType(self, t2.?)) {
                                                    if (i == 0) found_type = t1;
                                                    if (i == 1) found_type = t2;
                                                    break;
                                                }
                                                if (next_split) |ns| {
                                                    split_idx = ns + 1;
                                                } else break;
                                            }
                                        }
                                    }
                                }
                            }
                            if (found_type == null) {
                                for (type_decl.primary_constructor, 0..) |prop, prop_i| {
                                if (std.mem.eql(u8, prop.type_ref.name, g_param) and prop.type_ref.generic_args.len == 0 and !prop.type_ref.is_array) {
                                    found_type = c.arguments[prop_i].resolved_type.?;
                                    break;
                                } else {
                                    if (std.mem.eql(u8, prop.type_ref.name, "NativeArray") and prop.type_ref.generic_args.len == 1 and std.mem.eql(u8, prop.type_ref.generic_args[0].name, g_param)) {
                                        if (c.arguments[prop_i].resolved_type.?.* == .Array) {
                                            found_type = c.arguments[prop_i].resolved_type.?.Array;
                                            break;
                                        }
                                    }
                                    
                                    if (prop.type_ref.is_function) {
                                        if (prop.type_ref.return_type) |ret_ref| {
                                            if (std.mem.eql(u8, ret_ref.name, g_param)) {
                                                if (c.arguments[prop_i].resolved_type == null and c.arguments[prop_i].data == .lambda_expr) {
                                                    _ = self.inferNode(c.arguments[prop_i], scope) catch null;
                                                }
                                                if (c.arguments[prop_i].resolved_type) |arg_t| {
                                                    const base_arg = extractBaseType(arg_t);
                                                    if (base_arg.* == .Function) {
                                                        found_type = base_arg.Function.return_type;
                                                        break;
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    
                                    const is_list_gparam = (std.mem.eql(u8, prop.type_ref.name, "List") and prop.type_ref.generic_args.len == 1 and std.mem.eql(u8, prop.type_ref.generic_args[0].name, g_param)) or (prop.type_ref.is_array and prop.type_ref.generic_args.len == 1 and std.mem.eql(u8, prop.type_ref.generic_args[0].name, g_param));
                                    if (is_list_gparam) {
                                        if (c.arguments[prop_i].resolved_type.?.* == .Custom) {
                                            const c_name = c.arguments[prop_i].resolved_type.?.Custom;
                                            if (std.mem.indexOf(u8, c_name, "List_") != null) {
                                                const arg_part = c_name[std.mem.indexOf(u8, c_name, "List_").? + 5 ..];
                                                found_type = try self.resolveTypeName(arg_part, false);
                                                break;
                                            }
                                        }
                                    }
                                    
                                    var is_list_node = false;
                                    if (std.mem.eql(u8, prop.type_ref.name, "List") and prop.type_ref.generic_args.len == 1) {
                                        const inner = prop.type_ref.generic_args[0];
                                        if (std.mem.eql(u8, inner.name, "Node") and inner.generic_args.len == 2) {
                                            if (std.mem.eql(u8, inner.generic_args[0].name, g_param) or std.mem.eql(u8, inner.generic_args[1].name, g_param)) {
                                                is_list_node = true;
                                            }
                                        }
                                    }
                                    if (is_list_node) {
                                        if (c.arguments[prop_i].resolved_type.?.* == .Custom) {
                                            const c_name = c.arguments[prop_i].resolved_type.?.Custom;
                                            if (std.mem.indexOf(u8, c_name, "List_") != null) {
                                                const list_part = c_name[std.mem.indexOf(u8, c_name, "List_").? + 5 ..];
                                                if (std.mem.indexOf(u8, list_part, "Node_") != null) {
                                                    var inner = list_part[std.mem.indexOf(u8, list_part, "Node_").? + 5 ..];
                                                    if (std.mem.endsWith(u8, inner, "Opt")) {
                                                        inner = inner[0 .. inner.len - 3];
                                                    }
                                                    var split_idx: usize = 0;
                                                    while (std.mem.indexOfPos(u8, inner, split_idx, "_")) |idx| {
                                                        const part1 = inner[0..idx];
                                                        const part2 = inner[idx + 1..];
                                                        const t1 = self.resolveTypeName(part1, false) catch null;
                                                        const t2 = self.resolveTypeName(part2, false) catch null;
                                                        if (t1 != null and t2 != null and isValidType(self, t1.?) and isValidType(self, t2.?)) {
                                                            if (std.mem.eql(u8, g_param, "K")) {
                                                                 found_type = t1;
                                                            } else if (std.mem.eql(u8, g_param, "V")) {
                                                                 found_type = t2;
                                                            }
                                                            break;
                                                        }
                                                        split_idx = idx + 1;
                                                    }
                                                    if (found_type != null) break;
                                                }
                                            }
                                        }
                                    }

                                    var is_map_gparam = false;
                                    if ((std.mem.eql(u8, prop.type_ref.name, "MutableMap") or std.mem.eql(u8, prop.type_ref.name, "Map")) and prop.type_ref.generic_args.len >= 1) {
                                        for (prop.type_ref.generic_args) |arg| {
                                            if (std.mem.eql(u8, arg.name, g_param)) {
                                                is_map_gparam = true;
                                                break;
                                            }
                                        }
                                    }
                                    if (is_map_gparam) {
                                        if (c.arguments[prop_i].resolved_type.?.* == .Custom) {
                                            const c_name = c.arguments[prop_i].resolved_type.?.Custom;
                                            var base_idx: ?usize = null;
                                            if (std.mem.indexOf(u8, c_name, "MutableMap_") != null) {
                                                base_idx = std.mem.indexOf(u8, c_name, "MutableMap_").? + "MutableMap_".len;
                                            } else if (std.mem.indexOf(u8, c_name, "Map_") != null) {
                                                base_idx = std.mem.indexOf(u8, c_name, "Map_").? + "Map_".len;
                                            }
                                            if (base_idx) |b_idx| {
                                                var inner = c_name[b_idx..];
                                                if (std.mem.endsWith(u8, inner, "Opt")) {
                                                    inner = inner[0 .. inner.len - 3];
                                                }
                                                var split_idx: usize = 0;
                                                while (std.mem.indexOfPos(u8, inner, split_idx, "_")) |idx| {
                                                    const part1 = inner[0..idx];
                                                    const part2 = inner[idx + 1..];
                                                    const t1 = self.resolveTypeName(part1, false) catch null;
                                                    const t2 = self.resolveTypeName(part2, false) catch null;
                                                    if (t1 != null and t2 != null and isValidType(self, t1.?) and isValidType(self, t2.?)) {
                                                        found_type = t1;
                                                        break;
                                                    }
                                                    split_idx = idx + 1;
                                                }
                                                if (found_type != null) break;
                                            }
                                        }
                                    }
                                }
                            }
                            }
                            if (found_type) |ft| {
                                type_args[i] = ft;
                            } else {
                                self.reportError(node.line, node.column, "TypeError: Could not infer generic parameter '{s}' for class '{s}'.", .{ g_param, name });
                                return error.TypeError;
                            }
                        }
                        
                        var mangled = ArrayList(u8).init(self.allocator);
                        try mangled.appendSlice(variable.Custom);
                        try mangled.appendSlice("_");
                        for (type_args, 0..) |t_arg, i| {
                            if (i > 0) try mangled.appendSlice("_");
                            try t_arg.formatSafe(mangled.writer());
                        }
                        const final_mangled = try mangled.toOwnedSlice();
                        
                        try self.monomorphizeClass(variable.Custom, type_args, final_mangled);
                        
                        const actual_mangled = self.alias_map.get(final_mangled) orelse final_mangled;

                        const mono_class_node = self.classes_ast.get(actual_mangled) orelse cn;
                        const mono_type_decl = mono_class_node.data.type_decl;
                        if (c.arguments.len < mono_type_decl.primary_constructor.len) {
                            var new_args = try self.allocator.alloc(*ASTNode, mono_type_decl.primary_constructor.len);
                            for (c.arguments, 0..) |arg, arg_i| {
                                new_args[arg_i] = arg;
                            }
                            var i = c.arguments.len;
                            while (i < mono_type_decl.primary_constructor.len) : (i += 1) {
                                const prop = mono_type_decl.primary_constructor[i];
                                if (prop.initializer) |init_node| {
                                    const cloned = try self.cloneNode(init_node);
                                    cloned.expected_type = prop.resolved_type orelse self.resolveTypeRef(prop.type_ref) catch null;
                                    for (mono_type_decl.primary_constructor[0..i], 0..) |prev_prop, prev_i| {
                                        try self.substituteParam(cloned, prev_prop.name, new_args[prev_i]);
                                    }
                                    _ = try self.inferNode(cloned, scope);
                                    new_args[i] = cloned;
                                } else {
                                    self.reportError(node.line, node.column, "TypeError: Missing argument for generic constructor parameter '{s}' of '{s}' which has no default value.", .{ prop.name, name });
                                    return error.TypeError;
                                }
                            }
                            c.arguments = new_args;
                        } else if (c.arguments.len > mono_type_decl.primary_constructor.len) {
                            self.reportError(node.line, node.column, "TypeError: Expected at most {} arguments for generic constructor of '{s}', got {}.", .{ mono_type_decl.primary_constructor.len, name, c.arguments.len });
                            return error.TypeError;
                        }

                        for (c.arguments, 0..) |arg, arg_i| {
                            if (arg_i < mono_type_decl.primary_constructor.len) {
                                const p = mono_type_decl.primary_constructor[arg_i];
                                if (p.resolved_type orelse self.resolveTypeRef(p.type_ref) catch null) |pt| {
                                    arg.expected_type = pt;
                                    if (arg.resolved_type == null) {
                                        _ = try self.inferNode(arg, scope);
                                    }
                                    if (!self.isCompatible(pt, arg.resolved_type.?)) {
                                        self.reportError(node.line, node.column, "TypeError: Expected {} but found {} for argument {}.", .{ pt.*, arg.resolved_type.?.*, arg_i + 1 });
                                        return error.TypeError;
                                    }
                                }
                            }
                        }

                        t.* = .{ .Custom = actual_mangled };
                        c.callee.data.identifier.resolved_c_name = actual_mangled;
                        return;
                    } else {
                        if (c.arguments.len < type_decl.primary_constructor.len) {
                            var new_args = try self.allocator.alloc(*ASTNode, type_decl.primary_constructor.len);
                            for (c.arguments, 0..) |arg, arg_i| {
                                new_args[arg_i] = arg;
                            }
                            var i = c.arguments.len;
                            while (i < type_decl.primary_constructor.len) : (i += 1) {
                                const prop = type_decl.primary_constructor[i];
                                if (prop.initializer) |init_node| {
                                    const cloned = try self.cloneNode(init_node);
                                    cloned.expected_type = prop.resolved_type orelse self.resolveTypeRef(prop.type_ref) catch null;
                                    for (type_decl.primary_constructor[0..i], 0..) |prev_prop, prev_i| {
                                        try self.substituteParam(cloned, prev_prop.name, new_args[prev_i]);
                                    }
                                    _ = try self.inferNode(cloned, scope);
                                    new_args[i] = cloned;
                                } else {
                                    self.reportError(node.line, node.column, "TypeError: Missing argument for constructor parameter '{s}' of '{s}' which has no default value.", .{ prop.name, name });
                                    return error.TypeError;
                                }
                            }
                            c.arguments = new_args;
                        } else if (c.arguments.len > type_decl.primary_constructor.len) {
                            self.reportError(node.line, node.column, "TypeError: Expected at most {} arguments for constructor of '{s}', got {}.", .{ type_decl.primary_constructor.len, name, c.arguments.len });
                            return error.TypeError;
                        }

                        // Propagate the declared parameter types to the provided
                        // args so the backend can coerce to the exact contract
                        // (fat-pointer vtable) instead of guessing. Lambda args
                        // must be inferred here with the expected type bound —
                        // otherwise a `type Cont(val run: () -> Int); Cont({42})`
                        // stores a Void-returning closure.
                        for (c.arguments, 0..) |arg, arg_i| {
                            if (arg_i < type_decl.primary_constructor.len) {
                                if (type_decl.primary_constructor[arg_i].resolved_type orelse self.resolveTypeRef(type_decl.primary_constructor[arg_i].type_ref) catch null) |pt| {
                                    arg.expected_type = pt;
                                    if (arg.resolved_type == null) {
                                        _ = try self.inferNode(arg, scope);
                                    }
                                }
                            }
                        }
                    }
                }
                
                t.* = variable.*;
                c.callee.data.identifier.resolved_c_name = variable.Custom;
                return;
            }
        }
        
        if (self.alias_map.get(name)) |c_name| {
            if (scope.lookupVariable(c_name)) |variable| {
                const resolved_name: ?[]const u8 = if (variable.* == .Custom) variable.Custom else if (variable.* == .String) @as([]const u8, "core_String") else null;
                if (resolved_name) |rn| {
                    if (self.contracts_ast.contains(rn)) {
                        self.reportError(node.line, node.column, "TypeError: Cannot instantiate contract '{s}'. Contracts define behavior only and have no state.", .{name});
                        return error.TypeError;
                    }
                    const class_node = self.classes_ast.get(rn);
                    if (class_node) |cn| {
                        const type_decl = cn.data.type_decl;
                        if (c.arguments.len < type_decl.primary_constructor.len) {
                            var new_args = try self.allocator.alloc(*ASTNode, type_decl.primary_constructor.len);
                            for (c.arguments, 0..) |arg, arg_i| {
                                new_args[arg_i] = arg;
                            }
                            var i = c.arguments.len;
                            while (i < type_decl.primary_constructor.len) : (i += 1) {
                                const prop = type_decl.primary_constructor[i];
                                if (prop.initializer) |init_node| {
                                    const cloned = try self.cloneNode(init_node);
                                    cloned.expected_type = prop.resolved_type orelse self.resolveTypeRef(prop.type_ref) catch null;
                                    new_args[i] = cloned;
                                    _ = try self.inferNode(cloned, scope);
                                } else {
                                    self.reportError(node.line, node.column, "TypeError: Missing argument for constructor parameter '{s}' of '{s}' which has no default value.", .{ prop.name, name });
                                    return error.TypeError;
                                }
                            }
                            c.arguments = new_args;
                        } else if (c.arguments.len > type_decl.primary_constructor.len) {
                            self.reportError(node.line, node.column, "TypeError: Expected at most {} arguments for constructor of '{s}', got {}.", .{ type_decl.primary_constructor.len, name, c.arguments.len });
                            return error.TypeError;
                        }

                        for (c.arguments, 0..) |arg, arg_i| {
                            if (arg_i < type_decl.primary_constructor.len) {
                                if (type_decl.primary_constructor[arg_i].resolved_type orelse self.resolveTypeRef(type_decl.primary_constructor[arg_i].type_ref) catch null) |pt| {
                                    arg.expected_type = pt;
                                    if (arg.resolved_type == null) {
                                        _ = try self.inferNode(arg, scope);
                                    }
                                }
                            }
                        }
                    }
                    t.* = variable.*;
                    c.callee.data.identifier.resolved_c_name = rn;
                    return;
                }
            }
        }
        if (try inferImplicitThisOrObjectCall(self, node, scope, t, name)) return;
        self.reportError(node.line, node.column, "TypeError: Undeclared function '{s}'.", .{name});
        return error.TypeError;
    } else if (c.callee.data == .get_expr) {
        _ = try self.inferNode(c.callee, scope);

        const g = c.callee.data.get_expr;

        // Function-typed struct field: `obj.run()` invokes the closure stored
        // in the field, not a (possibly skill-composed) method with the same
        // name. `inferGetExpr` resolves declared fields before methods, so a
        // matching field wins here and the call is emitted through the dynamic
        // closure (fat pointer) path — no method dispatch / default filling.
        if (g.object.resolved_type) |obj_type| {
            const obj_base = extractBaseType(obj_type);
            if (lookupDeclaredField(self, obj_base, g.name)) |field_type| {
                const fbase = extractBaseType(field_type);
                if (fbase.* == .Function) {
                    const f = fbase.Function;
                    for (c.arguments, 0..) |arg, arg_i| {
                        if (arg_i < f.params.len) {
                            arg.expected_type = f.params[arg_i];
                        }
                        if (arg.data == .lambda_expr) {
                            _ = try self.inferNode(arg, scope);
                        }
                    }
                    for (c.arguments, 0..) |arg, arg_i| {
                        if (arg_i < f.params.len) {
                            if (!self.isCompatible(f.params[arg_i], arg.resolved_type.?)) {
                                self.reportError(node.line, node.column, "TypeError: Expected {} but found {} for argument {}.", .{ f.params[arg_i].*, arg.resolved_type.?.*, arg_i + 1 });
                                return error.TypeError;
                            }
                        }
                    }
                    t.* = f.return_type.*;
                    node.resolved_type = t;
                    return;
                } else {
                    self.reportError(node.line, node.column, "TypeError: Cannot call a field '{s}' of non-function type {}.", .{ g.name, field_type.* });
                    return error.TypeError;
                }
            }
        }

        var is_static = false;
        var found_static_method: ?*ASTNode = null;
        
        if (g.object.data == .identifier) {
            const class_name = g.object.data.identifier.name;
            const actual_class_name = self.alias_map.get(class_name) orelse class_name;
            if (self.objects_ast.get(actual_class_name)) |obj_node| {
                is_static = true;
                const obj = obj_node.data.object_decl;
                
                // Static method overload resolution
                for (obj.members) |member| {
                    if (member.data == .fun_decl and std.mem.eql(u8, member.data.fun_decl.name, g.name)) {
                        const f = member.data.fun_decl;
                        if (c.arguments.len > f.params.len) continue;
                        
                        var has_defaults = true;
                        var i = c.arguments.len;
                        while (i < f.params.len) : (i += 1) {
                            if (f.params[i].initializer == null) {
                                has_defaults = false;
                                break;
                            }
                        }
                        if (!has_defaults) continue;
                        
                        var all_match = true;
                        for (c.arguments, 0..) |arg, arg_i| {
                            // Propagate the declared param type so lambdas infer
                            // `it` (skip raw generic params, which would mislead).
                            var expected_type: ?*EiwaType = null;
                            if (arg_i < f.params.len and f.params[arg_i].type_ref != null) {
                                const et = try self.resolveTypeRef(f.params[arg_i].type_ref.?);
                                if (et.* != .GenericParam) {
                                    expected_type = et;
                                    arg.expected_type = expected_type;
                                }
                            }
                            const arg_type = try self.inferNode(arg, scope);
                            if (expected_type) |et| {
                                if (f.generic_params.len == 0 and !self.isCompatible(et, arg_type)) {
                                    all_match = false;
                                    break;
                                }
                            }
                        }
                        
                        if (all_match) {
                            found_static_method = member;
                            break;
                        }
                    }
                }
                
                if (found_static_method == null) {
                    for (obj.members) |member| {
                        if (member.data == .fun_decl and std.mem.eql(u8, member.data.fun_decl.name, g.name)) {
                            found_static_method = member;
                            break;
                        }
                    }
                }
            }
        }
        
        if (is_static) {
            const matched_method = found_static_method orelse {
                self.reportError(node.line, node.column, "TypeError: Static method '{s}' not found.", .{g.name});
                return error.TypeError;
            };

            if (matched_method.data.fun_decl.generic_params.len > 0) {
                const f = &matched_method.data.fun_decl;
                var type_args = try self.allocator.alloc(*const EiwaType, f.generic_params.len);
                if (c.type_args.len == f.generic_params.len) {
                    for (c.type_args, 0..) |ta_ref, tai| {
                        type_args[tai] = try self.resolveTypeRef(ta_ref);
                    }
                } else {
                    for (f.generic_params, 0..) |param_name, pi| {
                        var inferred_t: ?*const EiwaType = null;
                        for (c.arguments, 0..) |arg, ai| {
                            if (ai >= f.params.len) break;
                            const arg_t = try self.inferNode(arg, scope);
                            const p_ref = f.params[ai].type_ref;
                            if (p_ref) |pr| {
                                if (pr.generic_args.len > 0 and std.mem.eql(u8, pr.generic_args[0].name, param_name)) {
                                    const base_arg_t = extractBaseType(arg_t);
                                    if (base_arg_t.* == .Custom) {
                                        if (std.mem.lastIndexOf(u8, base_arg_t.Custom, "_")) |idx| {
                                            const sub_name = base_arg_t.Custom[idx + 1 ..];
                                            const sub_t = try self.allocator.create(EiwaType);
                                            sub_t.* = .{ .Custom = sub_name };
                                            inferred_t = sub_t;
                                        }
                                    }
                                } else if (std.mem.eql(u8, pr.name, param_name)) {
                                    inferred_t = arg_t;
                                }
                            }
                        }
                        type_args[pi] = inferred_t orelse blk: {
                            const string_t = try self.allocator.create(EiwaType);
                            string_t.* = .String;
                            break :blk string_t;
                        };
                    }
                }

                var mangled = ArrayList(u8).init(self.allocator);
                const obj_name = self.alias_map.get(g.object.data.identifier.name) orelse g.object.data.identifier.name;
                try mangled.appendSlice(obj_name);
                try mangled.appendSlice("_");
                try mangled.appendSlice(g.name);
                for (type_args) |ta| {
                    try mangled.appendSlice("_");
                    try ta.formatSafe(mangled.writer());
                }
                const final_mangled = try mangled.toOwnedSlice();

                const old_class_name = self.current_class_name;
                self.current_class_name = obj_name;
                defer self.current_class_name = old_class_name;

                const old_gen_entry = self.generic_functions_ast.get(g.name);
                try self.generic_functions_ast.put(g.name, matched_method);
                const mono_result = self.monomorphizeFunction(g.name, type_args, final_mangled, null);
                if (old_gen_entry) |old| {
                    try self.generic_functions_ast.put(g.name, old);
                } else {
                    _ = self.generic_functions_ast.remove(g.name);
                }
                try mono_result;

                const func_node = self.functions_ast.get(final_mangled) orelse {
                    self.reportError(node.line, node.column, "TypeError: Monomorphized static method '{s}.{s}' not found.", .{ obj_name, g.name });
                    return error.TypeError;
                };
                const ret_type = func_node.resolved_type.?.Function.return_type;

                c.callee.data = .{ .identifier = .{
                    .name = g.name,
                    .resolved_c_name = final_mangled,
                    .is_class_property = false,
                } };
                c.callee.resolved_type = null;

                for (c.arguments, 0..) |arg, ai| {
                    // Propagate the declared param type so lambdas infer `it`.
                    if (ai < f.params.len) {
                        if (f.params[ai].type_ref) |tr| {
                            arg.expected_type = self.resolveTypeRef(tr) catch null;
                        }
                    }
                    _ = try self.inferNode(arg, scope);
                }

                t.* = ret_type.*;
                node.resolved_type = t;
                return;
            }

            if (matched_method.resolved_type == null or matched_method.resolved_type.?.* != .Function or matched_method.resolved_type.?.Function.return_type.* == .Unknown) {
                _ = try self.inferNode(matched_method, scope);
            }
            if (matched_method.resolved_type == null or matched_method.resolved_type.?.* != .Function) {
                self.reportError(node.line, node.column, "TypeError: Method '{s}' does not have a function type.", .{g.name});
                return error.TypeError;
            }
            const ret_type = matched_method.resolved_type.?.Function.return_type;
            const f = &matched_method.data.fun_decl;
            
            if (f.params.len > 0 and f.params[f.params.len - 1].is_varargs) {
                // Varargs method: always run arg resolution so positional args landing
                // on the variadic slot are collected into a List (even when the call's
                // arg count happens to equal the fixed param count).
                try resolveCallArguments(self, node, f.params, scope);
            } else if (hasNamedArgs(c.arguments)) {
                // Named arguments (`name = value`) must be reordered positionally;
                // the default-fill branch below would otherwise leave named_arg
                // nodes in place, which the emitters cannot lower.
                try resolveCallArguments(self, node, f.params, scope);
            } else if (c.arguments.len < f.params.len) {
                var new_args = try self.allocator.alloc(*ASTNode, f.params.len);
                for (c.arguments, 0..) |arg, arg_i| {
                    new_args[arg_i] = arg;
                }
                var i = c.arguments.len;
                while (i < f.params.len) : (i += 1) {
                    const prop = f.params[i];
                    if (prop.initializer) |init_node| {
                        const cloned = try self.cloneNode(init_node);
                        if (prop.type_ref) |tr| {
                            cloned.expected_type = self.resolveTypeRef(tr) catch null;
                        }
                        new_args[i] = cloned;
                        _ = try self.inferNode(cloned, scope);
                    } else {
                        self.reportError(node.line, node.column, "TypeError: Missing argument for parameter '{s}' of '{s}' which has no default value.", .{ prop.name, f.name });
                        return error.TypeError;
                    }
                }
                c.arguments = new_args;
            }
            
            const static_c_name = matched_method.resolved_type.?.Function.c_name;
            c.callee.data = .{ .identifier = .{
                .name = g.name,
                .resolved_c_name = static_c_name,
                .is_class_property = false,
            } };
            c.callee.resolved_type = null;
            
            if (c.arguments.len > f.params.len) {
                self.reportError(node.line, node.column, "TypeError: Too many arguments passed to method '{s}'. Expected {d}, got {d}.", .{ g.name, f.params.len, c.arguments.len });
                return error.TypeError;
            }

            for (c.arguments, 0..) |arg, i| {
                if (i < f.params.len and f.params[i].is_varargs) {
                    // Variadic slot: the arg is the synthetic List<T>; give it the
                    // monomorphized List type. Element compatibility was already checked.
                    if (f.params[i].type_ref) |tr| {
                        if (self.resolveTypeRef(tr) catch null) |et| {
                            arg.expected_type = self.makeListType(et, node.line, node.column) catch null;
                        }
                    }
                    _ = try self.inferNode(arg, scope);
                } else if (i < f.params.len and f.params[i].type_ref != null) {
                    const expected_type = try self.resolveTypeRef(f.params[i].type_ref.?);
                    // Propagate the declared param type so the backend coerces
                    // contract args to the exact contract vtable (not a
                    // random one from the fallback loop).
                    arg.expected_type = expected_type;
                    const arg_type = try self.inferNode(arg, scope);
                    if (!self.isCompatible(expected_type, arg_type)) {
                        self.reportError(arg.line, arg.column, "TypeError: Expected {} but found {} for argument {}.", .{ expected_type.*, arg_type.*, i + 1 });
                        return error.TypeError;
                    }
                } else {
                    _ = try self.inferNode(arg, scope);
                }
            }
            
            t.* = ret_type.*;
            node.resolved_type = t;
            return;
        }

        // Fill in method default parameters!
        if (g.object.resolved_type) |obj_type| {
            const base_type = extractBaseType(obj_type);
            var prim_class_name: ?[]const u8 = null;
            switch (base_type.*) {
                .Custom => |cn| prim_class_name = cn,
                .Int => prim_class_name = "core_Int",
                .Bool => prim_class_name = "core_Bool",
                .String => prim_class_name = "core_String",
                .Pointer => prim_class_name = "core_Pointer",
                else => {},
            }
            if (prim_class_name) |raw_class_name| {
                const class_name = self.alias_map.get(raw_class_name) orelse raw_class_name;
                if (self.classes_ast.get(class_name)) |class_node| {
                    const type_decl = class_node.data.type_decl;
                    
                    var found_method: ?*ASTNode = null;
                    for (type_decl.methods) |method| {
                        if (std.mem.eql(u8, method.data.fun_decl.name, g.name)) {
                            const f = &method.data.fun_decl;
                            if (c.arguments.len > f.params.len) continue;

                            var has_defaults = true;
                            var i = c.arguments.len;
                            while (i < f.params.len) : (i += 1) {
                                if (f.params[i].initializer == null) {
                                    has_defaults = false;
                                    break;
                                }
                            }
                            if (!has_defaults) continue;

                            var all_match = true;
                            for (c.arguments, 0..) |arg, arg_i| {
                                if (arg.data == .lambda_expr) {
                                    const expected_type = self.resolveTypeRef(f.params[arg_i].type_ref.?) catch null;
                                    if (expected_type == null or expected_type.?.* != .Function) {
                                        all_match = false;
                                        break;
                                    }
                                } else {
                                    const arg_type = arg.resolved_type orelse (self.inferNode(arg, scope) catch null);
                                    if (arg_type == null) {
                                        all_match = false;
                                        break;
                                    }
                                    const expected_type = self.resolveTypeRef(f.params[arg_i].type_ref.?) catch null;
                                    if (expected_type == null or !self.isCompatible(expected_type.?, arg_type.?)) {
                                        all_match = false;
                                        break;
                                    }
                                }
                            }

                            if (all_match) {
                                found_method = method;
                                break;
                            }
                        }
                    }

                    if (found_method == null) {
                        for (type_decl.methods) |method| {
                            if (std.mem.eql(u8, method.data.fun_decl.name, g.name)) {
                                found_method = method;
                                break;
                            }
                        }
                    }

                    
                    if (found_method) |m| {
                        const f = &m.data.fun_decl;

                        // Handle generic method with inferred type args
                        if (f.generic_params.len > 0 and c.type_args.len == 0 and c.arguments.len >= f.params.len) {
                            var type_args = try self.allocator.alloc(*const EiwaType, f.generic_params.len);
                            for (f.generic_params, 0..) |param_name, i| {
                                var found_type: ?*const EiwaType = null;
                                for (f.params, 0..) |p, arg_i| {
                                    if (arg_i < c.arguments.len) {
                                        if (p.type_ref) |tr| {
                                            if (std.mem.eql(u8, tr.name, param_name) and tr.generic_args.len == 0) {
                                                const arg_t = c.arguments[arg_i].resolved_type orelse continue;
                                                found_type = arg_t;
                                                break;
                                            }
                                            if (tr.is_function) {
                                                const arg = c.arguments[arg_i];
                                                // Generic param in function return position (e.g. R in
                                                // (T) -> R): infer the lambda with its param types bound
                                                // and an Unknown return, then read R off the result.
                                                if (tr.return_type) |ret_tr| {
                                                    if (std.mem.eql(u8, ret_tr.name, param_name) and ret_tr.generic_args.len == 0) {
                                                        if (arg.data == .lambda_expr and arg.resolved_type == null) {
                                                            var exp_params = try self.allocator.alloc(*const EiwaType, tr.generic_args.len);
                                                            for (tr.generic_args, 0..) |fp, fpi| {
                                                                exp_params[fpi] = self.resolveTypeRef(fp) catch try self.resolveTypeName("Void", false);
                                                            }
                                                            const unknown_t = try self.allocator.create(EiwaType);
                                                            unknown_t.* = .Unknown;
                                                            const exp_fn = try self.allocator.create(EiwaType);
                                                            exp_fn.* = .{ .Function = .{
                                                                .params = exp_params,
                                                                .return_type = unknown_t,
                                                                .c_name = "",
                                                            } };
                                                            arg.expected_type = exp_fn;
                                                            _ = try self.inferNode(arg, scope);
                                                        }
                                                        if (arg.resolved_type) |arg_t| {
                                                            const base_arg = extractBaseType(arg_t);
                                                            if (base_arg.* == .Function) {
                                                                found_type = base_arg.Function.return_type;
                                                            }
                                                        }
                                                    }
                                                }
                                                if (found_type == null) {
                                                    for (tr.generic_args, 0..) |param_tr, param_idx| {
                                                        if (std.mem.eql(u8, param_tr.name, param_name) and param_tr.generic_args.len == 0) {
                                                            if (arg.resolved_type) |arg_t| {
                                                                const base_arg = extractBaseType(arg_t);
                                                                if (base_arg.* == .Function and param_idx < base_arg.Function.params.len) {
                                                                    found_type = base_arg.Function.params[param_idx];
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                                if (found_type == null) {
                                    if (node.expected_type) |exp_t| {
                                        found_type = exp_t;
                                    }
                                }
                                type_args[i] = found_type orelse {
                                    self.reportError(node.line, node.column, "TypeError: Could not infer generic parameter '{s}' for method '{s}.{s}'.", .{ param_name, type_decl.name, g.name });
                                    return error.TypeError;
                                };
                            }

                            var mangled = ArrayList(u8).init(self.allocator);
                            try mangled.appendSlice(class_name);
                            try mangled.appendSlice("_");
                            try mangled.appendSlice(g.name);
                            for (type_args) |ta| {
                                try mangled.appendSlice("_");
                                try ta.formatSafe(mangled.writer());
                            }
                            const final_mangled = try mangled.toOwnedSlice();

                            // Scope the generic base node lookup to THIS class's method:
                            // generic_functions_ast is keyed by bare name and collides
                            // across classes (e.g. every type has a composed `let<R>`).
                            const old_gen_entry = self.generic_functions_ast.get(g.name);
                            try self.generic_functions_ast.put(g.name, m);
                            const mono_result = self.monomorphizeFunction(g.name, type_args, final_mangled, base_type);
                            if (old_gen_entry) |old| {
                                try self.generic_functions_ast.put(g.name, old);
                            } else {
                                _ = self.generic_functions_ast.remove(g.name);
                            }
                            try mono_result;

                            var call_args = try self.allocator.alloc(*ASTNode, c.arguments.len + 1);
                            call_args[0] = g.object;
                            for (c.arguments, 0..) |a, ai| {
                                call_args[ai + 1] = a;
                            }
                            c.arguments = call_args;

                            const func_node = self.functions_ast.get(final_mangled) orelse {
                                self.reportError(node.line, node.column, "TypeError: Monomorphized method '{s}.{s}' not found.", .{ type_decl.name, g.name });
                                return error.TypeError;
                            };
                            const ret_type = func_node.resolved_type.?.Function.return_type;

                            c.callee.data = .{ .identifier = .{
                                .name = g.name,
                                .resolved_c_name = final_mangled,
                            } };
                            t.* = ret_type.*;
                            return;
                        }

                        if (f.resolved_c_name) |rcn| {
                            c.callee.data.get_expr.resolved_c_name = rcn;
                        }


                        if (f.params.len > 0 and f.params[f.params.len - 1].is_varargs) {
                            // Varargs method: always run arg resolution so positional args
                            // landing on the variadic slot are collected into a List.
                            try resolveCallArguments(self, node, f.params, scope);
                        } else if (hasNamedArgs(c.arguments)) {
                            // Named arguments (`name = value`) must be reordered
                            // positionally; see the type-method dispatch above.
                            try resolveCallArguments(self, node, f.params, scope);
                        } else if (c.arguments.len < f.params.len) {

                            var new_args = try self.allocator.alloc(*ASTNode, f.params.len);
                            for (c.arguments, 0..) |arg, arg_i| {
                                new_args[arg_i] = arg;
                            }
                            var i = c.arguments.len;
                            while (i < f.params.len) : (i += 1) {
                                const prop = f.params[i];
                                if (prop.initializer) |init_node| {
                                    const cloned = try self.cloneNode(init_node);
                                    if (prop.type_ref) |tr| {
                                        cloned.expected_type = self.resolveTypeRef(tr) catch null;
                                    }
                                    new_args[i] = cloned;
                                    _ = try self.inferNode(cloned, scope);
                                } else {
                                    self.reportError(node.line, node.column, "TypeError: Missing argument for method parameter '{s}' of '{s}.{s}' which has no default value.", .{ prop.name, type_decl.name, g.name });
                                    return error.TypeError;
                                }
                            }
                            c.arguments = new_args;
                        } else if (c.arguments.len > f.params.len) {
                            self.reportError(node.line, node.column, "TypeError: Expected at most {} arguments for method '{s}.{s}', got {}.", .{ f.params.len, type_decl.name, g.name, c.arguments.len });
                            return error.TypeError;
                        }

                        for (c.arguments, 0..) |arg, arg_i| {
                            if (arg_i < f.params.len) {
                                if (f.params[arg_i].is_varargs) {
                                    // The variadic List<T> gets the monomorphized List type.
                                    if (f.params[arg_i].type_ref) |tr| {
                                        if (self.resolveTypeRef(tr) catch null) |et| {
                                            arg.expected_type = self.makeListType(et, node.line, node.column) catch null;
                                        }
                                    }
                                } else if (f.params[arg_i].type_ref) |tr| {
                                    arg.expected_type = self.resolveTypeRef(tr) catch null;
                                }
                            }
                            _ = try self.inferNode(arg, scope);
                        }

                    }
                } else if (self.contracts_ast.get(class_name)) |contract_node| {
                    const cd = contract_node.data.contract_decl;
                    for (cd.methods) |method| {
                        if (method.data == .fun_decl and std.mem.eql(u8, method.data.fun_decl.name, g.name)) {
                            const f = &method.data.fun_decl;
                            if (hasNamedArgs(c.arguments)) {
                                // Named arguments (`name = value`) must be reordered
                                // positionally; see the type-method dispatch above.
                                try resolveCallArguments(self, node, f.params, scope);
                            } else if (c.arguments.len < f.params.len) {
                                var new_args = try self.allocator.alloc(*ASTNode, f.params.len);
                                for (c.arguments, 0..) |arg, arg_i| {
                                    new_args[arg_i] = arg;
                                }
                                var i = c.arguments.len;
                                while (i < f.params.len) : (i += 1) {
                                    if (f.params[i].initializer) |init_node| {
                                        const cloned = try self.cloneNode(init_node);
                                        if (f.params[i].type_ref) |tr| {
                                            cloned.expected_type = self.resolveTypeRef(tr) catch null;
                                        }
                                        new_args[i] = cloned;
                                        _ = try self.inferNode(cloned, scope);
                                    }
                                }
                                c.arguments = new_args;
                            }
                            for (c.arguments, 0..) |arg, arg_i| {
                                if (arg_i < f.params.len) {
                                    if (f.params[arg_i].type_ref) |tr| {
                                        arg.expected_type = self.resolveTypeRef(tr) catch null;
                                    }
                                }
                                _ = try self.inferNode(arg, scope);
                            }
                            break;
                        }
                    }
                }
            }
        }
        
        t.* = .Void;
        if (c.callee.resolved_type) |rt| {
            const rt_base = extractBaseType(rt);
            if (rt_base.* == .Function) {
                const f = rt_base.Function;
                // Lib functions (e.g. variadic C printf) are exempt from
                // strict arity/type checks, but lambda args still need
                // inference so the transpiler sees their resolved types.
                var is_lib_call = false;
                if (g.object.resolved_type) |obj_rt| {
                    const obj_base = extractBaseType(obj_rt);
                    if (obj_base.* == .Custom and self.lib_symbols.contains(obj_base.Custom)) {
                        is_lib_call = true;
                    }
                }
                // Infer lambda arguments:
                for (c.arguments, 0..) |arg, arg_i| {
                    if (arg_i < f.params.len) {
                        arg.expected_type = f.params[arg_i];
                    }
                    if (arg.data == .lambda_expr or (is_lib_call and arg.resolved_type == null)) {
                        _ = try self.inferNode(arg, scope);
                    }
                }
                if (!is_lib_call) {
                    // Check compatibility:
                    for (c.arguments, 0..) |arg, arg_i| {
                        if (arg_i < f.params.len) {
                            if (!self.isCompatible(f.params[arg_i], arg.resolved_type.?)) {
                                self.reportError(node.line, node.column, "TypeError: Expected {} but found {} for argument {}.", .{ f.params[arg_i].*, arg.resolved_type.?.*, arg_i + 1 });
                                return error.TypeError;
                            }
                        }
                    }
                }
                t.* = f.return_type.*;
            } else {
                t.* = rt.*;
            }
        }
    } else {
        _ = try self.inferNode(c.callee, scope);
        t.* = .Void;
        if (c.callee.resolved_type) |rt| {
            const rt_base = extractBaseType(rt);
            if (rt_base.* == .Function) {
                const f = rt_base.Function;
                // Infer lambda arguments:
                for (c.arguments, 0..) |arg, arg_i| {
                    if (arg_i < f.params.len) {
                        arg.expected_type = f.params[arg_i];
                    }
                    if (arg.data == .lambda_expr) {
                        _ = try self.inferNode(arg, scope);
                    }
                }
                // Check compatibility:
                for (c.arguments, 0..) |arg, arg_i| {
                    if (arg_i < f.params.len) {
                        if (!self.isCompatible(f.params[arg_i], arg.resolved_type.?)) {
                            self.reportError(node.line, node.column, "TypeError: Expected {} but found {} for argument {}.", .{ f.params[arg_i].*, arg.resolved_type.?.*, arg_i + 1 });
                            return error.TypeError;
                        }
                    }
                }
                t.* = f.return_type.*;
            } else {
                t.* = rt.*;
            }
        }
    }
}

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

pub fn inferCallExpr(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    var c = &node.data.call_expr;
    // 1. Infer all arguments that are NOT lambdas
    for (c.arguments) |arg| {
        if (arg.data != .lambda_expr) {
            _ = try self.inferNode(arg, scope);
        }
    }

    if (c.callee.data == .identifier) {
        const name = c.callee.data.identifier.name;

        if (std.mem.eql(u8, name, "task") and c.arguments.len == 1) {
            _ = try self.inferNode(c.arguments[0], scope);
            const arg_type = c.arguments[0].resolved_type orelse return error.TypeError;
            const base_arg = extractBaseType(arg_type);
            if (base_arg.* != .Function) {
                self.reportError(node.line, node.column, "TypeError: task() requires a function argument, got {}.", .{arg_type.*});
                return error.TypeError;
            }
            const lambda_return = base_arg.Function.return_type;
            const type_args = try self.allocator.alloc(*const EiwaType, 1);
            type_args[0] = lambda_return;
            const gi = try self.allocator.create(EiwaType);
            gi.* = .{ .GenericInstance = .{
                .base_name = "Task",
                .type_args = type_args,
            }};
            t.* = gi.*;
            return;
        }

        if (c.type_args.len > 0) {
            const class_name = self.alias_map.get(name) orelse name;
            const class_node = self.classes_ast.get(class_name);
            if (class_node == null) {
                // Try as a generic function
                if (self.generic_functions_ast.get(name) != null) {
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

                    try self.monomorphizeFunction(name, type_args, final_mangled);

                    const func_node = self.functions_ast.get(final_mangled).?;
                    const fun_decl = &func_node.data.fun_decl;
                    const ret_type = func_node.resolved_type.?.Function.return_type;

                    if (c.arguments.len < fun_decl.params.len) {
                        var new_args = try self.allocator.alloc(*ASTNode, fun_decl.params.len);
                        for (c.arguments, 0..) |arg, arg_i| {
                            new_args[arg_i] = arg;
                        }
                        var i = c.arguments.len;
                        while (i < fun_decl.params.len) : (i += 1) {
                            if (fun_decl.params[i].initializer) |init_node| {
                                const cloned = try self.cloneNode(init_node);
                                const param_type = if (fun_decl.params[i].type_ref) |tr| self.resolveTypeRef(tr) catch null else null;
                                if (param_type) |pt| cloned.expected_type = pt;
                                new_args[i] = cloned;
                                _ = try self.inferNode(cloned, scope);
                            }
                        }
                        c.arguments = new_args;
                    }

                    for (c.arguments, 0..) |arg, arg_i| {
                        if (arg_i < fun_decl.params.len) {
                            const param_type = if (fun_decl.params[arg_i].type_ref) |tr| self.resolveTypeRef(tr) catch null else null;
                            if (param_type) |pt| {
                                arg.expected_type = pt;
                                arg.resolved_type = null;
                                _ = try self.inferNode(arg, scope);
                                if (!self.isCompatible(pt, arg.resolved_type.?)) {
                                    self.reportError(arg.line, arg.column, "TypeError: Expected {} but found {} for argument {}.", .{ pt.*, arg.resolved_type.?.*, arg_i + 1 });
                                    return error.TypeError;
                                }
                            }
                        }
                    }

                    t.* = ret_type.*;
                    c.callee.data.identifier.resolved_c_name = final_mangled;
                    return;
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
                if (!self.isCompatible(expected, arg.resolved_type.?)) {
                    self.reportError(arg.line, arg.column, "TypeError: Expected {} for argument {} of '{s}', got {}.", .{ expected.*, arg_i + 1, name, arg.resolved_type.?.* });
                    return error.TypeError;
                }
            }

            const actual_mangled = self.alias_map.get(final_mangled) orelse final_mangled;
            t.* = .{ .Custom = actual_mangled };
            c.callee.data.identifier.resolved_c_name = actual_mangled;
            return;
        }

        if (scope.lookupFunctions(name)) |overloads| {
            var best_match: ?*const EiwaType = null;
            
            for (overloads) |overload| {
                if (overload.* != .Function) continue;
                const f = overload.Function;
                if (c.arguments.len > f.params.len) continue;
                
                const func_node = self.functions_ast.get(f.c_name) orelse continue;
                const fun_decl = func_node.data.fun_decl;
                
                var has_defaults = true;
                var i = c.arguments.len;
                while (i < f.params.len) : (i += 1) {
                    if (fun_decl.params[i].initializer == null) {
                        has_defaults = false;
                        break;
                    }
                }
                if (!has_defaults) continue;
                
                var all_match = true;
                for (c.arguments, 0..) |arg, arg_i| {
                    if (arg.data == .lambda_expr) {
                        if (f.params[arg_i].* != .Function) {
                            all_match = false;
                            break;
                        }
                    } else {
                        if (!self.isCompatible(f.params[arg_i], arg.resolved_type.?)) {
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
            
            if (best_match) |matched| {
                const f = matched.Function;
                const func_node = self.functions_ast.get(f.c_name).?;
                const fun_decl = func_node.data.fun_decl;
                
                if (c.arguments.len < f.params.len) {
                    var new_args = try self.allocator.alloc(*ASTNode, f.params.len);
                    for (c.arguments, 0..) |arg, arg_i| {
                        new_args[arg_i] = arg;
                    }
                    var i = c.arguments.len;
                    while (i < f.params.len) : (i += 1) {
                        const cloned = try self.cloneNode(fun_decl.params[i].initializer.?);
                        new_args[i] = cloned;
                        _ = try self.inferNode(cloned, scope);
                    }
                    c.arguments = new_args;
                }
                
                // Now, infer all lambda arguments using the matched parameter types!
                for (c.arguments, 0..) |arg, arg_i| {
                    if (arg.data == .lambda_expr) {
                        arg.expected_type = f.params[arg_i];
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
            } else {
                // Print the argument types we provided to help debug
                var expected_types_str = ArrayList(u8).init(self.allocator);
                if (overloads.len > 0 and overloads[0].* == .Function) {
                    for (overloads[0].Function.params, 0..) |p, i| {
                        if (i > 0) try expected_types_str.appendSlice(", ");
                        const rt_str = try std.fmt.allocPrint(self.allocator, "{}", .{p.*});
                        try expected_types_str.appendSlice(rt_str);
                    }
                }
                
                var actual_types_str = ArrayList(u8).init(self.allocator);
                for (c.arguments, 0..) |arg, i| {
                    if (i > 0) try actual_types_str.appendSlice(", ");
                    if (arg.resolved_type) |rt| {
                        const rt_str = try std.fmt.allocPrint(self.allocator, "{}", .{rt.*});
                        try actual_types_str.appendSlice(rt_str);
                    } else {
                        try actual_types_str.appendSlice("unknown");
                    }
                }
                
                self.reportError(node.line, node.column, "TypeError: No matching overload found for function '{s}'. Expected: ({s}), Provided args: ({s})", .{ name, expected_types_str.items, actual_types_str.items });
                return error.TypeError;
            }
        }

        // Check for generic functions (not in regular scope because inferFunDecl returns early)
        if (c.type_args.len == 0) {
            if (self.generic_functions_ast.get(name)) |gen_node| {
            const gen_decl = gen_node.data.fun_decl;
            if (gen_decl.generic_params.len > 0) {
                var type_args = try self.allocator.alloc(*const EiwaType, gen_decl.generic_params.len);

                for (gen_decl.generic_params, 0..) |param_name, i| {
                    var found_type: ?*const EiwaType = null;
                    for (gen_decl.params, 0..) |p, arg_i| {
                        if (arg_i < c.arguments.len) {
                            if (p.type_ref) |tr| {
                                if (std.mem.eql(u8, tr.name, param_name) and tr.generic_args.len == 0) {
                                    found_type = c.arguments[arg_i].resolved_type.?;
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

                try self.monomorphizeFunction(name, type_args, final_mangled);

                const func_node = self.functions_ast.get(final_mangled).?;
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
                            arg.resolved_type = null;
                            _ = try self.inferNode(arg, scope);
                            if (!self.isCompatible(pt, arg.resolved_type.?)) {
                                self.reportError(arg.line, arg.column, "TypeError: Expected {} but found {} for argument {}.", .{ pt.*, arg.resolved_type.?.*, arg_i + 1 });
                                return error.TypeError;
                            }
                        }
                    }
                }

                t.* = ret_type.*;
                c.callee.data.identifier.resolved_c_name = final_mangled;
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
                        self.reportError(node.line, node.column, "TypeError: Expected {} for argument {} but got {}.", .{ expected_arg_type.*, arg_i + 1, arg.resolved_type.?.* });
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
                                std.debug.print("Failed to infer '{s}' for '{s}'. Prop: {s}. Arg type: {}\n", .{g_param, name, type_decl.primary_constructor[0].name, c.arguments[0].resolved_type.?.*});
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
                                    new_args[i] = cloned;
                                    _ = try self.inferNode(cloned, scope);
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
                                    arg.resolved_type = null;
                                    _ = try self.inferNode(arg, scope);
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
                    }
                    t.* = variable.*;
                    c.callee.data.identifier.resolved_c_name = rn;
                    return;
                }
            }
        }
        self.reportError(node.line, node.column, "TypeError: Undeclared function '{s}'.", .{name});
        return error.TypeError;
    } else if (c.callee.data == .get_expr) {
        _ = try self.inferNode(c.callee, scope);
        
        const g = c.callee.data.get_expr;
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
                            const arg_type = try self.inferNode(arg, scope);
                            const expected_type = try self.resolveTypeRef(f.params[arg_i].type_ref.?);
                            if (!self.isCompatible(expected_type, arg_type)) {
                                all_match = false;
                                break;
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
            const ret_type = matched_method.resolved_type.?.Function.return_type;
            const f = &matched_method.data.fun_decl;
            
            if (c.arguments.len < f.params.len) {
                var new_args = try self.allocator.alloc(*ASTNode, f.params.len);
                for (c.arguments, 0..) |arg, arg_i| {
                    new_args[arg_i] = arg;
                }
                var i = c.arguments.len;
                while (i < f.params.len) : (i += 1) {
                    const prop = f.params[i];
                    if (prop.initializer) |init_node| {
                        const cloned = try self.cloneNode(init_node);
                        _ = try self.inferNode(cloned, scope);
                        new_args[i] = cloned;
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
            
            for (c.arguments, 0..) |arg, i| {
                const arg_type = try self.inferNode(arg, scope);
                const expected_type = try self.resolveTypeRef(f.params[i].type_ref.?);
                if (!self.isCompatible(expected_type, arg_type)) {
                    self.reportError(arg.line, arg.column, "TypeError: Expected {} but found {} for argument {}.", .{ expected_type.*, arg_type.*, i + 1 });
                    return error.TypeError;
                }
            }
            
            t.* = ret_type.*;
            node.resolved_type = t;
            return;
        }

        // Fill in method default parameters!
        if (g.object.resolved_type) |obj_type| {
            const base_type = extractBaseType(obj_type);
            if (base_type.* == .Custom) {
                const class_name = base_type.Custom;
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
                        if (f.resolved_c_name) |rcn| {
                            c.callee.data.get_expr.resolved_c_name = rcn;
                        }


                        if (c.arguments.len < f.params.len) {

                            var new_args = try self.allocator.alloc(*ASTNode, f.params.len);
                            for (c.arguments, 0..) |arg, arg_i| {
                                new_args[arg_i] = arg;
                            }
                            var i = c.arguments.len;
                            while (i < f.params.len) : (i += 1) {
                                const prop = f.params[i];
                                if (prop.initializer) |init_node| {
                                    const cloned = try self.cloneNode(init_node);
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
                                if (f.params[arg_i].type_ref) |tr| {
                                    arg.expected_type = self.resolveTypeRef(tr) catch null;
                                }
                            }
                            _ = try self.inferNode(arg, scope);
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

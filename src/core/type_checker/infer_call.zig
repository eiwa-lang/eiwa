const std = @import("std");
const compat = @import("../compat.zig");
const ArrayList = compat.ArrayList;
const ast = @import("../ast.zig");
const infer_stmt_mod = @import("infer_stmt.zig");
const core = @import("core.zig");
const type_system = @import("../type_system.zig");

const ASTNode = core.ASTNode;
const TypeChecker = core.TypeChecker;
const Scope = core.Scope;
const EiwaType = core.EiwaType;
const extractBaseType = core.extractBaseType;
const isNullable = core.isNullable;

fn findExtensionWithDefaults(
    self: *TypeChecker,
    resolver: *TypeChecker,
    ext_list: ArrayList(*ASTNode),
    base_type: *const EiwaType,
    arg_count: usize,
    call_args: []const *ASTNode,
) ?*ASTNode {
    for (ext_list.items) |ext_node| {
        const f = &ext_node.data.fun_decl;
        if (f.receiver_type == null) continue;
        if (f.generic_params.len > 0) {
            if (matchGenericExtension(self, resolver, ext_node, base_type) == null) continue;
        } else {
            const rec_t = resolver.resolveHintTypeRef(f.receiver_type.?);
            if (rec_t == null) continue;
            if (!self.isCompatible(rec_t.?, base_type) and !self.isCompatible(base_type, rec_t.?)) continue;
        }
        if (arg_count > f.params.len) continue;
        var has_defaults = true;
        var i = arg_count;
        while (i < f.params.len) : (i += 1) {
            if (f.params[i].initializer == null) {
                has_defaults = false;
                break;
            }
        }
        if (!has_defaults) continue;
        if (!candidateHasNamedParams(f.params, call_args)) continue;
        return ext_node;
    }
    return null;
}

fn extParamIndex(params: []const []const u8, name: []const u8) ?usize {
    for (params, 0..) |p, i| {
        if (std.mem.eql(u8, p, name)) return i;
    }
    return null;
}

fn buildReceiverPattern(self: *TypeChecker, resolver: *TypeChecker, ref: *const ast.ASTTypeRef, params: []const []const u8) ?*const EiwaType {
    if (ref.generic_args.len == 0 and !ref.is_array and !ref.is_function and ref.union_types.len == 0) {
        if (extParamIndex(params, ref.name) != null) {
            const t = self.allocator.create(EiwaType) catch return null;
            t.* = .{ .GenericParam = ref.name };
            return t;
        }
        return resolver.resolveHintTypeRef(ref);
    }
    if (ref.is_array) {
        const elem = buildReceiverPattern(self, resolver, ref.generic_args[0], params) orelse return null;
        const t = self.allocator.create(EiwaType) catch return null;
        t.* = .{ .Array = elem };
        return t;
    }
    const actual_base = resolver.alias_map.get(ref.name) orelse ref.name;
    var args = self.allocator.alloc(*const EiwaType, ref.generic_args.len) catch return null;
    for (ref.generic_args, 0..) |ga, i| {
        args[i] = buildReceiverPattern(self, resolver, ga, params) orelse return null;
    }
    const out = self.allocator.create(EiwaType) catch return null;
    out.* = .{ .GenericInstance = .{ .base_name = actual_base, .type_args = args } };
    return out;
}

pub fn extensionReceiverPattern(self: *TypeChecker, resolver: *TypeChecker, ext_node: *ASTNode) ?*const EiwaType {
    const f = &ext_node.data.fun_decl;
    const rt_ref = f.receiver_type orelse return null;
    if (f.generic_params.len == 0) return resolver.resolveHintTypeRef(rt_ref);
    return buildReceiverPattern(self, resolver, rt_ref, f.generic_params);
}

fn genericArity(self: *TypeChecker, base_actual: []const u8) usize {
    if (self.classes_ast.get(base_actual)) |bn| {
        if (bn.data == .type_decl) return bn.data.type_decl.generic_params.len;
    }
    if (self.contracts_ast.get(base_actual)) |cn| {
        if (cn.data == .contract_decl) return cn.data.contract_decl.generic_params.len;
    }
    if (self.registry) |reg| {
        var it = reg.modules.iterator();
        while (it.next()) |entry| {
            const c = entry.value_ptr.checker;
            const ma = c.alias_map.get(base_actual) orelse base_actual;
            if (c.classes_ast.get(ma)) |bn| {
                if (bn.data == .type_decl) return bn.data.type_decl.generic_params.len;
            }
            if (c.contracts_ast.get(ma)) |cn| {
                if (cn.data == .contract_decl) return cn.data.contract_decl.generic_params.len;
            }
        }
    }
    return 1;
}

fn parseMangledType(self: *TypeChecker, name: []const u8) ?*const EiwaType {
    var bases = ArrayList([]const u8).init(self.allocator);
    defer bases.deinit();
    var ci = self.classes_ast.iterator();
    while (ci.next()) |e| {
        if (e.value_ptr.*.data == .type_decl and e.value_ptr.*.data.type_decl.generic_params.len > 0) {
            bases.append(e.key_ptr.*) catch return null;
        }
    }
    var ni = self.contracts_ast.iterator();
    while (ni.next()) |e| {
        if (e.value_ptr.*.data.contract_decl.generic_params.len > 0) {
            bases.append(e.key_ptr.*) catch return null;
        }
    }
    std.mem.sort([]const u8, bases.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return a.len > b.len;
        }
    }.lessThan);
    for (bases.items) |b| {
        if (!std.mem.startsWith(u8, name, b)) continue;
        const rest = name[b.len..];
        if (!std.mem.startsWith(u8, rest, "_")) continue;
        const inner = rest[1..];
        const arity = genericArity(self, b);
        const pieces = splitMangledPieces(self, inner, arity) orelse continue;
        if (pieces.len != arity) continue;
        var args = self.allocator.alloc(*const EiwaType, pieces.len) catch continue;
        var ok = true;
        for (pieces, 0..) |p, i| {
            args[i] = parseMangledType(self, p) orelse {
                ok = false;
                break;
            };
        }
        if (!ok) continue;
        const out = self.allocator.create(EiwaType) catch continue;
        out.* = .{ .GenericInstance = .{ .base_name = b, .type_args = args } };
        return out;
    }
    if (self.resolveHintTypeName(name, false)) |t| return t;
    return null;
}

fn splitMangledPieces(self: *TypeChecker, inner: []const u8, arity: usize) ?[][]const u8 {
    var pieces = ArrayList([]const u8).init(self.allocator);
    if (splitPiecesRec(self, inner, arity, &pieces)) return pieces.toOwnedSlice() catch null;
    return null;
}

fn splitPiecesRec(self: *TypeChecker, s: []const u8, n: usize, out: *ArrayList([]const u8)) bool {
    if (n == 0) return s.len == 0;
    if (s.len == 0) return false;
    if (n == 1) {
        if (parseMangledType(self, s) == null) return false;
        out.append(s) catch return false;
        return true;
    }
    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        if (s[i] != '_') continue;
        const head = s[0..i];
        if (parseMangledType(self, head) == null) continue;
        const checkpoint = out.items.len;
        out.append(head) catch return false;
        if (splitPiecesRec(self, s[i + 1 ..], n - 1, out)) return true;
        while (out.items.len > checkpoint) _ = out.pop();
    }
    return false;
}

pub fn unifyExtensionReceiver(self: *TypeChecker, bindings: *std.StringHashMap(*const EiwaType), params: []const []const u8, pattern: *const EiwaType, actual: *const EiwaType) bool {
    const act = extractBaseType(actual);
    switch (pattern.*) {
        .GenericParam, .Custom => |n| {
            const in_params = extParamIndex(params, n) != null;
            if (!in_params and pattern.* == .GenericParam) return false;
            if (in_params) {
                if (bindings.get(n)) |b| {
                    return self.isCompatible(b, act) or self.isCompatible(act, b);
                }
                bindings.put(n, act) catch return false;
                return true;
            }
            return self.isCompatible(pattern, act) or self.isCompatible(act, pattern);
        },
        .GenericInstance => |gi| {
            const rbase = self.alias_map.get(gi.base_name) orelse gi.base_name;
            switch (act.*) {
                .GenericInstance => |ag| {
                    const abase = self.alias_map.get(ag.base_name) orelse ag.base_name;
                    if (!std.mem.eql(u8, rbase, abase)) return false;
                    if (gi.type_args.len != ag.type_args.len) return false;
                    for (gi.type_args, ag.type_args) |ra, aa| {
                        if (!unifyExtensionReceiver(self, bindings, params, ra, aa)) return false;
                    }
                    return true;
                },
                .Custom => |mangled| {
                    const inst = parseMangledType(self, mangled) orelse return self.isCompatible(pattern, act);
                    if (inst.* != .GenericInstance) return self.isCompatible(pattern, act);
                    return unifyExtensionReceiver(self, bindings, params, pattern, inst);
                },
                else => return self.isCompatible(pattern, act),
            }
        },
        else => return self.isCompatible(pattern, act) or self.isCompatible(act, pattern),
    }
}

pub fn matchGenericExtension(self: *TypeChecker, resolver: *TypeChecker, ext_node: *ASTNode, actual: *const EiwaType) ?[]*const EiwaType {
    const f = &ext_node.data.fun_decl;
    if (f.generic_params.len == 0) return null;
    var bindings = std.StringHashMap(*const EiwaType).init(self.allocator);
    defer bindings.deinit();
    if (matchExtensionBindings(self, resolver, ext_node, actual, &bindings) == null) return null;
    var out = self.allocator.alloc(*const EiwaType, f.generic_params.len) catch return null;
    for (f.generic_params, 0..) |p, i| {
        out[i] = bindings.get(p) orelse return null;
    }
    return out;
}

// Unified match filling caller-owned bindings; returns the pattern's base
// for mangling, or null. Tries the defining module first, then the registry.
fn matchExtensionBindings(self: *TypeChecker, resolver: *TypeChecker, ext_node: *ASTNode, actual: *const EiwaType, bindings: *std.StringHashMap(*const EiwaType)) ?[]const u8 {
    const f = &ext_node.data.fun_decl;
    if (extensionReceiverPattern(self, resolver, ext_node)) |pattern| {
        if (unifyExtensionReceiver(self, bindings, f.generic_params, pattern, actual)) {
            if (pattern.* == .GenericInstance) return pattern.GenericInstance.base_name;
            return "ext";
        }
    }
    if (self.registry) |reg| {
        var it = reg.modules.iterator();
        while (it.next()) |entry| {
            const checker = entry.value_ptr.checker;
            if (extensionReceiverPattern(self, checker, ext_node)) |pattern| {
                if (unifyExtensionReceiver(self, bindings, f.generic_params, pattern, actual)) {
                    if (pattern.* == .GenericInstance) return pattern.GenericInstance.base_name;
                    return "ext";
                }
            }
        }
    }
    return null;
}

fn candidateHasNamedParams(params: []const ast.Param, call_args: []const *ASTNode) bool {
    for (call_args) |arg| {
        if (arg.data != .named_arg) continue;
        var found_name = false;
        for (params) |p| {
            if (std.mem.eql(u8, p.name, arg.data.named_arg.name)) {
                found_name = true;
                break;
            }
        }
        if (!found_name) return false;
    }
    return true;
}

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
            return prop.resolved_type orelse self.resolveHintTypeRef(prop.type_ref);
        }
    }
    for (c.body_fields) |prop| {
        if (std.mem.eql(u8, prop.name, member_name)) {
            return prop.resolved_type orelse self.resolveHintTypeRef(prop.type_ref);
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

    if (!has_named and c.arguments.len == params.len and !has_varargs) {
        // Positional fast path: params/args already aligned.
        return;
    }

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
                if (c.callee.data == .get_expr) {
                    // Member/extension call: bind `this` to the receiver so
                    // defaults like `code: Int = this.code` resolve (Kotlin-like).
                    // Free-function calls keep the previous behavior.
                    try self.substituteParam(cloned, "this", c.callee.data.get_expr.object);
                }
                // Propagate the declared param type so an empty default like
                // `params: List<String> = []` infers (mirrors every other default-fill site).
                if (p.type_ref) |tr| {
                    cloned.expected_type = self.resolveHintTypeRef(tr);
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

    // Aligned with params now (defaults filled, named reordered).
    c.arguments = final_args;
}

pub fn getArgForProp(arguments: []const *ASTNode, props: []const ast.ClassProp, prop_i: usize) ?*ASTNode {
    if (prop_i >= props.len) return null;
    const target_prop = props[prop_i];

    // 1. If any argument explicitly names this property:
    for (arguments) |arg| {
        if (arg.data == .named_arg and std.mem.eql(u8, arg.data.named_arg.name, target_prop.name)) {
            return arg.data.named_arg.value;
        }
    }

    // 2. Otherwise map positional arguments to un-named slots:
    var pos_i: usize = 0;
    for (arguments) |arg| {
        if (arg.data == .named_arg) continue;
        while (pos_i < props.len) {
            var is_named_slot = false;
            for (arguments) |other| {
                if (other.data == .named_arg and std.mem.eql(u8, other.data.named_arg.name, props[pos_idx_inner: {
                    break :pos_idx_inner pos_i;
                }].name)) {
                    is_named_slot = true;
                    break;
                }
            }
            if (!is_named_slot) break;
            pos_i += 1;
        }
        if (pos_i == prop_i) return arg;
        pos_i += 1;
    }
    return null;
}

pub fn resolveConstructorArguments(self: *TypeChecker, node: *ASTNode, props: []const ast.ClassProp, scope: *Scope) anyerror!void {
    var c = &node.data.call_expr;
    var has_named = false;
    for (c.arguments) |arg| {
        if (arg.data == .named_arg) {
            has_named = true;
            break;
        }
    }

    const has_varargs = props.len > 0 and props[props.len - 1].is_varargs;
    const varargs_idx: ?usize = if (has_varargs) props.len - 1 else null;

    if (!has_named and c.arguments.len == props.len and !has_varargs) return;

    if (c.arguments.len > props.len and varargs_idx == null) {
        self.reportError(node.line, node.column, "TypeError: Expected at most {} arguments for constructor, got {}.", .{ props.len, c.arguments.len });
        return error.TypeError;
    }

    var new_args = try self.allocator.alloc(?*ASTNode, props.len);
    for (new_args) |*slot| {
        slot.* = null;
    }

    var varargs_buf = ArrayList(*ASTNode).init(self.allocator);

    var pos_i: usize = 0;
    for (c.arguments) |arg| {
        if (arg.data == .named_arg) {
            const name = arg.data.named_arg.name;
            const val = arg.data.named_arg.value;
            var prop_match: ?usize = null;
            for (props, 0..) |p, pi| {
                if (std.mem.eql(u8, p.name, name)) {
                    prop_match = pi;
                    break;
                }
            }
            if (prop_match) |pi| {
                if (new_args[pi] != null) {
                    self.reportError(arg.line, arg.column, "TypeError: Duplicate argument provided for parameter '{s}'.", .{name});
                    return error.TypeError;
                }
                new_args[pi] = val;
            } else {
                self.reportError(arg.line, arg.column, "TypeError: Unknown parameter '{s}' in constructor call.", .{name});
                return error.TypeError;
            }
        } else {
            while (pos_i < props.len and new_args[pos_i] != null) : (pos_i += 1) {}
            if (pos_i >= props.len) {
                // Varargs overflow: the extra positional arg is collected into the List.
                if (varargs_idx != null) {
                    try varargs_buf.append(arg);
                    continue;
                }
                self.reportError(arg.line, arg.column, "TypeError: Too many positional arguments in constructor call.", .{});
                return error.TypeError;
            }
            // A positional arg landing directly on the variadic property is
            // collected into its List rather than passed as a scalar.
            if (varargs_idx) |vi| {
                if (pos_i == vi) {
                    try varargs_buf.append(arg);
                    pos_i += 1;
                    continue;
                }
            }
            new_args[pos_i] = arg;
            pos_i += 1;
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
            const elem_t = try self.resolveTypeRef(props[vi].type_ref);
            list_node.expected_type = try self.makeListType(elem_t, node.line, node.column);
            _ = try self.inferNode(list_node, scope);
            new_args[vi] = list_node;
        }
    }

    for (props, 0..) |p, pi| {
        if (new_args[pi] == null) {
            if (p.initializer) |init_node| {
                const cloned = try self.cloneNode(init_node);
                for (props[0..pi], 0..) |prev_p, prev_i| {
                    if (new_args[prev_i]) |prev_arg| {
                        try self.substituteParam(cloned, prev_p.name, prev_arg);
                    }
                }
                cloned.expected_type = p.resolved_type orelse self.resolveHintTypeRef(p.type_ref);
                _ = try self.inferNode(cloned, scope);
                new_args[pi] = cloned;
            } else {
                self.reportError(node.line, node.column, "TypeError: Missing argument for constructor parameter '{s}' which has no default value.", .{p.name});
                return error.TypeError;
            }
        }
    }

    var final_args = try self.allocator.alloc(*ASTNode, props.len);
    for (new_args, 0..) |opt_arg, i| {
        final_args[i] = opt_arg.?;
    }

    c.arguments = final_args;
}

fn propagateParamTypes(self: *TypeChecker, arguments: []const *ASTNode, params: []const ast.Param) void {
    for (params, 0..) |p, pi| {
        var target_arg: ?*ASTNode = null;
        for (arguments) |arg| {
            if (arg.data == .named_arg and std.mem.eql(u8, arg.data.named_arg.name, p.name)) {
                target_arg = arg;
                break;
            }
        }
        if (target_arg == null and pi < arguments.len and arguments[pi].data != .named_arg) {
            target_arg = arguments[pi];
        }
        if (target_arg) |arg| {
            if (arg.expected_type == null and p.type_ref != null) {
                if (self.resolveHintTypeRef(p.type_ref.?)) |pt| {
                    arg.expected_type = pt;
                    if (arg.data == .named_arg) {
                        arg.data.named_arg.value.expected_type = pt;
                    }
                }
            }
        }
    }
}

/// Best-effort inference for speculative probes (receiver/argument warm-up,
/// overload viability). Prints nothing: the authoritative pass re-infers and
/// reports. Errors still propagate as codes for `catch` to observe.
fn probeInfer(self: *TypeChecker, node: *ASTNode, scope: *Scope) anyerror!void {
    self.speculative_depth += 1;
    defer self.speculative_depth -= 1;
    _ = try self.inferNode(node, scope);
}

pub fn prePropagateExpectedTypes(self: *TypeChecker, node: *ASTNode, scope: *Scope) void {    var c = &node.data.call_expr;
    if (c.callee.data == .identifier) {
        const name = c.callee.data.identifier.name;
        const class_name = self.alias_map.get(name) orelse name;
        if (self.classes_ast.get(class_name)) |class_node| {
            const type_decl = class_node.data.type_decl;
            for (type_decl.primary_constructor, 0..) |prop, prop_i| {
                if (getArgForProp(c.arguments, type_decl.primary_constructor, prop_i)) |arg| {
                    if (arg.expected_type == null) {
                        const pt = prop.resolved_type orelse self.resolveHintTypeRef(prop.type_ref);
                        if (pt) |resolved| {
                            arg.expected_type = resolved;
                            if (arg.data == .named_arg) {
                                arg.data.named_arg.value.expected_type = resolved;
                            }
                        }
                    }
                }
            }
            return;
        }

        if (scope.lookupFunctions(name)) |overloads| {
            if (overloads.len == 1 and overloads[0].* == .Function) {
                const f = overloads[0].Function;
                if (self.functions_ast.get(f.c_name)) |fn_node| {
                    propagateParamTypes(self, c.arguments, fn_node.data.fun_decl.params);
                    return;
                }
            }
        }

        if (self.functions_ast.get(name)) |fn_node| {
            propagateParamTypes(self, c.arguments, fn_node.data.fun_decl.params);
            return;
        }
    } else if (c.callee.data == .get_expr) {
        const g = &c.callee.data.get_expr;
        if (g.object.resolved_type == null) {
            // Qualified skill access is rewritten by infer_member to `this.Skill_member`.
            var is_skill_receiver = false;
            if (g.object.data == .identifier) {
                const skill_src = g.object.data.identifier.name;
                const skill_actual = self.alias_map.get(skill_src) orelse skill_src;
                is_skill_receiver = self.skills_ast.contains(skill_actual);
                if (!is_skill_receiver and self.registry != null) {
                    var mod_it = self.registry.?.modules.iterator();
                    while (mod_it.next()) |entry| {
                        const reg_actual = entry.value_ptr.checker.alias_map.get(skill_src) orelse skill_actual;
                        if (entry.value_ptr.checker.skills_ast.contains(reg_actual)) {
                            is_skill_receiver = true;
                            break;
                        }
                    }
                }
            }
            if (!is_skill_receiver) {
                _ = probeInfer(self, g.object, scope) catch null;
            }
        }
        if (g.object.resolved_type) |obj_t| {
            const base_type = extractBaseType(obj_t);
            if (base_type.* == .Custom) {
                const class_name = self.alias_map.get(base_type.Custom) orelse base_type.Custom;
                const methods_list: ?[]const *ASTNode = if (self.classes_ast.get(class_name)) |cn| cn.data.type_decl.methods else if (self.objects_ast.get(class_name)) |on| on.data.object_decl.members else null;
                if (methods_list) |methods| {
                    for (methods) |method| {
                        if (method.data == .fun_decl and std.mem.eql(u8, method.data.fun_decl.name, g.name)) {
                            propagateParamTypes(self, c.arguments, method.data.fun_decl.params);
                            break;
                        }
                    }
                }
            }
        }
    }
}



/// Resolves the element type `T` of a variadic parameter declared as `T...`.
/// Returns null when the callee has no variadic parameter.
fn varargsElemType(self: *TypeChecker, fun_decl: anytype) ?*EiwaType {
    if (fun_decl.params.len == 0 or !fun_decl.params[fun_decl.params.len - 1].is_varargs) return null;
    const p = fun_decl.params[fun_decl.params.len - 1];
    if (p.type_ref) |tr| {
        if (self.resolveHintTypeRef(tr)) |t| return @constCast(t);
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
                    _ = probeInfer(self, val_node, scope) catch return false;
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
                if (!provided.items[search_i] and extractBaseType(f.params[search_i]).* == .Function) {
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
                    _ = probeInfer(self, arg, scope) catch return false;
                }
                if (arg.resolved_type) |at| {
                    const elem_t = varargsElemType(self, fun_decl) orelse return false;
                    if (!self.isCompatible(elem_t, at)) return false;
                }
                continue;
            }
            provided.items[pos_i] = true;
            if (arg.resolved_type == null) {
                _ = probeInfer(self, arg, scope) catch return false;
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
    const fn_name = try std.fmt.allocPrint(self.allocator, "__cblambda_{d}_{d}_{d}", .{ arg.line, arg.column, self.trampolines.count() });

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
                        try self.monomorphizeFunction(method, type_args, final_mangled, if (is_object) null else base_type);

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
                    const param_type = if (func_decl.params[arg_i].type_ref) |tr| self.resolveHintTypeRef(tr) else null;
                                if (param_type) |pt| {
                                    arg.expected_type = pt;
                                    if (arg.resolved_type == null) {
                                        _ = try self.inferNode(arg, scope);
                                    }
                                    if (!self.isCompatible(pt, arg.resolved_type.?)) {
                                        self.reportError(arg.line, arg.column, "TypeError: Expected {f} but found {f} for argument {}.", .{ pt.*, arg.resolved_type.?.*, arg_i + 1 });
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
        if (self.lookupGenericFunction(name, c.arguments.len)) |gen_node| {
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

            try self.monomorphizeFunction(gen_node, type_args, final_mangled, null);

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
                    const param_type = if (fun_decl.params[arg_i].type_ref) |tr| self.resolveHintTypeRef(tr) else null;
                    if (param_type) |pt| {
                        arg.expected_type = pt;
                        if (arg.resolved_type == null) {
                            _ = try self.inferNode(arg, scope);
                        }
                        if (!self.isCompatible(pt, arg.resolved_type.?)) {
                            self.reportError(arg.line, arg.column, "TypeError: Expected {f} but found {f} for argument {}.", .{ pt.*, arg.resolved_type.?.*, arg_i + 1 });
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

    try self.checkGenericTypeArgs(class_name, type_args, node.line, node.column);

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

    try resolveConstructorArguments(self, node, mono_decl.primary_constructor, scope);


    for (c.arguments, 0..) |arg, arg_i| {
        const expected = mono_decl.primary_constructor[arg_i].resolved_type orelse try self.resolveTypeRef(mono_decl.primary_constructor[arg_i].type_ref);
        arg.expected_type = expected;
        if (arg.resolved_type == null) {
            _ = try self.inferNode(arg, scope);
        }
        if (arg.resolved_type == null or !self.isCompatible(expected, arg.resolved_type.?)) {
            self.reportError(arg.line, arg.column, "TypeError: Expected {f} for argument {} of '{s}', got {f}.", .{ expected.*, arg_i + 1, name, arg.resolved_type.?.* });
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



fn mkDesugarThrowIdent(self: *TypeChecker, line: usize, col: usize, name: []const u8) anyerror!*ASTNode {
    const ident = try infer_stmt_mod.mkDesugarIdent(self, line, col, name);
    const ctor = try self.allocator.create(ASTNode);
    ctor.* = .{ .line = line, .column = col, .resolved_type = null, .data = .{ .call_expr = .{
        .callee = ident,
        .arguments = &.{},
    } } };
    const throw_node = try self.allocator.create(ASTNode);
    throw_node.* = .{ .line = line, .column = col, .resolved_type = null, .data = .{ .throw_stmt = .{ .expr = ctor } } };
    return throw_node;
}

fn bodyHasReturn(node: *ASTNode, valued_only: bool) bool {
    return core.visitEachNode(node, valued_only, bodyReturnEnter) catch false;
}

fn bodyReturnEnter(valued_only: bool, node: *ASTNode) anyerror!core.VisitAction {
    switch (node.data) {
        .return_stmt => |r| {
            if (!valued_only) return .stop;
            if (r.value != null) return .stop;
            return .recurse;
        },
        .lambda_expr, .fun_decl => return .prune,
        .program, .import_stmt => return .prune,
        else => return .recurse,
    }
}

/// Valued-`leave` enters shared by delivery, probing, and conversion.
/// Stops (nested loops/lambdas/functions keep their own target) live in
/// `core.visitEachNode` callers via prune; each enter below only holds its
/// leaf action.
fn collectValuedEnter(out: *ArrayList(*ASTNode), node: *ASTNode) anyerror!core.VisitAction {
    switch (node.data) {
        .while_stmt, .for_stmt, .lambda_expr, .fun_decl => return .prune,
        .break_stmt => |b| {
            if (b.value) |v| {
                if (v.data == .throw_stmt) return .prune;
                try out.append(v);
                return .prune;
            }
            return .recurse;
        },
        else => return .recurse,
    }
}

fn probeValuedEnter(found: *bool, node: *ASTNode) anyerror!core.VisitAction {
    switch (node.data) {
        .while_stmt, .for_stmt, .lambda_expr, .fun_decl => return .prune,
        .break_stmt => |b| {
            if (b.value) |v| {
                if (v.data == .throw_stmt) return .prune;
                found.* = true;
                return .stop;
            }
            return .recurse;
        },
        else => return .recurse,
    }
}

const ConvertValuedCtx = struct { tc: *TypeChecker, line: usize, col: usize };

fn convertValuedEnter(ctx: ConvertValuedCtx, node: *ASTNode) anyerror!core.VisitAction {
    switch (node.data) {
        .while_stmt, .for_stmt, .lambda_expr, .fun_decl => return .prune,
        .break_stmt => |b| {
            if (b.value) |v| {
                if (v.data == .throw_stmt) return .prune;
                const lv_ident = try infer_stmt_mod.mkDesugarIdent(ctx.tc, ctx.line, ctx.col, "LeaveValue");
                const lv_arg = try ctx.tc.allocator.alloc(*ASTNode, 1);
                lv_arg[0] = v;
                const lv_call = try infer_stmt_mod.mkDesugarNode(ctx.tc, ctx.line, ctx.col, .{ .call_expr = .{
                    .callee = lv_ident,
                    .arguments = lv_arg,
                } });
                node.data = .{ .throw_stmt = .{ .expr = lv_call } };
                return .prune;
            }
            return .recurse;
        },
        else => return .recurse,
    }
}

/// Value delivery setup for inlined (`@Embed`) calls: unifies delivered types
/// across blocks (temp scopes bind each block's params), converts `leave v`
/// to `throw LeaveValue(v)`. Null when no valued leaves. The caller
/// guarantees `@Embed` (inline entry checks); anything reaching the normal
/// call path with valued leaves is rejected by `rejectValuedLeaves`.
fn prepareValueDelivery(self: *TypeChecker, scope: *Scope, blocks: []const BlockArg, fun_decl: anytype, tag: []const u8, line: usize, col: usize) anyerror!?struct { t: *const EiwaType, out_name: []const u8 } {
    var deliver_t: ?*const EiwaType = null;
    for (blocks) |b| {
        var bleaves = ArrayList(*ASTNode).init(self.allocator);
        defer bleaves.deinit();
        for (b.lam.data.lambda_expr.body) |s| {
            _ = try core.visitEachNode(s, &bleaves, collectValuedEnter);
        }
        if (bleaves.items.len == 0) continue;
        // Declared block signature for param types.
        var sig_params: ?[]const *const EiwaType = null;
        for (fun_decl.params) |p| {
            if (!std.mem.eql(u8, p.name, b.name)) continue;
            if (p.type_ref) |tr| {
                const ft = try self.resolveTypeRef(tr);
                if (ft.* == .Function) sig_params = ft.Function.params;
            }
        }
        var tmp = Scope.init(self.allocator, scope);
        defer tmp.deinit();
        const lparams = b.lam.data.lambda_expr.params;
        if (lparams.len == 0) {
            if (sig_params) |sp| {
                if (sp.len == 1) try tmp.define("it", sp[0], false, false);
            }
        } else {
            for (lparams, 0..) |lp, li| {
                var pt: ?*const EiwaType = null;
                if (lp.type_ref) |tr| pt = try self.resolveTypeRef(tr);
                if (pt == null) {
                    if (sig_params) |sp| {
                        if (li < sp.len) pt = sp[li];
                    }
                }
                if (pt) |t| {
                    try tmp.define(lp.name, t, false, false);
                } else {
                    self.reportError(line, col, "TypeError: cannot infer block parameter type for value delivery.", .{});
                    return error.TypeError;
                }
            }
        }
        for (bleaves.items) |v| {
            const vt = try self.inferNode(v, &tmp);
            if (vt.* == .Void) {
                self.reportError(v.line, v.column, "TypeError: 'leave' value cannot be Void. Use bare 'leave' to exit.", .{});
                return error.TypeError;
            }
            if (deliver_t) |dt| {
                if (!self.isCompatible(dt, vt) and !self.isCompatible(vt, dt)) {
                    self.reportError(v.line, v.column, "TypeError: 'leave' values have incompatible types {f} and {f}.", .{ dt.*, vt.* });
                    return error.TypeError;
                }
            } else {
                deliver_t = vt;
            }
        }
        const cvt = ConvertValuedCtx{ .tc = self, .line = line, .col = col };
        for (b.lam.data.lambda_expr.body) |s| {
            _ = try core.visitEachNode(s, cvt, convertValuedEnter);
        }
    }
    const dt = deliver_t orelse return null;
    const out_name = try std.fmt.allocPrint(self.allocator, "{s}_out", .{tag});
    return .{ .t = dt, .out_name = out_name };
}



/// Valued `leave` only delivers through `@Embed` inlining (handled before
/// this point): anywhere else it is a `TypeError` here instead of
/// surfacing as a lambda return-type mismatch.
fn rejectValuedLeaves(self: *TypeChecker, node: *ASTNode) anyerror!void {
    for (node.data.call_expr.arguments) |arg| {
        const lam = if (arg.data == .named_arg) arg.data.named_arg.value else arg;
        if (lam.data != .lambda_expr) continue;
        for (lam.data.lambda_expr.body) |s| {
            var found = false;
            _ = try core.visitEachNode(s, &found, probeValuedEnter);
            if (found) {
                self.reportError(node.line, node.column, "TypeError: 'leave' with a value is only supported inside '@Embed' function blocks (e.g. 'repeat'/'loop').", .{});
                return error.TypeError;
            }
        }
    }
}

/// Source-level `TypeRef` for an inferred type (synthesized `var __out: T?`).
fn eiwaTypeToRef(self: *TypeChecker, t: *const EiwaType, nullable: bool, line: usize, col: usize) anyerror!*const ast.ASTTypeRef {
    const tr = try self.allocator.create(ast.ASTTypeRef);
    switch (t.*) {
        .Int => tr.* = .{ .name = "Int", .generic_args = &.{}, .is_array = false, .is_nullable = nullable },
        .Bool => tr.* = .{ .name = "Bool", .generic_args = &.{}, .is_array = false, .is_nullable = nullable },
        .Double => tr.* = .{ .name = "Double", .generic_args = &.{}, .is_array = false, .is_nullable = nullable },
        .String => tr.* = .{ .name = "String", .generic_args = &.{}, .is_array = false, .is_nullable = nullable },
        .Null => tr.* = .{ .name = "Null", .generic_args = &.{}, .is_array = false, .is_nullable = true },
        .Custom => |n| tr.* = .{ .name = n, .generic_args = &.{}, .is_array = false, .is_nullable = nullable },
        .GenericInstance => |gi| {
            var args = try self.allocator.alloc(*const ast.ASTTypeRef, gi.type_args.len);
            for (gi.type_args, 0..) |a, i| args[i] = try eiwaTypeToRef(self, a, false, line, col);
            tr.* = .{ .name = gi.base_name, .generic_args = args, .is_array = false, .is_nullable = nullable };
        },
        .Array => |elem| {
            const inner = try eiwaTypeToRef(self, elem, false, line, col);
            const g_args = try self.allocator.alloc(*const ast.ASTTypeRef, 1);
            g_args[0] = inner;
            tr.* = .{ .name = "", .generic_args = g_args, .is_array = true, .is_nullable = nullable };
        },
        else => {
            self.reportError(line, col, "TypeError: 'leave' value of this type cannot be delivered by 'repeat'/'loop'.", .{});
            return error.TypeError;
        },
    }
    return tr;
}

/// True when the subtree declares a nested type-like entity (type, object,
/// contract, skill, enum, lib, test). Those keep definition-site identity;
/// pasting them per call site risks duplicate emission: normal call instead.
fn bodyHasNestedDecl(node: *ASTNode) bool {
    return core.visitEachNode(node, {}, nestedDeclEnter) catch false;
}

fn nestedDeclEnter(ctx: void, node: *ASTNode) anyerror!core.VisitAction {
    _ = ctx;
    switch (node.data) {
        .type_decl, .object_decl, .contract_decl, .skill_decl, .enum_decl, .lib_decl, .test_decl, .fun_decl => return .stop,
        .program, .import_stmt => return .prune,
        else => return .recurse,
    }
}

/// `@Embed` on the declaration.
fn funIsEmbed(annotations: []const ast.Annotation) bool {
    for (annotations) |ann| {
        if (std.mem.eql(u8, ann.name, "Embed")) return true;
    }
    return false;
}

fn rewriteEmbedReturns(self: *TypeChecker, node: *ASTNode) anyerror!usize {
    var n: usize = 0;
    const ctx = CountCtx{ .tc = self, .count = &n };
    _ = try core.visitEachNode(node, ctx, rewriteReturnEnter);
    return n;
}

const CountCtx = struct { tc: *TypeChecker, count: *usize };

fn rewriteReturnEnter(ctx: CountCtx, node: *ASTNode) anyerror!core.VisitAction {
    switch (node.data) {
        .return_stmt => |r| {
            if (r.value != null) return .prune;
            node.data = (try mkDesugarThrowIdent(ctx.tc, node.line, node.column, "EmbedReturn")).data;
            ctx.count.* += 1;
            return .prune;
        },
        .lambda_expr, .fun_decl => return .prune,
        else => return .recurse,
    }
}


/// Bound names in a subtree (shadow bail for substitution).
fn collectBoundNames(node: *ASTNode, names: *std.StringHashMap(void)) anyerror!void {
    _ = try core.visitEachNode(node, names, boundNameEnter);
}

fn boundNameEnter(names: *std.StringHashMap(void), node: *ASTNode) anyerror!core.VisitAction {
    switch (node.data) {
        .var_decl => |v| try names.put(v.name, {}),
        .for_stmt => |f| {
            try names.put(f.index_name orelse "it", {});
            try names.put(f.item_name, {});
        },
        .try_stmt => |ts| for (ts.catches) |cb| {
            if (cb.var_name) |vn| try names.put(vn, {});
        },
        .lambda_expr => |l| for (l.params) |p| try names.put(p.name, {}),
        .fun_decl => |f| {
            try names.put(f.name, {});
            for (f.params) |p| try names.put(p.name, {});
        },
        else => {},
    }
    return .recurse;
}

fn substituteEmbedParam(self: *TypeChecker, node: *ASTNode, param_name: []const u8, fresh: []const u8, bailed: *bool) anyerror!void {
    const ctx = SubstCtx{ .tc = self, .param_name = param_name, .fresh = fresh, .bailed = bailed };
    _ = try core.visitEachNode(node, ctx, substEmbedEnter);
}

const SubstCtx = struct { tc: *TypeChecker, param_name: []const u8, fresh: []const u8, bailed: *bool };

fn substEmbedEnter(ctx: SubstCtx, node: *ASTNode) anyerror!core.VisitAction {
    switch (node.data) {
        .identifier => |id| {
            if (std.mem.eql(u8, id.name, ctx.param_name)) {
                const renamed = try ctx.tc.allocator.dupe(u8, ctx.fresh);
                node.data.identifier.name = renamed;
            }
            return .recurse;
        },
        .call_expr => |c| {
            if (c.callee.data == .identifier and std.mem.eql(u8, c.callee.data.identifier.name, ctx.param_name)) {
                ctx.bailed.* = true;
                return .prune;
            }
            return .recurse;
        },
        else => return .recurse,
    }
}

/// Clears inference state that doesn't survive cross-scope pasting (fresh inference recomputes the rest). Without this, stale flags miscompile.
fn clearEmbedState(node: *ASTNode) void {
    _ = core.visitEachNode(node, {}, clearEmbedEnter) catch unreachable;
}

fn clearEmbedEnter(ctx: void, node: *ASTNode) anyerror!core.VisitAction {
    _ = ctx;
    // Every node in a callee-body clone is definition-derived (see
    // `from_embed_body`): user-written code pasted later keeps `false`.
    node.from_embed_body = true;
    switch (node.data) {
        .identifier => |*id| {
            id.resolved_c_name = null;
            id.is_class_property = false;
            id.is_boxed = false;
            id.is_box_ref = false;
            id.owner_type_c_name = null;
        },
        .break_stmt => |*b| {
            b.is_lambda_break = false;
        },
        else => {},
    }
    node.expected_type = null;
    node.box_nullable_scalar = false;
    return .recurse;
}

fn pasteEmbedBlock(self: *TypeChecker, callnode: *ASTNode, lam: *ASTNode, line: usize, col: usize) anyerror!void {
    const callargs = callnode.data.call_expr.arguments;
    const lparams = lam.data.lambda_expr.params;
    var bindings = ArrayList(*ASTNode).init(self.allocator);
    if (lparams.len == 0) {
        if (callargs.len == 1) {
            const val_it = try self.allocator.create(ASTNode);
            val_it.* = .{ .line = line, .column = col, .resolved_type = null, .data = .{ .var_decl = .{ .is_mut = false, .name = "it", .type_ref = null, .initializer = callargs[0] } } };
            try bindings.append(val_it);
        } else if (callargs.len != 0) {
            self.reportError(line, col, "TypeError: block takes no parameters but got {} arguments.", .{callargs.len});
            return error.TypeError;
        }
    } else {
        if (callargs.len != lparams.len) {
            self.reportError(line, col, "TypeError: block takes {} parameters but got {} arguments.", .{ lparams.len, callargs.len });
            return error.TypeError;
        }
        for (lparams, 0..) |p, i| {
            const val_p = try self.allocator.create(ASTNode);
            val_p.* = .{ .line = line, .column = col, .resolved_type = null, .data = .{ .var_decl = .{ .is_mut = false, .name = p.name, .type_ref = null, .initializer = callargs[i] } } };
            try bindings.append(val_p);
        }
    }
    for (lam.data.lambda_expr.body) |s| {
        try bindings.append(try self.cloneNode(s));
    }
    callnode.data = .{ .block = .{ .statements = try bindings.toOwnedSlice(), .is_value = true } };
}

/// Recursively pastes block invocations in an inlined tree.
fn pasteEmbedBlocks(self: *TypeChecker, node: *ASTNode, blocks: []const BlockArg, line: usize, col: usize) anyerror!void {
    const ctx = PasteCtx{ .tc = self, .blocks = blocks, .line = line, .col = col };
    _ = try core.visitEachNode(node, ctx, pasteEmbedEnter);
}

const PasteCtx = struct { tc: *TypeChecker, blocks: []const BlockArg, line: usize, col: usize };

fn pasteEmbedEnter(ctx: PasteCtx, node: *ASTNode) anyerror!core.VisitAction {
    if (node.data == .call_expr) {
        const c = node.data.call_expr;
        if (c.callee.data == .identifier) {
            for (ctx.blocks) |b| {
                if (std.mem.eql(u8, c.callee.data.identifier.name, b.name)) {
                    try pasteEmbedBlock(ctx.tc, node, b.lam, ctx.line, ctx.col);
                    return .prune;
                }
            }
        }
    }
    return .recurse;
}

const BlockArg = struct {
    name: []const u8,
    lam: *ASTNode,
};

/// Uniformly renames bound names to fresh ones (scope structure is
/// preserved: shadowing survives relabeling). Skips `it` (implicit forms
/// resolve in place) — value params are substituted, block markers matched
/// structurally, so neither may be renamed.
fn renameEmbedNames(self: *TypeChecker, node: *ASTNode, map: *std.StringHashMap([]const u8)) anyerror!void {
    const ctx = RenameCtx{ .tc = self, .map = map };
    _ = try core.visitEachNode(node, ctx, renameEmbedEnter);
}

const RenameCtx = struct { tc: *TypeChecker, map: *std.StringHashMap([]const u8) };

fn renameEmbedEnter(ctx: RenameCtx, node: *ASTNode) anyerror!core.VisitAction {
    const self = ctx.tc;
    const map = ctx.map;
    switch (node.data) {
        .identifier => |*id| {
            if (std.mem.eql(u8, id.name, "it")) return .recurse;
            if (map.get(id.name)) |fresh| {
                id.name = fresh;
            }
        },
        .var_decl => |*v| {
            if (!std.mem.eql(u8, v.name, "it")) {
                if (map.get(v.name)) |fresh| v.name = fresh;
            }
        },
        .for_stmt => |*f| {
            if (f.index_name) |idx| {
                if (!std.mem.eql(u8, idx, "it")) {
                    if (map.get(idx)) |fresh| f.index_name = fresh;
                }
            }
            if (!std.mem.eql(u8, f.item_name, "it")) {
                if (map.get(f.item_name)) |fresh| f.item_name = fresh;
            }
        },
        .try_stmt => |*ts| {
            var renamed = false;
            for (ts.catches) |cb| {
                if (cb.var_name) |vn| {
                    if (!std.mem.eql(u8, vn, "it") and map.get(vn) != null) renamed = true;
                }
            }
            // CatchBlock is const: rebuild the slice when a var renames.
            if (renamed) {
                var new_catches = try self.allocator.alloc(ast.CatchBlock, ts.catches.len);
                for (ts.catches, 0..) |cb, i| {
                    new_catches[i] = cb;
                    if (cb.var_name) |vn| {
                        if (!std.mem.eql(u8, vn, "it")) {
                            if (map.get(vn)) |fresh| new_catches[i].var_name = fresh;
                        }
                    }
                }
                ts.catches = new_catches;
            }
        },
        .assignment => |*a| {
            if (!std.mem.eql(u8, a.name, "it")) {
                if (map.get(a.name)) |fresh| a.name = fresh;
            }
        },
        .lambda_expr => |*l| {
            var renamed_params = false;
            for (l.params) |pm| {
                if (!std.mem.eql(u8, pm.name, "it") and map.get(pm.name) != null) renamed_params = true;
            }
            if (renamed_params) {
                var new_params = try self.allocator.alloc(ast.Param, l.params.len);
                for (l.params, 0..) |pm, i| {
                    new_params[i] = pm;
                    if (!std.mem.eql(u8, pm.name, "it")) {
                        if (map.get(pm.name)) |fresh| new_params[i].name = fresh;
                    }
                }
                l.params = new_params;
            }
        },
        .fun_decl => |*f| {
            if (map.get(f.name)) |fresh| f.name = fresh;
            for (f.params) |*pm| {
                if (!std.mem.eql(u8, pm.name, "it")) {
                    if (map.get(pm.name)) |fresh| pm.name = fresh;
                }
            }
        },
        else => {},
    }
    return .recurse;
}

/// Definition-time `@Embed` check: block-typed params must be invoked
/// directly (`block(...)`). Any other use (forwarded as an argument,
/// stored, assigned) would dangle after textual expansion, surfacing as
/// a confusing "Undeclared variable" at each call site. Skipped when the
/// body rebinds a block name anywhere (those calls bail to normal closure
/// semantics, where forwarding works).
pub fn checkEmbedBlockUses(self: *TypeChecker, params: []const ast.Param, body: *ASTNode) anyerror!void {
    var blocks = ArrayList([]const u8).init(self.allocator);
    defer blocks.deinit();
    for (params) |p| {
        const tr = p.type_ref orelse continue;
        if (!tr.is_function) continue;
        try blocks.append(p.name);
    }
    if (blocks.items.len == 0) return;
    var bound = std.StringHashMap(void).init(self.allocator);
    defer bound.deinit();
    try collectBoundNames(body, &bound);
    for (blocks.items) |b| {
        if (bound.contains(b)) return;
    }
    for (blocks.items) |b| {
        try checkEmbedBlockNode(self, body, b);
    }
}

fn checkEmbedBlockNode(self: *TypeChecker, node: *ASTNode, block_name: []const u8) anyerror!void {
    const ctx = BlockUseCtx{ .tc = self, .block_name = block_name };
    _ = try core.visitEachNode(node, ctx, checkEmbedBlockEnter);
}

const BlockUseCtx = struct { tc: *TypeChecker, block_name: []const u8 };

fn checkEmbedBlockEnter(ctx: BlockUseCtx, node: *ASTNode) anyerror!core.VisitAction {
    const block_name = ctx.block_name;
    switch (node.data) {
        .identifier => |id| {
            if (std.mem.eql(u8, id.name, block_name)) {
                ctx.tc.reportError(node.line, node.column, "TypeError: cannot pass '@Embed' block '{s}' as a value; invoke it directly as '{s}(...)'.", .{ block_name, block_name });
                return error.TypeError;
            }
            return .recurse;
        },
        .call_expr => |c| {
            if (c.callee.data == .identifier and std.mem.eql(u8, c.callee.data.identifier.name, block_name)) {
                for (c.arguments) |arg| {
                    _ = try core.visitEachNode(arg, ctx, checkEmbedBlockEnter);
                }
                return .prune;
            }
            return .recurse;
        },
        .assignment => |a| {
            if (std.mem.eql(u8, a.name, block_name)) {
                ctx.tc.reportError(node.line, node.column, "TypeError: cannot assign to '@Embed' block '{s}'; invoke it directly as '{s}(...)'.", .{ block_name, block_name });
                return error.TypeError;
            }
            return .recurse;
        },
        else => return .recurse,
    }
}

/// Structural loop-driver shape, computed once at `@Embed` definition
/// validation and stored on `fun_decl.is_loop_driver` (monomorphized clones
/// preserve it): true when the body invokes a block param from inside a
/// loop. The inliner reads the flag instead of re-walking the body per
/// call site. Loop bodies thread `in_loop` via manual recursion; the
/// enumerator traverses everything else.
pub fn funBodyLoopsAroundBlocks(body: *ASTNode, block_names: []const []const u8) bool {
    if (block_names.len == 0) return false;
    const ctx = LoopShapeCtx{ .block_names = block_names, .in_loop = false };
    return core.visitEachNode(body, ctx, loopShapeEnter) catch false;
}

const LoopShapeCtx = struct { block_names: []const []const u8, in_loop: bool };

fn loopShapeEnter(ctx: LoopShapeCtx, node: *ASTNode) anyerror!core.VisitAction {
    switch (node.data) {
        .call_expr => |c| {
            if (ctx.in_loop and c.callee.data == .identifier) {
                for (ctx.block_names) |b| {
                    if (std.mem.eql(u8, c.callee.data.identifier.name, b)) return .stop;
                }
            }
            return .recurse;
        },
        .while_stmt => |w| {
            if (try core.visitEachNode(w.condition, ctx, loopShapeEnter)) return .stop;
            var nested = ctx;
            nested.in_loop = true;
            if (try core.visitEachNode(w.body, nested, loopShapeEnter)) return .stop;
            return .prune;
        },
        .for_stmt => |f| {
            if (try core.visitEachNode(f.iterable, ctx, loopShapeEnter)) return .stop;
            var nested = ctx;
            nested.in_loop = true;
            if (try core.visitEachNode(f.body, nested, loopShapeEnter)) return .stop;
            return .prune;
        },
        .lambda_expr, .fun_decl => return .prune,
        else => return .recurse,
    }
}

/// Converts block-direct bare `leave`s to `throw EmbedReturn()`, stopping
/// at nested loop/lambda/function boundaries (those keep their own
/// target). Valued leaves are skipped (delivery handles them separately).
/// Returns the conversion count.
fn convertBareLeavesToRegionExit(self: *TypeChecker, node: *ASTNode) anyerror!usize {
    var n: usize = 0;
    const ctx = CountCtx{ .tc = self, .count = &n };
    _ = try core.visitEachNode(node, ctx, convertBareEnter);
    return n;
}

fn convertBareEnter(ctx: CountCtx, node: *ASTNode) anyerror!core.VisitAction {
    switch (node.data) {
        .while_stmt, .for_stmt, .lambda_expr, .fun_decl => return .prune,
        .break_stmt => |b| {
            if (b.value != null) return .prune;
            node.data = (try mkDesugarThrowIdent(ctx.tc, node.line, node.column, "EmbedReturn")).data;
            ctx.count.* += 1;
            return .prune;
        },
        else => return .recurse,
    }
}

/// Inlines an `@Embed` call: clones the callee body, binds value params to
/// fresh holders, pastes block invocations, and infers the expansion as a
/// statement block. Falls back to a normal call (false) unless every
/// precondition holds; recursion is a hard error.
fn inlineEmbedCall(self: *TypeChecker, node: *ASTNode, scope: *Scope, fun_decl: anytype, c_name: []const u8, ret_type: *const EiwaType, t: *EiwaType) anyerror!bool {
    if (!funIsEmbed(fun_decl.annotations)) return false;
    // Termination backstop: each expansion pastes a finite body, so only an
    // unbounded path (recursion through inlining) can hit the cap. Same
    // function nested in source (e.g. `repeat` in `repeat`) is finite.
    if (self.embed_stack.items.len >= 64) {
        self.reportError(node.line, node.column, "TypeError: '@Embed' expansion too deep (recursive '@Embed' call to '{s}').", .{c_name});
        return error.TypeError;
    }
    const c_args = node.data.call_expr.arguments;
    var blocks = ArrayList(BlockArg).init(self.allocator);
    defer blocks.deinit();
    for (fun_decl.params, 0..) |p, pi| {
        const is_fn = if (p.type_ref) |tr| tr.is_function else false;
        if (!is_fn) continue;
        if (pi >= c_args.len) return false;
        const a = c_args[pi];
        const lam = if (a.data == .named_arg) a.data.named_arg.value else a;
        if (lam.data != .lambda_expr) return false;
        try blocks.append(.{ .name = p.name, .lam = lam });
    }
    // Inline cycle: a definition-derived call with literal blocks, to a
    // function already being expanded, would paste forever (each expansion
    // re-creates the call). Non-literal args bail below to a normal call
    // and terminate, so the check runs here — after the literal gate.
    // User-written nested calls (`repeat` in `repeat`) are not marked and
    // stay finite, so only genuine cycles trip this.
    if (node.from_embed_body) {
        for (self.embed_stack.items) |active| {
            if (std.mem.eql(u8, active, c_name)) {
                self.reportError(node.line, node.column, "TypeError: recursive '@Embed' call to '{s}' cannot be inlined.", .{fun_decl.name});
                return error.TypeError;
            }
        }
    }
    var valued = ArrayList(*ASTNode).init(self.allocator);
    defer valued.deinit();
    for (blocks.items) |b| {
        for (b.lam.data.lambda_expr.body) |s| {
            _ = try core.visitEachNode(s, &valued, collectValuedEnter);
        }
    }
    if (bodyHasReturn(fun_decl.body, true)) return false;
    var bound = std.StringHashMap(void).init(self.allocator);
    defer bound.deinit();
    try collectBoundNames(fun_decl.body, &bound);
    for (fun_decl.params) |p| {
        if (std.mem.eql(u8, p.name, "it")) return false;
        // Any body binding of a param name (value or block) breaks
        // textual matching: shadowing stays on the normal-call path.
        if (bound.contains(p.name)) return false;
    }
    const line = node.line;
    const col = node.column;
    const tag = try std.fmt.allocPrint(self.allocator, "__emb_{d}_{d}", .{ line, col });
    var expansion = ArrayList(*ASTNode).init(self.allocator);
    for (fun_decl.params, 0..) |p, pi| {
        const is_fn = if (p.type_ref) |tr| tr.is_function else false;
        if (is_fn) continue;
        if (pi >= c_args.len) return false;
        const holder = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ tag, p.name });
        const holder_decl = try self.allocator.create(ASTNode);
        holder_decl.* = .{ .line = line, .column = col, .resolved_type = null, .data = .{ .var_decl = .{ .is_mut = true, .name = holder, .type_ref = null, .initializer = c_args[pi] } } };
        try expansion.append(holder_decl);
    }
    const body_clone = try self.cloneNode(fun_decl.body);
    clearEmbedState(body_clone);
    if (bodyHasNestedDecl(body_clone)) return false;
    var renames = std.StringHashMap([]const u8).init(self.allocator);
    defer renames.deinit();
    var bit = bound.iterator();
    while (bit.next()) |entry| {
        const old = entry.key_ptr.*;
        if (std.mem.eql(u8, old, "it")) continue;
        var is_param = false;
        for (fun_decl.params) |fp| {
            if (std.mem.eql(u8, fp.name, old)) {
                is_param = true;
                break;
            }
        }
        if (is_param) continue;
        const fresh = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ tag, old });
        try renames.put(old, fresh);
    }
    try renameEmbedNames(self, body_clone, &renames);
    for (fun_decl.params) |p| {
        const is_fn = if (p.type_ref) |tr| tr.is_function else false;
        if (is_fn) continue;
        const holder = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ tag, p.name });
        var bailed = false;
        try substituteEmbedParam(self, body_clone, p.name, holder, &bailed);
        if (bailed) return false;
    }
    // Value delivery via shared helper (unifies T, converts to throws).
    var deliver_t: ?*const EiwaType = null;
    var out_name: ?[]const u8 = null;
    if (valued.items.len > 0) {
        if (try prepareValueDelivery(self, scope, blocks.items, fun_decl, tag, line, col)) |vd| {
            deliver_t = vd.t;
            out_name = vd.out_name;
        }
    }
    // Loop-driver bare breaks: when the callee loops around a block
    // invocation (`is_loop_driver`, computed at definition), block-direct
    // bare `leave`s exit the whole driver, so they ride the same
    // region-exit channel as callee-own `return`s (`throw EmbedReturn()`,
    // caught per expansion). Non-loop drivers (e.g. `runOnce`) stay purely
    // textual: `leave` binds to caller loops or errors when unbound.
    // Nested loops/lambdas keep their own target.
    var driver_exits: usize = 0;
    if (fun_decl.is_loop_driver) {
        for (blocks.items) |b| {
            for (b.lam.data.lambda_expr.body) |s| {
                driver_exits += try convertBareLeavesToRegionExit(self, s);
            }
        }
    }
    // Callee-own bare `return`s exit the region (rewritten pre-paste so
    // user-block `return`s, pasted later, keep non-local semantics).
    var region_exits: usize = 0;
    if (body_clone.data == .block) {
        for (body_clone.data.block.statements) |s| region_exits += try rewriteEmbedReturns(self, s);
    }
    try pasteEmbedBlocks(self, body_clone, blocks.items, line, col);
    if (body_clone.data != .block) return false;
    // Region exits were counted pre-paste (user `return`s paste later, untouched).
    // Converted driver bare breaks ride the same catch.
    // Valued delivery rides the same try with its own catch assigning `__out`.
    var catches = ArrayList(ast.CatchBlock).init(self.allocator);
    if (region_exits + driver_exits > 0) {
        const er_ref = try self.allocator.create(ast.ASTTypeRef);
        er_ref.* = .{ .name = "EmbedReturn", .generic_args = &.{}, .is_array = false, .is_nullable = false };
        const er_refs = try self.allocator.alloc(*const ast.ASTTypeRef, 1);
        er_refs[0] = er_ref;
        const empty_body = try infer_stmt_mod.mkDesugarNode(self, line, col, .{ .block = .{ .statements = &.{} } });
        try catches.append(.{ .var_name = "__emb_er", .types = er_refs, .body = empty_body });
    }
    if (out_name) |on| {
        const dt = deliver_t.?;
        const lv_arg = try eiwaTypeToRef(self, dt, false, line, col);
        const lv_args = try self.allocator.alloc(*const ast.ASTTypeRef, 1);
        lv_args[0] = lv_arg;
        const lv_ref = try self.allocator.create(ast.ASTTypeRef);
        lv_ref.* = .{ .name = "LeaveValue", .generic_args = lv_args, .is_array = false, .is_nullable = false };
        const lv_refs = try self.allocator.alloc(*const ast.ASTTypeRef, 1);
        lv_refs[0] = lv_ref;
        const e_ident = try infer_stmt_mod.mkDesugarIdent(self, line, col, "__emb_lv");
        const e_value = try infer_stmt_mod.mkDesugarGet(self, line, col, e_ident, "value");
        const set_out = try infer_stmt_mod.mkDesugarNode(self, line, col, .{ .assignment = .{ .name = on, .value = e_value } });
        const catch_stmts = try self.allocator.alloc(*ASTNode, 1);
        catch_stmts[0] = set_out;
        const catch_body = try infer_stmt_mod.mkDesugarNode(self, line, col, .{ .block = .{ .statements = catch_stmts } });
        try catches.append(.{ .var_name = "__emb_lv", .types = lv_refs, .body = catch_body });
        const null_lit = try infer_stmt_mod.mkDesugarNode(self, line, col, .{ .null_literal = {} });
        const out_ref = try eiwaTypeToRef(self, dt, true, line, col);
        const var_out = try infer_stmt_mod.mkDesugarNode(self, line, col, .{ .var_decl = .{ .is_mut = true, .name = on, .type_ref = out_ref, .initializer = null_lit } });
        try expansion.append(var_out);
    }
    if (catches.items.len > 0) {
        const try_node = try infer_stmt_mod.mkDesugarNode(self, line, col, .{ .try_stmt = .{ .body = body_clone, .catches = try catches.toOwnedSlice(), .is_value = false } });
        try expansion.append(try_node);
    } else {
        for (body_clone.data.block.statements) |s| try expansion.append(s);
    }
    if (out_name) |on| {
        try expansion.append(try infer_stmt_mod.mkDesugarIdent(self, line, col, on));
    }
    node.data = .{ .block = .{ .statements = try expansion.toOwnedSlice(), .is_value = out_name != null } };
    try self.embed_stack.append(c_name);
    defer _ = self.embed_stack.pop();
    if (out_name != null) {
        const bt = try infer_stmt_mod.inferBlockAsExpression(self, node, scope);
        if (bt) |rt| {
            if (node.expected_type) |exp_t| {
                if (!self.isCompatible(exp_t, rt)) {
                    self.reportError(node.line, node.column, "TypeError: '@Embed' call yields {f} but expected {f}.", .{ rt.*, exp_t.* });
                    return error.TypeError;
                }
            }
            t.* = rt.*;
        } else {
            t.* = .Void;
        }
    } else {
        const bt = try self.checkBlock(node.data.block.statements, scope);
        t.* = ret_type.*;
        _ = bt;
    }
    return true;
}

pub fn inferCallExpr(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    var c = &node.data.call_expr;

    // `funPointer { lambda }` — build a C function pointer (trampoline) for an
    // inline lambda without captures.
    if (c.callee.data == .identifier and std.mem.eql(u8, c.callee.data.identifier.name, "funPointer")) {
        if (try inferFunPointer(self, node, scope, t)) return;
    }

    prePropagateExpectedTypes(self, node, scope);

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
                    if (!candidateHasNamedParams(fun_decl.params, c.arguments)) continue;

                    var all_match = true;
                    for (c.arguments, 0..) |arg, arg_i| {
                        if (arg.data == .lambda_expr) {
                            if (arg_i >= f.params.len or extractBaseType(f.params[arg_i]).* != .Function) {
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

            // `@Embed` inline (statement + value delivery); node replaced when handled.
            if (try inlineEmbedCall(self, node, scope, fun_decl, f.c_name, f.return_type, t)) return;

            // Valued `leave` without inlining has no delivery channel.
            try rejectValuedLeaves(self, node);
            
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
                        self.reportError(node.line, node.column, "TypeError: Expected {f} for argument {} but got {f}.", .{ f.params[arg_i].*, arg_i + 1, arg.resolved_type.?.* });
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
            if (self.lookupGenericFunction(name, c.arguments.len)) |gen_node| {
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
                const min_len = @min(c.arguments.len, gen_decl.params.len);
                for (c.arguments[0..min_len], gen_decl.params[0..min_len]) |arg, p| {
                    if (arg.data == .lambda_expr and arg.resolved_type == null) {
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
                if (gen_decl.params.len != 1) {
                    try mangled.writer().print("_{d}", .{gen_decl.params.len});
                }
                for (type_args) |type_arg| {
                    try mangled.appendSlice("_");
                    try type_arg.formatSafe(mangled.writer());
                }
                const final_mangled = try mangled.toOwnedSlice();

                try self.monomorphizeFunction(gen_node, type_args, final_mangled, null);

                const actual_c_name_2 = blk_2: {
                    if (self.functions_ast.get(final_mangled)) |fn_node| {
                        if (fn_node.data.fun_decl.resolved_c_name) |rcn| break :blk_2 rcn;
                    }
                    break :blk_2 final_mangled;
                };
                const func_node = self.functions_ast.get(actual_c_name_2).?;
                const func_decl = func_node.data.fun_decl;
                const ret_type = func_node.resolved_type.?.Function.return_type;

                try resolveCallArguments(self, node, func_decl.params, scope);

                if (try inlineEmbedCall(self, node, scope, func_decl, actual_c_name_2, ret_type, t)) return;

                // Valued `leave` without inlining has no delivery channel.
                try rejectValuedLeaves(self, node);

                for (c.arguments, 0..) |arg, arg_i| {
                    if (arg_i < func_decl.params.len) {
                        const param_type = if (func_decl.params[arg_i].type_ref) |tr| self.resolveTypeRef(tr) catch null else null;
                        if (param_type) |pt| {
                            arg.expected_type = pt;
                            if (arg.resolved_type == null) {
                                _ = try self.inferNode(arg, scope);
                            }
                            if (!self.isCompatible(pt, arg.resolved_type.?)) {
                                self.reportError(arg.line, arg.column, "TypeError: Expected {f} but found {f} for argument {}.", .{ pt.*, arg.resolved_type.?.*, arg_i + 1 });
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
                            self.reportError(node.line, node.column, "TypeError: Incompatible types: expected '{f}', but got '{f}'. Did you mean to call '.freeze()'?", .{ expected_arg_type.*, arg.resolved_type.?.* });
                        } else {
                            self.reportError(node.line, node.column, "TypeError: Expected {f} for argument {} but got {f}.", .{ expected_arg_type.*, arg_i + 1, arg.resolved_type.?.* });
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
                                        const inner = c_name[prefix_len.?..];
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
                                    const arg_node = getArgForProp(c.arguments, type_decl.primary_constructor, prop_i) orelse continue;
                                    const arg_type = arg_node.resolved_type orelse (if (arg_node.data == .named_arg) arg_node.data.named_arg.value.resolved_type else null) orelse continue;

                                    if (std.mem.eql(u8, prop.type_ref.name, g_param) and prop.type_ref.generic_args.len == 0 and !prop.type_ref.is_array) {
                                        found_type = arg_type;
                                        break;
                                    } else {
                                        if (std.mem.eql(u8, prop.type_ref.name, "NativeArray") and prop.type_ref.generic_args.len == 1 and std.mem.eql(u8, prop.type_ref.generic_args[0].name, g_param)) {
                                            if (arg_type.* == .Array) {
                                                found_type = arg_type.Array;
                                                break;
                                            }
                                        }
                                        
                                        if (prop.type_ref.is_function) {
                                            if (prop.type_ref.return_type) |ret_ref| {
                                                if (std.mem.eql(u8, ret_ref.name, g_param)) {
                                                    const actual_arg = if (arg_node.data == .named_arg) arg_node.data.named_arg.value else arg_node;
                                                    if (actual_arg.resolved_type == null and actual_arg.data == .lambda_expr) {
                                                        _ = probeInfer(self, actual_arg, scope) catch null;
                                                    }
                                                    if (actual_arg.resolved_type) |arg_t| {
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
                                            if (arg_type.* == .Custom) {
                                                const c_name = arg_type.Custom;
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
                                            if (arg_type.* == .Custom) {
                                                const c_name = arg_type.Custom;
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
                                        var map_arg_match_idx: ?usize = null;
                                        if ((std.mem.eql(u8, prop.type_ref.name, "MutableMap") or std.mem.eql(u8, prop.type_ref.name, "Map")) and prop.type_ref.generic_args.len >= 1) {
                                            for (prop.type_ref.generic_args, 0..) |arg, g_idx| {
                                                if (std.mem.eql(u8, arg.name, g_param)) {
                                                    is_map_gparam = true;
                                                    map_arg_match_idx = g_idx;
                                                    break;
                                                }
                                            }
                                        }
                                        if (is_map_gparam) {
                                            if (arg_type.* == .Custom) {
                                                const c_name = arg_type.Custom;
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
                                                            if (map_arg_match_idx != null and map_arg_match_idx.? == 1) {
                                                                found_type = t2;
                                                            } else {
                                                                found_type = t1;
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
                        try resolveConstructorArguments(self, node, mono_type_decl.primary_constructor, scope);

                        for (c.arguments, 0..) |arg, arg_i| {
                            if (arg_i < mono_type_decl.primary_constructor.len) {
                                const p = mono_type_decl.primary_constructor[arg_i];
                                if (p.resolved_type orelse self.resolveTypeRef(p.type_ref) catch null) |pt| {
                                    arg.expected_type = pt;
                                    if (arg.resolved_type == null) {
                                        _ = try self.inferNode(arg, scope);
                                    }
                                    if (!self.isCompatible(pt, arg.resolved_type.?)) {
                                        self.reportError(node.line, node.column, "TypeError: Expected {f} but found {f} for argument {}.", .{ pt.*, arg.resolved_type.?.*, arg_i + 1 });
                                        return error.TypeError;
                                    }
                                }
                            }
                        }

                        t.* = .{ .Custom = actual_mangled };
                        c.callee.data.identifier.resolved_c_name = actual_mangled;
                        return;
                    } else {
                        try resolveConstructorArguments(self, node, type_decl.primary_constructor, scope);

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
                                    if (arg.resolved_type) |art| {
                                        const arg_is_simple = arg.data == .identifier or arg.data == .string_literal or arg.data == .int_literal or arg.data == .double_literal or arg.data == .bool_literal;
                                        const exp_base = extractBaseType(pt);
                                        const act_base = extractBaseType(art);
                                        const is_cstr_decay = exp_base.* == .Pointer and act_base.* == .String;
                                        if (arg_is_simple and !is_cstr_decay and !self.isCompatible(pt, art)) {
                                            self.reportError(arg.line, arg.column, "TypeError: Expected {f} for argument {} of '{s}', got {f}.", .{ pt.*, arg_i + 1, name, art.* });
                                            return error.TypeError;
                                        }
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
                        try resolveConstructorArguments(self, node, type_decl.primary_constructor, scope);

                        for (c.arguments, 0..) |arg, arg_i| {
                            if (arg_i < type_decl.primary_constructor.len) {
                                if (type_decl.primary_constructor[arg_i].resolved_type orelse self.resolveTypeRef(type_decl.primary_constructor[arg_i].type_ref) catch null) |pt| {
                                    arg.expected_type = pt;
                                    if (arg.resolved_type == null) {
                                        _ = try self.inferNode(arg, scope);
                                    }
                                    if (arg.resolved_type) |art| {
                                        const arg_is_simple = arg.data == .identifier or arg.data == .string_literal or arg.data == .int_literal or arg.data == .double_literal or arg.data == .bool_literal;
                                        const exp_base = extractBaseType(pt);
                                        const act_base = extractBaseType(art);
                                        const is_cstr_decay = exp_base.* == .Pointer and act_base.* == .String;
                                        if (arg_is_simple and !is_cstr_decay and !self.isCompatible(pt, art)) {
                                            self.reportError(arg.line, arg.column, "TypeError: Expected {f} for argument {} of '{s}', got {f}.", .{ pt.*, arg_i + 1, name, art.* });
                                            return error.TypeError;
                                        }
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
        if (self.global_scope.lookupFunctions(name)) |overloads| {
            for (overloads) |overload| {
                if (overload.* != .Function) continue;
                const f = overload.Function;
                if (f.receiver != null) continue;
                if (f.params.len != c.arguments.len) continue;
                for (f.params, 0..) |param, arg_i| {
                    const arg = c.arguments[arg_i];
                    if (arg.resolved_type) |actual| {
                        if (!self.isCompatible(param, actual)) {
                            self.reportError(arg.line, arg.column, "TypeError: Expected {f} but found {f} for argument {}.", .{ param.*, actual.*, arg_i + 1 });
                            return error.TypeError;
                        }
                    }
                }
            }
        }
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
                                self.reportError(node.line, node.column, "TypeError: Expected {f} but found {f} for argument {}.", .{ f.params[arg_i].*, arg.resolved_type.?.*, arg_i + 1 });
                                return error.TypeError;
                            }
                        }
                    }
                    t.* = f.return_type.*;
                    node.resolved_type = t;
                    return;
                } else {
                    self.reportError(node.line, node.column, "TypeError: Cannot call a field '{s}' of non-function type {f}.", .{ g.name, field_type.* });
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
                        if (!candidateHasNamedParams(f.params, c.arguments)) continue;
                        
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

                try self.monomorphizeFunction(matched_method, type_args, final_mangled, null);

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
            
            try resolveCallArguments(self, node, f.params, scope);
            
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
                        self.reportError(arg.line, arg.column, "TypeError: Expected {f} but found {f} for argument {}.", .{ expected_type.*, arg_type.*, i + 1 });
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
                            if (!candidateHasNamedParams(f.params, c.arguments)) continue;

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

                    if (found_method == null) {
                        if (self.extension_functions.get(g.name)) |ext_list| {
                            found_method = findExtensionWithDefaults(self, self, ext_list, base_type, c.arguments.len, c.arguments);
                        }
                        if (found_method == null and self.registry != null and self.imported_extension_names.contains(g.name)) {
                            var mod_it = self.registry.?.modules.iterator();
                            while (mod_it.next()) |entry| {
                                const checker = entry.value_ptr.checker;
                                if (checker.extension_functions.get(g.name)) |ext_list| {
                                    found_method = findExtensionWithDefaults(self, checker, ext_list, base_type, c.arguments.len, c.arguments);
                                    if (found_method != null) break;
                                }
                            }
                        }
                    }

                    
                    if (found_method) |m| {
                        var f = &m.data.fun_decl;

                        if (f.receiver_type != null and f.generic_params.len > 0 and c.type_args.len == 0) {
                            var bindings = std.StringHashMap(*const EiwaType).init(self.allocator);
                            defer bindings.deinit();
                            const recv_base = matchExtensionBindings(self, self, m, base_type, &bindings) orelse {
                                self.reportError(node.line, node.column, "TypeError: Could not infer generic parameters for extension '{s}'.", .{f.name});
                                return error.TypeError;
                            };
                            for (f.params, 0..) |p, arg_i| {
                                if (arg_i >= c.arguments.len) break;
                                if (p.type_ref) |tr| {
                                    if (tr.generic_args.len == 0 and extParamIndex(f.generic_params, tr.name) != null) {
                                        if (bindings.get(tr.name) == null) {
                                            if (c.arguments[arg_i].resolved_type) |rt| {
                                                try bindings.put(tr.name, rt);
                                            }
                                        }
                                    }
                                }
                            }
                            var type_args = try self.allocator.alloc(*const EiwaType, f.generic_params.len);
                            for (f.generic_params, 0..) |param_name, i| {
                                type_args[i] = bindings.get(param_name) orelse {
                                    self.reportError(node.line, node.column, "TypeError: Could not infer generic parameter '{s}' for extension '{s}'.", .{ param_name, f.name });
                                    return error.TypeError;
                                };
                            }
                            var mangled = ArrayList(u8).init(self.allocator);
                            try mangled.appendSlice(f.name);
                            try mangled.appendSlice("_");
                            try mangled.appendSlice(recv_base);
                            for (type_args) |ta| {
                                try mangled.appendSlice("_");
                                try ta.formatSafe(mangled.writer());
                            }
                            const final_mangled = try mangled.toOwnedSlice();
                            try self.monomorphizeFunction(m, type_args, final_mangled, null);
                            if (self.functions_ast.get(final_mangled)) |spec_node| {
                                c.callee.data.get_expr.resolved_c_name = final_mangled;
                                c.callee.resolved_type = spec_node.resolved_type;
                                f = &spec_node.data.fun_decl;
                            } else {
                                self.reportError(node.line, node.column, "TypeError: Monomorphized extension '{s}' not found.", .{f.name});
                                return error.TypeError;
                            }
                        }

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

                            try self.monomorphizeFunction(m, type_args, final_mangled, base_type);

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

                        try resolveCallArguments(self, node, f.params, scope);

                        for (c.arguments, 0..) |arg, arg_i| {
                            var exp_t: ?*const EiwaType = null;
                            if (arg_i < f.params.len) {
                                if (f.params[arg_i].is_varargs) {
                                    // The variadic List<T> gets the monomorphized List type.
                                    if (f.params[arg_i].type_ref) |tr| {
                                        if (self.resolveTypeRef(tr) catch null) |et| {
                                            exp_t = self.makeListType(et, node.line, node.column) catch null;
                                        }
                                    }
                                } else if (f.params[arg_i].type_ref) |tr| {
                                    exp_t = self.resolveTypeRef(tr) catch null;
                                }
                            }
                            arg.expected_type = exp_t;
                            _ = try self.inferNode(arg, scope);
                            if (exp_t) |expected| {
                                if (arg.resolved_type) |actual| {
                                    if (!self.isCompatible(expected, actual)) {
                                        var exp_buf: [128]u8 = undefined;
                                        var act_buf: [128]u8 = undefined;
                                        self.reportError(arg.line, arg.column, "TypeError: Expected '{s}' but found '{s}' for argument {}.", .{ expected.formatTypeName(&exp_buf), actual.formatTypeName(&act_buf), arg_i + 1 });
                                        return error.TypeError;
                                    }
                                }
                            }
                        }

                    }
                } else if (self.contracts_ast.get(class_name)) |contract_node| {
                    const cd = contract_node.data.contract_decl;
                    for (cd.methods) |method| {
                        if (method.data == .fun_decl and std.mem.eql(u8, method.data.fun_decl.name, g.name)) {
                            const f = &method.data.fun_decl;
                            try resolveCallArguments(self, node, f.params, scope);
                            for (c.arguments, 0..) |arg, arg_i| {
                                var exp_t: ?*const EiwaType = null;
                                if (arg_i < f.params.len) {
                                    if (f.params[arg_i].type_ref) |tr| {
                                        exp_t = self.resolveTypeRef(tr) catch null;
                                    }
                                }
                                arg.expected_type = exp_t;
                                _ = try self.inferNode(arg, scope);
                                if (exp_t) |expected| {
                                    if (arg.resolved_type) |actual| {
                                        if (!self.isCompatible(expected, actual)) {
                                            var exp_buf: [128]u8 = undefined;
                                            var act_buf: [128]u8 = undefined;
                                            self.reportError(arg.line, arg.column, "TypeError: Expected '{s}' but found '{s}' for argument {}.", .{ expected.formatTypeName(&exp_buf), actual.formatTypeName(&act_buf), arg_i + 1 });
                                            return error.TypeError;
                                        }
                                    }
                                }
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
                var f = rt_base.Function;
                if (c.callee.data == .get_expr) {
                    if (c.callee.data.get_expr.resolved_c_name) |rcn| {
                        if (self.functions_ast.get(rcn)) |fn_node| {
                            if (fn_node.resolved_type) |frt| {
                                const fbase = extractBaseType(frt);
                                if (fbase.* == .Function) f = fbase.Function;
                            }
                        }
                    }
                }
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
                                self.reportError(node.line, node.column, "TypeError: Expected {f} but found {f} for argument {}.", .{ f.params[arg_i].*, arg.resolved_type.?.*, arg_i + 1 });
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
                            self.reportError(node.line, node.column, "TypeError: Expected {f} but found {f} for argument {}.", .{ f.params[arg_i].*, arg.resolved_type.?.*, arg_i + 1 });
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

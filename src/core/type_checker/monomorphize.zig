const std = @import("std");
const compat = @import("../compat.zig");
const ArrayList = compat.ArrayList;
const ast = @import("../ast.zig");
const type_system = @import("../type_system.zig");
const core = @import("core.zig");
const infer_decl_mod = @import("infer_decl.zig");

const ASTNode = ast.ASTNode;
const TypeChecker = core.TypeChecker;
const EiwaType = type_system.EiwaType;

pub fn monomorphizeClass(self: *TypeChecker, base_name: []const u8, type_args: []*const EiwaType, mangled_name: []const u8) !void {
    if (self.classes_ast.get(mangled_name) != null) return;
    
    var actual_base_name = self.alias_map.get(base_name) orelse base_name;
    var base_node = self.classes_ast.get(actual_base_name);
    if (base_node == null and self.registry != null) {
        var mod_it = self.registry.?.modules.iterator();
        while (mod_it.next()) |entry| {
            const mod_actual = entry.value_ptr.checker.alias_map.get(base_name) orelse base_name;
            if (entry.value_ptr.checker.classes_ast.get(mod_actual)) |bn| {
                base_node = bn;
                actual_base_name = mod_actual;
                try self.alias_map.put(base_name, mod_actual);
                try self.classes_ast.put(mod_actual, bn);
                break;
            }
        }
    }
    if (base_node != null and base_node.?.data.type_decl.generic_params.len == 0) {
        if (self.classes_ast.get(base_name)) |bn| {
            if (bn.data.type_decl.generic_params.len > 0) {
                base_node = bn;
                actual_base_name = base_name;
            }
        }
    }
    if (base_node == null or base_node.?.data.type_decl.generic_params.len == 0) {
        self.reportError(0, 0, "TypeError: Generic class '{s}' not found.", .{base_name});
        return error.TypeError;
    }
    
    const new_node = try self.allocator.create(ASTNode);
    new_node.* = base_node.?.*;
    
    const type_decl = base_node.?.data.type_decl;
    if (type_decl.generic_params.len != type_args.len) {
        self.reportError(0, 0, "TypeError: Expected {} generic arguments for '{s}', got {}.", .{type_decl.generic_params.len, base_name, type_args.len});
        return error.TypeError;
    }
    
    // Create the generic map mapping (e.g. "T" -> .String)
    var generic_map = std.StringHashMap(*const EiwaType).init(self.allocator);
    defer generic_map.deinit();
    for (type_decl.generic_params, 0..) |param_name, i| {
        try generic_map.put(param_name, type_args[i]);
    }
    
    // Setup alias_map early so resolveTypeName can use it!
    var old_aliases = std.StringHashMap([]const u8).init(self.allocator);
    defer old_aliases.deinit();

    for (type_decl.generic_params, 0..) |param_name, i| {
        var conc_buf = ArrayList(u8).init(self.allocator);
        try type_args[i].formatSafe(conc_buf.writer());
        const conc_name = try conc_buf.toOwnedSlice();

        if (self.alias_map.get(param_name)) |old_val| {
            try old_aliases.put(param_name, old_val);
        }
        _ = self.global_scope.define(conc_name, type_args[i], false, false) catch {};
        try self.alias_map.put(param_name, conc_name);
        try self.alias_map.put(conc_name, conc_name);
    }

    var new_props = try self.allocator.alloc(ast.ClassProp, type_decl.primary_constructor.len);
    for (type_decl.primary_constructor, 0..) |prop, i| {
        new_props[i] = prop;
        new_props[i].type_ref = try self.cloneTypeRef(prop.type_ref);
        if (generic_map.get(prop.type_ref.name)) |g_type| {
            if (prop.type_ref.is_nullable) {
                // T? must become `Concrete | null`, not bare Concrete
                const union_t = try self.allocator.create(EiwaType);
                union_t.* = .{ .Union = .{
                    .left = try self.allocator.create(EiwaType),
                    .right = try self.allocator.create(EiwaType),
                } };
                @constCast(union_t.Union.left).* = g_type.*;
                @constCast(union_t.Union.right).* = .Null;
                new_props[i].resolved_type = union_t;
            } else {
                new_props[i].resolved_type = g_type;
            }
        }
        if (prop.initializer) |init_node| {
            new_props[i].initializer = try self.cloneNode(init_node);
        }
    }
    
    var filtered_methods = ArrayList(*ASTNode).init(self.allocator);
    for (type_decl.methods) |method| {
        if (method.data == .fun_decl) {
            const mname = method.data.fun_decl.name;
            if (std.mem.eql(u8, mname, "toString") or std.mem.eql(u8, mname, "hashCode")) {
                continue;
            }
        }
        try filtered_methods.append(method);
    }
    var new_methods = try self.allocator.alloc(*ASTNode, filtered_methods.items.len);
    for (filtered_methods.items, 0..) |method, i| {
        const new_method = try self.allocator.create(ASTNode);
        new_method.* = method.*;
        if (method.data == .fun_decl) {
            var m_decl = method.data.fun_decl;
            if (m_decl.type_ref) |tr| {
                m_decl.type_ref = try self.cloneTypeRef(tr);
            }
            if (m_decl.params.len > 0) {
                var new_params = try self.allocator.alloc(ast.Param, m_decl.params.len);
                for (m_decl.params, 0..) |p, j| {
                    new_params[j] = p;
                    if (p.type_ref) |ptr| {
                        new_params[j].type_ref = try self.cloneTypeRef(ptr);
                    }
                    if (p.initializer) |init_node| {
                        new_params[j].initializer = try self.cloneNode(init_node);
                    }
                }
                m_decl.params = new_params;
            }
            m_decl.body = try self.cloneNode(m_decl.body);
            new_method.data = .{ .fun_decl = m_decl };
        }
        new_methods[i] = new_method;
    }
    var new_body_fields = try self.allocator.alloc(ast.ClassProp, type_decl.body_fields.len);
    for (type_decl.body_fields, 0..) |prop, i| {
        new_body_fields[i] = prop;
        new_body_fields[i].type_ref = try self.cloneTypeRef(prop.type_ref);
        if (generic_map.get(prop.type_ref.name)) |g_type| {
            new_body_fields[i].resolved_type = g_type;
        }
        if (prop.initializer) |init_node| {
            new_body_fields[i].initializer = try self.cloneNode(init_node);
        }
    }

    var new_type_decl = type_decl;
    new_type_decl.primary_constructor = new_props;
    new_type_decl.body_fields = new_body_fields;
    new_type_decl.methods = new_methods;
    new_type_decl.name = mangled_name;
    new_type_decl.resolved_c_name = mangled_name;
    new_type_decl.generic_params = &.{};
    new_node.data = .{ .type_decl = new_type_decl };

    // Insert monomorphized node into classes_ast & alias_map
    try self.classes_ast.put(mangled_name, new_node);
    try self.alias_map.put(mangled_name, mangled_name);
    if (std.mem.indexOf(u8, mangled_name, "_or_") != null) {
        var display_buf = ArrayList(u8).init(self.allocator);
        var it = std.mem.splitSequence(u8, mangled_name, "_or_");
        var idx: usize = 0;
        while (it.next()) |part| : (idx += 1) {
            if (idx > 0) try display_buf.appendSlice(" | ");
            try display_buf.appendSlice(part);
        }
        const disp = try display_buf.toOwnedSlice();
        try self.alias_map.put(disp, mangled_name);
    }
    
    // Register and trigger deep inference on the monomorphized class!
    const class_type = try self.allocator.create(EiwaType);
    try infer_decl_mod.inferTypeDecl(self, new_node, &self.global_scope, class_type);
    
    for (type_decl.generic_params) |param_name| {
        if (old_aliases.get(param_name)) |old_val| {
            try self.alias_map.put(param_name, old_val);
        } else {
            _ = self.alias_map.remove(param_name);
        }
    }

    try self.monomorphized_nodes.append(new_node);
}

// Cross-module lookup for generic functions: same registry fallback
// monomorphizeClass uses for classes, imported into the local map on first hit.
pub fn lookupGenericFunction(self: *TypeChecker, name: []const u8, arity: ?usize) ?*ASTNode {
    if (self.generic_functions_ast.get(name)) |list| {
        if (arity) |a| {
            for (list.items) |n| {
                if (n.data.fun_decl.params.len == a) return n;
            }
        } else if (list.items.len > 0) {
            return list.items[0];
        }
    }
    if (self.registry) |reg| {
        var mod_it = reg.modules.iterator();
        while (mod_it.next()) |entry| {
            if (entry.value_ptr.checker.generic_functions_ast.get(name)) |list| {
                if (arity) |a| {
                    for (list.items) |n| {
                        if (n.data.fun_decl.params.len == a) {
                            const gop = self.generic_functions_ast.getOrPut(name) catch return n;
                            if (!gop.found_existing) {
                                gop.value_ptr.* = ArrayList(*ASTNode).init(self.allocator);
                            }
                            gop.value_ptr.append(n) catch {};
                            return n;
                        }
                    }
                } else if (list.items.len > 0) {
                    const n = list.items[0];
                    const gop = self.generic_functions_ast.getOrPut(name) catch return n;
                    if (!gop.found_existing) {
                        gop.value_ptr.* = ArrayList(*ASTNode).init(self.allocator);
                    }
                    gop.value_ptr.append(n) catch {};
                    return n;
                }
            }
        }
    }
    return null;
}

pub fn monomorphizeFunction(self: *TypeChecker, base_node: *ASTNode, type_args: []*const EiwaType, mangled_name: []const u8, receiver: ?*const EiwaType) !void {
    if (self.functions_ast.get(mangled_name) != null) return;

    const fun_decl = base_node.data.fun_decl;
    if (fun_decl.generic_params.len != type_args.len) {
        self.reportError(0, 0, "TypeError: Expected {} generic arguments for '{s}', got {}.", .{ fun_decl.generic_params.len, fun_decl.name, type_args.len });
        return error.TypeError;
    }

    var old_aliases = std.StringHashMap([]const u8).init(self.allocator);
    defer old_aliases.deinit();

    for (fun_decl.generic_params, 0..) |param_name, i| {
        var conc_buf = ArrayList(u8).init(self.allocator);
        try type_args[i].formatSafe(conc_buf.writer());
        const conc_name = try conc_buf.toOwnedSlice();

        if (self.alias_map.get(param_name)) |old_val| {
            try old_aliases.put(param_name, old_val);
        }
        _ = self.global_scope.define(conc_name, type_args[i], false, false) catch {};
        try self.alias_map.put(param_name, conc_name);
        try self.alias_map.put(conc_name, conc_name);
    }

    const new_node = try self.cloneNode(base_node);
    new_node.data.fun_decl.generic_params = &.{};
    new_node.data.fun_decl.name = mangled_name;
    // Pre-set resolved_c_name so inferFunDecl skips its own mangling
    new_node.data.fun_decl.resolved_c_name = mangled_name;

    const t = try self.allocator.create(EiwaType);
    if (receiver) |rec| {
        var method_scope = type_system.Scope.init(self.allocator, &self.global_scope);
        defer method_scope.deinit();
        try method_scope.define("this", rec, false, false);
        try infer_decl_mod.inferFunDecl(self, new_node, &method_scope, t);
    } else {
        try infer_decl_mod.inferFunDecl(self, new_node, &self.global_scope, t);
    }
    new_node.resolved_type = t;

    for (fun_decl.generic_params) |param_name| {
        if (old_aliases.get(param_name)) |old_val| {
            try self.alias_map.put(param_name, old_val);
        } else {
            _ = self.alias_map.remove(param_name);
        }
    }

    try self.monomorphized_nodes.append(new_node);
}

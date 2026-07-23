const std = @import("std");
const compat = @import("../compat.zig");
const ArrayList = compat.ArrayList;
const ast = @import("../ast.zig");
const type_system = @import("../type_system.zig");
const core = @import("core.zig");
const infer_decl_mod = @import("infer_decl.zig");

const ASTNode = ast.ASTNode;
const TypeChecker = core.TypeChecker;
const AetherType = type_system.AetherType;

pub fn monomorphizeClass(self: *TypeChecker, base_name: []const u8, type_args: []*const AetherType, mangled_name: []const u8) !void {
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
    var generic_map = std.StringHashMap(*const AetherType).init(self.allocator);
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
            new_props[i].resolved_type = g_type;
        }
        if (prop.initializer) |init_node| {
            new_props[i].initializer = try self.cloneNode(init_node);
        }
    }
    
    var new_methods = try self.allocator.alloc(*ASTNode, type_decl.methods.len);
    for (type_decl.methods, 0..) |method, i| {
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
    var new_type_decl = type_decl;
    new_type_decl.primary_constructor = new_props;
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
    const class_type = try self.allocator.create(AetherType);
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

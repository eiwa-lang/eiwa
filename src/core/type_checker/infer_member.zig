const std = @import("std");
const compat = @import("../compat.zig");
const ArrayList = compat.ArrayList;
const ast = @import("../ast.zig");
const core = @import("core.zig");
const type_system = @import("../type_system.zig");
const infer_call_mod = @import("infer_call.zig");

const ASTNode = core.ASTNode;
const TypeChecker = core.TypeChecker;
const Scope = core.Scope;
const EiwaType = core.EiwaType;
const isNullable = core.isNullable;
const extractBaseType = core.extractBaseType;

fn inferGetExprForSingleType(self: *TypeChecker, target_type: *const EiwaType, member_name: []const u8) ?*const EiwaType {
    const base_type = extractBaseType(target_type);
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
        else => {},
    }
    if (name_opt == null) return null;
    const lookup = self.alias_map.get(name_opt.?) orelse name_opt.?;
    const actual_name = lookup;
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
    if (class_node_opt) |cn| {
        const c = cn.data.type_decl;
        for (c.primary_constructor) |prop| {
            if (std.mem.eql(u8, prop.name, member_name)) {
                return prop.resolved_type orelse (self.resolveTypeRef(prop.type_ref) catch null);
            }
        }
        for (c.methods) |method| {
            if (method.data == .fun_decl and std.mem.eql(u8, method.data.fun_decl.name, member_name)) {
                if (method.data.fun_decl.type_ref) |tr| {
                    return self.resolveTypeRef(tr) catch null;
                } else if (method.data.fun_decl.is_expr_body) {
                    if (method.data.fun_decl.body.resolved_type) |rt| return rt;
                }
                const void_type = self.allocator.create(EiwaType) catch return null;
                void_type.* = .Void;
                return void_type;
            }
        }
        for (c.contracts) |contract_name| {
            const actual_contract = self.alias_map.get(contract_name) orelse contract_name;
            if (self.contracts_ast.get(actual_contract)) |contract_node| {
                for (contract_node.data.contract_decl.methods) |method| {
                    if (method.data == .fun_decl and std.mem.eql(u8, method.data.fun_decl.name, member_name)) {
                        if (method.data.fun_decl.type_ref) |tr| {
                            return self.resolveTypeRef(tr) catch null;
                        } else {
                            const void_type = self.allocator.create(EiwaType) catch return null;
                            void_type.* = .Void;
                            return void_type;
                        }
                    }
                }
            } else if (self.classes_ast.get(actual_contract)) |super_node| {
                const sc = super_node.data.type_decl;
                for (sc.primary_constructor) |prop| {
                    if (std.mem.eql(u8, prop.name, member_name)) {
                        return prop.resolved_type orelse (self.resolveTypeRef(prop.type_ref) catch null);
                    }
                }
                for (sc.methods) |method| {
                    if (method.data == .fun_decl and std.mem.eql(u8, method.data.fun_decl.name, member_name)) {
                        if (method.data.fun_decl.type_ref) |tr| {
                            return self.resolveTypeRef(tr) catch null;
                        } else if (method.data.fun_decl.is_expr_body) {
                            if (method.data.fun_decl.body.resolved_type) |rt| return rt;
                        }
                        const void_type = self.allocator.create(EiwaType) catch return null;
                        void_type.* = .Void;
                        return void_type;
                    }
                }
            }
        }
    }
    return null;
}

pub fn inferGetExpr(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    var g = &node.data.get_expr;

    // Check if it's a lib method call (e.g. C.printf)
    if (g.object.data == .identifier) {
        const full_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ g.object.data.identifier.name, g.name });
        if (scope.lookupVariable(full_name)) |found_type| {
            t.* = found_type.*;
            node.resolved_type = found_type;

            const obj_t = try self.allocator.create(EiwaType);
            obj_t.* = .{ .Custom = g.object.data.identifier.name };
            g.object.resolved_type = obj_t;

            return;
        } else if (scope.lookupFunctions(full_name)) |overloads| {
            if (overloads.len > 0) {
                const found_type = overloads[0];
                t.* = found_type.*;
                node.resolved_type = found_type;

                const obj_t = try self.allocator.create(EiwaType);
                obj_t.* = .{ .Custom = g.object.data.identifier.name };
                g.object.resolved_type = obj_t;

                return;
            }
        }
    }

    // Qualified skill member access (e.g. MouseInput.click()) inside a composing type.
    // Rewrites to the shadowed method "{Skill}_{member}" on the current type.
    if (g.object.data == .identifier) {
        const skill_src = g.object.data.identifier.name;
        const skill_actual = self.alias_map.get(skill_src) orelse skill_src;
        if (self.skills_ast.contains(skill_actual)) {
            if (self.current_type_c_name) |type_c_name| {
                if (self.skills_ast.get(skill_actual)) |sn| {
                    const qualified = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ sn.data.skill_decl.name, g.name });
                    g.name = qualified;
                    const obj_t = try self.allocator.create(EiwaType);
                    obj_t.* = .{ .Custom = type_c_name };
                    g.object.resolved_type = obj_t;
                    const this_t = try self.allocator.create(EiwaType);
                    this_t.* = .{ .Custom = type_c_name };
                    g.object.data = .{ .identifier = .{ .name = "this", .resolved_c_name = null } };
                    g.object.resolved_type = this_t;
                }
            } else {
                self.reportError(node.line, node.column, "TypeError: Qualified skill access '{s}.{s}' is only allowed inside a type that composes the skill.", .{ skill_src, g.name });
                return error.TypeError;
            }
        }
    }

    const obj_type = try self.inferNode(g.object, scope);
    var prop_type: ?*const EiwaType = null;
    var is_static = false;
    if (g.object.data == .identifier) {
        const class_name = g.object.data.identifier.name;
        const actual_class_name = self.alias_map.get(class_name) orelse class_name;
        if (self.objects_ast.contains(actual_class_name)) {
            is_static = true;
            // Pin the resolved object name so the transpiler does not re-resolve
            // it through the (possibly polluted) global alias map.
            g.object.data.identifier.resolved_c_name = actual_class_name;
            const obj_node = self.objects_ast.get(actual_class_name).?;
            const obj = obj_node.data.object_decl;
            for (obj.members) |member| {
                if (member.data == .var_decl and std.mem.eql(u8, member.data.var_decl.name, g.name)) {
                    if (member.resolved_type == null) {
                        _ = try self.inferNode(member, scope);
                    }
                    prop_type = member.resolved_type;
                    break;
                } else if (member.data == .fun_decl and std.mem.eql(u8, member.data.fun_decl.name, g.name)) {
                    if (member.resolved_type == null) {
                        _ = try self.inferNode(member, scope);
                    }
                    prop_type = member.resolved_type;
                    break;
                }
            }
            if (prop_type == null) {
                self.reportError(node.line, node.column, "TypeError: Static member '{s}' not found in object '{s}'.", .{g.name, class_name});
                return error.TypeError;
            }
        } else if (self.enums_ast.contains(actual_class_name)) {
            is_static = true;
            g.object.data.identifier.resolved_c_name = actual_class_name;
            const enum_node = self.enums_ast.get(actual_class_name).?;
            const ed = enum_node.data.enum_decl;
            if (std.mem.eql(u8, g.name, "values")) {
                const fn_type = try self.allocator.create(EiwaType);
                const ret_type = try self.allocator.create(EiwaType);
                const elem_type = try self.allocator.create(EiwaType);
                elem_type.* = .{ .Custom = actual_class_name };
                ret_type.* = .{ .GenericInstance = .{
                    .base_name = "List",
                    .type_args = try self.allocator.dupe(*const EiwaType, &.{elem_type}),
                }};
                fn_type.* = .{ .Function = .{
                    .params = &.{},
                    .return_type = ret_type,
                    .c_name = try std.fmt.allocPrint(self.allocator, "{s}_values", .{actual_class_name}),
                }};
                prop_type = fn_type;
            } else {
                var found_variant = false;
                for (ed.variants) |variant| {
                    if (std.mem.eql(u8, variant.name, g.name)) {
                        found_variant = true;
                        const variant_type = try self.allocator.create(EiwaType);
                        variant_type.* = .{ .Custom = actual_class_name };
                        prop_type = variant_type;
                        break;
                    }
                }
                if (!found_variant) {
                    self.reportError(node.line, node.column, "TypeError: Variant '{s}' not found in enum '{s}'.", .{g.name, class_name});
                    return error.TypeError;
                }
            }
        }
    }

    if (!is_static) {
        if (isNullable(obj_type) and !g.is_safe) {
            self.reportError(node.line, node.column, "TypeError: Only safe (?.) or non-null asserted (!!.) calls are allowed on a nullable receiver of type {}.", .{obj_type.*});
            return error.TypeError;
        }
    }
    const base_type = extractBaseType(obj_type);
    var lookup_name: ?[]const u8 = null;
    var base_name: ?[]const u8 = null;
    switch (base_type.*) {
        .Custom => |n| base_name = n,
        .GenericInstance => |gi| {
            const actual_gi_base = self.alias_map.get(gi.base_name) orelse gi.base_name;
            var mangled = ArrayList(u8).init(self.allocator);
            try mangled.appendSlice(actual_gi_base);
            try mangled.appendSlice("_");
            for (gi.type_args, 0..) |t_arg, i| {
                if (i > 0) try mangled.appendSlice("_");
                try t_arg.formatSafe(mangled.writer());
            }
            base_name = try mangled.toOwnedSlice();
        },
        .Int => base_name = "core_Int",
        .String => base_name = "core_String",
        .Bool => base_name = "core_Bool",
        else => {},
    }
    
    if (base_name) |bn| {
        lookup_name = self.alias_map.get(bn) orelse bn;
    }
    
    if (lookup_name) |name| {
        var actual_name = name;
        if (!self.classes_ast.contains(actual_name) and std.mem.indexOf(u8, actual_name, " | ") != null) {
            var buf = ArrayList(u8).init(self.allocator);
            var it = std.mem.splitSequence(u8, actual_name, " | ");
            var idx: usize = 0;
            while (it.next()) |part| : (idx += 1) {
                if (idx > 0) try buf.appendSlice("_or_");
                try buf.appendSlice(part);
            }
            actual_name = try buf.toOwnedSlice();
        }
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
        if (class_node_opt == null and base_type.* == .GenericInstance) {
            const gi_base = self.alias_map.get(base_type.GenericInstance.base_name) orelse base_type.GenericInstance.base_name;
            class_node_opt = self.classes_ast.get(gi_base);
            if (class_node_opt == null and self.registry != null) {
                var mod_it = self.registry.?.modules.iterator();
                while (mod_it.next()) |entry| {
                    const mod_actual = entry.value_ptr.checker.alias_map.get(gi_base) orelse gi_base;
                    if (entry.value_ptr.checker.classes_ast.get(mod_actual)) |bn| {
                        class_node_opt = bn;
                        break;
                    }
                }
            }
        }
        if (self.enums_ast.get(actual_name) != null) {
            if (std.mem.eql(u8, g.name, "ordinal")) {
                const int_t = try self.allocator.create(EiwaType);
                int_t.* = .Int;
                prop_type = int_t;
            } else if (std.mem.eql(u8, g.name, "name")) {
                const str_t = try self.allocator.create(EiwaType);
                str_t.* = .String;
                prop_type = str_t;
            } else if (std.mem.eql(u8, g.name, "toString")) {
                const fn_t = try self.allocator.create(EiwaType);
                const str_t = try self.allocator.create(EiwaType);
                str_t.* = .String;
                fn_t.* = .{ .Function = .{
                    .params = &.{},
                    .return_type = str_t,
                    .c_name = try std.fmt.allocPrint(self.allocator, "{s}_toString", .{actual_name}),
                }};
                prop_type = fn_t;
            } else if (std.mem.eql(u8, g.name, "hashCode")) {
                const fn_t = try self.allocator.create(EiwaType);
                const int_t = try self.allocator.create(EiwaType);
                int_t.* = .Int;
                fn_t.* = .{ .Function = .{
                    .params = &.{},
                    .return_type = int_t,
                    .c_name = try std.fmt.allocPrint(self.allocator, "{s}_hashCode", .{actual_name}),
                }};
                prop_type = fn_t;
            } else if (std.mem.eql(u8, g.name, "equals")) {
                const fn_t = try self.allocator.create(EiwaType);
                const bool_t = try self.allocator.create(EiwaType);
                bool_t.* = .Bool;
                const param_t = try self.allocator.create(EiwaType);
                param_t.* = .{ .Custom = "Stringable" };
                fn_t.* = .{ .Function = .{
                    .params = try self.allocator.dupe(*const EiwaType, &.{param_t}),
                    .return_type = bool_t,
                    .c_name = try std.fmt.allocPrint(self.allocator, "{s}_equals", .{actual_name}),
                }};
                prop_type = fn_t;
            }
        } else if (self.contracts_ast.get(name)) |contract_node| {
            // Member lookup on a contract-typed receiver
            for (contract_node.data.contract_decl.methods) |method| {
                if (method.data == .fun_decl and std.mem.eql(u8, method.data.fun_decl.name, g.name)) {
                    if (method.data.fun_decl.type_ref) |tr| {
                        prop_type = try self.resolveTypeRef(tr);
                    } else {
                        const void_type = try self.allocator.create(EiwaType);
                        void_type.* = .Void;
                        prop_type = void_type;
                    }
                    break;
                }
            }
        } else if (class_node_opt) |class_node| {
            const c = class_node.data.type_decl;
            for (c.primary_constructor) |prop| {
                if (std.mem.eql(u8, prop.name, g.name)) {
                    prop_type = prop.resolved_type orelse self.resolveTypeRef(prop.type_ref) catch null;
                    break;
                }
            }
            if (prop_type == null) {
                for (c.methods) |method| {
                    if (std.mem.eql(u8, method.data.fun_decl.name, g.name)) {
                        if (method.data.fun_decl.type_ref) |tr| {
                            prop_type = try self.resolveTypeRef(tr);
                        } else if (method.data.fun_decl.is_expr_body) {
                            if (method.data.fun_decl.body.resolved_type) |rt| {
                                prop_type = rt;
                            } else {
                                const void_type = try self.allocator.create(EiwaType);
                                void_type.* = .Void;
                                prop_type = void_type;
                            }
                        } else {
                            const void_type = try self.allocator.create(EiwaType);
                            void_type.* = .Void;
                            prop_type = void_type;
                        }
                        break;
                    }
                }
            }
        }
    } else if (base_type.* == .Array) {
        if (std.mem.eql(u8, g.name, "length")) {
            const int_t = try self.allocator.create(EiwaType);
            int_t.* = .Int;
            prop_type = int_t;
        } else if (std.mem.eql(u8, g.name, "push")) {
            // Returns a function type that takes T and returns Void
            const fun_t = try self.allocator.create(EiwaType);
            var params = try self.allocator.alloc(*const EiwaType, 1);
            params[0] = base_type.Array;
            
            const void_t = try self.allocator.create(EiwaType);
            void_t.* = .Void;
            
            fun_t.* = .{ .Function = .{
                .params = params,
                .return_type = void_t,
                .c_name = "", // Will be resolved in the C Transpiler
            }};
            prop_type = fun_t;
        } else if (std.mem.eql(u8, g.name, "set")) {
            // set(index: Int, val: T): Void
            const fun_t = try self.allocator.create(EiwaType);
            var params = try self.allocator.alloc(*const EiwaType, 2);
            
            const int_t = try self.allocator.create(EiwaType);
            int_t.* = .Int;
            
            params[0] = int_t;
            params[1] = base_type.Array;
            
            const void_t = try self.allocator.create(EiwaType);
            void_t.* = .Void;
            
            fun_t.* = .{ .Function = .{
                .params = params,
                .return_type = void_t,
                .c_name = "",
            }};
            prop_type = fun_t;
        }
    }

    if (prop_type == null and std.mem.eql(u8, g.name, "toString")) {
        const fn_type = try self.allocator.create(EiwaType);
        const str_type = try self.allocator.create(EiwaType);
        const actual_str_name = self.alias_map.get("String") orelse "core_String";
        str_type.* = .{ .Custom = actual_str_name };
        fn_type.* = .{ .Function = .{
            .params = &.{},
            .return_type = str_type,
            .receiver = obj_type,
            .c_name = if (base_type.* == .Bool) "core_Bool_toString" else (if (base_type.* == .Int) "core_Int_toString" else "toString"),
        } };
        prop_type = fn_type;
    }

    if (prop_type == null and std.mem.eql(u8, g.name, "hashCode")) {
        const fn_type = try self.allocator.create(EiwaType);
        const int_type = try self.allocator.create(EiwaType);
        int_type.* = .Int;
        fn_type.* = .{ .Function = .{
            .params = &.{},
            .return_type = int_type,
            .receiver = obj_type,
            .c_name = if (base_type.* == .Int) "core_Int_hashCode" else (if (base_type.* == .Bool) "core_Bool_hashCode" else "hashCode"),
        } };
        prop_type = fn_type;
    }

    if (prop_type == null and base_type.* == .Union) {
        const left_t = inferGetExprForSingleType(self, base_type.Union.left, g.name);
        const right_t = inferGetExprForSingleType(self, base_type.Union.right, g.name);
        if (left_t != null and right_t != null) {
            if (self.isCompatible(left_t.?, right_t.?)) {
                prop_type = left_t.?;
            } else {
                const union_res = try self.allocator.create(EiwaType);
                union_res.* = .{ .Union = .{ .left = left_t.?, .right = right_t.? } };
                prop_type = union_res;
            }
        }
    }

    if (prop_type == null) {
        self.reportError(node.line, node.column, "TypeError: Unresolved property '{s}' on type {}.", .{ g.name, obj_type.* });
        return error.TypeError;
    }

    if (isNullable(obj_type) and g.is_safe) {
        t.* = .{ .Union = .{
            .left = prop_type.?,
            .right = try self.allocator.create(EiwaType),
        } };
        @constCast(t.Union.right).* = .Null;
    } else {
        t.* = prop_type.?.*;
    }
}

pub fn inferSetExpr(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    var s = &node.data.set_expr;
    const obj_type = try self.inferNode(s.object, scope);
    const assigned_type = try self.inferNode(s.value, scope);

    if (s.object.data == .identifier) {
        const class_name = s.object.data.identifier.name;
        const actual_class_name = self.alias_map.get(class_name) orelse class_name;
        if (self.objects_ast.contains(actual_class_name)) {
            s.object.data.identifier.resolved_c_name = actual_class_name;
            const obj_node = self.objects_ast.get(actual_class_name).?;
            const obj = obj_node.data.object_decl;
            var found_prop = false;
            for (obj.members) |member| {
                if (member.data == .var_decl and std.mem.eql(u8, member.data.var_decl.name, s.name)) {
                    found_prop = true;
                    if (member.resolved_type == null) {
                        _ = try self.inferNode(member, scope);
                    }
                    const v = member.data.var_decl;
                    if (!v.is_mut) {
                        self.reportError(node.line, node.column, "TypeError: Cannot assign to constant property '{s}' of object '{s}'.", .{ s.name, class_name });
                        return error.TypeError;
                    }
                    const prop_type = member.resolved_type.?;
                    if (!self.isCompatible(prop_type, assigned_type)) {
                        self.reportError(node.line, node.column, "TypeError: Expected {} but found {} when setting static property '{s}'.", .{ prop_type.*, assigned_type.*, s.name });
                        return error.TypeError;
                    }
                    break;
                }
            }
            if (!found_prop) {
                self.reportError(node.line, node.column, "TypeError: Unresolved static property '{s}' on object '{s}'.", .{ s.name, class_name });
                return error.TypeError;
            }
            t.* = assigned_type.*;
            return;
        }
    }

    const base_type = extractBaseType(obj_type);
    var lookup_name: ?[]const u8 = null;
    switch (base_type.*) {
        .Custom => |n| lookup_name = self.alias_map.get(n) orelse n,
        .GenericInstance => |gi| {
            const actual_gi_base = self.alias_map.get(gi.base_name) orelse gi.base_name;
            var mangled = ArrayList(u8).init(self.allocator);
            try mangled.appendSlice(actual_gi_base);
            try mangled.appendSlice("_");
            for (gi.type_args, 0..) |t_arg, i| {
                if (i > 0) try mangled.appendSlice("_");
                try t_arg.formatSafe(mangled.writer());
            }
            const m_name = try mangled.toOwnedSlice();
            lookup_name = self.alias_map.get(m_name) orelse m_name;
        },
        else => {},
    }

    if (lookup_name) |name| {
        var actual_name = name;
        if (!self.classes_ast.contains(actual_name) and std.mem.indexOf(u8, actual_name, " | ") != null) {
            var buf = ArrayList(u8).init(self.allocator);
            var it = std.mem.splitSequence(u8, actual_name, " | ");
            var idx: usize = 0;
            while (it.next()) |part| : (idx += 1) {
                if (idx > 0) try buf.appendSlice("_or_");
                try buf.appendSlice(part);
            }
            actual_name = try buf.toOwnedSlice();
        }
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
        if (class_node_opt == null and base_type.* == .GenericInstance) {
            const gi_base = self.alias_map.get(base_type.GenericInstance.base_name) orelse base_type.GenericInstance.base_name;
            class_node_opt = self.classes_ast.get(gi_base);
            if (class_node_opt == null and self.registry != null) {
                var mod_it = self.registry.?.modules.iterator();
                while (mod_it.next()) |entry| {
                    const mod_actual = entry.value_ptr.checker.alias_map.get(gi_base) orelse gi_base;
                    if (entry.value_ptr.checker.classes_ast.get(mod_actual)) |bn| {
                        class_node_opt = bn;
                        break;
                    }
                }
            }
        }
        var found_prop = false;
        if (class_node_opt) |class_node| {
            const c = class_node.data.type_decl;
            for (c.primary_constructor) |prop| {
                if (std.mem.eql(u8, prop.name, s.name)) {
                    found_prop = true;
                    if (!prop.is_mut) {
                        self.reportError(node.line, node.column, "TypeError: Cannot assign to constant property '{s}' of type {}.", .{ s.name, base_type.* });
                        return error.TypeError;
                    }
                    const prop_type = prop.resolved_type orelse (self.resolveTypeRef(prop.type_ref) catch null);
                    if (prop_type) |pt| {
                        if (!self.isCompatible(pt, assigned_type)) {
                            self.reportError(node.line, node.column, "TypeError: Expected {} but found {} when setting property '{s}'.", .{ pt.*, assigned_type.*, s.name });
                            return error.TypeError;
                        }
                    }
                    break;
                }
            }
        }
        if (!found_prop) {
            self.reportError(node.line, node.column, "TypeError: Unresolved property '{s}' on type {}.", .{ s.name, base_type.* });
            return error.TypeError;
        }
    }

    t.* = assigned_type.*;
}

fn isNativeArrayType(t: *const EiwaType) bool {
    switch (t.*) {
        .Array => return true,
        .Custom => |n| return std.mem.startsWith(u8, n, "NativeArray") or std.mem.startsWith(u8, n, "EiwaArray"),
        .GenericInstance => |gi| return std.mem.startsWith(u8, gi.base_name, "NativeArray") or std.mem.startsWith(u8, gi.base_name, "Array"),
        else => return false,
    }
}

fn extractArrayElemType(self: *TypeChecker, obj_type: *const EiwaType) !*const EiwaType {
    switch (obj_type.*) {
        .Array => |elem| return elem,
        .GenericInstance => |gi| {
            if (gi.type_args.len > 0) return gi.type_args[0];
        },
        .Custom => |name| {
            if (std.mem.startsWith(u8, name, "NativeArray<") and std.mem.endsWith(u8, name, ">")) {
                const elem_str = name[12 .. name.len - 1];
                const dummy_ref = try self.allocator.create(ast.ASTTypeRef);
                dummy_ref.* = .{ .name = elem_str, .generic_args = &.{}, .is_array = false, .is_nullable = false };
                return try self.resolveTypeRef(dummy_ref);
            }
        },
        else => {},
    }
    const void_t = try self.allocator.create(EiwaType);
    void_t.* = .Void;
    return void_t;
}

pub fn inferIndexExpr(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    const i = node.data.index_expr;
    const obj_type = try self.inferNode(i.object, scope);
    
    if (!isNativeArrayType(obj_type) and (obj_type.* == .Custom or obj_type.* == .GenericInstance)) {
        // Redireciona para object.get(index)
        const get_ident = try self.allocator.create(ASTNode);
        get_ident.* = .{ .line = node.line, .column = node.column, .resolved_type = null, .data = .{ .identifier = .{ .name = "get", .resolved_c_name = null } } };
        
        const get_expr = try self.allocator.create(ASTNode);
        get_expr.* = .{ .line = node.line, .column = node.column, .resolved_type = null, .data = .{ .get_expr = .{ .object = i.object, .name = "get", .is_safe = false } } };
        
        var args = try self.allocator.alloc(*ASTNode, 1);
        args[0] = i.index;
        
        node.data = .{ .call_expr = .{ .callee = get_expr, .arguments = args } };
        
        try infer_call_mod.inferCallExpr(self, node, scope, t);
        return;
    }
    
    if (!isNativeArrayType(obj_type)) {
        self.reportError(node.line, node.column, "TypeError: Index operator '[]' can only be used on arrays or objects with .get(). Found {}.", .{obj_type.*});
        return error.TypeError;
    }
    
    const index_type = try self.inferNode(i.index, scope);
    if (index_type.* != .Int) {
        self.reportError(node.line, node.column, "TypeError: Array index must be Int. Found {}.", .{index_type.*});
        return error.TypeError;
    }
    
    t.* = (try extractArrayElemType(self, obj_type)).*;
}

pub fn inferIndexSetExpr(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    const i = node.data.index_set_expr;
    const obj_type = try self.inferNode(i.object, scope);
    
    if (!isNativeArrayType(obj_type) and (obj_type.* == .Custom or obj_type.* == .GenericInstance)) {
        // Redireciona para object.put(index, value) ou object.set(index, value)
        const get_ident = try self.allocator.create(ASTNode);
        get_ident.* = .{ .line = node.line, .column = node.column, .resolved_type = null, .data = .{ .identifier = .{ .name = "put", .resolved_c_name = null } } };
        
        const get_expr = try self.allocator.create(ASTNode);
        get_expr.* = .{ .line = node.line, .column = node.column, .resolved_type = null, .data = .{ .get_expr = .{ .object = i.object, .name = "put", .is_safe = false } } };
        
        var args = try self.allocator.alloc(*ASTNode, 2);
        args[0] = i.index;
        args[1] = i.value;
        
        node.data = .{ .call_expr = .{ .callee = get_expr, .arguments = args } };
        
        try infer_call_mod.inferCallExpr(self, node, scope, t);
        return;
    }
    
    if (!isNativeArrayType(obj_type)) {
        self.reportError(node.line, node.column, "TypeError: Index assignment operator '[]=' can only be used on arrays or objects with .put(). Found {}.", .{obj_type.*});
        return error.TypeError;
    }
    
    const elem_type = try extractArrayElemType(self, obj_type);
    const index_type = try self.inferNode(i.index, scope);
    if (index_type.* != .Int) {
        self.reportError(node.line, node.column, "TypeError: Array index must be Int. Found {}.", .{index_type.*});
        return error.TypeError;
    }
    
    const value_type = try self.inferNode(i.value, scope);
    if (!self.isCompatible(elem_type, value_type)) {
        self.reportError(node.line, node.column, "TypeError: Cannot assign {} to array of {}.", .{value_type.*, elem_type.*});
        return error.TypeError;
    }
    
    t.* = .Void;
}

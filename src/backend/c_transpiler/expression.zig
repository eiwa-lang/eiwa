const std = @import("std");
const compat = @import("../../core/compat.zig");
const ArrayList = compat.ArrayList;
const core = @import("core.zig");
const ts = @import("../../core/type_system.zig");

const ASTNode = core.ASTNode;
const CTranspiler = core.CTranspiler;

fn listItemType(self: *CTranspiler, t: *const ts.EiwaType) ?*const ts.EiwaType {
    const base = ts.extractBaseType(t);
    if (base.* != .Custom) return null;
    const classes_ast = self.classes_ast orelse return null;
    const class_node = classes_ast.get(base.Custom) orelse return null;
    if (class_node.data != .type_decl) return null;
    for (class_node.data.type_decl.primary_constructor) |prop| {
        if (!std.mem.eql(u8, prop.name, "items")) continue;
        const prop_type = prop.resolved_type orelse continue;
        const prop_base = ts.extractBaseType(prop_type);
        if (prop_base.* == .Array) return prop_base.Array;
    }
    return null;
}

pub fn emitExpression(self: *CTranspiler, node: *ASTNode) !void {
    switch (node.data) {
        .int_literal => |val| {
            try self.writer.writer().print("{}", .{val});
        },
        .bool_literal => |b| {
            if (b) try self.writer.appendSlice("1")
            else try self.writer.appendSlice("0");
        },
        .null_literal => {
            try self.writer.appendSlice("0");
        },
        .string_literal => |val| {
            try self.writer.writer().print("\"{s}\"", .{val});
        },
        .identifier => |i| {
            const name = try core.cIdent(self.allocator, i.resolved_c_name orelse i.name);
            if (node.resolved_type != null and node.resolved_type.?.* == .Void) {
                try self.writer.appendSlice("0");
            } else if (i.is_class_property) {
                try self.writer.writer().print("this->{s}", .{i.name});
            } else if (i.is_boxed) {
                try self.writer.writer().print("{s}->value", .{name});
            } else {
                try self.writer.appendSlice(name);
            }
        },
        .named_arg => |na| {
            try self.emitExpression(na.value);
        },
        .unary_expr => |u| {
            if (u.operator == .bang_bang) {
                try self.emitExpression(u.operand);
            } else if (u.operator == .bang) {
                try self.writer.appendSlice("!(");
                try self.emitExpression(u.operand);
                try self.writer.appendSlice(")");
            } else if (u.operator == .minus) {
                try self.writer.appendSlice("-(");
                try self.emitExpression(u.operand);
                try self.writer.appendSlice(")");
            }
        },
        .array_literal => |a| {
            if (node.resolved_type) |rt| {
                if (ts.extractBaseType(rt).* == .Array) {
                    try self.emitArrayStruct(ts.extractBaseType(rt).Array);
                    
                    const inner_c_type = try self.cType(ts.extractBaseType(rt).Array);
                    var safe_inner = ArrayList(u8).init(self.allocator);
                    for (inner_c_type) |ch| {
                        if (ch == '*') continue;
                        if (ch == ' ') continue;
                        try safe_inner.append(ch);
                    }
                    const struct_name = try std.fmt.allocPrint(self.allocator, "EiwaArray_{s}", .{safe_inner.items});
                    
                    try self.writer.appendSlice("({ ");
                    try self.writer.writer().print("{s}* _tmp_arr = {s}_new(); ", .{struct_name, struct_name});
                    for (a.elements) |elem| {
                        try self.writer.writer().print("{s}_push(_tmp_arr, ", .{struct_name});
                        try self.emitExpression(elem);
                        try self.writer.appendSlice("); ");
                    }
                    try self.writer.appendSlice("_tmp_arr; })");
                } else if (rt.* == .Custom) {
                    const struct_name = rt.Custom;
                    try self.writer.writer().print("{s}_new(({{ ", .{struct_name});
                    
                    var safe_inner_name = ArrayList(u8).init(self.allocator);
                    if (listItemType(self, rt)) |item_type| {
                        const inner_c_type = try self.cType(item_type);
                        for (inner_c_type) |ch| {
                            if (ch == '*') continue;
                            if (ch == ' ') continue;
                            try safe_inner_name.append(ch);
                        }
                    } else if (a.elements.len > 0) {
                        const inner_c_type = try self.cType(a.elements[0].resolved_type.?);
                        for (inner_c_type) |ch| {
                            if (ch == '*') continue;
                            if (ch == ' ') continue;
                            try safe_inner_name.append(ch);
                        }
                    } else {
                        try safe_inner_name.appendSlice("Void");
                    }
                    const safe_inner = safe_inner_name.items;
                    
                    const array_struct_name = try std.fmt.allocPrint(self.allocator, "EiwaArray_{s}", .{safe_inner});
                    try self.writer.writer().print("{s}* _tmp_arr = {s}_new(); ", .{array_struct_name, array_struct_name});
                    for (a.elements) |elem| {
                        try self.writer.writer().print("{s}_push(_tmp_arr, ", .{array_struct_name});
                        const elem_t = if (elem.resolved_type) |ert| ts.extractBaseType(ert) else null;
                        const is_elem_primitive = elem_t != null and (elem_t.?.* == .Int or elem_t.?.* == .Bool);
                        const is_target_void = std.mem.eql(u8, safe_inner, "void");
                        if (is_elem_primitive and is_target_void) {
                            try self.writer.appendSlice("(void*)(intptr_t)(");
                            try self.emitExpression(elem);
                            try self.writer.appendSlice(")");
                        } else {
                            try self.emitExpression(elem);
                        }
                        try self.writer.appendSlice("); ");
                    }
                    try self.writer.appendSlice("_tmp_arr; }))");
                }
            }
        },
        .map_literal => |m| {
            if (node.resolved_type) |rt| {
                if (rt.* == .Custom) {
                    const custom_name = rt.Custom; // Map_core_String_core_String
                    
                    var safe_inner_name = ArrayList(u8).init(self.allocator);
                    if (m.elements.len > 0) {
                        const call = m.elements[0].data.call_expr;
                        try call.arguments[0].resolved_type.?.formatSafe(safe_inner_name.writer());
                        try safe_inner_name.appendSlice("_");
                        try call.arguments[1].resolved_type.?.formatSafe(safe_inner_name.writer());
                    } else {
                        try safe_inner_name.appendSlice("Void_Void");
                    }
                    const safe_inner = safe_inner_name.items;
                    
                    const node_name = try std.fmt.allocPrint(self.allocator, "collections_Node_{s}", .{ safe_inner });
                    const custom_t = try self.allocator.create(ts.EiwaType);
                    custom_t.* = .{ .Custom = node_name };
                    const null_t = try self.allocator.create(ts.EiwaType);
                    null_t.* = .Null;
                    const union_t = try self.allocator.create(ts.EiwaType);
                    union_t.* = .{ .Union = .{ .left = custom_t, .right = null_t } };
                    
                    try self.emitArrayStruct(union_t);
                    
                    const array_name = try std.fmt.allocPrint(self.allocator, "EiwaArray_{s}", .{node_name});
                    const list_name = try std.fmt.allocPrint(self.allocator, "collections_List_collections_Node_{s}Opt", .{safe_inner});
                    const mmap_name = try std.fmt.allocPrint(self.allocator, "collections_MutableMap_{s}", .{safe_inner});
                    
                    try self.writer.writer().print("{s}_new(({{ ", .{custom_name});
                    try self.writer.writer().print("{s}* _buckets = {s}_new(); ", .{array_name, array_name});
                    try self.writer.writer().print("for (int _i = 0; _i < 16; _i++) {{ {s}_push(_buckets, 0); }} ", .{array_name});
                    try self.writer.writer().print("{s}* _list = {s}_new(_buckets); ", .{list_name, list_name});
                    try self.writer.writer().print("{s}* _mmap = {s}_new(_list); ", .{mmap_name, mmap_name});
                    
                    for (m.elements) |elem| {
                        const call = elem.data.call_expr;
                        try self.writer.writer().print("{s}_put(_mmap, ", .{mmap_name});
                        try self.emitExpression(call.arguments[0]);
                        try self.writer.appendSlice(", ");
                        try self.emitExpression(call.arguments[1]);
                        try self.writer.appendSlice("); ");
                    }
                    
                    try self.writer.appendSlice("_list; }))");
                }
            }
        },
        .index_expr => |idx| {
            try self.emitExpression(idx.object);
            try self.writer.appendSlice("->data[");
            try self.emitExpression(idx.index);
            try self.writer.appendSlice("]");
        },
        .index_set_expr => |s| {
            try self.emitExpression(s.object);
            try self.writer.appendSlice("->data[");
            try self.emitExpression(s.index);
            try self.writer.appendSlice("] = ");
            try self.emitExpression(s.value);
        },

        .assignment => |a| {
            if (a.value.resolved_type) |vrt| {
                if (ts.extractBaseType(vrt).* == .Void) {
                    // Void values have no C storage: evaluate for the side
                    // effect and drop the store (see cStorageType).
                    try self.emitExpression(a.value);
                    return;
                }
            }
            if (a.is_class_property) {
                try self.writer.writer().print("this->{s} = ", .{a.name});
            } else if (a.is_boxed) {
                try self.writer.writer().print("{s}->value = ", .{try core.cIdent(self.allocator, a.name)});
            } else {
                try self.writer.writer().print("{s} = ", .{try core.cIdent(self.allocator, a.name)});
            }
            if (a.value.resolved_type) |vrt| {
                const val_base = ts.extractBaseType(vrt);
                if (val_base.* == .Int or val_base.* == .Bool) {
                    var is_void_target = false;
                    if (a.value.expected_type) |ext| {
                        const target_base = ts.extractBaseType(ext);
                        if (target_base.* == .Union or (target_base.* == .Custom and !std.mem.eql(u8, target_base.Custom, "core_Int") and !std.mem.eql(u8, target_base.Custom, "core_Bool"))) {
                            is_void_target = true;
                        }
                    }
                    if (is_void_target) {
                        try self.writer.appendSlice("(void*)(intptr_t)(");
                        try self.emitExpression(a.value);
                        try self.writer.appendSlice(")");
                        return;
                    }
                }
            }
            try self.emitExpression(a.value);
        },
        .get_expr => |g| {
            if (self.objects_ast) |oa| {
                if (g.object.data == .identifier) {
                    const class_name = g.object.data.identifier.name;
                    const actual_class_name = g.object.data.identifier.resolved_c_name orelse if (self.alias_map) |am| (am.get(class_name) orelse class_name) else class_name;
                    if (oa.contains(actual_class_name)) {
                        try self.writer.writer().print("{s}_{s}", .{actual_class_name, g.name});
                        return;
                    }
                }
            }
            if (self.enums_ast) |ea| {
                if (g.object.data == .identifier) {
                    const class_name = g.object.data.identifier.name;
                    const actual_class_name = g.object.data.identifier.resolved_c_name orelse if (self.alias_map) |am| (am.get(class_name) orelse class_name) else class_name;
                    if (ea.contains(actual_class_name)) {
                        try self.writer.writer().print("{s}_{s}", .{actual_class_name, g.name});
                        return;
                    }
                }
            }
            const rt = g.object.resolved_type.?;
            const base_type = ts.extractBaseType(rt);
            if (base_type.* == .Custom) {
                const class_name = base_type.Custom;

                if (g.is_safe) {
                    try self.writer.appendSlice("((");
                    try self.emitExpression(g.object);
                    try self.writer.writer().print(") == 0 ? 0 : ((({s}*)(", .{class_name});
                    try self.emitExpression(g.object);
                    try self.writer.writer().print("))->{s}))", .{g.name});
                } else {
                    try self.writer.writer().print("((({s}*)(", .{class_name});
                    try self.emitExpression(g.object);
                    try self.writer.writer().print("))->{s})", .{g.name});
                }
            } else {
                if (g.is_safe) {
                    try self.writer.appendSlice("((");
                    try self.emitExpression(g.object);
                    try self.writer.appendSlice(") == 0 ? 0 : (");
                    try self.emitExpression(g.object);
                    try self.writer.writer().print(")->{s})", .{g.name});
                } else {
                    try self.emitExpression(g.object);
                    try self.writer.writer().print("->{s}", .{g.name});
                }
            }
        },
        .set_expr => |s| {
            if (s.value.resolved_type) |vrt| {
                if (ts.extractBaseType(vrt).* == .Void) {
                    // Void values have no C storage: evaluate for the side
                    // effect and drop the store (see cStorageType).
                    try self.emitExpression(s.value);
                    return;
                }
            }
            if (self.objects_ast) |oa| {
                if (s.object.data == .identifier) {
                    const class_name = s.object.data.identifier.name;
                    const actual_class_name = s.object.data.identifier.resolved_c_name orelse if (self.alias_map) |am| (am.get(class_name) orelse class_name) else class_name;
                    if (oa.contains(actual_class_name)) {
                        try self.writer.writer().print("({s}_{s} = ", .{actual_class_name, s.name});
                        try self.emitExpression(s.value);
                        try self.writer.appendSlice(")");
                        return;
                    }
                }
            }
            const rt = s.object.resolved_type.?;
            const base_type = ts.extractBaseType(rt);
            if (base_type.* == .Custom) {
                const class_name = base_type.Custom;

                try self.writer.writer().print("((({s}*)(", .{class_name});
                try self.emitExpression(s.object);
                try self.writer.writer().print("))->{s} = ", .{s.name});
                const val_t = if (s.value.resolved_type) |vrt| ts.extractBaseType(vrt) else null;
                const exp_t = if (s.value.expected_type) |ext| ts.extractBaseType(ext) else null;
                if (val_t != null and (val_t.?.* == .Int or val_t.?.* == .Bool) and exp_t != null and (exp_t.?.* == .Union or exp_t.?.* == .Pointer or (exp_t.?.* == .Custom and !std.mem.eql(u8, exp_t.?.Custom, "core_Int") and !std.mem.eql(u8, exp_t.?.Custom, "core_Bool")))) {
                    try self.writer.appendSlice("(void*)(intptr_t)(");
                    try self.emitExpression(s.value);
                    try self.writer.appendSlice(")");
                } else {
                    try self.emitExpression(s.value);
                }
                try self.writer.appendSlice(")");
            } else {
                try self.emitExpression(s.object);
                try self.writer.writer().print("->{s} = ", .{s.name});
                const val_t = if (s.value.resolved_type) |vrt| ts.extractBaseType(vrt) else null;
                const exp_t = if (s.value.expected_type) |ext| ts.extractBaseType(ext) else null;
                if (val_t != null and (val_t.?.* == .Int or val_t.?.* == .Bool) and exp_t != null and (exp_t.?.* == .Union or exp_t.?.* == .Pointer or (exp_t.?.* == .Custom and !std.mem.eql(u8, exp_t.?.Custom, "core_Int") and !std.mem.eql(u8, exp_t.?.Custom, "core_Bool")))) {
                    try self.writer.appendSlice("(void*)(intptr_t)(");
                    try self.emitExpression(s.value);
                    try self.writer.appendSlice(")");
                } else {
                    try self.emitExpression(s.value);
                }
            }
        },
        .call_expr => |c| {
            var is_closure = (c.callee.data == .identifier and c.callee.data.identifier.resolved_c_name == null and c.callee.resolved_type != null and ts.extractBaseType(c.callee.resolved_type.?).* == .Function);
            if (!is_closure and c.callee.data == .get_expr and c.callee.resolved_type != null and ts.extractBaseType(c.callee.resolved_type.?).* == .Function) {
                const g = c.callee.data.get_expr;
                if (g.object.resolved_type) |rt| {
                    var class_name: ?[]const u8 = null;
                    if (rt.* == .Custom) {
                        class_name = rt.Custom;
                    } else if (rt.* == .Union and rt.Union.left.* == .Custom) {
                        class_name = rt.Union.left.Custom;
                    }
                    if (class_name) |cn| {
                        const actual_cn = if (self.alias_map) |am| am.get(cn) orelse cn else cn;
                        if (self.classes_ast) |ca| {
                            if (ca.get(actual_cn)) |class_node| {
                                const cd = class_node.data.type_decl;
                                for (cd.primary_constructor) |prop| {
                                    if (std.mem.eql(u8, prop.name, g.name)) {
                                        is_closure = true;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if (!is_closure and c.callee.data != .identifier and c.callee.data != .get_expr and c.callee.resolved_type != null and ts.extractBaseType(c.callee.resolved_type.?).* == .Function) {
                is_closure = true;
            }
            if (is_closure) {
                const f = ts.extractBaseType(c.callee.resolved_type.?).Function;
                const ret_type_str = try self.cType(f.return_type);
                
                var params_c = ArrayList(u8).init(self.allocator);
                try params_c.appendSlice("void*");
                if (f.receiver) |rec| {
                    try params_c.appendSlice(", ");
                    try params_c.appendSlice(try self.cType(rec));
                }
                for (f.params) |p| {
                    try params_c.appendSlice(", ");
                    try params_c.appendSlice(try self.cType(p));
                }
                
                try self.writer.appendSlice("((");
                try self.writer.writer().print("{s} (*)({s})", .{ret_type_str, params_c.items});
                try self.writer.appendSlice(")(");
                try self.emitExpression(c.callee);
                try self.writer.appendSlice(").fn_ptr)(");
                try self.emitExpression(c.callee);
                try self.writer.appendSlice(".env");
                
                for (c.arguments) |arg| {
                    try self.writer.appendSlice(", ");
                    try self.emitExpression(arg);
                }
                try self.writer.appendSlice(")");
            } else if (c.callee.data == .identifier) {

                const raw_c_name = c.callee.data.identifier.resolved_c_name orelse c.callee.data.identifier.name;
                const c_name = if (self.alias_map) |am| am.get(raw_c_name) orelse raw_c_name else raw_c_name;
                if (self.classes.contains(c_name) or self.known_constructors.contains(c_name)) {
                    try self.writer.writer().print("{s}_new", .{c_name});
                    try self.writer.appendSlice("(");
                    for (c.arguments, 0..) |arg, i| {
                        if (i > 0) try self.writer.appendSlice(", ");
                        const arg_t = if (arg.resolved_type) |art| ts.extractBaseType(art) else null;
                        const exp_t = if (arg.expected_type) |ext| ts.extractBaseType(ext) else null;
                        if (arg_t != null and (arg_t.?.* == .Int or arg_t.?.* == .Bool) and exp_t != null and (exp_t.?.* == .Union or exp_t.?.* == .Custom)) {
                            try self.writer.appendSlice("(void*)(intptr_t)(");
                            try self.emitExpression(arg);
                            try self.writer.appendSlice(")");
                        } else {
                            try self.emitExpression(arg);
                        }
                    }
                    try self.writer.appendSlice(")");
                } else {
                    try self.writer.writer().print("{s}(", .{c_name});
                    for (c.arguments, 0..) |arg, i| {
                        if (i > 0) try self.writer.appendSlice(", ");
                        const arg_t = if (arg.resolved_type) |art| ts.extractBaseType(art) else null;
                        const exp_t = if (arg.expected_type) |ext| ts.extractBaseType(ext) else null;
                        if (arg_t != null and (arg_t.?.* == .Int or arg_t.?.* == .Bool) and exp_t != null and (exp_t.?.* == .Union or exp_t.?.* == .Custom)) {
                            try self.writer.appendSlice("(void*)(intptr_t)(");
                            try self.emitExpression(arg);
                            try self.writer.appendSlice(")");
                        } else {
                            try self.emitExpression(arg);
                        }
                    }
                    try self.writer.appendSlice(")");
                }
            } else if (c.callee.data == .get_expr) {
                const g = c.callee.data.get_expr;
                const rt = g.object.resolved_type.?;
                
                if (rt.* == .Custom and self.libs.contains(rt.Custom)) {
                    // It's a C method call from a lib block!
                    var c_func_name = g.name;
                    if (self.alias_map) |am| {
                        const full_lib_func_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{rt.Custom, g.name});
                        defer self.allocator.free(full_lib_func_name);
                        if (am.get(full_lib_func_name)) |mapped| {
                            c_func_name = mapped;
                        }
                    }
                    try self.writer.writer().print("{s}(", .{c_func_name});
                    for (c.arguments, 0..) |arg, i| {
                        if (i > 0) try self.writer.appendSlice(", ");
                        const arg_t = ts.extractBaseType(arg.resolved_type.?);
                        const is_string = switch (arg_t.*) {
                            .String => true,
                            .Custom => |name| std.mem.eql(u8, name, "core_String") or std.mem.eql(u8, name, "String"),
                            else => false,
                        };
                        if (is_string) {
                            try self.writer.appendSlice("(");
                            try self.emitExpression(arg);
                            try self.writer.appendSlice(")->ptr");
                        } else {
                            try self.emitExpression(arg);
                        }
                    }
                    try self.writer.appendSlice(")");
                    return;
                }

                if (std.mem.eql(u8, g.name, "toString")) {
                    if (rt.* == .Bool) {
                        try self.writer.appendSlice("core_Bool_toString(");
                        try self.emitExpression(g.object);
                        try self.writer.appendSlice(")");
                        return;
                    } else if (rt.* == .Int) {
                        try self.writer.appendSlice("core_Int_toString(");
                        try self.emitExpression(g.object);
                        try self.writer.appendSlice(")");
                        return;
                    } else if (rt.* == .String) {
                        try self.emitExpression(g.object);
                        return;
                    } else if (rt.* == .Custom) {
                        const actual_cn = if (self.alias_map) |am| (am.get(rt.Custom) orelse rt.Custom) else rt.Custom;
                        if (!self.isContract(actual_cn) and !self.isContract(rt.Custom)) {
                            try self.writer.writer().print("{s}_toString(", .{actual_cn});
                            try self.emitExpression(g.object);
                            try self.writer.appendSlice(")");
                            return;
                        }
                    }
                    try self.writer.appendSlice("eiwa_to_string((void*)(");
                    try self.emitExpression(g.object);
                    try self.writer.appendSlice("))");
                    return;
                }

                if (std.mem.eql(u8, g.name, "hashCode")) {
                    if (rt.* == .Bool) {
                        try self.writer.appendSlice("core_Bool_hashCode(");
                        try self.emitExpression(g.object);
                        try self.writer.appendSlice(")");
                        return;
                    } else if (rt.* == .Int) {
                        try self.writer.appendSlice("core_Int_hashCode(");
                        try self.emitExpression(g.object);
                        try self.writer.appendSlice(")");
                        return;
                    } else if (rt.* == .String) {
                        try self.writer.appendSlice("core_String_hashCode(");
                        try self.emitExpression(g.object);
                        try self.writer.appendSlice(")");
                        return;
                    } else if (rt.* == .Custom) {
                        const actual_cn = if (self.alias_map) |am| (am.get(rt.Custom) orelse rt.Custom) else rt.Custom;
                        if (!self.isContract(actual_cn) and !self.isContract(rt.Custom)) {
                            try self.writer.writer().print("{s}_hashCode(", .{actual_cn});
                            try self.emitExpression(g.object);
                            try self.writer.appendSlice(")");
                            return;
                        }
                    }
                    try self.writer.appendSlice("eiwa_hash_code((void*)(");
                    try self.emitExpression(g.object);
                    try self.writer.appendSlice("))");
                    return;
                }

                var class_name: []const u8 = "unknown";
                if (rt.* == .String) {
                    class_name = "core_String";
                } else if (rt.* == .Int) {
                    class_name = "core_Int";
                } else if (rt.* == .Bool) {
                    class_name = "core_Bool";
                } else if (rt.* == .Custom) {
                    class_name = rt.Custom;
                } else if (rt.* == .Array) {
                    const inner_c_type = try self.cType(rt.Array);
                    var safe_inner = ArrayList(u8).init(self.allocator);
                    for (inner_c_type) |ch| {
                        if (ch == '*') continue;
                        if (ch == ' ') continue;
                        try safe_inner.append(ch);
                    }
                    class_name = try std.fmt.allocPrint(self.allocator, "EiwaArray_{s}", .{safe_inner.items});
                } else if (rt.* == .Union) {
                    if (rt.Union.left.* == .String) {
                        class_name = "core_String";
                    } else if (rt.Union.left.* == .Custom) {
                        class_name = rt.Union.left.Custom;
                    }
                } else if (rt.* == .GenericInstance) {
                    if (self.isContract(rt.GenericInstance.base_name)) {
                        class_name = rt.GenericInstance.base_name;
                    }
                }
                
                var is_contract_call = false;
                var contract_method_index: usize = 0;
                const actual_contract_name = if (self.alias_map) |am| (am.get(class_name) orelse class_name) else class_name;
                if (self.isContract(class_name) or self.isContract(actual_contract_name)) {
                    if (self.contracts_ast.?.get(actual_contract_name) orelse self.contracts_ast.?.get(class_name)) |cnode| {
                        for (cnode.data.contract_decl.methods, 0..) |cm, idx| {
                            if (cm.data == .fun_decl and std.mem.eql(u8, cm.data.fun_decl.name, g.name)) {
                                is_contract_call = true;
                                contract_method_index = idx;
                                break;
                            }
                        }
                    }
                }

                if (is_contract_call) {
                    // Dynamic dispatch through the object header descriptor + contract vtable
                    const cnode = (self.contracts_ast.?.get(actual_contract_name) orelse self.contracts_ast.?.get(class_name)).?;
                    const cm = cnode.data.contract_decl.methods[contract_method_index];
                    var ret_str: []const u8 = "void";
                    var params_str = ArrayList(u8).init(self.allocator);
                    if (cm.resolved_type) |crt| {
                        if (crt.* == .Function) {
                            ret_str = try self.cType(crt.Function.return_type);
                            for (crt.Function.params) |p| {
                                try params_str.appendSlice(", ");
                                try params_str.appendSlice(try self.cType(p));
                            }
                        }
                    }
                    // Generic contract methods carry no resolved signature; use the
                    // call site's substituted types (e.g. await(): T -> Int).
                    if (node.resolved_type) |nrt| {
                        const nrt_base = ts.extractBaseType(nrt);
                        if (nrt_base.* != .Custom or !std.mem.eql(u8, nrt_base.Custom, "T")) {
                            ret_str = try self.cType(nrt_base);
                        }
                    }
                    if (cm.resolved_type == null) {
                        params_str.items = &.{};
                        for (c.arguments) |arg| {
                            try params_str.appendSlice(", ");
                            const at = if (arg.resolved_type) |art| ts.extractBaseType(art) else null;
                            if (at) |a| {
                                try params_str.appendSlice(try self.cType(a));
                            } else {
                                try params_str.appendSlice("void*");
                            }
                        }
                    }
                    if (g.is_safe) {
                        try self.writer.appendSlice("((");
                        try self.emitExpression(g.object);
                        try self.writer.appendSlice(") == 0 ? 0 : ");
                    }
                    if (std.mem.eql(u8, g.name, "toString")) {
                        try self.writer.appendSlice("eiwa_to_string((void*)(");
                        try self.emitExpression(g.object);
                        try self.writer.appendSlice("))");
                        if (g.is_safe) try self.writer.appendSlice(")");
                        return;
                    } else if (std.mem.eql(u8, g.name, "hashCode")) {
                        try self.writer.appendSlice("eiwa_hash_code((void*)(");
                        try self.emitExpression(g.object);
                        try self.writer.appendSlice("))");
                        if (g.is_safe) try self.writer.appendSlice(")");
                        return;
                    }

                    try self.writer.writer().print("(({s}(*)(void*{s}))eiwa_find_vtable(*(const EiwaTypeDescriptor**) (", .{ ret_str, params_str.items });
                    try self.emitExpression(g.object);
                    try self.writer.writer().print("), &{s}_contract)[{d}])(", .{ actual_contract_name, contract_method_index });
                    try self.emitExpression(g.object);
                    for (c.arguments) |arg| {
                        try self.writer.appendSlice(", ");
                        try self.emitExpression(arg);
                    }
                    try self.writer.appendSlice(")");
                    if (g.is_safe) {
                        try self.writer.appendSlice(")");
                    }
                } else if (g.is_safe) {
                    const actual_c_fn = g.resolved_c_name orelse try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{class_name, g.name});
                    try self.writer.appendSlice("((");
                    try self.emitExpression(g.object);
                    try self.writer.appendSlice(") == 0 ? 0 : ");
                    try self.writer.writer().print("{s}(", .{actual_c_fn});
                    try self.emitExpression(g.object);
                    for (c.arguments) |arg| {
                        try self.writer.appendSlice(", ");
                        const arg_t = if (arg.resolved_type) |art| ts.extractBaseType(art) else null;
                        const exp_t = if (arg.expected_type) |ext| ts.extractBaseType(ext) else null;
                        if (arg_t != null and (arg_t.?.* == .Int or arg_t.?.* == .Bool) and exp_t != null and (exp_t.?.* == .Union or exp_t.?.* == .Custom)) {
                            try self.writer.appendSlice("(void*)(intptr_t)(");
                            try self.emitExpression(arg);
                            try self.writer.appendSlice(")");
                        } else {
                            try self.emitExpression(arg);
                        }
                    }
                    try self.writer.appendSlice("))");
                } else {
                    const actual_c_fn = g.resolved_c_name orelse try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{class_name, g.name});
                    try self.writer.writer().print("{s}(", .{actual_c_fn});


                    try self.emitExpression(g.object);
                    for (c.arguments) |arg| {
                        try self.writer.appendSlice(", ");
                        const arg_t = if (arg.resolved_type) |art| ts.extractBaseType(art) else null;
                        const exp_t = if (arg.expected_type) |ext| ts.extractBaseType(ext) else null;
                        if (arg_t != null and (arg_t.?.* == .Int or arg_t.?.* == .Bool) and exp_t != null and (exp_t.?.* == .Union or exp_t.?.* == .Custom)) {
                            try self.writer.appendSlice("(void*)(intptr_t)(");
                            try self.emitExpression(arg);
                            try self.writer.appendSlice(")");
                        } else {
                            try self.emitExpression(arg);
                        }
                    }
                    try self.writer.appendSlice(")");
                }

            } else {
                try self.emitExpression(c.callee);
                try self.writer.appendSlice("(");
                for (c.arguments, 0..) |arg, i| {
                    if (i > 0) try self.writer.appendSlice(", ");
                    try self.emitExpression(arg);
                }
                try self.writer.appendSlice(")");
            }
        },
        .if_expr => |i| {
            try self.writer.appendSlice("((");
            try self.emitExpression(i.condition);
            try self.writer.appendSlice(") ? ");
            
            if (i.then_branch.data == .block) {
                try self.emitExpression(i.then_branch.data.block.statements[0]); // Hack for simple ifs
            } else {
                try self.emitExpression(i.then_branch);
            }
            
            try self.writer.appendSlice(" : ");
            
            if (i.else_branch) |eb| {
                if (eb.data == .block) {
                    try self.emitExpression(eb.data.block.statements[0]);
                } else {
                    try self.emitExpression(eb);
                }
            } else {
                try self.writer.appendSlice("0"); // fallback
            }
            try self.writer.appendSlice(")");
        },
        .ternary_expr => |t| {
            try self.writer.appendSlice("((");
            try self.emitExpression(t.condition);
            try self.writer.appendSlice(") ? (");
            try self.emitExpression(t.then_branch);
            try self.writer.appendSlice(") : ");
            if (t.else_branch) |eb| {
                try self.writer.appendSlice("(");
                try self.emitExpression(eb);
                try self.writer.appendSlice(")");
            } else {
                try self.writer.appendSlice("0");
            }
            try self.writer.appendSlice(")");
        },
        .binary_expr => |b| {
            if (b.op == .elvis) {
                try self.writer.appendSlice("((");
                try self.emitExpression(b.left);
                try self.writer.appendSlice(") != 0 ? (");
                try self.emitExpression(b.left);
                try self.writer.appendSlice(") : (");
                try self.emitExpression(b.right);
                try self.writer.appendSlice("))");
                return;
            }
            if (b.op == .eq_eq or b.op == .bang_eq) {
                const left_is_null = (b.left.data == .null_literal);
                const right_is_null = (b.right.data == .null_literal);

                if (left_is_null or right_is_null) {
                    const non_null_side = if (left_is_null) b.right else b.left;
                    if (non_null_side.resolved_type) |rt| {
                        if (!ts.isNullable(rt)) {
                            if (b.op == .eq_eq) {
                                try self.writer.appendSlice("0");
                            } else {
                                try self.writer.appendSlice("1");
                            }
                            return;
                        }
                    }
                }

                const left_base = if (b.left.resolved_type) |rt| ts.extractBaseType(rt) else null;
                const right_base = if (b.right.resolved_type) |rt| ts.extractBaseType(rt) else null;

                const left_is_union = (left_base != null and left_base.?.* == .Union);
                const right_is_union = (right_base != null and right_base.?.* == .Union);

                if (left_is_union or right_is_union) {
                    const union_side = if (left_is_union) b.left else b.right;
                    const other_side = if (left_is_union) b.right else b.left;
                    const other_t = if (other_side.resolved_type) |rt| ts.extractBaseType(rt) else null;

                    if (other_t) |ot| {
                        if (ot.* == .Int or ot.* == .Bool) {
                            if (b.op == .bang_eq) try self.writer.appendSlice("!(");
                            try self.writer.appendSlice("((int)(intptr_t)(");
                            try self.emitExpression(union_side);
                            try self.writer.appendSlice(") == (");
                            try self.emitExpression(other_side);
                            try self.writer.appendSlice("))");
                            if (b.op == .bang_eq) try self.writer.appendSlice(")");
                            return;
                        } else if (ot.* == .String or (ot.* == .Custom and (std.mem.eql(u8, ot.Custom, "core_String") or std.mem.eql(u8, ot.Custom, "String")))) {
                            if (b.op == .bang_eq) try self.writer.appendSlice("!(");
                            try self.writer.appendSlice("(");
                            try self.writer.appendSlice("((core_String*)(");
                            try self.emitExpression(union_side);
                            try self.writer.appendSlice(")) == (");
                            try self.emitExpression(other_side);
                            try self.writer.appendSlice(") || (((void*)(");
                            try self.emitExpression(union_side);
                            try self.writer.appendSlice(")) != 0 && (");
                            try self.emitExpression(other_side);
                            try self.writer.appendSlice(") != 0 && core_String_equals((core_String*)(");
                            try self.emitExpression(union_side);
                            try self.writer.appendSlice("), ");
                            try self.emitExpression(other_side);
                            try self.writer.appendSlice(")))");
                            if (b.op == .bang_eq) try self.writer.appendSlice(")");
                            return;
                        }
                    }
                }

                var string_or_custom_type: ?*const ts.EiwaType = null;
                if (b.left.resolved_type) |rt| {
                    const base = ts.extractBaseType(rt);
                    if (base.* == .String or base.* == .Custom) {
                        string_or_custom_type = base;
                    }
                }
                if (string_or_custom_type == null) {
                    if (b.right.resolved_type) |rt| {
                        const base = ts.extractBaseType(rt);
                        if (base.* == .String or base.* == .Custom) {
                            string_or_custom_type = base;
                        }
                    }
                }

                var has_equals = false;
                var class_name: []const u8 = "";
                if (string_or_custom_type) |base| {
                    if (base.* == .String) {
                        has_equals = true;
                        class_name = "core_String";
                    } else if (base.* == .Custom) {
                        class_name = base.Custom;
                        if (self.classes_ast) |ca| {
                            if (ca.get(class_name)) |class_node| {
                                const cd = class_node.data.type_decl;
                                for (cd.methods) |method| {
                                    if (method.data == .fun_decl and std.mem.eql(u8, method.data.fun_decl.name, "equals")) {
                                        has_equals = true;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }

                if (has_equals) {
                    if (b.op == .bang_eq) {
                        try self.writer.appendSlice("!(");
                    } else {
                        try self.writer.appendSlice("(");
                    }
                    
                    try self.writer.appendSlice("(");
                    try self.emitExpression(b.left);
                    try self.writer.appendSlice(") == (");
                    try self.emitExpression(b.right);
                    try self.writer.appendSlice(") || ((");
                    try self.emitExpression(b.left);
                    try self.writer.appendSlice(") != 0 && (");
                    try self.emitExpression(b.right);
                    try self.writer.appendSlice(") != 0 && ");
                    
                    try self.writer.writer().print("{s}_equals(", .{class_name});
                    try self.emitExpression(b.left);
                    try self.writer.appendSlice(", ");
                    try self.emitExpression(b.right);
                    try self.writer.appendSlice(")))");
                    return;
                }
            }
            if (b.op == .plus and std.meta.activeTag(b.left.resolved_type.?.*) == .Pointer) {
                const c_type = try core.getCTypeStr(self.allocator, b.left.resolved_type.?);
                try self.writer.writer().print("((({s})(", .{c_type});
                try self.emitExpression(b.left);
                try self.writer.appendSlice(")) + ");
                try self.emitExpression(b.right);
                try self.writer.appendSlice(")");
                return;
            }
            if (b.op == .minus and std.meta.activeTag(b.left.resolved_type.?.*) == .Pointer and std.meta.activeTag(b.right.resolved_type.?.*) == .Pointer) {
                const c_type = try core.getCTypeStr(self.allocator, b.left.resolved_type.?);
                try self.writer.writer().print("((({s})(", .{c_type});
                try self.emitExpression(b.left);
                try self.writer.writer().print(")) - (({s})(", .{c_type});
                try self.emitExpression(b.right);
                try self.writer.appendSlice(")))");
                return;
            }

            try self.writer.appendSlice("(");
            try self.emitExpression(b.left);
            const op_str = switch (b.op) {
                .plus => " + ",
                .minus => " - ",
                .star => " * ",
                .slash => " / ",
                .eq_eq => " == ",
                .bang_eq => " != ",
                .less => " < ",
                .greater => " > ",
                .less_eq => " <= ",
                .greater_eq => " >= ",
                .and_and => " && ",
                .or_or => " || ",
                else => return error.UnsupportedOperator,
            };
            try self.writer.appendSlice(op_str);
            try self.emitExpression(b.right);
            try self.writer.appendSlice(")");
        },
        .as_expr => |a| {
            const dest_t = a.type_ref.resolved_type.?;
            const t_str = try self.cType(dest_t);
            if (dest_t.* == .Int or dest_t.* == .Bool) {
                try self.writer.writer().print("(({s})(intptr_t)(", .{t_str});
                try self.emitExpression(a.value);
                try self.writer.appendSlice("))");
            } else {
                try self.writer.writer().print("(({s})", .{t_str});
                try self.emitExpression(a.value);
                try self.writer.appendSlice(")");
            }
        },
        .is_expr => |i| {
            const target_t = i.type_ref.resolved_type.?;
            if (target_t.* == .Void) {
                try self.writer.appendSlice(if (i.is_not) "0" else "1");
                return;
            }
            const target_c_name = switch (target_t.*) {
                .Custom => |cname| cname,
                .Int => "core_Int",
                .Bool => "core_Bool",
                .String => "core_String",
                .Null => "core_Null",
                .Void => "core_Void",
                else => "unknown",
            };
            if (i.is_not) {
                try self.writer.appendSlice("!(");
            }
            if (std.mem.eql(u8, target_c_name, "core_Null")) {
                try self.writer.appendSlice("((");
                try self.emitExpression(i.value);
                try self.writer.appendSlice(") == 0)");
            } else if (std.mem.eql(u8, target_c_name, "core_Int")) {
                try self.writer.appendSlice("((uintptr_t)(");
                try self.emitExpression(i.value);
                try self.writer.appendSlice(") < 0x10000)");
            } else if (std.mem.eql(u8, target_c_name, "core_Bool")) {
                try self.writer.appendSlice("((uintptr_t)(");
                try self.emitExpression(i.value);
                try self.writer.appendSlice(") <= 1)");
            } else {
                const contract_c_name = if (std.mem.endsWith(u8, target_c_name, "Echoable")) "core_Stringable" else target_c_name;
                if (self.isContract(contract_c_name)) {
                    try self.writer.appendSlice("((uintptr_t)(");
                    try self.emitExpression(i.value);
                    try self.writer.writer().print(") != 0 && ((uintptr_t)(", .{});
                    try self.emitExpression(i.value);
                    try self.writer.writer().print(") < 0x10000 || eiwa_implements(*(const EiwaTypeDescriptor**) (", .{});
                    try self.emitExpression(i.value);
                    try self.writer.writer().print("), &{s}_contract)))", .{contract_c_name});
                } else {
                    try self.writer.appendSlice("((uintptr_t)(");
                    try self.emitExpression(i.value);
                    try self.writer.appendSlice(") >= 0x10000 && *(const EiwaTypeDescriptor**)(");
                    try self.emitExpression(i.value);
                    try self.writer.writer().print(") == &{s}_descriptor)", .{target_c_name});
                }
            }
            if (i.is_not) {
                try self.writer.appendSlice(")");
            }
        },
        .is_type_cond => {
            return error.UnsupportedExpression;
        },
        .when_expr => |w| {
            const res_t = node.resolved_type.?;
            const is_void = res_t.* == .Void;

            try self.writer.appendSlice("({ ");

            const res_var_name = try std.fmt.allocPrint(self.allocator, "_when_res_{}_{}", .{ node.line, node.column });
            if (!is_void) {
                const res_c_type = try self.cType(res_t);
                try self.writer.writer().print("{s} {s}; ", .{ res_c_type, res_var_name });
            }

            var subj_var_name: []const u8 = "";
            if (w.subject) |subj| {
                const subj_t = subj.resolved_type.?;
                const subj_c_type = try self.cType(subj_t);
                subj_var_name = try std.fmt.allocPrint(self.allocator, "_when_subj_{}_{}", .{ node.line, node.column });
                try self.writer.writer().print("{s} {s} = ", .{ subj_c_type, subj_var_name });
                try self.emitExpression(subj);
                try self.writer.appendSlice("; ");
            }

            for (w.cases, 0..) |case, case_idx| {
                if (case_idx > 0) {
                    try self.writer.appendSlice("else ");
                }

                if (case.is_else) {
                    try self.writer.appendSlice("{ ");
                    try emitWhenCaseBody(self, case.body, is_void, res_var_name);
                    try self.writer.appendSlice("} ");
                } else {
                    try self.writer.appendSlice("if (");
                    for (case.conds, 0..) |cond, c_idx| {
                        if (c_idx > 0) {
                            try self.writer.appendSlice(" || ");
                        }

                        if (w.subject) |subj| {
                            const subj_t = subj.resolved_type.?;
                            if (cond.data == .is_type_cond) {
                                const type_cond = cond.data.is_type_cond;
                                const target_t = type_cond.type_ref.resolved_type.?;
                                const target_c_name = switch (target_t.*) {
                                    .Custom => |cname| cname,
                                    .Int => "core_Int",
                                    .Bool => "core_Bool",
                                    .String => "core_String",
                                    .Null => "core_Null",
                                    else => "unknown",
                                };

                                if (type_cond.is_not) {
                                    try self.writer.appendSlice("!(");
                                }
                                if (std.mem.eql(u8, target_c_name, "core_Null")) {
                                    try self.writer.writer().print("({s} == 0)", .{subj_var_name});
                                } else if (std.mem.eql(u8, target_c_name, "core_Int")) {
                                    try self.writer.writer().print("((uintptr_t)({s}) < 0x10000)", .{subj_var_name});
                                } else if (std.mem.eql(u8, target_c_name, "core_Bool")) {
                                    try self.writer.writer().print("((uintptr_t)({s}) <= 1)", .{subj_var_name});
                                } else if (self.isContract(target_c_name)) {
                                    try self.writer.writer().print("((uintptr_t)({s}) < 0x10000 || eiwa_implements(*(const EiwaTypeDescriptor**)({s}), &{s}_contract))", .{ subj_var_name, subj_var_name, target_c_name });
                                } else {
                                    try self.writer.writer().print("((uintptr_t)({s}) >= 0x10000 && *(const EiwaTypeDescriptor**)({s}) == &{s}_descriptor)", .{ subj_var_name, subj_var_name, target_c_name });
                                }
                                if (type_cond.is_not) {
                                    try self.writer.appendSlice(")");
                                }
                            } else {
                                // Value check: subj == cond
                                const is_str = (subj_t.* == .String or (subj_t.* == .Custom and std.mem.eql(u8, subj_t.Custom, "core_String")));
                                if (is_str) {
                                    try self.writer.writer().print("core_String_equals({s}, ", .{ subj_var_name });
                                    try self.emitExpression(cond);
                                    try self.writer.appendSlice(")");
                                } else {
                                    try self.writer.writer().print("{s} == ", .{ subj_var_name });
                                    try self.emitExpression(cond);
                                }
                            }
                        } else {
                            // Subjectless when: cond is boolean expr
                            try self.emitExpression(cond);
                        }
                    }
                    try self.writer.appendSlice(") { ");
                    try emitWhenCaseBody(self, case.body, is_void, res_var_name);
                    try self.writer.appendSlice("} ");
                }
            }

            if (!is_void) {
                try self.writer.writer().print("{s}; ", .{ res_var_name });
            }
            try self.writer.appendSlice("})");
        },
        .lambda_expr => |l| {
            const line = node.line;
            const col = node.column;
            
            const lambda_key = try std.fmt.allocPrint(self.allocator, "{}_{}_{s}", .{ line, col, self.current_fn_c_name });
            const is_new_lambda = !self.emitted_lambdas.contains(lambda_key);
            if (is_new_lambda) {
                try self.emitted_lambdas.put(lambda_key, {});
            }
            
            var param_names = ArrayList([]const u8).init(self.allocator);
            var param_types = ArrayList(*const ts.EiwaType).init(self.allocator);
            
            var locals = std.StringHashMap(void).init(self.allocator);
            defer locals.deinit();
            
            if (node.resolved_type) |rt| {
                const rt_base = ts.extractBaseType(rt);
                if (rt_base.* == .Function) {
                    const f = rt_base.Function;
                    if (f.receiver) |rec| {
                        try param_names.append("this");
                        try param_types.append(rec);
                        try locals.put("this", {});
                    }
                }
            }
            
            if (l.params.len > 0) {
                if (node.resolved_type) |rt| {
                    const rt_base = ts.extractBaseType(rt);
                    if (rt_base.* == .Function) {
                        const f = rt_base.Function;
                        for (l.params, 0..) |p, i| {
                            try param_names.append(try core.cIdent(self.allocator, p.name));
                            try param_types.append(f.params[i]);
                            try locals.put(p.name, {});
                        }
                    }
                }
            } else if (node.resolved_type) |rt| {
                const rt_base = ts.extractBaseType(rt);
                if (rt_base.* == .Function) {
                    const f = rt_base.Function;
                    if (f.params.len == 1) {
                        try param_names.append("it");
                        try param_types.append(f.params[0]);
                        try locals.put("it", {});
                    }
                }
            }
            
            for (l.body) |stmt| {
                try collectDeclaredLocals(stmt, &locals);
            }
            
            var captures = ArrayList(CaptureInfo).init(self.allocator);
            defer captures.deinit();
            for (l.body) |stmt| {
                try self.collectCaptures(stmt, &locals, &captures);
            }
            
            const env_struct_name = try std.fmt.allocPrint(self.allocator, "_env_{}_{}_{s}", .{ line, col, self.current_fn_c_name });
            const lambda_fn_name = try std.fmt.allocPrint(self.allocator, "_lambda_{}_{}_{s}", .{ line, col, self.current_fn_c_name });
            
            if (is_new_lambda) {
                if (captures.items.len > 0) {
                    var hw = self.header_writer.writer();
                    try hw.print("typedef struct {{\n", .{});
                    for (captures.items) |cap| {
                        const cap_c_name = try core.cIdent(self.allocator, cap.name);
                        if (cap.is_boxed) {
                            const box_type = try getBoxTypeName(self.allocator, cap.c_type);
                            try hw.print("    {s}* {s};\n", .{box_type, cap_c_name});
                        } else {
                            try hw.print("    {s} {s};\n", .{cap.c_type, cap_c_name});
                        }
                    }
                    try hw.print("}} {s};\n\n", .{env_struct_name});
                }
            }

            var return_type_str: []const u8 = "void";
            if (node.resolved_type) |rt| {
                const rt_base = ts.extractBaseType(rt);
                if (rt_base.* == .Function) {
                    return_type_str = try self.cType(rt_base.Function.return_type);
                }
            }
            
            // Create a temporary body writer for this lambda
            var body_writer = ArrayList(u8).init(self.allocator);
            defer body_writer.deinit();
            
            const old_writer = self.writer;
            self.writer = body_writer;
            
            for (l.body, 0..) |stmt, i| {
                if (i == l.body.len - 1 and !std.mem.eql(u8, return_type_str, "void")) {
                    try self.writer.appendSlice("    return ");
                    try self.emitExpression(stmt);
                    try self.writer.appendSlice(";\n");
                } else {
                    try self.emitStatement(stmt);
                }
            }
            
            // Restore self.writer to old_writer
            body_writer = self.writer;
            self.writer = old_writer;
            
            // Emit helper function header and body flatly into header_writer
            if (is_new_lambda) {
                var hw = self.header_writer.writer();
                try hw.print("static inline {s} {s}(void* __env", .{return_type_str, lambda_fn_name});
                for (param_names.items, param_types.items) |p_name, p_type| {
                    const p_c_type = try self.cType(p_type);
                    try hw.print(", {s} {s}", .{p_c_type, p_name});
                }
                try hw.print(") {{\n", .{});
                
                if (captures.items.len > 0) {
                    try hw.print("    {s}* env = ({s}*)__env;\n", .{env_struct_name, env_struct_name});
                    for (captures.items) |cap| {
                        const cap_c_name = try core.cIdent(self.allocator, cap.name);
                        if (cap.is_boxed) {
                            const box_type = try getBoxTypeName(self.allocator, cap.c_type);
                            try hw.print("    {s}* {s} = env->{s};\n", .{box_type, cap_c_name, cap_c_name});
                        } else {
                            try hw.print("    {s} {s} = env->{s};\n", .{cap.c_type, cap_c_name, cap_c_name});
                        }
                    }
                }
                
                try self.header_writer.appendSlice(body_writer.items);
                try self.header_writer.appendSlice("}\n\n");
            }
            
            // Construct the EiwaClosure struct literal
            try self.writer.appendSlice("(EiwaClosure){ ");
            try self.writer.writer().print("(void*){s}, ", .{lambda_fn_name});
            if (captures.items.len > 0) {
                try self.writer.writer().print("({{\n", .{});
                try self.writer.writer().print("        {s}* _tmp_env = GC_MALLOC(sizeof({s}));\n", .{env_struct_name, env_struct_name});
                for (captures.items) |cap| {
                    try self.writer.writer().print("        _tmp_env->{s} = {s};\n", .{ try core.cIdent(self.allocator, cap.name), try core.cIdent(self.allocator, cap.name) });
                }
                try self.writer.writer().print("        _tmp_env;\n", .{});
                try self.writer.writer().print("    }})", .{});
            } else {
                try self.writer.appendSlice("0");
            }
            try self.writer.appendSlice(" }");
        },
        else => return error.UnsupportedExpression,
    }
}

fn emitWhenCaseBody(self: *CTranspiler, body: *ASTNode, is_void: bool, res_var_name: []const u8) anyerror!void {
    if (body.data == .block) {
        const stmts = body.data.block.statements;
        for (stmts, 0..) |stmt, idx| {
            if (idx == stmts.len - 1 and !is_void) {
                try self.writer.appendSlice("    ");
                try self.writer.writer().print("{s} = ", .{ res_var_name });
                try self.emitExpression(stmt);
                try self.writer.appendSlice(";\n");
            } else {
                try self.emitStatement(stmt);
            }
        }
    } else {
        if (!is_void) {
            try self.writer.appendSlice("    ");
            try self.writer.writer().print("{s} = ", .{ res_var_name });
            try self.emitExpression(body);
            try self.writer.appendSlice(";\n");
        } else {
            try self.emitStatement(body);
        }
    }
}

const CaptureInfo = struct {
    name: []const u8,
    c_type: []const u8,
    is_boxed: bool,
};

fn getBoxTypeName(allocator: std.mem.Allocator, c_type: []const u8) ![]const u8 {
    var safe = ArrayList(u8).init(allocator);
    for (c_type) |c| {
        if (c == '*') {
            try safe.appendSlice("Ptr");
        } else if (c == ' ') {
            try safe.appendSlice("_");
        } else {
            try safe.append(c);
        }
    }
    return try std.fmt.allocPrint(allocator, "Box_{s}", .{safe.items});
}

fn collectDeclaredLocals(node: *ASTNode, locals: *std.StringHashMap(void)) anyerror!void {
    switch (node.data) {
        .var_decl => |v| {
            try locals.put(v.name, {});
        },
        .block => |b| {
            for (b.statements) |stmt| {
                try collectDeclaredLocals(stmt, locals);
            }
        },
        .if_expr => |i| {
            try collectDeclaredLocals(i.then_branch, locals);
            if (i.else_branch) |eb| try collectDeclaredLocals(eb, locals);
        },
        .while_stmt => |w| {
            try collectDeclaredLocals(w.body, locals);
        },
        .for_stmt => |f| {
            try locals.put(f.item_name, {});
            try collectDeclaredLocals(f.body, locals);
        },
        .try_stmt => |try_s| {
            try collectDeclaredLocals(try_s.body, locals);
            for (try_s.catches) |c| {
                if (c.var_name) |vn| try locals.put(vn, {});
                try collectDeclaredLocals(c.body, locals);
            }
        },
        .when_expr => |w| {
            for (w.cases) |case| {
                try collectDeclaredLocals(case.body, locals);
            }
        },
        else => {},
    }
}

pub fn collectCaptures(self: *CTranspiler, node: *ASTNode, locals: *const std.StringHashMap(void), captures: *ArrayList(CaptureInfo)) anyerror!void {
    switch (node.data) {
        .identifier => |i| {
            if (locals.contains(i.name)) return;
            if (i.is_class_property) return;
            
            const name = i.resolved_c_name orelse i.name;
            if (self.classes.contains(name) or self.classes.contains(i.name)) return;
            if (self.emitted_functions.contains(name)) return;
            if (self.libs.contains(name)) return;
            
            for (captures.items) |cap| {
                if (std.mem.eql(u8, cap.name, i.name)) return;
            }
            
            if (node.resolved_type) |rt| {
                const c_type = try self.cType(rt);
                try captures.append(.{
                    .name = i.name,
                    .c_type = c_type,
                    .is_boxed = i.is_boxed,
                });
            }
        },
        .call_expr => |c| {
            try self.collectCaptures(c.callee, locals, captures);
            for (c.arguments) |arg| {
                try self.collectCaptures(arg, locals, captures);
            }
        },
        .unary_expr => |u| try self.collectCaptures(u.operand, locals, captures),
        .binary_expr => |b| {
            try self.collectCaptures(b.left, locals, captures);
            try self.collectCaptures(b.right, locals, captures);
        },
        .if_expr => |i| {
            try self.collectCaptures(i.condition, locals, captures);
            try self.collectCaptures(i.then_branch, locals, captures);
            if (i.else_branch) |eb| try self.collectCaptures(eb, locals, captures);
        },
        .index_expr => |idx| {
            try self.collectCaptures(idx.object, locals, captures);
            try self.collectCaptures(idx.index, locals, captures);
        },
        .index_set_expr => |s| {
            try self.collectCaptures(s.object, locals, captures);
            try self.collectCaptures(s.index, locals, captures);
            try self.collectCaptures(s.value, locals, captures);
        },
        .assignment => |a| {
            try self.collectCaptures(a.value, locals, captures);
            if (!locals.contains(a.name)) {
                for (captures.items) |cap| {
                    if (std.mem.eql(u8, cap.name, a.name)) return;
                }
                if (node.resolved_type) |rt| {
                    const c_type = try self.cType(rt);
                    try captures.append(.{
                        .name = a.name,
                        .c_type = c_type,
                        .is_boxed = a.is_boxed,
                    });
                }
            }
        },
        .get_expr => |g| try self.collectCaptures(g.object, locals, captures),
        .set_expr => |s| {
            try self.collectCaptures(s.object, locals, captures);
            try self.collectCaptures(s.value, locals, captures);
        },
        .block => |b| {
            for (b.statements) |stmt| {
                try self.collectCaptures(stmt, locals, captures);
            }
        },
        .while_stmt => |w| {
            try self.collectCaptures(w.condition, locals, captures);
            try self.collectCaptures(w.body, locals, captures);
        },
        .for_stmt => |f| {
            try self.collectCaptures(f.iterable, locals, captures);
            try self.collectCaptures(f.body, locals, captures);
        },
        .return_stmt => |r| {
            if (r.value) |val| try self.collectCaptures(val, locals, captures);
        },
        .throw_stmt => |th| try self.collectCaptures(th.expr, locals, captures),
        .var_decl => |v| {
            if (v.initializer) |init| try self.collectCaptures(init, locals, captures);
        },
        .ternary_expr => |t| {
            try self.collectCaptures(t.condition, locals, captures);
            try self.collectCaptures(t.then_branch, locals, captures);
            if (t.else_branch) |eb| try self.collectCaptures(eb, locals, captures);
        },
        .as_expr => |a| try self.collectCaptures(a.value, locals, captures),
        .named_arg => |na| try self.collectCaptures(na.value, locals, captures),
        .is_expr => |i| try self.collectCaptures(i.value, locals, captures),
        .try_stmt => |try_s| {
            try self.collectCaptures(try_s.body, locals, captures);
            for (try_s.catches) |c| {
                try self.collectCaptures(c.body, locals, captures);
            }
        },
        .when_expr => |w| {
            if (w.subject) |subj| try self.collectCaptures(subj, locals, captures);
            for (w.cases) |case| {
                for (case.conds) |cond| try self.collectCaptures(cond, locals, captures);
                try self.collectCaptures(case.body, locals, captures);
            }
        },
        .lambda_expr => |l| {
            var inner_locals = std.StringHashMap(void).init(self.allocator);
            defer inner_locals.deinit();

            var loc_it = locals.iterator();
            while (loc_it.next()) |entry| {
                try inner_locals.put(entry.key_ptr.*, {});
            }
            for (l.params) |p| {
                try inner_locals.put(p.name, {});
            }
            if (l.params.len == 0) {
                try inner_locals.put("it", {});
            }
            for (l.body) |stmt| {
                try collectDeclaredLocals(stmt, &inner_locals);
            }
            for (l.body) |stmt| {
                try self.collectCaptures(stmt, &inner_locals, captures);
            }
        },
        else => {},
    }
}

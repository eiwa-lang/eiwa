const std = @import("std");
const compat = @import("../../core/compat.zig");
const ArrayList = compat.ArrayList;
const core = @import("core.zig");
const ts = @import("../../core/type_system.zig");

const ASTNode = core.ASTNode;
const CTranspiler = core.CTranspiler;

pub fn emitTypeDecl(self: *CTranspiler, node: *ASTNode) !void {
    const type_decl = node.data.type_decl;
    if (type_decl.generic_params.len > 0) return;
    const actual_name = type_decl.resolved_c_name orelse type_decl.name;
    if (std.mem.endsWith(u8, actual_name, "_K") or std.mem.endsWith(u8, actual_name, "_V")) return;
    if (self.classes.contains(actual_name)) return;
    try self.classes.put(actual_name, {});

    var primitive_type: ?[]const u8 = null;
    for (type_decl.annotations) |ann| {
        if (std.mem.eql(u8, ann.name, "Primitive") and ann.arguments.len > 0) {
            primitive_type = ann.arguments[0];
            break;
        }
    }

    if (primitive_type == null) {
        // Pre-emit any array structs needed for properties
        for (type_decl.primary_constructor) |prop| {
            if (prop.resolved_type) |rt| {
                if (ts.extractBaseType(rt).* == .Array) try self.emitArrayStruct(ts.extractBaseType(rt).Array);
            }
        }

        // Pre-emit any Custom struct dependencies (e.g. MutableList depends on List)
        if (self.classes_ast) |ca| {
            for (type_decl.primary_constructor) |prop| {
                if (prop.resolved_type) |rt| {
                    const base = ts.extractBaseType(rt);
                    if (base.* == .Custom) {
                        if (ca.get(base.Custom)) |dep_node| {
                            if (dep_node.data == .type_decl and dep_node.data.type_decl.generic_params.len == 0) {
                                try self.emitTypeDecl(dep_node);
                            }
                        }
                    }
                }
            }
        }

        // Emit Struct
        try self.header_writer.writer().print("typedef struct {s} {s};\n", .{ actual_name, actual_name });
        try self.header_writer.writer().print("extern const EiwaTypeDescriptor {s}_descriptor;\n", .{actual_name});
        try self.header_writer.writer().print("struct {s} {{\n", .{actual_name});
        try self.header_writer.writer().print("    const EiwaTypeDescriptor* _desc;\n", .{});

        for (type_decl.primary_constructor) |prop| {
            if (!prop.is_property) continue;
            var t_str: []const u8 = "void*";
            if (prop.resolved_type) |rt| {
                t_str = try self.cType(rt);
            }
            try self.header_writer.writer().print("    {s} {s};\n", .{ t_str, prop.name });
        }
        try self.header_writer.writer().print("}};\n\n", .{});

        // Emit Allocator/Constructor Declaration
        try self.header_writer.writer().print("{s}* {s}_new(", .{ actual_name, actual_name });
        for (type_decl.primary_constructor, 0..) |prop, i| {
            if (i > 0) try self.header_writer.appendSlice(", ");
            var t_str: []const u8 = "void*";
            if (prop.resolved_type) |rt| {
                t_str = try self.cType(rt);
            }
            try self.header_writer.writer().print("{s} {s}", .{ t_str, prop.name });
        }
        try self.header_writer.appendSlice(");\n");
        try self.header_writer.writer().print("{s}* {s}_constructor({s}* this);\n", .{ actual_name, actual_name, actual_name });

        // Emit vtables for implemented contracts
        var valid_contract_count: usize = 0;
        for (type_decl.contracts) |contract_src| {
            const contract_c_name = if (self.alias_map) |am| (am.get(contract_src) orelse contract_src) else contract_src;
            if (!self.isContract(contract_c_name) and !self.isContract(contract_src)) continue;
            const contract_node = if (self.contracts_ast) |ca| ca.get(contract_c_name) orelse continue else continue;

            valid_contract_count += 1;
            try self.header_writer.writer().print("extern const EiwaContractDescriptor {s}_contract;\n", .{contract_c_name});

            try self.writer.writer().print("void* {s}_{s}_vtable[] = {{\n", .{ actual_name, contract_c_name });
            for (contract_node.data.contract_decl.methods) |cm| {
                if (cm.data != .fun_decl) continue;
                const cm_name = cm.data.fun_decl.name;
                // Find the implementing method in the type
                var impl_c_name: ?[]const u8 = null;
                for (type_decl.methods) |m| {
                    if (m.data == .fun_decl and std.mem.eql(u8, m.data.fun_decl.name, cm_name)) {
                        impl_c_name = m.data.fun_decl.resolved_c_name orelse try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ actual_name, cm_name });
                        break;
                    }
                }
                if (impl_c_name) |icn| {
                    try self.writer.writer().print("    (void*)&{s},\n", .{icn});
                } else {
                    try self.writer.appendSlice("    0,\n");
                }
            }
            try self.writer.appendSlice("};\n");
        }

        // Emit the impl table + static descriptor definition
        if (valid_contract_count > 0) {
            try self.writer.writer().print("const EiwaContractImpl {s}_impls[] = {{\n", .{actual_name});
            for (type_decl.contracts) |contract_src| {
                const contract_c_name = if (self.alias_map) |am| (am.get(contract_src) orelse contract_src) else contract_src;
                if (!self.isContract(contract_c_name) and !self.isContract(contract_src)) continue;
                try self.writer.writer().print("    {{ &{s}_contract, {s}_{s}_vtable }},\n", .{ contract_c_name, actual_name, contract_c_name });
            }
            try self.writer.appendSlice("};\n");
            try self.writer.writer().print("const EiwaTypeDescriptor {s}_descriptor = {{ \"{s}\", {s}_impls, {d} }};\n\n", .{ actual_name, type_decl.name, actual_name, valid_contract_count });
        } else {
            try self.writer.writer().print("const EiwaTypeDescriptor {s}_descriptor = {{ \"{s}\", 0, 0 }};\n\n", .{ actual_name, type_decl.name });
        }

        // Emit Allocator/Constructor Implementation
        try self.writer.writer().print("{s}* {s}_new(", .{ actual_name, actual_name });
        for (type_decl.primary_constructor, 0..) |prop, i| {
            if (i > 0) try self.writer.appendSlice(", ");
            var t_str: []const u8 = "void*";
            if (prop.resolved_type) |rt| {
                t_str = try self.cType(rt);
                if (ts.extractBaseType(rt).* == .Array) try self.emitArrayStruct(ts.extractBaseType(rt).Array);
            }
            try self.writer.writer().print("{s} {s}", .{ t_str, prop.name });
        }
        try self.writer.writer().print(") {{\n", .{});
        try self.writer.writer().print("    {s}* instance = ({s}*)GC_MALLOC(sizeof({s}));\n", .{ actual_name, actual_name, actual_name });
        try self.writer.writer().print("    instance->_desc = &{s}_descriptor;\n", .{actual_name});

        for (type_decl.primary_constructor) |prop| {
            if (!prop.is_property) continue;
            try self.writer.writer().print("    instance->{s} = {s};\n", .{ prop.name, prop.name });
        }
        try self.writer.appendSlice("    return instance;\n}\n\n");
    }

    for (type_decl.methods) |method| {
        if (method.data.fun_decl.generic_params.len > 0) continue;
        try self.emitMethodDecl(actual_name, method, primitive_type);
    }
}

pub fn emitContractDecl(self: *CTranspiler, node: *ASTNode) !void {
    const contract_decl = node.data.contract_decl;
    const actual_name = contract_decl.resolved_c_name orelse contract_decl.name;
    if (self.classes.contains(actual_name)) return;
    try self.classes.put(actual_name, {});

    try self.header_writer.writer().print("extern const EiwaContractDescriptor {s}_contract;\n", .{actual_name});
    try self.writer.writer().print("const EiwaContractDescriptor {s}_contract = {{ \"{s}\" }};\n\n", .{ actual_name, contract_decl.name });
}

pub fn emitSkillDecl(self: *CTranspiler, node: *ASTNode) !void {
    _ = self;
    _ = node;
    // Skills emit nothing: their methods are cloned into consuming types.
}

pub fn emitMethodDecl(self: *CTranspiler, class_name: []const u8, node: *ASTNode, primitive_type: ?[]const u8) !void {
    const decl = node.data.fun_decl;
    const fn_c_name = decl.resolved_c_name orelse try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ class_name, decl.name });

    // 1. Emit the signature to header_writer
    if (node.resolved_type) |rt| {
        const fun_type = rt.Function;
        const ret_base = ts.extractBaseType(fun_type.return_type);
        // Forward-declare Custom return types that may not be defined yet
        if (ret_base.* == .Custom and !self.classes.contains(ret_base.Custom)) {
            try self.forward_writer.writer().print("typedef struct {s} {s};\n", .{ ret_base.Custom, ret_base.Custom });
        }
        const ret_str = try self.cType(fun_type.return_type);
        try self.header_writer.writer().print("{s} ", .{ret_str});
    } else {
        try self.header_writer.appendSlice("void ");
    }

    if (primitive_type) |pt| {
        try self.header_writer.writer().print("{s}({s} this", .{ fn_c_name, pt });
    } else {
        try self.header_writer.writer().print("{s}({s}* this", .{ fn_c_name, class_name });
    }

    if (node.resolved_type) |rt| {
        const fun_type = rt.Function;
        for (decl.params, 0..) |p, i| {
            try self.header_writer.appendSlice(", ");
            const param_t_str = try self.cType(fun_type.params[i]);
            try self.header_writer.writer().print("{s} {s}", .{ param_t_str, p.name });
        }
    }
    try self.header_writer.appendSlice(");\n");

    // 2. Emit the implementation to writer
    if (node.resolved_type) |rt| {
        const fun_type = rt.Function;
        const ret_str = try self.cType(fun_type.return_type);
        if (ts.extractBaseType(fun_type.return_type).* == .Array) try self.emitArrayStruct(ts.extractBaseType(fun_type.return_type).Array);
        try self.writer.writer().print("{s} ", .{ret_str});
    } else {
        try self.writer.appendSlice("void ");
    }

    if (primitive_type) |pt| {
        try self.writer.writer().print("{s}({s} this", .{ fn_c_name, pt });
    } else {
        try self.writer.writer().print("{s}({s}* this", .{ fn_c_name, class_name });
    }

    if (node.resolved_type) |rt| {
        const fun_type = rt.Function;
        for (decl.params, 0..) |p, i| {
            try self.writer.appendSlice(", ");
            const param_t_str = try self.cType(fun_type.params[i]);
            if (ts.extractBaseType(fun_type.params[i]).* == .Array) try self.emitArrayStruct(ts.extractBaseType(fun_type.params[i]).Array);
            try self.writer.writer().print("{s} {s}", .{ param_t_str, p.name });
        }
    }
    try self.writer.appendSlice(") {\n");

    const old_fn_c_name = self.current_fn_c_name;
    self.current_fn_c_name = fn_c_name;
    defer self.current_fn_c_name = old_fn_c_name;

    // Emit #line directive so clang reports errors with the original .ei source location
    try self.writer.writer().print("#line {d} \"{s}\"\n", .{ node.line, self.source_file });

    if (decl.is_expr_body) {
        try self.writer.appendSlice("    return ");
        try self.emitExpression(decl.body);
        try self.writer.appendSlice(";\n");
    } else {
        switch (decl.body.data) {
            .block => |b| {
                for (b.statements) |stmt| {
                    try self.emitStatement(stmt);
                }
            },
            else => unreachable,
        }
    }
    try self.writer.appendSlice("}\n\n");
}

pub fn emitFunDecl(self: *CTranspiler, node: *ASTNode) !void {
    const decl = node.data.fun_decl;
    if (decl.generic_params.len > 0) return; // Skip generic functions
    const is_main = std.mem.eql(u8, decl.name, "main");

    if (is_main and self.is_test_mode) {
        return; // Skip user-defined main in test mode
    }

    const actual_name = decl.resolved_c_name orelse decl.name;
    const func_name = if (is_main) "eiwa_main" else actual_name;

    if (self.emitted_functions.contains(func_name)) return;
    try self.emitted_functions.put(func_name, {});

    var sig = ArrayList(u8).init(self.allocator);
    if (is_main) {
        try sig.writer().print("int ", .{});
    } else if (node.resolved_type) |rt| {
        const fun_type = rt.Function;
        const ret_str = try self.cType(fun_type.return_type);
        if (ts.extractBaseType(fun_type.return_type).* == .Array) try self.emitArrayStruct(ts.extractBaseType(fun_type.return_type).Array);
        try sig.writer().print("{s} ", .{ret_str});
    } else {
        try sig.writer().print("void ", .{});
    }

    try sig.writer().print("{s}(", .{func_name});
    if (is_main) {
        // main has no params or argc/argv if needed later
    } else if (node.resolved_type) |rt| {
        const fun_type = rt.Function;
        var outer_params = std.StringHashMap(void).init(self.allocator);
        defer outer_params.deinit();
        for (decl.params, 0..) |p, i| {
            if (i > 0) try sig.writer().print(", ", .{});
            const param_t_str = try self.cType(fun_type.params[i]);
            if (ts.extractBaseType(fun_type.params[i]).* == .Array) try self.emitArrayStruct(ts.extractBaseType(fun_type.params[i]).Array);
            try sig.writer().print("{s} {s}", .{ param_t_str, p.name });
            try outer_params.put(p.name, {});
        }
        try self.pushOuterScope(outer_params);
        defer self.popOuterScope();
    }
    try sig.writer().print(")", .{});

    try self.header_writer.writer().print("{s};\n", .{sig.items});
    try self.writer.writer().print("{s} {{\n", .{sig.items});

    const old_fn_c_name = self.current_fn_c_name;
    self.current_fn_c_name = func_name;
    defer self.current_fn_c_name = old_fn_c_name;

    // Emit #line directive so clang reports errors with the original .ei source location
    try self.writer.writer().print("#line {d} \"{s}\"\n", .{ node.line, self.source_file });

    if (decl.is_expr_body) {
        try self.writer.appendSlice("    return ");
        try self.emitExpression(decl.body);
        try self.writer.appendSlice(";\n");
    } else {
        switch (decl.body.data) {
            .block => |b| {
                for (b.statements) |stmt| {
                    try self.emitStatement(stmt);
                }
            },
            else => unreachable,
        }
    }
    if (is_main) {
        try self.writer.appendSlice("    return 0;\n");
    }
    try self.writer.appendSlice("}\n\n");

    if (is_main) {
        try self.writer.appendSlice("int main(int argc, char** argv) {\n    GC_init();\n    (void)argc;\n    (void)argv;\n");
        for (self.static_initializers.items) |si| {
            try self.writer.writer().print("    {s} = ", .{si.name});
            try self.emitExpression(si.init);
            try self.writer.appendSlice(";\n");
        }
        try self.writer.appendSlice("    return eiwa_main();\n}\n\n");
    }
}

pub fn emitTestDecl(self: *CTranspiler, node: *ASTNode) !void {
    const decl = node.data.test_decl;

    try self.test_names.append(decl.name);
    const test_id = self.test_count;
    self.test_count += 1;

    try self.writer.writer().print("void eiwa_test_{d}() {{\n", .{test_id});

    const old_fn_c_name = self.current_fn_c_name;
    self.current_fn_c_name = try std.fmt.allocPrint(self.allocator, "eiwa_test_{d}", .{test_id});
    defer self.current_fn_c_name = old_fn_c_name;
    switch (decl.body.data) {
        .block => |b| {
            for (b.statements) |stmt| {
                try self.emitStatement(stmt);
            }
        },
        else => unreachable,
    }
    try self.writer.appendSlice("}\n\n");
}

pub fn emitLibDecl(self: *CTranspiler, node: *ASTNode) !void {
    const l = node.data.lib_decl;
    if (self.libs.contains(l.name)) return;
    try self.libs.put(l.name, {});

    for (l.annotations) |ann| {
        if (std.mem.eql(u8, ann.name, "Header")) {
            for (ann.arguments) |arg| {
                if (arg.len > 0 and arg[0] == '<' and arg[arg.len - 1] == '>') {
                    try self.writer.writer().print("#include {s}\n", .{arg});
                } else {
                    try self.writer.writer().print("#include \"{s}\"\n", .{arg});
                }
            }
        } else if (std.mem.eql(u8, ann.name, "Link")) {
            for (ann.arguments) |arg| {
                try self.link_libraries.put(arg, {});
            }
        }
    }
    try self.writer.appendSlice("\n");
}

pub fn emitObjectDecl(self: *CTranspiler, node: *ASTNode) anyerror!void {
    const obj = node.data.object_decl;
    for (obj.members) |member| {
        if (member.data == .fun_decl) {
            try self.emitFunDecl(member);
        } else if (member.data == .var_decl) {
            const v = member.data.var_decl;
            const var_name = v.resolved_c_name orelse v.name;
            if (self.emitted_variables.contains(var_name)) continue;
            try self.emitted_variables.put(var_name, {});

            var type_str: []const u8 = "int";
            if (member.resolved_type) |rt| {
                type_str = try self.cType(rt);
            }
            // Declarations in header
            try self.header_writer.writer().print("extern {s} {s};\n", .{ type_str, var_name });

            // Definitions in writer initialized to zero / default
            try self.writer.writer().print("{s} {s} = 0;\n", .{ type_str, var_name });

            // Queue static initializer
            if (v.initializer) |init_node| {
                try self.static_initializers.append(.{ .name = var_name, .init = init_node });
            }
        }
    }
}

pub fn emitEnumDecl(self: *CTranspiler, node: *ASTNode) !void {
    const ed = node.data.enum_decl;
    const actual_name = ed.resolved_c_name orelse ed.name;
    if (self.classes.contains(actual_name)) return;
    try self.classes.put(actual_name, {});

    const hw = self.header_writer.writer();
    const w = self.writer.writer();

    // Struct & Type Descriptor in Header
    try hw.print("typedef struct {s} {s};\n", .{ actual_name, actual_name });
    try hw.print("extern const EiwaTypeDescriptor {s}_descriptor;\n", .{actual_name});
    try hw.print("struct {s} {{\n", .{actual_name});
    try hw.print("    const EiwaTypeDescriptor* _desc;\n", .{});
    try hw.print("    int ordinal;\n", .{});
    try hw.print("    core_String* name;\n", .{});
    try hw.print("}};\n\n", .{});

    // Method & Variant Getter Declarations in Header
    try hw.print("core_String* {s}_toString({s}* self);\n", .{ actual_name, actual_name });
    try hw.print("int {s}_hashCode({s}* self);\n", .{ actual_name, actual_name });
    try hw.print("bool {s}_equals({s}* self, void* other);\n", .{ actual_name, actual_name });
    for (ed.variants) |variant| {
        try hw.print("{s}* {s}_{s}_get(void);\n", .{ actual_name, actual_name, variant.name });
        try hw.print("#define {s}_{s} ({s}_{s}_get())\n", .{ actual_name, variant.name, actual_name, variant.name });
    }
    try self.header_writer.appendSlice("\n");

    // C File: Method Implementations
    try w.print("core_String* {s}_toString({s}* self) {{\n", .{ actual_name, actual_name });
    try w.print("    if (!self) return core_String_new(\"null\", 4);\n", .{});
    try w.print("    return self->name;\n", .{});
    try w.print("}}\n\n", .{});

    try w.print("int {s}_hashCode({s}* self) {{\n", .{ actual_name, actual_name });
    try w.print("    if (!self) return 0;\n", .{});
    try w.print("    return self->ordinal;\n", .{});
    try w.print("}}\n\n", .{});

    try w.print("bool {s}_equals({s}* self, void* other) {{\n", .{ actual_name, actual_name });
    try w.print("    if (!self || !other) return self == other;\n", .{});
    try w.print("    {s}* o = ({s}*)other;\n", .{ actual_name, actual_name });
    try w.print("    return self->ordinal == o->ordinal;\n", .{});
    try w.print("}}\n\n", .{});

    // C File: Contract vtables & Descriptor
    try w.print("void* {s}_Stringable_vtable[] = {{ (void*)&{s}_toString }};\n", .{ actual_name, actual_name });
    try w.print("void* {s}_Hashable_vtable[] = {{ (void*)&{s}_hashCode }};\n", .{ actual_name, actual_name });
    try w.print("void* {s}_Equatable_vtable[] = {{ (void*)&{s}_equals }};\n", .{ actual_name, actual_name });

    try w.print("const EiwaContractImpl {s}_contract_impls[] = {{\n", .{actual_name});
    try w.print("    {{ &core_Stringable_contract, {s}_Stringable_vtable }},\n", .{actual_name});
    try w.print("    {{ &core_Hashable_contract, {s}_Hashable_vtable }},\n", .{actual_name});
    try w.print("    {{ &core_Equatable_contract, {s}_Equatable_vtable }},\n", .{actual_name});
    try w.print("}};\n\n", .{});

    try w.print("const EiwaTypeDescriptor {s}_descriptor = {{\n", .{actual_name});
    try w.print("    .name = \"{s}\",\n", .{actual_name});
    try w.print("    .impls = {s}_contract_impls,\n", .{actual_name});
    try w.print("    .impl_count = 3,\n", .{});
    try w.print("}};\n\n", .{});

    // C File: Variant Storage & Lazy Initializers
    for (ed.variants) |variant| {
        try w.print("static struct {s} {s}_{s}_struct;\n", .{ actual_name, actual_name, variant.name });
    }

    try w.print("static bool {s}_inited = false;\n", .{actual_name});
    try w.print("static void {s}_init() {{\n", .{actual_name});
    try w.print("    if ({s}_inited) return;\n", .{actual_name});
    try w.print("    {s}_inited = true;\n", .{actual_name});
    for (ed.variants) |variant| {
        try w.print("    {s}_{s}_struct._desc = &{s}_descriptor;\n", .{ actual_name, variant.name, actual_name });
        try w.print("    {s}_{s}_struct.ordinal = {d};\n", .{ actual_name, variant.name, variant.ordinal });
        try w.print("    {s}_{s}_struct.name = core_String_new(\"{s}\", {d});\n", .{ actual_name, variant.name, variant.name, variant.name.len });
    }
    try w.print("}}\n\n", .{});

    for (ed.variants) |variant| {
        try w.print("{s}* {s}_{s}_get(void) {{\n", .{ actual_name, actual_name, variant.name });
        try w.print("    {s}_init();\n", .{actual_name});
        try w.print("    return &{s}_{s}_struct;\n", .{ actual_name, variant.name });
        try w.print("}}\n\n", .{});
    }
}

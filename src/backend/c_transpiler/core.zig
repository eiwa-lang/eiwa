const std = @import("std");
const compat = @import("../../core/compat.zig");
const ArrayList = compat.ArrayList;
const ast = @import("../../core/ast.zig");
const tc_mod = @import("../../core/type_checker/core.zig");
const type_system = @import("../../core/type_system.zig");
pub const ASTNode = ast.ASTNode;
pub const TokenType = ast.TokenType;

pub const std_lib_c = @import("std_lib.zig").std_lib_c;
pub const expr_mod = @import("expression.zig");
pub const stmt_mod = @import("statement.zig");
pub const decl_mod = @import("declaration.zig");

const c_reserved_words = std.StaticStringMap(void).initComptime(.{
    .{ "auto" },     .{ "break" },    .{ "case" },     .{ "char" },
    .{ "const" },    .{ "continue" }, .{ "default" },  .{ "do" },
    .{ "double" },   .{ "else" },     .{ "enum" },     .{ "extern" },
    .{ "float" },    .{ "for" },      .{ "goto" },     .{ "if" },
    .{ "inline" },   .{ "int" },      .{ "long" },     .{ "register" },
    .{ "restrict" }, .{ "return" },   .{ "short" },    .{ "signed" },
    .{ "sizeof" },   .{ "static" },   .{ "struct" },   .{ "switch" },
    .{ "typedef" },  .{ "union" },    .{ "unsigned" }, .{ "void" },
    .{ "volatile" }, .{ "while" },    .{ "bool" },     .{ "true" },
    .{ "false" },    .{ "NULL" },
});

pub fn cIdent(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (c_reserved_words.has(name)) {
        return try std.fmt.allocPrint(allocator, "eiwa_{s}", .{name});
    }
    return name;
}

pub fn getCTypeStr(allocator: std.mem.Allocator, t: *const type_system.EiwaType) ![]const u8 {
    switch (t.*) {
        .Int => return "int64_t",
        .Double => return "double",
        .Bool => return "bool",
        .Pointer => |elem| {
            if (elem.* == .Void) return "char*";
            const inner = try getCTypeStr(allocator, elem);
            return try std.fmt.allocPrint(allocator, "{s}*", .{inner});
        },
        .String => return "core_String*",
        .Void => return "void",
        .Custom => |name| {
            if (std.mem.eql(u8, name, "Int") or std.mem.eql(u8, name, "std_core_Int") or std.mem.eql(u8, name, "core_Int")) return "int64_t";
            if (std.mem.eql(u8, name, "Double") or std.mem.eql(u8, name, "std_core_Double") or std.mem.eql(u8, name, "core_Double")) return "double";
            if (std.mem.eql(u8, name, "Bool") or std.mem.eql(u8, name, "std_core_Bool") or std.mem.eql(u8, name, "core_Bool")) return "bool";
            if (std.mem.eql(u8, name, "core_String") or std.mem.eql(u8, name, "String")) return "core_String*";
            if (std.mem.endsWith(u8, name, "Stringable") or std.mem.endsWith(u8, name, "Equatable") or std.mem.endsWith(u8, name, "Hashable") or std.mem.endsWith(u8, name, "Throwable") or std.mem.endsWith(u8, name, "Serializable") or std.mem.endsWith(u8, name, "SerdeValue") or std.mem.endsWith(u8, name, "SerdeList")) {
                return "void*";
            }
            return try std.fmt.allocPrint(allocator, "{s}*", .{name});
        },
        .Array => |elem| {
            const inner = try getCTypeStr(allocator, elem);
            var safe_inner = ArrayList(u8).init(allocator);
            for (inner) |c| {
                if (c == '*') continue;
                if (c == ' ') continue;
                try safe_inner.append(c);
            }
            return try std.fmt.allocPrint(allocator, "EiwaArray_{s}*", .{safe_inner.items});
        },
        .Union => |u| {
            if (u.right.* == .Null) {
                return try getCTypeStr(allocator, u.left);
            } else if (u.left.* == .Null) {
                return try getCTypeStr(allocator, u.right);
            } else {
                return "void*";
            }
        },
        .Function => return "EiwaClosure",
        .GenericInstance => return "void*",
        else => return "void*",
    }
}

pub const CTranspiler = struct {
    allocator: std.mem.Allocator,
    header_writer: ArrayList(u8),
    forward_writer: ArrayList(u8), // for type forward declarations (before header)
    writer: ArrayList(u8),
    classes: std.StringHashMap(void),
    known_constructors: std.StringHashMap(void), // pre-registered, not yet emitted
    libs: std.StringHashMap(void),
    link_libraries: std.StringHashMap(void),
    // Build requirements declared by `lib` annotations (@Source/@Include/@Define),
    // consumed by the CLI when assembling the C compiler invocation.
    c_sources: std.StringHashMap(void),
    c_includes: std.StringHashMap(void),
    c_defines: std.StringHashMap(void),
    emitted_functions: std.StringHashMap(void),
    emitted_variables: std.StringHashMap(void),
    emitted_lambdas: std.StringHashMap(void),
    // Mangled C name of the function currently being emitted; suffixes lambda
    // names so monomorphized instantiations of the same generic function
    // (whose lambda nodes share line/col) emit distinct C symbols.
    current_fn_c_name: []const u8 = "",
    emitted_modules: std.AutoHashMap(*ASTNode, void),
    is_test_mode: bool = false,
    test_names: ArrayList([]const u8),
    test_count: usize = 0,
    classes_ast: ?*std.StringHashMap(*ASTNode) = null,
    objects_ast: ?*std.StringHashMap(*ASTNode) = null,
    enums_ast: ?*std.StringHashMap(*ASTNode) = null,
    contracts_ast: ?*std.StringHashMap(*ASTNode) = null,
    alias_map: ?*std.StringHashMap([]const u8) = null,
    source_file: []const u8 = "<unknown>", // path to the .ei source file being transpiled
    static_initializers: ArrayList(StaticInitializer),
    // Stack of outer scope variables for lambda capture
    outer_scope_vars: ArrayList(std.StringHashMap(void)),

    pub const StaticInitializer = struct {
        name: []const u8,
        init: *ASTNode,
    };

    pub const emitTypeDecl = decl_mod.emitTypeDecl;
    pub const emitContractDecl = decl_mod.emitContractDecl;
    pub const emitSkillDecl = decl_mod.emitSkillDecl;
    pub const emitMethodDecl = decl_mod.emitMethodDecl;
    pub const emitFunDecl = decl_mod.emitFunDecl;
    pub const emitTestDecl = decl_mod.emitTestDecl;
    pub const emitLibDecl = decl_mod.emitLibDecl;
    pub const emitObjectDecl = decl_mod.emitObjectDecl;
    pub const emitEnumDecl = decl_mod.emitEnumDecl;

    pub const emitStatement = stmt_mod.emitStatement;
    pub const emitExpression = expr_mod.emitExpression;
    pub const collectCaptures = expr_mod.collectCaptures;

    /// Contract-aware C type: contract-typed values are erased to `void*`
    /// (dynamic dispatch goes through the object header descriptor).
    pub fn cType(self: *CTranspiler, t: *const type_system.EiwaType) ![]const u8 {
        const base = type_system.extractBaseType(t);
        if (base.* == .Custom) {
            if (self.contracts_ast) |ca| {
                const lookup = if (self.alias_map) |am| (am.get(base.Custom) orelse base.Custom) else base.Custom;
                if (ca.contains(lookup) or ca.contains(base.Custom)) return "void*";
            }
        } else if (base.* == .Array) {
            const inner = try self.cType(base.Array);
            var safe_inner = ArrayList(u8).init(self.allocator);
            for (inner) |c| {
                if (c == '*') continue;
                if (c == ' ') continue;
                try safe_inner.append(c);
            }
            return try std.fmt.allocPrint(self.allocator, "EiwaArray_{s}*", .{safe_inner.items});
        }
        return getCTypeStr(self.allocator, t);
    }

    // Like cType, but for storage positions (struct fields, constructor params).
    // C has no void values, so a Void-typed field (generic T instantiated as
    // Void) is stored as a dummy int that is never meaningfully read.
    pub fn cStorageType(self: *CTranspiler, t: *const type_system.EiwaType) ![]const u8 {
        const ct = try self.cType(t);
        if (std.mem.eql(u8, ct, "void")) return "int";
        return ct;
    }

    pub fn isContract(self: *CTranspiler, name: []const u8) bool {
        if (self.contracts_ast) |ca| {
            const lookup = if (self.alias_map) |am| (am.get(name) orelse name) else name;
            return ca.contains(lookup) or ca.contains(name);
        }
        return false;
    }

    pub fn init(allocator: std.mem.Allocator) CTranspiler {
        return CTranspiler{
            .allocator = allocator,
            .header_writer = ArrayList(u8).init(allocator),
            .forward_writer = ArrayList(u8).init(allocator),
            .writer = ArrayList(u8).init(allocator),
            .classes = std.StringHashMap(void).init(allocator),
            .known_constructors = std.StringHashMap(void).init(allocator),
            .libs = std.StringHashMap(void).init(allocator),
            .link_libraries = std.StringHashMap(void).init(allocator),
            .c_sources = std.StringHashMap(void).init(allocator),
            .c_includes = std.StringHashMap(void).init(allocator),
            .c_defines = std.StringHashMap(void).init(allocator),
            .emitted_functions = std.StringHashMap(void).init(allocator),
            .emitted_variables = std.StringHashMap(void).init(allocator),
            .emitted_lambdas = std.StringHashMap(void).init(allocator),
            .emitted_modules = std.AutoHashMap(*ASTNode, void).init(allocator),
            .is_test_mode = false,
            .test_names = ArrayList([]const u8).init(allocator),
            .test_count = 0,
            .static_initializers = ArrayList(StaticInitializer).init(allocator),
            .outer_scope_vars = ArrayList(std.StringHashMap(void)).init(allocator),
        };
    }

    pub fn deinit(self: *CTranspiler) void {
        self.header_writer.deinit();
        self.forward_writer.deinit();
        self.writer.deinit();
        self.classes.deinit();
        self.known_constructors.deinit();
        self.libs.deinit();
        self.link_libraries.deinit();
        self.c_sources.deinit();
        self.c_includes.deinit();
        self.c_defines.deinit();
        self.emitted_functions.deinit();
        self.emitted_variables.deinit();
        self.emitted_modules.deinit();
        self.emitted_lambdas.deinit();
        self.test_names.deinit();
        self.static_initializers.deinit();
        // Note: outer_scope_vars items are owned by the functions that pushed them
        // and will be deinit'd when those functions clean up, so we just deinit the array
        self.outer_scope_vars.deinit();
    }

    pub fn pushOuterScope(self: *CTranspiler, params: std.StringHashMap(void)) !void {
        try self.outer_scope_vars.append(params);
    }

    pub fn popOuterScope(self: *CTranspiler) void {
        if (self.outer_scope_vars.items.len > 0) {
            self.outer_scope_vars.items.len -= 1;
        }
    }

    pub fn getOuterScopeVars(self: *CTranspiler) ?std.StringHashMap(void) {
        if (self.outer_scope_vars.items.len > 0) {
            return self.outer_scope_vars.items[self.outer_scope_vars.items.len - 1];
        }
        return null;
    }

    pub fn transpile(self: *CTranspiler, node: *ASTNode) ![]const u8 {
        // Pre-register all monomorphized class names into known_constructors AND
        // emit their forward declarations (typedef struct X X) into forward_writer.
        // This guarantees every struct name is known before any prototype is emitted.
        if (self.classes_ast) |ca| {
            var pre_it = ca.iterator();
            while (pre_it.next()) |entry| {
                if (entry.value_ptr.*.data == .type_decl) {
                    const cd = entry.value_ptr.*.data.type_decl;
                    const actual_name = entry.key_ptr.*;
                    if (cd.generic_params.len == 0 and !std.mem.endsWith(u8, actual_name, "_K") and !std.mem.endsWith(u8, actual_name, "_V")) {
                        if (!self.known_constructors.contains(actual_name)) {
                            try self.known_constructors.put(actual_name, {});
                            try self.forward_writer.writer().print("typedef struct {s} {s};\n", .{ actual_name, actual_name });
                        }
                    }
                }
            }
            try self.forward_writer.appendSlice("\n");
        }

        try self.transpileNode(node, true);

        if (self.classes_ast) |ca| {
            var it = ca.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.*.data == .type_decl) {
                    const cd = entry.value_ptr.*.data.type_decl;
                    const actual_name = entry.key_ptr.*;
                    if (cd.generic_params.len == 0 and !std.mem.endsWith(u8, actual_name, "_K") and !std.mem.endsWith(u8, actual_name, "_V")) {
                        try self.emitTypeDecl(entry.value_ptr.*);
                    }
                }
            }
        }

        var final = ArrayList(u8).init(self.allocator);
        try final.appendSlice(std_lib_c);
        try final.appendSlice("\n__thread EiwaExceptionFrame* eiwa_exception_stack = 0;\n__thread void* eiwa_active_exception = 0;\n\n");
        try final.appendSlice(self.forward_writer.items); // forward decls go first
        try final.appendSlice(self.header_writer.items);
        try final.appendSlice(self.writer.items);

        return try final.toOwnedSlice();
    }

    pub fn emitArrayStruct(self: *CTranspiler, elem: *const type_system.EiwaType) !void {
        const inner_c_type = try self.cType(elem);

        var safe_inner = ArrayList(u8).init(self.allocator);
        for (inner_c_type) |c| {
            if (c == '*') continue;
            if (c == ' ') continue;
            try safe_inner.append(c);
        }
        const struct_name = try std.fmt.allocPrint(self.allocator, "EiwaArray_{s}", .{safe_inner.items});

        if (self.classes.contains(struct_name)) return;
        try self.classes.put(struct_name, {});

        var w = self.header_writer.writer();
        try w.print("typedef struct {{\n", .{});
        try w.print("    {s}* data;\n", .{inner_c_type});
        try w.print("    size_t length;\n", .{});
        try w.print("    size_t capacity;\n", .{});
        try w.print("}} {s};\n\n", .{struct_name});

        try w.print("{s}* {s}_new() {{\n", .{ struct_name, struct_name });
        try w.print("    {s}* arr = GC_MALLOC(sizeof({s}));\n", .{ struct_name, struct_name });
        try w.print("    arr->data = GC_MALLOC(4 * sizeof({s}));\n", .{inner_c_type});
        try w.print("    memset(arr->data, 0, 4 * sizeof({s}));\n", .{inner_c_type});
        try w.print("    arr->length = 0;\n", .{});
        try w.print("    arr->capacity = 4;\n", .{});
        try w.print("    return arr;\n", .{});
        try w.print("}}\n\n", .{});

        try w.print("void {s}_push({s}* arr, {s} val) {{\n", .{ struct_name, struct_name, inner_c_type });
        try w.print("    if (arr->length == arr->capacity) {{\n", .{});
        try w.print("        size_t old_capacity = arr->capacity;\n", .{});
        try w.print("        arr->capacity *= 2;\n", .{});
        try w.print("        arr->data = GC_REALLOC(arr->data, arr->capacity * sizeof({s}));\n", .{inner_c_type});
        try w.print("        memset(arr->data + old_capacity, 0, (arr->capacity - old_capacity) * sizeof({s}));\n", .{inner_c_type});
        try w.print("    }}\n", .{});
        try w.print("    arr->data[arr->length++] = val;\n", .{});
        try w.print("}}\n\n", .{});

        try w.print("void {s}_set({s}* arr, int index, {s} val) {{\n", .{ struct_name, struct_name, inner_c_type });
        try w.print("    if (index >= 0 && index < arr->length) {{\n", .{});
        try w.print("        arr->data[index] = val;\n", .{});
        try w.print("    }}\n", .{});
        try w.print("}}\n\n", .{});
    }

    pub fn transpileNode(self: *CTranspiler, node: *ASTNode, is_root: bool) !void {
        switch (node.data) {
            .program => |p| {
                var has_main = false;

                // Pass 1: Types, Contracts, Skills and Imports
                for (p.statements) |stmt| {
                    if (stmt.data == .import_stmt) {
                        if (stmt.data.import_stmt.module_ast) |mod_ast| {
                            if (!self.emitted_modules.contains(mod_ast)) {
                                try self.emitted_modules.put(mod_ast, {});
                                try self.transpileNode(mod_ast, false);
                            }
                        }
                    } else if (stmt.data == .type_decl) {
                        const cd = stmt.data.type_decl;
                        const actual_name = cd.resolved_c_name orelse cd.name;
                        if (cd.generic_params.len == 0 and std.mem.indexOf(u8, actual_name, "_K") == null and std.mem.indexOf(u8, actual_name, "_V") == null) {
                            try self.emitTypeDecl(stmt);
                        }
                    } else if (stmt.data == .enum_decl) {
                        try self.emitEnumDecl(stmt);
                    } else if (stmt.data == .contract_decl) {
                        try self.emitContractDecl(stmt);
                    } else if (stmt.data == .skill_decl) {
                        try self.emitSkillDecl(stmt);
                    } else if (stmt.data == .lib_decl) {
                        try self.emitLibDecl(stmt);
                    }
                }

                // Pass 2: Function Declarations
                for (p.statements) |stmt| {
                    if (stmt.data == .fun_decl) {
                        if (std.mem.eql(u8, stmt.data.fun_decl.name, "main")) has_main = true;
                        try self.emitFunDecl(stmt);
                    } else if (stmt.data == .object_decl) {
                        try self.emitObjectDecl(stmt);
                    } else if (stmt.data == .test_decl and self.is_test_mode) {
                        try self.emitTestDecl(stmt);
                    }
                }

                // Pass 3: Top-Level Statements Collection
                var top_level_stmts = ArrayList(*ASTNode).init(self.allocator);
                defer top_level_stmts.deinit();
                for (p.statements) |stmt| {
                    if (stmt.data != .fun_decl and stmt.data != .type_decl and stmt.data != .enum_decl and stmt.data != .contract_decl and stmt.data != .skill_decl and stmt.data != .import_stmt and stmt.data != .test_decl and stmt.data != .lib_decl and stmt.data != .object_decl) {
                        try top_level_stmts.append(stmt);
                    }
                }

                if (is_root) {
                    if (top_level_stmts.items.len > 0 and has_main) {
                        std.debug.print("Error: Cannot mix top-level statements with fun main()\n", .{});
                        return error.HybridMainConflict;
                    }

                    if (self.is_test_mode) {
                        try self.writer.appendSlice("int main(int argc, char** argv) {\n    GC_init();\n    (void)argc;\n    (void)argv;\n");
                        for (self.static_initializers.items) |si| {
                            try self.writer.writer().print("    {s} = ", .{si.name});
                            try self.emitExpression(si.init);
                            try self.writer.appendSlice(";\n");
                        }
                        try self.writer.appendSlice("    int __failed = 0;\n");
                        for (self.test_names.items, 0..) |tname, i| {
                            try self.writer.appendSlice("    {\n");
                            try self.writer.appendSlice("        EiwaExceptionFrame __frame;\n");
                            try self.writer.appendSlice("        eiwa_push_exception_frame(&__frame);\n");
                            try self.writer.appendSlice("        if (setjmp(__frame.buf) == 0) {\n");
                            try self.writer.writer().print("            eiwa_test_{d}();\n", .{i});
                            try self.writer.appendSlice("            eiwa_pop_exception_frame();\n");
                            try self.writer.writer().print("            printf(\"[PASS] {s}\\n\");\n", .{tname});
                            try self.writer.appendSlice("        } else {\n");
                            try self.writer.appendSlice("            eiwa_pop_exception_frame();\n");
                            try self.writer.appendSlice("            void* __exc = eiwa_active_exception;\n");
                            try self.writer.appendSlice("            eiwa_active_exception = 0;\n");
                            try self.writer.appendSlice("            const char* __name = \"UnknownException\";\n");
                            try self.writer.appendSlice("            const char* __msg = \"\";\n");
                            try self.writer.appendSlice("            if (__exc) {\n");
                            try self.writer.appendSlice("                const EiwaTypeDescriptor* __desc = *(const EiwaTypeDescriptor**)__exc;\n");
                            try self.writer.appendSlice("                if (__desc) __name = __desc->name;\n");
                            try self.writer.appendSlice("                void** __vt = eiwa_find_vtable(__desc, &exceptions_Throwable_contract);\n");
                            try self.writer.appendSlice("                if (__vt && __vt[0]) {\n");
                            try self.writer.appendSlice("                    core_String* __s = ((core_String*(*)(void*))__vt[0])(__exc);\n");
                            try self.writer.appendSlice("                    if (__s) __msg = __s->ptr;\n");
                            try self.writer.appendSlice("                }\n");
                            try self.writer.appendSlice("            }\n");
                            try self.writer.writer().print("            printf(\"*[FAIL] {s}: %s (%s)\\n\", __name, __msg);\n", .{tname});
                            try self.writer.appendSlice("            __failed = 1;\n");
                            try self.writer.appendSlice("        }\n");
                            try self.writer.appendSlice("    }\n");
                        }
                        try self.writer.appendSlice("    return __failed;\n}\n");
                    } else if (!has_main) {
                        try self.writer.appendSlice("int main(int argc, char** argv) {\n    GC_init();\n");
                        try self.writer.appendSlice("    (void)argc;\n");
                        try self.writer.appendSlice("    (void)argv;\n");
                        for (self.static_initializers.items) |si| {
                            try self.writer.writer().print("    {s} = ", .{si.name});
                            try self.emitExpression(si.init);
                            try self.writer.appendSlice(";\n");
                        }

                        for (top_level_stmts.items) |stmt| {
                            try self.emitStatement(stmt);
                        }
                        try self.writer.appendSlice("    return 0;\n}\n");
                    }
                } else {
                    if (top_level_stmts.items.len > 0) {
                        std.debug.print("Error: Imported files cannot contain top-level statements (side-effects).\n", .{});
                        return error.ImportSideEffectsNotAllowed;
                    }
                }
            },
            else => return error.InvalidProgramNode,
        }
    }
};

const std = @import("std");
const compat = @import("../compat.zig");
const ArrayList = compat.ArrayList;
const ast = @import("../ast.zig");
const parser_mod = @import("../../frontend/parser/core.zig");
const core = @import("core.zig");

const ASTNode = core.ASTNode;
const TypeChecker = core.TypeChecker;
const Scope = core.Scope;
const EiwaType = core.EiwaType;

pub const std_modules = std.StaticStringMap([]const u8).initComptime(.{
    .{ "core.ei", @embedFile("../../std/core.ei") },
    .{ "io.ei", @embedFile("../../std/io.ei") },
    .{ "system.ei", @embedFile("../../std/system.ei") },
    .{ "exceptions.ei", @embedFile("../../std/exceptions.ei") },
    .{ "time.ei", @embedFile("../../std/time.ei") },
    .{ "math.ei", @embedFile("../../std/math.ei") },
    .{ "fs.ei", @embedFile("../../std/fs.ei") },
    .{ "collections.ei", @embedFile("../../std/collections.ei") },
    .{ "net.ei", @embedFile("../../std/net.ei") },
    .{ "http.ei", @embedFile("../../std/http.ei") },
    .{ "env.ei", @embedFile("../../std/env.ei") },
    .{ "serde.ei", @embedFile("../../std/serde.ei") },
    .{ "json.ei", @embedFile("../../std/json.ei") },
    .{ "yaml.ei", @embedFile("../../std/yaml.ei") },
    .{ "log.ei", @embedFile("../../std/log.ei") },
});

pub const user_implicit_imports = &[_][]const u8{ "std.core", "std.io", "std.system", "std.exceptions", "std.env", "std.collections", "std.time", "std.serde", "std.log" };
pub const core_implicit_imports = &[_][]const u8{ "std.core", "std.io", "std.system", "std.exceptions" };
pub const core_fallback_modules = &[_][]const u8{ "io.ei", "system.ei", "exceptions.ei" };

pub const auto_injected_contracts = &[_][]const u8{ "Stringable", "Equatable", "Hashable" };
pub const auto_injected_skills = &[_][]const u8{ "Echoable" };

pub fn inferImportStmt(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    _ = scope;
    if (self.pass == .validation) {
        t.* = .Void;
        return;
    }

    var i = &node.data.import_stmt;
    const dir_path = std.fs.path.dirname(self.filename) orelse ".";
    var actual_module_path: []const u8 = i.module_path;
    if (!std.mem.endsWith(u8, actual_module_path, ".ei")) {
        actual_module_path = try std.fmt.allocPrint(self.allocator, "{s}.ei", .{actual_module_path});
    }
    var mod_path: []const u8 = undefined;
    var mod_source: []const u8 = undefined;

    if (std.mem.startsWith(u8, actual_module_path, "std.")) {
        const pkg_name = actual_module_path[4..];
        mod_path = try std.fmt.allocPrint(self.allocator, "std/{s}", .{pkg_name});

        if (std_modules.get(pkg_name)) |source| {
            mod_source = source;
        } else {
            self.reportError(node.line, node.column, "ImportError: Unknown standard library package 'std.{s}'", .{pkg_name});
            return error.ImportError;
        }
    } else {
        if (std.mem.eql(u8, dir_path, ".")) {
            mod_path = actual_module_path;
        } else {
            mod_path = try std.fs.path.join(self.allocator, &.{ dir_path, actual_module_path });
        }
        if (self.registry == null) {
            mod_source = std.Io.Dir.cwd().readFileAlloc(self.io, mod_path, self.allocator, .limited(1024 * 1024)) catch |err| {
                self.reportError(node.line, node.column, "ImportError: Failed to read module file '{s}': {}", .{ mod_path, err });
                return error.ImportError;
            };
        }
    }

    var mod_ast: *ASTNode = undefined;
    var prefix: []const u8 = undefined;
    var tc_opt: ?*TypeChecker = null;
    var fallback_tc: TypeChecker = undefined;
    var has_fallback = false;

    if (self.registry) |reg| {
        if (reg.modules.get(mod_path)) |m| {
            mod_ast = m.ast_root;
            prefix = m.module_prefix;
            tc_opt = m.checker;
        } else {
            self.reportError(node.line, node.column, "ImportError: Module '{s}' not found in registry.", .{mod_path});
            return error.ImportError;
        }
    } else {
        var p = parser_mod.Parser.init(self.allocator, mod_source);
        mod_ast = try p.parse();

        const basename = std.fs.path.basename(mod_path);
        const ext_idx = std.mem.lastIndexOf(u8, basename, ".") orelse basename.len;
        prefix = basename[0..ext_idx];

        fallback_tc = TypeChecker.init(self.allocator, mod_source, mod_path);
        fallback_tc.module_prefix = prefix;
        fallback_tc.is_test_mode = self.is_test_mode;
        try fallback_tc.validate(mod_ast);
        tc_opt = &fallback_tc;
        has_fallback = true;
    }
    i.module_ast = mod_ast;
    const tc = tc_opt.?;

    if (i.destructured.len == 0) {
        // Non-destructured imports only re-export symbols declared in the module
        // itself (ADR 26) — transitively imported symbols do not leak.
        var it = tc.global_scope.symbols.iterator();
        while (it.next()) |entry| {
            if (!tc.local_symbols.contains(entry.key_ptr.*)) continue;
            try self.global_scope.symbols.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        var alias_it = tc.alias_map.iterator();
        while (alias_it.next()) |entry| {
            if (!tc.local_symbols.contains(entry.key_ptr.*)) continue;
            try self.alias_map.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        var class_ast_it = tc.classes_ast.iterator();
        while (class_ast_it.next()) |entry| {
            try self.classes_ast.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        var contract_ast_it = tc.contracts_ast.iterator();
        while (contract_ast_it.next()) |entry| {
            try self.contracts_ast.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        var skill_ast_it = tc.skills_ast.iterator();
        while (skill_ast_it.next()) |entry| {
            try self.skills_ast.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        var object_ast_it = tc.objects_ast.iterator();
        while (object_ast_it.next()) |entry| {
            try self.objects_ast.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    } else {
        for (i.destructured) |sym| {
            var found = false;

            if (tc.alias_map.get(sym)) |aliased_name| {
                try self.alias_map.put(sym, aliased_name);
            } else if (prefix.len > 0) {
                const aliased_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ prefix, sym });
                try self.alias_map.put(sym, aliased_name);
            }

            if (tc.global_scope.lookupFunctions(sym)) |overloads| {
                for (overloads) |overload| {
                    try self.global_scope.define(sym, overload, false, true);
                }
                found = true;
            } else if (tc.global_scope.lookupVariable(sym)) |variable| {
                try self.global_scope.define(sym, variable, false, false);
                found = true;
            }

            if (!found) {
                for (mod_ast.data.program.statements) |stmt| {
                    if (stmt.data == .type_decl) {
                        if (std.mem.eql(u8, stmt.data.type_decl.name, sym)) {
                            found = true;
                            break;
                        }
                    } else if (stmt.data == .contract_decl) {
                        if (std.mem.eql(u8, stmt.data.contract_decl.name, sym)) {
                            found = true;
                            break;
                        }
                    } else if (stmt.data == .skill_decl) {
                        if (std.mem.eql(u8, stmt.data.skill_decl.name, sym)) {
                            found = true;
                            break;
                        }
                    } else if (stmt.data == .lib_decl) {
                        if (std.mem.eql(u8, stmt.data.lib_decl.name, sym)) {
                            found = true;
                            break;
                        }
                    }
                }
            }

            if (!found and (std.mem.endsWith(u8, mod_path, "core") or std.mem.endsWith(u8, mod_path, "core.ei")) and self.registry != null) {
                var mod_it = self.registry.?.modules.iterator();
                while (mod_it.next()) |entry| {
                    const k = entry.key_ptr.*;
                    var is_fb = false;
                    for (core_fallback_modules) |fb_name| {
                        if (std.mem.endsWith(u8, k, fb_name)) {
                            is_fb = true;
                            break;
                        }
                    }
                    if (is_fb) {
                        const fb_tc = entry.value_ptr.checker;
                        if (!fb_tc.local_symbols.contains(sym)) continue;
                        const fb_prefix = fb_tc.module_prefix orelse "";
                        if (fb_tc.global_scope.lookupFunctions(sym)) |overloads| {
                            for (overloads) |overload| {
                                try self.global_scope.define(sym, overload, false, true);
                            }
                            if (fb_prefix.len > 0) {
                                const aliased_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ fb_prefix, sym });
                                try self.alias_map.put(sym, aliased_name);
                            }
                            found = true;
                            break;
                        } else if (fb_tc.global_scope.lookupVariable(sym)) |variable| {
                            try self.global_scope.define(sym, variable, false, false);
                            if (fb_prefix.len > 0) {
                                const aliased_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ fb_prefix, sym });
                                try self.alias_map.put(sym, aliased_name);
                            }
                            found = true;
                            break;
                        } else if (fb_tc.global_scope.symbols.get(sym)) |sym_info| {
                            if (sym_info.variable) |vs| {
                                _ = self.global_scope.define(sym, vs.eiwa_type, false, false) catch {};
                            }
                            if (fb_prefix.len > 0) {
                                const aliased_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ fb_prefix, sym });
                                try self.alias_map.put(sym, aliased_name);
                            }
                            var c_it = fb_tc.classes_ast.iterator();
                            while (c_it.next()) |ce| { try self.classes_ast.put(ce.key_ptr.*, ce.value_ptr.*); }
                            var ct_it = fb_tc.contracts_ast.iterator();
                            while (ct_it.next()) |cte| { try self.contracts_ast.put(cte.key_ptr.*, cte.value_ptr.*); }
                            found = true;
                            break;
                        }
                    }
                }
            }

            if (!found) {
                self.reportError(node.line, node.column, "ImportError: Symbol '{s}' not found in module '{s}'.", .{ sym, mod_path });
                return error.ImportError;
            }
        }

        var class_ast_it = tc.classes_ast.iterator();
        while (class_ast_it.next()) |entry| {
            try self.classes_ast.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        var contract_ast_it2 = tc.contracts_ast.iterator();
        while (contract_ast_it2.next()) |entry| {
            try self.contracts_ast.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        var skill_ast_it2 = tc.skills_ast.iterator();
        while (skill_ast_it2.next()) |entry| {
            try self.skills_ast.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        var object_ast_it = tc.objects_ast.iterator();
        while (object_ast_it.next()) |entry| {
            try self.objects_ast.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        // Also register generic template symbols so that method bodies referencing
        // sibling classes (e.g. List.mut() returns MutableList) can resolve them.
        var alias_it2 = tc.alias_map.iterator();
        while (alias_it2.next()) |entry| {
            if (!self.alias_map.contains(entry.key_ptr.*)) {
                try self.alias_map.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }
        var sym_it = tc.global_scope.symbols.iterator();
        while (sym_it.next()) |entry| {
            if (!self.global_scope.symbols.contains(entry.key_ptr.*)) {
                try self.global_scope.symbols.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }
    }

    var fun_ast_it = tc.functions_ast.iterator();
    while (fun_ast_it.next()) |entry| {
        try self.functions_ast.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    if (has_fallback) {
        fallback_tc.deinit();
    }

    t.* = .Void;
}

pub fn inferTypeDecl(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    var c = &node.data.type_decl;
    if (c.resolved_c_name == null) {
        if (self.module_prefix) |prefix| {
            c.resolved_c_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ prefix, c.name });
            if (!std.mem.eql(u8, c.name, "Int") and !std.mem.eql(u8, c.name, "Bool") and !std.mem.eql(u8, c.name, "Pointer") and !std.mem.eql(u8, c.name, "OpaquePointer")) {
                try self.alias_map.put(c.name, c.resolved_c_name.?);
            }
        } else {
            c.resolved_c_name = c.name;
        }
    }
    const actual_c_name = c.resolved_c_name.?;
    const class_type = try self.allocator.create(EiwaType);
    if (std.mem.eql(u8, c.name, "Int")) {
        class_type.* = .Int;
    } else if (std.mem.eql(u8, c.name, "Bool")) {
        class_type.* = .Bool;
    } else if (std.mem.eql(u8, c.name, "String")) {
        class_type.* = .String;
    } else if (std.mem.eql(u8, c.name, "OpaquePointer") or std.mem.eql(u8, c.name, "Pointer")) {
        class_type.* = .{ .Pointer = try self.allocator.create(EiwaType) };
        @constCast(class_type.Pointer).* = .Void;
    } else {
        class_type.* = .{ .Custom = actual_c_name };
    }
    try scope.define(c.name, class_type, false, false);
    if (!std.mem.eql(u8, c.name, actual_c_name)) {
        try scope.define(actual_c_name, class_type, false, false);
    }

    try self.classes_ast.put(actual_c_name, node);

    // Generic Templates are not deeply inferred nor compiled directly.
    // They wait to be monomorphized when instantiated.
    if (c.generic_params.len > 0) {
        t.* = .Void;
        return;
    }

    try injectAutoContractsAndSkills(self, c);

    // Compose skills exactly once (mutates c.methods)
    if (!c.skills_composed) {
        c.skills_composed = true;
        try composeSkills(self, node, c);
    }

    if (!c.serde_generated) {
        c.serde_generated = true;
        try generateDefaultToString(self, node, c);
        try generateDefaultHashCode(self, node, c);
        try generateDefaultEquals(self, node, c);
        try generateSerdeFields(self, node, c);
    }

    var class_scope = Scope.init(self.allocator, scope);
    defer class_scope.deinit();
    try class_scope.define("this", class_type, false, false);

    var class_props = std.StringHashMap(void).init(self.allocator);
    defer class_props.deinit();
    const old_props = self.current_class_props;
    self.current_class_props = &class_props;
    defer self.current_class_props = old_props;

    const old_type_c_name = self.current_type_c_name;
    self.current_type_c_name = actual_c_name;
    defer self.current_type_c_name = old_type_c_name;

    for (c.primary_constructor) |*prop| {
        const param_type = prop.resolved_type orelse try self.resolveTypeRef(prop.type_ref);
        prop.resolved_type = param_type;

        if (prop.initializer) |init_node| {
            if (self.pass == .validation) {
                const cloned_init = try self.cloneNode(init_node);
                cloned_init.expected_type = param_type;
                const init_type = try self.inferNode(cloned_init, scope);
                if (!self.isCompatible(param_type, init_type)) {
                    self.reportError(node.line, node.column, "TypeError: Default value type {} is incompatible with property type {}.", .{ init_type.*, param_type.* });
                    return error.TypeError;
                }
            }
        }

        if (prop.is_property) {
            try class_props.put(prop.name, {});
            try class_scope.define(prop.name, param_type, prop.is_mut, false);
        }
    }

    const old_class_methods = self.current_class_methods;
    self.current_class_methods = c.methods;
    defer self.current_class_methods = old_class_methods;

    // Pre-register method signatures in class_scope for sibling/forward method calls without this.
    for (c.methods) |method| {
        if (method.data == .fun_decl) {
            const m = &method.data.fun_decl;
            if (m.generic_params.len > 0) continue;
            var param_types = ArrayList(*const EiwaType).init(self.allocator);
            for (m.params) |p| {
                const p_t = if (p.type_ref) |tr| self.resolveTypeRef(tr) catch try self.resolveTypeName("Void", false) else try self.resolveTypeName("Void", false);
                try param_types.append(p_t);
            }
            const ret_t = if (m.type_ref) |tr| self.resolveTypeRef(tr) catch try self.resolveTypeName("Void", false) else try self.resolveTypeName("Void", false);

            var method_count: usize = 0;
            for (c.methods) |other_m| {
                if (other_m.data == .fun_decl and std.mem.eql(u8, other_m.data.fun_decl.name, m.name)) {
                    method_count += 1;
                }
            }

            var mangled = ArrayList(u8).init(self.allocator);
            try mangled.writer().print("{s}_{s}", .{ actual_c_name, m.name });
            if (method_count > 1) {
                for (param_types.items) |pt| {
                    try mangled.appendSlice("_");
                    try pt.formatSafe(mangled.writer());
                }
            }
            const m_c_name = try mangled.toOwnedSlice();
            m.resolved_c_name = m_c_name;

            const fn_type = try self.allocator.create(EiwaType);
            fn_type.* = .{ .Function = .{
                .params = try param_types.toOwnedSlice(),
                .return_type = ret_t,
                .c_name = m_c_name,
                .receiver = class_type,
            } };
            try class_scope.define(m.name, fn_type, false, true);
        }
    }

    // Methods
    for (c.methods) |method| {
        if (method.data == .fun_decl) {

            const m_name = method.data.fun_decl.name;
            const is_operator = std.mem.eql(u8, m_name, "plus") or
                std.mem.eql(u8, m_name, "minus") or
                std.mem.eql(u8, m_name, "star") or
                std.mem.eql(u8, m_name, "slash");
            if (is_operator) {
                var has_operator_mod = false;
                for (method.data.fun_decl.modifiers) |mod| {
                    if (mod == .kw_operator) {
                        has_operator_mod = true;
                        break;
                    }
                }
                if (!has_operator_mod) {
                    self.reportError(method.line, method.column, "TypeError: Method '{s}' must be marked with the 'operator' modifier.", .{m_name});
                    return error.TypeError;
                }
            }
        }
        _ = try self.inferNode(method, &class_scope);
    }

    // Contract conformance is validated after method inference so expression-body
    // implementations have their return types resolved.
    try validateContracts(self, node, c);
    t.* = .Void;
}

fn composeSkills(self: *TypeChecker, node: *ASTNode, c: anytype) anyerror!void {
    if (c.skills.len == 0) return;

    var final_methods = ArrayList(*ASTNode).init(self.allocator);
    var provided = std.StringHashMap([]const u8).init(self.allocator);

    for (c.methods) |m| {
        try final_methods.append(m);
        if (m.data == .fun_decl) {
            try provided.put(m.data.fun_decl.name, "");
        }
    }

    for (c.skills) |skill_src_name| {
        const skill_actual = self.alias_map.get(skill_src_name) orelse skill_src_name;
        var skill_node_opt = self.skills_ast.get(skill_actual);
        if (skill_node_opt == null and self.registry != null) {
            var mod_it = self.registry.?.modules.iterator();
            while (mod_it.next()) |entry| {
                const reg_actual = entry.value_ptr.checker.alias_map.get(skill_src_name) orelse skill_actual;
                if (entry.value_ptr.checker.skills_ast.get(reg_actual)) |sn| {
                    skill_node_opt = sn;
                    break;
                }
            }
        }
        const skill_node = skill_node_opt orelse {
            self.reportError(node.line, node.column, "TypeError: Skill '{s}' not found.", .{skill_src_name});
            return error.TypeError;
        };
        const s = skill_node.data.skill_decl;

        // A type may compose a skill only if it implements every required contract.
        for (s.required_contracts) |req| {
            const req_actual = self.alias_map.get(req) orelse req;
            var found = false;
            for (c.contracts) |tc| {
                const tc_actual = self.alias_map.get(tc) orelse tc;
                if (std.mem.eql(u8, tc_actual, req_actual)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                self.reportError(node.line, node.column, "Skill '{s}' requires contract '{s}'.\nType '{s}' does not implement it.", .{ s.name, req, c.name });
                return error.TypeError;
            }
        }

        for (s.methods) |m| {
            if (m.data != .fun_decl) continue;
            const fname = m.data.fun_decl.name;
            if (provided.get(fname)) |other_skill| {
                if (other_skill.len == 0) {
                    // Type implements it explicitly — skill version stays available qualified.
                    const renamed = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ s.name, fname });
                    const cloned = try self.cloneNode(m);
                    @constCast(&cloned.data.fun_decl).name = renamed;
                    try final_methods.append(cloned);
                } else {
                    // Two skills provide the same member without an explicit resolution.
                    self.reportError(m.line, m.column, "TypeError: Ambiguous member '{s}' from skills '{s}' and '{s}'. Resolve it explicitly in type '{s}' with 'implement fun {s}'.", .{ fname, other_skill, s.name, c.name, fname });
                    return error.TypeError;
                }
            } else {
                try provided.put(fname, s.name);
                const cloned = try self.cloneNode(m);
                try final_methods.append(cloned);
            }
        }
    }

    c.methods = try final_methods.toOwnedSlice();
}

fn validateContracts(self: *TypeChecker, node: *ASTNode, c: anytype) anyerror!void {
    for (c.contracts) |contract_src_name| {
        const contract_actual = self.alias_map.get(contract_src_name) orelse contract_src_name;
        const contract_node = self.contracts_ast.get(contract_actual) orelse {
            self.reportError(node.line, node.column, "TypeError: Contract '{s}' not found.", .{contract_src_name});
            return error.TypeError;
        };
        const cd = contract_node.data.contract_decl;

        for (cd.methods) |cm| {
            if (cm.data != .fun_decl) continue;
            const cm_name = cm.data.fun_decl.name;

            var found: ?*ASTNode = null;
            var from_skill = false;
            for (c.methods) |m| {
                if (m.data != .fun_decl) continue;
                if (std.mem.eql(u8, m.data.fun_decl.name, cm_name)) {
                    found = m;
                    // Methods cloned from skills carry no 'implement' requirement.
                    for (c.skills) |skill_src| {
                        const skill_actual = self.alias_map.get(skill_src) orelse skill_src;
                        if (self.skills_ast.get(skill_actual)) |sn| {
                            for (sn.data.skill_decl.methods) |sm| {
                                if (sm.data == .fun_decl and std.mem.eql(u8, sm.data.fun_decl.name, cm_name)) {
                                    from_skill = true;
                                    break;
                                }
                            }
                        }
                    }
                    break;
                }
            }

            if (found == null) {
                self.reportError(node.line, node.column, "TypeError: Type '{s}' does not implement method '{s}' required by contract '{s}'.", .{ c.name, cm_name, cd.name });
                return error.TypeError;
            }

            const m = found.?;
            if (!from_skill) {
                var is_auto_contract = false;
                for (auto_injected_contracts) |aic| {
                    const aic_actual = self.alias_map.get(aic) orelse aic;
                    if (std.mem.eql(u8, contract_actual, aic_actual) or std.mem.eql(u8, cd.name, aic)) {
                        is_auto_contract = true;
                        break;
                    }
                }
                if (!is_auto_contract) {
                    var has_implement = false;
                    for (m.data.fun_decl.modifiers) |mod| {
                        if (mod == .kw_implement) {
                            has_implement = true;
                            break;
                        }
                    }
                    if (!has_implement) {
                        self.reportError(m.line, m.column, "TypeError: Method '{s}' implements contract '{s}' and must be marked with 'implement'.", .{ cm_name, cd.name });
                        return error.TypeError;
                    }
                }
            }

            if (m.data.fun_decl.params.len != cm.data.fun_decl.params.len) {
                self.reportError(m.line, m.column, "TypeError: Method '{s}' does not match the signature of contract '{s}'.", .{ cm_name, cd.name });
                return error.TypeError;
            }

            // Return type compatibility (Void if omitted on either side)
            const contract_ret = if (cm.data.fun_decl.type_ref) |tr| try self.resolveTypeRef(tr) else blk: {
                const v = try self.allocator.create(EiwaType);
                v.* = .Void;
                break :blk v;
            };
            const impl_ret = if (m.data.fun_decl.type_ref) |tr| try self.resolveTypeRef(tr) else blk: {
                if (m.data.fun_decl.is_expr_body) {
                    if (m.data.fun_decl.body.resolved_type) |bt| {
                        break :blk bt;
                    }
                    // Body not inferred yet — skip the check for now.
                    break :blk contract_ret;
                }
                const v = try self.allocator.create(EiwaType);
                v.* = .Void;
                break :blk v;
            };

            // Skip return type check if contract return type is a generic param
            var skip_ret_check = false;
            if (contract_ret.* == .Custom and cd.generic_params.len > 0) {
                for (cd.generic_params) |gp| {
                    if (std.mem.eql(u8, gp, contract_ret.Custom)) {
                        skip_ret_check = true;
                        break;
                    }
                }
            }
            if (!skip_ret_check and !self.isCompatible(contract_ret, impl_ret)) {
                self.reportError(m.line, m.column, "TypeError: Method '{s}' returns {} but contract '{s}' requires {}.", .{ cm_name, impl_ret.*, cd.name, contract_ret.* });
                return error.TypeError;
            }
        }
    }
}

pub fn inferContractDecl(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    var cd = &node.data.contract_decl;
    if (cd.resolved_c_name == null) {
        if (self.module_prefix) |prefix| {
            cd.resolved_c_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ prefix, cd.name });
            try self.alias_map.put(cd.name, cd.resolved_c_name.?);
        } else {
            cd.resolved_c_name = cd.name;
        }
    }
    const actual_c_name = cd.resolved_c_name.?;
    const contract_type = try self.allocator.create(EiwaType);
    contract_type.* = .{ .Custom = actual_c_name };
    try scope.define(cd.name, contract_type, false, false);
    if (!std.mem.eql(u8, cd.name, actual_c_name)) {
        try scope.define(actual_c_name, contract_type, false, false);
    }
    try self.contracts_ast.put(actual_c_name, node);

    if (cd.generic_params.len > 0) {
        t.* = .Void;
        return;
    }

    // Register method signatures only (contracts have no bodies to check).
    for (cd.methods) |method| {
        if (method.data != .fun_decl) continue;
        const m = &method.data.fun_decl;
        var param_types = ArrayList(*const EiwaType).init(self.allocator);
        for (m.params) |p| {
            const p_t = if (p.type_ref) |tr| try self.resolveTypeRef(tr) else try self.resolveTypeName("Void", false);
            try param_types.append(p_t);
        }
        const ret_t = if (m.type_ref) |tr| try self.resolveTypeRef(tr) else try self.resolveTypeName("Void", false);
        m.resolved_c_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ actual_c_name, m.name });
        const fn_type = try self.allocator.create(EiwaType);
        fn_type.* = .{ .Function = .{
            .params = try param_types.toOwnedSlice(),
            .return_type = ret_t,
            .c_name = m.resolved_c_name.?,
            .receiver = contract_type,
        } };
        method.resolved_type = fn_type;
    }
    t.* = .Void;
}

pub fn inferSkillDecl(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    _ = scope;
    var sd = &node.data.skill_decl;
    if (sd.resolved_c_name == null) {
        if (self.module_prefix) |prefix| {
            sd.resolved_c_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ prefix, sd.name });
            try self.alias_map.put(sd.name, sd.resolved_c_name.?);
        } else {
            sd.resolved_c_name = sd.name;
        }
    }
    try self.skills_ast.put(sd.resolved_c_name.?, node);
    // Skill bodies are type-checked at the composition site (per consuming type),
    // never standalone.
    t.* = .Void;
}

pub fn inferFunDecl(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    var f = &node.data.fun_decl;
    if (f.generic_params.len > 0) {
        try self.generic_functions_ast.put(f.name, node);
        t.* = .Void;
        return;
    }
    var param_types = ArrayList(*const EiwaType).init(self.allocator);
    var mangled_name = ArrayList(u8).init(self.allocator);
    const is_method = scope.lookupVariable("this") != null;
    if (is_method) {
        const this_t = scope.lookupVariable("this").?;
        const base_t = core.extractBaseType(this_t);
        const class_name = if (self.current_class_name) |cname| (self.alias_map.get(cname) orelse cname) else (if (base_t.* == .Custom) base_t.Custom else (if (base_t.* == .Pointer and base_t.Pointer.* == .Custom) base_t.Pointer.Custom else (if (base_t.* == .Int) "core_Int" else (if (base_t.* == .Bool) "core_Bool" else (if (base_t.* == .String) "core_String" else f.name)))));


        try mangled_name.writer().print("{s}_{s}", .{ class_name, f.name });
    }
    else if (self.current_class_name) |class_name| {
        const actual_class = self.alias_map.get(class_name) orelse class_name;
        try mangled_name.writer().print("{s}_{s}", .{ actual_class, f.name });
    } else if (self.module_prefix) |prefix| {
        try mangled_name.writer().print("{s}_{s}", .{ prefix, f.name });
    } else {
        try mangled_name.appendSlice(f.name);
    }

    var is_overloaded = false;
    if (is_method or self.current_class_name != null) {
        if (self.current_class_methods) |methods| {
            var method_count: usize = 0;
            for (methods) |m| {
                if (m.data == .fun_decl and std.mem.eql(u8, m.data.fun_decl.name, f.name)) {
                    method_count += 1;
                }
            }
            if (method_count > 1) is_overloaded = true;
        }
    }




    var fun_scope = Scope.init(self.allocator, scope);
    fun_scope.is_function_boundary = true;
    defer fun_scope.deinit();

    for (f.params) |*p| {
        var param_type: *EiwaType = undefined;
        if (p.type_ref) |tr| {
            param_type = try self.resolveTypeRef(tr);

            if (!is_method or is_overloaded) {
                try mangled_name.appendSlice("_");
                try param_type.formatSafe(mangled_name.writer());
            }
        } else {
            param_type = try self.allocator.create(EiwaType);
            param_type.* = .Void;
            if (!is_method or is_overloaded) {
                try mangled_name.appendSlice("_Void");
            }
        }


        if (p.initializer) |init_node| {
            if (self.pass == .validation) {
                const cloned_init = try self.cloneNode(init_node);
                cloned_init.expected_type = param_type;
                const init_type = try self.inferNode(cloned_init, scope);
                if (!self.isCompatible(param_type, init_type)) {
                    self.reportError(node.line, node.column, "TypeError: Default value type {} is incompatible with parameter type {}.", .{ init_type.*, param_type.* });
                    return error.TypeError;
                }
            }
        }

        try fun_scope.define(p.name, param_type, false, false);
        try param_types.append(param_type);
    }

    if (f.resolved_c_name != null) {
        // Already set (e.g. by monomorphizeFunction) — just ensure it's in functions_ast
        try self.functions_ast.put(f.resolved_c_name.?, node);
    } else if (std.mem.eql(u8, f.name, "main")) {
        f.resolved_c_name = "main";
        try self.functions_ast.put(f.resolved_c_name.?, node);
    } else {
        f.resolved_c_name = try mangled_name.toOwnedSlice();
        try self.functions_ast.put(f.resolved_c_name.?, node);
        if (!is_method and self.current_class_name == null) {
            try self.local_symbols.put(f.name, {});
            if (self.module_prefix != null) {
                try self.alias_map.put(f.name, f.resolved_c_name.?);
            }
        }
    }

    var return_type: *const EiwaType = undefined;
    var body_inferred = false;

    if (f.type_ref) |tr| {
        return_type = try self.resolveTypeRef(tr);
    } else if (f.is_expr_body) {
        _ = try self.inferNode(f.body, &fun_scope);
        body_inferred = true;
        return_type = f.body.resolved_type.?;
    } else {
        const void_t = try self.allocator.create(EiwaType);
        void_t.* = .Void;
        return_type = void_t;
    }

    const fn_type = try self.allocator.create(EiwaType);
    fn_type.* = .{ .Function = .{
        .params = try param_types.toOwnedSlice(),
        .return_type = return_type,
        .c_name = f.resolved_c_name.?,
        .receiver = if (is_method) scope.lookupVariable("this") else null,
    } };

    try scope.define(f.name, fn_type, false, true);

    if (self.pass == .declaration) {
        t.* = fn_type.*;
        return;
    }

    if (!body_inferred) {
        _ = try self.inferNode(f.body, &fun_scope);
    }

    if (f.is_expr_body) {
        if (!self.isCompatible(return_type, f.body.resolved_type.?)) {
            self.reportError(node.line, node.column, "TypeError: Expected {} but found {} in expression body.", .{ return_type.*, f.body.resolved_type.?.* });
            return error.TypeError;
        }
    }
    t.* = fn_type.*;
}

pub fn inferVarDecl(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    const v = &node.data.var_decl;
    if (self.current_class_name) |class_name| {
        const actual_class = self.alias_map.get(class_name) orelse class_name;
        @constCast(v).resolved_c_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ actual_class, v.name });
    }
    var declared: ?*const EiwaType = null;
    if (v.type_ref) |tr| {
        declared = try self.resolveTypeRef(tr);
    }

    var inferred: ?*const EiwaType = null;
    if (v.initializer) |init_node| {
        if (declared) |d| {
            init_node.expected_type = d;
            init_node.resolved_type = null;
        }
        inferred = try self.inferNode(init_node, scope);
    }

    if (declared != null and inferred != null) {
        if (!self.isCompatible(declared.?, inferred.?)) {
            self.reportError(node.line, node.column, "TypeError: Expected {} but found {} for variable '{s}'.", .{ declared.?.*, inferred.?.*, v.name });
            return error.TypeError;
        }
    }

    const final_type = declared orelse (inferred orelse blk: {
        const void_t = try self.allocator.create(EiwaType);
        void_t.* = .Void;
        break :blk void_t;
    });
    try scope.define(v.name, final_type, v.is_mut, false);
    if (scope.symbols.getPtr(v.name)) |sym_ptr| {
        var sym = sym_ptr.*;
        if (sym.variable) |v_sym| {
            var new_v = v_sym;
            new_v.decl_node = node;
            sym.variable = new_v;
            sym_ptr.* = sym;
        }
    }
    node.resolved_type = final_type;
    t.* = .Void;
}

pub fn inferLibDecl(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    const l = node.data.lib_decl;
    const lib_type = try self.allocator.create(EiwaType);
    lib_type.* = .{ .Custom = l.name };
    try scope.define(l.name, lib_type, false, false);
    try self.local_symbols.put(l.name, {});

    for (l.functions) |func| {
        const f = &func.data.fun_decl;
        const full_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ l.name, f.name });

        var ret_type: *EiwaType = undefined;
        if (f.type_ref) |tr| {
            ret_type = try self.resolveTypeRef(tr);
        } else {
            ret_type = try self.allocator.create(EiwaType);
            ret_type.* = .Void;
        }
        var c_name = f.name;
        for (f.annotations) |ann| {
            if (std.mem.eql(u8, ann.name, "Alias")) {
                if (ann.arguments.len > 0) {
                    c_name = ann.arguments[0];
                }
            }
        }
        try scope.define(full_name, ret_type, false, true);
        try self.alias_map.put(full_name, c_name);
        try self.local_symbols.put(full_name, {});
    }
    t.* = .Void;
}

pub fn inferObjectDecl(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    var o = &node.data.object_decl;
    const name = o.name orelse {
        self.reportError(node.line, node.column, "TypeError: Companion object must have a resolved bound name.", .{});
        return error.TypeError;
    };

    if (o.resolved_c_name == null) {
        if (self.module_prefix) |prefix| {
            o.resolved_c_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ prefix, name });
            try self.alias_map.put(name, o.resolved_c_name.?);
        } else {
            o.resolved_c_name = name;
        }
    }
    const actual_c_name = o.resolved_c_name.?;
    const obj_type = try self.allocator.create(EiwaType);
    obj_type.* = .{ .Custom = actual_c_name };
    if (scope.lookupVariable(name) == null) {
        _ = scope.define(name, obj_type, false, false) catch {};
    }
    if (!std.mem.eql(u8, name, actual_c_name)) {
        if (scope.lookupVariable(actual_c_name) == null) {
            _ = scope.define(actual_c_name, obj_type, false, false) catch {};
        }
    }


    try self.objects_ast.put(actual_c_name, node);

    // Set static block context
    const old_class_name = self.current_class_name;
    const old_class_methods = self.current_class_methods;
    self.current_class_name = name;
    self.current_class_methods = o.members;
    defer {
        self.current_class_name = old_class_name;
        self.current_class_methods = old_class_methods;
    }


    var obj_scope = Scope.init(self.allocator, scope);
    defer obj_scope.deinit();

    for (o.members) |member| {
        _ = try self.inferNode(member, &obj_scope);
    }
    t.* = .Void;
}

pub fn inferEnumDecl(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    var ed = &node.data.enum_decl;
    if (ed.resolved_c_name == null) {
        if (self.module_prefix) |prefix| {
            ed.resolved_c_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ prefix, ed.name });
            try self.alias_map.put(ed.name, ed.resolved_c_name.?);
        } else {
            ed.resolved_c_name = ed.name;
        }
    }
    const actual_c_name = ed.resolved_c_name.?;
    const enum_type = try self.allocator.create(EiwaType);
    enum_type.* = .{ .Custom = actual_c_name };

    if (scope.lookupVariable(ed.name) == null) {
        _ = scope.define(ed.name, enum_type, false, false) catch {};
    }
    if (!std.mem.eql(u8, ed.name, actual_c_name)) {
        if (scope.lookupVariable(actual_c_name) == null) {
            _ = scope.define(actual_c_name, enum_type, false, false) catch {};
        }
    }

    try self.enums_ast.put(actual_c_name, node);
    t.* = .Void;
}

fn makeIdent(self: *TypeChecker, line: usize, col: usize, name: []const u8) !*ASTNode {
    const node = try self.allocator.create(ASTNode);
    node.* = .{
        .line = line,
        .column = col,
        .resolved_type = null,
        .expected_type = null,
        .data = .{
            .identifier = .{
                .name = name,
                .resolved_c_name = null,
            },
        },
    };
    return node;
}

fn makeStringLiteral(self: *TypeChecker, line: usize, col: usize, val: []const u8) !*ASTNode {
    const node = try self.allocator.create(ASTNode);
    node.* = .{
        .line = line,
        .column = col,
        .resolved_type = null,
        .expected_type = null,
        .data = .{ .string_literal = val },
    };
    return node;
}

fn makeCall(self: *TypeChecker, line: usize, col: usize, callee_name: []const u8, args: []const *ASTNode, type_args: []const *const ast.ASTTypeRef) !*ASTNode {
    const callee = try makeIdent(self, line, col, callee_name);
    const node = try self.allocator.create(ASTNode);
    node.* = .{
        .line = line,
        .column = col,
        .resolved_type = null,
        .expected_type = null,
        .data = .{
            .call_expr = .{
                .callee = callee,
                .arguments = args,
                .type_args = type_args,
            },
        },
    };
    return node;
}

fn serdeBoxFor(self: *TypeChecker, line: usize, col: usize, tr: *const ast.ASTTypeRef, field_name: []const u8) anyerror!?*ASTNode {
    const field_ident = try makeIdent(self, line, col, field_name);
    const name = tr.name;

    if (std.mem.eql(u8, name, "Int")) {
        const args = try self.allocator.alloc(*ASTNode, 1);
        args[0] = field_ident;
        return try makeCall(self, line, col, "SerdeInt", args, &.{});
    } else if (std.mem.eql(u8, name, "Bool")) {
        const args = try self.allocator.alloc(*ASTNode, 1);
        args[0] = field_ident;
        return try makeCall(self, line, col, "SerdeBool", args, &.{});
    } else if (std.mem.eql(u8, name, "String")) {
        const args = try self.allocator.alloc(*ASTNode, 1);
        args[0] = field_ident;
        return try makeCall(self, line, col, "SerdeString", args, &.{});
    } else if (std.mem.eql(u8, name, "List") and tr.generic_args.len == 1) {
        const elem_tr = tr.generic_args[0];
        if (elem_tr.is_nullable) return null;

        const elem_name = elem_tr.name;
        var list_wrapper_name: ?[]const u8 = null;
        var needs_generic = false;

        if (std.mem.eql(u8, elem_name, "Int")) {
            list_wrapper_name = "SerdeIntList";
        } else if (std.mem.eql(u8, elem_name, "Bool")) {
            list_wrapper_name = "SerdeBoolList";
        } else if (std.mem.eql(u8, elem_name, "String")) {
            list_wrapper_name = "SerdeStringList";
        } else if (self.implementsContract(elem_name, "Serializable")) {
            list_wrapper_name = "SerdeObjectList";
            needs_generic = true;
        }

        if (list_wrapper_name) |wrapper| {
            const list_args = try self.allocator.alloc(*ASTNode, 1);
            list_args[0] = field_ident;

            var call_type_args: []const *const ast.ASTTypeRef = &.{};
            if (needs_generic) {
                const mono_elem_tr = try self.allocator.create(ast.ASTTypeRef);
                mono_elem_tr.* = .{
                    .name = elem_name,
                    .generic_args = &.{},
                    .is_array = false,
                    .is_nullable = false,
                };
                const t_args = try self.allocator.alloc(*const ast.ASTTypeRef, 1);
                t_args[0] = mono_elem_tr;
                call_type_args = t_args;
            }

            const list_inner_call = try makeCall(self, line, col, wrapper, list_args, call_type_args);
            const wrapper_args = try self.allocator.alloc(*ASTNode, 1);
            wrapper_args[0] = list_inner_call;
            return try makeCall(self, line, col, "SerdeListValue", wrapper_args, &.{});
        }
    } else if (self.implementsContract(name, "Serializable")) {
        const args = try self.allocator.alloc(*ASTNode, 1);
        args[0] = field_ident;
        return try makeCall(self, line, col, "SerdeObject", args, &.{});
    }

    return null;
}

pub fn injectAutoContractsAndSkills(self: *TypeChecker, c: anytype) !void {
    if (std.mem.eql(u8, c.name, "OpaquePointer") or std.mem.eql(u8, c.name, "Pointer")) return;

    for (auto_injected_contracts) |contract_name| {
        var exists = false;
        for (c.contracts) |existing| {
            if (std.mem.eql(u8, existing, contract_name)) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            var new_contracts = try self.allocator.alloc([]const u8, c.contracts.len + 1);
            for (c.contracts, 0..) |item, i| {
                new_contracts[i] = item;
            }
            new_contracts[c.contracts.len] = contract_name;
            c.contracts = new_contracts;
        }
    }

    const basename = std.fs.path.basename(self.filename);
    if (!std.mem.eql(u8, basename, "core.ei")) {
        for (auto_injected_skills) |skill_name| {
            var exists = false;
            for (c.skills) |existing| {
                if (std.mem.eql(u8, existing, skill_name)) {
                    exists = true;
                    break;
                }
            }
            if (!exists) {
                var new_skills = try self.allocator.alloc([]const u8, c.skills.len + 1);
                for (c.skills, 0..) |item, i| {
                    new_skills[i] = item;
                }
                new_skills[c.skills.len] = skill_name;
                c.skills = new_skills;
            }
        }
    }
}

fn makePlus(self: *TypeChecker, line: usize, col: usize, left: *ASTNode, right: *ASTNode) !*ASTNode {
    const node = try self.allocator.create(ASTNode);
    node.* = .{
        .line = line,
        .column = col,
        .resolved_type = null,
        .expected_type = null,
        .data = .{
            .binary_expr = .{
                .op = .plus,
                .left = left,
                .right = right,
            },
        },
    };
    return node;
}

fn makeBinaryOp(self: *TypeChecker, line: usize, col: usize, op: ast.TokenType, left: *ASTNode, right: *ASTNode) !*ASTNode {
    const node = try self.allocator.create(ASTNode);
    node.* = .{
        .line = line,
        .column = col,
        .resolved_type = null,
        .expected_type = null,
        .data = .{
            .binary_expr = .{
                .op = op,
                .left = left,
                .right = right,
            },
        },
    };
    return node;
}

fn makeIntLiteral(self: *TypeChecker, line: usize, col: usize, val: i64) !*ASTNode {
    const node = try self.allocator.create(ASTNode);
    node.* = .{
        .line = line,
        .column = col,
        .resolved_type = null,
        .expected_type = null,
        .data = .{ .int_literal = val },
    };
    return node;
}

fn makeBoolLiteral(self: *TypeChecker, line: usize, col: usize, val: bool) !*ASTNode {
    const node = try self.allocator.create(ASTNode);
    node.* = .{
        .line = line,
        .column = col,
        .resolved_type = null,
        .expected_type = null,
        .data = .{ .bool_literal = val },
    };
    return node;
}

fn makeMemberAccess(self: *TypeChecker, line: usize, col: usize, obj_name: []const u8, prop_name: []const u8) !*ASTNode {
    const obj_ident = try makeIdent(self, line, col, obj_name);
    const node = try self.allocator.create(ASTNode);
    node.* = .{
        .line = line,
        .column = col,
        .resolved_type = null,
        .expected_type = null,
        .data = .{
            .get_expr = .{
                .object = obj_ident,
                .name = prop_name,
                .is_safe = false,
            },
        },
    };
    return node;
}

fn makeMemberCall(self: *TypeChecker, line: usize, col: usize, obj_name: []const u8, prop_name: []const u8, method_name: []const u8, is_safe: bool) !*ASTNode {
    const member_acc = try makeMemberAccess(self, line, col, obj_name, prop_name);
    const callee = try self.allocator.create(ASTNode);
    callee.* = .{
        .line = line,
        .column = col,
        .resolved_type = null,
        .expected_type = null,
        .data = .{
            .get_expr = .{
                .object = member_acc,
                .name = method_name,
                .is_safe = is_safe,
            },
        },
    };
    const node = try self.allocator.create(ASTNode);
    node.* = .{
        .line = line,
        .column = col,
        .resolved_type = null,
        .expected_type = null,
        .data = .{
            .call_expr = .{
                .callee = callee,
                .arguments = &.{},
                .type_args = &.{},
            },
        },
    };
    return node;
}

fn makeMemberCallOrNullFallback(self: *TypeChecker, line: usize, col: usize, obj_name: []const u8, prop: anytype, method_name: []const u8, null_fallback: *ASTNode) !*ASTNode {
    const prop_rt = prop.resolved_type orelse try self.resolveTypeRef(prop.type_ref);
    const is_ptr_type = prop.type_ref.is_nullable or core.isNullable(prop_rt);
    if (!is_ptr_type) {
        return try makeMemberCall(self, line, col, obj_name, prop.name, method_name, false);
    }

    const val_call_safe = try makeMemberCall(self, line, col, obj_name, prop.name, method_name, true);
    const elvis_node = try self.allocator.create(ASTNode);
    elvis_node.* = .{
        .line = line,
        .column = col,
        .resolved_type = null,
        .expected_type = null,
        .data = .{
            .binary_expr = .{
                .left = val_call_safe,
                .op = .elvis,
                .right = null_fallback,
            },
        },
    };
    return elvis_node;
}

fn makeIsTypeCond(self: *TypeChecker, line: usize, col: usize, type_name: []const u8) !*ASTNode {
    const tr = try self.allocator.create(ast.ASTTypeRef);
    tr.* = .{
        .name = type_name,
        .generic_args = &.{},
        .is_array = false,
        .is_nullable = false,
    };
    const node = try self.allocator.create(ASTNode);
    node.* = .{
        .line = line,
        .column = col,
        .resolved_type = null,
        .expected_type = null,
        .data = .{
            .is_type_cond = .{
                .type_ref = tr,
                .is_not = false,
            },
        },
    };
    return node;
}

fn generateDefaultToString(self: *TypeChecker, node: *ASTNode, c: anytype) anyerror!void {
    if (std.mem.eql(u8, c.name, "Int") or std.mem.eql(u8, c.name, "Bool") or std.mem.eql(u8, c.name, "String") or std.mem.eql(u8, c.name, "Pointer") or std.mem.eql(u8, c.name, "OpaquePointer")) return;

    for (c.methods) |m| {
        if (m.data == .fun_decl and std.mem.eql(u8, m.data.fun_decl.name, "toString")) return;
    }

    var prop_count: usize = 0;
    for (c.primary_constructor) |prop| {
        if (prop.is_property) prop_count += 1;
    }

    var body_node: *ASTNode = undefined;
    if (prop_count == 0) {
        body_node = try makeStringLiteral(self, node.line, node.column, c.name);
    } else {
        const prefix_str = try std.fmt.allocPrint(self.allocator, "{s}(", .{c.name});
        var curr_expr = try makeStringLiteral(self, node.line, node.column, prefix_str);

        var is_first = true;
        for (c.primary_constructor) |prop| {
            if (!prop.is_property) continue;
            if (prop.type_ref.is_array or prop.type_ref.is_function or (prop.type_ref.resolved_type != null and prop.type_ref.resolved_type.?.* == .Function) or std.mem.indexOf(u8, prop.type_ref.name, "->") != null or std.mem.startsWith(u8, prop.type_ref.name, "fun")) continue;

            const label_str = try std.fmt.allocPrint(self.allocator, "{s}{s}=", .{ if (is_first) "" else ", ", prop.name });
            is_first = false;

            const label_lit = try makeStringLiteral(self, node.line, node.column, label_str);
            curr_expr = try makePlus(self, node.line, node.column, curr_expr, label_lit);

            const null_str = try makeStringLiteral(self, node.line, node.column, "null");
            const val_call = try makeMemberCallOrNullFallback(self, node.line, node.column, "this", prop, "toString", null_str);
            curr_expr = try makePlus(self, node.line, node.column, curr_expr, val_call);
        }

        const suffix_lit = try makeStringLiteral(self, node.line, node.column, ")");
        body_node = try makePlus(self, node.line, node.column, curr_expr, suffix_lit);
    }

    const ret_tr = try self.allocator.create(ast.ASTTypeRef);
    ret_tr.* = .{
        .name = "String",
        .generic_args = &.{},
        .is_array = false,
        .is_nullable = false,
    };

    const method_node = try self.allocator.create(ASTNode);
    method_node.* = .{
        .line = node.line,
        .column = node.column,
        .resolved_type = null,
        .expected_type = null,
        .data = .{
            .fun_decl = .{
                .annotations = &.{},
                .modifiers = &[_]ast.TokenType{ .kw_implement },
                .name = "toString",
                .generic_params = &[_][]const u8{},
                .params = &.{},
                .type_ref = ret_tr,
                .body = body_node,
                .is_expr_body = true,
                .resolved_c_name = null,
            },
        },
    };

    var new_methods = try self.allocator.alloc(*ASTNode, c.methods.len + 1);
    for (c.methods, 0..) |m, i| {
        new_methods[i] = m;
    }
    new_methods[c.methods.len] = method_node;
    c.methods = new_methods;
}

fn generateDefaultHashCode(self: *TypeChecker, node: *ASTNode, c: anytype) anyerror!void {
    if (std.mem.eql(u8, c.name, "Int") or std.mem.eql(u8, c.name, "Bool") or std.mem.eql(u8, c.name, "String") or std.mem.eql(u8, c.name, "Pointer") or std.mem.eql(u8, c.name, "OpaquePointer")) return;

    for (c.methods) |m| {
        if (m.data == .fun_decl and std.mem.eql(u8, m.data.fun_decl.name, "hashCode")) return;
    }

    var prop_count: usize = 0;
    for (c.primary_constructor) |prop| {
        if (prop.is_property) prop_count += 1;
    }

    var body_node: *ASTNode = undefined;
    if (prop_count == 0) {
        body_node = try makeIntLiteral(self, node.line, node.column, 0);
    } else {
        var curr_expr: ?*ASTNode = null;
        for (c.primary_constructor) |prop| {
            if (!prop.is_property) continue;
            if (prop.type_ref.is_array or prop.type_ref.is_function or (prop.type_ref.resolved_type != null and prop.type_ref.resolved_type.?.* == .Function) or std.mem.indexOf(u8, prop.type_ref.name, "->") != null or std.mem.startsWith(u8, prop.type_ref.name, "fun")) continue;

            const zero_int = try makeIntLiteral(self, node.line, node.column, 0);
            const hc_call = try makeMemberCallOrNullFallback(self, node.line, node.column, "this", prop, "hashCode", zero_int);
            if (curr_expr == null) {
                curr_expr = hc_call;
            } else {
                curr_expr = try makeBinaryOp(self, node.line, node.column, .plus, curr_expr.?, hc_call);
            }
        }
        body_node = curr_expr.?;
    }

    const ret_tr = try self.allocator.create(ast.ASTTypeRef);
    ret_tr.* = .{
        .name = "Int",
        .generic_args = &.{},
        .is_array = false,
        .is_nullable = false,
    };

    const method_node = try self.allocator.create(ASTNode);
    method_node.* = .{
        .line = node.line,
        .column = node.column,
        .resolved_type = null,
        .expected_type = null,
        .data = .{
            .fun_decl = .{
                .annotations = &.{},
                .modifiers = &[_]ast.TokenType{ .kw_implement },
                .name = "hashCode",
                .generic_params = &[_][]const u8{},
                .params = &.{},
                .type_ref = ret_tr,
                .body = body_node,
                .is_expr_body = true,
                .resolved_c_name = null,
            },
        },
    };

    var new_methods = try self.allocator.alloc(*ASTNode, c.methods.len + 1);
    for (c.methods, 0..) |m, i| {
        new_methods[i] = m;
    }
    new_methods[c.methods.len] = method_node;
    c.methods = new_methods;
}

fn generateDefaultEquals(self: *TypeChecker, node: *ASTNode, c: anytype) anyerror!void {
    if (std.mem.eql(u8, c.name, "Int") or std.mem.eql(u8, c.name, "Bool") or std.mem.eql(u8, c.name, "String") or std.mem.eql(u8, c.name, "Pointer") or std.mem.eql(u8, c.name, "OpaquePointer")) return;

    for (c.methods) |m| {
        if (m.data == .fun_decl and std.mem.eql(u8, m.data.fun_decl.name, "equals")) return;
    }

    var prop_count: usize = 0;
    for (c.primary_constructor) |prop| {
        if (prop.is_property) prop_count += 1;
    }

    var case_then_body: *ASTNode = undefined;
    if (prop_count == 0) {
        case_then_body = try makeBoolLiteral(self, node.line, node.column, true);
    } else {
        var curr_expr: ?*ASTNode = null;
        for (c.primary_constructor) |prop| {
            if (!prop.is_property) continue;
            if (prop.type_ref.is_array or prop.type_ref.is_function or (prop.type_ref.resolved_type != null and prop.type_ref.resolved_type.?.* == .Function) or std.mem.indexOf(u8, prop.type_ref.name, "->") != null or std.mem.startsWith(u8, prop.type_ref.name, "fun")) continue;

            const this_prop = try makeMemberAccess(self, node.line, node.column, "this", prop.name);
            const other_prop = try makeMemberAccess(self, node.line, node.column, "other", prop.name);
            const eq_expr = try makeBinaryOp(self, node.line, node.column, .eq_eq, this_prop, other_prop);

            if (curr_expr == null) {
                curr_expr = eq_expr;
            } else {
                curr_expr = try makeBinaryOp(self, node.line, node.column, .and_and, curr_expr.?, eq_expr);
            }
        }
        case_then_body = curr_expr.?;
    }

    const is_cond = try makeIsTypeCond(self, node.line, node.column, c.name);
    const conds = try self.allocator.alloc(*ASTNode, 1);
    conds[0] = is_cond;

    const case_is = ast.WhenCase{
        .conds = conds,
        .body = case_then_body,
        .is_else = false,
    };

    const case_else = ast.WhenCase{
        .conds = &.{},
        .body = try makeBoolLiteral(self, node.line, node.column, false),
        .is_else = true,
    };

    const cases = try self.allocator.alloc(ast.WhenCase, 2);
    cases[0] = case_is;
    cases[1] = case_else;

    const subj = try makeIdent(self, node.line, node.column, "other");
    const when_body = try self.allocator.create(ASTNode);
    when_body.* = .{
        .line = node.line,
        .column = node.column,
        .resolved_type = null,
        .expected_type = null,
        .data = .{
            .when_expr = .{
                .subject = subj,
                .cases = cases,
            },
        },
    };

    const param_tr = try self.allocator.create(ast.ASTTypeRef);
    param_tr.* = .{
        .name = "Stringable",
        .generic_args = &.{},
        .is_array = false,
        .is_nullable = false,
    };

    const ret_tr = try self.allocator.create(ast.ASTTypeRef);
    ret_tr.* = .{
        .name = "Bool",
        .generic_args = &.{},
        .is_array = false,
        .is_nullable = false,
    };

    const params = try self.allocator.alloc(ast.Param, 1);
    params[0] = .{
        .name = "other",
        .type_ref = param_tr,
        .initializer = null,
    };

    const method_node = try self.allocator.create(ASTNode);
    method_node.* = .{
        .line = node.line,
        .column = node.column,
        .resolved_type = null,
        .expected_type = null,
        .data = .{
            .fun_decl = .{
                .annotations = &.{},
                .modifiers = &[_]ast.TokenType{ .kw_implement, .kw_operator },
                .name = "equals",
                .generic_params = &[_][]const u8{},
                .params = params,
                .type_ref = ret_tr,
                .body = when_body,
                .is_expr_body = true,
                .resolved_c_name = null,
            },
        },
    };

    var new_methods = try self.allocator.alloc(*ASTNode, c.methods.len + 1);
    for (c.methods, 0..) |m, i| {
        new_methods[i] = m;
    }
    new_methods[c.methods.len] = method_node;
    c.methods = new_methods;
}

fn generateSerdeFields(self: *TypeChecker, node: *ASTNode, c: anytype) anyerror!void {
    if (!self.implementsContract(c.name, "Serializable")) return;

    for (c.methods) |m| {
        if (m.data == .fun_decl and std.mem.eql(u8, m.data.fun_decl.name, "serdeFields")) return;
    }

    var elems = ArrayList(*ASTNode).init(self.allocator);
    defer elems.deinit();

    if (std.mem.startsWith(u8, c.name, "collections_List_") or std.mem.startsWith(u8, c.name, "List_")) {
        var wrapper_name: []const u8 = "SerdeObjectList";
        if (std.mem.endsWith(u8, c.name, "_core_Int") or std.mem.endsWith(u8, c.name, "_Int")) {
            wrapper_name = "SerdeIntList";
        } else if (std.mem.endsWith(u8, c.name, "_core_Bool") or std.mem.endsWith(u8, c.name, "_Bool")) {
            wrapper_name = "SerdeBoolList";
        } else if (std.mem.endsWith(u8, c.name, "_core_String") or std.mem.endsWith(u8, c.name, "_String")) {
            wrapper_name = "SerdeStringList";
        }

        const this_ident = try self.allocator.create(ASTNode);
        this_ident.* = .{
            .line = node.line,
            .column = node.column,
            .resolved_type = null,
            .data = .{ .identifier = .{ .name = "this", .resolved_c_name = "this", .is_class_property = false } },
        };

        const list_args = try self.allocator.alloc(*ASTNode, 1);
        list_args[0] = this_ident;

        const list_inner_call = try makeCall(self, node.line, node.column, wrapper_name, list_args, &.{});
        const wrapper_args = try self.allocator.alloc(*ASTNode, 1);
        wrapper_args[0] = list_inner_call;
        const list_val = try makeCall(self, node.line, node.column, "SerdeListValue", wrapper_args, &.{});

        const field_args = try self.allocator.alloc(*ASTNode, 2);
        field_args[0] = try makeStringLiteral(self, node.line, node.column, "__list__");
        field_args[1] = list_val;

        const serde_field_call = try makeCall(self, node.line, node.column, "SerdeField", field_args, &.{});
        try elems.append(serde_field_call);
    } else {
        for (c.primary_constructor) |prop| {
            if (!prop.is_property) continue;
            if (prop.type_ref.is_nullable) continue;

            const boxed = try serdeBoxFor(self, node.line, node.column, prop.type_ref, prop.name) orelse continue;
            const field_args = try self.allocator.alloc(*ASTNode, 2);
            field_args[0] = try makeStringLiteral(self, node.line, node.column, prop.name);
            field_args[1] = boxed;

            const serde_field_call = try makeCall(self, node.line, node.column, "SerdeField", field_args, &.{});
            try elems.append(serde_field_call);
        }
    }

    const serde_field_type = try self.resolveTypeName("SerdeField", false);
    const list_c_name = self.alias_map.get("List") orelse "List";
    var mangled = ArrayList(u8).init(self.allocator);
    try mangled.appendSlice(list_c_name);
    try mangled.appendSlice("_");
    try serde_field_type.formatSafe(mangled.writer());
    const mangled_name = try mangled.toOwnedSlice();
    const list_serde_field_type = try self.allocator.create(EiwaType);
    list_serde_field_type.* = .{ .Custom = self.alias_map.get(mangled_name) orelse mangled_name };

    const arr_node = try self.allocator.create(ASTNode);
    arr_node.* = .{
        .line = node.line,
        .column = node.column,
        .resolved_type = null,
        .expected_type = list_serde_field_type,
        .data = .{
            .array_literal = .{
                .elements = try elems.toOwnedSlice(),
            },
        },
    };

    const sf_type_ref = try self.allocator.create(ast.ASTTypeRef);
    sf_type_ref.* = .{
        .name = "SerdeField",
        .generic_args = &.{},
        .is_array = false,
        .is_nullable = false,
    };
    const list_ret_type_args = try self.allocator.alloc(*const ast.ASTTypeRef, 1);
    list_ret_type_args[0] = sf_type_ref;

    const list_ret_type_ref = try self.allocator.create(ast.ASTTypeRef);
    list_ret_type_ref.* = .{
        .name = "List",
        .generic_args = list_ret_type_args,
        .is_array = false,
        .is_nullable = false,
    };

    const method_node = try self.allocator.create(ASTNode);
    method_node.* = .{
        .line = node.line,
        .column = node.column,
        .resolved_type = null,
        .expected_type = null,
        .data = .{
            .fun_decl = .{
                .annotations = &.{},
                .modifiers = &[_]ast.TokenType{ .kw_implement },
                .name = "serdeFields",
                .generic_params = &[_][]const u8{},
                .params = &.{},
                .type_ref = list_ret_type_ref,
                .body = arr_node,
                .is_expr_body = true,
                .resolved_c_name = null,
            },
        },
    };

    var new_methods = try self.allocator.alloc(*ASTNode, c.methods.len + 1);
    for (c.methods, 0..) |m, i| {
        new_methods[i] = m;
    }
    new_methods[c.methods.len] = method_node;
    c.methods = new_methods;
}

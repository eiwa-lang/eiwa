const std = @import("std");
const compat = @import("../compat.zig");
const ArrayList = compat.ArrayList;
const ast = @import("../ast.zig");
const parser_mod = @import("../../frontend/parser/core.zig");
const type_system = @import("../type_system.zig");
const diagnostics = @import("../diagnostics.zig");

pub const ASTNode = ast.ASTNode;
pub const EiwaType = type_system.EiwaType;
pub const Scope = type_system.Scope;
pub const TargetInfo = @import("../target.zig").TargetInfo;

const infer_expr_mod = @import("infer_expr.zig");
const infer_stmt_mod = @import("infer_stmt.zig");
const infer_decl_mod = @import("infer_decl.zig");
const infer_when_mod = @import("infer_when.zig");
const infer_call_mod = @import("infer_call.zig");
pub const isNullable = type_system.isNullable;
pub const isNullableScalar = type_system.isNullableScalar;
pub const extractBaseType = type_system.extractBaseType;
pub const stripNull = type_system.stripNull;
pub const isBool = type_system.isBool;

/// Detect `s != null` / `s == null` over an identifier; `then_narrowed` selects the narrowed branch.
pub const NullCheck = struct {
    name: []const u8,
    then_narrowed: bool,
};

pub fn matchNullCheck(cond: *ASTNode) ?NullCheck {
    if (cond.data != .binary_expr) return null;
    const b = cond.data.binary_expr;
    const then_narrowed = switch (b.op) {
        .bang_eq => true,
        .eq_eq => false,
        else => return null,
    };
    if (b.left.data == .identifier and b.right.data == .null_literal) {
        return .{ .name = b.left.data.identifier.name, .then_narrowed = then_narrowed };
    }
    if (b.right.data == .identifier and b.left.data == .null_literal) {
        return .{ .name = b.right.data.identifier.name, .then_narrowed = then_narrowed };
    }
    return null;
}

pub fn collectThenNarrowings(cond: *ASTNode, out: *ArrayList([]const u8)) !void {
    return collectChainNarrowings(cond, out, .and_and, true);
}

pub fn collectElseNarrowings(cond: *ASTNode, out: *ArrayList([]const u8)) !void {
    return collectChainNarrowings(cond, out, .or_or, false);
}

fn collectChainNarrowings(cond: *ASTNode, out: *ArrayList([]const u8), chain_op: ast.TokenType, want_then: bool) !void {
    if (cond.data == .binary_expr and cond.data.binary_expr.op == chain_op) {
        try collectChainNarrowings(cond.data.binary_expr.left, out, chain_op, want_then);
        try collectChainNarrowings(cond.data.binary_expr.right, out, chain_op, want_then);
        return;
    }
    if (matchNullCheck(cond)) |nc| {
        if (nc.then_narrowed == want_then) try out.append(nc.name);
    }
}

fn core_applyNarrowings(self: *TypeChecker, scope: *Scope, local: *Scope, names: []const []const u8) !bool {
    var any = false;
    for (names) |nm| {
        if (try self.narrowedBinding(scope, nm)) |narrowed| {
            try self.defineNarrowed(local, nm, narrowed);
            any = true;
        }
    }
    return any;
}

pub const ModuleRegistry = struct {
    allocator: std.mem.Allocator,
    modules: std.StringHashMap(ModuleState),
    ordered_modules: ArrayList([]const u8),

    pub const ModuleState = struct {
        filename: []const u8,
        source: []const u8,
        ast_root: *ASTNode,
        checker: *TypeChecker,
        module_prefix: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) ModuleRegistry {
        return .{
            .allocator = allocator,
            .modules = std.StringHashMap(ModuleState).init(allocator),
            .ordered_modules = ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *ModuleRegistry) void {
        var it = self.modules.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.checker.deinit();
            self.allocator.destroy(entry.value_ptr.checker);
        }
        self.modules.deinit();
        self.ordered_modules.deinit();
    }
};

pub const TypeChecker = struct {
    allocator: std.mem.Allocator,
    io: std.Io = undefined,
    global_scope: Scope,
    source: []const u8,
    filename: []const u8,
    alias_map: std.StringHashMap([]const u8),
    module_prefix: ?[]const u8 = null,
    is_test_mode: bool = false,
    current_class_props: ?*std.StringHashMap(void) = null,
    classes_ast: std.StringHashMap(*ASTNode),
    objects_ast: std.StringHashMap(*ASTNode),
    contracts_ast: std.StringHashMap(*ASTNode),
    skills_ast: std.StringHashMap(*ASTNode),
    enums_ast: std.StringHashMap(*ASTNode),
    libs_ast: std.StringHashMap(*ASTNode),
    functions_ast: std.StringHashMap(*ASTNode),
    generic_functions_ast: std.StringHashMap(ArrayList(*ASTNode)),
    extension_functions: std.StringHashMap(ArrayList(*ASTNode)),
    imported_extension_names: std.StringHashMap(void),
    /// `cFunctionPtr(fn)` trampolines: C name -> the fun_decl node it forwards to.
    trampolines: std.StringHashMap(*ASTNode),
    local_symbols: std.StringHashMap(void),
    lib_symbols: std.StringHashMap(void),
    monomorphized_nodes: ArrayList(*ASTNode),
    current_class_name: ?[]const u8 = null,
    current_class_methods: ?[]const *ASTNode = null,
    current_type_c_name: ?[]const u8 = null,
    current_fn_return: ?*const EiwaType = null,
    /// While > 0, diagnostics stay silent (speculative resolutions).
    speculative_depth: usize = 0,
    registry: ?*ModuleRegistry = null,
    target_info: ?TargetInfo = null,
    pass: enum { declaration, validation } = .validation,
    status: enum { unvisited, declaring_types, declared_types, declaring_signatures, declared_signatures, resolving_imports, resolved_imports, validating, validated } = .unvisited,
    /// While > 0, stylistic warnings stay silent (clones misattribute positions).
    monomorph_depth: usize = 0,
    /// While > 0, unreachable-code warnings stay silent (not user mistake).
    synthetic_depth: usize = 0,

    pub const inferNode = core_inferNode;
    pub const reportError = core_reportError;
    pub const reportWarning = core_reportWarning;
    pub const defineNarrowed = core_defineNarrowed;
    pub const applyNarrowings = core_applyNarrowings;
    pub const narrowedBinding = core_narrowedBinding;
    pub const resolveTypeRef = core_resolveTypeRef;
    pub const cloneTypeRef = @import("clone.zig").cloneTypeRef;
    pub const resolveTypeName = core_resolveTypeName;
    pub const monomorphizeClass = @import("monomorphize.zig").monomorphizeClass;
    pub const monomorphizeFunction = @import("monomorphize.zig").monomorphizeFunction;
    pub const lookupGenericFunction = @import("monomorphize.zig").lookupGenericFunction;
    pub const makeListType = core_makeListType;
    pub const cloneNode = @import("clone.zig").cloneNode;
    pub const validate = core_validate;
    pub const declareTypes = core_declareTypes;
    pub const declareSignatures = core_declareSignatures;
    pub const resolveImports = core_resolveImports;
    pub const checkBlock = infer_stmt_mod.checkBlock;
    pub const findUndeclaredTypeArg = core_findUndeclaredTypeArg;
    pub const uniqueEnumVariantOwner = core_uniqueEnumVariantOwner;
    pub const countEnumVariantOwners = core_countEnumVariantOwners;
    pub const typeHasEnum = core_typeHasEnum;
    pub const checkGenericTypeArgs = core_checkGenericTypeArgs;
    pub const resolveHintTypeRef = core_resolveHintTypeRef;
    pub const resolveHintTypeName = core_resolveHintTypeName;
    pub const inferBlockAsExpression = infer_stmt_mod.inferBlockAsExpression;
    pub const inferBranchAsExpression = infer_stmt_mod.inferBranchAsExpression;
    pub const isCompatible = core_isCompatible;
    pub const conformsTo = core_conformsTo;
    pub const implementsContract = core_implementsContract;
    pub const injectImplicitImports = core_injectImplicitImports;
    pub const substituteParam = infer_call_mod.substituteParam;

    pub fn matchesTarget(self: *const TypeChecker, platform_targets: []const []const u8) bool {
        if (platform_targets.len == 0) return true;
        if (self.target_info) |ti| {
            return ti.matchesAny(platform_targets);
        }
        return true;
    }

    pub fn init(allocator: std.mem.Allocator, source: []const u8, filename: []const u8) TypeChecker {
        const checker = TypeChecker{
            .allocator = allocator,
            .global_scope = Scope.init(allocator, null),
            .source = source,
            .filename = filename,
            .alias_map = std.StringHashMap([]const u8).init(allocator),
            .module_prefix = null,
            .is_test_mode = false,
            .current_class_props = null,
            .classes_ast = std.StringHashMap(*ASTNode).init(allocator),
            .objects_ast = std.StringHashMap(*ASTNode).init(allocator),
            .contracts_ast = std.StringHashMap(*ASTNode).init(allocator),
            .skills_ast = std.StringHashMap(*ASTNode).init(allocator),
            .enums_ast = std.StringHashMap(*ASTNode).init(allocator),
            .libs_ast = std.StringHashMap(*ASTNode).init(allocator),
            .functions_ast = std.StringHashMap(*ASTNode).init(allocator),
            .generic_functions_ast = std.StringHashMap(ArrayList(*ASTNode)).init(allocator),
            .extension_functions = std.StringHashMap(ArrayList(*ASTNode)).init(allocator),
            .imported_extension_names = std.StringHashMap(void).init(allocator),
            .trampolines = std.StringHashMap(*ASTNode).init(allocator),
            .local_symbols = std.StringHashMap(void).init(allocator),
            .lib_symbols = std.StringHashMap(void).init(allocator),
            .monomorphized_nodes = ArrayList(*ASTNode).init(allocator),
            .current_class_name = null,
            .registry = null,
            .target_info = null,
            .pass = .validation,
            .status = .unvisited,
        };
        return checker;
    }

    pub fn deinit(self: *TypeChecker) void {
        self.global_scope.deinit();
        self.alias_map.deinit();
        self.classes_ast.deinit();
        self.objects_ast.deinit();
        self.contracts_ast.deinit();
        self.skills_ast.deinit();
        self.enums_ast.deinit();
        self.libs_ast.deinit();
        self.functions_ast.deinit();
        var gen_it = self.generic_functions_ast.iterator();
        while (gen_it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.generic_functions_ast.deinit();
        var ext_it = self.extension_functions.iterator();
        while (ext_it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.extension_functions.deinit();
        self.imported_extension_names.deinit();
        self.local_symbols.deinit();
        self.lib_symbols.deinit();
        self.monomorphized_nodes.deinit();
    }
};

pub var module_search_paths: []const []const u8 = &.{};
pub var module_root: []const u8 = ".";
pub var module_search_io: ?std.Io = null;

fn pathExists(path: []const u8) bool {
    const io = module_search_io orelse return false;
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Returns the library source root that `dir_path` (a module's parent
/// directory) belongs to, if any. This lets a leading-dot (root-relative)
/// import inside a dependency resolve against that dependency's own source
/// root rather than the entry project's root. Falls back to null when the
/// module lives in the entry project itself.
fn findLibraryRoot(dir: []const u8) ?[]const u8 {
    for (module_search_paths) |search_dir| {
        if (std.mem.eql(u8, dir, search_dir)) return search_dir;
        if (std.mem.startsWith(u8, dir, search_dir)) {
            const rest = dir[search_dir.len..];
            if (rest.len > 0 and std.mem.startsWith(u8, rest, "/")) {
                return search_dir;
            }
        }
    }
    return null;
}

/// Converts a dot-separated module path into a filesystem-relative path.
/// e.g. "mcp.mcp_builder" -> "mcp/mcp_builder.ei", "foo.ei" -> "foo.ei".
fn modulePathToFile(allocator: std.mem.Allocator, mod_path: []const u8) ![]const u8 {
    var path = mod_path;
    if (std.mem.endsWith(u8, path, ".ei")) {
        path = path[0 .. path.len - 3];
    }
    var buf = ArrayList(u8).init(allocator);
    defer buf.deinit();
    for (path) |c| {
        try buf.append(if (c == '.') '/' else c);
    }
    try buf.appendSlice(".ei");
    return buf.toOwnedSlice();
}

/// Canonicalizes a resolved module path to forward slashes so the same
/// physical file always maps to the same module key on every OS. On Windows
/// `std.fs.path.join` mixes backslashes (native separator) with forward
/// slashes (from the dot-separated module path), so the same file could be
/// loaded under two different keys — tripping "Duplicate type declaration".
fn canonicalModulePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, path, '\\') == null) return path;
    var buf = try allocator.alloc(u8, path.len);
    for (path, 0..) |c, i| buf[i] = if (c == '\\') '/' else c;
    return buf;
}

pub fn resolveModulePath(allocator: std.mem.Allocator, dir_path: []const u8, actual_module_path: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, actual_module_path, "std.")) {
        var pkg_name = actual_module_path[4..];
        if (std.mem.endsWith(u8, pkg_name, ".ei")) {
            pkg_name = pkg_name[0 .. pkg_name.len - 3];
        }
        const pkg_buf = try allocator.alloc(u8, pkg_name.len);
        @memcpy(pkg_buf, pkg_name);
        for (pkg_buf) |*ch| {
            if (ch.* == '.') ch.* = '/';
        }
        return try std.fmt.allocPrint(allocator, "std/{s}.ei", .{pkg_buf});
    }

    // Module paths are dot-separated. Filesystem-style separators and
    // parent/current-relative prefixes are not allowed.
    if (std.mem.startsWith(u8, actual_module_path, "..") or
        std.mem.startsWith(u8, actual_module_path, "./") or
        std.mem.indexOfScalar(u8, actual_module_path, '/') != null)
    {
        return error.InvalidModulePath;
    }

    // Root-relative: a leading '.' resolves against the root of the library
    // the importing module belongs to (a dependency's source root), or the
    // project root when the module is part of the entry project.
    // ".arest_builder" -> <library-or-project root>/arest_builder.ei
    if (std.mem.startsWith(u8, actual_module_path, ".")) {
        if (actual_module_path.len == 1) return error.InvalidModulePath;
        const inner = actual_module_path[1..];
        const file_path = try modulePathToFile(allocator, inner);
        const root = findLibraryRoot(dir_path) orelse module_root;
        const joined = try std.fs.path.join(allocator, &.{ root, file_path });
        // Project sources conventionally live in src/ (entry src/main.ei),
        // but test files compile with the project root as module_root. Fall
        // back to src/ when the root-relative path does not exist, so tests
        // can import project sources with the same "." paths used in src/.
        if (!std.mem.eql(u8, root, "src") and !pathExists(joined)) {
            const src_candidate = try std.fs.path.join(allocator, &.{ "src", file_path });
            if (pathExists(src_candidate)) {
                return try canonicalModulePath(allocator, src_candidate);
            }
        }
        return try canonicalModulePath(allocator, joined);
    }

    // Bare module path: resolve relative to the importing file's directory,
    // falling back to the configured module search paths (dependencies).
    const file_path = try modulePathToFile(allocator, actual_module_path);
    const relative = if (std.mem.eql(u8, dir_path, "."))
        file_path
    else
        try std.fs.path.join(allocator, &.{ dir_path, file_path });

    if (module_search_paths.len == 0) {
        return try canonicalModulePath(allocator, relative);
    }
    if (pathExists(relative)) {
        return try canonicalModulePath(allocator, relative);
    }
    for (module_search_paths) |search_dir| {
        const candidate = try std.fs.path.join(allocator, &.{ search_dir, file_path });
        if (pathExists(candidate)) {
            return try canonicalModulePath(allocator, candidate);
        }
    }
    return try canonicalModulePath(allocator, relative);
}

/// Builds the monomorphized `List<T>` type used for a varargs parameter (`T...`)
/// and for synthetic varargs array literals at call sites. Mirrors the array-literal path.
fn core_makeListType(self: *TypeChecker, elem: *const EiwaType, line: usize, col: usize) !*EiwaType {
    const list_c_name = self.alias_map.get("List") orelse "List";
    const class_node = self.classes_ast.get(list_c_name) orelse {
        self.reportError(line, col, "TypeError: Class 'List' not found for varargs parameter.", .{});
        return error.TypeError;
    };
    const type_decl = class_node.data.type_decl;
    var type_args = try self.allocator.alloc(*const EiwaType, 1);
    type_args[0] = elem;
    var mangled = ArrayList(u8).init(self.allocator);
    try mangled.appendSlice(list_c_name);
    try mangled.appendSlice("_");
    try elem.formatSafe(mangled.writer());
    const mangled_name = try mangled.toOwnedSlice();
    try self.monomorphizeClass(type_decl.name, type_args, mangled_name);
    const t = try self.allocator.create(EiwaType);
    t.* = .{ .Custom = self.alias_map.get(mangled_name) orelse mangled_name };
    return t;
}

fn core_reportError(self: *TypeChecker, line: usize, column: usize, comptime message: []const u8, args: anytype) void {
    if (self.speculative_depth > 0) return;
    const cleaned_message = comptime blk: {
        if (std.mem.startsWith(u8, message, "TypeError: ")) {
            break :blk message["TypeError: ".len..];
        } else if (std.mem.startsWith(u8, message, "Syntax Error: ")) {
            break :blk message["Syntax Error: ".len..];
        }
        break :blk message;
    };
    diagnostics.printDiagnostic(
        self.filename,
        line,
        column,
        .err,
        cleaned_message,
        args,
        self.source,
        null,
    );
}

fn core_reportWarning(self: *TypeChecker, line: usize, column: usize, comptime message: []const u8, args: anytype) void {
    if (self.speculative_depth > 0) return;
    if (self.monomorph_depth > 0) return;
    diagnostics.printDiagnostic(
        self.filename,
        line,
        column,
        .warning,
        message,
        args,
        self.source,
        null,
    );
}

/// Force-rebind for narrowing (`Scope.define` is a no-op on compatible redefinition).
/// Val-only, reference-only narrowing: `None` for `var`s, non-nullables and heap-boxed scalars.
fn core_narrowedBinding(self: *TypeChecker, scope: *Scope, name: []const u8) !?*const EiwaType {
    const vs = scope.lookupVariableSymbol(name) orelse return null;
    if (vs.is_mut or !isNullable(vs.eiwa_type) or isNullableScalar(vs.eiwa_type)) return null;
    const narrowed = try self.allocator.create(EiwaType);
    narrowed.* = stripNull(vs.eiwa_type).*;
    return narrowed;
}

fn core_defineNarrowed(self: *TypeChecker, scope: *Scope, name: []const u8, narrowed: *const EiwaType) !void {
    _ = self;
    if (scope.symbols.getPtr(name)) |sym_ptr| {
        var sym = sym_ptr.*;
        if (sym.variable) |v| {
            var new_v = v;
            new_v.eiwa_type = narrowed;
            new_v.is_narrowed = true;
            sym.variable = new_v;
            sym_ptr.* = sym;
            return;
        }
    }
    try scope.define(name, narrowed, false, false);
    if (scope.symbols.getPtr(name)) |sym_ptr| {
        var sym = sym_ptr.*;
        if (sym.variable) |v| {
            var new_v = v;
            new_v.is_narrowed = true;
            sym.variable = new_v;
            sym_ptr.* = sym;
        }
    }
}

fn core_resolveTypeRef(self: *TypeChecker, ref: *const ast.ASTTypeRef) anyerror!*EiwaType {
    var base_type: EiwaType = .Void;
    var actual_is_nullable = ref.is_nullable;

    if (ref.union_types.len > 0) {
        var acc = try self.resolveTypeRef(ref.union_types[0]);
        for (ref.union_types[1..]) |u_item| {
            const resolved_u = try self.resolveTypeRef(u_item);
            const union_t = try self.allocator.create(EiwaType);
            union_t.* = .{ .Union = .{
                .left = acc,
                .right = resolved_u,
            } };
            acc = union_t;
        }
        base_type = acc.*;
    } else if (ref.is_function) {
        var params = ArrayList(*const EiwaType).init(self.allocator);
        for (ref.generic_args) |arg| {
            try params.append(try self.resolveTypeRef(arg));
        }
        const ret_t = try self.resolveTypeRef(ref.return_type.?);
        const rec_t = if (ref.receiver_type) |rec| try self.resolveTypeRef(rec) else null;

        base_type = .{ .Function = .{
            .params = try params.toOwnedSlice(),
            .return_type = ret_t,
            .receiver = rec_t,
            .c_name = "",
        } };
    } else if (ref.is_array) {
        if (ref.generic_args.len != 1) return error.TypeError;
        const inner_type = try self.resolveTypeRef(ref.generic_args[0]);

        if (self.pass == .validation and self.classes_ast.contains(self.alias_map.get("List") orelse "List")) {
            if (self.findUndeclaredTypeArg(inner_type, &.{})) |bad| {
                if (self.speculative_depth == 0) {
                    self.reportError(0, 0, "TypeError: Type '{s}' not found.", .{bad});
                }
                return error.TypeError;
            }
        }

        const list_base = "List";
        const type_args = try self.allocator.alloc(*const EiwaType, 1);
        type_args[0] = inner_type;

        var mangled = ArrayList(u8).init(self.allocator);
        const resolved_base = self.alias_map.get(list_base) orelse list_base;
        try mangled.appendSlice(resolved_base);
        try mangled.appendSlice("_");
        try inner_type.formatSafe(mangled.writer());
        const mangled_name = try mangled.toOwnedSlice();

        try self.monomorphizeClass(resolved_base, type_args, mangled_name);

        const actual_mangled = self.alias_map.get(mangled_name) orelse mangled_name;
        base_type = .{ .Custom = actual_mangled };
    } else {
        var alias = self.alias_map.get(ref.name) orelse ref.name;
        if (!self.classes_ast.contains(alias)) {
            if (std.mem.endsWith(u8, alias, "?")) {
                actual_is_nullable = true;
                alias = alias[0 .. alias.len - 1];
            } else if (std.mem.endsWith(u8, alias, "Opt")) {
                actual_is_nullable = true;
                alias = alias[0 .. alias.len - 3];
            }
        }

        // Check primitives first
        if (std.mem.eql(u8, alias, "Int") or std.mem.eql(u8, alias, "core_Int")) {
            base_type = .Int;
        } else if (std.mem.eql(u8, alias, "Double") or std.mem.eql(u8, alias, "core_Double")) {
            base_type = .Double;
        } else if (std.mem.eql(u8, alias, "Bool") or std.mem.eql(u8, alias, "core_Bool")) {
            base_type = .Bool;
        } else if (std.mem.eql(u8, alias, "String") or std.mem.eql(u8, alias, "core_String")) {
            base_type = .String;
        } else if (std.mem.eql(u8, alias, "Void") or std.mem.eql(u8, alias, "core_Void")) {
            base_type = .Void;
        } else if (std.mem.eql(u8, alias, "Pointer")) {
            base_type = .{ .Pointer = try self.allocator.create(EiwaType) };
            @constCast(base_type.Pointer).* = .Void;
        } else if (std.mem.eql(u8, alias, "Null")) {
            base_type = .Null;
        } else if (ref.generic_args.len > 0) {
            var args_list = ArrayList(*const EiwaType).init(self.allocator);
            for (ref.generic_args) |arg| {
                const arg_type = try self.resolveTypeRef(arg);
                try args_list.append(arg_type);
            }
            const type_args = try args_list.toOwnedSlice();

            if (std.mem.eql(u8, alias, "NativeArray")) {
                if (type_args.len != 1) return error.TypeError;
                base_type = .{ .Array = type_args[0] };
            } else if (std.mem.eql(u8, alias, "Pointer")) {
                if (type_args.len != 1) return error.TypeError;
                base_type = .{ .Pointer = type_args[0] };
            } else {
                base_type = .{ .GenericInstance = .{ .base_name = alias, .type_args = type_args } };

                const actual_base = self.alias_map.get(alias) orelse alias;
                var mangled = ArrayList(u8).init(self.allocator);
                try mangled.appendSlice(actual_base);
                try mangled.appendSlice("_");
                for (type_args, 0..) |t_arg, i| {
                    if (i > 0) try mangled.appendSlice("_");
                    try t_arg.formatSafe(mangled.writer());
                }
                const mangled_name = try mangled.toOwnedSlice();

                // Check if any type arg is an unresolved generic parameter
                var has_unresolved_generic = false;
                if (self.classes_ast.get(actual_base)) |base_node| {
                    if (base_node.data == .type_decl) {
                        const base_decl = base_node.data.type_decl;
                        for (type_args) |t_arg| {
                            if (t_arg.* == .Custom) {
                                for (base_decl.generic_params) |gp| {
                                    if (std.mem.eql(u8, t_arg.Custom, gp)) {
                                        has_unresolved_generic = true;
                                        break;
                                    }
                                }
                            }
                            if (has_unresolved_generic) break;
                        }
                    }
                }
                // Contracts are pure signatures: never monomorphize them.
                // Keep the GenericInstance so member lookup can substitute
                // the contract's generic params with the concrete type args.
                const is_contract = self.contracts_ast.contains(actual_base);
                if (self.pass == .validation) {
                    try self.checkGenericTypeArgs(actual_base, type_args, 0, 0);
                }
                if (is_contract) {
                    base_type = .{ .GenericInstance = .{ .base_name = actual_base, .type_args = type_args } };
                } else {
                    if (!has_unresolved_generic) {
                        try self.monomorphizeClass(alias, type_args, mangled_name);
                    }

                    const actual_mangled = self.alias_map.get(mangled_name) orelse if (has_unresolved_generic) alias else mangled_name;
                    base_type = .{ .Custom = actual_mangled };
                }
            }
        } else if (self.classes_ast.contains(alias) or (self.alias_map.get(alias) != null and self.classes_ast.contains(self.alias_map.get(alias).?))) {
            const actual_class = self.alias_map.get(alias) orelse alias;
            base_type = .{ .Custom = actual_class };
        } else if (std.mem.indexOf(u8, alias, "_or_") != null or std.mem.indexOf(u8, alias, " | ") != null) {
            const sep = if (std.mem.indexOf(u8, alias, "_or_") != null) "_or_" else " | ";
            const sep_idx = std.mem.indexOf(u8, alias, sep).?;
            var raw_p1 = alias[0..sep_idx];
            var raw_p2 = alias[sep_idx + sep.len ..];
            const t1 = self.resolveHintTypeName(raw_p1, false) orelse (if (std.mem.startsWith(u8, raw_p1, "core_")) self.resolveHintTypeName(raw_p1[5..], false) else null);
            const t2 = self.resolveHintTypeName(raw_p2, false) orelse (if (std.mem.startsWith(u8, raw_p2, "core_")) self.resolveHintTypeName(raw_p2[5..], false) else null);
            if (t1 != null and t2 != null) {
                const union_t = try self.allocator.create(EiwaType);
                union_t.* = .{ .Union = .{ .left = t1.?, .right = t2.? } };
                base_type = union_t.*;
            } else {
                base_type = .{ .Custom = alias };
            }
        } else if (self.global_scope.lookupVariable(alias)) |found_t| {
            base_type = found_t.*;
        } else {
            base_type = .{ .Custom = alias };
        }
    }

    const t = try self.allocator.create(EiwaType);
    if (actual_is_nullable) {
        t.* = .{ .Union = .{
            .left = try self.allocator.create(EiwaType),
            .right = try self.allocator.create(EiwaType),
        } };
        @constCast(t.Union.left).* = base_type;
        @constCast(t.Union.right).* = .Null;
    } else {
        t.* = base_type;
    }
    @constCast(ref).resolved_type = t;
    return t;
}

fn core_resolveTypeName(self: *TypeChecker, name: []const u8, is_nullable: bool) anyerror!*EiwaType {
    var p = parser_mod.Parser.init(self.allocator, name);
    const ref = try p.parseType();
    if (is_nullable) {
        @constCast(ref).is_nullable = true;
    }
    return try self.resolveTypeRef(ref);
}

fn core_resolveHintTypeRef(self: *TypeChecker, ref: *const ast.ASTTypeRef) ?*const EiwaType {
    self.speculative_depth += 1;
    defer self.speculative_depth -= 1;
    return self.resolveTypeRef(ref) catch null;
}

fn core_resolveHintTypeName(self: *TypeChecker, name: []const u8, is_nullable: bool) ?*const EiwaType {
    self.speculative_depth += 1;
    defer self.speculative_depth -= 1;
    return self.resolveTypeName(name, is_nullable) catch null;
}

fn core_checkGenericTypeArgs(self: *TypeChecker, base_actual: []const u8, type_args: []const *const EiwaType, line: usize, column: usize) anyerror!void {
    var base_params: []const []const u8 = &.{};
    var base_known = false;
    if (self.classes_ast.get(base_actual)) |base_node| {
        if (base_node.data == .type_decl) {
            base_known = true;
            base_params = base_node.data.type_decl.generic_params;
        }
    } else if (self.contracts_ast.get(base_actual)) |contract_node| {
        if (contract_node.data == .contract_decl) {
            base_known = true;
            base_params = contract_node.data.contract_decl.generic_params;
        }
    }
    if (!base_known) return;
    for (type_args) |t_arg| {
        if (self.findUndeclaredTypeArg(t_arg, base_params)) |bad| {
            // Silent inside speculative hint resolutions (see
            // speculative_depth): only authoritative positions diagnose.
            if (self.speculative_depth == 0) {
                self.reportError(line, column, "TypeError: Type '{s}' not found.", .{bad});
            }
            return error.TypeError;
        }
    }
}

fn core_findUndeclaredTypeArg(self: *TypeChecker, t: *const EiwaType, base_params: []const []const u8) ?[]const u8 {    switch (t.*) {
        .Custom => |name| {
            for (base_params) |gp| {
                if (std.mem.eql(u8, name, gp)) return null;
            }
            const actual = self.alias_map.get(name) orelse name;
            if (self.classes_ast.contains(actual)) return null;
            if (self.enums_ast.contains(actual)) return null;
            if (self.contracts_ast.contains(actual)) return null;
            if (self.skills_ast.contains(actual)) return null;
            if (self.objects_ast.contains(actual)) return null;
            return name;
        },
        .GenericParam, .Unknown => return null,
        .Union => |u| {
            if (self.findUndeclaredTypeArg(u.left, base_params)) |bad| return bad;
            return self.findUndeclaredTypeArg(u.right, base_params);
        },
        .Array => |elem| return self.findUndeclaredTypeArg(elem, base_params),
        .Pointer => |inner| return self.findUndeclaredTypeArg(inner, base_params),
        .Function => |f| {
            for (f.params) |p| {
                if (self.findUndeclaredTypeArg(p, base_params)) |bad| return bad;
            }
            if (self.findUndeclaredTypeArg(f.return_type, base_params)) |bad| return bad;
            if (f.receiver) |rec| {
                if (self.findUndeclaredTypeArg(rec, base_params)) |bad| return bad;
            }
            return null;
        },
        // Nested instances were validated by their own resolution.
        else => return null,
    }
}

fn core_uniqueEnumVariantOwner(self: *TypeChecker, expected: *const EiwaType, variant: []const u8) ?[]const u8 {
    var first: ?[]const u8 = null;
    var second = false;
    countOwners(self, expected, variant, &first, &second);
    if (second) return null;
    return first;
}

fn core_typeHasEnum(self: *TypeChecker, t: *const EiwaType) bool {
    switch (t.*) {
        .Custom => |name| {
            const actual = self.alias_map.get(name) orelse name;
            return self.enums_ast.contains(actual);
        },
        .Union => |u| return self.typeHasEnum(u.left) or self.typeHasEnum(u.right),
        else => return false,
    }
}

fn core_countEnumVariantOwners(self: *TypeChecker, expected: *const EiwaType, variant: []const u8) usize {
    var first: ?[]const u8 = null;
    var second = false;
    countOwners(self, expected, variant, &first, &second);
    if (second) return 2;
    return if (first != null) 1 else 0;
}

fn countOwners(self: *TypeChecker, t: *const EiwaType, variant: []const u8, first: *?[]const u8, second: *bool) void {
    switch (t.*) {
        .Custom => |name| {
            const actual = self.alias_map.get(name) orelse name;
            const enum_node = self.enums_ast.get(actual) orelse return;
            for (enum_node.data.enum_decl.variants) |v| {
                if (!std.mem.eql(u8, v.name, variant)) continue;
                if (first.*) |prev| {
                    if (!std.mem.eql(u8, prev, actual)) second.* = true;
                    return;
                }
                first.* = actual;
                return;
            }
        },
        .Union => |u| {
            countOwners(self, u.left, variant, first, second);
            if (second.*) return;
            countOwners(self, u.right, variant, first, second);
        },
        else => {},
    }
}

fn core_injectImplicitImports(self: *TypeChecker, node: *ASTNode) anyerror!void {
    const basename = std.fs.path.basename(self.filename);

    // std.core itself has absolutely no implicit imports
    if (std.mem.eql(u8, basename, "core.ei")) return;

    const implicit_imports = if (std.mem.eql(u8, basename, "io.ei"))
        &[_][]const u8{"std.core"}
    else if (std.mem.eql(u8, basename, "system.ei") or std.mem.eql(u8, basename, "exceptions.ei"))
        &[_][]const u8{ "std.core", "std.io" }
    else if (std.mem.startsWith(u8, self.filename, "std/") or std.mem.indexOf(u8, self.filename, "std/") != null)
        infer_decl_mod.core_implicit_imports
    else
        infer_decl_mod.user_implicit_imports;

    const import_count = implicit_imports.len;
    var new_stmts = try self.allocator.alloc(*ASTNode, node.data.program.statements.len + import_count);

    for (implicit_imports, 0..) |imp_path, i| {
        const import_node = try self.allocator.create(ASTNode);
        import_node.* = .{
            .line = 0,
            .column = 0,
            .resolved_type = null,
            .data = .{
                .import_stmt = .{
                    .module_path = imp_path,
                    .destructured = &[_][]const u8{},
                    .module_ast = null,
                },
            },
        };
        new_stmts[i] = import_node;
    }

    for (node.data.program.statements, 0..) |stmt, i| {
        new_stmts[i + import_count] = stmt;
    }
    node.data.program.statements = new_stmts;
}

/// Reports a clear error when a local declaration's name is already bound (via
/// an import) to a *different* symbol — the classic confusion where a user type
/// named `Node` silently resolves to `std.collections.Node`, producing a
/// misleading "Unresolved property" error far from the real cause. Returns
/// error.TypeError after reporting when a collision is found.
fn reportTypeNameCollision(self: *TypeChecker, stmt: *ASTNode, kind: []const u8, name: []const u8, prospective_c_name: []const u8) !void {
    if (self.alias_map.get(name)) |aliased| {
        if (!std.mem.eql(u8, aliased, prospective_c_name)) {
            self.reportError(stmt.line, stmt.column, "TypeError: {s} '{s}' conflicts with an imported declaration ('{s}'). Rename it to avoid ambiguity.", .{ kind, name, aliased });
            return error.TypeError;
        }
    }
}

fn areContractsEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a) |c_a| {
        var found = false;
        for (b) |c_b| {
            if (std.mem.eql(u8, c_a, c_b)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn core_declareTypes(self: *TypeChecker, node: *ASTNode) anyerror!void {
    if (self.status == .declaring_types or self.status == .declared_types or
        self.status == .declaring_signatures or self.status == .declared_signatures or
        self.status == .resolving_imports or self.status == .resolved_imports or
        self.status == .validating or self.status == .validated) return;

    self.status = .declaring_types;

    if (node.data == .program) {
        try self.injectImplicitImports(node);

        // Trigger declareTypes on all dependencies first
        for (node.data.program.statements) |stmt| {
            if (stmt.data == .import_stmt) {
                if (self.registry) |reg| {
                    const dir_path = std.fs.path.dirname(self.filename) orelse ".";
                    var actual_module_path = stmt.data.import_stmt.module_path;
                    if (!std.mem.endsWith(u8, actual_module_path, ".ei")) {
                        actual_module_path = try std.fmt.allocPrint(self.allocator, "{s}.ei", .{actual_module_path});
                    }
                    const mod_path = try resolveModulePath(self.allocator, dir_path, actual_module_path);
                    if (reg.modules.get(mod_path)) |m| {
                        try m.checker.declareTypes(m.ast_root);
                        var class_ast_it = m.checker.classes_ast.iterator();
                        while (class_ast_it.next()) |entry| {
                            try self.classes_ast.put(entry.key_ptr.*, entry.value_ptr.*);
                        }
                        var contract_ast_it = m.checker.contracts_ast.iterator();
                        while (contract_ast_it.next()) |entry| {
                            try self.contracts_ast.put(entry.key_ptr.*, entry.value_ptr.*);
                        }
                        var skill_ast_it = m.checker.skills_ast.iterator();
                        while (skill_ast_it.next()) |entry| {
                            try self.skills_ast.put(entry.key_ptr.*, entry.value_ptr.*);
                        }
                        var enum_ast_it = m.checker.enums_ast.iterator();
                        while (enum_ast_it.next()) |entry| {
                            try self.enums_ast.put(entry.key_ptr.*, entry.value_ptr.*);
                        }
                        var object_ast_it = m.checker.objects_ast.iterator();
                        while (object_ast_it.next()) |entry| {
                            try self.objects_ast.put(entry.key_ptr.*, entry.value_ptr.*);
                        }
                        var lib_ast_it = m.checker.libs_ast.iterator();
                        while (lib_ast_it.next()) |entry| {
                            try self.libs_ast.put(entry.key_ptr.*, entry.value_ptr.*);
                        }
                        var alias_it = m.checker.alias_map.iterator();
                        while (alias_it.next()) |entry| {
                            if (!self.alias_map.contains(entry.key_ptr.*)) {
                                try self.alias_map.put(entry.key_ptr.*, entry.value_ptr.*);
                            }
                        }
                        var sym_it = m.checker.global_scope.symbols.iterator();
                        while (sym_it.next()) |entry| {
                            if (self.global_scope.symbols.get(entry.key_ptr.*) == null) {
                                const sym = entry.value_ptr.*;
                                if (sym.variable) |vs| {
                                    _ = self.global_scope.define(entry.key_ptr.*, vs.eiwa_type, vs.is_mut, false) catch {};
                                }
                                if (sym.overloads) |ov_list| {
                                    for (ov_list.items) |ov_type| {
                                        _ = self.global_scope.define(entry.key_ptr.*, ov_type, false, true) catch {};
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Enforce ADR 60: Unique explicit lib names and mandatory contract consistency across platform variants
        var seen_libs = std.StringHashMap(*ASTNode).init(self.allocator);
        defer seen_libs.deinit();

        var type_groups = std.StringHashMap(ArrayList(*ASTNode)).init(self.allocator);
        defer {
            var it = type_groups.valueIterator();
            while (it.next()) |list| list.deinit();
            type_groups.deinit();
        }
        var object_groups = std.StringHashMap(ArrayList(*ASTNode)).init(self.allocator);
        defer {
            var it = object_groups.valueIterator();
            while (it.next()) |list| list.deinit();
            object_groups.deinit();
        }

        for (node.data.program.statements) |stmt| {
            if (stmt.data == .lib_decl) {
                const l = &stmt.data.lib_decl;
                if (seen_libs.get(l.name)) |prev| {
                    _ = prev;
                    self.reportError(stmt.line, stmt.column, "TypeError: Duplicate lib declaration '{s}'. Platform-specific FFI libraries must use distinct, explicit names (e.g. Posix{s}, Win32{s}).", .{ l.name, l.name, l.name });
                    return error.TypeError;
                }
                try seen_libs.put(l.name, stmt);
            } else if (stmt.data == .type_decl) {
                const c = &stmt.data.type_decl;
                const g = try type_groups.getOrPut(c.name);
                if (!g.found_existing) {
                    g.value_ptr.* = ArrayList(*ASTNode).init(self.allocator);
                }
                try g.value_ptr.append(stmt);
            } else if (stmt.data == .object_decl) {
                const o = &stmt.data.object_decl;
                if (o.name) |o_name| {
                    const g = try object_groups.getOrPut(o_name);
                    if (!g.found_existing) {
                        g.value_ptr.* = ArrayList(*ASTNode).init(self.allocator);
                    }
                    try g.value_ptr.append(stmt);
                }
            }
        }

        // Validate contract consistency across all type variants with the same name
        var tg_it = type_groups.iterator();
        while (tg_it.next()) |entry| {
            const list = entry.value_ptr.*;
            var has_platform = false;
            for (list.items) |s| {
                if (s.data.type_decl.platform_targets.len > 0) {
                    has_platform = true;
                    break;
                }
            }
            if (has_platform) {
                var ref_contracts: ?[]const []const u8 = null;
                for (list.items) |s| {
                    if (s.data.type_decl.contracts.len > 0) {
                        ref_contracts = s.data.type_decl.contracts;
                        break;
                    }
                }
                if (ref_contracts == null) {
                    const first_stmt = list.items[0];
                    self.reportError(first_stmt.line, first_stmt.column, "TypeError: Platform-specialized type '{s}' must implement at least one contract.", .{entry.key_ptr.*});
                    return error.TypeError;
                }
                const expected_contracts = ref_contracts.?;
                for (list.items) |s| {
                    const c = &s.data.type_decl;
                    if (c.contracts.len == 0) {
                        self.reportError(s.line, s.column, "TypeError: Default/platform declaration '{s}' must implement the same contract(s) as other variants.", .{c.name});
                        return error.TypeError;
                    }
                    if (!areContractsEqual(expected_contracts, c.contracts)) {
                        self.reportError(s.line, s.column, "TypeError: Variant of type '{s}' has inconsistent contract list. All variants (including default) must implement the same contracts.", .{c.name});
                        return error.TypeError;
                    }
                }
            }
        }

        // Validate contract consistency across all object variants with the same name
        var og_it = object_groups.iterator();
        while (og_it.next()) |entry| {
            const list = entry.value_ptr.*;
            var has_platform = false;
            for (list.items) |s| {
                if (s.data.object_decl.platform_targets.len > 0) {
                    has_platform = true;
                    break;
                }
            }
            if (has_platform) {
                var ref_contracts: ?[]const []const u8 = null;
                for (list.items) |s| {
                    if (s.data.object_decl.contracts.len > 0) {
                        ref_contracts = s.data.object_decl.contracts;
                        break;
                    }
                }
                if (ref_contracts == null) {
                    const first_stmt = list.items[0];
                    self.reportError(first_stmt.line, first_stmt.column, "TypeError: Platform-specialized object '{s}' must implement at least one contract.", .{entry.key_ptr.*});
                    return error.TypeError;
                }
                const expected_contracts = ref_contracts.?;
                for (list.items) |s| {
                    const o = &s.data.object_decl;
                    const o_name = o.name orelse "object";
                    if (o.contracts.len == 0) {
                        self.reportError(s.line, s.column, "TypeError: Default/platform declaration '{s}' must implement the same contract(s) as other variants.", .{o_name});
                        return error.TypeError;
                    }
                    if (!areContractsEqual(expected_contracts, o.contracts)) {
                        self.reportError(s.line, s.column, "TypeError: Variant of object '{s}' has inconsistent contract list. All variants (including default) must implement the same contracts.", .{o_name});
                        return error.TypeError;
                    }
                }
            }
        }

        // Declare local types
        for (node.data.program.statements) |stmt| {
            if (stmt.data == .type_decl) {
                var c = &stmt.data.type_decl;
                if (!self.matchesTarget(c.platform_targets)) continue;
                if (c.resolved_c_name == null) {
                    const prospective: []const u8 = if (self.module_prefix) |prefix|
                        try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ prefix, c.name })
                    else
                        c.name;
                    try reportTypeNameCollision(self, stmt, "Type", c.name, prospective);
                    if (self.module_prefix) |prefix| {
                        c.resolved_c_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ prefix, c.name });
                        if (!std.mem.eql(u8, c.name, "Int") and !std.mem.eql(u8, c.name, "Bool") and !std.mem.eql(u8, c.name, "Pointer")) {
                            try self.alias_map.put(c.name, c.resolved_c_name.?);
                        }
                    } else {
                        c.resolved_c_name = c.name;
                    }
                }
                const actual_c_name = c.resolved_c_name.?;

                if (self.classes_ast.get(actual_c_name)) |existing| {
                    const existing_targets = existing.data.type_decl.platform_targets;
                    if (existing_targets.len == 0 and c.platform_targets.len > 0) {
                        // Specialized overrides universal fallback
                    } else if (existing_targets.len > 0 and c.platform_targets.len == 0) {
                        // Specialized already registered, ignore universal fallback
                        continue;
                    } else {
                        self.reportError(stmt.line, stmt.column, "TypeError: Duplicate type declaration '{s}' for the same target.", .{c.name});
                        return error.TypeError;
                    }
                }

                const class_type = try self.allocator.create(EiwaType);
                if (std.mem.eql(u8, c.name, "Int")) {
                    class_type.* = .Int;
                } else if (std.mem.eql(u8, c.name, "Bool")) {
                    class_type.* = .Bool;
                } else if (std.mem.eql(u8, c.name, "String")) {
                    class_type.* = .String;
                } else if (std.mem.eql(u8, c.name, "Pointer")) {
                    class_type.* = .{ .Pointer = try self.allocator.create(EiwaType) };
                    @constCast(class_type.Pointer).* = .Void;
                } else {
                    class_type.* = .{ .Custom = actual_c_name };
                }
                _ = self.global_scope.define(c.name, class_type, false, false) catch {};
                if (!std.mem.eql(u8, c.name, actual_c_name)) {
                    _ = self.global_scope.define(actual_c_name, class_type, false, false) catch {};
                }
                try self.classes_ast.put(actual_c_name, stmt);
                try self.local_symbols.put(c.name, {});
                try infer_decl_mod.injectAutoContractsAndSkills(self, c);
            } else if (stmt.data == .contract_decl) {
                var cd = &stmt.data.contract_decl;
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
                _ = self.global_scope.define(cd.name, contract_type, false, false) catch {};
                if (!std.mem.eql(u8, cd.name, actual_c_name)) {
                    _ = self.global_scope.define(actual_c_name, contract_type, false, false) catch {};
                }
                try self.contracts_ast.put(actual_c_name, stmt);
                try self.local_symbols.put(cd.name, {});
            } else if (stmt.data == .skill_decl) {
                var sd = &stmt.data.skill_decl;
                if (sd.resolved_c_name == null) {
                    if (self.module_prefix) |prefix| {
                        sd.resolved_c_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ prefix, sd.name });
                        try self.alias_map.put(sd.name, sd.resolved_c_name.?);
                    } else {
                        sd.resolved_c_name = sd.name;
                    }
                }
                try self.skills_ast.put(sd.resolved_c_name.?, stmt);
                try self.local_symbols.put(sd.name, {});
            } else if (stmt.data == .object_decl) {
                var o = &stmt.data.object_decl;
                if (!self.matchesTarget(o.platform_targets)) continue;
                if (o.name) |o_name| {
                    if (o.resolved_c_name == null) {
                        if (self.module_prefix) |prefix| {
                            o.resolved_c_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ prefix, o_name });
                            try self.alias_map.put(o_name, o.resolved_c_name.?);
                        } else {
                            o.resolved_c_name = o_name;
                        }
                    }
                    const actual_c_name = o.resolved_c_name.?;

                    if (self.objects_ast.get(actual_c_name)) |existing| {
                        const existing_targets = existing.data.object_decl.platform_targets;
                        if (existing_targets.len == 0 and o.platform_targets.len > 0) {
                            // Specialized overrides universal fallback
                        } else if (existing_targets.len > 0 and o.platform_targets.len == 0) {
                            // Specialized already registered, ignore universal fallback
                            continue;
                        } else {
                            self.reportError(stmt.line, stmt.column, "TypeError: Duplicate object declaration '{s}' for the same target.", .{o_name});
                            return error.TypeError;
                        }
                    }

                    const obj_type = try self.allocator.create(EiwaType);
                    obj_type.* = .{ .Custom = actual_c_name };
                    try self.objects_ast.put(actual_c_name, stmt);
                    try self.local_symbols.put(o_name, {});
                    if (self.global_scope.lookupVariable(o_name) == null) {
                        _ = self.global_scope.define(o_name, obj_type, false, false) catch {};
                        if (!std.mem.eql(u8, o_name, actual_c_name)) {
                            _ = self.global_scope.define(actual_c_name, obj_type, false, false) catch {};
                        }
                    }
                }
            } else if (stmt.data == .enum_decl) {
                var ed = &stmt.data.enum_decl;
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
                try self.enums_ast.put(actual_c_name, stmt);
                try self.local_symbols.put(ed.name, {});
                if (self.global_scope.lookupVariable(ed.name) == null) {
                    _ = self.global_scope.define(ed.name, enum_type, false, false) catch {};
                    if (!std.mem.eql(u8, ed.name, actual_c_name)) {
                        _ = self.global_scope.define(actual_c_name, enum_type, false, false) catch {};
                    }
                }
            }
        }
    }

    self.status = .declared_types;
}

fn core_declareSignatures(self: *TypeChecker, node: *ASTNode) anyerror!void {
    if (self.status == .declaring_signatures or self.status == .declared_signatures or
        self.status == .resolving_imports or self.status == .resolved_imports or
        self.status == .validating or self.status == .validated) return;

    try self.declareTypes(node);

    self.status = .declaring_signatures;
    self.pass = .declaration;

    if (node.data == .program) {
        // Trigger declareSignatures on all dependencies first
        for (node.data.program.statements) |stmt| {
            if (stmt.data == .import_stmt) {
                if (self.registry) |reg| {
                    const dir_path = std.fs.path.dirname(self.filename) orelse ".";
                    var actual_module_path = stmt.data.import_stmt.module_path;
                    if (!std.mem.endsWith(u8, actual_module_path, ".ei")) {
                        actual_module_path = try std.fmt.allocPrint(self.allocator, "{s}.ei", .{actual_module_path});
                    }
                    const mod_path = try resolveModulePath(self.allocator, dir_path, actual_module_path);
                    if (reg.modules.get(mod_path)) |m| {
                        try m.checker.declareSignatures(m.ast_root);
                    }
                }
            }
        }

        // Resolve local imports BEFORE declaring object/type/fun signatures:
        // object property initializers (and const-folded defaults) may call
        // imported functions, which only enter functions_ast once the import
        // statement is inferred. resolveImports re-infers them idempotently.
        for (node.data.program.statements) |stmt| {
            if (stmt.data == .import_stmt) {
                _ = try self.inferNode(stmt, &self.global_scope);
            }
        }

        // Declare local signatures first so dependencies and mutual imports can see them
        for (node.data.program.statements) |stmt| {
            if (stmt.data == .lib_decl) {
                if (!self.matchesTarget(stmt.data.lib_decl.platform_targets)) continue;
                _ = try self.inferNode(stmt, &self.global_scope);
            } else if (stmt.data == .type_decl) {
                if (!self.matchesTarget(stmt.data.type_decl.platform_targets)) continue;
                _ = try self.inferNode(stmt, &self.global_scope);
            } else if (stmt.data == .object_decl) {
                if (!self.matchesTarget(stmt.data.object_decl.platform_targets)) continue;
                _ = try self.inferNode(stmt, &self.global_scope);
            } else if (stmt.data == .contract_decl or stmt.data == .skill_decl or stmt.data == .fun_decl) {
                _ = try self.inferNode(stmt, &self.global_scope);
            }
        }
    }

    self.status = .declared_signatures;
}

fn core_resolveImports(self: *TypeChecker, node: *ASTNode) anyerror!void {
    if (self.status == .resolving_imports or self.status == .resolved_imports or
        self.status == .validating or self.status == .validated) return;

    try self.declareSignatures(node);

    self.status = .resolving_imports;
    self.pass = .declaration;

    if (node.data == .program) {
        // Trigger resolveImports on all dependencies first
        for (node.data.program.statements) |stmt| {
            if (stmt.data == .import_stmt) {
                if (self.registry) |reg| {
                    const dir_path = std.fs.path.dirname(self.filename) orelse ".";
                    var actual_module_path = stmt.data.import_stmt.module_path;
                    if (!std.mem.endsWith(u8, actual_module_path, ".ei")) {
                        actual_module_path = try std.fmt.allocPrint(self.allocator, "{s}.ei", .{actual_module_path});
                    }
                    const mod_path = try resolveModulePath(self.allocator, dir_path, actual_module_path);
                    if (reg.modules.get(mod_path)) |m| {
                        try m.checker.resolveImports(m.ast_root);
                    }
                }
            }
        }

        // Resolve local imports
        for (node.data.program.statements) |stmt| {
            if (stmt.data == .import_stmt) {
                _ = try self.inferNode(stmt, &self.global_scope);
            }
        }
    }

    self.status = .resolved_imports;
}

fn collectUsedNames(self: *TypeChecker, node: *ASTNode, used: *std.StringHashMap(void)) anyerror!void {
    var member_uses = std.StringHashMap(void).init(self.allocator);
    defer member_uses.deinit();
    try collectUsedNamesInner(self, node, used, &member_uses);
    var it = member_uses.iterator();
    while (it.next()) |entry| {
        if (self.imported_extension_names.contains(entry.key_ptr.*)) {
            try used.put(entry.key_ptr.*, {});
        }
    }
}

fn collectUsedNamesInner(self: *TypeChecker, node: *ASTNode, used: *std.StringHashMap(void), member_uses: *std.StringHashMap(void)) anyerror!void {
    switch (node.data) {
        .program => |p| for (p.statements) |s| try collectUsedNamesInner(self, s, used, member_uses),
        .import_stmt => {},
        .identifier => |id| try used.put(id.name, {}),
        .assignment => |a| {
            try used.put(a.name, {});
            try collectUsedNamesInner(self, a.value, used, member_uses);
        },
        .binary_expr => |b| {
            try collectUsedNamesInner(self, b.left, used, member_uses);
            try collectUsedNamesInner(self, b.right, used, member_uses);
        },
        .unary_expr => |u| try collectUsedNamesInner(self, u.operand, used, member_uses),
        .call_expr => |c| {
            try collectUsedNamesInner(self, c.callee, used, member_uses);
            for (c.arguments) |arg| try collectUsedNamesInner(self, arg, used, member_uses);
            for (c.type_args) |ta| try collectUsedTypeRef(ta, used);
        },
        .named_arg => |na| try collectUsedNamesInner(self, na.value, used, member_uses),
        .get_expr => |g| {
            try member_uses.put(g.name, {});
            try collectUsedNamesInner(self, g.object, used, member_uses);
        },
        .set_expr => |s| {
            try member_uses.put(s.name, {});
            try collectUsedNamesInner(self, s.object, used, member_uses);
            try collectUsedNamesInner(self, s.value, used, member_uses);
        },
        .index_expr => |i| {
            try collectUsedNamesInner(self, i.object, used, member_uses);
            try collectUsedNamesInner(self, i.index, used, member_uses);
        },
        .index_set_expr => |i| {
            try collectUsedNamesInner(self, i.object, used, member_uses);
            try collectUsedNamesInner(self, i.index, used, member_uses);
            try collectUsedNamesInner(self, i.value, used, member_uses);
        },
        .if_expr => |i| {
            try collectUsedNamesInner(self, i.condition, used, member_uses);
            try collectUsedNamesInner(self, i.then_branch, used, member_uses);
            if (i.else_branch) |e| try collectUsedNamesInner(self, e, used, member_uses);
        },
        .ternary_expr => |t| {
            try collectUsedNamesInner(self, t.condition, used, member_uses);
            try collectUsedNamesInner(self, t.then_branch, used, member_uses);
            if (t.else_branch) |e| try collectUsedNamesInner(self, e, used, member_uses);
        },
        .while_stmt => |w| {
            try collectUsedNamesInner(self, w.condition, used, member_uses);
            try collectUsedNamesInner(self, w.body, used, member_uses);
        },
        .for_stmt => |f| {
            try collectUsedNamesInner(self, f.iterable, used, member_uses);
            try collectUsedNamesInner(self, f.body, used, member_uses);
        },
        .block => |b| for (b.statements) |s| try collectUsedNamesInner(self, s, used, member_uses),
        .return_stmt => |r| if (r.value) |v| try collectUsedNamesInner(self, v, used, member_uses),
        .break_stmt => |b| if (b.value) |v| try collectUsedNamesInner(self, v, used, member_uses),
        .throw_stmt => |t| try collectUsedNamesInner(self, t.expr, used, member_uses),
        .try_stmt => |t| {
            try collectUsedNamesInner(self, t.body, used, member_uses);
            for (t.catches) |c| {
                for (c.types) |ty| try collectUsedTypeRef(ty, used);
                try collectUsedNamesInner(self, c.body, used, member_uses);
            }
        },
        .when_expr => |w| {
            if (w.subject) |s| try collectUsedNamesInner(self, s, used, member_uses);
            for (w.cases) |c| {
                for (c.conds) |cond| try collectUsedNamesInner(self, cond, used, member_uses);
                try collectUsedNamesInner(self, c.body, used, member_uses);
            }
        },
        .lambda_expr => |l| {
            for (l.params) |p| {
                if (p.type_ref) |tr| try collectUsedTypeRef(tr, used);
                if (p.initializer) |init| try collectUsedNamesInner(self, init, used, member_uses);
            }
            for (l.body) |s| try collectUsedNamesInner(self, s, used, member_uses);
        },
        .var_decl => |v| {
            if (v.type_ref) |tr| try collectUsedTypeRef(tr, used);
            if (v.initializer) |init| try collectUsedNamesInner(self, init, used, member_uses);
        },
        .fun_decl => |f| {
            for (f.params) |p| {
                if (p.type_ref) |tr| try collectUsedTypeRef(tr, used);
                if (p.initializer) |init| try collectUsedNamesInner(self, init, used, member_uses);
            }
            if (f.type_ref) |tr| try collectUsedTypeRef(tr, used);
            if (f.receiver_type) |rt| try collectUsedTypeRef(rt, used);
            try collectUsedNamesInner(self, f.body, used, member_uses);
        },
        .type_decl => |t| {
            for (t.contracts) |c| try used.put(c, {});
            for (t.skills) |s| try used.put(s, {});
            for (t.primary_constructor) |prop| {
                try collectUsedTypeRef(prop.type_ref, used);
                if (prop.initializer) |init| try collectUsedNamesInner(self, init, used, member_uses);
            }
            for (t.body_fields) |prop| {
                try collectUsedTypeRef(prop.type_ref, used);
                if (prop.initializer) |init| try collectUsedNamesInner(self, init, used, member_uses);
            }
            for (t.methods) |m| try collectUsedNamesInner(self, m, used, member_uses);
        },
        .contract_decl => |c| for (c.methods) |m| try collectUsedNamesInner(self, m, used, member_uses),
        .skill_decl => |s| {
            for (s.required_contracts) |c| try used.put(c, {});
            for (s.methods) |m| try collectUsedNamesInner(self, m, used, member_uses);
        },
        .object_decl => |o| {
            for (o.contracts) |c| try used.put(c, {});
            for (o.skills) |s| try used.put(s, {});
            for (o.members) |m| try collectUsedNamesInner(self, m, used, member_uses);
        },
        .enum_decl => {},
        .lib_decl => |l| for (l.functions) |f| try collectUsedNamesInner(self, f, used, member_uses),
        .test_decl => |t| try collectUsedNamesInner(self, t.body, used, member_uses),
        .as_expr => |a| {
            try collectUsedNamesInner(self, a.value, used, member_uses);
            try collectUsedTypeRef(a.type_ref, used);
        },
        .is_expr => |i| {
            try collectUsedNamesInner(self, i.value, used, member_uses);
            try collectUsedTypeRef(i.type_ref, used);
        },
        .is_type_cond => |i| try collectUsedTypeRef(i.type_ref, used),
        .string_template => |s| for (s.parts) |p| try collectUsedNamesInner(self, p, used, member_uses),
        .array_literal => |a| for (a.elements) |e| try collectUsedNamesInner(self, e, used, member_uses),
        .map_literal => |m| for (m.elements) |e| try collectUsedNamesInner(self, e, used, member_uses),
        .int_literal, .double_literal, .string_literal, .bool_literal, .null_literal => {},
    }
}

fn collectUsedTypeRef(ref: *const ast.ASTTypeRef, used: *std.StringHashMap(void)) anyerror!void {
    try used.put(ref.name, {});
    for (ref.generic_args) |arg| try collectUsedTypeRef(arg, used);
    for (ref.union_types) |u| try collectUsedTypeRef(u, used);
    if (ref.receiver_type) |rt| try collectUsedTypeRef(rt, used);
    if (ref.return_type) |rt| try collectUsedTypeRef(rt, used);
}

fn checkUnusedImports(self: *TypeChecker, node: *ASTNode) anyerror!void {
    if (node.data != .program) return;
    const basename = std.fs.path.basename(self.filename);
    if (infer_decl_mod.std_modules.get(basename) != null) return;
    var used = std.StringHashMap(void).init(self.allocator);
    defer used.deinit();
    for (node.data.program.statements) |stmt| {
        if (stmt.data == .import_stmt) continue;
        try collectUsedNames(self, stmt, &used);
    }
    for (node.data.program.statements) |stmt| {
        if (stmt.data != .import_stmt) continue;
        const imp = stmt.data.import_stmt;
        if (imp.destructured.len == 0) continue;
        if (stmt.line == 0) continue;
        for (imp.destructured) |sym| {
            if (used.contains(sym)) continue;
            self.reportWarning(stmt.line, stmt.column, "Unused import '{s}' from '{s}'. Remove it to keep imports minimal.", .{ sym, imp.module_path });
        }
    }
}

fn core_validate(self: *TypeChecker, node: *ASTNode) anyerror!void {
    if (self.status == .validating or self.status == .validated) return;

    if (self.registry == null) {
        // Fallback: run all passes sequentially on this single checker/file
        if (node.data == .program) {
            try self.injectImplicitImports(node);
        }
        try self.declareTypes(node);
        try self.declareSignatures(node);
        try self.resolveImports(node);
    } else {
        try self.resolveImports(node);
    }

    self.status = .validating;
    self.pass = .validation;
    // Before inference: later passes rewrite expressions in place, hiding uses.
    try checkUnusedImports(self, node);
    _ = try self.inferNode(node, &self.global_scope);

    // Validate all dynamically monomorphized nodes
    var mono_idx: usize = 0;
    while (mono_idx < self.monomorphized_nodes.items.len) : (mono_idx += 1) {
        const mono_node = self.monomorphized_nodes.items[mono_idx];
        if (mono_node.data == .type_decl) {
            const class_type = try self.allocator.create(EiwaType);
            try infer_decl_mod.inferTypeDecl(self, mono_node, &self.global_scope, class_type);
        } else if (mono_node.data == .object_decl) {
            if (mono_node.resolved_type == null) {
                const obj_type = try self.allocator.create(EiwaType);
                try infer_decl_mod.inferObjectDecl(self, mono_node, &self.global_scope, obj_type);
            }
        }
    }

    // Insert any dynamically monomorphized nodes into the AST right after the
    // import statements. They must precede user code so the transpiler emits
    // their C prototypes before any lambdas that call them, but they must
    // come *after* imports so lib/type declarations from imported modules are
    // already registered when they are emitted.
    if (node.data == .program and self.monomorphized_nodes.items.len > 0) {
        var insert_idx: usize = 0;
        for (node.data.program.statements, 0..) |stmt, i| {
            if (stmt.data == .import_stmt) insert_idx = i + 1;
        }
        const old_stmts = node.data.program.statements;
        var final_stmts = try self.allocator.alloc(*ASTNode, old_stmts.len + self.monomorphized_nodes.items.len);
        @memcpy(final_stmts[0..insert_idx], old_stmts[0..insert_idx]);
        @memcpy(final_stmts[insert_idx..][0..self.monomorphized_nodes.items.len], self.monomorphized_nodes.items);
        @memcpy(final_stmts[insert_idx + self.monomorphized_nodes.items.len ..], old_stmts[insert_idx..]);
        node.data.program.statements = final_stmts;
    }

    self.status = .validated;
}

fn core_inferNode(self: *TypeChecker, node: *ASTNode, scope: *Scope) anyerror!*const EiwaType {
    if (self.pass == .validation) {
        switch (node.data) {
            .program, .type_decl, .object_decl, .enum_decl, .fun_decl, .import_stmt => {},
            else => {
                if (node.resolved_type) |rt| {
                    return rt;
                }
            },
        }
    } else {
        if (node.data != .fun_decl and node.data != .import_stmt) {
            if (node.resolved_type) |rt| {
                return rt;
            }
        }
    }
    const t = try self.allocator.create(EiwaType);
    switch (node.data) {
        .program => |p| {
            for (p.statements) |stmt| {
                if (stmt.data == .test_decl and !self.is_test_mode) continue;
                _ = try self.inferNode(stmt, scope);
            }
            t.* = .Void;
        },
        .test_decl => |td| {
            if (self.pass == .declaration) {
                t.* = .Void;
                return t;
            }
            _ = try self.inferNode(td.body, scope);
            t.* = .Void;
        },
        .import_stmt => try infer_decl_mod.inferImportStmt(self, node, scope, t),
        .lib_decl => try infer_decl_mod.inferLibDecl(self, node, scope, t),
        .type_decl => try infer_decl_mod.inferTypeDecl(self, node, scope, t),
        .contract_decl => try infer_decl_mod.inferContractDecl(self, node, scope, t),
        .skill_decl => try infer_decl_mod.inferSkillDecl(self, node, scope, t),
        .object_decl => try infer_decl_mod.inferObjectDecl(self, node, scope, t),
        .enum_decl => try infer_decl_mod.inferEnumDecl(self, node, scope, t),
        .fun_decl => try infer_decl_mod.inferFunDecl(self, node, scope, t),
        .var_decl => try infer_decl_mod.inferVarDecl(self, node, scope, t),
        .assignment => try infer_expr_mod.inferAssignment(self, node, scope, t),
        .unary_expr => try infer_expr_mod.inferUnaryExpr(self, node, scope, t),
        .binary_expr => try infer_expr_mod.inferBinaryExpr(self, node, scope, t),
        .get_expr => try infer_expr_mod.inferGetExpr(self, node, scope, t),
        .set_expr => try infer_expr_mod.inferSetExpr(self, node, scope, t),
        .named_arg => |na| {
            const val_t = try self.inferNode(na.value, scope);
            t.* = val_t.*;
        },
        .call_expr => try infer_expr_mod.inferCallExpr(self, node, scope, t),
        .as_expr => try infer_expr_mod.inferAsExpr(self, node, scope, t),
        .is_expr => try infer_expr_mod.inferIsExpr(self, node, scope, t),
        .ternary_expr => try infer_expr_mod.inferTernaryExpr(self, node, scope, t),
        .if_expr => try infer_stmt_mod.inferIfExpr(self, node, scope, t),
        .while_stmt => try infer_stmt_mod.inferWhileStmt(self, node, scope, t),
        .for_stmt => try infer_stmt_mod.inferForStmt(self, node, scope, t),
        .return_stmt => try infer_stmt_mod.inferReturnStmt(self, node, scope, t),
        .break_stmt => try infer_stmt_mod.inferBreakStmt(self, node, scope, t),
        .try_stmt => try infer_stmt_mod.inferTryStmt(self, node, scope, t),
        .throw_stmt => try infer_stmt_mod.inferThrowStmt(self, node, scope, t),
        .block => {
            if (node.data.block.is_value) {
                if (try infer_stmt_mod.inferBlockAsExpression(self, node, scope)) |rt| {
                    t.* = rt.*;
                } else {
                    t.* = .Void;
                }
            } else {
                return try self.checkBlock(node.data.block.statements, scope);
            }
        },
        .is_type_cond => t.* = .Bool,
        .when_expr => try infer_when_mod.inferWhenExpr(self, node, scope, t),
        .lambda_expr => try infer_expr_mod.inferLambdaExpr(self, node, scope, t),
        .identifier => try infer_expr_mod.inferIdentifier(self, node, scope, t),
        .int_literal => t.* = .Int,
        .double_literal => t.* = .Double,
        .string_literal => t.* = .String,
        .string_template => |st| {
            for (st.parts) |part| {
                _ = try self.inferNode(part, scope);
            }
            t.* = .String;
        },
        .bool_literal => t.* = .Bool,
        .null_literal => t.* = .Null,
        .array_literal => try infer_expr_mod.inferArrayLiteral(self, node, scope, t),
        .map_literal => try infer_expr_mod.inferMapLiteral(self, node, scope, t),
        .index_expr => try infer_expr_mod.inferIndexExpr(self, node, scope, t),
        .index_set_expr => try infer_expr_mod.inferIndexSetExpr(self, node, scope, t),
    }
    if (node.resolved_type == null) {
        node.resolved_type = t;
        // A `?.` call on a nullable receiver yields null when the receiver
        // is null, so its type must carry Null regardless of inference path.
        if (node.data == .call_expr and t.* != .Void and t.* != .Unknown) {
            const cc = node.data.call_expr.callee;
            if (cc.data == .get_expr and cc.data.get_expr.is_safe) {
                if (cc.data.get_expr.object.resolved_type) |obj_rt| {
                    if (isNullable(obj_rt) and !isNullable(t)) {
                        const null_t = try self.allocator.create(EiwaType);
                        null_t.* = .Null;
                        const union_t = try self.allocator.create(EiwaType);
                        union_t.* = .{ .Union = .{ .left = t, .right = null_t } };
                        node.resolved_type = union_t;
                    }
                }
            }
        }
    }
    return node.resolved_type.?;
}

fn core_conformsTo(self: *TypeChecker, actual_name: []const u8, target_name: []const u8) bool {
    const actual = self.alias_map.get(actual_name) orelse actual_name;
    const target = self.alias_map.get(target_name) orelse target_name;
    if (std.mem.eql(u8, actual, target)) return true;

    return self.implementsContract(actual, target);
}

fn core_implementsContract(self: *TypeChecker, type_name: []const u8, contract_name: []const u8) bool {
    const actual_type = self.alias_map.get(type_name) orelse type_name;
    const actual_contract = self.alias_map.get(contract_name) orelse contract_name;
    if (std.mem.eql(u8, actual_type, actual_contract)) return true;

    var node_opt = self.classes_ast.get(actual_type);
    if (node_opt == null) {
        if (std.mem.eql(u8, actual_type, "Int")) {
            node_opt = self.classes_ast.get("std_core_Int") orelse self.classes_ast.get("core_Int");
        } else if (std.mem.eql(u8, actual_type, "Double")) {
            node_opt = self.classes_ast.get("std_core_Double") orelse self.classes_ast.get("core_Double");
        } else if (std.mem.eql(u8, actual_type, "Bool")) {
            node_opt = self.classes_ast.get("std_core_Bool") orelse self.classes_ast.get("core_Bool");
        } else if (std.mem.eql(u8, actual_type, "String")) {
            node_opt = self.classes_ast.get("std_core_String") orelse self.classes_ast.get("core_String");
        }
    }
    const node = node_opt orelse return false;
    if (node.data != .type_decl) return false;
    for (node.data.type_decl.contracts) |c| {
        const c_actual = self.alias_map.get(c) orelse c;
        if (std.mem.eql(u8, c_actual, actual_contract) or std.mem.eql(u8, c_actual, contract_name) or std.mem.eql(u8, c, contract_name)) return true;
    }
    return false;
}

fn core_isCompatible(self: *TypeChecker, expected: *const EiwaType, actual: *const EiwaType) bool {
    if (expected.* == .Unknown or actual.* == .Unknown) return true;
    if (expected.* == .GenericParam or actual.* == .GenericParam) return true;
    if (isNullable(expected) and actual.* == .Null) return true;
    if (isNullable(actual) and !isNullable(expected)) return false;
    if (expected.* == .Custom and actual.* == .Custom and std.mem.eql(u8, expected.Custom, actual.Custom)) {
        return true;
    }

    if (expected.* == .Union) {
        if (self.isCompatible(expected.Union.left, actual) or self.isCompatible(expected.Union.right, actual)) {
            return true;
        }
    }
    if (actual.* == .Union) {
        if (self.isCompatible(expected, actual.Union.left) and self.isCompatible(expected, actual.Union.right)) {
            return true;
        }
    }

    const exp_base = extractBaseType(expected);
    const act_base = extractBaseType(actual);

    if (exp_base.* == .Custom) {
        const type_name: ?[]const u8 = switch (act_base.*) {
            .Custom => |name| name,
            .Int => "Int",
            .Double => "Double",
            .Bool => "Bool",
            .String => "String",
            else => null,
        };
        if (type_name) |tname| {
            if (self.conformsTo(tname, exp_base.Custom)) return true;
        }
    }

    // Contract-typed generic instance (e.g. Awaitable<Int>) on the expected side:
    // any type conforming to the base contract is acceptable.
    if (exp_base.* == .GenericInstance and self.contracts_ast.contains(exp_base.GenericInstance.base_name)) {
        const contract_base = exp_base.GenericInstance.base_name;
        switch (act_base.*) {
            .Custom => |name| {
                if (self.conformsTo(name, contract_base)) return true;
            },
            .GenericInstance => |act_gi| {
                if (std.mem.eql(u8, act_gi.base_name, contract_base)) return true;
                if (self.conformsTo(act_gi.base_name, contract_base)) return true;
            },
            .Int => if (self.conformsTo("Int", contract_base)) return true,
            .Double => if (self.conformsTo("Double", contract_base)) return true,
            .Bool => if (self.conformsTo("Bool", contract_base)) return true,
            .String => if (self.conformsTo("String", contract_base)) return true,
            else => {},
        }
    }

    // Int / Double / Bool / String ↔ Custom primitive bridges
    if (exp_base.* == .Int and act_base.* == .Custom and
        (std.mem.eql(u8, act_base.Custom, "core_Int") or std.mem.eql(u8, act_base.Custom, "std_core_Int") or std.mem.eql(u8, act_base.Custom, "Int")))
        return true;
    if (exp_base.* == .Custom and act_base.* == .Int and
        (std.mem.eql(u8, exp_base.Custom, "core_Int") or std.mem.eql(u8, exp_base.Custom, "std_core_Int") or std.mem.eql(u8, exp_base.Custom, "Int")))
        return true;

    if (exp_base.* == .Double and (act_base.* == .Int or (act_base.* == .Custom and (std.mem.eql(u8, act_base.Custom, "core_Int") or std.mem.eql(u8, act_base.Custom, "std_core_Int") or std.mem.eql(u8, act_base.Custom, "Int")))))
        return true;
    if (exp_base.* == .Double and act_base.* == .Custom and
        (std.mem.eql(u8, act_base.Custom, "core_Double") or std.mem.eql(u8, act_base.Custom, "std_core_Double") or std.mem.eql(u8, act_base.Custom, "Double")))
        return true;
    if (exp_base.* == .Custom and act_base.* == .Double and
        (std.mem.eql(u8, exp_base.Custom, "core_Double") or std.mem.eql(u8, exp_base.Custom, "std_core_Double") or std.mem.eql(u8, exp_base.Custom, "Double")))
        return true;

    if (exp_base.* == .Bool and act_base.* == .Custom and
        (std.mem.eql(u8, act_base.Custom, "core_Bool") or std.mem.eql(u8, act_base.Custom, "std_core_Bool") or std.mem.eql(u8, act_base.Custom, "Bool")))
        return true;
    if (exp_base.* == .Custom and act_base.* == .Bool and
        (std.mem.eql(u8, exp_base.Custom, "core_Bool") or std.mem.eql(u8, exp_base.Custom, "std_core_Bool") or std.mem.eql(u8, exp_base.Custom, "Bool")))
        return true;

    if (exp_base.* == .String and act_base.* == .Custom and
        (std.mem.eql(u8, act_base.Custom, "core_String") or std.mem.eql(u8, act_base.Custom, "std_core_String") or std.mem.eql(u8, act_base.Custom, "String")))
    {
        return true;
    }
    if (exp_base.* == .Custom and act_base.* == .String and
        (std.mem.eql(u8, exp_base.Custom, "core_String") or std.mem.eql(u8, exp_base.Custom, "std_core_String") or std.mem.eql(u8, exp_base.Custom, "String")))
    {
        return true;
    }

    if (std.meta.activeTag(exp_base.*) == std.meta.activeTag(act_base.*)) {
        switch (exp_base.*) {
            .Array => |elem| {
                if (act_base.* == .Array) {
                    return self.isCompatible(elem, act_base.Array);
                }
                return false;
            },
            .Pointer => |elem| {
                if (act_base.* == .Pointer) {
                    if (elem.* == .Void or act_base.Pointer.* == .Void) return true;
                    return self.isCompatible(elem, act_base.Pointer);
                }
                return false;
            },
            .Function => |f_exp| {
                if (act_base.* != .Function) return false;
                const f_act = act_base.Function;
                if (f_exp.params.len != f_act.params.len) return false;
                if (f_exp.receiver) |rec_exp| {
                    if (f_act.receiver) |rec_act| {
                        if (!self.isCompatible(rec_exp, rec_act)) return false;
                    } else {
                        return false;
                    }
                } else {
                    if (f_act.receiver != null) return false;
                }
                for (f_exp.params, 0..) |p_exp, i| {
                    if (!self.isCompatible(p_exp, f_act.params[i])) return false;
                }
                if (f_exp.return_type.* == .Void) return true;
                return self.isCompatible(f_exp.return_type, f_act.return_type);
            },
            else => return true,
        }
    }
    return false;
}

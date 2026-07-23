const std = @import("std");
const builtin = @import("builtin");
const compat = @import("core/compat.zig");
const ArrayList = compat.ArrayList;
const lexer = @import("frontend/lexer.zig");
const parser = @import("frontend/parser/core.zig");
const c_transpiler = @import("backend/c_transpiler/core.zig");
const ast = @import("core/ast.zig");

/// Main entry point for the Eiwa CLI.
/// Orchestrates the pipeline: Source -> Lexer -> Parser -> AST -> C Transpiler -> Binary.
pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var args_list = ArrayList([]const u8).init(allocator);
    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_it.deinit();
    while (args_it.next()) |arg| {
        try args_list.append(arg);
    }
    const args = args_list.items;

    if (args.len < 2 or (!std.mem.eql(u8, args[1], "run") and !std.mem.eql(u8, args[1], "build") and !std.mem.eql(u8, args[1], "test"))) {
        std.debug.print("Usage: eiwa <run|build|test> [file.ei]\n", .{});
        return;
    }
    const is_build = std.mem.eql(u8, args[1], "build");
    const is_test = std.mem.eql(u8, args[1], "test");

    var source_alloc = ArrayList(u8).init(allocator);
    defer source_alloc.deinit();

    var filename: []const u8 = "synthetic_test.ei";

    const io = init.io;

    if (is_test) {
        var search_path: []const u8 = ".";
        if (args.len > 2) {
            search_path = args[2];
        }
        if (std.mem.endsWith(u8, search_path, ".ei")) {
            try source_alloc.print("import {{}} from \"{s}\"\n", .{search_path});
        } else {
            var dir = std.Io.Dir.cwd().openDir(io, search_path, .{ .iterate = true }) catch |err| {
                std.debug.print("Failed to open test path '{s}': {}\n", .{ search_path, err });
                return;
            };
            defer dir.close(io);
            var walker = try dir.walk(allocator);
            defer walker.deinit();

            while (try walker.next(io)) |entry| {
                if (entry.kind == .file) {
                    if (std.mem.endsWith(u8, entry.basename, "_test.ei")) {
                        const full_import_path = try std.fs.path.join(allocator, &.{ search_path, entry.path });
                        defer allocator.free(full_import_path);
                        try source_alloc.print("import {{}} from \"{s}\"\n", .{full_import_path});
                    }
                }
            }
        }
        if (source_alloc.items.len == 0) {
            std.debug.print("No tests found.\n", .{});
            return;
        }
    } else {
        if (args.len < 3) {
            std.debug.print("Error: Missing file argument.\n", .{});
            return;
        }
        filename = args[2];
        if (!std.mem.endsWith(u8, filename, ".ei")) {
            std.debug.print("Error: Unsupported file extension. Please use .ei files.\n", .{});
            return;
        }
        const file_content = try std.Io.Dir.cwd().readFileAlloc(io, filename, allocator, .limited(1024 * 1024));
        defer allocator.free(file_content);
        try source_alloc.appendSlice(file_content);
    }
    const source = source_alloc.items;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "synthetic_test.ei", .data = source });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var registry = @import("core/type_checker/core.zig").ModuleRegistry.init(arena.allocator());
    defer registry.deinit();

    var queue = ArrayList([]const u8).init(arena.allocator());
    defer queue.deinit();

    const std_modules = @import("core/type_checker/infer_decl.zig").std_modules;

    const resolved_entry_path = try arena.allocator().dupe(u8, filename);
    try queue.append(resolved_entry_path);

    var queue_idx: usize = 0;
    var ast_root: *ast.ASTNode = undefined;
    while (queue_idx < queue.items.len) : (queue_idx += 1) {
        const cur_path = queue.items[queue_idx];
        if (registry.modules.contains(cur_path)) continue;

        var source_content: []const u8 = undefined;
        var is_std = false;

        if (std.mem.startsWith(u8, cur_path, "std/")) {
            const pkg_name = cur_path[4..];
            if (std_modules.get(pkg_name)) |src| {
                source_content = src;
                is_std = true;
            } else {
                std.debug.print("Error: Unknown standard library package 'std.{s}'\n", .{pkg_name});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, cur_path, "synthetic_test.ei")) {
            source_content = source;
        } else {
            source_content = std.Io.Dir.cwd().readFileAlloc(io, cur_path, arena.allocator(), .limited(1024 * 1024)) catch |err| {
                std.debug.print("Error: Failed to read module file '{s}': {}\n", .{ cur_path, err });
                std.process.exit(1);
            };
        }

        var p = parser.Parser.init(arena.allocator(), source_content);
        const ast_root_mod = p.parse() catch |err| {
            std.debug.print("Failed to parse module '{s}'. Error: {}\n", .{ cur_path, err });
            std.process.exit(1);
        };
        if (p.had_error) {
            std.process.exit(1);
        }

        if (queue_idx == 0) {
            ast_root = ast_root_mod;
        }

        const basename = std.fs.path.basename(cur_path);
        const ext_idx = std.mem.lastIndexOf(u8, basename, ".") orelse basename.len;
        const prefix = basename[0..ext_idx];

        var checker = try arena.allocator().create(@import("core/type_checker/core.zig").TypeChecker);
        checker.* = @import("core/type_checker/core.zig").TypeChecker.init(arena.allocator(), source_content, cur_path);
        checker.io = io;
        checker.module_prefix = if (queue_idx == 0) null else prefix;
        checker.is_test_mode = is_test;
        checker.registry = &registry;

        try checker.injectImplicitImports(ast_root_mod);

        try registry.modules.put(try arena.allocator().dupe(u8, cur_path), .{
            .filename = try arena.allocator().dupe(u8, cur_path),
            .source = source_content,
            .ast_root = ast_root_mod,
            .checker = checker,
            .module_prefix = if (queue_idx == 0) "" else prefix,
        });
        try registry.ordered_modules.append(try arena.allocator().dupe(u8, cur_path));

        // Scan for imports
        if (ast_root_mod.data == .program) {
            const dir_path = std.fs.path.dirname(cur_path) orelse ".";
            for (ast_root_mod.data.program.statements) |stmt| {
                if (stmt.data == .import_stmt) {
                    const i = &stmt.data.import_stmt;
                    var actual_module_path = i.module_path;
                    if (!std.mem.endsWith(u8, actual_module_path, ".ei")) {
                        actual_module_path = try std.fmt.allocPrint(arena.allocator(), "{s}.ei", .{actual_module_path});
                    }
                    var import_resolved_path: []const u8 = undefined;
                    if (std.mem.startsWith(u8, actual_module_path, "std.")) {
                        const pkg_name = actual_module_path[4..];
                        import_resolved_path = try std.fmt.allocPrint(arena.allocator(), "std/{s}", .{pkg_name});
                    } else {
                        if (std.mem.eql(u8, dir_path, ".")) {
                            import_resolved_path = actual_module_path;
                        } else {
                            import_resolved_path = try std.fs.path.join(arena.allocator(), &.{ dir_path, actual_module_path });
                        }
                    }
                    try queue.append(import_resolved_path);
                }
            }
        }
    }

    // Pass 2a: Declare Class and Object Types (Dependencies first: reverse queue order)
    const modules_slice = registry.ordered_modules.items;
    var idx: usize = modules_slice.len;
    while (idx > 0) {
        idx -= 1;
        const path = modules_slice[idx];
        const mod = registry.modules.get(path).?;
        try mod.checker.declareTypes(mod.ast_root);
    }

    // Pass 2b: Declare Signatures (constructors, methods, functions, libraries)
    idx = modules_slice.len;
    while (idx > 0) {
        idx -= 1;
        const path = modules_slice[idx];
        const mod = registry.modules.get(path).?;
        try mod.checker.declareSignatures(mod.ast_root);
    }

    // Pass 2c: Resolve Imports (link/copy symbols between modules)
    idx = modules_slice.len;
    while (idx > 0) {
        idx -= 1;
        const path = modules_slice[idx];
        const mod = registry.modules.get(path).?;
        try mod.checker.resolveImports(mod.ast_root);
    }

    // Pass 3: Validate Bodies
    idx = modules_slice.len;
    while (idx > 0) {
        idx -= 1;
        const path = modules_slice[idx];
        const mod = registry.modules.get(path).?;
        mod.checker.validate(mod.ast_root) catch {
            std.process.exit(1);
        };
    }

    // Consolidate classes, objects, contracts, and aliases for the CTranspiler
    var global_classes_ast = std.StringHashMap(*ast.ASTNode).init(arena.allocator());
    var global_objects_ast = std.StringHashMap(*ast.ASTNode).init(arena.allocator());
    var global_enums_ast = std.StringHashMap(*ast.ASTNode).init(arena.allocator());
    var global_contracts_ast = std.StringHashMap(*ast.ASTNode).init(arena.allocator());
    var global_alias_map = std.StringHashMap([]const u8).init(arena.allocator());

    for (registry.ordered_modules.items) |path| {
        const mod = registry.modules.get(path).?;
        var class_it = mod.checker.classes_ast.iterator();
        while (class_it.next()) |entry| {
            try global_classes_ast.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        var object_it = mod.checker.objects_ast.iterator();
        while (object_it.next()) |entry| {
            try global_objects_ast.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        var enum_it = mod.checker.enums_ast.iterator();
        while (enum_it.next()) |entry| {
            try global_enums_ast.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        var contract_it = mod.checker.contracts_ast.iterator();
        while (contract_it.next()) |entry| {
            try global_contracts_ast.put(entry.key_ptr.*, entry.value_ptr.*);
            if (entry.value_ptr.*.data == .contract_decl) {
                try global_contracts_ast.put(entry.value_ptr.*.data.contract_decl.name, entry.value_ptr.*);
            }
        }
        var alias_it = mod.checker.alias_map.iterator();
        while (alias_it.next()) |entry| {
            try global_alias_map.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    var transpiler = c_transpiler.CTranspiler.init(allocator);
    transpiler.is_test_mode = is_test;
    transpiler.classes_ast = &global_classes_ast;
    transpiler.objects_ast = &global_objects_ast;
    transpiler.enums_ast = &global_enums_ast;
    transpiler.contracts_ast = &global_contracts_ast;
    transpiler.alias_map = &global_alias_map;
    transpiler.source_file = filename; // used for #line directives in C output
    defer transpiler.deinit();

    const c_code = try transpiler.transpile(ast_root);
    defer allocator.free(c_code);

    const out_c_filename = "temp_out.c";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_c_filename, .data = c_code });
    // defer std.fs.cwd().deleteFile(out_c_filename) catch {};

    // Invoke zig cc
    const basename = std.fs.path.basename(filename);
    const ext = std.fs.path.extension(basename);
    const out_bin_name = basename[0 .. basename.len - ext.len];
    const final_bin = if (is_test) "test_runner" else if (out_bin_name.len > 0) out_bin_name else "a.out";

    const actual_zig = "zig";

    var cc_argv = ArrayList([]const u8).init(allocator);
    try cc_argv.appendSlice(&[_][]const u8{ actual_zig, "cc", "-O0", "-fwrapv", "-fno-sanitize=undefined" });
    if (builtin.target.os.tag == .macos) {
        try cc_argv.appendSlice(&[_][]const u8{ "-I", "/opt/homebrew/include", "-L", "/opt/homebrew/lib" });
    }
    try cc_argv.appendSlice(&[_][]const u8{ out_c_filename, "-lgc" });

    var lib_it = transpiler.link_libraries.keyIterator();
    while (lib_it.next()) |lib_name| {
        const flag = try std.fmt.allocPrint(allocator, "-l{s}", .{lib_name.*});
        try cc_argv.append(flag);

        const macro = try std.fmt.allocPrint(allocator, "-DEIWA_USE_{s}", .{lib_name.*});
        for (macro) |*c| {
            c.* = std.ascii.toUpper(c.*);
        }
        try cc_argv.append(macro);
    }

    try cc_argv.appendSlice(&[_][]const u8{ "-o", final_bin });

    const result = try std.process.run(allocator, io, .{
        .argv = cc_argv.items,
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    if (result.term != .exited or result.term.exited != 0) {
        // Filter C stderr: show only semantic errors, hide internal C details.
        // With #line directives in the generated C, clang now reports errors as:
        //   person.ei:2:172: error: ...
        // instead of temp_out.c:NNN:COL: error: ...
        var found_error = false;
        var lines = std.mem.splitScalar(u8, result.stderr, '\n');
        while (lines.next()) |line| {
            // Only process lines that contain 'error:'
            if (std.mem.indexOf(u8, line, "error:") == null) continue;
            if (std.mem.indexOf(u8, line, "too many errors") != null) continue;

            if (std.mem.indexOf(u8, line, "temp_out.c:")) |_| {
                // Fallback: error on a C-internal line (outside #line'd regions)
                if (std.mem.indexOf(u8, line, "error: ")) |err_pos| {
                    const raw_msg = line[err_pos + 7 ..];
                    const msg = translateCError(raw_msg);
                    if (!found_error) {
                        std.debug.print("\nCompilation error:\n", .{});
                        found_error = true;
                    }
                    std.debug.print("  → {s}\n", .{msg});
                }
            } else if (std.mem.indexOf(u8, line, ".ei:")) |ae_pos| {
                // Error mapped back to an Eiwa source file via #line directive
                // Format: path/to/file.ei:LINE:COL: error: MESSAGE
                const location_part = line[0 .. ae_pos + 3]; // e.g. "../../samples/person.ei"
                // Extract just the basename for cleaner output
                const ae_basename = std.fs.path.basename(location_part);
                // Find line number after the .ei:
                const after_ae = line[ae_pos + 4 ..];
                var col_it = std.mem.splitScalar(u8, after_ae, ':');
                const line_num = col_it.next() orelse "?";
                // Find the error message
                if (std.mem.indexOf(u8, line, "error: ")) |err_pos| {
                    std.debug.print("RAW C ERROR LINE: {s}\n", .{line});
                    const raw_msg = line[err_pos + 7 ..];
                    const msg = translateCError(raw_msg);
                    if (!found_error) {
                        std.debug.print("\nCompilation error:\n", .{});
                        found_error = true;
                    }
                    std.debug.print("  → {s}:{s}: {s}\n", .{ ae_basename, line_num, msg });
                }
            } else {
                // Non-file error (e.g. linker errors)
                if (!found_error) {
                    std.debug.print("\nCompilation error:\n", .{});
                    found_error = true;
                }
                std.debug.print("  → {s}\n", .{line});
            }
        }
        if (!found_error) {
            std.debug.print("\nCompilation error (internal):\n{s}\n", .{result.stderr});
        }
        std.process.exit(1);
    }

    if (!is_build) {
        // Execute final binary
        var exe_path_buf: [1024]u8 = undefined;
        const exe_path = try std.fmt.bufPrint(&exe_path_buf, "./{s}", .{final_bin});

        var child = try std.process.spawn(io, .{
            .argv = &[_][]const u8{exe_path},
        });
        const term = try child.wait(io);

        if (term == .exited and term.exited != 0) {
            std.process.exit(term.exited);
        } else if (term == .signal) {
            std.debug.print("Error: Test runner crashed with signal {}\n", .{term.signal});
            std.process.exit(1);
        }
    } else {
        std.debug.print("Successfully built {s}\n", .{final_bin});
    }
}

test "imports" {
    _ = @import("core/ast.zig");
    _ = @import("frontend/lexer.zig");
    _ = @import("frontend/parser/core.zig");
    _ = @import("backend/c_transpiler/core.zig");
}

/// Translate low-level C compiler error messages into user-friendly Eiwa errors.
/// Hides internal details like mangled names and C-specific type nomenclature.
fn translateCError(msg: []const u8) []const u8 {
    // Int passed where String is expected (e.g. string concatenation without .toString())
    if (std.mem.indexOf(u8, msg, "incompatible integer to pointer") != null and
        std.mem.indexOf(u8, msg, "core_String") != null)
    {
        return "Type error: cannot use an Int value where a String is expected. Did you forget .toString()?";
    }
    // Null dereference / incomplete type
    if (std.mem.indexOf(u8, msg, "incomplete definition of type") != null) {
        return "Type error: attempted to use an undefined type. Check your imports.";
    }
    // Undeclared identifier
    if (std.mem.indexOf(u8, msg, "use of undeclared identifier") != null) {
        return "Name error: reference to an undeclared symbol. Check your imports and variable names.";
    }
    // Generic incompatible pointer (type mismatch between structs)
    if (std.mem.indexOf(u8, msg, "incompatible pointer types") != null) {
        return "Type error: incompatible types in assignment or function call.";
    }
    // Linker errors
    if (std.mem.indexOf(u8, msg, "undefined reference") != null or
        std.mem.indexOf(u8, msg, "undefined symbol") != null)
    {
        return "Linker error: symbol not found. Ensure all required modules are imported.";
    }
    // Fallback: return the raw message (still better than the full C trace)
    return msg;
}

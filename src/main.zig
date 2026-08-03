const std = @import("std");
const builtin = @import("builtin");
const compat = @import("core/compat.zig");
const ArrayList = compat.ArrayList;
const lexer = @import("frontend/lexer.zig");
const parser = @import("frontend/parser/core.zig");
const c_transpiler = @import("backend/c_transpiler/core.zig");
const ast = @import("core/ast.zig");
const type_checker = @import("core/type_checker/core.zig");
const build_options = @import("build_options");
const llvm_emitter = if (build_options.has_llvm) @import("backend/llvm_emitter/core.zig") else struct {};

pub const BackendKind = enum {
    c,
    llvm,
};

/// Converts a filesystem path (relative to the module root) into a
/// root-relative dot import path. e.g. "samples/tests/foo_test.ei" -> ".samples.tests.foo_test".
fn toRootDotPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var rel = path;
    if (std.mem.startsWith(u8, rel, "./")) {
        rel = rel[2..];
    }
    const root = type_checker.module_root;
    if (!std.mem.eql(u8, root, ".")) {
        if (std.mem.startsWith(u8, rel, root)) {
            const rest = rel[root.len..];
            if (rest.len > 0 and std.mem.startsWith(u8, rest, "/")) {
                rel = rest[1..];
            }
        }
    }
    var name = rel;
    if (std.mem.endsWith(u8, name, ".ei")) {
        name = name[0 .. name.len - 3];
    }
    var buf = ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    try buf.append('.');
    for (name) |c| {
        try buf.append(if (c == '/') '.' else c);
    }
    return buf.toOwnedSlice();
}

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

    if (args.len >= 2 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) {
        std.debug.print(
            \\eiwac - Eiwa compiler backend
            \\
            \\Usage: eiwac <command> [options] [file.ei] [program args...]
            \\
            \\Commands:
            \\  run        Compile and execute the program
            \\  build      Compile to a native binary
            \\  test       Run test blocks ("test \"name\" {{ ... }}")
            \\
            \\Options:
            \\  --backend=c      Use the C backend (stable)
            \\  --backend=llvm   Use the LLVM backend (if available)
            \\  --release        Optimized build (LLVM backend)
            \\  -o <name>        Output binary name (build command)
            \\  -I, -L, -l, -D   Extra flags forwarded to the C compiler
            \\  -h, --help       Show this help
            \\
            \\Extra positional arguments after the file are forwarded to
            \\the program when using the run command.
            \\
        , .{});
        return;
    }

    if (args.len < 2 or (!std.mem.eql(u8, args[1], "run") and !std.mem.eql(u8, args[1], "build") and !std.mem.eql(u8, args[1], "test"))) {
        std.debug.print("Usage: eiwac <run|build|test> [options] [file.ei]  (see eiwac --help)\n", .{});
        return;
    }
    const is_build = std.mem.eql(u8, args[1], "build");
    const is_test = std.mem.eql(u8, args[1], "test");

    var source_alloc = ArrayList(u8).init(allocator);
    defer source_alloc.deinit();

    var filename: []const u8 = "synthetic_test.ei";

    const io = init.io;

    var cli_c_flags = ArrayList([]const u8).init(allocator);
    defer cli_c_flags.deinit();
    var positionals = ArrayList([]const u8).init(allocator);
    defer positionals.deinit();

    var backend_kind: BackendKind = if (build_options.has_llvm) .llvm else .c;
    var backend_explicit: bool = false;
    var is_release: bool = false;
    var output_name: ?[]const u8 = null;
    var module_paths = ArrayList([]const u8).init(allocator);
    defer module_paths.deinit();

    var arg_idx: usize = 2;
    while (arg_idx < args.len) : (arg_idx += 1) {
        const arg = args[arg_idx];
        if (std.mem.startsWith(u8, arg, "--backend=")) {
            const val = arg["--backend=".len..];
            if (std.mem.eql(u8, val, "llvm")) {
                backend_kind = .llvm;
            } else if (std.mem.eql(u8, val, "c")) {
                backend_kind = .c;
            } else {
                std.debug.print("Error: unknown backend '{s}'. Valid options: --backend=c, --backend=llvm\n", .{val});
                std.process.exit(1);
            }
            backend_explicit = true;
        } else if (std.mem.eql(u8, arg, "-o")) {
            if (arg_idx + 1 >= args.len) {
                std.debug.print("Error: -o requires an output name\n", .{});
                return;
            }
            arg_idx += 1;
            output_name = args[arg_idx];
        } else if (std.mem.eql(u8, arg, "--module-path")) {
            if (arg_idx + 1 >= args.len) {
                std.debug.print("Error: --module-path requires a directory\n", .{});
                return;
            }
            arg_idx += 1;
            try module_paths.append(args[arg_idx]);
        } else if (std.mem.eql(u8, arg, "--release")) {
            is_release = true;
        } else if (std.mem.startsWith(u8, arg, "-I") or std.mem.startsWith(u8, arg, "-L") or std.mem.startsWith(u8, arg, "-l") or std.mem.startsWith(u8, arg, "-D")) {
            if (arg.len == 2 and arg_idx + 1 < args.len) {
                try cli_c_flags.append(arg);
                arg_idx += 1;
                try cli_c_flags.append(args[arg_idx]);
            } else {
                try cli_c_flags.append(arg);
            }
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try cli_c_flags.append(arg);
        } else {
            try positionals.append(arg);
        }
    }

    type_checker.module_search_paths = module_paths.items;
    type_checker.module_search_io = io;

    if (is_test) {
        var search_path: []const u8 = ".";
        if (positionals.items.len > 0) {
            search_path = positionals.items[0];
        }
        if (std.mem.endsWith(u8, search_path, ".ei")) {
            //TODO: isso foi modificado porque deu esse erro:
            // ➜ ./bin/eiwac test samples/tests/oop_test.ei --backend=c
            // Error: Failed to read module file 'samples/tests/samples/oop.ei': error.FileNotFound
            //type_checker.module_root = std.fs.path.dirname(search_path) orelse ".";
            type_checker.module_root = ".";
            const dot_path = try toRootDotPath(allocator, search_path);
            defer allocator.free(dot_path);
            try source_alloc.print("import {{}} from \"{s}\"\n", .{dot_path});
        } else {
            var dir = std.Io.Dir.cwd().openDir(io, search_path, .{ .iterate = true }) catch |err| {
                std.debug.print("Failed to open test path '{s}': {}\n", .{ search_path, err });
                return;
            };
            defer dir.close(io);
            type_checker.module_root = ".";
            var walker = try dir.walk(allocator);
            defer walker.deinit();

            while (try walker.next(io)) |entry| {
                if (entry.kind == .file) {
                    if (std.mem.endsWith(u8, entry.basename, "_test.ei")) {
                        var rel_path = entry.path;
                        if (std.mem.startsWith(u8, rel_path, "./")) {
                            rel_path = rel_path[2..];
                        }
                        const dot_path = try toRootDotPath(allocator, rel_path);
                        defer allocator.free(dot_path);
                        try source_alloc.print("import {{}} from \"{s}\"\n", .{dot_path});
                    }
                }
            }
        }
        if (source_alloc.items.len == 0) {
            std.debug.print("No tests found.\n", .{});
            return;
        }
    } else {
        if (positionals.items.len == 0) {
            std.debug.print("Error: Missing file argument.\n", .{});
            return;
        }
        filename = positionals.items[0];
        if (!std.mem.endsWith(u8, filename, ".ei")) {
            std.debug.print("Error: Unsupported file extension. Please use .ei files.\n", .{});
            return;
        }
        var module_root = std.fs.path.dirname(filename) orelse ".";
        if (module_root.len == 0) module_root = ".";
        type_checker.module_root = module_root;
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
                    const import_resolved_path = type_checker.resolveModulePath(arena.allocator(), dir_path, actual_module_path) catch |err| {
                        std.debug.print("\n\x1b[31mError\x1b[0m in {s}:{}:{}:\n", .{ cur_path, stmt.line, stmt.column });
                        std.debug.print("ImportError: invalid module path '{s}': {s}\n", .{ i.module_path, @errorName(err) });
                        std.debug.print("Use '.' separators (e.g. \"mcp.mcp_builder\") and a leading '.' for the project root (e.g. \".arest_builder\").\n", .{});
                        std.process.exit(1);
                    };
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

    if (backend_kind == .llvm) {
        if (!build_options.has_llvm) {
            std.debug.print("Error: The Eiwa compiler was built without LLVM support or LLVM 21+ was not found on your system.\n", .{});
            std.process.exit(1);
        }
        var emitter = try llvm_emitter.LLVMEmitter.init(allocator, filename, is_release);
        defer emitter.deinit();
        emitter.is_test_mode = is_test;

        try emitter.emitModule(ast_root);

        if (is_build) {
            const basename = std.fs.path.basename(filename);
            const ext = std.fs.path.extension(basename);
            const out_bin_name = basename[0 .. basename.len - ext.len];
            const final_bin = output_name orelse (if (out_bin_name.len > 0) out_bin_name else "a.out");

            try emitter.emitNativeBinary(final_bin, io);
            std.debug.print("LLVM backend: Successfully built native binary '{s}' (Release: {})\n", .{ final_bin, is_release });
        } else {
            const exit_code = try emitter.executeJIT();
            if (exit_code != 0) {
                std.process.exit(@intCast(exit_code));
            }
        }
        return;
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
    const final_bin = if (is_test) "test_runner" else output_name orelse (if (out_bin_name.len > 0) out_bin_name else "a.out");

    const actual_zig = "zig";

    const self_src_dir = build_options.eiwa_home;
    const repo_root = std.fs.path.dirname(self_src_dir) orelse ".";

    const inc_transpiler = try std.fs.path.join(allocator, &.{ repo_root, "src/backend/c_transpiler" });
    const inc_third_party = try std.fs.path.join(allocator, &.{ repo_root, "src/runtime/third_party" });
    const inc_transpiler_flag = try std.fmt.allocPrint(allocator, "-I{s}", .{inc_transpiler});
    const inc_third_party_flag = try std.fmt.allocPrint(allocator, "-I{s}", .{inc_third_party});

    var cc_argv = ArrayList([]const u8).init(allocator);
    try cc_argv.appendSlice(&[_][]const u8{ actual_zig, "cc", "-O0", "-fwrapv", "-fno-sanitize=undefined" });
    if (builtin.target.os.tag == .macos) {
        try cc_argv.appendSlice(&[_][]const u8{ "-I", "/opt/homebrew/include", "-L", "/opt/homebrew/lib" });
    }
    try cc_argv.appendSlice(&[_][]const u8{
        inc_transpiler_flag,
        inc_third_party_flag,
        out_c_filename,
        "-lgc",
    });

    // Build requirements declared by `lib` annotations in Eiwa sources.
    var inc_it = transpiler.c_includes.keyIterator();
    while (inc_it.next()) |dir| {
        try cc_argv.append(try std.fmt.allocPrint(allocator, "-I{s}", .{dir.*}));
    }
    var def_it = transpiler.c_defines.keyIterator();
    while (def_it.next()) |def| {
        try cc_argv.append(try std.fmt.allocPrint(allocator, "-D{s}", .{def.*}));
    }
    var src_it = transpiler.c_sources.keyIterator();
    while (src_it.next()) |src| {
        try cc_argv.append(src.*);
    }

    var lib_it = transpiler.link_libraries.keyIterator();
    while (lib_it.next()) |lib_name| {
        if (try resolvePkgConfig(allocator, io, lib_name.*)) |flags| {
            for (flags) |flag| {
                try cc_argv.append(flag);
            }
        } else {
            const flag = try std.fmt.allocPrint(allocator, "-l{s}", .{lib_name.*});
            try cc_argv.append(flag);
        }

        const macro = try std.fmt.allocPrint(allocator, "-DEIWA_USE_{s}", .{lib_name.*});
        for (macro) |*c| {
            c.* = std.ascii.toUpper(c.*);
        }
        try cc_argv.append(macro);
    }

    for (cli_c_flags.items) |flag| {
        try cc_argv.append(flag);
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
        var err_it = std.mem.splitScalar(u8, result.stderr, '\n');
        while (err_it.next()) |line| {
            if (std.mem.indexOf(u8, line, "error:") != null) {
                std.debug.print("C ERROR: {s}\n", .{line});
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

        var child_argv = ArrayList([]const u8).init(allocator);
        defer child_argv.deinit();
        try child_argv.append(exe_path);
        if (positionals.items.len > 1) {
            for (positionals.items[1..]) |extra| {
                try child_argv.append(extra);
            }
        }

        var child = try std.process.spawn(io, .{
            .argv = child_argv.items,
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

fn resolvePkgConfig(allocator: std.mem.Allocator, io: anytype, lib_name: []const u8) !?[][]const u8 {
    const pkg1 = try std.fmt.allocPrint(allocator, "lib{s}", .{lib_name});
    defer allocator.free(pkg1);
    const names = [_][]const u8{ pkg1, lib_name };
    const binaries = [_][]const u8{ "pkg-config", "/opt/homebrew/bin/pkg-config" };

    const extra_paths = try std.fmt.allocPrint(allocator, "/opt/homebrew/opt/lib{s}/lib/pkgconfig:/opt/homebrew/opt/{s}/lib/pkgconfig:/usr/local/opt/lib{s}/lib/pkgconfig:/usr/local/opt/{s}/lib/pkgconfig:/opt/homebrew/lib/pkgconfig:/usr/local/lib/pkgconfig", .{ lib_name, lib_name, lib_name, lib_name });
    defer allocator.free(extra_paths);

    const env_var_arg = try std.fmt.allocPrint(allocator, "PKG_CONFIG_PATH={s}", .{extra_paths});
    defer allocator.free(env_var_arg);

    for (names) |name| {
        for (binaries) |bin| {
            const res = std.process.run(allocator, io, .{
                .argv = &[_][]const u8{ "/usr/bin/env", env_var_arg, bin, "--cflags", "--libs", name },
            }) catch continue;
            defer {
                allocator.free(res.stdout);
                allocator.free(res.stderr);
            }

            if (res.term == .exited and res.term.exited == 0 and res.stdout.len > 0) {
                var flags = ArrayList([]const u8).init(allocator);
                var it = std.mem.tokenizeAny(u8, res.stdout, " \t\r\n");
                while (it.next()) |tok| {
                    if (tok.len > 0) {
                        try flags.append(try allocator.dupe(u8, tok));
                    }
                }
                if (flags.items.len > 0) {
                    return try flags.toOwnedSlice();
                }
            }
        }
    }
    return null;
}

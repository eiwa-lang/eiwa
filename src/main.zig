const std = @import("std");
const builtin = @import("builtin");
const compat = @import("core/compat.zig");
const ArrayList = compat.ArrayList;
const lexer = @import("frontend/lexer.zig");
const parser = @import("frontend/parser/core.zig");
const ast = @import("core/ast.zig");
const type_checker = @import("core/type_checker/core.zig");
const coroutines = @import("core/coroutines.zig");
const coroutines_transform = @import("core/coroutines_transform.zig");
const eiwa_home = @import("core/eiwa_home.zig");
const build_options = @import("build_options");
const llvm_emitter = if (build_options.has_llvm) @import("backend/llvm_emitter/core.zig") else struct {};

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

// --- Clean crash reporting --------------------------------------------------
// When a compiled Eiwa program crashes (JIT), Zig's default handler dumps its
// own runtime frames (main/run/start/callMain) which are just noise — the
// error lives in the JIT'd program frames. Install a handler that reports the
// fault address and only the non-toolchain frames (JIT code + C libraries),
// keeping the crash actionable instead of a wall of Zig internals.

const Dl_info = extern struct {
    dli_fname: ?[*:0]const u8,
    dli_fbase: ?*anyopaque,
    dli_sname: ?[*:0]const u8,
    dli_saddr: ?*anyopaque,
};
extern "c" fn dladdr(addr: *const anyopaque, info: *Dl_info) c_int;

var eiwac_base: ?*anyopaque = null;

fn crashWrite(s: []const u8) void {
    _ = std.c.write(2, s.ptr, s.len);
}

fn crashWriteFrame(addr: usize) void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "    0x{x}\n", .{addr}) catch return;
    crashWrite(s);
}

fn crashHandler(sig: std.posix.SIG, info: *const std.posix.siginfo_t, ctx_ptr: ?*anyopaque) callconv(.c) void {
    const name = switch (sig) {
        .SEGV => "Segmentation fault",
        .ILL => "Illegal instruction",
        .BUS => "Bus error",
        .ABRT => "Aborted",
        .TRAP => "Trap",
        .FPE => "Arithmetic exception",
        else => "Fatal signal",
    };
    const fault_addr: ?usize = switch (builtin.os.tag) {
        .macos => @intFromPtr(info.addr),
        .linux => @intFromPtr(info.fields.sigfault.addr),
        else => null,
    };

    crashWrite("\n\x1b[1;31mRuntime Error:\x1b[0m ");
    crashWrite(name);
    if (sig == .SEGV and (fault_addr == null or fault_addr.? < 4096)) {
        crashWrite(" (null pointer dereference)");
    }
    if (fault_addr) |a| {
        crashWrite(" at address ");
        crashWriteFrame(a);
    } else {
        crashWrite("\n");
    }
    crashWrite("\x1b[1;36mStack Trace (JIT):\x1b[0m\n");
    var addr_buf: [48]usize = undefined;
    if (ctx_ptr) |raw_ctx| {
        if (std.debug.cpu_context.fromPosixSignalContext(raw_ctx)) |native_ctx| {
            const stack = std.debug.captureCurrentStackTrace(.{ .context = &native_ctx, .allow_unsafe_unwind = true }, &addr_buf);
            var frame_idx: usize = 0;
            for (stack.return_addresses) |ra| {
                var dli: Dl_info = undefined;
                if (dladdr(@ptrFromInt(ra), &dli) != 0) {
                    // Skip frames inside the eiwac binary itself (main/run/start):
                    // they are the toolchain wrapper, not the failing program.
                    if (dli.dli_fbase != null and dli.dli_fbase == eiwac_base) continue;

                    var frame_buf: [256]u8 = undefined;
                    if (dli.dli_sname) |sname| {
                        const sym = std.mem.sliceTo(sname, 0);
                        const line_str = std.fmt.bufPrint(&frame_buf, "  {d}: 0x{x} in {s}\n", .{ frame_idx, ra, sym }) catch continue;
                        crashWrite(line_str);
                    } else {
                        const line_str = std.fmt.bufPrint(&frame_buf, "  {d}: 0x{x}\n", .{ frame_idx, ra }) catch continue;
                        crashWrite(line_str);
                    }
                } else {
                    var frame_buf: [64]u8 = undefined;
                    const line_str = std.fmt.bufPrint(&frame_buf, "  {d}: 0x{x}\n", .{ frame_idx, ra }) catch continue;
                    crashWrite(line_str);
                }
                frame_idx += 1;
            }
        }
    }
    crashWrite("\n");
    std.process.exit(@as(u8, @truncate(128 + @intFromEnum(sig))));
}

fn installCleanCrashHandler() void {
    var self_info: Dl_info = undefined;
    if (dladdr(@ptrFromInt(@returnAddress()), &self_info) != 0) {
        eiwac_base = self_info.dli_fbase;
    }
    const act: std.posix.Sigaction = .{
        .handler = .{ .sigaction = crashHandler },
        .mask = std.posix.sigemptyset(),
        .flags = (std.posix.SA.SIGINFO | std.posix.SA.RESTART | std.posix.SA.RESETHAND | std.posix.SA.ONSTACK),
    };
    std.posix.sigaction(.SEGV, &act, null);
    std.posix.sigaction(.ILL, &act, null);
    std.posix.sigaction(.BUS, &act, null);
    std.posix.sigaction(.FPE, &act, null);
    std.posix.sigaction(.TRAP, &act, null);
    std.posix.sigaction(.ABRT, &act, null);
}

pub fn main(init: std.process.Init) !void {
    installCleanCrashHandler();
    // Never let a Zig error value reach the runtime's default printer (which
    // dumps `error: <name>` + a native stack trace). Eiwa diagnostics are
    // reported inline before the error propagates; here we just exit cleanly.
    run(init) catch |err| {
        if (err != error.ParseError and err != error.TypeError and err != error.LLVMVerificationFailed) {
            std.debug.print("Error: compilation failed ({s}).\n", .{@errorName(err)});
        }
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
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
            \\  --release        Optimized build
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
    eiwa_home.io = io;

    var cli_c_flags = ArrayList([]const u8).init(allocator);
    defer cli_c_flags.deinit();
    var positionals = ArrayList([]const u8).init(allocator);
    defer positionals.deinit();

    var is_release: bool = false;
    var output_name: ?[]const u8 = null;
    var module_paths = ArrayList([]const u8).init(allocator);
    defer module_paths.deinit();

    var arg_idx: usize = 2;
    while (arg_idx < args.len) : (arg_idx += 1) {
        const arg = args[arg_idx];
        if (std.mem.eql(u8, arg, "-o")) {
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

        if (!std.mem.endsWith(u8, search_path, ".ei")) {
            var dir = std.Io.Dir.cwd().openDir(io, search_path, .{ .iterate = true }) catch |err| {
                std.debug.print("Failed to open test path '{s}': {}\n", .{ search_path, err });
                std.process.exit(1);
            };
            defer dir.close(io);

            var walker = try dir.walk(allocator);
            defer walker.deinit();

            var test_files = ArrayList([]const u8).init(allocator);
            defer test_files.deinit();

            while (try walker.next(io)) |entry| {
                if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, "_test.ei")) {
                    const full_path = try std.fs.path.join(allocator, &[_][]const u8{ search_path, entry.path });
                    try test_files.append(full_path);
                }
            }

            if (test_files.items.len == 0) {
                std.debug.print("No tests found in '{s}'.\n", .{search_path});
                std.process.exit(0);
            }

            const CTimeSpec = extern struct {
                tv_sec: i64,
                tv_nsec: c_long,
            };
            const c_clock = struct {
                extern fn clock_gettime(clk_id: c_int, tp: *CTimeSpec) c_int;
            };

            var total_passed: usize = 0;
            var total_failed: usize = 0;

            var start_ts: CTimeSpec = undefined;
            _ = c_clock.clock_gettime(0, &start_ts);

            for (test_files.items) |tfile| {
                var child_args = ArrayList([]const u8).init(allocator);
                defer child_args.deinit();
                try child_args.appendSlice(&[_][]const u8{ args[0], "test", tfile });
                if (is_release) try child_args.append("--release");

                var child = try std.process.spawn(io, .{ .argv = child_args.items });
                const term = try child.wait(io);
                if (term == .exited and term.exited == 0) {
                    total_passed += 1;
                } else {
                    std.debug.print("*[FAIL] {s}\n", .{tfile});
                    total_failed += 1;
                }
            }

            var end_ts: CTimeSpec = undefined;
            _ = c_clock.clock_gettime(0, &end_ts);
            const elapsed_sec = @as(f64, @floatFromInt(end_ts.tv_sec - start_ts.tv_sec)) +
                @as(f64, @floatFromInt(end_ts.tv_nsec - start_ts.tv_nsec)) / 1_000_000_000.0;

            if (total_failed > 0) {
                std.debug.print("\nLLVM Test Suite: {d} PASSED, {d} FAILED in {d:.2}s\n", .{ total_passed, total_failed, elapsed_sec });
                std.process.exit(1);
            } else {
                std.debug.print("\nLLVM Test Suite: ALL {d} TESTS PASSED in {d:.2}s!\n", .{ total_passed, elapsed_sec });
                std.process.exit(0);
            }
        }

        type_checker.module_root = ".";
        const dot_path = try toRootDotPath(allocator, search_path);
        defer allocator.free(dot_path);
        try source_alloc.print("import {{}} from \"{s}\"\n", .{dot_path});
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
        p.filename = cur_path;
        const ast_root_mod = p.parse() catch {
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
    var global_trampolines = std.StringHashMap(*ast.ASTNode).init(arena.allocator());
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
        var tramp_it = mod.checker.trampolines.iterator();
        while (tramp_it.next()) |entry| {
            try global_trampolines.put(entry.key_ptr.*, entry.value_ptr.*);
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
        var skill_it = mod.checker.skills_ast.iterator();
        while (skill_it.next()) |entry| {
            try global_contracts_ast.put(entry.key_ptr.*, entry.value_ptr.*);
            if (entry.value_ptr.*.data == .skill_decl) {
                try global_contracts_ast.put(entry.value_ptr.*.data.skill_decl.name, entry.value_ptr.*);
            }
        }
        var alias_it = mod.checker.alias_map.iterator();
        while (alias_it.next()) |entry| {
            try global_alias_map.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    // Coroutines (stackless, inference): mark suspend functions and suspension
    // points before emission. The LLVM backend transforms marked functions.
    var global_functions_ast = std.StringHashMap(*ast.ASTNode).init(arena.allocator());
    for (registry.ordered_modules.items) |path| {
        const mod = registry.modules.get(path).?;
        var fn_it = mod.checker.functions_ast.iterator();
        while (fn_it.next()) |entry| {
            try global_functions_ast.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    coroutines.detectSuspendFunctions(arena.allocator(), &registry, &global_functions_ast) catch |err| {
        std.debug.print("Error: coroutine detection failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    // Fase C (P1): rewrite `val x = task { ... }` / `val x = r.await()` into the
    // stackless machinery (generated Continuation + Scheduler) before emission.
    coroutines_transform.transformProgram(arena.allocator(), &registry) catch |err| {
        std.debug.print("Error: coroutine transform failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    if (!build_options.has_llvm) {
        std.debug.print("Error: The Eiwa compiler was built without LLVM support or LLVM 21+ was not found on your system.\n", .{});
        std.process.exit(1);
    }
    const emitter = try allocator.create(llvm_emitter.LLVMEmitter);
    emitter.* = try llvm_emitter.LLVMEmitter.init(allocator, filename, is_release);
    // Bloco B: allocate via real GC_malloc/
    // GC_realloc (zeroed, GC-managed) instead of raw malloc. Always for
    // native builds (the binary links -lgc); for the JIT only when the
    // host eiwac links libgc. Must be set before emitModule.
    llvm_emitter.prefer_gc_alloc = is_build or llvm_emitter.has_gc;
    emitter.is_test_mode = is_test;
    emitter.contracts_ast = &global_contracts_ast;
    emitter.classes_ast = &global_classes_ast;
    emitter.cli_c_flags = cli_c_flags.items;
    emitter.registry = &registry;
    emitter.host_argv = args;
    // argv[0] is the program name (basename of the file); the rest are the
    // positional arguments after it. Exposed to Process.args()/argAt().
    {
        var argv = ArrayList([]const u8).init(arena.allocator());
        const prog_name = std.fs.path.basename(filename);
        try argv.append(prog_name);
        if (positionals.items.len > 1) {
            for (positionals.items[1..]) |extra| try argv.append(extra);
        }
        emitter.program_argv = argv.items;
    }

    try emitter.emitModule(ast_root);

    if (is_build) {
        const basename = std.fs.path.basename(filename);
        const ext = std.fs.path.extension(basename);
        const out_bin_name = basename[0 .. basename.len - ext.len];
        const final_bin = output_name orelse (if (out_bin_name.len > 0) out_bin_name else "a.out");

        try emitter.emitNativeBinary(final_bin, io);
        std.debug.print("LLVM backend: Successfully built native binary '{s}' (Release: {})\n", .{ final_bin, is_release });
    } else {
        const exit_code = try emitter.executeJIT(io);
        const code: u8 = if (exit_code < 0) 1 else @intCast(@min(exit_code, 255));
        std.process.exit(code);
    }
}

test "imports" {
    _ = @import("core/ast.zig");
    _ = @import("frontend/lexer.zig");
    _ = @import("frontend/parser/core.zig");
}


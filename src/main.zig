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
const case_checker = @import("core/case_checker.zig");
const target_mod = @import("core/target.zig");
const build_options = @import("build_options");
const llvm_emitter = if (build_options.has_llvm) @import("backend/llvm_emitter/core.zig") else struct {};



fn getProcessId() u32 {
    if (builtin.os.tag == .windows) {
        return @intCast(std.os.windows.GetCurrentProcessId());
    } else {
        return @intCast(std.c.getpid());
    }
}

// --- Parallel test harness helpers -------------------------------------------
// `eiwac test` spawns one child `eiwac test <file>` per `*_test.ei`. Each child
// compiles the file and runs its `test "name" { }` blocks, printing `[PASS]`/
// `*[FAIL]` per block plus a final `[SUMMARY] <n> passed, <m> failed` line, and
// exits with the failed-block count. The parent spawns children concurrently
// (bounded by CPU count so tests don't wait on each other to start) and counts
// test BLOCKS from each child's `[SUMMARY]`, not whole files.

const TestProc = struct {
    tfile: []const u8,
    child: std.process.Child,
};

const ChildResult = struct {
    term: std.process.Child.Term,
    output: []u8,
    /// True when the child was killed for exceeding the per-test deadline
    /// (a hung test must be reported, not allowed to freeze the whole suite).
    timed_out: bool = false,
};

/// Reads a spawned child's stdout+stderr pipes to EOF (concurrently, to avoid
/// pipe-buffer deadlocks) and waits for it. If the child has not finished by
/// `deadline` it is killed and the output collected so far is returned with
/// `timed_out` set. Caller owns result.output.
fn collectChild(allocator: std.mem.Allocator, io: std.Io, child: *std.process.Child, deadline: std.Io.Clock.Timestamp) !ChildResult {
    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    var timed_out = false;
    while (true) {
        multi_reader.fill(4096, .{ .deadline = deadline }) catch |err| switch (err) {
            error.EndOfStream => break,
            error.Timeout => {
                timed_out = true;
                break;
            },
            else => |e| return e,
        };
    }

    // On timeout, terminate the child. `kill` also closes/nulls the pipes, but
    // everything read so far is already buffered inside `multi_reader`.
    if (timed_out) child.kill(io);
    try multi_reader.checkAnyError();

    const term = if (timed_out) std.process.Child.Term{ .unknown = 0 } else try child.wait(io);
    const stdout_slice = try multi_reader.toOwnedSlice(0);
    defer allocator.free(stdout_slice);
    const stderr_slice = try multi_reader.toOwnedSlice(1);
    defer allocator.free(stderr_slice);

    const out = try allocator.alloc(u8, stdout_slice.len + stderr_slice.len);
    var out_len = normalizeNewlines(out, stdout_slice);
    out_len += normalizeNewlines(out[out_len..], stderr_slice);
    return .{ .term = term, .output = out[0..out_len], .timed_out = timed_out };
}

/// The Windows C runtime emits CRLF (`\r\n`) on stdout even when it is a pipe,
/// so every marker line would otherwise carry a trailing `\r` — breaking the
/// `[PASS]`/`*[FAIL]`/`[SUMMARY]` parsing in the parent harness and mangling
/// the log. Normalize to plain `\n` so results behave identically on every OS.
fn normalizeNewlines(out: []u8, from: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < from.len) : (i += 1) {
        if (from[i] == '\r') {
            if (i + 1 < from.len and from[i + 1] == '\n') continue;
            out[n] = '\n';
        } else {
            out[n] = from[i];
        }
        n += 1;
    }
    return n;
}

const Summary = struct {
    passed: usize,
    failed: usize,
};

/// Extracts the `[SUMMARY] <passed> passed, <failed> failed` line emitted by the
/// compiled test runner. Returns null when the child produced none (e.g. a
/// compile error or a crash before the runner finished).
fn parseSummary(output: []const u8) ?Summary {
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "[SUMMARY] ")) continue;
        const rest = line["[SUMMARY] ".len..];
        var parts = std.mem.splitSequence(u8, rest, " passed, ");
        const passed_str = parts.next() orelse continue;
        const failed_str = parts.next() orelse continue;
        if (!std.mem.endsWith(u8, failed_str, " failed")) continue;
        const failed_num = failed_str[0 .. failed_str.len - " failed".len];
        const passed = std.fmt.parseInt(usize, passed_str, 10) catch continue;
        const failed = std.fmt.parseInt(usize, failed_num, 10) catch continue;
        return .{ .passed = passed, .failed = failed };
    }
    return null;
}

fn countLines(output: []const u8, prefix: []const u8) usize {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, prefix)) count += 1;
    }
    return count;
}

/// Spawns `eiwac test <file>` with piped stdio so the parent can capture and
/// count the child's per-test-block output.
fn spawnTestChild(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, tfile: []const u8, is_release: bool) !TestProc {
    var child_args = ArrayList([]const u8).init(allocator);
    defer child_args.deinit();
    try child_args.appendSlice(&[_][]const u8{ args[0], "test", tfile });
    if (is_release) try child_args.append("--release");
    const child = try std.process.spawn(io, .{ .argv = child_args.items, .stdout = .pipe, .stderr = .pipe });
    return .{ .tfile = tfile, .child = child };
}

/// Main entry point for the Eiwa CLI.
/// Orchestrates the pipeline: Source -> Lexer -> Parser -> AST -> C Transpiler -> Binary.

// --- Clean crash reporting --------------------------------------------------
// When a compiled Eiwa program crashes (JIT), Zig's default handler dumps its
// own runtime frames (main/run/start/callMain) which are just noise — the
// error lives in the JIT'd program frames. Install a handler that reports the
// fault address and only the non-toolchain frames (JIT code + C libraries),
// keeping the crash actionable instead of a wall of Zig internals.

const posix_crash = if (builtin.os.tag != .windows) struct {
    const Dl_info = extern struct {
        dli_fname: ?[*:0]const u8,
        dli_fbase: ?*anyopaque,
        dli_sname: ?[*:0]const u8,
        dli_saddr: ?*anyopaque,
    };
    extern "c" fn dladdr(addr: *const anyopaque, info: *Dl_info) c_int;

    var eiwac_base: ?*anyopaque = null;

    fn write(s: []const u8) void {
        _ = std.c.write(2, s.ptr, s.len);
    }

    fn writeFrame(addr: usize) void {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "    0x{x}\n", .{addr}) catch return;
        write(s);
    }

    fn handler(sig: std.posix.SIG, info: *const std.posix.siginfo_t, ctx_ptr: ?*anyopaque) callconv(.c) void {
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

        write("\n\x1b[1;31mRuntime Error:\x1b[0m ");
        write(name);
        if (sig == .SEGV and (fault_addr == null or fault_addr.? < 4096)) {
            write(" (null pointer dereference)");
        }
        if (fault_addr) |a| {
            write(" at address ");
            writeFrame(a);
        } else {
            write("\n");
        }
        write("\x1b[1;36mStack Trace (JIT):\x1b[0m\n");
        var addr_buf: [48]usize = undefined;
        if (builtin.os.tag != .linux and ctx_ptr != null) {
            if (std.debug.cpu_context.fromPosixSignalContext(ctx_ptr.?)) |native_ctx| {
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
                            write(line_str);
                        } else {
                            const line_str = std.fmt.bufPrint(&frame_buf, "  {d}: 0x{x}\n", .{ frame_idx, ra }) catch continue;
                            write(line_str);
                        }
                    } else {
                        var frame_buf: [64]u8 = undefined;
                        const line_str = std.fmt.bufPrint(&frame_buf, "  {d}: 0x{x}\n", .{ frame_idx, ra }) catch continue;
                        write(line_str);
                    }
                    frame_idx += 1;
                }
            }
        }
        write("\n");
        std.process.exit(@as(u8, @truncate(128 + @intFromEnum(sig))));
    }

    pub fn install() void {
        var self_info: Dl_info = undefined;
        if (dladdr(@ptrFromInt(@returnAddress()), &self_info) != 0) {
            eiwac_base = self_info.dli_fbase;
        }
        const act: std.posix.Sigaction = .{
            .handler = .{ .sigaction = handler },
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
} else struct {
    pub fn install() void {}
};

// --- Windows crash reporting -------------------------------------------------
// Zig installs a vectored exception handler on Windows (std.debug) and, when the
// root module exposes `root.debug.handleSegfault`, calls it with the faulting
// address and register context. We use that to print a JIT-focused report instead
// of Zig's default handler, which recurses into a panic trying to symbolize
// JIT'd frames ("aborting due to recursive panic").
const windows_crash = if (builtin.os.tag == .windows) struct {
    const kernel32 = struct {
        extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
        extern "kernel32" fn GetModuleHandleExW(dwFlags: u32, lpModuleName: ?*const anyopaque, phModule: *?*anyopaque) callconv(.winapi) i32;
        extern "kernel32" fn GetModuleFileNameW(hModule: ?*anyopaque, lpFilename: [*]u16, nSize: u32) callconv(.winapi) u32;
    };
    extern "c" fn _write(fd: c_int, buf: *const anyopaque, count: c_uint) c_int;

    const from_address: u32 = 0x00000004;
    const unchanged_refcount: u32 = 0x00000002;

    fn write(s: []const u8) void {
        _ = _write(2, s.ptr, @intCast(s.len));
    }

    /// UTF-8 filename of the module containing `addr`, or null when the address
    /// is not inside a loaded module (e.g. MCJIT-mapped JIT code).
    fn moduleNameFor(addr: usize, out: []u8) ?[]const u8 {
        var hmod: ?*anyopaque = null;
        if (kernel32.GetModuleHandleExW(from_address | unchanged_refcount, @ptrFromInt(addr), &hmod) == 0) return null;
        var wide: [512]u16 = undefined;
        const n = kernel32.GetModuleFileNameW(hmod, &wide, wide.len);
        if (n == 0 or n >= wide.len) return null;
        return std.unicode.utf16LeToUtf8(out, wide[0..n]) catch null;
    }

    pub fn report(addr: ?usize, name: []const u8, ctx: ?std.debug.CpuContextPtr) noreturn {
        write("\n\x1b[1;31mRuntime Error:\x1b[0m ");
        write(name);
        if (addr) |a| {
            if (a < 4096) write(" (null pointer dereference)");
            var abuf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&abuf, " at address 0x{x}\n", .{a}) catch "";
            write(s);
        } else {
            write("\n");
        }
        write("\x1b[1;36mStack Trace (JIT):\x1b[0m\n");
        const exe_handle = kernel32.GetModuleHandleW(null);
        var addr_buf: [48]usize = undefined;
        if (ctx) |c| {
            const stack = std.debug.captureCurrentStackTrace(.{ .context = c, .allow_unsafe_unwind = true }, &addr_buf);
            var frame_idx: usize = 0;
            for (stack.return_addresses) |ra| {
                // Skip frames inside eiwac.exe itself (toolchain wrapper).
                var hmod: ?*anyopaque = null;
                if (kernel32.GetModuleHandleExW(from_address | unchanged_refcount, @ptrFromInt(ra), &hmod) != 0 and hmod == exe_handle) continue;
                var mbuf: [256]u8 = undefined;
                if (moduleNameFor(ra, &mbuf)) |m| {
                    var fbuf: [512]u8 = undefined;
                    const s = std.fmt.bufPrint(&fbuf, "  {d}: 0x{x} in {s}\n", .{ frame_idx, ra, m }) catch continue;
                    write(s);
                } else {
                    var fbuf: [64]u8 = undefined;
                    const s = std.fmt.bufPrint(&fbuf, "  {d}: 0x{x}\n", .{ frame_idx, ra }) catch continue;
                    write(s);
                }
                frame_idx += 1;
            }
        }
        write("\n");
        std.process.exit(1);
    }
} else struct {
    pub fn report(addr: ?usize, name: []const u8, ctx: ?std.debug.CpuContextPtr) noreturn {
        _ = addr;
        _ = name;
        _ = ctx;
        std.process.exit(1);
    }
};

/// Zig's std.debug segfault handler (installed on Windows) calls this override
/// on an access violation. POSIX keeps its own handler (`posix_crash`), so this
/// only fires on Windows.
pub const debug = struct {
    pub fn handleSegfault(addr: ?usize, name: []const u8, ctx: ?std.debug.CpuContextPtr) noreturn {
        windows_crash.report(addr, name, ctx);
    }
};

pub fn main(init: std.process.Init) !void {
    posix_crash.install();
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

/// Computes a content hash over everything that affects the emitted binary:
/// the compiler executable itself (which embeds the stdlib sources), target,
/// codegen flags, and every module in the import closure (path + source).
/// Transitive dependency changes are covered because dep modules are part of
/// the closure. When `deps_only` is set, only dependency modules (std/* and
/// modules under a --module-path dir) contribute — used for the per-deps
/// object cache (Phase A3). Returns null on any I/O failure — the cache is
/// best-effort and must never break a build.
fn computeProgramCacheKey(
    alloc: std.mem.Allocator,
    io: std.Io,
    registry: *type_checker.ModuleRegistry,
    is_release: bool,
    target_info: target_mod.TargetInfo,
    cli_c_flags: []const []const u8,
    module_paths: []const []const u8,
    deps_only: bool,
    pool_keys: ?*std.StringHashMap(*ast.ASTNode),
) ?[64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&.{ @intFromBool(build_options.has_llvm), @intFromBool(build_options.has_gc), @intFromBool(is_release) });
    hasher.update(target_info.triple);
    hasher.update(&.{0});
    for (cli_c_flags) |f| {
        hasher.update(f);
        hasher.update(&.{0});
    }
    // Host-CPU tuning changes codegen; include the opt-out env var if set.
    if (std.c.getenv("EIWA_BASELINE_CPU")) |v| hasher.update(std.mem.span(v));
    hasher.update(&.{0});

    // Any change to the compiler (including the embedded stdlib sources)
    // invalidates every cached binary.
    const exe_path = std.process.executablePathAlloc(io, alloc) catch return null;
    defer alloc.free(exe_path);
    const exe_bytes = std.Io.Dir.cwd().readFileAlloc(io, exe_path, alloc, .limited(64 * 1024 * 1024)) catch return null;
    defer alloc.free(exe_bytes);
    hasher.update(exe_bytes);

    for (registry.ordered_modules.items) |path| {
        const mod = registry.modules.get(path) orelse continue;
        if (deps_only and !((isDepModulePath(alloc, path, module_paths) catch false))) continue;
        hasher.update(mod.filename);
        hasher.update(&.{0});
        hasher.update(mod.source);
        hasher.update(&.{0});
    }

    // The deps object's content also depends on the whole-program
    // monomorphization pool: generic skill bodies (e.g. collection `equals`
    // doing `is List<T>`) reference vtables of every `List<X>` instantiated
    // anywhere, which is entry-driven. Hash the sorted pool names so the
    // deps object is invalidated iff the instantiated-type set changes.
    if (deps_only) {
        if (pool_keys) |pk| {
            var names = ArrayList([]const u8).init(alloc);
            defer names.deinit();
            var kit = pk.keyIterator();
            while (kit.next()) |k| names.append(k.*) catch return null;
            std.mem.sort([]const u8, names.items, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }.lessThan);
            for (names.items) |n| {
                hasher.update(n);
                hasher.update(&.{0});
            }
        }
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    var hex: [64]u8 = undefined;
    for (digest, 0..) |b, i| {
        hex[i * 2] = std.fmt.hex_charset[b >> 4];
        hex[i * 2 + 1] = std.fmt.hex_charset[b & 0xf];
    }
    return hex;
}

/// True when `path` belongs to a dependency: an embedded std module or a
/// file under one of the `--module-path` directories (e.g. git deps cloned
/// into ~/.eiwa/repository). Everything else is project (entry-unit) code.
fn isDepModulePath(alloc: std.mem.Allocator, path: []const u8, module_paths: []const []const u8) !bool {
    if (std.mem.startsWith(u8, path, "std/")) return true;
    const abs_path = try std.fs.path.resolve(alloc, &.{path});
    defer alloc.free(abs_path);
    for (module_paths) |mp| {
        const abs_mp = try std.fs.path.resolve(alloc, &.{mp});
        defer alloc.free(abs_mp);
        if (std.mem.startsWith(u8, abs_path, abs_mp)) return true;
    }
    return false;
}

/// Directory holding cached artifacts. `EIWA_CACHE_DIR` overrides the
/// default (`~/.eiwa/cache`); returns null when no base dir is known.
fn cacheDir(alloc: std.mem.Allocator, sub: []const u8) ?[]const u8 {
    if (std.c.getenv("EIWA_CACHE_DIR")) |v| {
        return std.fmt.allocPrint(alloc, "{s}/{s}", .{ std.mem.span(v), sub }) catch null;
    }
    const home = (std.c.getenv("HOME") orelse std.c.getenv("USERPROFILE")) orelse return null;
    return std.fmt.allocPrint(alloc, "{s}/.eiwa/cache/{s}", .{ std.mem.span(home), sub }) catch null;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Copies `src_abs` (absolute) to `dst` (may be relative to the cwd),
/// preserving permissions (exec bit) and replacing atomically.
fn copyFileFromCache(io: std.Io, src_abs: []const u8, dst: []const u8) !void {
    const src_dir_path = std.fs.path.dirname(src_abs) orelse ".";
    var src_dir = try std.Io.Dir.cwd().openDir(io, src_dir_path, .{});
    defer src_dir.close(io);
    try std.Io.Dir.copyFile(src_dir, std.fs.path.basename(src_abs), std.Io.Dir.cwd(), dst, io, .{});
}

/// Stores `src` (relative to cwd or absolute) into the cache at `dst_abs`,
/// atomically (atomic create + replace), preserving the exec bit.
fn copyFileToCache(io: std.Io, src: []const u8, dst_abs: []const u8) !void {
    const dst_dir_path = std.fs.path.dirname(dst_abs) orelse return error.InvalidPath;
    var dst_dir = try std.Io.Dir.cwd().openDir(io, dst_dir_path, .{});
    defer dst_dir.close(io);
    try std.Io.Dir.copyFile(std.Io.Dir.cwd(), src, dst_dir, std.fs.path.basename(dst_abs), io, .{});
}

/// Runs the cached binary in a child process (same process group, so signals
/// like Ctrl+C reach it) and exits with its exit code.
fn execCachedBinary(io: std.Io, alloc: std.mem.Allocator, bin_path: []const u8, prog_args: []const []const u8) noreturn {
    var argv = ArrayList([]const u8).init(alloc);
    argv.append(bin_path) catch std.process.exit(1);
    for (prog_args) |a| argv.append(a) catch std.process.exit(1);
    var child = std.process.spawn(io, .{ .argv = argv.items }) catch |err| {
        std.debug.print("Error: failed to execute cached binary '{s}': {s}\n", .{ bin_path, @errorName(err) });
        std.process.exit(1);
    };
    const term = child.wait(io) catch std.process.exit(1);
    switch (term) {
        .exited => |code| std.process.exit(code),
        else => std.process.exit(1),
    }
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
            \\  --target <name>  Target triple or alias (windows, linux, macos, wasm)
            \\  -o <name>        Output binary name (build command)
            \\  --aot            run: build a cached native binary and execute
            \\                   it instead of JIT (used by eiwa run on projects)
            \\  --no-cache       Disable the incremental build cache
            \\  -I, -L, -l, -D   Extra flags forwarded to the C compiler
            \\  -h, --help       Show this help
            \\
            \\Extra positional arguments after the file are forwarded to
            \\the program when using the run command.
            \\
            \\Test runner (test command, no file):
            \\  Tests run in parallel (one child per CPU core). A hung test is
            \\  killed and reported after a timeout instead of freezing the suite.
            \\  EIWA_TEST_JOBS        override the parallel window (1 = sequential)
            \\  EIWA_TEST_TIMEOUT_MS  per-test timeout in ms (default 120000)
            \\
            \\Incremental cache: unchanged builds reuse artifacts under
            \\EIWA_CACHE_DIR (default ~/.eiwa/cache) keyed by content hashes.
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

    var filename: []const u8 = undefined;

    const io = init.io;
    eiwa_home.io = io;

    var cli_c_flags = ArrayList([]const u8).init(allocator);
    defer cli_c_flags.deinit();
    var positionals = ArrayList([]const u8).init(allocator);
    defer positionals.deinit();

    var is_release: bool = false;
    var aot_run: bool = false;
    var no_cache: bool = false;
    var target_arg: ?[]const u8 = null;
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
        } else if (std.mem.eql(u8, arg, "--aot")) {
            aot_run = true;
        } else if (std.mem.eql(u8, arg, "--no-cache")) {
            no_cache = true;
        } else if (std.mem.eql(u8, arg, "--target")) {
            if (arg_idx + 1 >= args.len) {
                std.debug.print("Error: --target requires a target triple or alias (e.g. windows, linux, macos)\n", .{});
                return;
            }
            arg_idx += 1;
            target_arg = args[arg_idx];
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

            std.mem.sort([]const u8, test_files.items, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }.lessThan);

            const CTimeSpec = extern struct {
                tv_sec: i64,
                tv_nsec: c_long,
            };
            const c_clock = struct {
                extern fn clock_gettime(clk_id: c_int, tp: *CTimeSpec) c_int;
            };

            var total_passed: usize = 0;
            var total_failed: usize = 0;
            var files_failed: usize = 0;

            var start_ts: CTimeSpec = undefined;
            _ = c_clock.clock_gettime(0, &start_ts);

            // Bounded concurrency: run up to one test child per CPU core. Every
            // child starts immediately (none waits for a previous test to
            // finish) while keeping the machine from being overwhelmed by ~100
            // concurrent compilers. As one child completes the next is spawned.
            // `EIWA_TEST_JOBS` overrides the window (e.g. 1 = fully sequential).
            const cpu_count = std.Thread.getCpuCount() catch 4;
            const jobs = if (std.c.getenv("EIWA_TEST_JOBS")) |v|
                std.fmt.parseInt(usize, std.mem.span(v), 10) catch cpu_count
            else
                cpu_count;
            const window = @min(jobs, test_files.items.len);

            // Per-test deadline: a hung test (e.g. a busy-looping coroutine) is
            // killed and reported as a failure instead of freezing the suite.
            // `EIWA_TEST_TIMEOUT_MS` overrides the default 120s.
            const default_timeout_ms: i64 = 120 * 1000;
            const timeout_ms = if (std.c.getenv("EIWA_TEST_TIMEOUT_MS")) |v|
                std.fmt.parseInt(i64, std.mem.span(v), 10) catch default_timeout_ms
            else
                default_timeout_ms;
            const timeout_duration = std.Io.Duration.fromMilliseconds(timeout_ms);

            var running: std.ArrayList(TestProc) = .empty;
            defer {
                for (running.items) |*p| p.child.kill(io);
                running.deinit(allocator);
            }

            var next_idx: usize = 0;
            while (running.items.len < window and next_idx < test_files.items.len) : (next_idx += 1) {
                try running.append(allocator, try spawnTestChild(allocator, io, args, test_files.items[next_idx], is_release));
            }

            while (running.items.len > 0) {
                var p = running.orderedRemove(0);
                const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
                    .raw = timeout_duration,
                    .clock = .real,
                });
                const res = try collectChild(allocator, io, &p.child, deadline);
                defer allocator.free(res.output);

                // Print each file's output under a header so parallel (and
                // out-of-order) runs stay attributable.
                const basename = std.fs.path.basename(p.tfile);
                std.debug.print("--- {s} ---\n", .{basename});
                std.debug.print("{s}", .{res.output});

                if (res.timed_out) {
                    std.debug.print("*[FAIL] {s} (timeout after {d}s)\n", .{ basename, @divTrunc(timeout_ms, 1000) });
                    total_failed += 1;
                    files_failed += 1;
                } else if (parseSummary(res.output)) |sum| {
                    total_passed += sum.passed;
                    total_failed += sum.failed;
                    if (sum.failed > 0) files_failed += 1;
                } else {
                    // No [SUMMARY] (compile error / crash / exit() inside a test).
                    // A non-zero exit with no in-child *[FAIL] marker means the
                    // file died before the harness could report the failure —
                    // still credit any test blocks that did run, and surface a
                    // file-level *[FAIL] so the culprit is visible in the log.
                    const passed = countLines(res.output, "[PASS] ");
                    var failed = countLines(res.output, "*[FAIL] ");
                    const exited_ok = res.term == .exited and res.term.exited == 0;
                    if (!exited_ok and failed == 0) {
                        failed += 1;
                        std.debug.print("*[FAIL] {s} (terminated before the harness reported results)\n", .{basename});
                    }
                    total_passed += passed;
                    total_failed += failed;
                    if (failed > 0) files_failed += 1;
                }

                if (next_idx < test_files.items.len) {
                    try running.append(allocator, try spawnTestChild(allocator, io, args, test_files.items[next_idx], is_release));
                    next_idx += 1;
                }
            }

            var end_ts: CTimeSpec = undefined;
            _ = c_clock.clock_gettime(0, &end_ts);
            const elapsed_sec = @as(f64, @floatFromInt(end_ts.tv_sec - start_ts.tv_sec)) +
                @as(f64, @floatFromInt(end_ts.tv_nsec - start_ts.tv_nsec)) / 1_000_000_000.0;

            if (total_failed > 0) {
                std.debug.print("\nLLVM Test Suite: {d} PASSED, {d} FAILED in {d:.2}s ({d} file(s) with failures)\n", .{ total_passed, total_failed, elapsed_sec, files_failed });
                std.process.exit(1);
            } else {
                std.debug.print("\nLLVM Test Suite: ALL {d} TESTS PASSED in {d:.2}s!\n", .{ total_passed, elapsed_sec });
                std.process.exit(0);
            }
        }

        filename = search_path;
        type_checker.module_root = ".";
        const file_content = try std.Io.Dir.cwd().readFileAlloc(io, filename, allocator, .limited(1024 * 1024));
        defer allocator.free(file_content);
        try source_alloc.appendSlice(file_content);
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

    const target_info = if (target_arg) |t_str|
        target_mod.TargetInfo.parse(arena.allocator(), t_str) catch |err| {
            std.debug.print("Error: Invalid --target '{s}' ({s})\n", .{ t_str, @errorName(err) });
            std.process.exit(1);
        }
    else
        target_mod.TargetInfo.detectHost(arena.allocator());

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
        } else if (queue_idx == 0) {
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
        checker.target_info = target_info;

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

                    const case_check = case_checker.checkPathCasing(io, arena.allocator(), import_resolved_path) catch .ok;
                    switch (case_check) {
                        .mismatch => |m| {
                            std.debug.print("\n\x1b[31mError\x1b[0m in {s}:{}:{}:\n", .{ cur_path, stmt.line, stmt.column });
                            std.debug.print("ImportError: Case mismatch in module import '{s}'.\n", .{i.module_path});
                            std.debug.print("Actual file on disk is '{s}'.\n", .{m.actual});
                            std.debug.print("Eiwa requires exact case-sensitive import paths across all operating systems.\n", .{});
                            std.process.exit(1);
                        },
                        else => {},
                    }

                    try queue.append(import_resolved_path);
                }
            }
        }
    }

    // Incremental binary cache (docs/perf-plan-incremental-cache.md): the key
    // covers the full import closure + compiler binary + flags, so a change
    // anywhere invalidates. A hit lets `build` skip the whole backend and
    // lets `run --aot` exec the cached binary directly.
    var final_bin: ?[]const u8 = null;
    if (is_build) {
        const basename = std.fs.path.basename(filename);
        const ext = std.fs.path.extension(basename);
        const out_bin_name = basename[0 .. basename.len - ext.len];
        var fb: []const u8 = output_name orelse (if (out_bin_name.len > 0) out_bin_name else "a.out");
        if (target_info.os_tag == .windows and !std.mem.endsWith(u8, fb, ".exe")) {
            fb = try std.fmt.allocPrint(allocator, "{s}.exe", .{fb});
        }
        final_bin = fb;
    }

    var cache_bin_path: ?[]const u8 = null;
    const cache_enabled = !no_cache and target_info.is_host and (is_build or (!is_test and aot_run));
    if (cache_enabled) {
        if (computeProgramCacheKey(arena.allocator(), io, &registry, is_release, target_info, cli_c_flags.items, module_paths.items, false, null)) |hex| {
            if (cacheDir(arena.allocator(), "bin")) |dir| {
                const exe_ext = if (target_info.os_tag == .windows) ".exe" else "";
                std.Io.Dir.cwd().createDirPath(io, dir) catch {};
                cache_bin_path = std.fmt.allocPrint(arena.allocator(), "{s}/{s}{s}", .{ dir, hex, exe_ext }) catch null;
            }
        }
    }

    if (cache_bin_path) |cp| {
        if (fileExists(io, cp)) {
            if (is_build) {
                copyFileFromCache(io, cp, final_bin.?) catch {
                    std.debug.print("Error: cache hit but failed to copy '{s}' to '{s}'\n", .{ cp, final_bin.? });
                    std.process.exit(1);
                };
                std.debug.print("LLVM backend: Successfully built native binary '{s}' (Release: {}, cache hit)\n", .{ final_bin.?, is_release });
                return;
            }
            execCachedBinary(io, arena.allocator(), cp, positionals.items[1..]);
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

    // Rewrite `val x = task { ... }` / `val x = r.await()` into the
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
    // Allocate via real GC_malloc/
    // GC_realloc (zeroed, GC-managed) instead of raw malloc. Always for
    // host native builds (the binary links -lgc); for the JIT only when the
    // host eiwac links libgc. For cross-target builds without vendored libgc,
    // uses standard libc allocator.
    llvm_emitter.prefer_gc_alloc = (is_build and target_info.is_host) or (llvm_emitter.has_gc and target_info.is_host);
    emitter.is_test_mode = is_test;
    emitter.contracts_ast = &global_contracts_ast;
    emitter.classes_ast = &global_classes_ast;
    emitter.cli_c_flags = cli_c_flags.items;
    emitter.registry = &registry;
    emitter.target_info = target_info;
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

    // Phase A3 split emission (docs/perf-plan-incremental-cache.md): the deps
    // unit (std + --module-path dependencies) is emitted once and cached as a
    // single object; the entry unit (project code) is re-emitted every build
    // and linked against it. Eligibility mirrors prefer_gc_alloc (split needs
    // the GC runtime linked, not the non-GC helper stubs).
    var linked_split = false;
    const aot_tmp: ?[]const u8 = if (!is_build and aot_run and cache_bin_path != null and !is_test)
        try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ cache_bin_path.?, getProcessId() })
    else
        null;

    const split_eligible = cache_enabled and build_options.has_llvm and llvm_emitter.prefer_gc_alloc;
    if (split_eligible) {
        var dep_module_set = std.AutoHashMap(*ast.ASTNode, void).init(arena.allocator());
        var entry_module_set = std.AutoHashMap(*ast.ASTNode, void).init(arena.allocator());
        for (registry.ordered_modules.items) |path| {
            const mod = registry.modules.get(path).?;
            if (isDepModulePath(arena.allocator(), path, module_paths.items) catch false) {
                try dep_module_set.put(mod.ast_root, {});
            } else {
                try entry_module_set.put(mod.ast_root, {});
            }
        }

        var deps_obj_path: ?[]const u8 = null;
        if (dep_module_set.count() > 0 and entry_module_set.count() > 0) {
            if (computeProgramCacheKey(arena.allocator(), io, &registry, is_release, target_info, cli_c_flags.items, module_paths.items, true, &global_classes_ast)) |hex| {
                if (cacheDir(arena.allocator(), "objects")) |dir| {
                    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
                    const obj_ext = if (target_info.os_tag == .windows) "obj" else "o";
                    deps_obj_path = std.fmt.allocPrint(arena.allocator(), "{s}/{s}.{s}", .{ dir, hex, obj_ext }) catch null;
                }
            }
        }

        if (deps_obj_path) |deps_obj| {
            const obj_ext = if (target_info.os_tag == .windows) "obj" else "o";
            // Ensure the deps object (emit only on cache miss).
            if (!fileExists(io, deps_obj)) {
                const deps_emitter = try allocator.create(llvm_emitter.LLVMEmitter);
                deps_emitter.* = try llvm_emitter.LLVMEmitter.init(allocator, filename, is_release);
                deps_emitter.contracts_ast = &global_contracts_ast;
                deps_emitter.classes_ast = &global_classes_ast;
                deps_emitter.cli_c_flags = cli_c_flags.items;
                deps_emitter.registry = &registry;
                deps_emitter.target_info = target_info;
                deps_emitter.unit_modules = &dep_module_set;
                deps_emitter.unit_is_entry = false;
                try deps_emitter.emitModule(ast_root);
                const dtmp = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ deps_obj, getProcessId() });
                try deps_emitter.emitObjectFile(dtmp);
                std.Io.Dir.renameAbsolute(dtmp, deps_obj, io) catch {
                    std.Io.Dir.cwd().deleteFile(io, dtmp) catch {};
                    if (!fileExists(io, deps_obj)) return error.CacheStoreFailed;
                };
            }

            // Entry object: emitted every build, then linked with the deps object.
            emitter.unit_modules = &entry_module_set;
            emitter.unit_is_entry = true;
            try emitter.emitModule(ast_root);
            const etmp = try std.fmt.allocPrint(allocator, "{s}.entry.{d}.{s}", .{ deps_obj, getProcessId(), obj_ext });
            try emitter.emitObjectFile(etmp);
            defer std.Io.Dir.cwd().deleteFile(io, etmp) catch {};
            const out_path = if (is_build) final_bin.? else aot_tmp.?;
            const objs = [_][]const u8{ deps_obj, etmp };
            try emitter.linkObjects(&objs, out_path, io);
            linked_split = true;
        }
    }

    if (!linked_split) {
        try emitter.emitModule(ast_root);
    }

    if (is_build) {
        const fb = final_bin.?;
        if (!linked_split) try emitter.emitNativeBinary(fb, io);
        std.debug.print("LLVM backend: Successfully built native binary '{s}' (Release: {})\n", .{ fb, is_release });
        // Populate the binary cache for future builds/runs (best-effort).
        if (cache_bin_path) |cp| {
            copyFileToCache(io, fb, cp) catch {};
        }
    } else if (aot_run and cache_bin_path != null and !is_test) {
        // run --aot: build into the cache (temp + atomic rename so concurrent
        // runs never see a partial binary), then execute it.
        const cp = cache_bin_path.?;
        const tmp = aot_tmp.?;
        if (!linked_split) try emitter.emitNativeBinary(tmp, io);
        std.Io.Dir.renameAbsolute(tmp, cp, io) catch {
            std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
            if (!fileExists(io, cp)) return error.CacheStoreFailed;
        };
        execCachedBinary(io, arena.allocator(), cp, positionals.items[1..]);
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


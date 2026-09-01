const std = @import("std");

fn fileExists(b: *std.Build, path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        var file = std.Io.Dir.openFileAbsolute(b.graph.io, path, .{}) catch return false;
        file.close(b.graph.io);
        return true;
    }
    var file = std.Io.Dir.cwd().openFile(b.graph.io, path, .{}) catch return false;
    file.close(b.graph.io);
    return true;
}

fn findLlvmPath(b: *std.Build) ?struct { include_path: ?[]const u8, lib_path: ?[]const u8 } {
    if (b.option([]const u8, "llvm-path", "Custom path to LLVM installation")) |p| {
        return .{
            .include_path = std.fs.path.join(b.allocator, &.{ p, "include" }) catch b.fmt("{s}/include", .{p}),
            .lib_path = std.fs.path.join(b.allocator, &.{ p, "lib" }) catch b.fmt("{s}/lib", .{p}),
        };
    }
    // Check environment variables case-insensitively for LLVM_PATH / LLVM_HOME
    var env_it = b.graph.environ_map.iterator();
    while (env_it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "LLVM_PATH") or std.ascii.eqlIgnoreCase(entry.key_ptr.*, "LLVM_HOME")) {
            const p = entry.value_ptr.*;
            const inc = std.fs.path.join(b.allocator, &.{ p, "include" }) catch b.fmt("{s}/include", .{p});
            const lib = std.fs.path.join(b.allocator, &.{ p, "lib" }) catch b.fmt("{s}/lib", .{p});
            const header = std.fs.path.join(b.allocator, &.{ inc, "llvm-c", "Core.h" }) catch b.fmt("{s}/llvm-c/Core.h", .{inc});
            if (fileExists(b, header)) {
                return .{
                    .include_path = inc,
                    .lib_path = lib,
                };
            }
        }
    }
    // Check macOS Homebrew llvm@21
    if (fileExists(b, "/opt/homebrew/opt/llvm@21/include/llvm-c/Core.h")) {
        return .{
            .include_path = "/opt/homebrew/opt/llvm@21/include",
            .lib_path = "/opt/homebrew/opt/llvm@21/lib",
        };
    }
    // Check macOS Homebrew default llvm
    if (fileExists(b, "/opt/homebrew/opt/llvm/include/llvm-c/Core.h")) {
        return .{
            .include_path = "/opt/homebrew/opt/llvm/include",
            .lib_path = "/opt/homebrew/opt/llvm/lib",
        };
    }
    // Check Intel macOS Homebrew (under /usr/local) llvm@21
    if (fileExists(b, "/usr/local/opt/llvm@21/include/llvm-c/Core.h")) {
        return .{
            .include_path = "/usr/local/opt/llvm@21/include",
            .lib_path = "/usr/local/opt/llvm@21/lib",
        };
    }
    // Check Intel macOS Homebrew default llvm
    if (fileExists(b, "/usr/local/opt/llvm/include/llvm-c/Core.h")) {
        return .{
            .include_path = "/usr/local/opt/llvm/include",
            .lib_path = "/usr/local/opt/llvm/lib",
        };
    }
    // Check system default /usr/include/llvm-c/Core.h
    if (fileExists(b, "/usr/include/llvm-c/Core.h")) {
        return .{ .include_path = null, .lib_path = null };
    }
    // Check Ubuntu/Debian /usr/lib/llvm-21/include/llvm-c/Core.h
    if (fileExists(b, "/usr/lib/llvm-21/include/llvm-c/Core.h")) {
        return .{
            .include_path = "/usr/lib/llvm-21/include",
            .lib_path = "/usr/lib/llvm-21/lib",
        };
    }
    // Check Windows standard LLVM and MSYS2/UCRT64 paths
    for ([_][]const u8{
        "C:/msys64/ucrt64",
        "C:/msys64/mingw64",
        "C:/msys64/clang64",
        "C:/Program Files/LLVM",
        "C:/Program Files (x86)/LLVM",
        "C:/LLVM",
    }) |p| {
        const inc = std.fs.path.join(b.allocator, &.{ p, "include" }) catch continue;
        const lib = std.fs.path.join(b.allocator, &.{ p, "lib" }) catch continue;
        const header = std.fs.path.join(b.allocator, &.{ inc, "llvm-c", "Core.h" }) catch continue;
        if (fileExists(b, header)) {
            return .{
                .include_path = inc,
                .lib_path = lib,
            };
        }
    }

    return null;
}

/// Locates the Boehm GC (libgc) installation. When found, the `eiwac` host
/// links libgc and the LLVM JIT can use real GC_malloc/GC_realloc.
/// When absent, the JIT keeps the malloc-first
/// fallback and everything behaves as before.
fn findLibgcPath(b: *std.Build) ?struct { lib_path: ?[]const u8 } {
    if (b.option([]const u8, "gc-path", "Custom path to Boehm GC (libgc) installation")) |p| {
        return .{ .lib_path = b.fmt("{s}/lib", .{p}) };
    }
    // macOS Homebrew (Apple Silicon)
    if (fileExists(b, "/opt/homebrew/lib/libgc.dylib")) {
        return .{ .lib_path = "/opt/homebrew/lib" };
    }
    // macOS Homebrew (Intel, under /usr/local)
    if (fileExists(b, "/usr/local/lib/libgc.dylib")) {
        return .{ .lib_path = "/usr/local/lib" };
    }
    // Windows MSYS2 / UCRT64 & MinGW64
    if (fileExists(b, "C:/msys64/ucrt64/lib/libgc.dll.a") or fileExists(b, "C:/msys64/ucrt64/lib/libgc.a")) {
        return .{ .lib_path = "C:/msys64/ucrt64/lib" };
    }
    if (fileExists(b, "C:/msys64/mingw64/lib/libgc.dll.a") or fileExists(b, "C:/msys64/mingw64/lib/libgc.a")) {
        return .{ .lib_path = "C:/msys64/mingw64/lib" };
    }
    // Ubuntu/Debian x86_64
    if (fileExists(b, "/usr/lib/x86_64-linux-gnu/libgc.so")) {
        return .{ .lib_path = "/usr/lib/x86_64-linux-gnu" };
    }
    // Ubuntu/Debian arm64 / aarch64
    if (fileExists(b, "/usr/lib/aarch64-linux-gnu/libgc.so")) {
        return .{ .lib_path = "/usr/lib/aarch64-linux-gnu" };
    }
    // Linux armhf
    if (fileExists(b, "/usr/lib/arm-linux-gnueabihf/libgc.so")) {
        return .{ .lib_path = "/usr/lib/arm-linux-gnueabihf" };
    }
    // Linux riscv64
    if (fileExists(b, "/usr/lib/riscv64-linux-gnu/libgc.so")) {
        return .{ .lib_path = "/usr/lib/riscv64-linux-gnu" };
    }
    // Linux generic (/usr/lib, /usr/lib64) and /usr/local — linker default search paths
    if (fileExists(b, "/usr/lib/libgc.so") or fileExists(b, "/usr/lib64/libgc.so")) {
        return .{ .lib_path = null };
    }
    if (fileExists(b, "/usr/local/lib/libgc.so")) {
        return .{ .lib_path = "/usr/local/lib" };
    }
    return null;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Default to ReleaseSafe: `zig build` is how eiwac is normally produced
    // (see AGENTS.md), and a Debug compiler is several times slower on every
    // `eiwa run`/`build`. Safety checks stay on; pass -Doptimize=Debug for
    // compiler development or -Doptimize=ReleaseFast for maximum speed.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .ReleaseSafe;

    const llvm_info = findLlvmPath(b);
    const has_llvm = llvm_info != null;
    const gc_info = findLibgcPath(b);
    const has_gc = gc_info != null;

    const options = b.addOptions();
    options.addOption(bool, "has_llvm", has_llvm);
    options.addOption(bool, "has_gc", has_gc);
    options.addOption([]const u8, "eiwa_home", b.path("src").getPath(b));

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addOptions("build_options", options);
    exe_module.link_libc = true;

    if (has_llvm) {
        const info = llvm_info.?;
        if (info.include_path) |inc| {
            exe_module.addIncludePath(.{ .cwd_relative = inc });
        }
        if (info.lib_path) |lib| {
            exe_module.addLibraryPath(.{ .cwd_relative = lib });
        }
        exe_module.linkSystemLibrary("LLVM", .{});
    }
    if (gc_info) |info| {
        if (info.lib_path) |lib| {
            exe_module.addLibraryPath(.{ .cwd_relative = lib });
        }
        exe_module.linkSystemLibrary("gc", .{});
    }

    const exe = b.addExecutable(.{
        .name = "eiwac",
        .root_module = exe_module,
    });

    const install_eiwac = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "../bin" } },
    });
    b.getInstallStep().dependOn(&install_eiwac.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addOptions("build_options", options);
    test_module.link_libc = true;

    if (has_llvm) {
        const info = llvm_info.?;
        if (info.include_path) |inc| {
            test_module.addIncludePath(.{ .cwd_relative = inc });
        }
        if (info.lib_path) |lib| {
            test_module.addLibraryPath(.{ .cwd_relative = lib });
        }
        test_module.linkSystemLibrary("LLVM", .{});
    }
    if (gc_info) |info| {
        if (info.lib_path) |lib| {
            test_module.addLibraryPath(.{ .cwd_relative = lib });
        }
        test_module.linkSystemLibrary("gc", .{});
    }

    const exe_unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}

const std = @import("std");

fn fileExists(b: *std.Build, path: []const u8) bool {
    var file = std.Io.Dir.cwd().openFile(b.graph.io, path, .{}) catch return false;
    file.close(b.graph.io);
    return true;
}

fn findLlvmPath(b: *std.Build) ?struct { include_path: ?[]const u8, lib_path: ?[]const u8 } {
    if (b.option([]const u8, "llvm-path", "Custom path to LLVM installation")) |p| {
        return .{
            .include_path = b.fmt("{s}/include", .{p}),
            .lib_path = b.fmt("{s}/lib", .{p}),
        };
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

    return null;
}

/// Locates the Boehm GC (libgc) installation. When found, the `eiwac` host
/// links libgc and the LLVM JIT can use real GC_malloc/GC_realloc (Bloco B,
/// docs/tasks-bloco-b-gc-jit.md). When absent, the JIT keeps the malloc-first
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
    // Ubuntu/Debian
    if (fileExists(b, "/usr/lib/x86_64-linux-gnu/libgc.so")) {
        return .{ .lib_path = "/usr/lib/x86_64-linux-gnu" };
    }
    // Linux generic (/usr/lib) and /usr/local — linker default search paths
    if (fileExists(b, "/usr/lib/libgc.so")) {
        return .{ .lib_path = null };
    }
    if (fileExists(b, "/usr/local/lib/libgc.so")) {
        return .{ .lib_path = "/usr/local/lib" };
    }
    return null;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    if (has_llvm) {
        const info = llvm_info.?;
        if (info.include_path) |inc| {
            exe_module.addIncludePath(.{ .cwd_relative = inc });
        }
        if (info.lib_path) |lib| {
            exe_module.addLibraryPath(.{ .cwd_relative = lib });
        }
        exe_module.linkSystemLibrary("LLVM", .{});
        exe_module.link_libc = true;
    }
    if (gc_info) |info| {
        if (info.lib_path) |lib| {
            exe_module.addLibraryPath(.{ .cwd_relative = lib });
        }
        exe_module.linkSystemLibrary("gc", .{});
        exe_module.link_libc = true;
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

    if (has_llvm) {
        const info = llvm_info.?;
        if (info.include_path) |inc| {
            test_module.addIncludePath(.{ .cwd_relative = inc });
        }
        if (info.lib_path) |lib| {
            test_module.addLibraryPath(.{ .cwd_relative = lib });
        }
        test_module.linkSystemLibrary("LLVM", .{});
        test_module.link_libc = true;
    }
    if (gc_info) |info| {
        if (info.lib_path) |lib| {
            test_module.addLibraryPath(.{ .cwd_relative = lib });
        }
        test_module.linkSystemLibrary("gc", .{});
        test_module.link_libc = true;
    }

    const exe_unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}

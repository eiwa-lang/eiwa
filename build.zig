const std = @import("std");
const builtin = @import("builtin");

fn fileExists(b: *std.Build, path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.fs.path.isAbsolute(path)) {
        var file = std.Io.Dir.openFileAbsolute(b.graph.io, path, .{}) catch return false;
        file.close(b.graph.io);
        return true;
    }
    var file = std.Io.Dir.cwd().openFile(b.graph.io, path, .{}) catch return false;
    file.close(b.graph.io);
    return true;
}

const Dependency = struct {
    name: []const u8,
    include_path: ?[]const u8 = null,
    lib_path: ?[]const u8 = null,
    import_lib: ?[]const u8 = null,

    fn applyTo(self: Dependency, module: *std.Build.Module) void {
        if (self.include_path) |inc| module.addIncludePath(.{ .cwd_relative = inc });
        if (self.lib_path) |lib| module.addLibraryPath(.{ .cwd_relative = lib });
        if (self.import_lib) |file| {
            module.addObjectFile(.{ .cwd_relative = file });
        } else {
            module.linkSystemLibrary(self.name, .{});
        }
    }
};

fn findLlvm(b: *std.Build) ?Dependency {
    if (b.option([]const u8, "llvm-path", "Custom path to LLVM installation")) |p| {
        return .{
            .name = "LLVM",
            .include_path = std.fs.path.join(b.allocator, &.{ p, "include" }) catch b.fmt("{s}/include", .{p}),
            .lib_path = std.fs.path.join(b.allocator, &.{ p, "lib" }) catch b.fmt("{s}/lib", .{p}),
        };
    }
    for ([_][]const u8{ "LLVM_PATH", "LLVM_HOME", "MSYSTEM_PREFIX", "MINGW_PREFIX" }) |key| {
        if (b.graph.environ_map.get(key)) |p| {
            return .{
                .name = "LLVM",
                .include_path = std.fs.path.join(b.allocator, &.{ p, "include" }) catch b.fmt("{s}/include", .{p}),
                .lib_path = std.fs.path.join(b.allocator, &.{ p, "lib" }) catch b.fmt("{s}/lib", .{p}),
                .import_lib = if (builtin.os.tag == .windows)
                    std.fs.path.join(b.allocator, &.{ p, "lib", "libLLVM.dll.a" }) catch null
                else
                    null,
            };
        }
    }
    if (builtin.os.tag == .macos) {
        for ([_][]const u8{ "/opt/homebrew/opt/llvm@21", "/opt/homebrew/opt/llvm", "/usr/local/opt/llvm@21", "/usr/local/opt/llvm" }) |p| {
            const header = std.fs.path.join(b.allocator, &.{ p, "include", "llvm-c", "Core.h" }) catch continue;
            if (fileExists(b, header)) {
                return .{
                    .name = "LLVM",
                    .include_path = std.fs.path.join(b.allocator, &.{ p, "include" }) catch null,
                    .lib_path = std.fs.path.join(b.allocator, &.{ p, "lib" }) catch null,
                };
            }
        }
    }
    if (builtin.os.tag == .linux) {
        if (fileExists(b, "/usr/include/llvm-c/Core.h")) return .{ .name = "LLVM" };
        if (fileExists(b, "/usr/lib/llvm-21/include/llvm-c/Core.h")) {
            return .{
                .name = "LLVM",
                .include_path = "/usr/lib/llvm-21/include",
                .lib_path = "/usr/lib/llvm-21/lib",
            };
        }
    }
    if (builtin.os.tag == .windows) {
        return .{
            .name = "LLVM",
            .include_path = "C:/msys64/ucrt64/include",
            .lib_path = "C:/msys64/ucrt64/lib",
            .import_lib = "C:/msys64/ucrt64/lib/libLLVM.dll.a",
        };
    }
    return null;
}

fn findLibgc(b: *std.Build) ?Dependency {
    if (b.option([]const u8, "gc-path", "Custom path to Boehm GC (libgc) installation")) |p| {
        return .{ .name = "gc", .lib_path = b.fmt("{s}/lib", .{p}) };
    }
    for ([_][]const u8{ "GC_PATH", "LIBGC_PATH", "MSYSTEM_PREFIX", "MINGW_PREFIX" }) |key| {
        if (b.graph.environ_map.get(key)) |p| {
            return .{
                .name = "gc",
                .lib_path = std.fs.path.join(b.allocator, &.{ p, "lib" }) catch b.fmt("{s}/lib", .{p}),
                .import_lib = if (builtin.os.tag == .windows)
                    std.fs.path.join(b.allocator, &.{ p, "lib", "libgc.dll.a" }) catch null
                else
                    null,
            };
        }
    }
    if (builtin.os.tag == .macos) {
        for ([_][]const u8{ "/opt/homebrew/lib/libgc.dylib", "/usr/local/lib/libgc.dylib" }) |p| {
            if (fileExists(b, p)) return .{ .name = "gc", .lib_path = std.fs.path.dirname(p) };
        }
    }
    if (builtin.os.tag == .windows) {
        return .{
            .name = "gc",
            .lib_path = "C:/msys64/ucrt64/lib",
            .import_lib = "C:/msys64/ucrt64/lib/libgc.dll.a",
        };
    }
    if (builtin.os.tag == .linux) {
        for ([_][]const u8{
            "/usr/lib/x86_64-linux-gnu/libgc.so",
            "/usr/lib/aarch64-linux-gnu/libgc.so",
            "/usr/lib/arm-linux-gnueabihf/libgc.so",
            "/usr/lib/riscv64-linux-gnu/libgc.so",
            "/usr/lib/libgc.so",
            "/usr/local/lib/libgc.so",
        }) |p| {
            if (fileExists(b, p)) return .{ .name = "gc", .lib_path = std.fs.path.dirname(p) };
        }
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

    const llvm_dep = findLlvm(b);
    const gc_dep = findLibgc(b);

    const options = b.addOptions();
    options.addOption(bool, "has_llvm", llvm_dep != null);
    options.addOption(bool, "has_gc", gc_dep != null);
    options.addOption([]const u8, "eiwa_home", b.path("src").getPath(b));

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addOptions("build_options", options);
    exe_module.link_libc = true;
    if (llvm_dep) |dep| dep.applyTo(exe_module);
    if (gc_dep) |dep| dep.applyTo(exe_module);

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
    if (llvm_dep) |dep| dep.applyTo(test_module);
    if (gc_dep) |dep| dep.applyTo(test_module);

    const exe_unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}

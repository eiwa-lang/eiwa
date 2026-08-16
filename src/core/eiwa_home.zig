const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

/// Set once by the CLI entrypoint (`src/main.zig`) so the backends can resolve
/// the eiwa source home at runtime without threading an `Io` handle around.
pub var io: ?std.Io = null;

var resolved: ?[]const u8 = null;

/// Resolves the eiwa source home directory (the directory containing
/// `std/`, `runtime/`, `backend/`, ...). Priority:
///   1. `$EIWA_HOME` (only when libc is linked — the primary LLVM build)
///   2. relative to the running executable: `<exe dir>/../src` — this is the
///      shipped layout (`bin/eiwac` + `src/` side by side) and the dev layout
///      (`bin/eiwac` inside the repo), so the released binary is portable
///   3. compile-time fallback baked by `build.zig`
pub fn resolve(allocator: std.mem.Allocator) []const u8 {
    if (resolved) |home| return home;
    resolved = compute(allocator) catch build_options.eiwa_home;
    return resolved.?;
}

fn compute(allocator: std.mem.Allocator) ![]const u8 {
    if (builtin.link_libc) {
        if (std.c.getenv("EIWA_HOME")) |home_z| {
            return allocator.dupe(u8, std.mem.span(home_z));
        }
    }

    const active_io = io orelse return build_options.eiwa_home;
    const exe_dir = try std.process.executableDirPathAlloc(active_io, allocator);
    const candidate = try std.fs.path.join(allocator, &.{ exe_dir, "..", "src" });
    var dir = std.Io.Dir.cwd().openDir(active_io, candidate, .{}) catch null;
    if (dir) |*d| {
        d.close(active_io);
        return candidate;
    }

    return build_options.eiwa_home;
}
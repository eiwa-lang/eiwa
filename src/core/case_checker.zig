const std = @import("std");

pub const CaseCheckResult = union(enum) {
    ok: void,
    mismatch: struct {
        requested: []const u8,
        actual: []const u8,
    },
    not_found: void,
};

/// Verifies that every component of `path` matches the exact casing of the
/// filesystem entry on disk (even on case-insensitive filesystems like macOS APFS
/// or Windows NTFS).
pub fn checkPathCasing(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !CaseCheckResult {
    if (std.mem.startsWith(u8, path, "std/")) return .ok;

    var cur_dir_path: []const u8 = try allocator.alloc(u8, 0);
    defer allocator.free(cur_dir_path);

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            const next_dir = if (cur_dir_path.len == 0)
                try allocator.dupe(u8, "..")
            else
                try std.fs.path.join(allocator, &.{ cur_dir_path, ".." });
            allocator.free(cur_dir_path);
            cur_dir_path = next_dir;
            continue;
        }

        const open_dir_path = if (cur_dir_path.len == 0) "." else cur_dir_path;
        var dir = std.Io.Dir.cwd().openDir(io, open_dir_path, .{ .iterate = true }) catch return .not_found;
        defer dir.close(io);

        var dir_it = dir.iterate();
        var found = false;
        var actual_name: ?[]const u8 = null;

        while (try dir_it.next(io)) |entry| {
            if (std.mem.eql(u8, entry.name, component)) {
                found = true;
                break;
            } else if (std.ascii.eqlIgnoreCase(entry.name, component)) {
                actual_name = try allocator.dupe(u8, entry.name);
                break;
            }
        }

        if (actual_name) |actual| {
            defer allocator.free(actual);
            const actual_full = if (cur_dir_path.len == 0)
                try allocator.dupe(u8, actual)
            else
                try std.fs.path.join(allocator, &.{ cur_dir_path, actual });
            return .{
                .mismatch = .{
                    .requested = try allocator.dupe(u8, path),
                    .actual = actual_full,
                },
            };
        }

        if (!found) return .not_found;

        const next_dir = if (cur_dir_path.len == 0)
            try allocator.dupe(u8, component)
        else
            try std.fs.path.join(allocator, &.{ cur_dir_path, component });
        allocator.free(cur_dir_path);
        cur_dir_path = next_dir;
    }

    return .ok;
}

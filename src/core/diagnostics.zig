//! Diagnostics and Error Reporting Engine for Eiwa
//!
//! Provides standardized, colorful, and formatted diagnostic messages (errors,
//! warnings, notes, helps, and Internal Compiler Errors), matching modern
//! compiler standards (Rust/Clang/Zig).

const std = @import("std");
const builtin = @import("builtin");

pub const Severity = enum {
    err,
    warning,
    note,
    help,
    ice,

    pub fn label(self: Severity) []const u8 {
        return switch (self) {
            .err => "error",
            .warning => "warning",
            .note => "note",
            .help => "help",
            .ice => "internal compiler error",
        };
    }
};

pub const Color = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const red = "\x1b[31m";
    pub const green = "\x1b[32m";
    pub const yellow = "\x1b[33m";
    pub const blue = "\x1b[34m";
    pub const magenta = "\x1b[35m";
    pub const cyan = "\x1b[36m";
    pub const bold_red = "\x1b[1;31m";
    pub const bold_green = "\x1b[1;32m";
    pub const bold_yellow = "\x1b[1;33m";
    pub const bold_blue = "\x1b[1;34m";
    pub const bold_magenta = "\x1b[1;35m";
    pub const bold_cyan = "\x1b[1;36m";
};

/// Returns true if terminal colors should be used.
pub fn useColors() bool {
    if (std.c.getenv("NO_COLOR") != null) return false;
    if (std.c.getenv("TERM")) |term| {
        if (std.mem.eql(u8, std.mem.sliceTo(term, 0), "dumb")) return false;
    }
    if (builtin.os.tag == .windows) {
        return true;
    }
    return std.c.isatty(std.posix.STDERR_FILENO) != 0;
}

/// Print an Internal Compiler Error (ICE) and instructions for reporting.
pub fn printICE(
    title: []const u8,
    details: ?[]const u8,
) void {
    const colors = useColors();
    const bold_mag = if (colors) Color.bold_magenta else "";
    const bold_w = if (colors) Color.bold else "";
    const dim_c = if (colors) Color.dim else "";
    const cyan_c = if (colors) Color.cyan else "";
    const rst = if (colors) Color.reset else "";

    std.debug.print(
        "\n{s}error: internal compiler error:{s} {s}{s}{s}\n",
        .{ bold_mag, rst, bold_w, title, rst },
    );
    std.debug.print(
        "  {s}-->{s} This is a bug in the Eiwa compiler.\n",
        .{ cyan_c, rst },
    );
    std.debug.print(
        "  {s}-->{s} Please report this issue at {s}https://github.com/eiwa-lang/eiwa/issues{s}\n\n",
        .{ cyan_c, rst, bold_w, rst },
    );

    if (details) |det| {
        std.debug.print("{s}Compiler Diagnostic Details:{s}\n", .{ dim_c, rst });
        var lines = std.mem.splitScalar(u8, det, '\n');
        while (lines.next()) |line| {
            if (line.len > 0) {
                std.debug.print("  {s}\n", .{line});
            }
        }
        std.debug.print("\n", .{});
    }
}

/// Formatted snippet error/warning printer.
pub fn printDiagnostic(
    filename: []const u8,
    line: usize,
    column: usize,
    severity: Severity,
    comptime fmt: []const u8,
    args: anytype,
    source: ?[]const u8,
    hint: ?[]const u8,
) void {
    const colors = useColors();
    const rst = if (colors) Color.reset else "";
    const bold_w = if (colors) Color.bold else "";
    const cyan_c = if (colors) Color.cyan else "";

    const sev_color = if (colors) switch (severity) {
        .err => Color.bold_red,
        .warning => Color.bold_yellow,
        .note => Color.bold_cyan,
        .help => Color.bold_green,
        .ice => Color.bold_magenta,
    } else "";

    // 1. Header: error: <message>
    std.debug.print("\n{s}{s}:{s} {s}", .{ sev_color, severity.label(), rst, bold_w });
    std.debug.print(fmt, args);
    std.debug.print("{s}\n", .{rst});

    // 2. Location:  --> file:line:col
    std.debug.print("  {s}-->{s} {s}:{d}:{d}\n", .{ cyan_c, rst, filename, line, column });

    // 3. Source snippet preview if source is available
    if (source) |src| {
        if (line > 0) {
            var current_line: usize = 1;
            var start_idx: usize = 0;
            var end_idx: usize = 0;

            while (end_idx < src.len) : (end_idx += 1) {
                if (src[end_idx] == '\n') {
                    if (current_line == line) break;
                    current_line += 1;
                    start_idx = end_idx + 1;
                }
            }
            if (end_idx > src.len) end_idx = src.len;

            if (start_idx <= end_idx and start_idx < src.len) {
                const line_content = src[start_idx..end_idx];

                // Gutter width formatting
                var num_buf: [16]u8 = undefined;
                const line_num_str = std.fmt.bufPrint(&num_buf, "{}", .{line}) catch " ";
                const gutter_width = @max(line_num_str.len, 1);

                // Empty separator line: e.g. "   |"
                printSpaces(gutter_width + 2);
                std.debug.print("{s}|{s}\n", .{ cyan_c, rst });

                // Source code line: e.g. " 4 | val res = ..."
                std.debug.print(" {s}{s}{s} {s}|{s} {s}\n", .{ bold_w, line_num_str, rst, cyan_c, rst, line_content });

                // Caret underline: e.g. "   |               ^"
                printSpaces(gutter_width + 2);
                std.debug.print("{s}|{s} ", .{ cyan_c, rst });
                const col_offset = if (column > 0) column - 1 else 0;
                printSpaces(col_offset);
                std.debug.print("{s}^{s}\n", .{ sev_color, rst });

                // Empty separator line: e.g. "   |"
                printSpaces(gutter_width + 2);
                std.debug.print("{s}|{s}\n", .{ cyan_c, rst });
            }
        }
    }

    // 4. Optional help/hint
    if (hint) |h| {
        std.debug.print("  {s}={s} {s}help:{s} {s}\n", .{ cyan_c, rst, Color.bold_green, rst, h });
    }

    std.debug.print("\n", .{});
}

fn printSpaces(count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        std.debug.print(" ", .{});
    }
}

const std = @import("std");
const builtin = @import("builtin");

pub const OsFamily = enum {
    posix,
    windows,
    wasm,
    none,
};

pub const TargetInfo = struct {
    allocator: std.mem.Allocator,
    triple: []const u8,
    os_tag: std.Target.Os.Tag,
    arch: std.Target.Cpu.Arch,
    family: OsFamily,
    is_host: bool,

    pub fn detectHost(allocator: std.mem.Allocator) TargetInfo {
        const os_tag = builtin.os.tag;
        const arch = builtin.cpu.arch;
        const family: OsFamily = switch (os_tag) {
            .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos, .haiku => .posix,
            .windows => .windows,
            .wasi, .emscripten => .wasm,
            else => .none,
        };

        const triple_str = switch (os_tag) {
            .macos => if (arch == .aarch64) "arm64-apple-macosx11.0.0" else "x86_64-apple-macosx10.15.0",
            .linux => if (arch == .aarch64) "aarch64-unknown-linux-gnu" else "x86_64-unknown-linux-gnu",
            .windows => if (arch == .aarch64) "aarch64-pc-windows-gnu" else "x86_64-pc-windows-gnu",
            else => std.fmt.allocPrint(allocator, "{s}-{s}", .{
                @tagName(arch),
                @tagName(os_tag),
            }) catch "unknown-unknown",
        };

        return TargetInfo{
            .allocator = allocator,
            .triple = triple_str,
            .os_tag = os_tag,
            .arch = arch,
            .family = family,
            .is_host = true,
        };
    }

    pub fn parse(allocator: std.mem.Allocator, input: []const u8) !TargetInfo {
        var lower_buf: [128]u8 = undefined;
        if (input.len >= lower_buf.len) return error.TargetNameTooLong;
        const lower = std.ascii.lowerString(&lower_buf, input);

        // Aliases
        if (std.mem.eql(u8, lower, "windows") or std.mem.eql(u8, lower, "win") or std.mem.eql(u8, lower, "win64")) {
            return TargetInfo{
                .allocator = allocator,
                .triple = try allocator.dupe(u8, "x86_64-windows-gnu"),
                .os_tag = .windows,
                .arch = .x86_64,
                .family = .windows,
                .is_host = (builtin.os.tag == .windows and builtin.cpu.arch == .x86_64),
            };
        } else if (std.mem.eql(u8, lower, "windows-arm64") or std.mem.eql(u8, lower, "win-arm64")) {
            return TargetInfo{
                .allocator = allocator,
                .triple = try allocator.dupe(u8, "aarch64-windows-gnu"),
                .os_tag = .windows,
                .arch = .aarch64,
                .family = .windows,
                .is_host = (builtin.os.tag == .windows and builtin.cpu.arch == .aarch64),
            };
        } else if (std.mem.eql(u8, lower, "linux") or std.mem.eql(u8, lower, "linux-musl") or std.mem.eql(u8, lower, "linux-x86_64") or std.mem.eql(u8, lower, "linux-amd64")) {
            return TargetInfo{
                .allocator = allocator,
                .triple = try allocator.dupe(u8, "x86_64-linux-musl"),
                .os_tag = .linux,
                .arch = .x86_64,
                .family = .posix,
                .is_host = (builtin.os.tag == .linux and builtin.cpu.arch == .x86_64),
            };
        } else if (std.mem.eql(u8, lower, "linux-gnu")) {
            return TargetInfo{
                .allocator = allocator,
                .triple = try allocator.dupe(u8, "x86_64-linux-gnu"),
                .os_tag = .linux,
                .arch = .x86_64,
                .family = .posix,
                .is_host = (builtin.os.tag == .linux and builtin.cpu.arch == .x86_64),
            };
        } else if (std.mem.eql(u8, lower, "linux-arm64") or std.mem.eql(u8, lower, "linux-aarch64")) {
            return TargetInfo{
                .allocator = allocator,
                .triple = try allocator.dupe(u8, "aarch64-linux-musl"),
                .os_tag = .linux,
                .arch = .aarch64,
                .family = .posix,
                .is_host = (builtin.os.tag == .linux and builtin.cpu.arch == .aarch64),
            };
        } else if (std.mem.eql(u8, lower, "macos") or std.mem.eql(u8, lower, "darwin") or std.mem.eql(u8, lower, "macos-arm64")) {
            const arch: std.Target.Cpu.Arch = if (builtin.cpu.arch == .x86_64 and !std.mem.endsWith(u8, lower, "arm64")) .x86_64 else .aarch64;
            const triple = if (arch == .aarch64) "arm64-apple-macosx11.0.0" else "x86_64-apple-macosx10.15.0";
            return TargetInfo{
                .allocator = allocator,
                .triple = try allocator.dupe(u8, triple),
                .os_tag = .macos,
                .arch = arch,
                .family = .posix,
                .is_host = (builtin.os.tag == .macos and builtin.cpu.arch == arch),
            };
        } else if (std.mem.eql(u8, lower, "macos-x86_64") or std.mem.eql(u8, lower, "macos-amd64")) {
            return TargetInfo{
                .allocator = allocator,
                .triple = try allocator.dupe(u8, "x86_64-apple-macosx10.15.0"),
                .os_tag = .macos,
                .arch = .x86_64,
                .family = .posix,
                .is_host = (builtin.os.tag == .macos and builtin.cpu.arch == .x86_64),
            };
        } else if (std.mem.eql(u8, lower, "wasm") or std.mem.eql(u8, lower, "wasi") or std.mem.eql(u8, lower, "wasm32")) {
            return TargetInfo{
                .allocator = allocator,
                .triple = try allocator.dupe(u8, "wasm32-wasi"),
                .os_tag = .wasi,
                .arch = .wasm32,
                .family = .wasm,
                .is_host = false,
            };
        }

        // Custom full triple: parse components loosely
        var os_tag: std.Target.Os.Tag = .freestanding;
        var family: OsFamily = .none;
        if (std.mem.indexOf(u8, lower, "linux") != null) {
            os_tag = .linux;
            family = .posix;
        } else if (std.mem.indexOf(u8, lower, "darwin") != null or std.mem.indexOf(u8, lower, "macos") != null) {
            os_tag = .macos;
            family = .posix;
        } else if (std.mem.indexOf(u8, lower, "windows") != null or std.mem.indexOf(u8, lower, "win32") != null or std.mem.indexOf(u8, lower, "mingw") != null) {
            os_tag = .windows;
            family = .windows;
        } else if (std.mem.indexOf(u8, lower, "wasi") != null or std.mem.indexOf(u8, lower, "wasm") != null) {
            os_tag = .wasi;
            family = .wasm;
        }

        var arch: std.Target.Cpu.Arch = .x86_64;
        if (std.mem.startsWith(u8, lower, "aarch64") or std.mem.startsWith(u8, lower, "arm64")) {
            arch = .aarch64;
        } else if (std.mem.startsWith(u8, lower, "x86_64") or std.mem.startsWith(u8, lower, "amd64")) {
            arch = .x86_64;
        } else if (std.mem.startsWith(u8, lower, "arm") or std.mem.startsWith(u8, lower, "armhf")) {
            arch = .arm;
        } else if (std.mem.startsWith(u8, lower, "riscv64")) {
            arch = .riscv64;
        } else if (std.mem.startsWith(u8, lower, "wasm32")) {
            arch = .wasm32;
        }

        return TargetInfo{
            .allocator = allocator,
            .triple = try allocator.dupe(u8, input),
            .os_tag = os_tag,
            .arch = arch,
            .family = family,
            .is_host = (builtin.os.tag == os_tag and builtin.cpu.arch == arch),
        };
    }

    /// Checks if a single tag string matches this target.
    /// Matches on OS name ("linux", "macos", "windows"),
    /// OS family ("posix", "windows", "wasm"),
    /// Architecture ("x86_64", "arm64", "aarch64"),
    /// or triple substring.
    pub fn matchesTag(self: TargetInfo, tag: []const u8) bool {
        var lower_buf: [128]u8 = undefined;
        if (tag.len >= lower_buf.len) return false;
        const t = std.ascii.lowerString(&lower_buf, tag);

        // Family match
        if (std.mem.eql(u8, t, "posix") and self.family == .posix) return true;
        if (std.mem.eql(u8, t, "windows") and self.family == .windows) return true;
        if (std.mem.eql(u8, t, "wasm") and self.family == .wasm) return true;

        // OS tag match
        const os_name = @tagName(self.os_tag);
        if (std.mem.eql(u8, t, os_name)) return true;
        if (std.mem.eql(u8, t, "darwin") and self.os_tag == .macos) return true;
        if (std.mem.eql(u8, t, "macos") and self.os_tag == .macos) return true;
        if (std.mem.eql(u8, t, "win") and self.os_tag == .windows) return true;

        // Arch match
        const arch_name = @tagName(self.arch);
        if (std.mem.eql(u8, t, arch_name)) return true;
        if (std.mem.eql(u8, t, "arm64") and self.arch == .aarch64) return true;
        if (std.mem.eql(u8, t, "amd64") and self.arch == .x86_64) return true;

        // Full or partial triple match
        if (std.mem.eql(u8, t, self.triple)) return true;
        if (std.mem.indexOf(u8, self.triple, t) != null) return true;

        return false;
    }

    /// Checks if any tag in a slice matches this target.
    pub fn matchesAny(self: TargetInfo, tags: []const []const u8) bool {
        if (tags.len == 0) return true;
        for (tags) |tag| {
            if (self.matchesTag(tag)) return true;
        }
        return false;
    }
};

test "target info parsing and matching" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const win = try TargetInfo.parse(allocator, "windows");
    defer allocator.free(win.triple);
    try testing.expect(win.os_tag == .windows);
    try testing.expect(win.family == .windows);
    try testing.expect(win.matchesTag("windows"));
    try testing.expect(win.matchesTag("win"));
    try testing.expect(!win.matchesTag("posix"));
    try testing.expect(!win.matchesTag("linux"));

    const linux = try TargetInfo.parse(allocator, "linux");
    defer allocator.free(linux.triple);
    try testing.expect(linux.os_tag == .linux);
    try testing.expect(linux.family == .posix);
    try testing.expect(linux.matchesTag("posix"));
    try testing.expect(linux.matchesTag("linux"));
    try testing.expect(!linux.matchesTag("windows"));

    const macos = try TargetInfo.parse(allocator, "macos");
    defer allocator.free(macos.triple);
    try testing.expect(macos.os_tag == .macos);
    try testing.expect(macos.family == .posix);
    try testing.expect(macos.matchesTag("posix"));
    try testing.expect(macos.matchesTag("macos"));
    try testing.expect(macos.matchesTag("darwin"));
}

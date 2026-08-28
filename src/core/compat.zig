const std = @import("std");

pub fn ArrayList(comptime T: type) type {
    return struct {
        unmanaged: std.ArrayList(T) = .empty,
        allocator: std.mem.Allocator,
        items: []T = &.{},

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .unmanaged = .empty,
                .allocator = allocator,
                .items = &.{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.unmanaged.deinit(self.allocator);
            self.items = &.{};
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.unmanaged.clearRetainingCapacity();
            self.items = self.unmanaged.items;
        }

        pub fn append(self: *Self, item: T) !void {
            try self.unmanaged.append(self.allocator, item);
            self.items = self.unmanaged.items;
        }

        pub fn appendSlice(self: *Self, slice: []const T) !void {
            try self.unmanaged.appendSlice(self.allocator, slice);
            self.items = self.unmanaged.items;
        }

        pub fn pop(self: *Self) T {
            const val = self.unmanaged.pop() orelse unreachable;
            self.items = self.unmanaged.items;
            return val;
        }

        pub fn popOrNull(self: *Self) ?T {
            const val = self.unmanaged.popOrNull();
            self.items = self.unmanaged.items;
            return val;
        }

        pub fn insert(self: *Self, index: usize, item: T) !void {
            try self.unmanaged.insert(self.allocator, index, item);
            self.items = self.unmanaged.items;
        }

        pub fn toOwnedSlice(self: *Self) ![]T {
            const slice = try self.unmanaged.toOwnedSlice(self.allocator);
            self.items = &.{};
            return slice;
        }

        pub fn writer(self: *Self) *Self {
            return self;
        }

        pub fn print(self: *Self, comptime fmt: []const u8, args: anytype) !void {
            const formatted = try std.fmt.allocPrint(self.allocator, fmt, args);
            defer self.allocator.free(formatted);
            try self.appendSlice(formatted);
        }

        pub fn writeAll(self: *Self, bytes: []const u8) !void {
            try self.appendSlice(bytes);
        }
    };
}

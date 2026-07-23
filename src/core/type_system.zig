const std = @import("std");
const compat = @import("compat.zig");
const ArrayList = compat.ArrayList;

pub const AetherType = union(enum) {
    Int,
    String,
    Bool,
    Pointer: *const AetherType,
    Void,
    Null,
    Unknown,
    Array: *const AetherType,
    Custom: []const u8,
    Function: struct {
        params: []const *const AetherType,
        return_type: *const AetherType,
        c_name: []const u8,
        receiver: ?*const AetherType = null,
    },
    Union: struct {
        left: *const AetherType,
        right: *const AetherType,
    },
    GenericParam: []const u8,
    GenericInstance: struct {
        base_name: []const u8,
        type_args: []const *const AetherType,
    },

    pub fn format(self: AetherType, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        switch (self) {
            .Int => try writer.writeAll("Int"),
            .String => try writer.writeAll("String"),
            .Bool => try writer.writeAll("Bool"),
            .Pointer => |elem| {
                if (elem.* == .Void) {
                    try writer.writeAll("OpaquePointer");
                } else {
                    try writer.writeAll("Pointer<");
                    try elem.format("", options, writer);
                    try writer.writeAll(">");
                }
            },
            .Void => try writer.writeAll("Void"),
            .Null => try writer.writeAll("null"),
            .Unknown => try writer.writeAll("Unknown"),
            .Array => |elem| {
                try writer.writeAll("NativeArray<");
                try elem.format("", options, writer);
                try writer.writeAll(">");
            },
            .Custom => |name| try writer.writeAll(name),
            .Function => |f| {
                if (f.receiver) |r| {
                    try r.format("", options, writer);
                    try writer.writeAll(".(");
                } else {
                    try writer.writeAll("fun(");
                }
                for (f.params, 0..) |p, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try p.format("", options, writer);
                }
                try writer.writeAll("): ");
                try f.return_type.format("", options, writer);
            },
            .Union => |u| {
                if (u.right.* == .Null) {
                    try u.left.format("", options, writer);
                    try writer.writeAll("?");
                } else {
                    try u.left.format("", options, writer);
                    try writer.writeAll(" | ");
                    try u.right.format("", options, writer);
                }
            },
            .GenericParam => |name| try writer.writeAll(name),
            .GenericInstance => |g| {
                try writer.writeAll(g.base_name);
                try writer.writeAll("<");
                for (g.type_args, 0..) |arg, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try arg.format("", options, writer);
                }
                try writer.writeAll(">");
            },
        }
    }

    pub fn formatSafe(self: AetherType, writer: anytype) !void {
        switch (self) {
            .Int => try writer.writeAll("Int"),
            .String => try writer.writeAll("String"),
            .Bool => try writer.writeAll("Bool"),
            .Pointer => |elem| {
                if (elem.* == .Void) {
                    try writer.writeAll("OpaquePointer");
                } else {
                    try writer.writeAll("Pointer_");
                    try elem.formatSafe(writer);
                }
            },
            .Void => try writer.writeAll("Void"),
            .Null => try writer.writeAll("Null"),
            .Unknown => try writer.writeAll("Unknown"),
            .Array => |elem| {
                try writer.writeAll("Array_");
                try elem.formatSafe(writer);
            },
            .Custom => |name| {
                if (std.mem.indexOf(u8, name, " | ") != null) {
                    var it = std.mem.splitSequence(u8, name, " | ");
                    var idx: usize = 0;
                    while (it.next()) |part| : (idx += 1) {
                        if (idx > 0) try writer.writeAll("_or_");
                        for (part) |c| {
                            if (c == '<' or c == '>' or c == ',' or c == '|') {
                                try writer.writeAll("_");
                            } else if (c == ' ' or c == '?') {
                                // skip
                            } else {
                                var buf: [1]u8 = .{c};
                                try writer.writeAll(&buf);
                            }
                        }
                    }
                } else {
                    for (name) |c| {
                        if (c == '<' or c == '>' or c == ',' or c == '|') {
                            try writer.writeAll("_");
                        } else if (c == ' ' or c == '?') {
                            // skip
                        } else {
                            var buf: [1]u8 = .{c};
                            try writer.writeAll(&buf);
                        }
                    }
                }
            },
            .Function => |f| {
                if (f.receiver) |r| {
                    try r.formatSafe(writer);
                    try writer.writeAll("_");
                }
                try writer.writeAll("fun_");
                for (f.params, 0..) |p, i| {
                    if (i > 0) try writer.writeAll("_");
                    try p.formatSafe(writer);
                }
                try writer.writeAll("_ret_");
                try f.return_type.formatSafe(writer);
            },
            .Union => |u| {
                if (u.right.* == .Null) {
                    try u.left.formatSafe(writer);
                    try writer.writeAll("Opt");
                } else {
                    try u.left.formatSafe(writer);
                    try writer.writeAll("_or_");
                    try u.right.formatSafe(writer);
                }
            },
            .GenericParam => |name| try writer.writeAll(name),
            .GenericInstance => |g| {
                try writer.writeAll(g.base_name);
                try writer.writeAll("_");
                for (g.type_args, 0..) |arg, i| {
                    if (i > 0) try writer.writeAll("_");
                    try arg.formatSafe(writer);
                }
            },
        }
    }
};

const ast = @import("ast.zig");

pub const VariableSymbol = struct {
    aether_type: *const AetherType,
    is_mut: bool,
    is_boxed: bool = false,
    decl_node: ?*ast.ASTNode = null,
};

pub const Symbol = union(enum) {
    Variable: VariableSymbol,
    Overloads: ArrayList(*const AetherType),
};

pub const Scope = struct {
    allocator: std.mem.Allocator,
    parent: ?*Scope,
    symbols: std.StringHashMap(*Symbol),
    is_function_boundary: bool = false,

    pub fn init(allocator: std.mem.Allocator, parent: ?*Scope) Scope {
        return Scope{
            .allocator = allocator,
            .parent = parent,
            .symbols = std.StringHashMap(*Symbol).init(allocator),
            .is_function_boundary = false,
        };
    }

    pub fn deinit(self: *Scope) void {
        self.symbols.deinit();
    }

    pub fn define(self: *Scope, name: []const u8, t: *const AetherType, is_mut: bool, is_func: bool) !void {
        if (self.symbols.get(name)) |existing| {
            if (is_func) {
                if (existing.* == .Overloads) {
                    for (existing.Overloads.items) |ov| {
                        if (isCompatible(ov, t)) return;
                    }
                    try existing.Overloads.append(t);
                    return;
                } else {
                    std.debug.print("SymbolAlreadyDefined: {s} is not Overloads\n", .{name});
                    return error.SymbolAlreadyDefined;
                }
            } else {
                if (existing.* == .Variable and isCompatible(existing.Variable.aether_type, t)) {
                    return;
                }
                return error.SymbolAlreadyDefined;
            }
        }

        const sym = try self.allocator.create(Symbol);
        if (is_func) {
            var list = ArrayList(*const AetherType).init(self.allocator);
            try list.append(t);
            sym.* = .{ .Overloads = list };
        } else {
            sym.* = .{ .Variable = .{ .aether_type = t, .is_mut = is_mut } };
        }
        try self.symbols.put(name, sym);
    }

    pub fn lookupVariableSymbol(self: *Scope, name: []const u8) ?*const VariableSymbol {
        if (self.symbols.get(name)) |sym| {
            if (sym.* == .Variable) return &sym.Variable;
        }
        if (self.parent) |p| {
            return p.lookupVariableSymbol(name);
        }
        return null;
    }

    pub fn lookupVariable(self: *Scope, name: []const u8) ?*const AetherType {
        if (self.lookupVariableSymbol(name)) |vs| {
            return vs.aether_type;
        }
        return null;
    }

    pub fn lookupFunctions(self: *Scope, name: []const u8) ?[]const *const AetherType {
        if (self.symbols.get(name)) |sym| {
            if (sym.* == .Overloads) return sym.Overloads.items;
        }
        if (self.parent) |p| {
            return p.lookupFunctions(name);
        }
        return null;
    }
};

pub fn isNullable(t: *const AetherType) bool {
    return switch (t.*) {
        .Null => true,
        .Pointer => true,
        .Union => |u| isNullable(u.left) or isNullable(u.right),
        else => false,
    };
}

pub fn extractBaseType(t: *const AetherType) *const AetherType {
    return switch (t.*) {
        .Union => |u| if (u.right.* == .Null) extractBaseType(u.left) else t,
        else => t,
    };
}

pub fn isBool(t: *const AetherType) bool {
    const base = extractBaseType(t);
    switch (base.*) {
        .Bool => return true,
        .Custom => |name| {
            return std.mem.eql(u8, name, "Bool") or std.mem.eql(u8, name, "core_Bool");
        },
        else => return false,
    }
}

pub fn isCompatible(expected: *const AetherType, actual: *const AetherType) bool {
    if (expected.* == .Unknown or actual.* == .Unknown) return true;
    if (isNullable(expected) and actual.* == .Null) return true;
    if (isNullable(actual) and !isNullable(expected)) return false;

    const exp_base = extractBaseType(expected);
    const act_base = extractBaseType(actual);

    if (std.meta.activeTag(exp_base.*) == std.meta.activeTag(act_base.*)) {
        switch (exp_base.*) {
            .Custom => |name| {
                if (act_base.* == .Custom) {
                    return std.mem.eql(u8, name, act_base.Custom);
                }
                return false;
            },
            .Array => |elem| {
                if (act_base.* == .Array) {
                    return isCompatible(elem, act_base.Array);
                }
                return false;
            },
            .Pointer => |elem| {
                if (std.meta.activeTag(act_base.*) == .Pointer) {
                    if (elem.* == .Void or act_base.Pointer.* == .Void) return true;
                    return isCompatible(elem, act_base.Pointer);
                }
                return false;
            },
            .Function => |f_exp| {
                if (act_base.* != .Function) return false;
                const f_act = act_base.Function;
                if (f_exp.params.len != f_act.params.len) return false;
                if (f_exp.receiver) |rec_exp| {
                    if (f_act.receiver) |rec_act| {
                        if (!isCompatible(rec_exp, rec_act)) return false;
                    } else {
                        return false;
                    }
                } else {
                    if (f_act.receiver != null) return false;
                }
                for (f_exp.params, 0..) |p_exp, i| {
                    if (!isCompatible(p_exp, f_act.params[i])) return false;
                }
                return isCompatible(f_exp.return_type, f_act.return_type);
            },
            else => return true,
        }
    }
    return false;
}

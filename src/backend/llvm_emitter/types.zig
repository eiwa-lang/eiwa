const std = @import("std");
const ast = @import("../../core/ast.zig");
const types = @import("../../core/type_system.zig");
const c_bindings = @import("c_bindings.zig");
const llvm = c_bindings.llvm;

/// Matches a scalar against its mangled aliases (`"String"`, `"core_String"`, `"std_core_String"`).
pub fn isScalarName(name: []const u8, short: []const u8) bool {
    if (std.mem.eql(u8, name, short)) return true;
    const rest = if (std.mem.startsWith(u8, name, "std_core_")) name["std_core_".len..] else if (std.mem.startsWith(u8, name, "core_")) name["core_".len..] else return false;
    return std.mem.eql(u8, rest, short);
}

/// Matches an EiwaType against a scalar tag or its aliases (`.String` or `Custom("core_String")`).
pub fn isScalarType(t: types.EiwaType, short: []const u8) bool {
    return switch (t) {
        .Custom => |n| isScalarName(n, short),
        else => std.mem.eql(u8, @tagName(t), short),
    };
}

/// Mangled core name for a scalar tag (`Int` → `"core_Int"`); null otherwise.
pub fn scalarMangled(t: types.EiwaType) ?[]const u8 {
    return switch (t) {
        .Int => "core_Int",
        .Double => "core_Double",
        .Bool => "core_Bool",
        .String => "core_String",
        .Pointer => "core_Pointer",
        else => null,
    };
}

/// Maps Eiwa types to LLVM C-API LLVMTypeRef representation.
pub fn getLLVMType(ctx: llvm.LLVMContextRef, resolved_type: types.EiwaType) llvm.LLVMTypeRef {
    const expression = @import("expression.zig");
    return getLLVMTypeWithContracts(ctx, resolved_type, expression.global_contracts_ast_ptr);
}

pub fn getLLVMTypeWithContracts(ctx: llvm.LLVMContextRef, resolved_type: types.EiwaType, contracts_ast: ?*std.StringHashMap(*ast.ASTNode)) llvm.LLVMTypeRef {
    if (isContractType(resolved_type, contracts_ast)) {
        return getFatPointerType(ctx);
    }
    // Unions share the contract fat-pointer layout (lazy import avoids a cycle).
    const expression = @import("expression.zig");
    if (isRegisteredUnion(resolved_type, expression.global_unions_ast_ptr)) {
        return getFatPointerType(ctx);
    }
    switch (resolved_type) {
        .Int => return llvm.LLVMInt64TypeInContext(ctx),
        .Bool => return llvm.LLVMInt1TypeInContext(ctx),
        .Double => return llvm.LLVMDoubleTypeInContext(ctx),
        .Void => return llvm.LLVMVoidTypeInContext(ctx),
        .String, .Pointer => return llvm.LLVMPointerTypeInContext(ctx, 0),
        .Custom => |name| {
            if (isScalarName(name, "Int")) return llvm.LLVMInt64TypeInContext(ctx);
            if (isScalarName(name, "Bool")) return llvm.LLVMInt1TypeInContext(ctx);
            if (isScalarName(name, "Double")) return llvm.LLVMDoubleTypeInContext(ctx);
            return llvm.LLVMPointerTypeInContext(ctx, 0);
        },
        .Array, .Function, .Union, .GenericParam, .GenericInstance => return llvm.LLVMPointerTypeInContext(ctx, 0),
        .Null, .Unknown => return llvm.LLVMInt64TypeInContext(ctx),
    }
}

pub fn isContractType(resolved_type: types.EiwaType, contracts_ast: ?*std.StringHashMap(*ast.ASTNode)) bool {
    var base = types.extractBaseType(&resolved_type);
    while (base.* == .Union or base.* == .Pointer) {
        if (base.* == .Union) {
            if (base.Union.left.* != .Null) {
                base = types.extractBaseType(base.Union.left);
            } else {
                base = types.extractBaseType(base.Union.right);
            }
        } else if (base.* == .Pointer) {
            base = types.extractBaseType(base.Pointer);
        }
    }
    const name = switch (base.*) {
        .Custom => |n| n,
        .GenericInstance => |gi| gi.base_name,
        else => return false,
    };
    const ca = contracts_ast orelse return false;
    if (ca.contains(name)) return true;

    // Check module-qualified contract (e.g. "core_Stringable" where "Stringable" is in ca)
    if (std.mem.lastIndexOfScalar(u8, name, '_')) |idx| {
        const prefix = name[0..idx];
        if (std.mem.indexOfScalar(u8, prefix, '_') == null) {
            if (ca.contains(name[idx + 1 ..])) return true;
        }
    }

    // Check generic contract instantiation (e.g. "Comparable_core_Int" where "Comparable" is in ca)
    if (std.mem.indexOfScalar(u8, name, '_')) |idx| {
        if (ca.contains(name[0..idx])) return true;
    }

    return false;
}

/// Returns the Fat Pointer struct type { ptr data, ptr vtable }.
pub fn getFatPointerType(ctx: llvm.LLVMContextRef) llvm.LLVMTypeRef {
    const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
    var fields = [_]llvm.LLVMTypeRef{ ptr_type, ptr_type };
    return llvm.LLVMStructTypeInContext(ctx, &fields, 2, 0);
}

pub fn isUnionTypeString(type_arg: []const u8, unions_ast: ?*std.StringHashMap(*ast.ASTNode)) bool {
    const ua = unions_ast orelse return false;
    return ua.contains(type_arg);
}

/// True for a closed union WITH a registered entry (declared name or
/// structural `.Union` whose `formatSafe` key is registered). Open shapes
/// stay false and keep the legacy lowering.
pub fn isRegisteredUnion(typ: types.EiwaType, unions_ast: ?*std.StringHashMap(*ast.ASTNode)) bool {
    const ua = unions_ast orelse return false;
    var base = types.extractBaseType(&typ);
    while (true) {
        if (base.* == .Pointer) {
            base = types.extractBaseType(base.Pointer);
            continue;
        }
        if (base.* == .Union) {
            const l = base.Union.left;
            const r = base.Union.right;
            if (l.* == .Null and r.* != .Null) {
                base = types.extractBaseType(r);
                continue;
            }
            if (r.* == .Null and l.* != .Null) {
                base = types.extractBaseType(l);
                continue;
            }
        }
        break;
    }
    switch (base.*) {
        .Custom => |n| return ua.contains(n),
        .GenericInstance => |gi| return ua.contains(gi.base_name),
        else => {},
    }
    if (base.* != .Union) return false;
    // Same `formatSafe` key the checker uses for the anonymous companion;
    // a divergence here silently breaks `is` identity, so share the function.
    var key = UnionKeyWriter{ .buf = undefined };
    base.formatSafe(key.writer()) catch return false;
    return ua.contains(key.buf[0..key.pos]);
}

/// Stack writer for `formatSafe` without allocation; overflow fails so the
/// caller treats the key as unregistered.
const UnionKeyWriter = struct {
    buf: [256]u8 = undefined,
    pos: usize = 0,

    const Interface = struct {
        state: *UnionKeyWriter,

        pub fn writeAll(self: @This(), s: []const u8) !void {
            const st = self.state;
            if (st.pos + s.len > st.buf.len) return error.NoSpaceLeft;
            @memcpy(st.buf[st.pos..][0..s.len], s);
            st.pos += s.len;
        }
    };

    fn writer(self: *@This()) Interface {
        return .{ .state = self };
    }
};

/// Returns true if `resolved_type` represents a Stringable type
/// (primitives, pointers, unions, or Stringable contracts).
pub fn isStringable(resolved_type: types.EiwaType) bool {
    var base = types.extractBaseType(&resolved_type);
    while (base.* == .Union or base.* == .Pointer) {
        if (base.* == .Union) {
            if (base.Union.left.* != .Null) {
                base = types.extractBaseType(base.Union.left);
            } else {
                base = types.extractBaseType(base.Union.right);
            }
        } else if (base.* == .Pointer) {
            base = types.extractBaseType(base.Pointer);
        }
    }
    return switch (base.*) {
        .Int, .Bool, .Double, .String, .Pointer, .Union => true,
        .Custom => |n| std.mem.eql(u8, n, "Stringable") or std.mem.eql(u8, n, "core_Stringable") or std.mem.eql(u8, n, "std_core_Stringable") or std.mem.endsWith(u8, n, "_Stringable"),
        else => false,
    };
}

/// Returns true if method `name` on `resolved_type` is an inlined primitive or
/// contract method emitted directly during get_expr (e.g. toString on Stringable,
/// toInt/toDouble on numbers, or hashCode on primitive scalars/strings).
pub fn isDirectBuiltinMethod(name: []const u8, resolved_type: ?types.EiwaType) bool {
    const rt = resolved_type orelse return false;
    if (std.mem.eql(u8, name, "toString")) {
        return isStringable(rt);
    }
    if (std.mem.eql(u8, name, "toInt") or std.mem.eql(u8, name, "toDouble")) {
        const base = types.extractBaseType(&rt).*;
        return base == .Int or base == .Double;
    }
    if (std.mem.eql(u8, name, "hashCode")) {
        const base = types.extractBaseType(&rt).*;
        return switch (base) {
            .Int, .Bool, .Double, .Pointer, .String => true,
            .Custom => |n| std.mem.eql(u8, n, "String") or std.mem.eql(u8, n, "core_String") or std.mem.eql(u8, n, "std_core_String") or std.mem.endsWith(u8, n, "_String"),
            else => false,
        };
    }
    return false;
}



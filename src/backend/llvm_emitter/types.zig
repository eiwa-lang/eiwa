const std = @import("std");
const ast = @import("../../core/ast.zig");
const types = @import("../../core/type_system.zig");
const c_bindings = @import("c_bindings.zig");
const llvm = c_bindings.llvm;

/// Maps Eiwa types to LLVM C-API LLVMTypeRef representation.
pub fn getLLVMType(ctx: llvm.LLVMContextRef, resolved_type: types.EiwaType) llvm.LLVMTypeRef {
    const expression = @import("expression.zig");
    return getLLVMTypeWithContracts(ctx, resolved_type, expression.global_contracts_ast_ptr);
}

pub fn getLLVMTypeWithContracts(ctx: llvm.LLVMContextRef, resolved_type: types.EiwaType, contracts_ast: ?*std.StringHashMap(*ast.ASTNode)) llvm.LLVMTypeRef {
    if (isContractType(resolved_type, contracts_ast)) {
        return getFatPointerType(ctx);
    }
    switch (resolved_type) {
        .Int => return llvm.LLVMInt64TypeInContext(ctx),
        .Bool => return llvm.LLVMInt1TypeInContext(ctx),
        .Double => return llvm.LLVMDoubleTypeInContext(ctx),
        .Void => return llvm.LLVMVoidTypeInContext(ctx),
        .String, .Pointer => return llvm.LLVMPointerTypeInContext(ctx, 0),
        .Custom => |name| {
            if (std.mem.eql(u8, name, "Int") or std.mem.eql(u8, name, "core_Int") or std.mem.eql(u8, name, "std_core_Int")) return llvm.LLVMInt64TypeInContext(ctx);
            if (std.mem.eql(u8, name, "Bool") or std.mem.eql(u8, name, "core_Bool") or std.mem.eql(u8, name, "std_core_Bool")) return llvm.LLVMInt1TypeInContext(ctx);
            if (std.mem.eql(u8, name, "Double") or std.mem.eql(u8, name, "core_Double") or std.mem.eql(u8, name, "std_core_Double")) return llvm.LLVMDoubleTypeInContext(ctx);
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
    const base_type_name = if (std.mem.indexOf(u8, name, "_core_")) |idx|
        name[0..idx]
    else if (std.mem.indexOf(u8, name, "_collections_")) |idx|
        name[0..idx]
    else
        name;

    const ca = contracts_ast orelse return false;
    if (ca.contains(name) or ca.contains(base_type_name)) return true;

    return false;
}

/// Returns the Fat Pointer struct type { ptr data, ptr vtable }.
pub fn getFatPointerType(ctx: llvm.LLVMContextRef) llvm.LLVMTypeRef {
    const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
    var fields = [_]llvm.LLVMTypeRef{ ptr_type, ptr_type };
    return llvm.LLVMStructTypeInContext(ctx, &fields, 2, 0);
}

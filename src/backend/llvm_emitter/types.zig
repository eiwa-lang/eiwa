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
        .Array, .Custom, .Function, .Union, .GenericParam, .GenericInstance => return llvm.LLVMPointerTypeInContext(ctx, 0),
        .Null, .Unknown => return llvm.LLVMInt64TypeInContext(ctx),
    }
}

/// Returns true if the resolved type is a contract (requires Fat Pointer representation).
pub fn isContractType(resolved_type: types.EiwaType, contracts_ast: ?*std.StringHashMap(*ast.ASTNode)) bool {
    const ca = contracts_ast orelse return false;
    switch (resolved_type) {
        .Custom => |name| return ca.contains(name),
        .GenericInstance => |gi| return ca.contains(gi.base_name),
        else => return false,
    }
}

/// Returns the Fat Pointer struct type { ptr data, ptr vtable }.
pub fn getFatPointerType(ctx: llvm.LLVMContextRef) llvm.LLVMTypeRef {
    const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
    var fields = [_]llvm.LLVMTypeRef{ ptr_type, ptr_type };
    return llvm.LLVMStructTypeInContext(ctx, &fields, 2, 0);
}

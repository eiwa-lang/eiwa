const std = @import("std");
const ast = @import("../../core/ast.zig");
const types = @import("../../core/type_system.zig");
const c_bindings = @import("c_bindings.zig");
const llvm = c_bindings.llvm;

/// Maps Eiwa types to LLVM C-API LLVMTypeRef representation.
pub fn getLLVMType(ctx: llvm.LLVMContextRef, resolved_type: types.EiwaType) llvm.LLVMTypeRef {
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

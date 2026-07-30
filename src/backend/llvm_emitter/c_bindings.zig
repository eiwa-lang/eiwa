const std = @import("std");

/// C-API bindings for LLVM 21 Core, Target, TargetMachine, ExecutionEngine, and PassBuilder APIs.
pub const llvm = @cImport({
    @cInclude("llvm-c/Core.h");
    @cInclude("llvm-c/Target.h");
    @cInclude("llvm-c/TargetMachine.h");
    @cInclude("llvm-c/ExecutionEngine.h");
    @cInclude("llvm-c/Analysis.h");
    @cInclude("llvm-c/BitWriter.h");
    @cInclude("llvm-c/Transforms/PassBuilder.h");
});

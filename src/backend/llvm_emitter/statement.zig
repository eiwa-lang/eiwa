const std = @import("std");
const ast = @import("../../core/ast.zig");
const types_mapping = @import("types.zig");
const expression = @import("expression.zig");
const c_bindings = @import("c_bindings.zig");
const llvm = c_bindings.llvm;

pub fn emitStatement(
    ctx: llvm.LLVMContextRef,
    mod: llvm.LLVMModuleRef,
    builder: llvm.LLVMBuilderRef,
    func_val: llvm.LLVMValueRef,
    scope: *std.StringHashMap(llvm.LLVMValueRef),
    node: *ast.ASTNode,
) !void {
    switch (node.data) {
        .var_decl => |v| {
            const name = v.resolved_c_name orelse v.name;
            const res_type = node.resolved_type orelse return error.MissingTypeForVarDecl;
            const llvm_type = types_mapping.getLLVMType(ctx, res_type.*);

            const name_z = try std.heap.page_allocator.dupeZ(u8, name);
            defer std.heap.page_allocator.free(name_z);

            const alloca_ptr = llvm.LLVMBuildAlloca(builder, llvm_type, name_z.ptr);
            try scope.put(name, alloca_ptr);

            if (v.initializer) |init_node| {
                const val = try expression.emitExpression(ctx, mod, builder, scope, init_node);
                _ = llvm.LLVMBuildStore(builder, val, alloca_ptr);
            }
        },
        .assignment => |assign| {
            const name = assign.name;
            const alloca_ptr = scope.get(name) orelse {
                std.debug.print("LLVM Emitter Error: Cannot assign to undeclared variable '{s}'.\n", .{name});
                return error.VariableNotFound;
            };

            const val = try expression.emitExpression(ctx, mod, builder, scope, assign.value);
            _ = llvm.LLVMBuildStore(builder, val, alloca_ptr);
        },
        .if_expr => |if_node| {
            const cond_val = try expression.emitExpression(ctx, mod, builder, scope, if_node.condition);

            const then_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "if.then");
            const else_bb = if (if_node.else_branch != null) llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "if.else") else null;
            const merge_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "if.merge");

            _ = llvm.LLVMBuildCondBr(builder, cond_val, then_bb, else_bb orelse merge_bb);

            // Emit then branch
            llvm.LLVMPositionBuilderAtEnd(builder, then_bb);
            try emitStatement(ctx, mod, builder, func_val, scope, if_node.then_branch);
            if (llvm.LLVMGetBasicBlockTerminator(then_bb) == null) {
                _ = llvm.LLVMBuildBr(builder, merge_bb);
            }

            // Emit else branch if present
            if (if_node.else_branch) |else_branch| {
                if (else_bb) |eb| {
                    llvm.LLVMPositionBuilderAtEnd(builder, eb);
                    try emitStatement(ctx, mod, builder, func_val, scope, else_branch);
                    if (llvm.LLVMGetBasicBlockTerminator(eb) == null) {
                        _ = llvm.LLVMBuildBr(builder, merge_bb);
                    }
                }
            }

            llvm.LLVMPositionBuilderAtEnd(builder, merge_bb);
        },
        .while_stmt => |w| {
            const cond_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "while.cond");
            const body_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "while.body");
            const after_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "while.after");

            _ = llvm.LLVMBuildBr(builder, cond_bb);

            // Condition block
            llvm.LLVMPositionBuilderAtEnd(builder, cond_bb);
            const cond_val = try expression.emitExpression(ctx, mod, builder, scope, w.condition);
            _ = llvm.LLVMBuildCondBr(builder, cond_val, body_bb, after_bb);

            // Body block
            llvm.LLVMPositionBuilderAtEnd(builder, body_bb);
            try emitStatement(ctx, mod, builder, func_val, scope, w.body);
            if (llvm.LLVMGetBasicBlockTerminator(body_bb) == null) {
                _ = llvm.LLVMBuildBr(builder, cond_bb);
            }

            // After block
            llvm.LLVMPositionBuilderAtEnd(builder, after_bb);
        },
        .return_stmt => |ret| {
            if (ret.value) |val_node| {
                const ret_val = try expression.emitExpression(ctx, mod, builder, scope, val_node);
                _ = llvm.LLVMBuildRet(builder, ret_val);
            } else {
                _ = llvm.LLVMBuildRetVoid(builder);
            }
        },
        .block => |blk| {
            for (blk.statements) |stmt| {
                try emitStatement(ctx, mod, builder, func_val, scope, stmt);
            }
        },
        .program => |prog| {
            for (prog.statements) |stmt| {
                try emitStatement(ctx, mod, builder, func_val, scope, stmt);
            }
        },
        .fun_decl, .import_stmt, .test_decl, .type_decl, .contract_decl, .skill_decl, .object_decl, .enum_decl, .lib_decl => {},
        else => {
            _ = try expression.emitExpression(ctx, mod, builder, scope, node);
        },
    }
}

const std = @import("std");
const ast = @import("../../core/ast.zig");
const types_mapping = @import("types.zig");
const expression = @import("expression.zig");
const core = @import("core.zig");
const c_bindings = @import("c_bindings.zig");
const llvm = c_bindings.llvm;

pub fn emitStatement(
    ctx: llvm.LLVMContextRef,
    mod: llvm.LLVMModuleRef,
    builder: llvm.LLVMBuilderRef,
    func_val: llvm.LLVMValueRef,
    scope: *std.StringHashMap(llvm.LLVMValueRef),
    structs: *std.StringHashMap(core.StructInfo),
    libs: *const std.StringHashMap(std.StringHashMap([]const u8)),
    node: *ast.ASTNode,
) anyerror!void {
    switch (node.data) {
        .var_decl => |v| {
            const name = v.resolved_c_name orelse v.name;
            const res_type = node.resolved_type orelse return error.MissingTypeForVarDecl;
            const llvm_type = types_mapping.getLLVMType(ctx, res_type.*);

            const name_z = try std.heap.page_allocator.dupeZ(u8, name);
            defer std.heap.page_allocator.free(name_z);

            const alloca_ptr = llvm.LLVMBuildAlloca(builder, llvm_type, name_z.ptr);
            try scope.put(name, alloca_ptr);
            // Locals inside object/type methods get a mangled resolved_c_name
            // ({Object}_{name}); keep the plain name in scope too so plain
            // identifier references resolve.
            if (!std.mem.eql(u8, name, v.name)) {
                try scope.put(v.name, alloca_ptr);
            }

            if (v.initializer) |init_node| {
                const val = try expression.emitExpression(ctx, mod, builder, scope, structs, libs, init_node);
                _ = llvm.LLVMBuildStore(builder, val, alloca_ptr);
            }
        },
        .assignment => |assign| {
            const name = assign.name;
            const alloca_ptr = scope.get(name) orelse {
                std.debug.print("LLVM Emitter Error: Cannot assign to undeclared variable '{s}'.\n", .{name});
                return error.VariableNotFound;
            };

            const val = try expression.emitExpression(ctx, mod, builder, scope, structs, libs, assign.value);
            _ = llvm.LLVMBuildStore(builder, val, alloca_ptr);
        },
        .if_expr => |if_node| {
            const cond_val = try expression.emitExpression(ctx, mod, builder, scope, structs, libs, if_node.condition);

            const then_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "if.then");
            const else_bb = if (if_node.else_branch != null) llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "if.else") else null;
            const merge_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "if.merge");

            _ = llvm.LLVMBuildCondBr(builder, cond_val, then_bb, else_bb orelse merge_bb);

            // Emit then branch
            llvm.LLVMPositionBuilderAtEnd(builder, then_bb);
            try emitStatement(ctx, mod, builder, func_val, scope, structs, libs, if_node.then_branch);
            if (llvm.LLVMGetBasicBlockTerminator(then_bb) == null) {
                _ = llvm.LLVMBuildBr(builder, merge_bb);
            }

            // Emit else branch if present
            if (if_node.else_branch) |else_branch| {
                if (else_bb) |eb| {
                    llvm.LLVMPositionBuilderAtEnd(builder, eb);
                    try emitStatement(ctx, mod, builder, func_val, scope, structs, libs, else_branch);
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
            const cond_val = try expression.emitExpression(ctx, mod, builder, scope, structs, libs, w.condition);
            _ = llvm.LLVMBuildCondBr(builder, cond_val, body_bb, after_bb);

            // Body block
            llvm.LLVMPositionBuilderAtEnd(builder, body_bb);
            try emitStatement(ctx, mod, builder, func_val, scope, structs, libs, w.body);
            if (llvm.LLVMGetBasicBlockTerminator(body_bb) == null) {
                _ = llvm.LLVMBuildBr(builder, cond_bb);
            }

            // After block
            llvm.LLVMPositionBuilderAtEnd(builder, after_bb);
        },
        .return_stmt => |ret| {
            if (ret.value) |val_node| {
                const ret_val = try expression.emitExpression(ctx, mod, builder, scope, structs, libs, val_node);
                _ = llvm.LLVMBuildRet(builder, ret_val);
            } else {
                _ = llvm.LLVMBuildRetVoid(builder);
            }
        },
        .throw_stmt => |th| {
            const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
            const i32_type = llvm.LLVMInt32TypeInContext(ctx);

            const exc_val = try expression.emitExpression(ctx, mod, builder, scope, structs, libs, th.expr);
            const active_global = llvm.LLVMGetNamedGlobal(mod, "eiwa_active_exception") orelse return error.ExceptionRuntimeMissing;
            const stack_global = llvm.LLVMGetNamedGlobal(mod, "eiwa_exception_stack") orelse return error.ExceptionRuntimeMissing;
            _ = llvm.LLVMBuildStore(builder, exc_val, active_global);

            const cur_stack = llvm.LLVMBuildLoad2(builder, ptr_type, stack_global, "cur_stack");
            const null_ptr = llvm.LLVMConstNull(ptr_type);
            const has_handler = llvm.LLVMBuildICmp(builder, llvm.LLVMIntNE, cur_stack, null_ptr, "has_handler");

            const do_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "throw.do");
            const unhandled_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "throw.unhandled");
            _ = llvm.LLVMBuildCondBr(builder, has_handler, do_bb, unhandled_bb);

            llvm.LLVMPositionBuilderAtEnd(builder, do_bb);
            {
                const frame_type = llvm.LLVMGetTypeByName(mod, "EiwaExceptionFrame") orelse return error.ExceptionRuntimeMissing;
                const buf_gep = llvm.LLVMBuildStructGEP2(builder, frame_type, cur_stack, 0, "stack_buf");
                const buf_ptr = llvm.LLVMBuildBitCast(builder, buf_gep, ptr_type, "sbuf");
                const longjmp_func = llvm.LLVMGetNamedFunction(mod, "longjmp") orelse return error.ExceptionRuntimeMissing;
                const lj_type = llvm.LLVMGlobalGetValueType(longjmp_func);
                const one_i32 = llvm.LLVMConstInt(i32_type, 1, 0);
                var lj_args = [_]llvm.LLVMValueRef{ buf_ptr, one_i32 };
                _ = llvm.LLVMBuildCall2(builder, lj_type, longjmp_func, &lj_args, 2, "");
                _ = llvm.LLVMBuildUnreachable(builder);
            }

            llvm.LLVMPositionBuilderAtEnd(builder, unhandled_bb);
            {
                const exit_func = llvm.LLVMGetNamedFunction(mod, "exit") orelse return error.ExceptionRuntimeMissing;
                const exit_type = llvm.LLVMGlobalGetValueType(exit_func);
                const one_i32 = llvm.LLVMConstInt(i32_type, 1, 0);
                var exit_args = [_]llvm.LLVMValueRef{one_i32};
                _ = llvm.LLVMBuildCall2(builder, exit_type, exit_func, &exit_args, 1, "");
                _ = llvm.LLVMBuildUnreachable(builder);
            }

            const cont_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "throw.cont");
            llvm.LLVMPositionBuilderAtEnd(builder, cont_bb);
        },
        .try_stmt => |ts| {
            const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
            const i32_type = llvm.LLVMInt32TypeInContext(ctx);
            const frame_type = llvm.LLVMGetTypeByName(mod, "EiwaExceptionFrame") orelse return error.ExceptionRuntimeMissing;
            const stack_global = llvm.LLVMGetNamedGlobal(mod, "eiwa_exception_stack") orelse return error.ExceptionRuntimeMissing;
            const active_global = llvm.LLVMGetNamedGlobal(mod, "eiwa_active_exception") orelse return error.ExceptionRuntimeMissing;

            const frame_ptr = llvm.LLVMBuildAlloca(builder, frame_type, "exc_frame");
            llvm.LLVMSetAlignment(frame_ptr, 16);

            const cur_stack = llvm.LLVMBuildLoad2(builder, ptr_type, stack_global, "cur_stack");
            const next_gep = llvm.LLVMBuildStructGEP2(builder, frame_type, frame_ptr, 1, "frame_next");
            _ = llvm.LLVMBuildStore(builder, cur_stack, next_gep);
            _ = llvm.LLVMBuildStore(builder, frame_ptr, stack_global);

            const buf_gep = llvm.LLVMBuildStructGEP2(builder, frame_type, frame_ptr, 0, "frame_buf");
            const buf_ptr = llvm.LLVMBuildBitCast(builder, buf_gep, ptr_type, "fbuf");
            const setjmp_func = llvm.LLVMGetNamedFunction(mod, "setjmp") orelse return error.ExceptionRuntimeMissing;
            const sj_type = llvm.LLVMGlobalGetValueType(setjmp_func);
            var sj_args = [_]llvm.LLVMValueRef{buf_ptr};
            const sj_ret = llvm.LLVMBuildCall2(builder, sj_type, setjmp_func, &sj_args, 1, "setjmp_ret");
            const zero_i32 = llvm.LLVMConstInt(i32_type, 0, 0);
            const is_try = llvm.LLVMBuildICmp(builder, llvm.LLVMIntEQ, sj_ret, zero_i32, "is_try");

            const try_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "try.body");
            const catch_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "try.catch");
            const after_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "try.after");
            _ = llvm.LLVMBuildCondBr(builder, is_try, try_bb, catch_bb);

            llvm.LLVMPositionBuilderAtEnd(builder, try_bb);
            try emitStatement(ctx, mod, builder, func_val, scope, structs, libs, ts.body);
            {
                const stack2 = llvm.LLVMBuildLoad2(builder, ptr_type, stack_global, "stack2");
                const next_gep2 = llvm.LLVMBuildStructGEP2(builder, frame_type, stack2, 1, "next2");
                const next_val2 = llvm.LLVMBuildLoad2(builder, ptr_type, next_gep2, "next_val2");
                _ = llvm.LLVMBuildStore(builder, next_val2, stack_global);
            }
            if (llvm.LLVMGetBasicBlockTerminator(llvm.LLVMGetInsertBlock(builder)) == null) {
                _ = llvm.LLVMBuildBr(builder, after_bb);
            }

            llvm.LLVMPositionBuilderAtEnd(builder, catch_bb);
            {
                const stack3 = llvm.LLVMBuildLoad2(builder, ptr_type, stack_global, "stack3");
                const next_gep3 = llvm.LLVMBuildStructGEP2(builder, frame_type, stack3, 1, "next3");
                const next_val3 = llvm.LLVMBuildLoad2(builder, ptr_type, next_gep3, "next_val3");
                _ = llvm.LLVMBuildStore(builder, next_val3, stack_global);
            }
            const exc_val = llvm.LLVMBuildLoad2(builder, ptr_type, active_global, "exc");
            _ = llvm.LLVMBuildStore(builder, llvm.LLVMConstNull(ptr_type), active_global);

            if (ts.catches.len > 0) {
                // TODO(emitter): Only the FIRST catch is handled here, and its
                // declared exception types are ignored — the C transpiler
                // dispatches typed catches (`catch (e: FooError)`) by comparing
                // an EiwaTypeDescriptor against the thrown value, and rethrows
                // when no catch matches. The LLVM model has no type descriptors
                // (see the `when (x) is T` TODO in expression.zig), so typed
                // multi-catch and rethrow semantics are silently dropped.
                // Proper fix: materialize type tags/descriptors so catch clauses
                // filter by type, and emit an else-rethrow for unhandled cases.
                // INHERITED GAMBIARRA: the setjmp/longjmp exception model itself
                // came from the C backend — see PRE-EXISTING comment in
                // src/backend/c_transpiler/statement.zig (try_stmt). The C
                // version is exact (uses the runtime's frame helpers + typed
                // catches); this LLVM copy is the degraded one. Fix in C first
                // or share the same helpers so both stay identical.
                const c = ts.catches[0];
                if (c.var_name) |var_name| {
                    const v_z = try std.heap.page_allocator.dupeZ(u8, var_name);
                    defer std.heap.page_allocator.free(v_z);
                    const var_alloca = llvm.LLVMBuildAlloca(builder, ptr_type, v_z.ptr);
                    _ = llvm.LLVMBuildStore(builder, exc_val, var_alloca);
                    try scope.put(var_name, var_alloca);
                }
                try emitStatement(ctx, mod, builder, func_val, scope, structs, libs, c.body);
            }

            if (llvm.LLVMGetBasicBlockTerminator(llvm.LLVMGetInsertBlock(builder)) == null) {
                _ = llvm.LLVMBuildBr(builder, after_bb);
            }

            llvm.LLVMPositionBuilderAtEnd(builder, after_bb);
        },
        .block => |blk| {
            for (blk.statements) |stmt| {
                try emitStatement(ctx, mod, builder, func_val, scope, structs, libs, stmt);
            }
        },
        .program => |prog| {
            for (prog.statements) |stmt| {
                try emitStatement(ctx, mod, builder, func_val, scope, structs, libs, stmt);
            }
        },
        .fun_decl, .import_stmt, .test_decl, .type_decl, .contract_decl, .skill_decl, .object_decl, .enum_decl, .lib_decl => {},
        else => {
            _ = try expression.emitExpression(ctx, mod, builder, scope, structs, libs, node);
        },
    }
}

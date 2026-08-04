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
            const is_contract = types_mapping.isContractType(res_type.*, expression.global_contracts_ast_ptr);
            const llvm_type = if (is_contract) types_mapping.getFatPointerType(ctx) else types_mapping.getLLVMType(ctx, res_type.*);

            const name_z = try std.heap.page_allocator.dupeZ(u8, name);
            defer std.heap.page_allocator.free(name_z);

            const alloca_ptr = llvm.LLVMBuildAlloca(builder, llvm_type, name_z.ptr);
            try scope.put(name, alloca_ptr);
            if (!std.mem.eql(u8, name, v.name)) {
                try scope.put(v.name, alloca_ptr);
            }

            if (v.initializer) |init_node| {
                var val = try expression.emitExpression(ctx, mod, builder, scope, structs, libs, init_node);
                if (is_contract) {
                    const contract_name = switch (res_type.*) {
                        .Custom => |n| n,
                        .GenericInstance => |gi| gi.base_name,
                        else => "",
                    };
                    if (init_node.resolved_type) |init_rt| {
                        const init_c_name = switch (init_rt.*) {
                            .Custom => |n| n,
                            .GenericInstance => |gi| gi.base_name,
                            else => "",
                        };
                        if (init_c_name.len > 0 and contract_name.len > 0) {
                            val = try expression.coerceToContract(ctx, mod, builder, val, init_c_name, contract_name);
                        }
                    }
                }
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
            if (llvm.LLVMGetBasicBlockTerminator(llvm.LLVMGetInsertBlock(builder)) == null) {
                _ = llvm.LLVMBuildBr(builder, merge_bb);
            }

            // Emit else branch if present
            if (if_node.else_branch) |else_branch| {
                if (else_bb) |eb| {
                    llvm.LLVMPositionBuilderAtEnd(builder, eb);
                    try emitStatement(ctx, mod, builder, func_val, scope, structs, libs, else_branch);
                    if (llvm.LLVMGetBasicBlockTerminator(llvm.LLVMGetInsertBlock(builder)) == null) {
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
            if (llvm.LLVMGetBasicBlockTerminator(llvm.LLVMGetInsertBlock(builder)) == null) {
                _ = llvm.LLVMBuildBr(builder, cond_bb);
            }

            // After block
            llvm.LLVMPositionBuilderAtEnd(builder, after_bb);
        },
        .for_stmt => |f| {
            // For-in over NativeArray/List on the raw buffer layout
            // (slot 0 = size, slots 2.. = elements). Item values are loaded as
            // i64 slots and bitcast to pointers when the element type is a
            // reference type. LLVM-SPECIFIC (NOT inherited from C): the C
            // transpiler iterates EiwaArray struct fields (data/length) — see
            // src/backend/c_transpiler/statement.zig (for_stmt).
            const arr_rt = if (f.iterable.resolved_type) |rt| rt.* else return error.UnsupportedForIterable;
            if (arr_rt != .Array and arr_rt != .Custom) return error.UnsupportedForIterable;

            const i64_type = llvm.LLVMInt64TypeInContext(ctx);
            const arr_val = try expression.emitExpression(ctx, mod, builder, scope, structs, libs, f.iterable);

            var idx0 = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, 0, 0)};
            const size_ptr = llvm.LLVMBuildGEP2(builder, i64_type, arr_val, &idx0, 1, "for_size_ptr");
            const size_val = llvm.LLVMBuildLoad2(builder, i64_type, size_ptr, "for_size");

            const i_ptr = llvm.LLVMBuildAlloca(builder, i64_type, "for_i");
            _ = llvm.LLVMBuildStore(builder, llvm.LLVMConstInt(i64_type, 0, 0), i_ptr);

            const cond_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "for.cond");
            const body_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "for.body");
            const after_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "for.after");

            _ = llvm.LLVMBuildBr(builder, cond_bb);

            llvm.LLVMPositionBuilderAtEnd(builder, cond_bb);
            const i_cur = llvm.LLVMBuildLoad2(builder, i64_type, i_ptr, "for_i_cur");
            const cond = llvm.LLVMBuildICmp(builder, llvm.LLVMIntSLT, i_cur, size_val, "for_cond");
            _ = llvm.LLVMBuildCondBr(builder, cond, body_bb, after_bb);

            llvm.LLVMPositionBuilderAtEnd(builder, body_bb);
            const i_body = llvm.LLVMBuildLoad2(builder, i64_type, i_ptr, "for_i_body");
            const elem_offset = llvm.LLVMBuildAdd(builder, i_body, llvm.LLVMConstInt(i64_type, 2, 0), "for_offset");
            var elem_idx = [_]llvm.LLVMValueRef{elem_offset};
            const elem_ptr = llvm.LLVMBuildGEP2(builder, i64_type, arr_val, &elem_idx, 1, "for_elem_ptr");
            var item_val = llvm.LLVMBuildLoad2(builder, i64_type, elem_ptr, "for_item");
            if (arr_rt == .Array) {
                const elem_t = arr_rt.Array.*;
                if (elem_t == .Custom or elem_t == .String or elem_t == .Pointer or elem_t == .Array or elem_t == .Union or elem_t == .Function) {
                    item_val = llvm.LLVMBuildIntToPtr(builder, item_val, llvm.LLVMPointerTypeInContext(ctx, 0), "for_item_ptr");
                } else if (elem_t == .Double) {
                    item_val = llvm.LLVMBuildBitCast(builder, item_val, llvm.LLVMDoubleTypeInContext(ctx), "for_item_double");
                }
            }

            var loop_scope = std.StringHashMap(llvm.LLVMValueRef).init(scope.allocator);
            defer loop_scope.deinit();
            var scope_it = scope.iterator();
            while (scope_it.next()) |entry| {
                try loop_scope.put(entry.key_ptr.*, entry.value_ptr.*);
            }
            // The item lives in an alloca (like function params and var decls)
            // so the identifier path loads it correctly instead of treating a
            // direct pointer value as an alloca address.
            const item_type = llvm.LLVMTypeOf(item_val);
            const item_name_z = try std.heap.page_allocator.dupeZ(u8, f.item_name);
            defer std.heap.page_allocator.free(item_name_z);
            const item_alloca = llvm.LLVMBuildAlloca(builder, item_type, item_name_z.ptr);
            _ = llvm.LLVMBuildStore(builder, item_val, item_alloca);
            try loop_scope.put(f.item_name, item_alloca);

            try emitStatement(ctx, mod, builder, func_val, &loop_scope, structs, libs, f.body);

            const i_next = llvm.LLVMBuildAdd(builder, i_body, llvm.LLVMConstInt(i64_type, 1, 0), "for_i_next");
            _ = llvm.LLVMBuildStore(builder, i_next, i_ptr);
            if (llvm.LLVMGetBasicBlockTerminator(llvm.LLVMGetInsertBlock(builder)) == null) {
                _ = llvm.LLVMBuildBr(builder, cond_bb);
            }

            llvm.LLVMPositionBuilderAtEnd(builder, after_bb);
        },
        .return_stmt => |ret| {
            if (ret.value) |val_node| {
                var ret_val = try expression.emitExpression(ctx, mod, builder, scope, structs, libs, val_node);
                const fn_type = llvm.LLVMGlobalGetValueType(func_val);
                const expected_ret_type = llvm.LLVMGetReturnType(fn_type);

                const fat_type = types_mapping.getFatPointerType(ctx);
                if (expected_ret_type == fat_type and llvm.LLVMTypeOf(ret_val) != fat_type) {
                    if (val_node.resolved_type) |val_rt| {
                        const val_c_name = switch (val_rt.*) {
                            .Custom => |n| n,
                            .GenericInstance => |gi| gi.base_name,
                            else => "",
                        };
                        // Extract target contract name from function return type
                        if (val_c_name.len > 0) {
                            // Find contract name from func_val
                            if (expression.global_contracts_ast_ptr) |ca| {
                                var it = ca.iterator();
                                while (it.next()) |entry| {
                                    const c_name = entry.key_ptr.*;
                                    ret_val = expression.coerceToContract(ctx, mod, builder, ret_val, val_c_name, c_name) catch ret_val;
                                    if (llvm.LLVMTypeOf(ret_val) == fat_type) break;
                                }
                            }
                        }
                    }
                }
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

            // throw never falls through: both branches end in unreachable. Put
            // the builder in a fresh unreachable block so subsequent statements
            // (if any) still have a valid (dead) insertion point without
            // leaving an unterminated basic block in the module.
            const cont_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "throw.cont");
            llvm.LLVMPositionBuilderAtEnd(builder, cont_bb);
            _ = llvm.LLVMBuildUnreachable(builder);
            const dead_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "throw.dead");
            llvm.LLVMPositionBuilderAtEnd(builder, dead_bb);
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

                    var final_exc_val = exc_val;
                    if (c.types.len > 0) {
                        const tr = c.types[0];
                        if (tr.resolved_type) |rt| {
                            if (types_mapping.isContractType(rt.*, expression.global_contracts_ast_ptr)) {
                                const contract_name = switch (rt.*) {
                                    .Custom => |n| n,
                                    .GenericInstance => |gi| gi.base_name,
                                    else => "",
                                };
                                const fat_type = types_mapping.getFatPointerType(ctx);
                                const var_alloca = llvm.LLVMBuildAlloca(builder, fat_type, v_z.ptr);
                                if (contract_name.len > 0) {
                                    final_exc_val = expression.coerceToContract(ctx, mod, builder, exc_val, "BoomException", contract_name) catch exc_val;
                                }
                                _ = llvm.LLVMBuildStore(builder, final_exc_val, var_alloca);
                                try scope.put(var_name, var_alloca);
                            } else {
                                const var_alloca = llvm.LLVMBuildAlloca(builder, ptr_type, v_z.ptr);
                                _ = llvm.LLVMBuildStore(builder, final_exc_val, var_alloca);
                                try scope.put(var_name, var_alloca);
                            }
                        } else {
                            const var_alloca = llvm.LLVMBuildAlloca(builder, ptr_type, v_z.ptr);
                            _ = llvm.LLVMBuildStore(builder, final_exc_val, var_alloca);
                            try scope.put(var_name, var_alloca);
                        }
                    } else {
                        const var_alloca = llvm.LLVMBuildAlloca(builder, ptr_type, v_z.ptr);
                        _ = llvm.LLVMBuildStore(builder, final_exc_val, var_alloca);
                        try scope.put(var_name, var_alloca);
                    }
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

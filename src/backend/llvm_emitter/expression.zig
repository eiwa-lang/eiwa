const std = @import("std");
const ast = @import("../../core/ast.zig");
const types_mapping = @import("types.zig");
const core = @import("core.zig");
const c_bindings = @import("c_bindings.zig");
const llvm = c_bindings.llvm;

pub fn emitExpression(
    ctx: llvm.LLVMContextRef,
    mod: llvm.LLVMModuleRef,
    builder: llvm.LLVMBuilderRef,
    scope: *std.StringHashMap(llvm.LLVMValueRef),
    structs: *std.StringHashMap(core.StructInfo),
    node: *ast.ASTNode,
) anyerror!llvm.LLVMValueRef {
    switch (node.data) {
        .int_literal => |val| {
            const i64_type = llvm.LLVMInt64TypeInContext(ctx);
            return llvm.LLVMConstInt(i64_type, @bitCast(val), 0);
        },
        .double_literal => |val| {
            const double_type = llvm.LLVMDoubleTypeInContext(ctx);
            return llvm.LLVMConstReal(double_type, val);
        },
        .bool_literal => |val| {
            const i1_type = llvm.LLVMInt1TypeInContext(ctx);
            return llvm.LLVMConstInt(i1_type, if (val) 1 else 0, 0);
        },
        .string_literal => |str| {
            const str_z = try std.heap.page_allocator.dupeZ(u8, str);
            defer std.heap.page_allocator.free(str_z);
            return llvm.LLVMBuildGlobalStringPtr(builder, str_z.ptr, "str_tmp");
        },
        .identifier => |ident| {
            const name = ident.resolved_c_name orelse ident.name;
            if (scope.get(name)) |var_val| {
                const val_type = llvm.LLVMTypeOf(var_val);
                // Check if variable is an alloca pointer vs direct parameter value
                if (llvm.LLVMGetTypeKind(val_type) == llvm.LLVMPointerTypeKind) {
                    const res_type = node.resolved_type orelse return var_val;
                    const elem_type = types_mapping.getLLVMType(ctx, res_type.*);
                    const name_z = try std.fmt.allocPrint(std.heap.page_allocator, "{s}_val\x00", .{name});
                    defer std.heap.page_allocator.free(name_z);
                    return llvm.LLVMBuildLoad2(builder, elem_type, var_val, name_z.ptr);
                }
                return var_val;
            }
            std.debug.print("LLVM Emitter Error: Variable '{s}' not found in local scope.\n", .{name});
            return error.VariableNotFound;
        },
        .get_expr => |get| {
            const obj_val = try emitExpression(ctx, mod, builder, scope, structs, get.object);
            if (get.object.resolved_type) |rt| {
                var type_name: []const u8 = "";
                if (rt.* == .Custom) {
                    type_name = rt.Custom;
                } else if (rt.* == .Pointer and rt.Pointer.* == .Custom) {
                    type_name = rt.Pointer.Custom;
                }
                if (structs.get(type_name)) |s_info| {
                    for (s_info.field_names, 0..) |f_name, f_idx| {
                        if (std.mem.eql(u8, f_name, get.name)) {
                            const field_name_z = try std.heap.page_allocator.dupeZ(u8, f_name);
                            defer std.heap.page_allocator.free(field_name_z);

                            const field_ptr = llvm.LLVMBuildStructGEP2(builder, s_info.struct_type, obj_val, @intCast(f_idx), field_name_z.ptr);
                            const field_type = s_info.field_types[f_idx];
                            return llvm.LLVMBuildLoad2(builder, field_type, field_ptr, "get_val");
                        }
                    }
                }
            }
            return error.PropertyNotFound;
        },
        .set_expr => |set| {
            const obj_val = try emitExpression(ctx, mod, builder, scope, structs, set.object);
            const val = try emitExpression(ctx, mod, builder, scope, structs, set.value);

            if (set.object.resolved_type) |rt| {
                var type_name: []const u8 = "";
                if (rt.* == .Custom) {
                    type_name = rt.Custom;
                } else if (rt.* == .Pointer and rt.Pointer.* == .Custom) {
                    type_name = rt.Pointer.Custom;
                }
                if (structs.get(type_name)) |s_info| {
                    for (s_info.field_names, 0..) |f_name, f_idx| {
                        if (std.mem.eql(u8, f_name, set.name)) {
                            const field_name_z = try std.heap.page_allocator.dupeZ(u8, f_name);
                            defer std.heap.page_allocator.free(field_name_z);

                            const field_ptr = llvm.LLVMBuildStructGEP2(builder, s_info.struct_type, obj_val, @intCast(f_idx), field_name_z.ptr);
                            _ = llvm.LLVMBuildStore(builder, val, field_ptr);
                            return val;
                        }
                    }
                }
            }
            return error.PropertyNotFound;
        },
        .array_literal => |arr| {
            const count: i64 = @intCast(arr.elements.len);
            const total_slots: i64 = count + 2; // slot 0: size, slot 1: capacity, slot 2..N+1: elements
            const size_bytes: i64 = total_slots * 8;

            const malloc_func = llvm.LLVMGetNamedFunction(mod, "malloc") orelse llvm.LLVMGetNamedFunction(mod, "GC_malloc").?;
            const malloc_type = llvm.LLVMGlobalGetValueType(malloc_func);
            const size_val = llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(ctx), @bitCast(size_bytes), 0);
            var malloc_args = [_]llvm.LLVMValueRef{size_val};
            const arr_ptr = llvm.LLVMBuildCall2(builder, malloc_type, malloc_func, &malloc_args, 1, "arr_alloc");

            const i64_type = llvm.LLVMInt64TypeInContext(ctx);
            // Store size at slot 0
            var idx0 = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, 0, 0)};
            const size_ptr = llvm.LLVMBuildGEP2(builder, i64_type, arr_ptr, &idx0, 1, "size_ptr");
            _ = llvm.LLVMBuildStore(builder, llvm.LLVMConstInt(i64_type, @bitCast(count), 0), size_ptr);

            // Store capacity at slot 1
            var idx1 = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, 1, 0)};
            const cap_ptr = llvm.LLVMBuildGEP2(builder, i64_type, arr_ptr, &idx1, 1, "cap_ptr");
            _ = llvm.LLVMBuildStore(builder, llvm.LLVMConstInt(i64_type, @bitCast(count), 0), cap_ptr);

            // Store elements
            for (arr.elements, 0..) |elem_node, idx| {
                const elem_val = try emitExpression(ctx, mod, builder, scope, structs, elem_node);
                const offset_val = llvm.LLVMConstInt(i64_type, @bitCast(@as(i64, @intCast(idx + 2))), 0);
                var elem_idx = [_]llvm.LLVMValueRef{offset_val};
                const elem_ptr = llvm.LLVMBuildGEP2(builder, i64_type, arr_ptr, &elem_idx, 1, "elem_ptr");
                _ = llvm.LLVMBuildStore(builder, elem_val, elem_ptr);
            }

            return arr_ptr;
        },
        .index_expr => |idx_expr| {
            const arr_ptr = try emitExpression(ctx, mod, builder, scope, structs, idx_expr.object);
            const i_val = try emitExpression(ctx, mod, builder, scope, structs, idx_expr.index);

            const i64_type = llvm.LLVMInt64TypeInContext(ctx);
            const offset_val = llvm.LLVMBuildAdd(builder, i_val, llvm.LLVMConstInt(i64_type, 2, 0), "offset");
            var elem_idx = [_]llvm.LLVMValueRef{offset_val};
            const elem_ptr = llvm.LLVMBuildGEP2(builder, i64_type, arr_ptr, &elem_idx, 1, "arr_idx_gep");
            return llvm.LLVMBuildLoad2(builder, i64_type, elem_ptr, "arr_elem_val");
        },
        .index_set_expr => |set_idx| {
            const arr_ptr = try emitExpression(ctx, mod, builder, scope, structs, set_idx.object);
            const i_val = try emitExpression(ctx, mod, builder, scope, structs, set_idx.index);
            const val = try emitExpression(ctx, mod, builder, scope, structs, set_idx.value);

            const i64_type = llvm.LLVMInt64TypeInContext(ctx);
            const offset_val = llvm.LLVMBuildAdd(builder, i_val, llvm.LLVMConstInt(i64_type, 2, 0), "offset");
            var elem_idx = [_]llvm.LLVMValueRef{offset_val};
            const elem_ptr = llvm.LLVMBuildGEP2(builder, i64_type, arr_ptr, &elem_idx, 1, "arr_set_gep");
            _ = llvm.LLVMBuildStore(builder, val, elem_ptr);
            return val;
        },
        .unary_expr => |un| {
            const operand_val = try emitExpression(ctx, mod, builder, scope, structs, un.operand);
            switch (un.operator) {
                .minus => {
                    if (un.operand.resolved_type) |t| {
                        if (t.* == .Double) {
                            return llvm.LLVMBuildFNeg(builder, operand_val, "fnegtmp");
                        }
                    }
                    return llvm.LLVMBuildNeg(builder, operand_val, "negtmp");
                },
                .bang => {
                    return llvm.LLVMBuildNot(builder, operand_val, "nottmp");
                },
                else => return error.UnsupportedUnaryOperator,
            }
        },
        .binary_expr => |bin| {
            const left_val = try emitExpression(ctx, mod, builder, scope, structs, bin.left);
            const right_val = try emitExpression(ctx, mod, builder, scope, structs, bin.right);

            const is_double = if (bin.left.resolved_type) |t| (t.* == .Double) else false;

            switch (bin.op) {
                .plus => {
                    if (is_double) return llvm.LLVMBuildFAdd(builder, left_val, right_val, "faddtmp");
                    return llvm.LLVMBuildAdd(builder, left_val, right_val, "addtmp");
                },
                .minus => {
                    if (is_double) return llvm.LLVMBuildFSub(builder, left_val, right_val, "fsubtmp");
                    return llvm.LLVMBuildSub(builder, left_val, right_val, "subtmp");
                },
                .star => {
                    if (is_double) return llvm.LLVMBuildFMul(builder, left_val, right_val, "fmultmp");
                    return llvm.LLVMBuildMul(builder, left_val, right_val, "multmp");
                },
                .slash => {
                    if (is_double) return llvm.LLVMBuildFDiv(builder, left_val, right_val, "fdivtmp");
                    return llvm.LLVMBuildSDiv(builder, left_val, right_val, "divtmp");
                },
                .less => {
                    if (is_double) return llvm.LLVMBuildFCmp(builder, llvm.LLVMRealOLT, left_val, right_val, "flttmp");
                    return llvm.LLVMBuildICmp(builder, llvm.LLVMIntSLT, left_val, right_val, "lttmp");
                },
                .less_eq => {
                    if (is_double) return llvm.LLVMBuildFCmp(builder, llvm.LLVMRealOLE, left_val, right_val, "fletmp");
                    return llvm.LLVMBuildICmp(builder, llvm.LLVMIntSLE, left_val, right_val, "letmp");
                },
                .greater => {
                    if (is_double) return llvm.LLVMBuildFCmp(builder, llvm.LLVMRealOGT, left_val, right_val, "fgttmp");
                    return llvm.LLVMBuildICmp(builder, llvm.LLVMIntSGT, left_val, right_val, "gttmp");
                },
                .greater_eq => {
                    if (is_double) return llvm.LLVMBuildFCmp(builder, llvm.LLVMRealOGE, left_val, right_val, "fgetmp");
                    return llvm.LLVMBuildICmp(builder, llvm.LLVMIntSGE, left_val, right_val, "getmp");
                },
                .eq_eq => {
                    if (is_double) return llvm.LLVMBuildFCmp(builder, llvm.LLVMRealOEQ, left_val, right_val, "feqtmp");
                    return llvm.LLVMBuildICmp(builder, llvm.LLVMIntEQ, left_val, right_val, "eqtmp");
                },
                .bang_eq => {
                    if (is_double) return llvm.LLVMBuildFCmp(builder, llvm.LLVMRealUNE, left_val, right_val, "fnetmp");
                    return llvm.LLVMBuildICmp(builder, llvm.LLVMIntNE, left_val, right_val, "netmp");
                },
                .and_and => return llvm.LLVMBuildAnd(builder, left_val, right_val, "andtmp"),
                .or_or => return llvm.LLVMBuildOr(builder, left_val, right_val, "ortmp"),
                else => return error.UnsupportedBinaryOperator,
            }
        },
        .lambda_expr => |lam| {
            const lam_name_z = try std.heap.page_allocator.dupeZ(u8, "lambda_anon_fn");
            defer std.heap.page_allocator.free(lam_name_z);

            var param_types = try std.heap.page_allocator.alloc(llvm.LLVMTypeRef, lam.params.len);
            defer std.heap.page_allocator.free(param_types);

            for (lam.params, 0..) |p, i| {
                if (p.type_ref) |tr| {
                    if (tr.resolved_type) |rt| {
                        param_types[i] = types_mapping.getLLVMType(ctx, rt.*);
                        continue;
                    }
                }
                param_types[i] = llvm.LLVMInt64TypeInContext(ctx);
            }

            var ret_type: llvm.LLVMTypeRef = llvm.LLVMInt64TypeInContext(ctx);
            if (node.resolved_type) |rt| {
                if (rt.* == .Function) {
                    ret_type = types_mapping.getLLVMType(ctx, rt.Function.return_type.*);
                }
            }

            const func_type = llvm.LLVMFunctionType(ret_type, if (param_types.len > 0) param_types.ptr else null, @intCast(param_types.len), 0);
            const func_val = llvm.LLVMAddFunction(mod, lam_name_z.ptr, func_type);

            const parent_bb = llvm.LLVMGetInsertBlock(builder);

            const entry_block = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "entry");
            llvm.LLVMPositionBuilderAtEnd(builder, entry_block);

            var lam_scope = std.StringHashMap(llvm.LLVMValueRef).init(std.heap.page_allocator);
            defer lam_scope.deinit();

            for (lam.params, 0..) |p, i| {
                const param_val = llvm.LLVMGetParam(func_val, @intCast(i));
                const p_type = llvm.LLVMTypeOf(param_val);
                const p_name_z = try std.heap.page_allocator.dupeZ(u8, p.name);
                defer std.heap.page_allocator.free(p_name_z);

                const alloca_ptr = llvm.LLVMBuildAlloca(builder, p_type, p_name_z.ptr);
                _ = llvm.LLVMBuildStore(builder, param_val, alloca_ptr);
                try lam_scope.put(p.name, alloca_ptr);
            }

            const statement = @import("statement.zig");
            for (lam.body) |stmt| {
                try statement.emitStatement(ctx, mod, builder, func_val, &lam_scope, structs, stmt);
            }

            const cur_bb = llvm.LLVMGetInsertBlock(builder);
            if (llvm.LLVMGetBasicBlockTerminator(cur_bb) == null) {
                const r_kind = llvm.LLVMGetTypeKind(ret_type);
                if (r_kind == llvm.LLVMVoidTypeKind) {
                    _ = llvm.LLVMBuildRetVoid(builder);
                } else if (r_kind == llvm.LLVMIntegerTypeKind) {
                    _ = llvm.LLVMBuildRet(builder, llvm.LLVMConstInt(ret_type, 0, 0));
                } else if (r_kind == llvm.LLVMDoubleTypeKind) {
                    _ = llvm.LLVMBuildRet(builder, llvm.LLVMConstReal(ret_type, 0.0));
                } else {
                    _ = llvm.LLVMBuildRetVoid(builder);
                }
            }

            if (parent_bb) |pbb| {
                llvm.LLVMPositionBuilderAtEnd(builder, pbb);
            }

            return func_val;
        },
        .call_expr => |call| {
            if (call.callee.data == .identifier) {
                const callee_name = call.callee.data.identifier.resolved_c_name orelse call.callee.data.identifier.name;

                const is_print_call = std.mem.eql(u8, callee_name, "print") or
                    std.mem.startsWith(u8, callee_name, "System_print") or
                    std.mem.startsWith(u8, callee_name, "io_print");

                if (is_print_call) {
                    const printf_func = llvm.LLVMGetNamedFunction(mod, "printf") orelse return error.PrintfNotFound;
                    const printf_type = llvm.LLVMGlobalGetValueType(printf_func);

                    if (call.arguments.len > 0) {
                        const arg_val = try emitExpression(ctx, mod, builder, scope, structs, call.arguments[0]);
                        const arg_type = llvm.LLVMTypeOf(arg_val);

                        var fmt_str: [*c]const u8 = "%lld\n";
                        if (llvm.LLVMGetTypeKind(arg_type) == llvm.LLVMDoubleTypeKind) {
                            fmt_str = "%f\n";
                        } else if (llvm.LLVMGetTypeKind(arg_type) == llvm.LLVMPointerTypeKind) {
                            fmt_str = "%s\n";
                        }

                        const fmt_val = llvm.LLVMBuildGlobalStringPtr(builder, fmt_str, "fmt_str");
                        var printf_args = [_]llvm.LLVMValueRef{ fmt_val, arg_val };

                        return llvm.LLVMBuildCall2(
                            builder,
                            printf_type,
                            printf_func,
                            &printf_args,
                            2,
                            "printftmp",
                        );
                    }
                }

                const callee_z = try std.heap.page_allocator.dupeZ(u8, callee_name);
                defer std.heap.page_allocator.free(callee_z);

                if (llvm.LLVMGetNamedFunction(mod, callee_z.ptr)) |func_val| {
                    var arg_vals = try std.heap.page_allocator.alloc(llvm.LLVMValueRef, call.arguments.len);
                    defer std.heap.page_allocator.free(arg_vals);

                    for (call.arguments, 0..) |arg_node, idx| {
                        arg_vals[idx] = try emitExpression(ctx, mod, builder, scope, structs, arg_node);
                    }

                    const func_type = llvm.LLVMGlobalGetValueType(func_val);
                    return llvm.LLVMBuildCall2(
                        builder,
                        func_type,
                        func_val,
                        if (arg_vals.len > 0) arg_vals.ptr else null,
                        @intCast(arg_vals.len),
                        "calltmp",
                    );
                }
            }

            // Dynamic Function / Lambda Call
            const callee_val = try emitExpression(ctx, mod, builder, scope, structs, call.callee);

            var arg_vals = try std.heap.page_allocator.alloc(llvm.LLVMValueRef, call.arguments.len);
            defer std.heap.page_allocator.free(arg_vals);

            for (call.arguments, 0..) |arg_node, idx| {
                arg_vals[idx] = try emitExpression(ctx, mod, builder, scope, structs, arg_node);
            }

            var ret_type: llvm.LLVMTypeRef = llvm.LLVMInt64TypeInContext(ctx);
            var param_types = try std.heap.page_allocator.alloc(llvm.LLVMTypeRef, call.arguments.len);
            defer std.heap.page_allocator.free(param_types);

            if (call.callee.resolved_type) |rt| {
                if (rt.* == .Function) {
                    ret_type = types_mapping.getLLVMType(ctx, rt.Function.return_type.*);
                    for (call.arguments, 0..) |_, idx| {
                        if (idx < rt.Function.params.len) {
                            param_types[idx] = types_mapping.getLLVMType(ctx, rt.Function.params[idx].*);
                        } else {
                            param_types[idx] = llvm.LLVMInt64TypeInContext(ctx);
                        }
                    }
                }
            } else {
                for (call.arguments, 0..) |_, idx| {
                    param_types[idx] = llvm.LLVMInt64TypeInContext(ctx);
                }
            }

            const dynamic_fn_type = llvm.LLVMFunctionType(ret_type, if (param_types.len > 0) param_types.ptr else null, @intCast(param_types.len), 0);
            return llvm.LLVMBuildCall2(
                builder,
                dynamic_fn_type,
                callee_val,
                if (arg_vals.len > 0) arg_vals.ptr else null,
                @intCast(arg_vals.len),
                "dyn_calltmp",
            );
        },
        else => return error.UnsupportedExpressionNode,
    }
}

const std = @import("std");
const ast = @import("../../core/ast.zig");
const types_mapping = @import("types.zig");
const c_bindings = @import("c_bindings.zig");
const llvm = c_bindings.llvm;

pub fn emitExpression(
    ctx: llvm.LLVMContextRef,
    mod: llvm.LLVMModuleRef,
    builder: llvm.LLVMBuilderRef,
    scope: *std.StringHashMap(llvm.LLVMValueRef),
    node: *ast.ASTNode,
) !llvm.LLVMValueRef {
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
        .unary_expr => |un| {
            const operand_val = try emitExpression(ctx, mod, builder, scope, un.operand);
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
            const left_val = try emitExpression(ctx, mod, builder, scope, bin.left);
            const right_val = try emitExpression(ctx, mod, builder, scope, bin.right);

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
        .call_expr => |call| {
            var callee_name: []const u8 = "";
            if (call.callee.data == .identifier) {
                callee_name = call.callee.data.identifier.resolved_c_name orelse call.callee.data.identifier.name;
            } else {
                return error.DynamicCallNotSupportedYet;
            }

            const is_print_call = std.mem.eql(u8, callee_name, "print") or
                std.mem.startsWith(u8, callee_name, "System_print") or
                std.mem.startsWith(u8, callee_name, "io_print");

            if (is_print_call) {
                const printf_func = llvm.LLVMGetNamedFunction(mod, "printf") orelse return error.PrintfNotFound;
                const printf_type = llvm.LLVMGlobalGetValueType(printf_func);

                if (call.arguments.len > 0) {
                    const arg_val = try emitExpression(ctx, mod, builder, scope, call.arguments[0]);
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

            const func_val = llvm.LLVMGetNamedFunction(mod, callee_z.ptr) orelse {
                std.debug.print("LLVM Emitter Error: Function '{s}' not found in LLVM module.\n", .{callee_name});
                return error.FunctionNotFound;
            };

            var arg_vals = try std.heap.page_allocator.alloc(llvm.LLVMValueRef, call.arguments.len);
            defer std.heap.page_allocator.free(arg_vals);

            for (call.arguments, 0..) |arg_node, idx| {
                arg_vals[idx] = try emitExpression(ctx, mod, builder, scope, arg_node);
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
        },
        else => return error.UnsupportedExpressionNode,
    }
}

const std = @import("std");
const ast = @import("../../core/ast.zig");
const types_mapping = @import("types.zig");
const eiwa_types = @import("../../core/type_system.zig");
const expression = @import("expression.zig");
const core = @import("core.zig");
const c_bindings = @import("c_bindings.zig");
const llvm = c_bindings.llvm;

fn checkVtableMatch(ctx: llvm.LLVMContextRef, mod: llvm.LLVMModuleRef, builder: llvm.LLVMBuilderRef, ptr_type: llvm.LLVMTypeRef, exc_vtable: llvm.LLVMValueRef, tr_rt: eiwa_types.EiwaType) anyerror!llvm.LLVMValueRef {
    var is_m = llvm.LLVMConstInt(llvm.LLVMInt1TypeInContext(ctx), 0, 0);
    const base_rt = eiwa_types.extractBaseType(&tr_rt);
    if (types_mapping.isContractType(base_rt.*, expression.global_contracts_ast_ptr)) {
        return llvm.LLVMConstInt(llvm.LLVMInt1TypeInContext(ctx), 1, 0);
    }
    switch (base_rt.*) {
        .Custom => |n| {
            if (try expression.findVtableGlobal(ctx, mod, n, "Throwable")) |target_vt| {
                const vt_cast = llvm.LLVMBuildPointerCast(builder, target_vt, ptr_type, "target_vt_cast");
                const matches_type = llvm.LLVMBuildICmp(builder, llvm.LLVMIntEQ, exc_vtable, vt_cast, "matches_type");
                is_m = llvm.LLVMBuildOr(builder, is_m, matches_type, "is_m_or");
            }
        },
        .GenericInstance => |gi| {
            if (try expression.findVtableGlobal(ctx, mod, gi.base_name, "Throwable")) |target_vt| {
                const vt_cast = llvm.LLVMBuildPointerCast(builder, target_vt, ptr_type, "target_vt_cast");
                const matches_type = llvm.LLVMBuildICmp(builder, llvm.LLVMIntEQ, exc_vtable, vt_cast, "matches_type");
                is_m = llvm.LLVMBuildOr(builder, is_m, matches_type, "is_m_or");
            }
        },
        .Union => |u| {
            const sub_m1 = try checkVtableMatch(ctx, mod, builder, ptr_type, exc_vtable, u.left.*);
            const sub_m2 = try checkVtableMatch(ctx, mod, builder, ptr_type, exc_vtable, u.right.*);
            const sub_m = llvm.LLVMBuildOr(builder, sub_m1, sub_m2, "is_m_or_union");
            is_m = llvm.LLVMBuildOr(builder, is_m, sub_m, "is_m_or");
        },
        else => {
            is_m = llvm.LLVMConstInt(llvm.LLVMInt1TypeInContext(ctx), 1, 0);
        },
    }
    return is_m;
}

pub fn emitStatement(
    ctx: llvm.LLVMContextRef,
    mod: llvm.LLVMModuleRef,
    builder: llvm.LLVMBuilderRef,
    func_val: llvm.LLVMValueRef,
    scope: *std.StringHashMap(llvm.LLVMValueRef),
    structs: *std.StringHashMap(core.StructInfo),
    libs: *const std.StringHashMap(std.StringHashMap([]const u8)),
    node: *ast.ASTNode,
    declared_ret: ?*const eiwa_types.EiwaType,
) anyerror!void {
    switch (node.data) {
        .var_decl => |v| {
            const name = v.resolved_c_name orelse v.name;
            const res_type = node.resolved_type orelse return error.MissingTypeForVarDecl;

            // A `val`/`var` of type Void has no storage — its initializer is
            // evaluated purely for side effects (mirrors the C backend, which
            // emits `foo();` with no `result` variable). Reads of such a
            // variable (e.g. `result is Void`) are handled by the identifier /
            // `is` paths (constant VoidTypeKind checks).
            if (res_type.* == .Void) {
                if (v.initializer) |init_node| {
                    _ = try expression.emitExpression(ctx, mod, builder, scope, structs, libs, init_node);
                }
                // Still bind the name to a dummy so a later read of the
                // variable resolves instead of failing with VariableNotFound
                // (which would stub the whole function). The coroutine await
                // hoist produces `val __awaitN = <task>.result!!` for a Void
                // task (`Void? !!` -> Void); the binding is side-effect-only,
                // but the name must exist for the trailing reference.
                const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
                const name_z = try std.heap.page_allocator.dupeZ(u8, name);
                defer std.heap.page_allocator.free(name_z);
                const dummy = llvm.LLVMBuildAlloca(builder, ptr_type, name_z.ptr);
                _ = llvm.LLVMBuildStore(builder, llvm.LLVMConstNull(ptr_type), dummy);
                try scope.put(name, dummy);
                if (!std.mem.eql(u8, name, v.name)) {
                    try scope.put(v.name, dummy);
                }
                return;
            }

            const is_contract = types_mapping.isContractType(res_type.*, expression.global_contracts_ast_ptr);
            const llvm_type = if (is_contract) types_mapping.getFatPointerType(ctx) else types_mapping.getLLVMType(ctx, res_type.*);

            const name_z = try std.heap.page_allocator.dupeZ(u8, name);
            defer std.heap.page_allocator.free(name_z);

            if (v.is_boxed) {
                // Boxed var: allocate a heap cell via GC_malloc (or malloc) and
                // store the pointer in a stack alloca. The scope entry is alloca(ptr);
                // reads load ptr from alloca then load value from ptr;
                // writes load ptr from alloca then store value into ptr.
                const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
                const malloc_fn = core.getHeapAllocFn(mod);
                const malloc_type = llvm.LLVMGlobalGetValueType(malloc_fn);
                // Allocate dynamic cell size matching the exact LLVM type layout
                const cell_size = llvm.LLVMSizeOf(llvm_type);
                var malloc_args = [_]llvm.LLVMValueRef{cell_size};
                const box_ptr = llvm.LLVMBuildCall2(builder, malloc_type, malloc_fn, &malloc_args, 1, "box_ptr");

                if (v.initializer) |init_node| {
                    var init_val = try expression.emitExpression(ctx, mod, builder, scope, structs, libs, init_node);
                    init_val = expression.coerceArg(builder, init_val, llvm_type);
                    if (expression.storeValue(init_val, llvm_type)) |sv| {
                        _ = llvm.LLVMBuildStore(builder, sv, box_ptr);
                    }
                }

                // Stack alloca holds the box pointer
                const alloca_ptr = llvm.LLVMBuildAlloca(builder, ptr_type, name_z.ptr);
                _ = llvm.LLVMBuildStore(builder, box_ptr, alloca_ptr);
                try scope.put(name, alloca_ptr);
                if (!std.mem.eql(u8, name, v.name)) {
                    try scope.put(v.name, alloca_ptr);
                }
            } else {
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
                    val = expression.coerceArg(builder, val, llvm_type);
                    if (expression.storeValue(val, llvm_type)) |sv| {
                        _ = llvm.LLVMBuildStore(builder, sv, alloca_ptr);
                    }
                }
            }
        },
        .assignment => |assign| {
            // Class property assignment (implicit or explicit this.field = value)
            if (assign.is_class_property) {
                const this_ptr = scope.get("this") orelse return error.VariableNotFound;
                const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
                const this_val = llvm.LLVMBuildLoad2(builder, ptr_type, this_ptr, "this_val_assign");
                const cur_parent_fn = llvm.LLVMGetBasicBlockParent(llvm.LLVMGetInsertBlock(builder));
                const cur_fn_name_ptr = llvm.LLVMGetValueName(cur_parent_fn);
                const cur_fn_name = std.mem.span(cur_fn_name_ptr);

                var selected_struct: ?core.StructInfo = null;
                var selected_f_idx: usize = 0;

                var target_type_name: ?[]const u8 = assign.owner_type_c_name;
                if (target_type_name == null or structs.get(target_type_name.?) == null) {
                    if (std.mem.lastIndexOfScalar(u8, cur_fn_name, '_')) |idx| {
                        target_type_name = cur_fn_name[0..idx];
                    }
                }

                if (target_type_name) |t_name| {
                    if (structs.get(t_name)) |s_info| {
                        for (s_info.field_names, 0..) |f_name, f_idx| {
                            if (std.mem.eql(u8, f_name, assign.name)) {
                                selected_struct = s_info;
                                selected_f_idx = f_idx;
                                break;
                            }
                        }
                    }
                }

                if (selected_struct == null and target_type_name != null) {
                    const t_name = target_type_name.?;
                    const suffix = try std.fmt.allocPrint(std.heap.page_allocator, "_{s}", .{t_name});
                    defer std.heap.page_allocator.free(suffix);
                    const suffix_type = try std.fmt.allocPrint(std.heap.page_allocator, "_{s}_type", .{t_name});
                    defer std.heap.page_allocator.free(suffix_type);
                    const type_suffix = try std.fmt.allocPrint(std.heap.page_allocator, "{s}_type", .{t_name});
                    defer std.heap.page_allocator.free(type_suffix);
                    var it = structs.iterator();
                    while (it.next()) |entry| {
                        const k = entry.key_ptr.*;
                        if (std.mem.endsWith(u8, k, suffix) or std.mem.endsWith(u8, k, suffix_type) or std.mem.eql(u8, k, type_suffix) or std.mem.endsWith(u8, k, t_name) or std.mem.eql(u8, k, t_name)) {
                            const s_info = entry.value_ptr.*;
                            for (s_info.field_names, 0..) |f_name, f_idx| {
                                if (std.mem.eql(u8, f_name, assign.name)) {
                                    selected_struct = s_info;
                                    selected_f_idx = f_idx;
                                    break;
                                }
                            }
                            if (selected_struct != null) break;
                        }
                    }
                }

                if (selected_struct == null) {
                    var s_it = structs.iterator();
                    while (s_it.next()) |e| {
                        const s_name = e.key_ptr.*;
                        const s_info = e.value_ptr.*;
                        if (std.mem.startsWith(u8, cur_fn_name, s_name)) {
                            for (s_info.field_names, 0..) |f_name, f_idx| {
                                if (std.mem.eql(u8, f_name, assign.name)) {
                                    selected_struct = s_info;
                                    selected_f_idx = f_idx;
                                    break;
                                }
                            }
                            if (selected_struct != null) break;
                        }
                    }
                }


                if (selected_struct) |s_info| {
                    const val = try expression.emitExpression(ctx, mod, builder, scope, structs, libs, assign.value);
                    const field_ptr = llvm.LLVMBuildStructGEP2(
                        builder, s_info.struct_type, this_val, @intCast(selected_f_idx), "assign_field_ptr",
                    );
                    if (expression.storeValue(val, s_info.field_types[selected_f_idx])) |sv| {
                        _ = llvm.LLVMBuildStore(builder, sv, field_ptr);
                    }
                    return;
                }
                return error.PropertyNotFound;
            }

            const val = try expression.emitExpression(ctx, mod, builder, scope, structs, libs, assign.value);

            const alloca_ptr = scope.get(assign.name) orelse {
                if (core.verbose) std.debug.print("LLVM Emitter Error: Cannot assign to undeclared variable '{s}'.\n", .{assign.name});
                return error.VariableNotFound;
            };

            if (assign.is_boxed) {
                const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
                const box_ptr = llvm.LLVMBuildLoad2(builder, ptr_type, alloca_ptr, "box_ptr_load");
                const target_t = types_mapping.getFatPointerType(ctx);
                const box_val = expression.coerceArg(builder, val, target_t);
                if (expression.storeValue(box_val, target_t)) |sv| {
                    _ = llvm.LLVMBuildStore(builder, sv, box_ptr);
                }
            } else {
                const target_t = llvm.LLVMGetAllocatedType(alloca_ptr);
                const coerced_val = expression.coerceArg(builder, val, target_t);
                if (expression.storeValue(coerced_val, target_t)) |sv| {
                    _ = llvm.LLVMBuildStore(builder, sv, alloca_ptr);
                }
            }
        },
        .if_expr => |if_node| {
            var cond_val = try expression.emitExpression(ctx, mod, builder, scope, structs, libs, if_node.condition);
            const cond_type = llvm.LLVMTypeOf(cond_val);
            if (llvm.LLVMGetTypeKind(cond_type) == llvm.LLVMPointerTypeKind) {
                cond_val = llvm.LLVMBuildIsNotNull(builder, cond_val, "cond_ptr_bool");
            } else if (llvm.LLVMGetTypeKind(cond_type) == llvm.LLVMIntegerTypeKind and llvm.LLVMGetIntTypeWidth(cond_type) != 1) {
                cond_val = llvm.LLVMBuildICmp(builder, llvm.LLVMIntNE, cond_val, llvm.LLVMConstNull(cond_type), "cond_int_bool");
            }

            const then_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "if.then");
            const else_bb = if (if_node.else_branch != null) llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "if.else") else null;
            const merge_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "if.merge");

            _ = llvm.LLVMBuildCondBr(builder, cond_val, then_bb, else_bb orelse merge_bb);

            // Emit then branch
            llvm.LLVMPositionBuilderAtEnd(builder, then_bb);
            try emitStatement(ctx, mod, builder, func_val, scope, structs, libs, if_node.then_branch, declared_ret);
            if (llvm.LLVMGetBasicBlockTerminator(llvm.LLVMGetInsertBlock(builder)) == null) {
                _ = llvm.LLVMBuildBr(builder, merge_bb);
            }

            // Emit else branch if present
            if (if_node.else_branch) |else_branch| {
                if (else_bb) |eb| {
                    llvm.LLVMPositionBuilderAtEnd(builder, eb);
                    try emitStatement(ctx, mod, builder, func_val, scope, structs, libs, else_branch, declared_ret);
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
            var cond_val = try expression.emitExpression(ctx, mod, builder, scope, structs, libs, w.condition);
            const cond_type = llvm.LLVMTypeOf(cond_val);
            if (llvm.LLVMGetTypeKind(cond_type) == llvm.LLVMPointerTypeKind) {
                cond_val = llvm.LLVMBuildIsNotNull(builder, cond_val, "cond_ptr_bool");
            } else if (llvm.LLVMGetTypeKind(cond_type) == llvm.LLVMIntegerTypeKind and llvm.LLVMGetIntTypeWidth(cond_type) != 1) {
                cond_val = llvm.LLVMBuildICmp(builder, llvm.LLVMIntNE, cond_val, llvm.LLVMConstNull(cond_type), "cond_int_bool");
            }
            _ = llvm.LLVMBuildCondBr(builder, cond_val, body_bb, after_bb);

            // Body block
            llvm.LLVMPositionBuilderAtEnd(builder, body_bb);
            try emitStatement(ctx, mod, builder, func_val, scope, structs, libs, w.body, declared_ret);
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
            // transpiler iterated EiwaArray struct fields (data/length).
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
            // Load the element using the array's element stride/type (mirrors the
            // index path): contract elements are 16-byte fat pointers {data,
            // vtable}, so loading them as i64 slots would truncate the vtable.
            const elem_type = expression.arrayElemLLVMType(ctx, f.iterable.resolved_type);
            const elem_stride = expression.arrayElemStride(ctx, elem_type);
            const for_elem_name = try std.heap.page_allocator.dupeZ(u8, "for_elem_ptr");
            defer std.heap.page_allocator.free(for_elem_name);
            const elem_ptr = expression.arrayElemTypedPtr(builder, ctx, arr_val, i_body, elem_type, elem_stride, for_elem_name.ptr);
            var item_val = llvm.LLVMBuildLoad2(builder, elem_type, elem_ptr, "for_item");
            // Only when the element type fell back to an i64 slot (arrayElemLLVMType
            // could not resolve it): reconstruct ref/double values the old way.
            if (llvm.LLVMGetTypeKind(elem_type) == llvm.LLVMIntegerTypeKind and arr_rt == .Array) {
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
            if (f.index_name) |idx_name| {
                const idx_name_z = try std.heap.page_allocator.dupeZ(u8, idx_name);
                defer std.heap.page_allocator.free(idx_name_z);
                const idx_alloca = llvm.LLVMBuildAlloca(builder, i64_type, idx_name_z.ptr);
                _ = llvm.LLVMBuildStore(builder, i_body, idx_alloca);
                try loop_scope.put(idx_name, idx_alloca);
            }

            const item_type = llvm.LLVMTypeOf(item_val);
            const item_name_z = try std.heap.page_allocator.dupeZ(u8, f.item_name);
            defer std.heap.page_allocator.free(item_name_z);
            const item_alloca = llvm.LLVMBuildAlloca(builder, item_type, item_name_z.ptr);
            _ = llvm.LLVMBuildStore(builder, item_val, item_alloca);
            try loop_scope.put(f.item_name, item_alloca);

            try emitStatement(ctx, mod, builder, func_val, &loop_scope, structs, libs, f.body, declared_ret);

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
                    // The target contract is the function's declared return
                    // type (deterministic vtable lookup); an empty name would
                    // make findVtableGlobal scan every vtable and attach a
                    // random one (e.g. `return this` in start(): Awaitable<T>
                    // picked `collections_MutableList_Int_Serializable_vtable`
                    // because the short-name derivation ended in `Int`).
                    var contract_c_name: []const u8 = "";
                    if (declared_ret) |drt| {
                        contract_c_name = switch (eiwa_types.extractBaseType(drt).*) {
                            .Custom => |n| n,
                            .GenericInstance => |gi| gi.base_name,
                            else => "",
                        };
                    }
                    if (val_node.resolved_type) |val_rt| {
                        const val_c_name = switch (eiwa_types.extractBaseType(val_rt).*) {
                            .Custom => |n| n,
                            .GenericInstance => |gi| gi.base_name,
                            else => "",
                        };
                        if (val_c_name.len > 0) {
                            ret_val = expression.coerceToContract(ctx, mod, builder, ret_val, val_c_name, contract_c_name) catch ret_val;
                        }
                    }
                }
                // Coerce the return value to the function's declared return
                // type (e.g. a nullable primitive `Int?` is `ptr` while
                // `curr!!.value` is a raw `i64`), mirroring argument coercion.
                if (llvm.LLVMGetTypeKind(expected_ret_type) == llvm.LLVMVoidTypeKind) {
                    _ = llvm.LLVMBuildRetVoid(builder);
                } else {
                    if (llvm.LLVMTypeOf(ret_val) != expected_ret_type) {
                        ret_val = expression.coerceArg(builder, ret_val, expected_ret_type);
                    }
                    _ = llvm.LLVMBuildRet(builder, ret_val);
                }
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
            const fat_type = types_mapping.getFatPointerType(ctx);
            var fat_exc = exc_val;
            if (llvm.LLVMTypeOf(exc_val) != fat_type) {
                var conc_c: []const u8 = "";
                if (th.expr.resolved_type) |rt| {
                    conc_c = switch (rt.*) {
                        .Custom => |n| n,
                        .GenericInstance => |gi| gi.base_name,
                        else => "",
                    };
                }
                fat_exc = expression.coerceToContract(ctx, mod, builder, exc_val, conc_c, "Throwable") catch blk: {
                    var f = llvm.LLVMConstNull(fat_type);
                    f = llvm.LLVMBuildInsertValue(builder, f, exc_val, 0, "fat_data");
                    break :blk f;
                };
            }
            _ = llvm.LLVMBuildStore(builder, fat_exc, active_global);

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
                const longjmp_func = (core.findLongjmp(mod) orelse return error.ExceptionRuntimeMissing);
                const lj_type = llvm.LLVMGlobalGetValueType(longjmp_func);
                const one_i32 = llvm.LLVMConstInt(i32_type, 1, 0);
                var lj_args = [_]llvm.LLVMValueRef{ buf_ptr, one_i32 };
                _ = llvm.LLVMBuildCall2(builder, lj_type, longjmp_func, &lj_args, 2, "");
                _ = llvm.LLVMBuildUnreachable(builder);
            }

            llvm.LLVMPositionBuilderAtEnd(builder, unhandled_bb);
            {
                // Report before exiting: an unhandled Eiwa exception is a silent
                // exit(1) otherwise, which makes debugging impossible.
                if (llvm.LLVMGetNamedFunction(mod, "puts")) |puts_fn| {
                    const puts_ft = llvm.LLVMGlobalGetValueType(puts_fn);
                    const msg_ptr = llvm.LLVMBuildGlobalStringPtr(builder, "Error: unhandled exception (no matching handler)", "unhandled_msg");
                    var puts_args = [_]llvm.LLVMValueRef{msg_ptr};
                    _ = llvm.LLVMBuildCall2(builder, puts_ft, puts_fn, &puts_args, 1, "");
                }
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
            const setjmp_func = (core.findSetjmp(mod) orelse return error.ExceptionRuntimeMissing);
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
            try emitStatement(ctx, mod, builder, func_val, scope, structs, libs, ts.body, declared_ret);
            if (llvm.LLVMGetBasicBlockTerminator(llvm.LLVMGetInsertBlock(builder)) == null) {
                const stack2 = llvm.LLVMBuildLoad2(builder, ptr_type, stack_global, "stack2");
                const next_gep2 = llvm.LLVMBuildStructGEP2(builder, frame_type, stack2, 1, "next2");
                const next_val2 = llvm.LLVMBuildLoad2(builder, ptr_type, next_gep2, "next_val2");
                _ = llvm.LLVMBuildStore(builder, next_val2, stack_global);
                _ = llvm.LLVMBuildBr(builder, after_bb);
            }

            llvm.LLVMPositionBuilderAtEnd(builder, catch_bb);
            {
                const stack3 = llvm.LLVMBuildLoad2(builder, ptr_type, stack_global, "stack3");
                const next_gep3 = llvm.LLVMBuildStructGEP2(builder, frame_type, stack3, 1, "next3");
                const next_val3 = llvm.LLVMBuildLoad2(builder, ptr_type, next_gep3, "next_val3");
                _ = llvm.LLVMBuildStore(builder, next_val3, stack_global);
            }
            const fat_type = types_mapping.getFatPointerType(ctx);
            const exc_val = llvm.LLVMBuildLoad2(builder, fat_type, active_global, "exc");
            _ = llvm.LLVMBuildStore(builder, llvm.LLVMConstNull(fat_type), active_global);

            if (ts.catches.len > 0) {
                const rethrow_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "catch.rethrow");
                var cur_check_bb = catch_bb;

                for (ts.catches, 0..) |c, idx| {
                    llvm.LLVMPositionBuilderAtEnd(builder, cur_check_bb);

                    const catch_body_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "catch.body");
                    const is_last_catch = (idx + 1 == ts.catches.len);
                    const next_check_bb = if (!is_last_catch)
                        llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "catch.check")
                    else
                        rethrow_bb;

                    if (c.types.len > 0) {
                        const exc_vtable = llvm.LLVMBuildExtractValue(builder, exc_val, 1, "exc_vtable");
                        var is_matched = llvm.LLVMConstInt(llvm.LLVMInt1TypeInContext(ctx), 0, 0);
                        for (c.types) |tr| {
                            if (tr.resolved_type) |rt| {
                                const sub_m = try checkVtableMatch(ctx, mod, builder, ptr_type, exc_vtable, rt.*);
                                is_matched = llvm.LLVMBuildOr(builder, is_matched, sub_m, "is_matched_or");
                            } else {
                                if (try expression.findVtableGlobal(ctx, mod, tr.name, "Throwable")) |target_vt| {
                                    const vt_cast = llvm.LLVMBuildPointerCast(builder, target_vt, ptr_type, "target_vt_cast");
                                    const matches_type = llvm.LLVMBuildICmp(builder, llvm.LLVMIntEQ, exc_vtable, vt_cast, "matches_type");
                                    is_matched = llvm.LLVMBuildOr(builder, is_matched, matches_type, "is_matched_or");
                                } else {
                                    is_matched = llvm.LLVMConstInt(llvm.LLVMInt1TypeInContext(ctx), 1, 0);
                                }
                            }
                        }
                        _ = llvm.LLVMBuildCondBr(builder, is_matched, catch_body_bb, next_check_bb);
                    } else {
                        _ = llvm.LLVMBuildBr(builder, catch_body_bb);
                    }

                    // --- Catch Body ---
                    llvm.LLVMPositionBuilderAtEnd(builder, catch_body_bb);
                    if (c.var_name) |var_name| {
                        const v_z = try std.heap.page_allocator.dupeZ(u8, var_name);
                        defer std.heap.page_allocator.free(v_z);

                        const var_alloca = llvm.LLVMBuildAlloca(builder, fat_type, v_z.ptr);
                        _ = llvm.LLVMBuildStore(builder, exc_val, var_alloca);
                        try scope.put(var_name, var_alloca);
                    }
                    try emitStatement(ctx, mod, builder, func_val, scope, structs, libs, c.body, declared_ret);
                    if (llvm.LLVMGetBasicBlockTerminator(llvm.LLVMGetInsertBlock(builder)) == null) {
                        _ = llvm.LLVMBuildBr(builder, after_bb);
                    }

                    cur_check_bb = next_check_bb;
                }

                // --- Rethrow Block ---
                llvm.LLVMPositionBuilderAtEnd(builder, rethrow_bb);
                _ = llvm.LLVMBuildStore(builder, exc_val, active_global);
                const cur_stack2 = llvm.LLVMBuildLoad2(builder, ptr_type, stack_global, "cur_stack2");
                const null_ptr2 = llvm.LLVMConstNull(ptr_type);
                const has_handler2 = llvm.LLVMBuildICmp(builder, llvm.LLVMIntNE, cur_stack2, null_ptr2, "has_handler2");

                const rethrow_do_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "rethrow.do");
                const rethrow_unhandled_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "rethrow.unhandled");
                _ = llvm.LLVMBuildCondBr(builder, has_handler2, rethrow_do_bb, rethrow_unhandled_bb);

                llvm.LLVMPositionBuilderAtEnd(builder, rethrow_do_bb);
                {
                    const buf_gep2 = llvm.LLVMBuildStructGEP2(builder, frame_type, cur_stack2, 0, "stack_buf2");
                    const buf_ptr2 = llvm.LLVMBuildBitCast(builder, buf_gep2, ptr_type, "sbuf2");
                    const longjmp_func2 = (core.findLongjmp(mod) orelse return error.ExceptionRuntimeMissing);
                    const lj_type2 = llvm.LLVMGlobalGetValueType(longjmp_func2);
                    const one_i322 = llvm.LLVMConstInt(i32_type, 1, 0);
                    var lj_args2 = [_]llvm.LLVMValueRef{ buf_ptr2, one_i322 };
                    _ = llvm.LLVMBuildCall2(builder, lj_type2, longjmp_func2, &lj_args2, 2, "");
                    _ = llvm.LLVMBuildUnreachable(builder);
                }

                llvm.LLVMPositionBuilderAtEnd(builder, rethrow_unhandled_bb);
                {
                    if (llvm.LLVMGetNamedFunction(mod, "puts")) |puts_fn| {
                        const puts_ft2 = llvm.LLVMGlobalGetValueType(puts_fn);
                        const msg_ptr2 = llvm.LLVMBuildGlobalStringPtr(builder, "Error: unhandled exception (no matching handler)", "unhandled_msg2");
                        var puts_args2 = [_]llvm.LLVMValueRef{msg_ptr2};
                        _ = llvm.LLVMBuildCall2(builder, puts_ft2, puts_fn, &puts_args2, 1, "");
                    }
                    const exit_func2 = llvm.LLVMGetNamedFunction(mod, "exit") orelse return error.ExceptionRuntimeMissing;
                    const exit_type2 = llvm.LLVMGlobalGetValueType(exit_func2);
                    const one_i322 = llvm.LLVMConstInt(i32_type, 1, 0);
                    var exit_args2 = [_]llvm.LLVMValueRef{one_i322};
                    _ = llvm.LLVMBuildCall2(builder, exit_type2, exit_func2, &exit_args2, 1, "");
                    _ = llvm.LLVMBuildUnreachable(builder);
                }
            } else {
                llvm.LLVMPositionBuilderAtEnd(builder, catch_bb);
                _ = llvm.LLVMBuildStore(builder, llvm.LLVMConstNull(fat_type), active_global);
                _ = llvm.LLVMBuildBr(builder, after_bb);
            }

            llvm.LLVMPositionBuilderAtEnd(builder, after_bb);
        },
        .block => |blk| {
            for (blk.statements) |stmt| {
                try emitStatement(ctx, mod, builder, func_val, scope, structs, libs, stmt, declared_ret);
            }
        },
        .program => |prog| {
            for (prog.statements) |stmt| {
                try emitStatement(ctx, mod, builder, func_val, scope, structs, libs, stmt, declared_ret);
            }
        },
        .fun_decl, .import_stmt, .test_decl, .type_decl, .contract_decl, .skill_decl, .object_decl, .enum_decl, .lib_decl => {},
        else => {
            _ = try expression.emitExpression(ctx, mod, builder, scope, structs, libs, node);
        },
    }
}

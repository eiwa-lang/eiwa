const std = @import("std");
const ast = @import("../../core/ast.zig");
const ts = @import("../../core/type_system.zig");
const compat = @import("../../core/compat.zig");
const types_mapping = @import("types.zig");
const statement = @import("statement.zig");
const core = @import("core.zig");
const c_bindings = @import("c_bindings.zig");
const llvm = c_bindings.llvm;

pub fn emitExpression(
    ctx: llvm.LLVMContextRef,
    mod: llvm.LLVMModuleRef,
    builder: llvm.LLVMBuilderRef,
    scope: *std.StringHashMap(llvm.LLVMValueRef),
    structs: *std.StringHashMap(core.StructInfo),
    libs: *const std.StringHashMap(std.StringHashMap([]const u8)),
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
        .null_literal => {
            const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
            return llvm.LLVMConstNull(ptr_type);
        },
        .string_literal => |str| {
            const str_z = try std.heap.page_allocator.dupeZ(u8, str);
            defer std.heap.page_allocator.free(str_z);
            return llvm.LLVMBuildGlobalStringPtr(builder, str_z.ptr, "str_tmp");
        },
        .identifier => |ident| {
            const name = ident.resolved_c_name orelse ident.name;
            // TODO(emitter): This "is this a class property?" test relies on a
            // heuristic fallback: `scope.get(name) == null` with `this` in scope
            // is taken to mean `name` is a receiver field. That masks a gap in
            // the type checker (src/core/type_checker/) which sometimes fails to
            // flag identifiers as `is_class_property`. The heuristic is order-
            // sensitive (a shadowed local with the same name as a field would
            // mis-resolve) and scans *every* struct's layout to find the field.
            // Proper fix: make the type checker set `is_class_property` reliably,
            // then delete the `scope.get(name) == null` fallback below.
            // LLVM-SPECIFIC (NOT inherited from C): the C transpiler resolves
            // field access through the type checker's is_class_property flag and
            // emits `this->field` directly; it never guesses from scope. This
            // fallback exists only because the LLVM path hits identifiers the C
            // path doesn't (emitted bodies bypass the C field codegen). Fix the
            // type checker and delete the heuristic — no C-side change needed.
            const is_prop = ident.is_class_property or
                (scope.get("this") != null and scope.get(name) == null);
            if (is_prop) {
                const this_ptr = scope.get("this") orelse {
                    std.debug.print("LLVM Emitter Error: Class property '{s}' requires 'this' in scope.\n", .{name});
                    return error.VariableNotFound;
                };
                const this_val = llvm.LLVMBuildLoad2(builder, llvm.LLVMTypeOf(this_ptr), this_ptr, "this_val");
                var it = structs.iterator();
                while (it.next()) |entry| {
                    const s_info = entry.value_ptr.*;
                    if (llvm.LLVMTypeOf(this_val) != s_info.struct_type and llvm.LLVMTypeOf(this_val) != llvm.LLVMPointerType(s_info.struct_type, 0)) {
                        continue;
                    }
                    for (s_info.field_names, 0..) |f_name, f_idx| {
                        if (std.mem.eql(u8, f_name, name)) {
                            const field_name_z = try std.heap.page_allocator.dupeZ(u8, f_name);
                            defer std.heap.page_allocator.free(field_name_z);
                            const field_ptr = llvm.LLVMBuildStructGEP2(builder, s_info.struct_type, this_val, @intCast(f_idx), field_name_z.ptr);
                            return llvm.LLVMBuildLoad2(builder, s_info.field_types[f_idx], field_ptr, "prop_val");
                        }
                    }
                }
                std.debug.print("LLVM Emitter Error: Class property '{s}' not found in struct layout.\n", .{name});
                return error.PropertyNotFound;
            }
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
            // In the LLVM emitter a String value IS a char pointer, so `.ptr`
            // (and `.length`-free access) resolves to the string value itself.
            if (get.object.resolved_type) |obj_rt| {
                const base = obj_rt.*;
                if ((base == .String or base == .Pointer) and std.mem.eql(u8, get.name, "ptr")) {
                    return emitExpression(ctx, mod, builder, scope, structs, libs, get.object);
                }
            }

            // NativeArray builtins: `.length` loads slot 0 of the raw buffer
            // layout (slot 0 = size, slot 1 = capacity, slots 2.. = elements),
            // matching the array_literal emission below.
            // TODO(emitter): SPECIAL CASE — review before promoting LLVM to
            // default backend. `push`/`get`/`set`/`length` on .Array are
            // inlined here instead of emitting shared EiwaArray_* helpers like
            // the C transpiler does (src/backend/c_transpiler/core.zig:290).
            // LLVM-SPECIFIC (NOT inherited from C): the C backend generates one
            // EiwaArray struct + push/set functions per element type; the LLVM
            // emitter uses an untyped i64 buffer and inlines the operations.
            if (get.object.resolved_type) |obj_rt| {
                if (obj_rt.* == .Array and std.mem.eql(u8, get.name, "length")) {
                    const arr_ptr = try emitExpression(ctx, mod, builder, scope, structs, libs, get.object);
                    const i64_type = llvm.LLVMInt64TypeInContext(ctx);
                    var idx0 = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, 0, 0)};
                    const size_ptr = llvm.LLVMBuildGEP2(builder, i64_type, arr_ptr, &idx0, 1, "arr_len_ptr");
                    return llvm.LLVMBuildLoad2(builder, i64_type, size_ptr, "arr_len");
                }
            }

            // Contract method dispatch: `value.toString()` where the static type
            // is a contract (e.g. `Stringable`). In the LLVM model the object is
            // a raw boxed value, so call the eiwa_to_string runtime helper.
            // TODO(emitter): The "Stringable-ness" test below is duplicated with
            // the one in the call_expr `.toString()` dispatch further down, and
            // both are stringly-typed (`"Stringable"`/`"core_Stringable"` name
            // matches) plus a hardcoded primitive list. It mirrors the C
            // transpiler's eiwa_to_string fallback, but the duplication risks
            // drift. Proper fix: centralize an `isStringable(resolved_type)`
            // helper (single source of truth) and prefer a resolved-type flag
            // from the type checker over name matching.
            // INHERITED GAMBIARRA: the name-based toString + eiwa_to_string
            // fallback came from the C backend — see PRE-EXISTING comment in
            // src/backend/c_transpiler/expression.zig (get_expr toString).
            if (std.mem.eql(u8, get.name, "toString")) {
                if (get.object.resolved_type) |obj_rt| {
                    const obj_base = obj_rt.*;
                    const is_stringable = switch (obj_base) {
                        .Int, .Bool, .Double, .String, .Union => true,
                        .Custom => |n| std.mem.eql(u8, n, "Stringable") or std.mem.eql(u8, n, "core_Stringable"),
                        .Pointer => |p| p.* == .Custom and (std.mem.eql(u8, p.Custom, "Stringable") or std.mem.eql(u8, p.Custom, "core_Stringable")),
                        else => false,
                    };
                    if (is_stringable) {
                        const obj_val = try emitExpression(ctx, mod, builder, scope, structs, libs, get.object);
                        const fn_val = llvm.LLVMGetNamedFunction(mod, "eiwa_to_string") orelse return error.ToStringHelperNotFound;
                        const fn_type = llvm.LLVMGlobalGetValueType(fn_val);
                        // eiwa_to_string takes a ptr (boxed value). Int/Bool are
                        // raw i64 in the LLVM model, so box them via inttoptr.
                        var arg_val = obj_val;
                        if (obj_base == .Int or obj_base == .Bool or obj_base == .Double) {
                            const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
                            arg_val = llvm.LLVMBuildIntToPtr(builder, obj_val, ptr_type, "tostr_box");
                        }
                        var args = [_]llvm.LLVMValueRef{arg_val};
                        return llvm.LLVMBuildCall2(builder, fn_type, fn_val, &args, 1, "tostr_tmp");
                    }
                }
            }

            // Primitive/String hashCode() — the String type's body relies on
            // `this.length`/`this.ptr` struct fields the LLVM model doesn't
            // materialize, so use the eiwa_hash_string helper instead. Int's
            // hashCode is the value itself.
            // TODO(emitter): SPECIAL CASE — review before promoting LLVM to
            // default backend. This bypasses method dispatch entirely: Int/Bool
            // return the raw value, Double bitcasts to i64, String/Pointer call
            // eiwa_hash_string. If `hashCode` is ever overridden on a contract
            // or redefined in std, this special case will silently shadow the
            // real implementation. LLVM-SPECIFIC (NOT inherited from C): the C
            // transpiler resolves hashCode through normal std method emission.
            if (std.mem.eql(u8, get.name, "hashCode")) {
                if (get.object.resolved_type) |obj_rt| {
                    const obj_base = obj_rt.*;
                    if (obj_base == .String or obj_base == .Pointer) {
                        const obj_val = try emitExpression(ctx, mod, builder, scope, structs, libs, get.object);
                        const fn_val = llvm.LLVMGetNamedFunction(mod, "eiwa_hash_string") orelse return error.HashStringHelperNotFound;
                        const fn_type = llvm.LLVMGlobalGetValueType(fn_val);
                        var args = [_]llvm.LLVMValueRef{obj_val};
                        return llvm.LLVMBuildCall2(builder, fn_type, fn_val, &args, 1, "hash_tmp");
                    }
                    if (obj_base == .Int or obj_base == .Bool) {
                        return try emitExpression(ctx, mod, builder, scope, structs, libs, get.object);
                    }
                    if (obj_base == .Double) {
                        const obj_val = try emitExpression(ctx, mod, builder, scope, structs, libs, get.object);
                        return llvm.LLVMBuildBitCast(builder, obj_val, llvm.LLVMInt64TypeInContext(ctx), "hash_double");
                    }
                }
            }

            // Object static variable access: `Env.isLoaded` -> global `env_Env_isLoaded`.
            if (get.object.data == .identifier) {
                const obj_c_name = get.object.data.identifier.resolved_c_name orelse get.object.data.identifier.name;
                const global_name = try std.fmt.allocPrint(std.heap.page_allocator, "{s}_{s}\x00", .{ obj_c_name, get.name });
                defer std.heap.page_allocator.free(global_name);
                if (llvm.LLVMGetNamedGlobal(mod, global_name.ptr)) |g| {
                    const g_type = llvm.LLVMTypeOf(g);
                    const elem_type = llvm.LLVMGetElementType(g_type);
                    const init = llvm.LLVMGetInitializer(g);
                    const actual_elem_type = if (init != null) llvm.LLVMTypeOf(init) else elem_type;
                    const val = llvm.LLVMBuildLoad2(builder, actual_elem_type, g, "obj_var_load");
                    return val;
                }
            }

            const obj_val = try emitExpression(ctx, mod, builder, scope, structs, libs, get.object);
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
            {
                const rt = get.object.resolved_type;
                std.debug.print("[llvm-dbg] get_expr '.{s}' on object kind={s} resolved_type={?}\n", .{ get.name, @tagName(get.object.data), rt });
            }
            return error.PropertyNotFound;
        },
        .set_expr => |set| {
            // Object static variable assignment: `Env.isLoaded = true` -> global `env_Env_isLoaded`.
            if (set.object.data == .identifier) {
                const obj_c_name = set.object.data.identifier.resolved_c_name orelse set.object.data.identifier.name;
                const global_name = try std.fmt.allocPrint(std.heap.page_allocator, "{s}_{s}\x00", .{ obj_c_name, set.name });
                defer std.heap.page_allocator.free(global_name);
                if (llvm.LLVMGetNamedGlobal(mod, global_name.ptr)) |g| {
                    const val = try emitExpression(ctx, mod, builder, scope, structs, libs, set.value);
                    _ = llvm.LLVMBuildStore(builder, val, g);
                    return val;
                }
            }

            const obj_val = try emitExpression(ctx, mod, builder, scope, structs, libs, set.object);
            const val = try emitExpression(ctx, mod, builder, scope, structs, libs, set.value);

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

            // TODO(emitter): malloc-first ordering is the libgc-linking
            // workaround — see the note in core.zig emitTypeConstructor.
            // The array is laid out as a raw i64 buffer (header + elements),
            // matching the C transpiler's EiwaArray model.
            // LLVM-SPECIFIC (NOT inherited from C): the C transpiler emits
            // GC_MALLOC because its generated code links libgc via
            // eiwa_runtime.h. This fallback exists only because the `eiwa` host
            // binary doesn't link libgc; the C backend has no such workaround.
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
                const elem_val = try emitExpression(ctx, mod, builder, scope, structs, libs, elem_node);
                const offset_val = llvm.LLVMConstInt(i64_type, @bitCast(@as(i64, @intCast(idx + 2))), 0);
                var elem_idx = [_]llvm.LLVMValueRef{offset_val};
                const elem_ptr = llvm.LLVMBuildGEP2(builder, i64_type, arr_ptr, &elem_idx, 1, "elem_ptr");
                _ = llvm.LLVMBuildStore(builder, elem_val, elem_ptr);
            }

            // The type checker types array literals as the monomorphized
            // `List<T>` struct (`type List<T>(val items: NativeArray<T>)`),
            // and downstream code (for-in desugar, index access, methods)
            // reads the `.items` field. Wrap the raw buffer in the struct so
            // the value matches its resolved type.
            if (node.resolved_type) |rt| {
                if (rt.* == .Custom) {
                    if (structs.get(rt.Custom)) |s_info| {
                        for (s_info.field_names, 0..) |f_name, f_idx| {
                            if (std.mem.eql(u8, f_name, "items")) {
                                const malloc_fn2 = llvm.LLVMGetNamedFunction(mod, "malloc") orelse break;
                                const malloc_type2 = llvm.LLVMGlobalGetValueType(malloc_fn2);
                                var size_args = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, 128, 0)};
                                const struct_ptr = llvm.LLVMBuildCall2(builder, malloc_type2, malloc_fn2, &size_args, 1, "list_alloc");
                                const field_name_z = try std.heap.page_allocator.dupeZ(u8, f_name);
                                defer std.heap.page_allocator.free(field_name_z);
                                const items_ptr = llvm.LLVMBuildStructGEP2(builder, s_info.struct_type, struct_ptr, @intCast(f_idx), field_name_z.ptr);
                                _ = llvm.LLVMBuildStore(builder, arr_ptr, items_ptr);
                                return struct_ptr;
                            }
                        }
                    }
                }
            }

            return arr_ptr;
        },
        .index_expr => |idx_expr| {
            const arr_ptr = try emitExpression(ctx, mod, builder, scope, structs, libs, idx_expr.object);
            const i_val = try emitExpression(ctx, mod, builder, scope, structs, libs, idx_expr.index);

            const i64_type = llvm.LLVMInt64TypeInContext(ctx);
            const offset_val = llvm.LLVMBuildAdd(builder, i_val, llvm.LLVMConstInt(i64_type, 2, 0), "offset");
            var elem_idx = [_]llvm.LLVMValueRef{offset_val};
            const elem_ptr = llvm.LLVMBuildGEP2(builder, i64_type, arr_ptr, &elem_idx, 1, "arr_idx_gep");
            // Load with the element's real type (slots are 8 bytes either
            // way) so pointer/Double elements don't produce type-mismatched
            // values in typed contexts (e.g. `ret ptr`).
            const elem_type = arrayElemLLVMType(ctx, idx_expr.object.resolved_type);
            return llvm.LLVMBuildLoad2(builder, elem_type, elem_ptr, "arr_elem_val");
        },
        .index_set_expr => |set_idx| {
            const arr_ptr = try emitExpression(ctx, mod, builder, scope, structs, libs, set_idx.object);
            const i_val = try emitExpression(ctx, mod, builder, scope, structs, libs, set_idx.index);
            const val = try emitExpression(ctx, mod, builder, scope, structs, libs, set_idx.value);

            const i64_type = llvm.LLVMInt64TypeInContext(ctx);
            const offset_val = llvm.LLVMBuildAdd(builder, i_val, llvm.LLVMConstInt(i64_type, 2, 0), "offset");
            var elem_idx = [_]llvm.LLVMValueRef{offset_val};
            const elem_ptr = llvm.LLVMBuildGEP2(builder, i64_type, arr_ptr, &elem_idx, 1, "arr_set_gep");
            _ = llvm.LLVMBuildStore(builder, val, elem_ptr);
            return val;
        },
        .unary_expr => |un| {
            const operand_val = try emitExpression(ctx, mod, builder, scope, structs, libs, un.operand);
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
                .bang_bang => {
                    const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
                    const not_null = llvm.LLVMBuildICmp(builder, llvm.LLVMIntNE, operand_val, llvm.LLVMConstNull(ptr_type), "notnull_tmp");
                    return llvm.LLVMBuildSelect(builder, not_null, operand_val, llvm.LLVMConstNull(ptr_type), "notnull_sel");
                },
                else => return error.UnsupportedUnaryOperator,
            }
        },
        .binary_expr => |bin| {
            const left_val = try emitExpression(ctx, mod, builder, scope, structs, libs, bin.left);
            const right_val = try emitExpression(ctx, mod, builder, scope, structs, libs, bin.right);

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
                    // String `==` compares contents (C backend: core_String_equals).
                    // TODO(emitter): SPECIAL CASE — review in Phase 61; proper
                    // fix is dispatch through the Equatable contract vtable.
                    if (isStringOperand(bin.left) or isStringOperand(bin.right)) {
                        const strcmp_fn = llvm.LLVMGetNamedFunction(mod, "strcmp") orelse blk: {
                            const p = llvm.LLVMPointerTypeInContext(ctx, 0);
                            var ps = [_]llvm.LLVMTypeRef{ p, p };
                            const ft = llvm.LLVMFunctionType(llvm.LLVMInt32TypeInContext(ctx), &ps, 2, 0);
                            break :blk llvm.LLVMAddFunction(mod, "strcmp", ft);
                        };
                        const ft = llvm.LLVMGlobalGetValueType(strcmp_fn);
                        var args = [_]llvm.LLVMValueRef{ left_val, right_val };
                        const cmp = llvm.LLVMBuildCall2(builder, ft, strcmp_fn, &args, 2, "strcmp_tmp");
                        const zero = llvm.LLVMConstInt(llvm.LLVMTypeOf(cmp), 0, 0);
                        return llvm.LLVMBuildICmp(builder, llvm.LLVMIntEQ, cmp, zero, "streq_tmp");
                    }
                    return llvm.LLVMBuildICmp(builder, llvm.LLVMIntEQ, left_val, right_val, "eqtmp");
                },
                .bang_eq => {
                    if (is_double) return llvm.LLVMBuildFCmp(builder, llvm.LLVMRealUNE, left_val, right_val, "fnetmp");
                    if (isStringOperand(bin.left) or isStringOperand(bin.right)) {
                        const strcmp_fn = llvm.LLVMGetNamedFunction(mod, "strcmp") orelse blk: {
                            const p = llvm.LLVMPointerTypeInContext(ctx, 0);
                            var ps = [_]llvm.LLVMTypeRef{ p, p };
                            const ft = llvm.LLVMFunctionType(llvm.LLVMInt32TypeInContext(ctx), &ps, 2, 0);
                            break :blk llvm.LLVMAddFunction(mod, "strcmp", ft);
                        };
                        const ft = llvm.LLVMGlobalGetValueType(strcmp_fn);
                        var args = [_]llvm.LLVMValueRef{ left_val, right_val };
                        const cmp = llvm.LLVMBuildCall2(builder, ft, strcmp_fn, &args, 2, "strcmp_tmp");
                        const zero = llvm.LLVMConstInt(llvm.LLVMTypeOf(cmp), 0, 0);
                        return llvm.LLVMBuildICmp(builder, llvm.LLVMIntNE, cmp, zero, "strne_tmp");
                    }
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

            for (lam.body) |stmt| {
                try statement.emitStatement(ctx, mod, builder, func_val, &lam_scope, structs, libs, stmt);
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

                const callee_z = try std.heap.page_allocator.dupeZ(u8, callee_name);
                defer std.heap.page_allocator.free(callee_z);

                // String constructor: in the LLVM model a String IS a char
                // pointer, so `String(buf, len)` returns the buffer pointer.
                if (std.mem.eql(u8, callee_name, "core_String") or std.mem.eql(u8, callee_name, "String")) {
                    if (call.arguments.len > 0) {
                        return emitExpression(ctx, mod, builder, scope, structs, libs, call.arguments[0]);
                    }
                }

                if (llvm.LLVMGetNamedFunction(mod, callee_z.ptr)) |func_val| {
                    var arg_vals = try std.heap.page_allocator.alloc(llvm.LLVMValueRef, call.arguments.len);
                    defer std.heap.page_allocator.free(arg_vals);

                    const func_type = llvm.LLVMGlobalGetValueType(func_val);
                    const param_count = llvm.LLVMCountParamTypes(func_type);
                    const func_param_types = try std.heap.page_allocator.alloc(llvm.LLVMTypeRef, param_count);
                    defer std.heap.page_allocator.free(func_param_types);
                    llvm.LLVMGetParamTypes(func_type, func_param_types.ptr);

                    for (call.arguments, 0..) |arg_node, idx| {
                        var arg_val = try emitExpression(ctx, mod, builder, scope, structs, libs, arg_node);
                        if (idx < param_count) {
                            arg_val = coerceArg(builder, arg_val, func_param_types[idx]);
                        }
                        arg_vals[idx] = arg_val;
                    }

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

            // FFI lib method call (e.g. Console.puts(...) / Standard.gcMalloc(...))
            if (call.callee.data == .get_expr) {
                const g = call.callee.data.get_expr;
                if (g.object.data == .identifier) {
                    const lib_name = g.object.data.identifier.name;
                    if (libs.get(lib_name)) |func_names| {
                        if (func_names.get(g.name)) |c_name| {
                            const c_name_z = try std.heap.page_allocator.dupeZ(u8, c_name);
                            defer std.heap.page_allocator.free(c_name_z);

                            if (llvm.LLVMGetNamedFunction(mod, c_name_z.ptr)) |func_val| {
                                var arg_vals = try std.heap.page_allocator.alloc(llvm.LLVMValueRef, call.arguments.len);
                                defer std.heap.page_allocator.free(arg_vals);

                                const func_type = llvm.LLVMGlobalGetValueType(func_val);
                                const param_count = llvm.LLVMCountParamTypes(func_type);
                                const func_param_types = try std.heap.page_allocator.alloc(llvm.LLVMTypeRef, param_count);
                                defer std.heap.page_allocator.free(func_param_types);
                                llvm.LLVMGetParamTypes(func_type, func_param_types.ptr);

                                for (call.arguments, 0..) |arg_node, idx| {
                                    var arg_val = try emitExpression(ctx, mod, builder, scope, structs, libs, arg_node);
                                    if (idx < param_count) {
                                        arg_val = coerceArg(builder, arg_val, func_param_types[idx]);
                                    }
                                    arg_vals[idx] = arg_val;
                                }

                                return llvm.LLVMBuildCall2(
                                    builder,
                                    func_type,
                                    func_val,
                                    if (arg_vals.len > 0) arg_vals.ptr else null,
                                    @intCast(arg_vals.len),
                                    "ffitmp",
                                );
                            }
                        }
                    }
                }
            }

            // Object/static method call: the type checker sets the callee's
            // resolved type to the Function type whose `c_name` is the exact
            // mangled symbol (e.g. `coroutines_Coroutine_sleep`).
            if (call.callee.data == .get_expr) {
                if (call.callee.resolved_type) |rt| {
                    if (rt.* == .Function) {
                        if (rt.Function.c_name.len > 0) {
                            const fn_c_name = rt.Function.c_name;
                            const fn_c_name_z = try std.heap.page_allocator.dupeZ(u8, fn_c_name);
                            defer std.heap.page_allocator.free(fn_c_name_z);
                            if (llvm.LLVMGetNamedFunction(mod, fn_c_name_z.ptr)) |func_val| {
                                const func_type = llvm.LLVMGlobalGetValueType(func_val);
                                const param_count = llvm.LLVMCountParamTypes(func_type);
                                const func_param_types = try std.heap.page_allocator.alloc(llvm.LLVMTypeRef, param_count);
                                defer std.heap.page_allocator.free(func_param_types);
                                llvm.LLVMGetParamTypes(func_type, func_param_types.ptr);

                                // Object/static methods have no receiver; instance
                                // methods dispatch elsewhere. Offset to account for
                                // receiver-less calls only.
                                const has_receiver = rt.Function.receiver != null;
                                const arg_base: usize = if (has_receiver) 1 else 0;

                                var arg_vals = try std.heap.page_allocator.alloc(llvm.LLVMValueRef, call.arguments.len + arg_base);
                                defer std.heap.page_allocator.free(arg_vals);

                                if (has_receiver) {
                                    const obj_val = try emitExpression(ctx, mod, builder, scope, structs, libs, call.callee.data.get_expr.object);
                                    arg_vals[0] = obj_val;
                                }

                                for (call.arguments, 0..) |arg_node, idx| {
                                    var arg_val = try emitExpression(ctx, mod, builder, scope, structs, libs, arg_node);
                                    if (idx + arg_base < param_count) {
                                        arg_val = coerceArg(builder, arg_val, func_param_types[idx + arg_base]);
                                    }
                                    arg_vals[idx + arg_base] = arg_val;
                                }

                                return llvm.LLVMBuildCall2(
                                    builder,
                                    func_type,
                                    func_val,
                                    if (arg_vals.len > 0) arg_vals.ptr else null,
                                    @intCast(arg_vals.len),
                                    "static_tmp",
                                );
                            }
                        }
                    }
                }
            }

            // String concatenation: `+` on String desugars to `.plus()`; in the
            // LLVM model a String is a char pointer so emit an inline concat.
            // TODO(emitter): `+` on strings is special-cased here as an inline
            // malloc/strlen/sprintf sequence because the LLVM model represents
            // String as a bare char* (no EiwaString struct with .length/.ptr),
            // so the stdlib String.plus body can't run as-is. This bypasses the
            // Stringable/hashCode/memory model entirely and re-allocates with
            // the emitter's own malloc preference. It mirrors the C transpiler's
            // string handling but only covers `+` (no repeat/join/etc.). Proper
            // fix: materialize a real String representation (or reuse
            // eiwa_concat from the runtime) so string ops share one code path.
            // INHERITED GAMBIARRA: string-as-char* + inline concat traces to the
            // C backend's String model (EiwaString/Str, eiwa_concat in
            // src/backend/c_transpiler/eiwa_runtime.h). The C version allocates
            // a real String header; this LLVM inline path returns a bare buffer
            // with no header, so `.length`/`.ptr` semantics differ.
            if (call.callee.data == .get_expr) {
                const g = call.callee.data.get_expr;
                if (std.mem.eql(u8, g.name, "plus")) {
                    if (g.object.resolved_type) |obj_rt| {
                        const obj_base = obj_rt.*;
                        const is_string_plus = obj_base == .String or (obj_base == .Custom and std.mem.eql(u8, obj_base.Custom, "String")) or
                            (obj_base == .Custom and std.mem.eql(u8, obj_base.Custom, "core_String"));
                        if (is_string_plus and call.arguments.len >= 1) {
                            const i64_type = llvm.LLVMInt64TypeInContext(ctx);

                            const left_val = try emitExpression(ctx, mod, builder, scope, structs, libs, g.object);
                            const right_val = try emitExpression(ctx, mod, builder, scope, structs, libs, call.arguments[0]);

                            // total = strlen(a) + strlen(b) + 1
                            const strlen_func = llvm.LLVMGetNamedFunction(mod, "strlen") orelse return error.StrlenNotFound;
                            const strlen_type = llvm.LLVMGlobalGetValueType(strlen_func);
                            var sl_args = [_]llvm.LLVMValueRef{left_val};
                            const len_a = llvm.LLVMBuildCall2(builder, strlen_type, strlen_func, &sl_args, 1, "strlen_a");
                            var sr_args = [_]llvm.LLVMValueRef{right_val};
                            const len_b = llvm.LLVMBuildCall2(builder, strlen_type, strlen_func, &sr_args, 1, "strlen_b");
                            const total = llvm.LLVMBuildAdd(builder, len_a, len_b, "concat_len");
                            const total_plus_one = llvm.LLVMBuildAdd(builder, total, llvm.LLVMConstInt(i64_type, 1, 0), "concat_len1");

                            // buf = malloc(total + 1); sprintf(buf, "%s%s", a, b)
                            // TODO(emitter): malloc-first ordering is the
                            // libgc-linking workaround — see the note in
                            // core.zig emitTypeConstructor.
                            // LLVM-SPECIFIC (NOT inherited from C): same as the
                            // array-literal malloc note — the C backend uses
                            // GC_MALLOC via eiwa_runtime.h and has no fallback.
                            const gc_func = llvm.LLVMGetNamedFunction(mod, "malloc") orelse llvm.LLVMGetNamedFunction(mod, "GC_malloc").?;
                            const gc_type = llvm.LLVMGlobalGetValueType(gc_func);
                            var gc_args = [_]llvm.LLVMValueRef{total_plus_one};
                            const buf = llvm.LLVMBuildCall2(builder, gc_type, gc_func, &gc_args, 1, "concat_buf");

                            const sprintf_func = llvm.LLVMGetNamedFunction(mod, "sprintf") orelse return error.SprintfNotFound;
                            const sprintf_type = llvm.LLVMGlobalGetValueType(sprintf_func);
                            const fmt = llvm.LLVMBuildGlobalStringPtr(builder, "%s%s", "concat_fmt");
                            var sp_args = [_]llvm.LLVMValueRef{ buf, fmt, left_val, right_val };
                            _ = llvm.LLVMBuildCall2(builder, sprintf_type, sprintf_func, &sp_args, 4, "concat_sprintf");
                            return buf;
                        }
                    }
                }
            }

            // Object method call: `obj.method(args...)` where obj is a struct
            // instance. Emits a call to the mangled `{Type}_{method}` function
            // with the object as the receiver (this).
            if (call.callee.data == .get_expr) {
                const g = call.callee.data.get_expr;
                if (g.object.resolved_type) |obj_rt| {
                    var type_name: []const u8 = "";
                    if (obj_rt.* == .Custom) {
                        type_name = obj_rt.Custom;
                    } else if (obj_rt.* == .Pointer and obj_rt.Pointer.* == .Custom) {
                        type_name = obj_rt.Pointer.Custom;
                    }
                    if (structs.get(type_name) != null) {
                        const method_name = try std.heap.page_allocator.dupeZ(u8, type_name);
                        defer std.heap.page_allocator.free(method_name);
                        const method_z = try std.fmt.allocPrint(std.heap.page_allocator, "{s}_{s}\x00", .{ type_name, g.name });
                        defer std.heap.page_allocator.free(method_z);

                        if (llvm.LLVMGetNamedFunction(mod, method_z.ptr)) |func_val| {
                            const func_type = llvm.LLVMGlobalGetValueType(func_val);
                            const param_count = llvm.LLVMCountParamTypes(func_type);
                            const func_param_types = try std.heap.page_allocator.alloc(llvm.LLVMTypeRef, param_count);
                            defer std.heap.page_allocator.free(func_param_types);
                            llvm.LLVMGetParamTypes(func_type, func_param_types.ptr);

                            var arg_vals = try std.heap.page_allocator.alloc(llvm.LLVMValueRef, call.arguments.len + 1);
                            defer std.heap.page_allocator.free(arg_vals);

                            const obj_val = try emitExpression(ctx, mod, builder, scope, structs, libs, g.object);
                            arg_vals[0] = obj_val;

                            for (call.arguments, 0..) |arg_node, idx| {
                                var arg_val = try emitExpression(ctx, mod, builder, scope, structs, libs, arg_node);
                                if (idx + 1 < param_count) {
                                    arg_val = coerceArg(builder, arg_val, func_param_types[idx + 1]);
                                }
                                arg_vals[idx + 1] = arg_val;
                            }

                            return llvm.LLVMBuildCall2(
                                builder,
                                func_type,
                                func_val,
                                if (arg_vals.len > 0) arg_vals.ptr else null,
                                @intCast(arg_vals.len),
                                "method_tmp",
                            );
                        }
                    }
                }
            }

            // Contract method dispatch call: `value.toString()` on a Stringable
            // value. The get_expr emission already produces the final string
            // pointer via eiwa_to_string — pass it through, do NOT call it.
            // TODO(emitter): This pass-through exists because the get_expr
            // `.toString()` branch above ALREADY emitted the eiwa_to_string call,
            // so re-dispatching here would double-call it. That coupling is
            // subtle and order-dependent; the is_stringable check is a second,
            // looser copy of the get_expr one (see the TODO there). Proper fix:
            // collapse get_expr/call_expr toString handling into a single code
            // path (e.g. only handle `toString` at the call_expr level and make
            // get_expr return the boxed value).
            // INHERITED GAMBIARRA: name-based toString dispatch traces back to
            // the C backend — see PRE-EXISTING comment in
            // src/backend/c_transpiler/expression.zig (get_expr toString). This
            // pass-through layer is LLVM-specific (a consequence of emitting the
            // call at get_expr time), but the underlying stringly-typed dispatch
            // is the inherited part.
            if (call.callee.data == .get_expr) {
                const g = call.callee.data.get_expr;
                if (std.mem.eql(u8, g.name, "toString") and call.arguments.len == 0) {
                    if (g.object.resolved_type) |obj_rt| {
                        const obj_base = obj_rt.*;
                        const is_stringable = obj_base == .Int or obj_base == .Bool or obj_base == .Double or
                            obj_base == .String or obj_base == .Pointer or obj_base == .Union or
                            (obj_base == .Custom and (std.mem.eql(u8, obj_base.Custom, "Stringable") or std.mem.eql(u8, obj_base.Custom, "core_Stringable")));
                        if (is_stringable) {
                            return emitExpression(ctx, mod, builder, scope, structs, libs, call.callee);
                        }
                    }
                }
            }

            // NativeArray builtins: `arr.get(i)`, `arr.set(i, v)`, `arr.push(v)`
            // on the raw buffer layout (slot 0 = size, slot 1 = capacity,
            // slots 2.. = elements). See the TODO(emitter) on `.length` above.
            if (call.callee.data == .get_expr) {
                const g = call.callee.data.get_expr;
                if (g.object.resolved_type) |obj_rt| {
                    if (obj_rt.* == .Array) {
                        const i64_type = llvm.LLVMInt64TypeInContext(ctx);
                        if (std.mem.eql(u8, g.name, "get") and call.arguments.len == 1) {
                            const arr_ptr = try emitExpression(ctx, mod, builder, scope, structs, libs, g.object);
                            const i_val = try emitExpression(ctx, mod, builder, scope, structs, libs, call.arguments[0]);
                            const offset_val = llvm.LLVMBuildAdd(builder, i_val, llvm.LLVMConstInt(i64_type, 2, 0), "offset");
                            var elem_idx = [_]llvm.LLVMValueRef{offset_val};
                            const elem_ptr = llvm.LLVMBuildGEP2(builder, i64_type, arr_ptr, &elem_idx, 1, "arr_get_gep");
                            const elem_type = arrayElemLLVMType(ctx, g.object.resolved_type);
                            return llvm.LLVMBuildLoad2(builder, elem_type, elem_ptr, "arr_get_val");
                        }
                        if (std.mem.eql(u8, g.name, "set") and call.arguments.len == 2) {
                            const arr_ptr = try emitExpression(ctx, mod, builder, scope, structs, libs, g.object);
                            const i_val = try emitExpression(ctx, mod, builder, scope, structs, libs, call.arguments[0]);
                            const val = try emitExpression(ctx, mod, builder, scope, structs, libs, call.arguments[1]);
                            const offset_val = llvm.LLVMBuildAdd(builder, i_val, llvm.LLVMConstInt(i64_type, 2, 0), "offset");
                            var elem_idx = [_]llvm.LLVMValueRef{offset_val};
                            const elem_ptr = llvm.LLVMBuildGEP2(builder, i64_type, arr_ptr, &elem_idx, 1, "arr_set_gep");
                            _ = llvm.LLVMBuildStore(builder, val, elem_ptr);
                            return val;
                        }
                        if (std.mem.eql(u8, g.name, "push") and call.arguments.len == 1) {
                            return try emitNativeArrayPush(ctx, mod, builder, scope, structs, libs, g.object, call.arguments[0]);
                        }
                    }
                }
            }

            // String.replace(old, new) — routed to the hand-emitted
            // eiwa_str_replace helper (see emitStrReplaceHelper in core.zig).
            // TODO(emitter): SPECIAL CASE — same review bucket as hashCode /
            // toString: bypasses method dispatch and will shadow any future
            // std reimplementation of String.replace.
            if (call.callee.data == .get_expr) {
                const g = call.callee.data.get_expr;
                if (std.mem.eql(u8, g.name, "replace") and call.arguments.len == 2) {
                    if (g.object.resolved_type) |obj_rt| {
                        if (obj_rt.* == .String) {
                            const s_val = try emitExpression(ctx, mod, builder, scope, structs, libs, g.object);
                            const old_val = try emitExpression(ctx, mod, builder, scope, structs, libs, call.arguments[0]);
                            const new_val = try emitExpression(ctx, mod, builder, scope, structs, libs, call.arguments[1]);
                            const fn_val = llvm.LLVMGetNamedFunction(mod, "eiwa_str_replace") orelse return error.StrReplaceHelperNotFound;
                            const fn_type = llvm.LLVMGlobalGetValueType(fn_val);
                            var args = [_]llvm.LLVMValueRef{ s_val, old_val, new_val };
                            return llvm.LLVMBuildCall2(builder, fn_type, fn_val, &args, 3, "replace_tmp");
                        }
                    }
                }
            }

            // Dynamic Function / Lambda Call
            const callee_val = try emitExpression(ctx, mod, builder, scope, structs, libs, call.callee);

            var arg_vals = try std.heap.page_allocator.alloc(llvm.LLVMValueRef, call.arguments.len);
            defer std.heap.page_allocator.free(arg_vals);

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

            for (call.arguments, 0..) |arg_node, idx| {
                var arg_val = try emitExpression(ctx, mod, builder, scope, structs, libs, arg_node);
                if (llvm.LLVMGetTypeKind(param_types[idx]) != llvm.LLVMVoidTypeKind) {
                    arg_val = coerceArg(builder, arg_val, param_types[idx]);
                }
                arg_vals[idx] = arg_val;
            }

            const dynamic_fn_type = llvm.LLVMFunctionType(ret_type, if (param_types.len > 0) param_types.ptr else null, @intCast(param_types.len), 0);
            // Void-returning calls must NOT be given an SSA name (invalid IR);
            // LLVMBuildCall2 dereferences the name unconditionally, so use the
            // empty-string sentinel (LLVM treats "" as "no name") rather than null.
            const call_name: [*c]const u8 = if (llvm.LLVMGetTypeKind(ret_type) == llvm.LLVMVoidTypeKind) "" else "dyn_calltmp";
            return llvm.LLVMBuildCall2(
                builder,
                dynamic_fn_type,
                callee_val,
                if (arg_vals.len > 0) arg_vals.ptr else null,
                @intCast(arg_vals.len),
                call_name,
            );
        },
        .if_expr => |i| {
            const is_void = if (node.resolved_type) |rt| rt.* == .Void else false;
            const ret_type = if (node.resolved_type) |rt| types_mapping.getLLVMType(ctx, rt.*) else llvm.LLVMInt64TypeInContext(ctx);
            const i64_type = llvm.LLVMInt64TypeInContext(ctx);

            const cur_bb = llvm.LLVMGetInsertBlock(builder);
            const func_val = llvm.LLVMGetBasicBlockParent(cur_bb);

            const cond_val = try emitExpression(ctx, mod, builder, scope, structs, libs, i.condition);

            const then_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "expr_if.then");
            const else_bb = if (i.else_branch != null) llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "expr_if.else") else null;
            const merge_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "expr_if.merge");

            _ = llvm.LLVMBuildCondBr(builder, cond_val, then_bb, else_bb orelse merge_bb);

            const res_ptr = if (!is_void) llvm.LLVMBuildAlloca(builder, ret_type, "expr_if_res") else null;

            llvm.LLVMPositionBuilderAtEnd(builder, then_bb);
            if (i.then_branch.data == .block) {
                try statement.emitStatement(ctx, mod, builder, func_val, scope, structs, libs, i.then_branch);
            } else {
                const val = try emitExpression(ctx, mod, builder, scope, structs, libs, i.then_branch);
                if (res_ptr) |rp| {
                    _ = llvm.LLVMBuildStore(builder, val, rp);
                }
            }
            if (llvm.LLVMGetBasicBlockTerminator(llvm.LLVMGetInsertBlock(builder)) == null) {
                _ = llvm.LLVMBuildBr(builder, merge_bb);
            }

            if (i.else_branch) |else_node| {
                if (else_bb) |eb| {
                    llvm.LLVMPositionBuilderAtEnd(builder, eb);
                    if (else_node.data == .block) {
                        try statement.emitStatement(ctx, mod, builder, func_val, scope, structs, libs, else_node);
                    } else {
                        const val = try emitExpression(ctx, mod, builder, scope, structs, libs, else_node);
                        if (res_ptr) |rp| {
                            _ = llvm.LLVMBuildStore(builder, val, rp);
                        }
                    }
                    if (llvm.LLVMGetBasicBlockTerminator(llvm.LLVMGetInsertBlock(builder)) == null) {
                        _ = llvm.LLVMBuildBr(builder, merge_bb);
                    }
                }
            } else {
                if (else_bb) |eb| {
                    llvm.LLVMPositionBuilderAtEnd(builder, eb);
                    if (llvm.LLVMGetBasicBlockTerminator(eb) == null) {
                        _ = llvm.LLVMBuildBr(builder, merge_bb);
                    }
                }
            }

            llvm.LLVMPositionBuilderAtEnd(builder, merge_bb);
            if (res_ptr) |rp| {
                return llvm.LLVMBuildLoad2(builder, ret_type, rp, "expr_if_res_load");
            }
            return llvm.LLVMConstInt(i64_type, 0, 0);
        },
        .when_expr => |w| {
            const is_void = if (node.resolved_type) |rt| rt.* == .Void else false;
            const ret_type = if (node.resolved_type) |rt| types_mapping.getLLVMType(ctx, rt.*) else llvm.LLVMInt64TypeInContext(ctx);

            const i64_type = llvm.LLVMInt64TypeInContext(ctx);
            const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);

            const cur_bb = llvm.LLVMGetInsertBlock(builder);
            const func_val = llvm.LLVMGetBasicBlockParent(cur_bb);

            var subj_ptr: ?llvm.LLVMValueRef = null;
            if (w.subject) |subj| {
                const subj_val = try emitExpression(ctx, mod, builder, scope, structs, libs, subj);
                subj_ptr = llvm.LLVMBuildAlloca(builder, llvm.LLVMTypeOf(subj_val), "when_subj");
                _ = llvm.LLVMBuildStore(builder, subj_val, subj_ptr.?);
            }

            const res_ptr = if (!is_void) llvm.LLVMBuildAlloca(builder, ret_type, "when_res") else null;

            const merge_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "when.merge");

            for (w.cases, 0..) |case, case_idx| {
                const body_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "when.body");
                const next_bb = if (case_idx + 1 < w.cases.len) llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "when.next") else null;

                if (case.is_else) {
                    _ = llvm.LLVMBuildBr(builder, body_bb);
                } else {
                    var cond_vals = compat.ArrayList(llvm.LLVMValueRef).init(std.heap.page_allocator);
                    defer cond_vals.deinit();
                    for (case.conds) |cond| {
                        if (cond.data == .is_type_cond) {
                            // TODO(emitter): Type checks in `when (x) is T` are
                            // implemented as raw pointer-range heuristics: a value
                            // < 0x10000 is "an Int/Double", <= 1 is "a Bool", and
                            // anything >= 0x10000 is treated as "any custom type".
                            // This is a simplified version of the C runtime's
                            // tagging (eiwa_runtime.h uses < 0x10000 as a small-
                            // int convention too), BUT it cannot distinguish two
                            // different custom types or a String from a Person:
                            // any `is SomeCustomType` where the value is a boxed
                            // pointer always matches. The C transpiler gets this
                            // right by dereferencing an EiwaTypeDescriptor and
                            // comparing to the target's descriptor/vtable. Proper
                            // fix: materialize type descriptors (or a type-tag
                            // header on boxed values) in the LLVM model so
                            // `is` compares actual types, not pointer ranges.
                            // INHERITED GAMBIARRA: the `< 0x10000`/`<= 1` tagging
                            // rule came from the C backend — see PRE-EXISTING
                            // comments in src/backend/c_transpiler/expression.zig
                            // (is_expr / when is_type_cond) and
                            // src/backend/c_transpiler/eiwa_runtime.h. The C
                            // version extends the range check with an exact
                            // EiwaTypeDescriptor comparison for custom types;
                            // this LLVM copy stops at the range check (no
                            // descriptors exist in the LLVM model). The tag
                            // constant (0x10000) is duplicated across both
                            // backends and must not drift.
                            const type_cond = cond.data.is_type_cond;
                            const target_t = if (type_cond.type_ref.resolved_type) |rt| rt.* else ts.EiwaType.Unknown;
                            var target_c_name: []const u8 = "unknown";
                            switch (target_t) {
                                .Custom => |cn| target_c_name = cn,
                                .Int => target_c_name = "core_Int",
                                .Double => target_c_name = "core_Double",
                                .Bool => target_c_name = "core_Bool",
                                .Null => target_c_name = "core_Null",
                                .String => target_c_name = "core_String",
                                else => {},
                            }
                            const subj_load = llvm.LLVMBuildLoad2(builder, llvm.LLVMTypeOf(subj_ptr.?), subj_ptr.?, "when_subj_load");
                            const subj_int = llvm.LLVMBuildPtrToInt(builder, subj_load, i64_type, "when_subj_int");
                            var is_match: llvm.LLVMValueRef = undefined;
                            if (std.mem.eql(u8, target_c_name, "core_Null")) {
                                is_match = llvm.LLVMBuildICmp(builder, llvm.LLVMIntEQ, subj_load, llvm.LLVMConstNull(ptr_type), "when_is_null");
                            } else if (std.mem.eql(u8, target_c_name, "core_Int") or std.mem.eql(u8, target_c_name, "core_Double") or std.mem.eql(u8, target_c_name, "Double")) {
                                is_match = llvm.LLVMBuildICmp(builder, llvm.LLVMIntULT, subj_int, llvm.LLVMConstInt(i64_type, 0x10000, 0), "when_is_small");
                            } else if (std.mem.eql(u8, target_c_name, "core_Bool")) {
                                is_match = llvm.LLVMBuildICmp(builder, llvm.LLVMIntULE, subj_int, llvm.LLVMConstInt(i64_type, 1, 0), "when_is_bool");
                            } else {
                                // Custom type / contract: non-primitive boxed pointer.
                                is_match = llvm.LLVMBuildICmp(builder, llvm.LLVMIntUGE, subj_int, llvm.LLVMConstInt(i64_type, 0x10000, 0), "when_is_custom");
                            }
                            if (type_cond.is_not) {
                                is_match = llvm.LLVMBuildNot(builder, is_match, "when_is_not");
                            }
                            try cond_vals.append(is_match);
                        } else {
                            // Value check: subject == cond (or plain Bool condition).
                            var cond_val = try emitExpression(ctx, mod, builder, scope, structs, libs, cond);
                            if (subj_ptr != null) {
                                const subj_load = llvm.LLVMBuildLoad2(builder, llvm.LLVMTypeOf(subj_ptr.?), subj_ptr.?, "when_subj_load");
                                cond_val = llvm.LLVMBuildICmp(builder, llvm.LLVMIntEQ, subj_load, cond_val, "when_val_eq");
                            }
                            try cond_vals.append(cond_val);
                        }
                    }
                    var combined = cond_vals.items[0];
                    for (cond_vals.items[1..]) |c| {
                        combined = llvm.LLVMBuildOr(builder, combined, c, "when_or");
                    }
                    _ = llvm.LLVMBuildCondBr(builder, combined, body_bb, next_bb orelse merge_bb);
                }

                llvm.LLVMPositionBuilderAtEnd(builder, body_bb);
                if (case.body.data == .block) {
                    try statement.emitStatement(ctx, mod, builder, func_val, scope, structs, libs, case.body);
                } else {
                    const val = try emitExpression(ctx, mod, builder, scope, structs, libs, case.body);
                    if (res_ptr) |rp| {
                        _ = llvm.LLVMBuildStore(builder, val, rp);
                    }
                }
                if (llvm.LLVMGetBasicBlockTerminator(body_bb) == null) {
                    _ = llvm.LLVMBuildBr(builder, merge_bb);
                }

                if (next_bb) |nb| {
                    llvm.LLVMPositionBuilderAtEnd(builder, nb);
                }
            }

            llvm.LLVMPositionBuilderAtEnd(builder, merge_bb);
            if (res_ptr) |rp| {
                return llvm.LLVMBuildLoad2(builder, ret_type, rp, "when_res_load");
            }
            return llvm.LLVMConstInt(i64_type, 0, 0);
        },
        else => {
            std.debug.print("LLVM Debug: unsupported expression node type {any}\n", .{node.data});
            return error.UnsupportedExpressionNode;
        },
    }
}

/// TODO(emitter): `coerceArg` is a symptom, not a fix. The LLVM emitter models
/// primitives (Int/Bool/Double) as raw LLVM integers while Union/contract
/// parameters (`Stringable?`) are pointers, so this boxes/unboxes/extends at
/// every call boundary via runtime LLVM type inspection. That keeps the emitter
/// honest about the current value model but is fragile: it guesses intent from
/// LLVM type kinds (e.g. any i64 -> any ptr boxes, which is wrong once a custom
/// type is represented as an integer or a String as anything but a char*).
/// Proper fix: decide the canonical representation of each Eiwa type ONCE in the
/// type checker (src/core/type_checker/) — e.g. tag `is_boxed` on resolved types
/// like the C transpiler does — and have the emitter use that flag instead of
/// LLVM type-kind sniffing. Until then, keep this as the single choke-point for
/// all argument coercion (do NOT add ad-hoc boxing at individual call sites).
/// INHERITED GAMBIARRA: the boxing model itself (primitives raw, boxed custom/
/// union values) traces back to the C backend's `is_boxed` flags in
/// src/backend/c_transpiler/expression.zig. The C transpiler uses the type
/// checker's is_boxed decision directly; this LLVM coercion re-derives it from
/// LLVM type kinds, which is the fragile part. Aligning both on the same
/// type-checker flag removes the sniffing here.
fn coerceArg(
    builder: llvm.LLVMBuilderRef,
    arg_val: llvm.LLVMValueRef,
    param_type: llvm.LLVMTypeRef,
) llvm.LLVMValueRef {
    const arg_type = llvm.LLVMTypeOf(arg_val);
    const arg_kind = llvm.LLVMGetTypeKind(arg_type);
    const param_kind = llvm.LLVMGetTypeKind(param_type);
    if (arg_kind == llvm.LLVMIntegerTypeKind and param_kind == llvm.LLVMPointerTypeKind) {
        return llvm.LLVMBuildIntToPtr(builder, arg_val, param_type, "box_arg");
    }
    if (arg_kind == llvm.LLVMPointerTypeKind and param_kind == llvm.LLVMIntegerTypeKind) {
        return llvm.LLVMBuildPtrToInt(builder, arg_val, param_type, "unbox_arg");
    }
    if (arg_kind == llvm.LLVMIntegerTypeKind and param_kind == llvm.LLVMIntegerTypeKind) {
        const arg_bits = llvm.LLVMGetIntTypeWidth(arg_type);
        const param_bits = llvm.LLVMGetIntTypeWidth(param_type);
        if (arg_bits != param_bits) {
            if (arg_bits < param_bits) {
                return llvm.LLVMBuildZExt(builder, arg_val, param_type, "ext_arg");
            }
            return llvm.LLVMBuildTrunc(builder, arg_val, param_type, "trunc_arg");
        }
    }
    return arg_val;
}

fn isStringOperand(node: *ast.ASTNode) bool {
    const rt = node.resolved_type orelse return false;
    return switch (rt.*) {
        .String => true,
        .Custom => |n| std.mem.eql(u8, n, "core_String") or std.mem.eql(u8, n, "String"),
        else => false,
    };
}

/// Maps the element type of an .Array-typed expression to its LLVM load type
/// for the raw buffer slots (8 bytes each). Reference types load as ptr,
/// Double as double (bitcast-compatible 8-byte slot), everything else as i64.
fn arrayElemLLVMType(ctx: llvm.LLVMContextRef, obj_rt: ?*const ts.EiwaType) llvm.LLVMTypeRef {
    if (obj_rt) |rt| {
        if (rt.* == .Array) {
            const elem_t = rt.Array.*;
            switch (elem_t) {
                .Custom, .String, .Pointer, .Array, .Union, .Function, .GenericInstance => return llvm.LLVMPointerTypeInContext(ctx, 0),
                .Double => return llvm.LLVMDoubleTypeInContext(ctx),
                else => return llvm.LLVMInt64TypeInContext(ctx),
            }
        }
    }
    return llvm.LLVMInt64TypeInContext(ctx);
}

/// Resolves the memory address (lvalue) of an array buffer variable, so
/// `push` can write back the (possibly reallocated) buffer pointer.
/// Supports identifiers (local allocas) and field chains (`this.items`).
fn emitArrayLvalue(
    ctx: llvm.LLVMContextRef,
    mod: llvm.LLVMModuleRef,
    builder: llvm.LLVMBuilderRef,
    scope: *std.StringHashMap(llvm.LLVMValueRef),
    structs: *std.StringHashMap(core.StructInfo),
    libs: *const std.StringHashMap(std.StringHashMap([]const u8)),
    node: *ast.ASTNode,
) anyerror!llvm.LLVMValueRef {
    switch (node.data) {
        .identifier => |ident| {
            const name = ident.resolved_c_name orelse ident.name;
            if (scope.get(name)) |var_val| {
                if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(var_val)) == llvm.LLVMPointerTypeKind) {
                    return var_val;
                }
            }
            return error.ArrayLvalueNotAddressable;
        },
        .get_expr => |get| {
            const obj_val = try emitExpression(ctx, mod, builder, scope, structs, libs, get.object);
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
                            return llvm.LLVMBuildStructGEP2(builder, s_info.struct_type, obj_val, @intCast(f_idx), field_name_z.ptr);
                        }
                    }
                }
            }
            return error.ArrayLvalueNotAddressable;
        },
        else => return error.ArrayLvalueNotAddressable,
    }
}

/// Emits `arr.push(val)` on the raw buffer layout (slot 0 = size,
/// slot 1 = capacity, slots 2.. = elements), growing via realloc when full
/// and writing the (possibly moved) buffer pointer back to the lvalue.
/// TODO(emitter): realloc-first ordering is the same libgc-linking workaround
/// as malloc in emitTypeConstructor — the C backend uses GC_REALLOC inside
/// EiwaArray_push (src/backend/c_transpiler/core.zig:315). LLVM-SPECIFIC.
fn emitNativeArrayPush(
    ctx: llvm.LLVMContextRef,
    mod: llvm.LLVMModuleRef,
    builder: llvm.LLVMBuilderRef,
    scope: *std.StringHashMap(llvm.LLVMValueRef),
    structs: *std.StringHashMap(core.StructInfo),
    libs: *const std.StringHashMap(std.StringHashMap([]const u8)),
    object_node: *ast.ASTNode,
    value_node: *ast.ASTNode,
) anyerror!llvm.LLVMValueRef {
    const i64_type = llvm.LLVMInt64TypeInContext(ctx);
    const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);

    const arr_addr = try emitArrayLvalue(ctx, mod, builder, scope, structs, libs, object_node);
    const arr_val = llvm.LLVMBuildLoad2(builder, ptr_type, arr_addr, "arr_buf");
    const val = try emitExpression(ctx, mod, builder, scope, structs, libs, value_node);

    var idx0 = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, 0, 0)};
    const size_ptr = llvm.LLVMBuildGEP2(builder, i64_type, arr_val, &idx0, 1, "size_ptr");
    const size_val = llvm.LLVMBuildLoad2(builder, i64_type, size_ptr, "size_val");

    var idx1 = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, 1, 0)};
    const cap_ptr = llvm.LLVMBuildGEP2(builder, i64_type, arr_val, &idx1, 1, "cap_ptr");
    const cap_val = llvm.LLVMBuildLoad2(builder, i64_type, cap_ptr, "cap_val");

    const is_full = llvm.LLVMBuildICmp(builder, llvm.LLVMIntEQ, size_val, cap_val, "arr_full");

    const func_val = llvm.LLVMGetBasicBlockParent(llvm.LLVMGetInsertBlock(builder));
    const pre_bb = llvm.LLVMGetInsertBlock(builder);
    const grow_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "arr_grow");
    const cont_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "arr_push_cont");
    _ = llvm.LLVMBuildCondBr(builder, is_full, grow_bb, cont_bb);

    // Grow: newcap = cap == 0 ? 4 : cap * 2; arr = realloc(arr, (newcap+2)*8)
    llvm.LLVMPositionBuilderAtEnd(builder, grow_bb);
    const cap_is_zero = llvm.LLVMBuildICmp(builder, llvm.LLVMIntEQ, cap_val, llvm.LLVMConstInt(i64_type, 0, 0), "cap_zero");
    const doubled = llvm.LLVMBuildMul(builder, cap_val, llvm.LLVMConstInt(i64_type, 2, 0), "cap_doubled");
    const new_cap = llvm.LLVMBuildSelect(builder, cap_is_zero, llvm.LLVMConstInt(i64_type, 4, 0), doubled, "new_cap");
    const total_slots = llvm.LLVMBuildAdd(builder, new_cap, llvm.LLVMConstInt(i64_type, 2, 0), "total_slots");
    const new_bytes = llvm.LLVMBuildMul(builder, total_slots, llvm.LLVMConstInt(i64_type, 8, 0), "new_bytes");

    var realloc_fn = llvm.LLVMGetNamedFunction(mod, "realloc");
    if (realloc_fn == null) {
        var realloc_params = [_]llvm.LLVMTypeRef{ ptr_type, i64_type };
        const realloc_type = llvm.LLVMFunctionType(ptr_type, &realloc_params, 2, 0);
        realloc_fn = llvm.LLVMAddFunction(mod, "realloc", realloc_type);
    }
    const realloc_type = llvm.LLVMGlobalGetValueType(realloc_fn);
    var realloc_args = [_]llvm.LLVMValueRef{ arr_val, new_bytes };
    const grown_arr = llvm.LLVMBuildCall2(builder, realloc_type, realloc_fn, &realloc_args, 2, "grown_arr");

    var grow_idx1 = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, 1, 0)};
    const new_cap_ptr = llvm.LLVMBuildGEP2(builder, i64_type, grown_arr, &grow_idx1, 1, "new_cap_ptr");
    _ = llvm.LLVMBuildStore(builder, new_cap, new_cap_ptr);
    _ = llvm.LLVMBuildBr(builder, cont_bb);

    // Continue: store element, bump size, write buffer pointer back
    llvm.LLVMPositionBuilderAtEnd(builder, cont_bb);
    const phi = llvm.LLVMBuildPhi(builder, ptr_type, "arr_phi");
    var phi_vals = [_]llvm.LLVMValueRef{ arr_val, grown_arr };
    var phi_bbs = [_]llvm.LLVMBasicBlockRef{ pre_bb, grow_bb };
    llvm.LLVMAddIncoming(phi, &phi_vals, &phi_bbs, 2);

    const elem_offset = llvm.LLVMBuildAdd(builder, size_val, llvm.LLVMConstInt(i64_type, 2, 0), "elem_offset");
    var elem_idx = [_]llvm.LLVMValueRef{elem_offset};
    const elem_ptr = llvm.LLVMBuildGEP2(builder, i64_type, phi, &elem_idx, 1, "push_elem_ptr");
    _ = llvm.LLVMBuildStore(builder, val, elem_ptr);

    const new_size = llvm.LLVMBuildAdd(builder, size_val, llvm.LLVMConstInt(i64_type, 1, 0), "new_size");
    var phi_idx0 = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, 0, 0)};
    const phi_size_ptr = llvm.LLVMBuildGEP2(builder, i64_type, phi, &phi_idx0, 1, "phi_size_ptr");
    _ = llvm.LLVMBuildStore(builder, new_size, phi_size_ptr);

    _ = llvm.LLVMBuildStore(builder, phi, arr_addr);
    return val;
}

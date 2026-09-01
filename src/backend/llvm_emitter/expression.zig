const std = @import("std");
const ast = @import("../../core/ast.zig");
const ts = @import("../../core/type_system.zig");
const compat = @import("../../core/compat.zig");
const types_mapping = @import("types.zig");
const statement = @import("statement.zig");

/// Hex digit value (0-15) or null for non-hex characters.
fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}
const core = @import("core.zig");
const c_bindings = @import("c_bindings.zig");
const llvm = c_bindings.llvm;

// ---------------------------------------------------------------------------
// Closure fat-pointer helpers
// ---------------------------------------------------------------------------

/// Metadata for a single captured variable.
const CaptureInfo = struct {
    name: []const u8,
    llvm_type: llvm.LLVMTypeRef,
    /// If true the variable is heap-boxed (mutable `var` captured by a
    /// lambda). The env field stores a `ptr` to the value cell instead of
    /// the value itself; reads and writes inside the lambda go through the
    /// pointer (double-indirection), matching the C backend `Box_T { T value; }`
    /// model but without needing a named struct.
    is_boxed: bool = false,
};

/// Walk `node` and record every `var_decl` name (and `for` item names) into
/// `locals`.  These are variables that are *declared* inside the lambda body
/// and therefore must NOT be treated as captures.
fn collectDeclaredLocalsLLVM(node: *ast.ASTNode, locals: *std.StringHashMap(void)) anyerror!void {
    switch (node.data) {
        .var_decl => |v| try locals.put(v.name, {}),
        .block => |b| for (b.statements) |s| try collectDeclaredLocalsLLVM(s, locals),
        .if_expr => |i| {
            try collectDeclaredLocalsLLVM(i.then_branch, locals);
            if (i.else_branch) |eb| try collectDeclaredLocalsLLVM(eb, locals);
        },
        .while_stmt => |w| try collectDeclaredLocalsLLVM(w.body, locals),
        .for_stmt => |f| {
            try locals.put(f.item_name, {});
            try collectDeclaredLocalsLLVM(f.body, locals);
        },
        .try_stmt => |t| {
            try collectDeclaredLocalsLLVM(t.body, locals);
            for (t.catches) |c| {
                if (c.var_name) |vn| try locals.put(vn, {});
                try collectDeclaredLocalsLLVM(c.body, locals);
            }
        },
        .when_expr => |w| for (w.cases) |c| try collectDeclaredLocalsLLVM(c.body, locals),
        else => {},
    }
}

/// Walk `node` and collect every identifier that:
///   - is not in `locals` (not declared inside the lambda)
///   - is not a class property
///   - is not an LLVM global function
///   - is not a struct/type name
///   - has a resolved type
/// Nested lambdas are walked with an extended `inner_locals` so their own
/// declarations don't leak upward as captures.
fn collectCapturesLLVM(
    node: *ast.ASTNode,
    locals: *const std.StringHashMap(void),
    captures: *compat.ArrayList(CaptureInfo),
    mod: llvm.LLVMModuleRef,
    structs: *std.StringHashMap(core.StructInfo),
    ctx: llvm.LLVMContextRef,
) anyerror!void {
    switch (node.data) {
        .identifier => |i| {
            if (locals.contains(i.name)) return;
            if (i.is_class_property) {
                // Class properties are reached through `this` at emission time
                // (see the is_prop path in emitExpression). Capture the `this`
                // pointer itself so lambdas inside methods can resolve them —
                // otherwise body emission fails with `this` missing from the
                // scope. Receiver lambdas already re-stack `this` from the
                // receiver parameter, so it stays a local there.
                if (locals.contains("this")) return;
                for (captures.items) |cap| {
                    if (std.mem.eql(u8, cap.name, "this")) return;
                }
                try captures.append(.{ .name = "this", .llvm_type = llvm.LLVMPointerTypeInContext(ctx, 0), .is_boxed = false });
                return;
            }
            const name = i.resolved_c_name orelse i.name;
            // Skip global functions and type names
            const name_z = try std.heap.page_allocator.dupeZ(u8, name);
            defer std.heap.page_allocator.free(name_z);
            if (llvm.LLVMGetNamedFunction(mod, name_z.ptr) != null) return;
            const iname_z = try std.heap.page_allocator.dupeZ(u8, i.name);
            defer std.heap.page_allocator.free(iname_z);
            if (llvm.LLVMGetNamedFunction(mod, iname_z.ptr) != null) return;
            if (structs.contains(name) or structs.contains(i.name)) return;
            // Already captured?
            for (captures.items) |cap| {
                if (std.mem.eql(u8, cap.name, i.name)) return;
            }
            if (node.resolved_type) |rt| {
                const llvm_t = types_mapping.getLLVMType(ctx, rt.*);
                try captures.append(.{ .name = i.name, .llvm_type = llvm_t, .is_boxed = i.is_boxed });
            }
        },
        .call_expr => |c| {
            try collectCapturesLLVM(c.callee, locals, captures, mod, structs, ctx);
            for (c.arguments) |arg| try collectCapturesLLVM(arg, locals, captures, mod, structs, ctx);
        },
        .unary_expr => |u| try collectCapturesLLVM(u.operand, locals, captures, mod, structs, ctx),
        .binary_expr => |b| {
            try collectCapturesLLVM(b.left, locals, captures, mod, structs, ctx);
            try collectCapturesLLVM(b.right, locals, captures, mod, structs, ctx);
        },
        .if_expr => |i| {
            try collectCapturesLLVM(i.condition, locals, captures, mod, structs, ctx);
            try collectCapturesLLVM(i.then_branch, locals, captures, mod, structs, ctx);
            if (i.else_branch) |eb| try collectCapturesLLVM(eb, locals, captures, mod, structs, ctx);
        },
        .index_expr => |idx| {
            try collectCapturesLLVM(idx.object, locals, captures, mod, structs, ctx);
            try collectCapturesLLVM(idx.index, locals, captures, mod, structs, ctx);
        },
        .index_set_expr => |s| {
            try collectCapturesLLVM(s.object, locals, captures, mod, structs, ctx);
            try collectCapturesLLVM(s.index, locals, captures, mod, structs, ctx);
            try collectCapturesLLVM(s.value, locals, captures, mod, structs, ctx);
        },
        .assignment => |a| {
            try collectCapturesLLVM(a.value, locals, captures, mod, structs, ctx);
            // The target name can also be a capture (if assigned-to from outer scope)
            if (!locals.contains(a.name)) {
                for (captures.items) |cap| {
                    if (std.mem.eql(u8, cap.name, a.name)) return;
                }
                if (node.resolved_type) |rt| {
                    const llvm_t = types_mapping.getLLVMType(ctx, rt.*);
                    try captures.append(.{ .name = a.name, .llvm_type = llvm_t, .is_boxed = a.is_boxed });
                }
            }
        },
        .get_expr => |g| try collectCapturesLLVM(g.object, locals, captures, mod, structs, ctx),
        .set_expr => |s| {
            try collectCapturesLLVM(s.object, locals, captures, mod, structs, ctx);
            try collectCapturesLLVM(s.value, locals, captures, mod, structs, ctx);
        },
        .block => |b| for (b.statements) |s| try collectCapturesLLVM(s, locals, captures, mod, structs, ctx),
        .while_stmt => |w| {
            try collectCapturesLLVM(w.condition, locals, captures, mod, structs, ctx);
            try collectCapturesLLVM(w.body, locals, captures, mod, structs, ctx);
        },
        .for_stmt => |f| {
            try collectCapturesLLVM(f.iterable, locals, captures, mod, structs, ctx);
            try collectCapturesLLVM(f.body, locals, captures, mod, structs, ctx);
        },
        .return_stmt => |r| { if (r.value) |v| try collectCapturesLLVM(v, locals, captures, mod, structs, ctx); },
        .throw_stmt => |t| try collectCapturesLLVM(t.expr, locals, captures, mod, structs, ctx),
        .var_decl => |v| { if (v.initializer) |init| try collectCapturesLLVM(init, locals, captures, mod, structs, ctx); },
        .ternary_expr => |t| {
            try collectCapturesLLVM(t.condition, locals, captures, mod, structs, ctx);
            try collectCapturesLLVM(t.then_branch, locals, captures, mod, structs, ctx);
            if (t.else_branch) |eb| try collectCapturesLLVM(eb, locals, captures, mod, structs, ctx);
        },
        .as_expr => |a| try collectCapturesLLVM(a.value, locals, captures, mod, structs, ctx),
        .named_arg => |na| try collectCapturesLLVM(na.value, locals, captures, mod, structs, ctx),
        .is_expr => |i| try collectCapturesLLVM(i.value, locals, captures, mod, structs, ctx),
        .try_stmt => |t| {
            try collectCapturesLLVM(t.body, locals, captures, mod, structs, ctx);
            for (t.catches) |c| try collectCapturesLLVM(c.body, locals, captures, mod, structs, ctx);
        },
        .when_expr => |w| {
            if (w.subject) |subj| try collectCapturesLLVM(subj, locals, captures, mod, structs, ctx);
            for (w.cases) |case| {
                for (case.conds) |cond| try collectCapturesLLVM(cond, locals, captures, mod, structs, ctx);
                try collectCapturesLLVM(case.body, locals, captures, mod, structs, ctx);
            }
        },
        // Nested lambda: build inner_locals (outer locals + inner params + inner decls)
        // so the inner lambda's own variables are not treated as captures.
        // Pass the outer `captures` list directly — anything not in inner_locals
        // will be added to the outer closure's capture set (same as C backend).
        .lambda_expr => |l| {
            var inner_locals = std.StringHashMap(void).init(std.heap.page_allocator);
            defer inner_locals.deinit();
            var loc_it = locals.iterator();
            while (loc_it.next()) |entry| try inner_locals.put(entry.key_ptr.*, {});
            for (l.params) |p| try inner_locals.put(p.name, {});
            if (l.params.len == 0) try inner_locals.put("it", {});
            for (l.body) |s| try collectDeclaredLocalsLLVM(s, &inner_locals);
            for (l.body) |s| try collectCapturesLLVM(s, &inner_locals, captures, mod, structs, ctx);
        },
        else => {},
    }
}

/// Global contracts AST pointer set during emitModule for contract vtable lookups.
pub var global_contracts_ast_ptr: ?*std.StringHashMap(*ast.ASTNode) = null;
pub var global_classes_ast_ptr: ?*std.StringHashMap(*ast.ASTNode) = null;

/// Returns a monotonically increasing counter for unique lambda naming.
/// Uses a file-level variable (safe: single-threaded compilation).
var lambda_counter_val: usize = 0;
fn lambdaCounter() usize {
    const c = lambda_counter_val;
    lambda_counter_val += 1;
    return c;
}

/// Current value of the lambda naming counter. Used by the stub fallback in
/// core.zig to find (and delete) lambda functions orphaned by a failed body
/// emission.
pub fn currentLambdaCounter() usize {
    return lambda_counter_val;
}

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
            if (node.resolved_type) |rt| {
                if (rt.* == .Pointer) {
                    return try emitRawCharBuffer(ctx, mod, builder, str);
                }
            }
            return try emitStringLiteral(ctx, mod, builder, str);
        },
        .identifier => |ident| {
            const name = ident.resolved_c_name orelse ident.name;
            const is_prop = ident.is_class_property;
            if (is_prop) {
                const this_ptr = scope.get("this") orelse {
                    if (core.verbose) std.debug.print("LLVM Emitter Error: Class property '{s}' requires 'this' in scope.\n", .{name});
                    return error.VariableNotFound;
                };
                const cur_parent_fn = llvm.LLVMGetBasicBlockParent(llvm.LLVMGetInsertBlock(builder));
                const cur_fn_name_ptr = llvm.LLVMGetValueName(cur_parent_fn);
                const cur_fn_name = std.mem.span(cur_fn_name_ptr);

                var selected_struct: ?core.StructInfo = null;
                var selected_f_idx: usize = 0;
                var selected_f_name: []const u8 = "";

                var target_type_name: ?[]const u8 = ident.owner_type_c_name;
                if (target_type_name == null or structs.get(target_type_name.?) == null) {
                    if (std.mem.lastIndexOfScalar(u8, cur_fn_name, '_')) |last_underscore_idx| {
                        target_type_name = cur_fn_name[0..last_underscore_idx];
                    }
                }

                if (target_type_name) |t_name| {
                    if (structs.get(t_name)) |s_info| {
                        for (s_info.field_names, 0..) |f_name, f_idx| {
                            if (std.mem.eql(u8, f_name, name)) {
                                selected_struct = s_info;
                                selected_f_idx = f_idx;
                                selected_f_name = f_name;
                                break;
                            }
                        }
                    }
                }



                if (selected_struct) |s_info| {
                    const ptr_type2 = llvm.LLVMPointerTypeInContext(ctx, 0);
                    const this_val2 = llvm.LLVMBuildLoad2(builder, ptr_type2, this_ptr, "this_val2");
                    const field_name_z = try std.heap.page_allocator.dupeZ(u8, selected_f_name);
                    defer std.heap.page_allocator.free(field_name_z);
                    const field_ptr = llvm.LLVMBuildStructGEP2(builder, s_info.struct_type, this_val2, @intCast(selected_f_idx), field_name_z.ptr);
                    const field_t = if (s_info.field_types[selected_f_idx] != null) s_info.field_types[selected_f_idx] else llvm.LLVMPointerTypeInContext(ctx, 0);
                    return llvm.LLVMBuildLoad2(builder, field_t, field_ptr, "prop_val");
                }
                return error.PropertyNotFound;
            }
            if (scope.get(name)) |var_val| {
                const val_type = llvm.LLVMTypeOf(var_val);
                if (ident.is_box_ref) {
                    // Yield the box pointer (single deref of the boxed var's
                    // alloca) so a task ctor can share the mutable capture.
                    const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
                    return llvm.LLVMBuildLoad2(builder, ptr_type, var_val, "box_ref");
                }
                if (llvm.LLVMGetTypeKind(val_type) == llvm.LLVMPointerTypeKind) {
                    // Boxed variable: the alloca holds a ptr to the value heap cell.
                    // Perform double-deref: load box_ptr from alloca, then load value from box_ptr.
                    if (ident.is_boxed) {
                        const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
                        const box_ptr = llvm.LLVMBuildLoad2(builder, ptr_type, var_val, "box_ptr");
                        // Determine the actual value type from resolved_type
                        const val_elem_type = if (node.resolved_type) |res_type|
                            types_mapping.getLLVMType(ctx, res_type.*)
                        else
                            llvm.LLVMInt64TypeInContext(ctx);
                        const name_z2 = try std.fmt.allocPrint(std.heap.page_allocator, "{s}_boxed_val\x00", .{name});
                        defer std.heap.page_allocator.free(name_z2);
                        return llvm.LLVMBuildLoad2(builder, val_elem_type, box_ptr, name_z2.ptr);
                    }
                    const elem_type = blk: {
                        if (llvm.LLVMIsAAllocaInst(var_val) != null) {
                            break :blk llvm.LLVMGetAllocatedType(var_val);
                        }
                        if (node.resolved_type) |res_type| {
                            if (types_mapping.isContractType(res_type.*, global_contracts_ast_ptr)) {
                                break :blk types_mapping.getFatPointerType(ctx);
                            }
                        }
                        break :blk llvm.LLVMPointerTypeInContext(ctx, 0);
                    };
                    const name_z = try std.fmt.allocPrint(std.heap.page_allocator, "{s}_val\x00", .{name});
                    defer std.heap.page_allocator.free(name_z);
                    return llvm.LLVMBuildLoad2(builder, elem_type, var_val, name_z.ptr);
                }
                return var_val;
            }

            const name_z = try std.heap.page_allocator.dupeZ(u8, name);
            defer std.heap.page_allocator.free(name_z);
            if (llvm.LLVMGetNamedGlobal(mod, name_z.ptr)) |g| {
                const res_type = node.resolved_type orelse return g;
                const is_contract = types_mapping.isContractType(res_type.*, global_contracts_ast_ptr);
                const elem_type = if (is_contract) types_mapping.getFatPointerType(ctx) else types_mapping.getLLVMType(ctx, res_type.*);
                return llvm.LLVMBuildLoad2(builder, elem_type, g, "global_load");
            }
            if (llvm.LLVMGetNamedFunction(mod, name_z.ptr)) |f| {
                return f;
            }
            const core_name = try std.fmt.allocPrint(std.heap.page_allocator, "core_{s}\x00", .{name});
            defer std.heap.page_allocator.free(core_name);
            if (llvm.LLVMGetNamedFunction(mod, core_name.ptr)) |f| {
                return f;
            }
            const std_core_name = try std.fmt.allocPrint(std.heap.page_allocator, "std_core_{s}\x00", .{name});
            defer std.heap.page_allocator.free(std_core_name);
            if (llvm.LLVMGetNamedFunction(mod, std_core_name.ptr)) |f| {
                return f;
            }

            if (core.verbose) std.debug.print("LLVM Emitter Error: Variable '{s}' not found in local or global scope.\n", .{name});
            return error.VariableNotFound;
        },
        .get_expr => |get| {
            // Pointer values resolve `.ptr` to the pointer value itself.
            if (get.object.resolved_type) |obj_rt| {
                const base = obj_rt.*;
                if (base == .Pointer and std.mem.eql(u8, get.name, "ptr")) {
                    return emitExpression(ctx, mod, builder, scope, structs, libs, get.object);
                }
            }

            // NativeArray builtins: `.length` loads slot 0 of the raw buffer
            // layout (slot 0 = size, slot 1 = capacity, slots 2.. = elements),
            // matching the array_literal layout.
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
            // is Stringable (primitives, pointers, unions, or Stringable contracts).
            // Handled via centralized `types_mapping.isStringable`.
            if (std.mem.eql(u8, get.name, "toString")) {
                if (get.object.resolved_type) |obj_rt| {
                    if (types_mapping.isStringable(obj_rt.*)) {
                        const obj_base = obj_rt.*;
                        if (obj_base == .Union) {
                            return try emitUnionBuiltin(ctx, mod, builder, scope, structs, libs, get.object, .to_string, get.is_safe);
                        }
                        const obj_val = try emitExpression(ctx, mod, builder, scope, structs, libs, get.object);
                        if (obj_base == .Int) {
                            const i64_type = llvm.LLVMInt64TypeInContext(ctx);
                            const gc_func = core.getHeapAllocFn(mod);
                            const gc_type = llvm.LLVMGlobalGetValueType(gc_func);
                            const buf_size = llvm.LLVMConstInt(i64_type, 32, 0);
                            var gc_args = [_]llvm.LLVMValueRef{buf_size};
                            const buf = llvm.LLVMBuildCall2(builder, gc_type, gc_func, &gc_args, 1, "int_str_buf");

                            const sprintf_func = llvm.LLVMGetNamedFunction(mod, "sprintf") orelse blk: {
                                const p = llvm.LLVMPointerTypeInContext(ctx, 0);
                                var ps = [_]llvm.LLVMTypeRef{ p, p };
                                const ft = llvm.LLVMFunctionType(llvm.LLVMInt32TypeInContext(ctx), &ps, 2, 1);
                                break :blk llvm.LLVMAddFunction(mod, "sprintf", ft);
                            };
                            const sprintf_type = llvm.LLVMGlobalGetValueType(sprintf_func);
                            const fmt = llvm.LLVMBuildGlobalStringPtr(builder, "%lld", "int_fmt");
                            var sprintf_args = [_]llvm.LLVMValueRef{ buf, fmt, obj_val };
                            _ = llvm.LLVMBuildCall2(builder, sprintf_type, sprintf_func, &sprintf_args, 3, "sprintf_res");
                            return try wrapStringWithHeader(ctx, mod, builder, buf, "int_str");
                        } else if (obj_base == .Bool) {
                            const true_str = llvm.LLVMBuildGlobalStringPtr(builder, "true", "bool_str_true");
                            const false_str = llvm.LLVMBuildGlobalStringPtr(builder, "false", "bool_str_false");
                            const sel = llvm.LLVMBuildSelect(builder, obj_val, true_str, false_str, "bool_tostr");
                            return try wrapStringWithHeader(ctx, mod, builder, sel, "bool_str");
                        } else if (obj_base == .Double) {
                            const i64_type = llvm.LLVMInt64TypeInContext(ctx);
                            const gc_func = core.getHeapAllocFn(mod);
                            const gc_type = llvm.LLVMGlobalGetValueType(gc_func);
                            const buf_size = llvm.LLVMConstInt(i64_type, 64, 0);
                            var gc_args = [_]llvm.LLVMValueRef{buf_size};
                            const buf = llvm.LLVMBuildCall2(builder, gc_type, gc_func, &gc_args, 1, "double_str_buf");

                            const sprintf_func = llvm.LLVMGetNamedFunction(mod, "sprintf") orelse blk: {
                                const p = llvm.LLVMPointerTypeInContext(ctx, 0);
                                var ps = [_]llvm.LLVMTypeRef{ p, p };
                                const ft = llvm.LLVMFunctionType(llvm.LLVMInt32TypeInContext(ctx), &ps, 2, 1);
                                break :blk llvm.LLVMAddFunction(mod, "sprintf", ft);
                            };
                            const sprintf_type = llvm.LLVMGlobalGetValueType(sprintf_func);
                            const fmt = llvm.LLVMBuildGlobalStringPtr(builder, "%g", "double_fmt");
                            var sprintf_args = [_]llvm.LLVMValueRef{ buf, fmt, obj_val };
                            _ = llvm.LLVMBuildCall2(builder, sprintf_type, sprintf_func, &sprintf_args, 3, "sprintf_res");
                            return try wrapStringWithHeader(ctx, mod, builder, buf, "double_str");
                        } else {
                            const fn_val = llvm.LLVMGetNamedFunction(mod, "eiwa_to_string") orelse return error.ToStringHelperNotFound;
                            const fn_type = llvm.LLVMGlobalGetValueType(fn_val);
                            var args = [_]llvm.LLVMValueRef{obj_val};
                            const tstr = llvm.LLVMBuildCall2(builder, fn_type, fn_val, &args, 1, "tostr_tmp");
                            return try wrapStringWithHeader(ctx, mod, builder, tstr, "str_tostr");
                        }
                    }
                }
            }

            // Primitive numeric conversions: Double.toInt() and Int.toDouble().
            // Emits direct CPU cast instructions (FPToSI / SIToFP).
            if (std.mem.eql(u8, get.name, "toInt")) {
                if (get.object.resolved_type) |obj_rt| {
                    if (obj_rt.* == .Union) {
                        return try emitUnionBuiltin(ctx, mod, builder, scope, structs, libs, get.object, .to_int, get.is_safe);
                    } else if (obj_rt.* == .Double) {
                        const obj_val = try emitExpression(ctx, mod, builder, scope, structs, libs, get.object);
                        return llvm.LLVMBuildFPToSI(builder, obj_val, llvm.LLVMInt64TypeInContext(ctx), "double_to_int");
                    } else if (obj_rt.* == .Int) {
                        return try emitExpression(ctx, mod, builder, scope, structs, libs, get.object);
                    }
                }
            }
            if (std.mem.eql(u8, get.name, "toDouble")) {
                if (get.object.resolved_type) |obj_rt| {
                    if (obj_rt.* == .Union) {
                        return try emitUnionBuiltin(ctx, mod, builder, scope, structs, libs, get.object, .to_double, get.is_safe);
                    } else if (obj_rt.* == .Int) {
                        const obj_val = try emitExpression(ctx, mod, builder, scope, structs, libs, get.object);
                        return llvm.LLVMBuildSIToFP(builder, obj_val, llvm.LLVMDoubleTypeInContext(ctx), "int_to_double");
                    } else if (obj_rt.* == .Double) {
                        return try emitExpression(ctx, mod, builder, scope, structs, libs, get.object);
                    }
                }
            }



            if (std.mem.eql(u8, get.name, "hashCode")) {
                if (get.object.resolved_type) |obj_rt| {
                    const obj_base = obj_rt.*;
                    if (obj_base == .Int) {
                        return try emitExpression(ctx, mod, builder, scope, structs, libs, get.object);
                    } else if (obj_base == .Bool) {
                        const b_val = try emitExpression(ctx, mod, builder, scope, structs, libs, get.object);
                        return llvm.LLVMBuildZExt(builder, b_val, llvm.LLVMInt64TypeInContext(ctx), "bool_hash");
                    } else if (obj_base == .Double) {
                        const obj_val = try emitExpression(ctx, mod, builder, scope, structs, libs, get.object);
                        return llvm.LLVMBuildBitCast(builder, obj_val, llvm.LLVMInt64TypeInContext(ctx), "hash_double");
                    }
                }
            }

            if (get.object.data == .identifier) {
                const id_name = get.object.data.identifier.name;
                const obj_c_name = get.object.data.identifier.resolved_c_name orelse id_name;
                // A bare class-field identifier (e.g. `this.builder` in a method)
                // is not a local and is not a global/object: skip the global
                // property path, otherwise the field is resolved as a bogus
                // global and emits a load with a null operand (invalid IR).
                const obj_is_class_prop = get.object.data.identifier.is_class_property;
                if (!obj_is_class_prop and scope.get(id_name) == null and scope.get(obj_c_name) == null) {
                    var g: ?llvm.LLVMValueRef = null;
                    const global_name = try std.fmt.allocPrint(std.heap.page_allocator, "{s}_{s}\x00", .{ obj_c_name, get.name });
                    defer std.heap.page_allocator.free(global_name);
                    g = llvm.LLVMGetNamedGlobal(mod, global_name.ptr);
                    if (g == null and std.mem.endsWith(u8, obj_c_name, "_type")) {
                        const base_name = obj_c_name[0 .. obj_c_name.len - 5];
                        const base_global_name = try std.fmt.allocPrint(std.heap.page_allocator, "{s}_{s}\x00", .{ base_name, get.name });
                        defer std.heap.page_allocator.free(base_global_name);
                        g = llvm.LLVMGetNamedGlobal(mod, base_global_name.ptr);
                    }
                    if (g == null) {
                        const target_suffix = try std.fmt.allocPrint(std.heap.page_allocator, "_{s}_{s}", .{ obj_c_name, get.name });
                        defer std.heap.page_allocator.free(target_suffix);
                        var glob_it = llvm.LLVMGetFirstGlobal(mod);
                        while (glob_it) |glob| : (glob_it = llvm.LLVMGetNextGlobal(glob)) {
                            const glob_name_ptr = llvm.LLVMGetValueName(glob);
                            const glob_name_s = std.mem.span(glob_name_ptr);
                            if (std.mem.endsWith(u8, glob_name_s, target_suffix) or std.mem.eql(u8, glob_name_s, global_name)) {
                                g = glob;
                                break;
                            }
                        }
                    }
                    if (g) |global_var| {
                        const res_type = node.resolved_type orelse return global_var;
                        if (res_type.* == .Function) return global_var;
                        const elem_type = types_mapping.getLLVMType(ctx, res_type.*);
                        return llvm.LLVMBuildLoad2(builder, elem_type, global_var, "obj_var_load");
                    }
                }
            }


            var obj_val = try emitExpression(ctx, mod, builder, scope, structs, libs, get.object);
            if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(obj_val)) == llvm.LLVMStructTypeKind) {
                obj_val = llvm.LLVMBuildExtractValue(builder, obj_val, 0, "fat_data_ptr");
            }
            if (std.mem.eql(u8, get.name, "length") or std.mem.eql(u8, get.name, "len")) {
                const is_str = if (get.object.resolved_type) |rt| (switch (ts.extractBaseType(rt).*) {
                    .String => true,
                    .Custom => |n| std.mem.eql(u8, n, "String") or std.mem.eql(u8, n, "core_String") or std.mem.eql(u8, n, "std_core_String"),
                    else => false,
                }) else false;
                if (is_str) {
                    const i64_type = llvm.LLVMInt64TypeInContext(ctx);
                    const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
                    var inst_fields = [_]llvm.LLVMTypeRef{ ptr_type, i64_type };
                    const inst_struct_t = llvm.LLVMStructTypeInContext(ctx, &inst_fields, 2, 0);
                    const f1_ptr = llvm.LLVMBuildStructGEP2(builder, inst_struct_t, obj_val, 1, "str_len_ptr");
                    return llvm.LLVMBuildLoad2(builder, i64_type, f1_ptr, "str_len");
                }
            }
            if (get.object.resolved_type) |rt| {
                var base_rt = ts.extractBaseType(rt);
                if (base_rt.* == .String or (base_rt.* == .Custom and (std.mem.eql(u8, base_rt.Custom, "String") or std.mem.eql(u8, base_rt.Custom, "core_String") or std.mem.eql(u8, base_rt.Custom, "std_core_String")))) {
                    if (std.mem.eql(u8, get.name, "ptr") or std.mem.eql(u8, get.name, "data")) {
                        const i64_type = llvm.LLVMInt64TypeInContext(ctx);
                        const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
                        var inst_fields = [_]llvm.LLVMTypeRef{ ptr_type, i64_type };
                        const inst_struct_t = llvm.LLVMStructTypeInContext(ctx, &inst_fields, 2, 0);
                        const f0_ptr = llvm.LLVMBuildStructGEP2(builder, inst_struct_t, obj_val, 0, "str_data_ptr");
                        return llvm.LLVMBuildLoad2(builder, ptr_type, f0_ptr, "str_data");
                    }
                }
                if (base_rt.* == .Pointer) {
                    if (std.mem.eql(u8, get.name, "ptr") or std.mem.eql(u8, get.name, "data")) {
                        return obj_val;
                    }
                }
                if (base_rt.* == .Union or base_rt.* == .Pointer) {
                    var s_variant: ?*const ts.EiwaType = null;
                    var curr: ?*const ts.EiwaType = base_rt;
                    while (curr) |c_type| {
                        const b = ts.extractBaseType(c_type);
                        switch (b.*) {
                            .Custom, .GenericInstance => {
                                s_variant = b;
                                break;
                            },
                            .Union => |u| {
                                const l_base = ts.extractBaseType(u.left);
                                if (l_base.* == .Custom or l_base.* == .GenericInstance) {
                                    s_variant = l_base;
                                    break;
                                }
                                curr = u.right;
                            },
                            .Pointer => |p| curr = p,
                            else => break,
                        }
                    }
                    if (s_variant) |sv| base_rt = sv;
                }
                var type_name: []const u8 = "";
                if (base_rt.* == .Custom) {
                    type_name = base_rt.Custom;
                } else if (base_rt.* == .GenericInstance) {
                    type_name = base_rt.GenericInstance.base_name;
                }
                var s_info_opt = structs.get(type_name);
                if (s_info_opt == null and get.resolved_c_name != null) {
                    type_name = get.resolved_c_name.?;
                    s_info_opt = structs.get(type_name);
                }
                if (s_info_opt == null and get.object.data == .as_expr) {
                    type_name = get.object.data.as_expr.type_ref.name;
                    s_info_opt = structs.get(type_name);
                }
                if (s_info_opt == null and type_name.len > 0) {
                    const suffix = try std.fmt.allocPrint(std.heap.page_allocator, "_{s}", .{type_name});
                    defer std.heap.page_allocator.free(suffix);
                    const suffix_type = try std.fmt.allocPrint(std.heap.page_allocator, "_{s}_type", .{type_name});
                    defer std.heap.page_allocator.free(suffix_type);
                    const type_suffix = try std.fmt.allocPrint(std.heap.page_allocator, "{s}_type", .{type_name});
                    defer std.heap.page_allocator.free(type_suffix);
                    var it = structs.iterator();
                    while (it.next()) |entry| {
                        const k = entry.key_ptr.*;
                        if (std.mem.endsWith(u8, k, suffix) or std.mem.endsWith(u8, k, suffix_type) or std.mem.eql(u8, k, type_suffix) or std.mem.endsWith(u8, k, type_name) or std.mem.eql(u8, k, type_name)) {
                            s_info_opt = entry.value_ptr.*;
                            break;
                        }
                    }
                }
                if (s_info_opt) |s_info| {
                    if (s_info.field_names.len == 3 and std.mem.eql(u8, s_info.field_names[1], "ordinal") and std.mem.eql(u8, s_info.field_names[2], "name")) {
                        if (std.mem.eql(u8, get.name, "toString")) {
                            const real_obj = if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(obj_val)) == llvm.LLVMStructTypeKind)
                                llvm.LLVMBuildExtractValue(builder, obj_val, 0, "fat_obj_ptr")
                            else
                                obj_val;
                            const field_ptr = llvm.LLVMBuildStructGEP2(builder, s_info.struct_type, real_obj, 2, "enum_name_ptr");
                            return llvm.LLVMBuildLoad2(builder, s_info.field_types[2], field_ptr, "enum_name_val");
                        }
                        if (std.mem.eql(u8, get.name, "hashCode")) {
                            const real_obj = if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(obj_val)) == llvm.LLVMStructTypeKind)
                                llvm.LLVMBuildExtractValue(builder, obj_val, 0, "fat_obj_ptr")
                            else
                                obj_val;
                            const field_ptr = llvm.LLVMBuildStructGEP2(builder, s_info.struct_type, real_obj, 1, "enum_ord_ptr");
                            return llvm.LLVMBuildLoad2(builder, s_info.field_types[1], field_ptr, "enum_ord_val");
                        }
                    }
                    for (s_info.field_names, 0..) |f_name, f_idx| {
                        if (std.mem.eql(u8, f_name, get.name)) {
                            const field_name_z = try std.heap.page_allocator.dupeZ(u8, f_name);
                            defer std.heap.page_allocator.free(field_name_z);

                            const real_obj = if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(obj_val)) == llvm.LLVMStructTypeKind)
                                llvm.LLVMBuildExtractValue(builder, obj_val, 0, "fat_obj_ptr")
                            else
                                obj_val;

                            if (get.is_safe) {
                                const parent_func = llvm.LLVMGetBasicBlockParent(llvm.LLVMGetInsertBlock(builder));
                                const then_bb = llvm.LLVMAppendBasicBlockInContext(ctx, parent_func, "safe_get_then");
                                const else_bb = llvm.LLVMAppendBasicBlockInContext(ctx, parent_func, "safe_get_else");
                                const merge_bb = llvm.LLVMAppendBasicBlockInContext(ctx, parent_func, "safe_get_merge");

                                const is_null = llvm.LLVMBuildIsNull(builder, real_obj, "is_null");
                                _ = llvm.LLVMBuildCondBr(builder, is_null, else_bb, then_bb);

                                llvm.LLVMPositionBuilderAtEnd(builder, then_bb);
                                const field_ptr = llvm.LLVMBuildStructGEP2(builder, s_info.struct_type, real_obj, @intCast(f_idx), field_name_z.ptr);
                                const field_type = s_info.field_types[f_idx];
                                const val_then = llvm.LLVMBuildLoad2(builder, field_type, field_ptr, "get_val");
                                const then_end_bb = llvm.LLVMGetInsertBlock(builder);
                                _ = llvm.LLVMBuildBr(builder, merge_bb);

                                llvm.LLVMPositionBuilderAtEnd(builder, else_bb);
                                const const_null = llvm.LLVMConstNull(field_type);
                                const else_end_bb = llvm.LLVMGetInsertBlock(builder);
                                _ = llvm.LLVMBuildBr(builder, merge_bb);

                                llvm.LLVMPositionBuilderAtEnd(builder, merge_bb);
                                const phi = llvm.LLVMBuildPhi(builder, field_type, "safe_get_val");
                                var incoming_vals = [_]llvm.LLVMValueRef{ val_then, const_null };
                                var incoming_bbs = [_]llvm.LLVMBasicBlockRef{ then_end_bb, else_end_bb };
                                llvm.LLVMAddIncoming(phi, &incoming_vals, &incoming_bbs, 2);
                                return phi;
                            } else {
                                const field_ptr = llvm.LLVMBuildStructGEP2(builder, s_info.struct_type, real_obj, @intCast(f_idx), field_name_z.ptr);
                                const field_type = s_info.field_types[f_idx];
                                if (get.is_boxed) {
                                    // Boxed field: field holds a ptr to the heap
                                    // value cell (shared mutable capture).
                                    const box_ptr = llvm.LLVMBuildLoad2(builder, field_type, field_ptr, "get_box_ptr");
                                    const val_elem_type = if (node.resolved_type) |res_type|
                                        types_mapping.getLLVMType(ctx, res_type.*)
                                    else
                                        llvm.LLVMInt64TypeInContext(ctx);
                                    return llvm.LLVMBuildLoad2(builder, val_elem_type, box_ptr, "get_boxed_val");
                                }
                                return llvm.LLVMBuildLoad2(builder, field_type, field_ptr, "get_val");
                            }
                        }
                    }
                }
            }
            if (get.object.data == .identifier) {
                const id_name = get.object.data.identifier.name;
                const var_name = try std.fmt.allocPrint(std.heap.page_allocator, "{s}_{s}\x00", .{ id_name, get.name });
                defer std.heap.page_allocator.free(var_name);
                if (llvm.LLVMGetNamedGlobal(mod, var_name.ptr)) |global_var| {
                    const global_type = llvm.LLVMGlobalGetValueType(global_var);
                    return llvm.LLVMBuildLoad2(builder, global_type, global_var, "obj_static_load");
                }
                if (get.object.data.identifier.resolved_c_name) |rcn| {
                    const rcn_var_name = try std.fmt.allocPrint(std.heap.page_allocator, "{s}_{s}\x00", .{ rcn, get.name });
                    defer std.heap.page_allocator.free(rcn_var_name);
                    if (llvm.LLVMGetNamedGlobal(mod, rcn_var_name.ptr)) |global_var| {
                        const global_type = llvm.LLVMGlobalGetValueType(global_var);
                        return llvm.LLVMBuildLoad2(builder, global_type, global_var, "obj_static_load");
                    }
                }
            }
            if (get.object.resolved_type) |obj_rt| {
                const base_obj_rt = ts.extractBaseType(obj_rt);
                const type_name = switch (base_obj_rt.*) {
                    .Custom => |n| n,
                    .GenericInstance => |gi| gi.base_name,
                    else => "",
                };
                if (type_name.len > 0) {
                    const var_name = try std.fmt.allocPrint(std.heap.page_allocator, "{s}_{s}\x00", .{ type_name, get.name });
                    defer std.heap.page_allocator.free(var_name);
                    if (llvm.LLVMGetNamedGlobal(mod, var_name.ptr)) |global_var| {
                        const global_type = llvm.LLVMGlobalGetValueType(global_var);
                        return llvm.LLVMBuildLoad2(builder, global_type, global_var, "obj_static_load");
                    }
                }
            }
            if (core.verbose) std.debug.print("LLVM Debug: PropertyNotFound get.name={s} line={d} col={d} obj.resolved_type={any}\n", .{ get.name, node.line, node.column, if (get.object.resolved_type) |rt| rt.* else null });
            return error.PropertyNotFound;
        },
        .set_expr => |set| {
            // Object static variable assignment: `Env.isLoaded = true` -> global `env_Env_isLoaded`.
            if (set.object.data == .identifier) {
                const obj_c_name = set.object.data.identifier.resolved_c_name orelse set.object.data.identifier.name;
                const global_name = try std.fmt.allocPrint(std.heap.page_allocator, "{s}_{s}\x00", .{ obj_c_name, set.name });
                defer std.heap.page_allocator.free(global_name);
                var g = llvm.LLVMGetNamedGlobal(mod, global_name.ptr);
                if (g == null) {
                    const target_suffix = try std.fmt.allocPrint(std.heap.page_allocator, "_{s}_{s}", .{ obj_c_name, set.name });
                    defer std.heap.page_allocator.free(target_suffix);
                    var glob_it = llvm.LLVMGetFirstGlobal(mod);
                    while (glob_it) |glob| : (glob_it = llvm.LLVMGetNextGlobal(glob)) {
                        const glob_name_ptr = llvm.LLVMGetValueName(glob);
                        const glob_name_s = std.mem.span(glob_name_ptr);
                        if (std.mem.endsWith(u8, glob_name_s, target_suffix) or std.mem.eql(u8, glob_name_s, global_name)) {
                            g = glob;
                            break;
                        }
                    }
                }
                if (g) |global_var| {
                    const val = try emitExpression(ctx, mod, builder, scope, structs, libs, set.value);
                    if (storeValue(val, llvm.LLVMGlobalGetValueType(global_var))) |sv| {
                        _ = llvm.LLVMBuildStore(builder, sv, global_var);
                    }
                    return val;
                }
            }

            const obj_val = try emitExpression(ctx, mod, builder, scope, structs, libs, set.object);
            const val = try emitExpression(ctx, mod, builder, scope, structs, libs, set.value);

            if (set.object.resolved_type) |rt| {
                const base_rt = ts.extractBaseType(rt);
                var type_name: []const u8 = "";
                if (base_rt.* == .Custom) {
                    type_name = base_rt.Custom;
                } else if (base_rt.* == .GenericInstance) {
                    type_name = base_rt.GenericInstance.base_name;
                } else if (base_rt.* == .Pointer and base_rt.Pointer.* == .Custom) {
                    type_name = base_rt.Pointer.Custom;
                } else if (base_rt.* == .Pointer and base_rt.Pointer.* == .GenericInstance) {
                    type_name = base_rt.Pointer.GenericInstance.base_name;
                }
                var s_info_opt = structs.get(type_name);
                if (s_info_opt == null and type_name.len > 0) {
                    const suffix = try std.fmt.allocPrint(std.heap.page_allocator, "_{s}", .{type_name});
                    defer std.heap.page_allocator.free(suffix);
                    const suffix_type = try std.fmt.allocPrint(std.heap.page_allocator, "_{s}_type", .{type_name});
                    defer std.heap.page_allocator.free(suffix_type);
                    const type_suffix = try std.fmt.allocPrint(std.heap.page_allocator, "{s}_type", .{type_name});
                    defer std.heap.page_allocator.free(type_suffix);
                    var it = structs.iterator();
                    while (it.next()) |entry| {
                        const k = entry.key_ptr.*;
                        if (std.mem.endsWith(u8, k, suffix) or std.mem.endsWith(u8, k, suffix_type) or std.mem.eql(u8, k, type_suffix) or std.mem.endsWith(u8, k, type_name) or std.mem.eql(u8, k, type_name)) {
                            s_info_opt = entry.value_ptr.*;
                            break;
                        }
                    }
                }
                if (s_info_opt) |s_info| {
                    for (s_info.field_names, 0..) |f_name, f_idx| {
                        if (std.mem.eql(u8, f_name, set.name)) {
                            const field_name_z = try std.heap.page_allocator.dupeZ(u8, f_name);
                            defer std.heap.page_allocator.free(field_name_z);

                            const field_ptr = llvm.LLVMBuildStructGEP2(builder, s_info.struct_type, obj_val, @intCast(f_idx), field_name_z.ptr);
                            if (set.is_boxed) {
                                // Boxed field: load the box pointer from the
                                // field and store the value through it (shared
                                // mutable capture).
                                const box_ptr = llvm.LLVMBuildLoad2(builder, s_info.field_types[f_idx], field_ptr, "box_ptr_set");
                                const val_elem_type = if (set.value.resolved_type) |res_type|
                                    types_mapping.getLLVMType(ctx, res_type.*)
                                else
                                    llvm.LLVMInt64TypeInContext(ctx);
                                if (storeValue(val, val_elem_type)) |sv| {
                                    _ = llvm.LLVMBuildStore(builder, sv, box_ptr);
                                }
                                return val;
                            }
                            if (storeValue(val, s_info.field_types[f_idx])) |sv| {
                                _ = llvm.LLVMBuildStore(builder, sv, field_ptr);
                            }
                            return val;
                        }
                    }
                }
            }
            return error.PropertyNotFound;
        },
        .array_literal => |arr| {
            const count: i64 = @intCast(arr.elements.len);
            const elem_llvm = arrayLiteralElementLLVMType(ctx, node);
            const elem_stride = arrayElemStride(ctx, elem_llvm);

            // The array is laid out as a raw buffer (header + elements),
            // matching the C transpiler's EiwaArray model. Header is 2 x i64
            // slots (size, capacity); each element occupies `elem_stride`
            // bytes. Allocation goes through the active heap allocator
            // (GC_malloc when prefer_gc_alloc).
            const malloc_func = core.getHeapAllocFn(mod);
            const malloc_type = llvm.LLVMGlobalGetValueType(malloc_func);
            const size_bytes: i64 = 16 + count * elem_stride;
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

            const elem_contract = arrayLiteralElementContractName(node);

            // Store elements
            for (arr.elements, 0..) |elem_node, idx| {
                var elem_val = try emitExpression(ctx, mod, builder, scope, structs, libs, elem_node);
                if (elem_contract.len > 0) {
                    if (elem_node.resolved_type) |ert| {
                        const conc_c_name = switch (ert.*) {
                            .Custom => |n| n,
                            .GenericInstance => |gi| gi.base_name,
                            else => "",
                        };
                        if (conc_c_name.len > 0) {
                            elem_val = coerceToContract(ctx, mod, builder, elem_val, conc_c_name, elem_contract) catch elem_val;
                        }
                    }
                }
                const idx_val = llvm.LLVMConstInt(i64_type, @intCast(idx), 0);
                const elem_ptr_name = try std.heap.page_allocator.dupeZ(u8, "elem_ptr");
                defer std.heap.page_allocator.free(elem_ptr_name);
                const elem_ptr = arrayElemTypedPtr(builder, ctx, arr_ptr, idx_val, elem_llvm, elem_stride, elem_ptr_name.ptr);
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
                                const malloc_fn2 = core.getHeapAllocFn(mod);
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
            var arr_ptr = try emitExpression(ctx, mod, builder, scope, structs, libs, idx_expr.object);
            if (idx_expr.object.resolved_type) |rt| {
                const base_rt = ts.extractBaseType(rt);
                if (base_rt.* == .Custom or base_rt.* == .GenericInstance) {
                    const type_name = if (base_rt.* == .Custom) base_rt.Custom else base_rt.GenericInstance.base_name;
                    var s_info_opt = structs.get(type_name);
                    if (s_info_opt == null) {
                        if (std.mem.lastIndexOfScalar(u8, type_name, '_')) |idx| {
                            s_info_opt = structs.get(type_name[idx + 1 ..]);
                        }
                    }
                    if (s_info_opt) |s_info| {
                        const f0_ptr = llvm.LLVMBuildStructGEP2(builder, s_info.struct_type, arr_ptr, 0, "wrapper_list_ptr");
                        const f0_type = s_info.field_types[0];
                        arr_ptr = llvm.LLVMBuildLoad2(builder, f0_type, f0_ptr, "inner_arr_ptr");
                        // If MutableList -> List, unwrap second layer to NativeArray
                        if (std.mem.indexOf(u8, type_name, "MutableList") != null) {
                            const list_struct_opt = structs.get("List") orelse structs.get("collections_List");
                            if (list_struct_opt) |s2_info| {
                                const f02_ptr = llvm.LLVMBuildStructGEP2(builder, s2_info.struct_type, arr_ptr, 0, "wrapper_list_ptr2");
                                const f02_type = s2_info.field_types[0];
                                arr_ptr = llvm.LLVMBuildLoad2(builder, f02_type, f02_ptr, "inner_arr_ptr2");
                            }
                        }
                    }
                }
            }
            const i_val = try emitExpression(ctx, mod, builder, scope, structs, libs, idx_expr.index);

            const elem_type = arrayElemLLVMType(ctx, idx_expr.object.resolved_type);
            const elem_stride = arrayElemStride(ctx, elem_type);
            const idx_name = try std.heap.page_allocator.dupeZ(u8, "arr_idx_gep");
            defer std.heap.page_allocator.free(idx_name);
            const elem_ptr = arrayElemTypedPtr(builder, ctx, arr_ptr, i_val, elem_type, elem_stride, idx_name.ptr);
            return llvm.LLVMBuildLoad2(builder, elem_type, elem_ptr, "arr_elem_val");
        },
        .index_set_expr => |set_idx| {
            var arr_ptr = try emitExpression(ctx, mod, builder, scope, structs, libs, set_idx.object);
            if (set_idx.object.resolved_type) |rt| {
                const base_rt = ts.extractBaseType(rt);
                if (base_rt.* == .Custom or base_rt.* == .GenericInstance) {
                    const type_name = if (base_rt.* == .Custom) base_rt.Custom else base_rt.GenericInstance.base_name;
                    var s_info_opt = structs.get(type_name);
                    if (s_info_opt == null) {
                        if (std.mem.lastIndexOfScalar(u8, type_name, '_')) |idx| {
                            s_info_opt = structs.get(type_name[idx + 1 ..]);
                        }
                    }
                    if (s_info_opt) |s_info| {
                        const f0_ptr = llvm.LLVMBuildStructGEP2(builder, s_info.struct_type, arr_ptr, 0, "wrapper_list_ptr");
                        const f0_type = s_info.field_types[0];
                        arr_ptr = llvm.LLVMBuildLoad2(builder, f0_type, f0_ptr, "inner_arr_ptr");
                        if (std.mem.indexOf(u8, type_name, "MutableList") != null) {
                            const list_struct_opt = structs.get("List") orelse structs.get("collections_List");
                            if (list_struct_opt) |s2_info| {
                                const f02_ptr = llvm.LLVMBuildStructGEP2(builder, s2_info.struct_type, arr_ptr, 0, "wrapper_list_ptr2");
                                const f02_type = s2_info.field_types[0];
                                arr_ptr = llvm.LLVMBuildLoad2(builder, f02_type, f02_ptr, "inner_arr_ptr2");
                            }
                        }
                    }
                }
            }
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
                    const val_type = llvm.LLVMTypeOf(operand_val);
                    const val_kind = llvm.LLVMGetTypeKind(val_type);
                    if (val_kind == llvm.LLVMIntegerTypeKind) {
                        // Logical NOT always yields a Bool (i1): a condition like
                        // `!rel.contains("..")` must be an i1 branch operand. The
                        // old code zext'd back to the operand width (i64), so an
                        // `if (!x)` produced `br i64` — invalid IR.
                        return llvm.LLVMBuildICmp(builder, llvm.LLVMIntEQ, operand_val, llvm.LLVMConstInt(val_type, 0, 0), "is_zero");
                    }
                    return llvm.LLVMBuildNot(builder, operand_val, "nottmp");
                },
                .bang_bang => {
                    const val_kind = llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(operand_val));
                    if (val_kind == llvm.LLVMStructTypeKind) {
                        return operand_val;
                    }
                    const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
                    const not_null = llvm.LLVMBuildICmp(builder, llvm.LLVMIntNE, operand_val, llvm.LLVMConstNull(ptr_type), "notnull_tmp");
                    return llvm.LLVMBuildSelect(builder, not_null, operand_val, llvm.LLVMConstNull(ptr_type), "notnull_sel");
                },
                else => return error.UnsupportedUnaryOperator,
            }
        },
        .binary_expr => |bin| {
            // Elvis (?:) needs short-circuit: don't evaluate right if left is non-null.
            // Implement as a ternary: left != 0/null ? left : right
            if (bin.op == .elvis) {
                const func_val = llvm.LLVMGetBasicBlockParent(llvm.LLVMGetInsertBlock(builder));
                const lhs_val = try emitExpression(ctx, mod, builder, scope, structs, libs, bin.left);
                const i64_type = llvm.LLVMInt64TypeInContext(ctx);
                const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
                const lhs_kind = llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(lhs_val));
                const not_null = if (lhs_kind == llvm.LLVMStructTypeKind) blk: {
                    const data_ptr = llvm.LLVMBuildExtractValue(builder, lhs_val, 0, "elvis_data");
                    break :blk llvm.LLVMBuildIsNotNull(builder, data_ptr, "elvis_cond");
                } else if (lhs_kind == llvm.LLVMPointerTypeKind)
                    llvm.LLVMBuildICmp(builder, llvm.LLVMIntNE, lhs_val, llvm.LLVMConstNull(ptr_type), "elvis_cond")
                else
                    llvm.LLVMBuildICmp(builder, llvm.LLVMIntNE, lhs_val, llvm.LLVMConstInt(i64_type, 0, 0), "elvis_cond");

                const lhs_end_bb = llvm.LLVMGetInsertBlock(builder);
                const then_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "elvis_nonnull");
                const else_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "elvis_null");
                const merge_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "elvis_merge");
                _ = llvm.LLVMBuildCondBr(builder, not_null, then_bb, else_bb);

                llvm.LLVMPositionBuilderAtEnd(builder, then_bb);
                _ = llvm.LLVMBuildBr(builder, merge_bb);

                llvm.LLVMPositionBuilderAtEnd(builder, else_bb);
                const rhs_val = try emitExpression(ctx, mod, builder, scope, structs, libs, bin.right);
                const rhs_end_bb = llvm.LLVMGetInsertBlock(builder);
                if (llvm.LLVMGetBasicBlockTerminator(rhs_end_bb) == null) {
                    _ = llvm.LLVMBuildBr(builder, merge_bb);
                }

                llvm.LLVMPositionBuilderAtEnd(builder, merge_bb);
                const phi_type = llvm.LLVMTypeOf(lhs_val);
                const phi = llvm.LLVMBuildPhi(builder, phi_type, "elvis_val");
                var incoming_vals = [_]llvm.LLVMValueRef{ lhs_val, rhs_val };
                var incoming_bbs = [_]llvm.LLVMBasicBlockRef{ then_bb, rhs_end_bb };
                llvm.LLVMAddIncoming(phi, &incoming_vals, &incoming_bbs, 2);

                _ = lhs_end_bb;
                return phi;
            }

            if (bin.op == .and_and or bin.op == .or_or) {
                const func_val = llvm.LLVMGetBasicBlockParent(llvm.LLVMGetInsertBlock(builder));
                const left_val = try emitExpression(ctx, mod, builder, scope, structs, libs, bin.left);
                const i1_type = llvm.LLVMInt1TypeInContext(ctx);

                const rhs_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "sc_rhs");
                const merge_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "sc_merge");
                const lhs_bb = llvm.LLVMGetInsertBlock(builder);

                if (bin.op == .and_and) {
                    _ = llvm.LLVMBuildCondBr(builder, left_val, rhs_bb, merge_bb);
                } else {
                    _ = llvm.LLVMBuildCondBr(builder, left_val, merge_bb, rhs_bb);
                }

                llvm.LLVMPositionBuilderAtEnd(builder, rhs_bb);
                const right_val = try emitExpression(ctx, mod, builder, scope, structs, libs, bin.right);
                const rhs_end_bb = llvm.LLVMGetInsertBlock(builder);
                if (llvm.LLVMGetBasicBlockTerminator(rhs_end_bb) == null) {
                    _ = llvm.LLVMBuildBr(builder, merge_bb);
                }

                llvm.LLVMPositionBuilderAtEnd(builder, merge_bb);
                const phi = llvm.LLVMBuildPhi(builder, i1_type, "sc_res");
                const const_val = llvm.LLVMConstInt(i1_type, if (bin.op == .and_and) 0 else 1, 0);
                var incoming_vals = [_]llvm.LLVMValueRef{ const_val, right_val };
                var incoming_bbs = [_]llvm.LLVMBasicBlockRef{ lhs_bb, rhs_end_bb };
                llvm.LLVMAddIncoming(phi, &incoming_vals, &incoming_bbs, 2);
                return phi;
            }


            var left_val = try emitExpression(ctx, mod, builder, scope, structs, libs, bin.left);
            var right_val = try emitExpression(ctx, mod, builder, scope, structs, libs, bin.right);

            // Numeric promotion: `Int op Double` (or the reverse) resolves to a
            // Double in the type checker, so the arithmetic/comparison must run
            // in double precision with the Int operand promoted via SIToFP. Only
            // applies when both operands are numeric — custom-type operators
            // (e.g. `Money * Int` → `.times()`) dispatch via method, not float ops.
            const l_is_double = if (bin.left.resolved_type) |t| (t.* == .Double) else false;
            const r_is_double = if (bin.right.resolved_type) |t| (t.* == .Double) else false;
            const l_is_num = if (bin.left.resolved_type) |t| (t.* == .Int or t.* == .Double) else false;
            const r_is_num = if (bin.right.resolved_type) |t| (t.* == .Int or t.* == .Double) else false;
            const is_double = (l_is_double or r_is_double) and l_is_num and r_is_num;

            if (is_double) {
                const dbl_t = llvm.LLVMDoubleTypeInContext(ctx);
                if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(left_val)) == llvm.LLVMIntegerTypeKind) {
                    left_val = llvm.LLVMBuildSIToFP(builder, left_val, dbl_t, "int2dbl_l");
                }
                if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(right_val)) == llvm.LLVMIntegerTypeKind) {
                    right_val = llvm.LLVMBuildSIToFP(builder, right_val, dbl_t, "int2dbl_r");
                }
            }

            // Nullable/union vs scalar primitive (`Double? == 42.0`, `Int? == 42`,
            // `Bool? == true`): null-check the union before comparing, so `null`
            // never equals a zero scalar. Runs before the ptr→int coercions below.
            if (bin.op == .eq_eq or bin.op == .bang_eq) {
                const nullable_res = try emitNullableScalarCompare(ctx, mod, builder, left_val, right_val, bin.left.resolved_type, bin.right.resolved_type, bin.op == .eq_eq);
                if (nullable_res) |nr| return nr;
            }

            if (bin.op == .plus and (isStringOperand(bin.left) or isStringOperand(bin.right))) {
                const ptr_t = llvm.LLVMPointerTypeInContext(ctx, 0);
                const i64_t = llvm.LLVMInt64TypeInContext(ctx);
                const i8_t = llvm.LLVMInt8TypeInContext(ctx);

                var inst_fields = [_]llvm.LLVMTypeRef{ ptr_t, i64_t };
                const inst_struct_t = llvm.LLVMStructTypeInContext(ctx, &inst_fields, 2, 0);

                if (!isStringOperand(bin.left)) {
                    left_val = try emitValueToString(ctx, mod, builder, left_val, bin.left.resolved_type);
                } else {
                    left_val = coerceArg(builder, left_val, ptr_t);
                }

                if (!isStringOperand(bin.right)) {
                    right_val = try emitValueToString(ctx, mod, builder, right_val, bin.right.resolved_type);
                } else {
                    right_val = coerceArg(builder, right_val, ptr_t);
                }

                var empty_node = ast.ASTNode{
                    .data = .{ .string_literal = "" },
                    .line = bin.left.line,
                    .column = bin.left.column,
                };
                const empty_str_lit = try emitExpression(ctx, mod, builder, scope, structs, libs, &empty_node);
                const safe_left = llvm.LLVMBuildSelect(builder, llvm.LLVMBuildIsNull(builder, left_val, "l_null"), empty_str_lit, left_val, "safe_left");
                const safe_right = llvm.LLVMBuildSelect(builder, llvm.LLVMBuildIsNull(builder, right_val, "r_null"), empty_str_lit, right_val, "safe_right");

                const a_data_ptr = llvm.LLVMBuildStructGEP2(builder, inst_struct_t, safe_left, 0, "a_data_ptr");
                const a_data = llvm.LLVMBuildLoad2(builder, ptr_t, a_data_ptr, "a_data");
                const a_len_ptr = llvm.LLVMBuildStructGEP2(builder, inst_struct_t, safe_left, 1, "a_len_ptr");
                const a_len = llvm.LLVMBuildLoad2(builder, i64_t, a_len_ptr, "a_len");

                const b_data_ptr = llvm.LLVMBuildStructGEP2(builder, inst_struct_t, safe_right, 0, "b_data_ptr");
                const b_data = llvm.LLVMBuildLoad2(builder, ptr_t, b_data_ptr, "b_data");
                const b_len_ptr = llvm.LLVMBuildStructGEP2(builder, inst_struct_t, safe_right, 1, "b_len_ptr");
                const b_len = llvm.LLVMBuildLoad2(builder, i64_t, b_len_ptr, "b_len");

                const total_len = llvm.LLVMBuildAdd(builder, a_len, b_len, "concat_len");
                const total_alloc = llvm.LLVMBuildAdd(builder, total_len, llvm.LLVMConstInt(i64_t, 1, 0), "concat_alloc");

                const gc_func = core.getHeapAllocFn(mod);
                const gc_type = llvm.LLVMGlobalGetValueType(gc_func);
                var gc_args = [_]llvm.LLVMValueRef{total_alloc};
                const buf = llvm.LLVMBuildCall2(builder, gc_type, gc_func, &gc_args, 1, "concat_buf");

                const memcpy_fn = llvm.LLVMGetNamedFunction(mod, "memcpy") orelse blk: {
                    var ps = [_]llvm.LLVMTypeRef{ ptr_t, ptr_t, i64_t };
                    const ft = llvm.LLVMFunctionType(ptr_t, &ps, 3, 0);
                    break :blk llvm.LLVMAddFunction(mod, "memcpy", ft);
                };
                const memcpy_ft = llvm.LLVMGlobalGetValueType(memcpy_fn);

                var mc1_args = [_]llvm.LLVMValueRef{ buf, a_data, a_len };
                _ = llvm.LLVMBuildCall2(builder, memcpy_ft, memcpy_fn, &mc1_args, 3, "mc1");

                var a_len_idx = [_]llvm.LLVMValueRef{a_len};
                const buf_offset = llvm.LLVMBuildGEP2(builder, i8_t, buf, &a_len_idx, 1, "buf_offset");
                var mc2_args = [_]llvm.LLVMValueRef{ buf_offset, b_data, b_len };
                _ = llvm.LLVMBuildCall2(builder, memcpy_ft, memcpy_fn, &mc2_args, 3, "mc2");

                var tot_idx = [_]llvm.LLVMValueRef{total_len};
                const nul_ptr = llvm.LLVMBuildGEP2(builder, i8_t, buf, &tot_idx, 1, "nul_ptr");
                _ = llvm.LLVMBuildStore(builder, llvm.LLVMConstInt(i8_t, 0, 0), nul_ptr);

                // Allocate 16 bytes for core_String { ptr, length }
                var ga16 = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_t, 16, 0)};
                const raw_inst = llvm.LLVMBuildCall2(builder, gc_type, gc_func, &ga16, 1, "str_inst_alloc");
                const inst_ptr = llvm.LLVMBuildBitCast(builder, raw_inst, ptr_t, "str_inst");

                const f0_ptr = llvm.LLVMBuildStructGEP2(builder, inst_struct_t, inst_ptr, 0, "f0_ptr");
                _ = llvm.LLVMBuildStore(builder, buf, f0_ptr);

                const f1_ptr = llvm.LLVMBuildStructGEP2(builder, inst_struct_t, inst_ptr, 1, "f1_ptr");
                _ = llvm.LLVMBuildStore(builder, total_len, f1_ptr);

                return inst_ptr;
            }

            if (!is_double) {
                const l_type = llvm.LLVMTypeOf(left_val);
                const r_type = llvm.LLVMTypeOf(right_val);
                // Pointer arithmetic:
                if (llvm.LLVMGetTypeKind(l_type) == llvm.LLVMPointerTypeKind) {
                    const l_base = if (bin.left.resolved_type) |rt| ts.extractBaseType(rt).* else .Unknown;
                    const r_base = if (bin.right.resolved_type) |rt| ts.extractBaseType(rt).* else .Unknown;
                    const is_l_ptr = l_base == .Pointer or llvm.LLVMGetTypeKind(l_type) == llvm.LLVMPointerTypeKind;
                    const is_r_ptr = r_base == .Pointer;
                    const is_r_int = r_base == .Int or llvm.LLVMGetTypeKind(r_type) == llvm.LLVMIntegerTypeKind;

                    if (is_l_ptr and bin.op == .plus and is_r_int and !is_r_ptr) {
                        const i64_t = llvm.LLVMInt64TypeInContext(ctx);
                        const l_int = llvm.LLVMBuildPtrToInt(builder, left_val, i64_t, "ptr_int");
                        const r_int = coerceArg(builder, right_val, i64_t);
                        const sum = llvm.LLVMBuildAdd(builder, l_int, r_int, "ptr_add");
                        return llvm.LLVMBuildIntToPtr(builder, sum, l_type, "ptr_res");
                    }
                    if (is_l_ptr and bin.op == .minus and is_r_int and !is_r_ptr) {
                        const i64_t = llvm.LLVMInt64TypeInContext(ctx);
                        const l_int = llvm.LLVMBuildPtrToInt(builder, left_val, i64_t, "ptr_int");
                        const r_int = coerceArg(builder, right_val, i64_t);
                        const diff = llvm.LLVMBuildSub(builder, l_int, r_int, "ptr_sub");
                        return llvm.LLVMBuildIntToPtr(builder, diff, l_type, "ptr_res");
                    }
                    if (is_l_ptr and bin.op == .minus and is_r_ptr) {
                        const i64_t = llvm.LLVMInt64TypeInContext(ctx);
                        const l_int = llvm.LLVMBuildPtrToInt(builder, left_val, i64_t, "ptr_l_int");
                        const r_int = llvm.LLVMBuildPtrToInt(builder, right_val, i64_t, "ptr_r_int");
                        return llvm.LLVMBuildSub(builder, l_int, r_int, "ptr_diff");
                    }
                }
                if (llvm.LLVMGetTypeKind(l_type) == llvm.LLVMPointerTypeKind and !isStringOperand(bin.left)) {
                    const m_name: ?[]const u8 = switch (bin.op) {
                        .plus => "plus",
                        .minus => "minus",
                        .star => "times",
                        .slash => "div",
                        else => null,
                    };
                    if (m_name) |mn| {
                        var func_it = llvm.LLVMGetFirstFunction(mod);
                        var target_op_fn: ?llvm.LLVMValueRef = null;
                        const op_suffix = try std.fmt.allocPrint(std.heap.page_allocator, "_{s}", .{mn});
                        defer std.heap.page_allocator.free(op_suffix);
                        while (func_it != null) : (func_it = llvm.LLVMGetNextFunction(func_it.?)) {
                            const f_name_ptr = llvm.LLVMGetValueName(func_it.?);
                            const f_name_s = std.mem.span(f_name_ptr);
                            if (std.mem.endsWith(u8, f_name_s, op_suffix)) {
                                const ft = llvm.LLVMGlobalGetValueType(func_it.?);
                                if (llvm.LLVMCountParamTypes(ft) == 2) {
                                    target_op_fn = func_it.?;
                                    break;
                                }
                            }
                        }
                        if (target_op_fn) |op_fn| {
                            const ft = llvm.LLVMGlobalGetValueType(op_fn);
                            var op_args = [_]llvm.LLVMValueRef{ left_val, right_val };
                            return llvm.LLVMBuildCall2(builder, ft, op_fn, &op_args, 2, "op_res");
                        }
                    }
                }
                // Non-nullable primitive vs null: Int/Bool/Double can never be
                // null. Short-circuit before the ptr→i64 coercion path that
                // converts null_ptr(0) to i64(0), causing `0 != null → false`.
                // NOTE: We only do this for TRULY non-nullable types (Int, Bool, Double).
                // `Null` type and nullable unions are excluded — they CAN be null.
                const left_is_never_null = blk: {
                    if (bin.left.resolved_type) |rt| {
                        break :blk switch (rt.*) {
                            .Int, .Bool, .Double => true,
                            else => false,
                        };
                    }
                    break :blk false;
                };
                const right_is_never_null = blk: {
                    if (bin.right.resolved_type) |rt| {
                        break :blk switch (rt.*) {
                            .Int, .Bool, .Double => true,
                            else => false,
                        };
                    }
                    break :blk false;
                };
                if (bin.right.data == .null_literal and left_is_never_null) {
                    const i1t = llvm.LLVMInt1TypeInContext(ctx);
                    return switch (bin.op) {
                        .eq_eq => llvm.LLVMConstInt(i1t, 0, 0),  // Int == null → false
                        .bang_eq => llvm.LLVMConstInt(i1t, 1, 0), // Int != null → true
                        else => unreachable,
                    };
                }
                if (bin.left.data == .null_literal and right_is_never_null) {
                    const i1t = llvm.LLVMInt1TypeInContext(ctx);
                    return switch (bin.op) {
                        .eq_eq => llvm.LLVMConstInt(i1t, 0, 0),  // null == Int → false
                        .bang_eq => llvm.LLVMConstInt(i1t, 1, 0), // null != Int → true
                        else => unreachable,
                    };
                }
                if (llvm.LLVMGetTypeKind(l_type) == llvm.LLVMPointerTypeKind and llvm.LLVMGetTypeKind(r_type) == llvm.LLVMIntegerTypeKind) {
                    left_val = llvm.LLVMBuildPtrToInt(builder, left_val, r_type, "l_ptr2int");
                } else if (llvm.LLVMGetTypeKind(l_type) == llvm.LLVMIntegerTypeKind and llvm.LLVMGetTypeKind(r_type) == llvm.LLVMPointerTypeKind) {
                    right_val = llvm.LLVMBuildPtrToInt(builder, right_val, l_type, "r_ptr2int");
                }
            }

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
                    const l_is_str = isStringOperand(bin.left);
                    const r_is_str = isStringOperand(bin.right);
                    if ((l_is_str and r_is_str) or bin.left.data == .string_literal or bin.right.data == .string_literal) {
                        const seq_fn = llvm.LLVMGetNamedFunction(mod, "eiwa_string_equals") orelse return error.StringEqualsNotFound;
                        const seq_type = llvm.LLVMGlobalGetValueType(seq_fn);
                        const ptr_t = llvm.LLVMPointerTypeInContext(ctx, 0);
                        var args = [_]llvm.LLVMValueRef{ coerceArg(builder, left_val, ptr_t), coerceArg(builder, right_val, ptr_t) };
                        return llvm.LLVMBuildCall2(builder, seq_type, seq_fn, &args, 2, "streq_tmp");
                    }
                    if (bin.right.data == .null_literal and llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(left_val)) == llvm.LLVMStructTypeKind) {
                        const vt_ptr = llvm.LLVMBuildExtractValue(builder, left_val, 1, "eq_null_vt");
                        const data_ptr = llvm.LLVMBuildExtractValue(builder, left_val, 0, "eq_null_data");
                        const vt_null = llvm.LLVMBuildIsNull(builder, vt_ptr, "vt_null");
                        const data_null = llvm.LLVMBuildIsNull(builder, data_ptr, "data_null");
                        return llvm.LLVMBuildAnd(builder, vt_null, data_null, "eq_null");
                    }
                    if (bin.left.data == .null_literal and llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(right_val)) == llvm.LLVMStructTypeKind) {
                        const vt_ptr = llvm.LLVMBuildExtractValue(builder, right_val, 1, "eq_null_vt");
                        const data_ptr = llvm.LLVMBuildExtractValue(builder, right_val, 0, "eq_null_data");
                        const vt_null = llvm.LLVMBuildIsNull(builder, vt_ptr, "vt_null");
                        const data_null = llvm.LLVMBuildIsNull(builder, data_ptr, "data_null");
                        return llvm.LLVMBuildAnd(builder, vt_null, data_null, "eq_null");
                    }
                    var l_val = left_val;
                    var r_val = right_val;
                    if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(l_val)) == llvm.LLVMStructTypeKind) {
                        l_val = llvm.LLVMBuildExtractValue(builder, l_val, 0, "l_data");
                    }
                    if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(r_val)) == llvm.LLVMStructTypeKind) {
                        r_val = llvm.LLVMBuildExtractValue(builder, r_val, 0, "r_data");
                    }
                    if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(l_val)) == llvm.LLVMPointerTypeKind and llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(r_val)) == llvm.LLVMIntegerTypeKind) {
                        l_val = llvm.LLVMBuildPtrToInt(builder, l_val, llvm.LLVMTypeOf(r_val), "l_int");
                    } else if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(l_val)) == llvm.LLVMIntegerTypeKind and llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(r_val)) == llvm.LLVMPointerTypeKind) {
                        r_val = llvm.LLVMBuildPtrToInt(builder, r_val, llvm.LLVMTypeOf(l_val), "r_int");
                    }
                    {
                        var eq_class: ?[]const u8 = null;
                        if (customEqualsClass(bin.left, mod)) |cn| {
                            eq_class = cn;
                        } else if (customEqualsClass(bin.right, mod)) |cn| {
                            eq_class = cn;
                        }
                        if (eq_class) |cn| {
                            return try emitCustomEquals(ctx, mod, builder, l_val, r_val, cn);
                        }
                    }
                    return llvm.LLVMBuildICmp(builder, llvm.LLVMIntEQ, l_val, r_val, "eqtmp");
                },
                .bang_eq => {
                    if (is_double) return llvm.LLVMBuildFCmp(builder, llvm.LLVMRealUNE, left_val, right_val, "fnetmp");
                    const l_is_str = isStringOperand(bin.left);
                    const r_is_str = isStringOperand(bin.right);
                    if ((l_is_str and r_is_str) or bin.left.data == .string_literal or bin.right.data == .string_literal) {
                        const seq_fn = llvm.LLVMGetNamedFunction(mod, "eiwa_string_equals") orelse return error.StringEqualsNotFound;
                        const seq_type = llvm.LLVMGlobalGetValueType(seq_fn);
                        const ptr_t = llvm.LLVMPointerTypeInContext(ctx, 0);
                        var args = [_]llvm.LLVMValueRef{ coerceArg(builder, left_val, ptr_t), coerceArg(builder, right_val, ptr_t) };
                        const seq_res = llvm.LLVMBuildCall2(builder, seq_type, seq_fn, &args, 2, "streq_tmp");
                        const zero = llvm.LLVMConstInt(llvm.LLVMTypeOf(seq_res), 0, 0);
                        return llvm.LLVMBuildICmp(builder, llvm.LLVMIntEQ, seq_res, zero, "strne_tmp");
                    }
                    if (bin.right.data == .null_literal and llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(left_val)) == llvm.LLVMStructTypeKind) {
                        const vt_ptr = llvm.LLVMBuildExtractValue(builder, left_val, 1, "ne_null_vt");
                        const data_ptr = llvm.LLVMBuildExtractValue(builder, left_val, 0, "ne_null_data");
                        const vt_not_null = llvm.LLVMBuildIsNotNull(builder, vt_ptr, "vt_not_null");
                        const data_not_null = llvm.LLVMBuildIsNotNull(builder, data_ptr, "data_not_null");
                        return llvm.LLVMBuildOr(builder, vt_not_null, data_not_null, "ne_null");
                    }
                    if (bin.left.data == .null_literal and llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(right_val)) == llvm.LLVMStructTypeKind) {
                        const vt_ptr = llvm.LLVMBuildExtractValue(builder, right_val, 1, "ne_null_vt");
                        const data_ptr = llvm.LLVMBuildExtractValue(builder, right_val, 0, "ne_null_data");
                        const vt_not_null = llvm.LLVMBuildIsNotNull(builder, vt_ptr, "vt_not_null");
                        const data_not_null = llvm.LLVMBuildIsNotNull(builder, data_ptr, "data_not_null");
                        return llvm.LLVMBuildOr(builder, vt_not_null, data_not_null, "ne_null");
                    }
                    var l_val = left_val;
                    var r_val = right_val;
                    if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(l_val)) == llvm.LLVMStructTypeKind) {
                        l_val = llvm.LLVMBuildExtractValue(builder, l_val, 0, "l_data");
                    }
                    if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(r_val)) == llvm.LLVMStructTypeKind) {
                        r_val = llvm.LLVMBuildExtractValue(builder, r_val, 0, "r_data");
                    }
                    if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(l_val)) == llvm.LLVMPointerTypeKind and llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(r_val)) == llvm.LLVMIntegerTypeKind) {
                        l_val = llvm.LLVMBuildPtrToInt(builder, l_val, llvm.LLVMTypeOf(r_val), "l_int");
                    } else if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(l_val)) == llvm.LLVMIntegerTypeKind and llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(r_val)) == llvm.LLVMPointerTypeKind) {
                        r_val = llvm.LLVMBuildPtrToInt(builder, r_val, llvm.LLVMTypeOf(l_val), "r_int");
                    }
                    {
                        var eq_class: ?[]const u8 = null;
                        if (customEqualsClass(bin.left, mod)) |cn| {
                            eq_class = cn;
                        } else if (customEqualsClass(bin.right, mod)) |cn| {
                            eq_class = cn;
                        }
                        if (eq_class) |cn| {
                            const eq_res = try emitCustomEquals(ctx, mod, builder, l_val, r_val, cn);
                            const zero = llvm.LLVMConstInt(llvm.LLVMTypeOf(eq_res), 0, 0);
                            return llvm.LLVMBuildICmp(builder, llvm.LLVMIntEQ, eq_res, zero, "custom_ne_tmp");
                        }
                    }
                    return llvm.LLVMBuildICmp(builder, llvm.LLVMIntNE, l_val, r_val, "netmp");
                },
                .and_and => return llvm.LLVMBuildAnd(builder, left_val, right_val, "andtmp"),
                .or_or => return llvm.LLVMBuildOr(builder, left_val, right_val, "ortmp"),
                else => return error.UnsupportedBinaryOperator,
            }
        },
        .lambda_expr => |lam| {
            const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
            const i64_type = llvm.LLVMInt64TypeInContext(ctx);

            // Receiver lambdas (`HTMLBuilder.() -> Void`) receive the receiver
            // as an explicit leading parameter (arg 1 after env), mirroring the
            // C backend `_lambda_...(void* __env, T* this)`. `this` is therefore
            // NOT a capture — it is re-stacked from that parameter.
            const recv_type: ?*const ts.EiwaType = if (node.resolved_type) |rt| blk: {
                if (rt.* == .Function) break :blk rt.Function.receiver;
                break :blk null;
            } else null;

            // --- Step 1: Collect captures ------------------------------------------
            var locals = std.StringHashMap(void).init(std.heap.page_allocator);
            defer locals.deinit();

            // Add explicit params to locals
            for (lam.params) |p| try locals.put(p.name, {});
            // If no params but the type expects one, treat it as `it`
            if (lam.params.len == 0) {
                if (node.resolved_type) |rt| {
                    if (rt.* == .Function and rt.Function.params.len == 1) {
                        try locals.put("it", {});
                    }
                }
            }
            // Receiver is a parameter, never an env capture
            if (recv_type != null) try locals.put("this", {});
            // Add vars declared inside the body
            for (lam.body) |stmt| try collectDeclaredLocalsLLVM(stmt, &locals);

            var captures = compat.ArrayList(CaptureInfo).init(std.heap.page_allocator);
            defer captures.deinit();
            for (lam.body) |stmt| try collectCapturesLLVM(stmt, &locals, &captures, mod, structs, ctx);

            // --- Step 2: Determine param types (excluding env) ----------------------
            var param_types = try std.heap.page_allocator.alloc(llvm.LLVMTypeRef, lam.params.len);
            defer std.heap.page_allocator.free(param_types);
            for (lam.params, 0..) |p, i| {
                if (p.type_ref) |tr| {
                    if (tr.resolved_type) |rt| {
                        param_types[i] = types_mapping.getLLVMTypeWithContracts(ctx, rt.*, global_contracts_ast_ptr);
                        continue;
                    }
                }
                // Infer from the expected Function type: an explicit lambda
                // param like `{ tx -> ... }` bound to `(Connection) -> Void`
                // must get the contract's fat-pointer type, not an i64 fallback
                // (the caller passes a fat pointer for the Connection).
                if (node.resolved_type) |rt| {
                    if (rt.* == .Function and i < rt.Function.params.len) {
                        param_types[i] = types_mapping.getLLVMTypeWithContracts(ctx, rt.Function.params[i].*, global_contracts_ast_ptr);
                        continue;
                    }
                }
                param_types[i] = i64_type;
            }
            // Handle implicit `it` param. `it` exists only when the expected
            // Function type has exactly one parameter; a `() -> Void` lambda has
            // no user params at all (no fat-pointer fallback).
            var it_param_type: ?llvm.LLVMTypeRef = null;
            if (recv_type == null and lam.params.len == 0) {
                if (node.resolved_type) |rt| {
                    if (rt.* == .Function and rt.Function.params.len == 1) {
                        it_param_type = types_mapping.getLLVMTypeWithContracts(ctx, rt.Function.params[0].*, global_contracts_ast_ptr);
                    }
                }
            }
            // Receiver lambda: leading param carries the receiver object pointer
            const recv_param_type: ?llvm.LLVMTypeRef = if (recv_type) |rt|
                types_mapping.getLLVMTypeWithContracts(ctx, rt.*, global_contracts_ast_ptr)
            else
                null;

            var ret_type: llvm.LLVMTypeRef = llvm.LLVMVoidTypeInContext(ctx);
            if (node.resolved_type) |rt| {
                if (rt.* == .Function) {
                    ret_type = types_mapping.getLLVMTypeWithContracts(ctx, rt.Function.return_type.*, global_contracts_ast_ptr);
                }
            }

            // --- Step 3: Build env struct type (only when there are captures) ------
            // For boxed captures the env field is a `ptr` (to the heap value cell),
            // not the value itself — mirroring the C backend `Box_T*` field.
            const has_captures = captures.items.len > 0;
            const ptr_type_for_box = llvm.LLVMPointerTypeInContext(ctx, 0);
            var cap_type_arr = try std.heap.page_allocator.alloc(llvm.LLVMTypeRef, captures.items.len);
            defer std.heap.page_allocator.free(cap_type_arr);
            for (captures.items, 0..) |cap, ci| {
                cap_type_arr[ci] = if (cap.is_boxed) ptr_type_for_box else cap.llvm_type;
            }
            // env_struct_type is only used inside `if (has_captures)` blocks below
            const env_struct_type = llvm.LLVMStructTypeInContext(ctx, cap_type_arr.ptr, @intCast(captures.items.len), 0);

            // --- Step 4: Build LLVM function signature (ptr_env, params...) → ret ---
            const n_user_params = @as(usize, if (recv_param_type != null) 1 else 0) + (if (it_param_type != null) @as(usize, 1) else lam.params.len);
            var full_param_types = try std.heap.page_allocator.alloc(llvm.LLVMTypeRef, 1 + n_user_params);
            defer std.heap.page_allocator.free(full_param_types);
            full_param_types[0] = ptr_type; // env
            var user_param_offset: usize = 1;
            if (recv_param_type) |rpt| {
                full_param_types[user_param_offset] = rpt;
                user_param_offset += 1;
            }
            if (it_param_type) |ipt| {
                full_param_types[user_param_offset] = ipt;
            } else {
                for (param_types, 0..) |pt, idx| full_param_types[user_param_offset + idx] = pt;
            }

            const func_type = llvm.LLVMFunctionType(ret_type, full_param_types.ptr, @intCast(1 + n_user_params), 0);

            // Give each emitted lambda a unique name using a counter approach
            const lam_name_z = blk: {
                const counter = lambdaCounter();
                break :blk try std.fmt.allocPrint(std.heap.page_allocator, "lambda_anon_{d}\x00", .{counter});
            };
            defer std.heap.page_allocator.free(lam_name_z);

            const func_val = llvm.LLVMAddFunction(mod, lam_name_z.ptr, func_type);

            const parent_bb = llvm.LLVMGetInsertBlock(builder);

            // --- Step 5: Emit the lambda body in a new basic block ------------------
            const entry_block = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "entry");
            llvm.LLVMPositionBuilderAtEnd(builder, entry_block);

            var lam_scope = std.StringHashMap(llvm.LLVMValueRef).init(std.heap.page_allocator);
            defer lam_scope.deinit();

            // Re-stack user params (indices 1..)
            var user_param_index: usize = 1;
            if (recv_param_type) |rpt| {
                const recv_val = llvm.LLVMGetParam(func_val, 1);
                const this_alloca = llvm.LLVMBuildAlloca(builder, rpt, "this");
                _ = llvm.LLVMBuildStore(builder, recv_val, this_alloca);
                try lam_scope.put("this", this_alloca);
                user_param_index += 1;
            }
            if (it_param_type != null) {
                const param_val = llvm.LLVMGetParam(func_val, @intCast(user_param_index));
                const p_type = llvm.LLVMTypeOf(param_val);
                const alloca_ptr = llvm.LLVMBuildAlloca(builder, p_type, "it");
                _ = llvm.LLVMBuildStore(builder, param_val, alloca_ptr);
                try lam_scope.put("it", alloca_ptr);
            } else {
                for (lam.params, 0..) |p, i| {
                    const param_val = llvm.LLVMGetParam(func_val, @intCast(user_param_index + i));
                    const p_type = llvm.LLVMTypeOf(param_val);
                    const p_name_z = try std.heap.page_allocator.dupeZ(u8, p.name);
                    defer std.heap.page_allocator.free(p_name_z);
                    const alloca_ptr = llvm.LLVMBuildAlloca(builder, p_type, p_name_z.ptr);
                    _ = llvm.LLVMBuildStore(builder, param_val, alloca_ptr);
                    try lam_scope.put(p.name, alloca_ptr);
                }
            }

            // Re-stack captures from env (param 0)
            if (has_captures) {
                const env_param = llvm.LLVMGetParam(func_val, 0);
                for (captures.items, 0..) |cap, ci| {
                    const cap_name_z = try std.heap.page_allocator.dupeZ(u8, cap.name);
                    defer std.heap.page_allocator.free(cap_name_z);
                    var gep_idx = [_]llvm.LLVMValueRef{
                        llvm.LLVMConstInt(llvm.LLVMInt32TypeInContext(ctx), 0, 0),
                        llvm.LLVMConstInt(llvm.LLVMInt32TypeInContext(ctx), @intCast(ci), 0),
                    };
                    const field_llvm_type = if (cap.is_boxed) llvm.LLVMPointerTypeInContext(ctx, 0) else cap.llvm_type;
                    const field_ptr = llvm.LLVMBuildGEP2(builder, env_struct_type, env_param, &gep_idx, 2, cap_name_z.ptr);
                    if (cap.is_boxed) {
                        // Boxed: env field is a ptr to the heap value cell.
                        // Load the box pointer and store it in a ptr alloca so
                        // identifier reads/writes do double-deref automatically.
                        const box_ptr = llvm.LLVMBuildLoad2(builder, field_llvm_type, field_ptr, "box_ptr");
                        const ptr_alloca = llvm.LLVMBuildAlloca(builder, llvm.LLVMPointerTypeInContext(ctx, 0), cap_name_z.ptr);
                        _ = llvm.LLVMBuildStore(builder, box_ptr, ptr_alloca);
                        try lam_scope.put(cap.name, ptr_alloca);
                    } else {
                        const field_val = llvm.LLVMBuildLoad2(builder, field_llvm_type, field_ptr, "cap_val");
                        const alloca_ptr = llvm.LLVMBuildAlloca(builder, cap.llvm_type, cap_name_z.ptr);
                        _ = llvm.LLVMBuildStore(builder, field_val, alloca_ptr);
                        try lam_scope.put(cap.name, alloca_ptr);
                    }
                }
            }

            // Emit body — special-case the last statement for non-void lambdas:
            // if the body is non-empty and the last stmt is not a return_stmt,
            // treat it as an implicit return expression (mirrors C backend).
            const is_void_ret = llvm.LLVMGetTypeKind(ret_type) == llvm.LLVMVoidTypeKind;
            if (lam.body.len > 0 and !is_void_ret) {
                const last_idx = lam.body.len - 1;
                // Emit all but the last statement normally
                for (lam.body[0..last_idx]) |stmt| {
                    try statement.emitStatement(ctx, mod, builder, func_val, &lam_scope, structs, libs, stmt, null);
                }
                const last = lam.body[last_idx];
                if (last.data == .return_stmt) {
                    // Already a return — emit normally, terminator will be set
                    try statement.emitStatement(ctx, mod, builder, func_val, &lam_scope, structs, libs, last, null);
                } else {
                    // Implicit return: evaluate the expression and return its value
                    const ret_val = try emitExpression(ctx, mod, builder, &lam_scope, structs, libs, last);
                    const r_kind = llvm.LLVMGetTypeKind(ret_type);
                    if (r_kind == llvm.LLVMVoidTypeKind) {
                        _ = llvm.LLVMBuildRetVoid(builder);
                    } else {
                        _ = llvm.LLVMBuildRet(builder, coerceArg(builder, ret_val, ret_type));
                    }
                }
            } else {
                for (lam.body) |stmt| {
                    try statement.emitStatement(ctx, mod, builder, func_val, &lam_scope, structs, libs, stmt, null);
                }
            }

            // Add implicit terminator if needed
            const cur_bb = llvm.LLVMGetInsertBlock(builder);
            if (llvm.LLVMGetBasicBlockTerminator(cur_bb) == null) {
                const r_kind = llvm.LLVMGetTypeKind(ret_type);
                if (r_kind == llvm.LLVMVoidTypeKind) {
                    _ = llvm.LLVMBuildRetVoid(builder);
                } else if (r_kind == llvm.LLVMIntegerTypeKind) {
                    _ = llvm.LLVMBuildRet(builder, llvm.LLVMConstInt(ret_type, 0, 0));
                } else if (r_kind == llvm.LLVMDoubleTypeKind) {
                    _ = llvm.LLVMBuildRet(builder, llvm.LLVMConstReal(ret_type, 0.0));
                } else if (r_kind == llvm.LLVMPointerTypeKind or r_kind == llvm.LLVMStructTypeKind) {
                    _ = llvm.LLVMBuildRet(builder, llvm.LLVMConstNull(ret_type));
                } else {
                    _ = llvm.LLVMBuildRetVoid(builder);
                }
            }

            // --- Step 6: Back in parent_bb, build the closure struct ----------------
            if (parent_bb) |pbb| llvm.LLVMPositionBuilderAtEnd(builder, pbb);

            // Get the active heap allocation function (GC_malloc when
            // prefer_gc_alloc).
            const malloc_fn = core.getHeapAllocFn(mod);
            const malloc_type = llvm.LLVMGlobalGetValueType(malloc_fn);

            // Allocate and fill the env struct
            const env_ptr: llvm.LLVMValueRef = if (has_captures) blk: {
                const env_size = llvm.LLVMSizeOf(env_struct_type);
                var env_alloc_args = [_]llvm.LLVMValueRef{env_size};
                const env_mem = llvm.LLVMBuildCall2(builder, malloc_type, malloc_fn, &env_alloc_args, 1, "env_mem");
                // Fill each field with the current value (or box pointer) from the outer scope.
                for (captures.items, 0..) |cap, ci| {
                    const cap_name_for_scope = cap.name;
                    var gep_idx = [_]llvm.LLVMValueRef{
                        llvm.LLVMConstInt(llvm.LLVMInt32TypeInContext(ctx), 0, 0),
                        llvm.LLVMConstInt(llvm.LLVMInt32TypeInContext(ctx), @intCast(ci), 0),
                    };
                    const field_ptr = llvm.LLVMBuildGEP2(builder, env_struct_type, env_mem, &gep_idx, 2, "env_field");
                    if (cap.is_boxed) {
                        // Boxed capture: store the box pointer in the env field so the lambda
                        // shares the same heap cell as the outer scope.
                        // The outer scope's alloca IS the box-pointer alloca (an alloca(ptr)
                        // whose value is the GC-allocated value cell).
                        const outer_box_ptr: llvm.LLVMValueRef = outer_b: {
                            if (scope.get(cap_name_for_scope)) |alloca| {
                                // alloca holds a ptr to the box — load that ptr
                                break :outer_b llvm.LLVMBuildLoad2(builder, llvm.LLVMPointerTypeInContext(ctx, 0), alloca, "box_ptr_outer");
                            }
                            break :outer_b llvm.LLVMConstNull(llvm.LLVMPointerTypeInContext(ctx, 0));
                        };
                        _ = llvm.LLVMBuildStore(builder, outer_box_ptr, field_ptr);
                    } else {
                        const outer_val: llvm.LLVMValueRef = outer: {
                            if (scope.get(cap_name_for_scope)) |alloca| {
                                const vt = llvm.LLVMTypeOf(alloca);
                                if (llvm.LLVMGetTypeKind(vt) == llvm.LLVMPointerTypeKind) {
                                    break :outer llvm.LLVMBuildLoad2(builder, cap.llvm_type, alloca, "cap_outer");
                                }
                                break :outer alloca;
                            }
                            // Fallback: null/zero for unknown captures
                            break :outer llvm.LLVMConstNull(cap.llvm_type);
                        };
                        _ = llvm.LLVMBuildStore(builder, outer_val, field_ptr);
                    }
                }
                break :blk env_mem;
            } else llvm.LLVMConstNull(ptr_type);

            // Allocate the closure struct { fn_ptr: ptr, env: ptr }
            var closure_field_types = [_]llvm.LLVMTypeRef{ ptr_type, ptr_type };
            const closure_struct_type = llvm.LLVMStructTypeInContext(ctx, &closure_field_types, 2, 0);
            const closure_size = llvm.LLVMSizeOf(closure_struct_type);
            var cl_alloc_args = [_]llvm.LLVMValueRef{closure_size};
            const closure_mem = llvm.LLVMBuildCall2(builder, malloc_type, malloc_fn, &cl_alloc_args, 1, "closure_mem");

            // Store fn_ptr at field 0
            var fn_gep_idx = [_]llvm.LLVMValueRef{
                llvm.LLVMConstInt(llvm.LLVMInt32TypeInContext(ctx), 0, 0),
                llvm.LLVMConstInt(llvm.LLVMInt32TypeInContext(ctx), 0, 0),
            };
            const fn_ptr_field = llvm.LLVMBuildGEP2(builder, closure_struct_type, closure_mem, &fn_gep_idx, 2, "fn_ptr_field");
            _ = llvm.LLVMBuildStore(builder, func_val, fn_ptr_field);

            // Store env_ptr at field 1
            var env_gep_idx = [_]llvm.LLVMValueRef{
                llvm.LLVMConstInt(llvm.LLVMInt32TypeInContext(ctx), 0, 0),
                llvm.LLVMConstInt(llvm.LLVMInt32TypeInContext(ctx), 1, 0),
            };
            const env_ptr_field = llvm.LLVMBuildGEP2(builder, closure_struct_type, closure_mem, &env_gep_idx, 2, "env_ptr_field");
            _ = llvm.LLVMBuildStore(builder, env_ptr, env_ptr_field);

            return closure_mem;
        },
        .call_expr => |call| {
            // `cFunctionPtr(fn)`: emit `&eiwa_cb_<c_name>` — a generated
            // trampoline that forwards to the Eiwa function.
            if (call.c_fn_ptr) |tramp_name| {
                const c_name = tramp_name["eiwa_cb_".len..];
                const c_name_z = try std.heap.page_allocator.dupeZ(u8, c_name);
                defer std.heap.page_allocator.free(c_name_z);
                const target = llvm.LLVMGetNamedFunction(mod, c_name_z.ptr) orelse {
                    return error.CFunctionPtrTargetNotFound;
                };
                const func_type = llvm.LLVMGlobalGetValueType(target);

                const saved_block = llvm.LLVMGetInsertBlock(builder);

                const tramp_z = try std.heap.page_allocator.dupeZ(u8, tramp_name);
                defer std.heap.page_allocator.free(tramp_z);
                const tramp = llvm.LLVMGetNamedFunction(mod, tramp_z.ptr) orelse llvm.LLVMAddFunction(mod, tramp_z.ptr, func_type);
                if (llvm.LLVMCountBasicBlocks(tramp) == 0) {
                    const bb = llvm.LLVMAppendBasicBlockInContext(ctx, tramp, "entry");
                    llvm.LLVMPositionBuilderAtEnd(builder, bb);
                    const param_count: usize = @intCast(llvm.LLVMCountParamTypes(func_type));
                    var arg_vals = try std.heap.page_allocator.alloc(llvm.LLVMValueRef, param_count);
                    defer std.heap.page_allocator.free(arg_vals);
                    for (0..param_count) |i| {
                        arg_vals[i] = llvm.LLVMGetParam(tramp, @intCast(i));
                    }
                    const ret_val = llvm.LLVMBuildCall2(builder, func_type, target, if (param_count > 0) arg_vals.ptr else null, @intCast(param_count), "cb_ret");
                    if (llvm.LLVMGetTypeKind(llvm.LLVMGetReturnType(func_type)) == llvm.LLVMVoidTypeKind) {
                        _ = llvm.LLVMBuildRetVoid(builder);
                    } else {
                        _ = llvm.LLVMBuildRet(builder, ret_val);
                    }
                }

                // Restore the builder to the enclosing function's insertion point.
                llvm.LLVMPositionBuilderAtEnd(builder, saved_block);

                const ptr_t = llvm.LLVMPointerTypeInContext(ctx, 0);
                return llvm.LLVMBuildBitCast(builder, tramp, ptr_t, "cb_ptr");
            }

            if (call.callee.data == .identifier) {
                const callee_name = call.callee.data.identifier.resolved_c_name orelse call.callee.data.identifier.name;

                const callee_z = try std.heap.page_allocator.dupeZ(u8, callee_name);
                defer std.heap.page_allocator.free(callee_z);

                // String constructor: `String(buf)` / `String(buf, len)` builds a
                // length-prefixed string — `[i64 len][data...]` on the GC heap —
                // String(ptr, len) constructor: allocate %core_String { ptr, length } struct (Task 64.11)
                if (std.mem.eql(u8, callee_name, "core_String") or std.mem.eql(u8, callee_name, "String")) {
                    if (call.arguments.len > 0) {
                        const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
                        const i64_type = llvm.LLVMInt64TypeInContext(ctx);
                        var inst_fields = [_]llvm.LLVMTypeRef{ ptr_type, i64_type };
                        const inst_struct_t = llvm.LLVMStructTypeInContext(ctx, &inst_fields, 2, 0);

                        const src_buf = try emitExpression(ctx, mod, builder, scope, structs, libs, call.arguments[0]);
                        var len_val: llvm.LLVMValueRef = undefined;
                        if (call.arguments.len > 1) {
                            len_val = try emitExpression(ctx, mod, builder, scope, structs, libs, call.arguments[1]);
                        } else {
                            const strlen_func = llvm.LLVMGetNamedFunction(mod, "strlen") orelse blk: {
                                var ps = [_]llvm.LLVMTypeRef{ptr_type};
                                const ft = llvm.LLVMFunctionType(i64_type, &ps, 1, 0);
                                break :blk llvm.LLVMAddFunction(mod, "strlen", ft);
                            };
                            const strlen_type = llvm.LLVMGlobalGetValueType(strlen_func);
                            var sargs = [_]llvm.LLVMValueRef{src_buf};
                            len_val = llvm.LLVMBuildCall2(builder, strlen_type, strlen_func, &sargs, 1, "str_ctor_len");
                        }

                        const gc_alloc = core.getHeapAllocFn(mod);
                        const gc_type = llvm.LLVMGlobalGetValueType(gc_alloc);
                        var ga = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, 16, 0)};
                        const raw = llvm.LLVMBuildCall2(builder, gc_type, gc_alloc, &ga, 1, "str_inst");
                        const inst_ptr = llvm.LLVMBuildBitCast(builder, raw, ptr_type, "str_inst_ptr");

                        const f0_ptr = llvm.LLVMBuildStructGEP2(builder, inst_struct_t, inst_ptr, 0, "f0_ptr");
                        _ = llvm.LLVMBuildStore(builder, src_buf, f0_ptr);

                        const f1_ptr = llvm.LLVMBuildStructGEP2(builder, inst_struct_t, inst_ptr, 1, "f1_ptr");
                        _ = llvm.LLVMBuildStore(builder, len_val, f1_ptr);

                        return inst_ptr;
                    }
                }

                // `with(receiver, lambda)` builtin desugaring
                if (std.mem.eql(u8, callee_name, "with") and call.arguments.len == 2) {
                    const receiver_val = try emitExpression(ctx, mod, builder, scope, structs, libs, call.arguments[0]);
                    const lambda_node = call.arguments[1];
                    if (lambda_node.data == .lambda_expr) {
                        const lam = lambda_node.data.lambda_expr;
                        var lam_scope = std.StringHashMap(llvm.LLVMValueRef).init(std.heap.page_allocator);
                        defer lam_scope.deinit();
                        var scope_it = scope.iterator();
                        while (scope_it.next()) |entry| {
                            try lam_scope.put(entry.key_ptr.*, entry.value_ptr.*);
                        }

                        const rec_type = llvm.LLVMTypeOf(receiver_val);
                        const it_alloca = llvm.LLVMBuildAlloca(builder, rec_type, "it");
                        _ = llvm.LLVMBuildStore(builder, receiver_val, it_alloca);
                        try lam_scope.put("it", it_alloca);

                        if (call.arguments[0].resolved_type) |rec_rt| {
                            const is_contract = types_mapping.isContractType(rec_rt.*, global_contracts_ast_ptr);
                            if (is_contract) {
                                // Keep node resolved type intact for it.draw()
                            }
                        }

                        var last_val: llvm.LLVMValueRef = llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(ctx), 0, 0);
                        for (lam.body) |stmt| {
                            if (stmt.data == .return_stmt and stmt.data.return_stmt.value != null) {
                                last_val = try emitExpression(ctx, mod, builder, &lam_scope, structs, libs, stmt.data.return_stmt.value.?);
                            } else {
                                try statement.emitStatement(ctx, mod, builder, llvm.LLVMGetBasicBlockParent(llvm.LLVMGetInsertBlock(builder)), &lam_scope, structs, libs, stmt, null);
                            }
                        }
                        return last_val;
                    }
                }

                // A callee that names a local variable (or parameter) holds a
                // closure value `{ fn_ptr, env }` at runtime, never a function
                // symbol. Skip the named-function lookup below so the dynamic
                // closure invocation path handles it (otherwise a stub declared
                // under the same name — e.g. collections `add` — is called with
                // the wrong signature).
                const callee_is_var = scope.get(callee_name) != null;

                const target_func_init = if (callee_is_var)
                    null
                else if (std.mem.indexOf(u8, callee_name, "randomBytes") != null)
                    llvm.LLVMGetNamedFunction(mod, "eiwa_random_bytes")
                else if (std.mem.indexOf(u8, callee_name, "readByte") != null)
                    llvm.LLVMGetNamedFunction(mod, "eiwa_read_byte")
                else if (std.mem.indexOf(u8, callee_name, "writeByte") != null)
                    llvm.LLVMGetNamedFunction(mod, "eiwa_write_byte")
                else if (std.mem.indexOf(u8, callee_name, "charAt") != null)
                    llvm.LLVMGetNamedFunction(mod, "eiwa_char_at")
                else if (std.mem.indexOf(u8, callee_name, "nowMillis") != null)
                    llvm.LLVMGetNamedFunction(mod, "eiwa_now_millis")
                else
                    llvm.LLVMGetNamedFunction(mod, callee_z.ptr) orelse blk: {
                    const ctor_type_name = try std.fmt.allocPrint(std.heap.page_allocator, "{s}_type\x00", .{callee_name});
                    defer std.heap.page_allocator.free(ctor_type_name);
                    if (llvm.LLVMGetNamedFunction(mod, ctor_type_name.ptr)) |f| break :blk f;

                    const init_name = try std.fmt.allocPrint(std.heap.page_allocator, "{s}_init\x00", .{callee_name});
                    defer std.heap.page_allocator.free(init_name);
                    if (llvm.LLVMGetNamedFunction(mod, init_name.ptr)) |f| break :blk f;

                    const target_suffix = try std.fmt.allocPrint(std.heap.page_allocator, "_{s}", .{callee_name});
                    defer std.heap.page_allocator.free(target_suffix);
                    const init_suffix = try std.fmt.allocPrint(std.heap.page_allocator, "_{s}_init", .{callee_name});
                    defer std.heap.page_allocator.free(init_suffix);

                    var func_it = llvm.LLVMGetFirstFunction(mod);
                    while (func_it) |f| : (func_it = llvm.LLVMGetNextFunction(f)) {
                        const name_ptr = llvm.LLVMGetValueName(f);
                        const f_name = std.mem.span(name_ptr);
                        if (std.mem.endsWith(u8, f_name, target_suffix) or std.mem.endsWith(u8, f_name, init_suffix)) {
                            break :blk f;
                        }
                    }
                    break :blk null;
                };

                const target_func = target_func_init;

                if (target_func) |func_val| {
                    const func_type = llvm.LLVMGlobalGetValueType(func_val);
                    const param_count: usize = @intCast(llvm.LLVMCountParamTypes(func_type));

                    const func_param_types = try std.heap.page_allocator.alloc(llvm.LLVMTypeRef, param_count);
                    defer std.heap.page_allocator.free(func_param_types);
                    if (param_count > 0) {
                        llvm.LLVMGetParamTypes(func_type, func_param_types.ptr);
                    }

                    // Sibling method call: if the target function expects more args
                    // than were provided (e.g. stepTwice() → Wheel_stepTwice(this)),
                    // check if param[0] is a ptr receiver and inject `this` from scope.
                    const needs_this_inject = blk: {
                        if (param_count > call.arguments.len and param_count > 0) {
                            if (llvm.LLVMGetTypeKind(func_param_types[0]) == llvm.LLVMPointerTypeKind) {
                                if (scope.get("this") != null) break :blk true;
                            }
                        }
                        break :blk false;
                    };
                    const arg_offset: usize = if (needs_this_inject) 1 else 0;
                    const total_args = @max(call.arguments.len + arg_offset, param_count);

                    var arg_vals = try std.heap.page_allocator.alloc(llvm.LLVMValueRef, total_args);
                    defer std.heap.page_allocator.free(arg_vals);

                    if (needs_this_inject) {
                        // Load this from the alloca in scope
                        const this_alloca = scope.get("this").?;
                        arg_vals[0] = llvm.LLVMBuildLoad2(builder, llvm.LLVMTypeOf(this_alloca), this_alloca, "sibling_this");
                    }

                    for (call.arguments, 0..) |arg_node, idx| {
                        var arg_val = try emitExpression(ctx, mod, builder, scope, structs, libs, arg_node);
                        const p_idx = idx + arg_offset;
                        if (p_idx < param_count) {
                            const expected_type = func_param_types[p_idx];
                            if (llvm.LLVMGetTypeKind(expected_type) == llvm.LLVMStructTypeKind) {
                                // Target parameter is a Fat Pointer { ptr data, ptr vtable }
                                if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(arg_val)) != llvm.LLVMStructTypeKind) {
                                    if (arg_node.resolved_type) |arg_rt| {
                                        const arg_c_name = switch (ts.extractBaseType(arg_rt).*) {
                                            .Custom => |n| n,
                                            .GenericInstance => |gi| gi.base_name,
                                            .Int => "core_Int",
                                            .Double => "core_Double",
                                            .Bool => "core_Bool",
                                            .String => "core_String",
                                            .Pointer => "core_Pointer",
                                            else => "",
                                        };
                                        // Target contract name (from callee AST parameter if available)
                                        var contract_c_name: []const u8 = "";
                                        if (arg_node.expected_type) |et| {
                                            const ebase = ts.extractBaseType(et);
                                            if (ebase.* == .Custom) contract_c_name = ebase.Custom;
                                        }
                                        if (contract_c_name.len == 0) {
                                            if (call.callee.resolved_type) |crt| {
                                                if (crt.* == .Function and idx < crt.Function.params.len) {
                                                    switch (crt.Function.params[idx].*) {
                                                        .Custom => |n| contract_c_name = n,
                                                        .GenericInstance => |gi| contract_c_name = gi.base_name,
                                                        else => {},
                                                    }
                                                }
                                            }
                                        }
                                        if (arg_c_name.len > 0) {
                                            if (contract_c_name.len == 0) {
                                                if (global_contracts_ast_ptr) |ca| {
                                                    var it = ca.iterator();
                                                    while (it.next()) |entry| {
                                                        const c_name = entry.key_ptr.*;
                                                        const test_fat = coerceToContractChecked(ctx, mod, builder, arg_val, arg_c_name, c_name) catch continue;
                                                        if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(test_fat)) == llvm.LLVMStructTypeKind) {
                                                             arg_val = test_fat;
                                                             break;
                                                        }
                                                    }
                                                }
                                            } else {
                                                arg_val = try coerceToContract(ctx, mod, builder, arg_val, arg_c_name, contract_c_name);
                                            }
                                        }
                                    }
                                }
                                if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(arg_val)) != llvm.LLVMStructTypeKind) {
                                    arg_val = coerceArg(builder, arg_val, expected_type);
                                }
                            } else {
                                arg_val = coerceArg(builder, arg_val, expected_type);
                            }
                        }
                        arg_vals[p_idx] = arg_val;
                    }

                    const provided_total = call.arguments.len + arg_offset;
                    for (provided_total..total_args) |idx| {
                        const expected_type = if (idx < param_count) func_param_types[idx] else llvm.LLVMPointerTypeInContext(ctx, 0);
                        if (llvm.LLVMGetTypeKind(expected_type) == llvm.LLVMPointerTypeKind) {
                            const def_str = llvm.LLVMBuildGlobalStringPtr(builder, "Assertion failed", "default_str");
                            arg_vals[idx] = try wrapStringWithHeader(ctx, mod, builder, def_str, "assert_str");
                        } else {
                            arg_vals[idx] = llvm.LLVMConstNull(expected_type);
                        }
                    }

                    return llvm.LLVMBuildCall2(
                        builder,
                        func_type,
                        func_val,
                        if (arg_vals.len > 0) arg_vals.ptr else null,
                        @intCast(arg_vals.len),
                        if (llvm.LLVMGetTypeKind(llvm.LLVMGetReturnType(func_type)) == llvm.LLVMVoidTypeKind) "" else "calltmp",
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
                                const func_type = llvm.LLVMGlobalGetValueType(func_val);
                                const param_count = llvm.LLVMCountParamTypes(func_type);
                                const func_param_types = try std.heap.page_allocator.alloc(llvm.LLVMTypeRef, param_count);
                                defer std.heap.page_allocator.free(func_param_types);
                                llvm.LLVMGetParamTypes(func_type, func_param_types.ptr);

                                const total_args = @max(call.arguments.len, param_count);
                                var arg_vals = try std.heap.page_allocator.alloc(llvm.LLVMValueRef, total_args);
                                defer std.heap.page_allocator.free(arg_vals);

                                for (call.arguments, 0..) |arg_node, idx| {
                                    var arg_val = try emitExpression(ctx, mod, builder, scope, structs, libs, arg_node);
                                    if (arg_node.resolved_type) |art| {
                                        const art_base = ts.extractBaseType(art).*;
                                        if (art_base == .String or (art_base == .Custom and (std.mem.eql(u8, art_base.Custom, "String") or std.mem.eql(u8, art_base.Custom, "core_String")))) {
                                            const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
                                            const i64_type = llvm.LLVMInt64TypeInContext(ctx);
                                            var inst_fields = [_]llvm.LLVMTypeRef{ ptr_type, i64_type };
                                            const inst_struct_t = llvm.LLVMStructTypeInContext(ctx, &inst_fields, 2, 0);
                                            const f0_ptr = llvm.LLVMBuildStructGEP2(builder, inst_struct_t, arg_val, 0, "ffi_str_ptr");
                                            arg_val = llvm.LLVMBuildLoad2(builder, ptr_type, f0_ptr, "ffi_char_ptr");
                                        }
                                    }
                                    if (idx < param_count) {
                                        arg_val = coerceArg(builder, arg_val, func_param_types[idx]);
                                    }
                                    arg_vals[idx] = arg_val;
                                }

                                for (call.arguments.len..total_args) |idx| {
                                    const expected_type = if (idx < param_count) func_param_types[idx] else llvm.LLVMPointerTypeInContext(ctx, 0);
                                    arg_vals[idx] = llvm.LLVMConstNull(expected_type);
                                }

                                return llvm.LLVMBuildCall2(
                                    builder,
                                    func_type,
                                    func_val,
                                    if (arg_vals.len > 0) arg_vals.ptr else null,
                                    @intCast(arg_vals.len),
                                    if (llvm.LLVMGetTypeKind(llvm.LLVMGetReturnType(func_type)) == llvm.LLVMVoidTypeKind) "" else "ffitmp",
                                );
                            }
                        }
                    }
                }
            }


            if (call.callee.data == .get_expr) {
                const g = call.callee.data.get_expr;
                if (std.mem.eql(u8, g.name, "toString") and call.arguments.len == 0) {
                    const obj_rt_opt = g.object.resolved_type orelse blk: {
                        if (call.callee.resolved_type) |crt| {
                            if (crt.* == .Function) {
                                if (crt.Function.receiver != null) break :blk crt.Function.receiver.?;
                            }
                        }
                        break :blk null;
                    };
                    if (obj_rt_opt) |obj_rt| {
                        const base_obj = ts.extractBaseType(obj_rt).*;
                        if (base_obj == .String or (base_obj == .Custom and (std.mem.eql(u8, base_obj.Custom, "String") or std.mem.eql(u8, base_obj.Custom, "core_String")))) {
                            return try emitExpression(ctx, mod, builder, scope, structs, libs, g.object);
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
                            const get_obj = call.callee.data.get_expr.object;
                            const obj_c_name = if (get_obj.data == .identifier) (get_obj.data.identifier.resolved_c_name orelse get_obj.data.identifier.name) else "";
                            var func_val = llvm.LLVMGetNamedFunction(mod, fn_c_name_z.ptr);
                            if (func_val == null and obj_c_name.len > 0) {
                                const target_suffix = try std.fmt.allocPrint(std.heap.page_allocator, "_{s}_{s}", .{ obj_c_name, call.callee.data.get_expr.name });
                                defer std.heap.page_allocator.free(target_suffix);
                                var fn_it = llvm.LLVMGetFirstFunction(mod);
                                while (fn_it) |f| : (fn_it = llvm.LLVMGetNextFunction(f)) {
                                    const f_name_ptr = llvm.LLVMGetValueName(f);
                                    const f_name_s = std.mem.span(f_name_ptr);
                                    if (std.mem.endsWith(u8, f_name_s, target_suffix)) {
                                        func_val = f;
                                        break;
                                    }
                                }
                            }
                            if (func_val == null and std.mem.endsWith(u8, obj_c_name, "_type")) {
                                const base_obj = obj_c_name[0 .. obj_c_name.len - 5];
                                const base_suffix = try std.fmt.allocPrint(std.heap.page_allocator, "_{s}_{s}", .{ base_obj, call.callee.data.get_expr.name });
                                defer std.heap.page_allocator.free(base_suffix);
                                var fn_it = llvm.LLVMGetFirstFunction(mod);
                                while (fn_it) |f| : (fn_it = llvm.LLVMGetNextFunction(f)) {
                                    const f_name_ptr = llvm.LLVMGetValueName(f);
                                    const f_name_s = std.mem.span(f_name_ptr);
                                    if (std.mem.endsWith(u8, f_name_s, base_suffix)) {
                                        func_val = f;
                                        break;
                                    }
                                }
                            }
                            if (func_val) |f_val| {
                                const func_type = llvm.LLVMGlobalGetValueType(f_val);
                                const param_count = llvm.LLVMCountParamTypes(func_type);
                                const func_param_types = try std.heap.page_allocator.alloc(llvm.LLVMTypeRef, param_count);
                                defer std.heap.page_allocator.free(func_param_types);
                                llvm.LLVMGetParamTypes(func_type, func_param_types.ptr);

                                const has_receiver = if (call.callee.data == .get_expr) (param_count > 0 and call.arguments.len < param_count) else false;
                                const arg_base: usize = if (has_receiver) 1 else 0;

                                const total_args = @max(call.arguments.len + arg_base, param_count);
                                var arg_vals = try std.heap.page_allocator.alloc(llvm.LLVMValueRef, total_args);
                                defer std.heap.page_allocator.free(arg_vals);

                                if (has_receiver) {
                                    const obj_val = try emitExpression(ctx, mod, builder, scope, structs, libs, call.callee.data.get_expr.object);
                                    arg_vals[0] = obj_val;
                                }

                                for (call.arguments, 0..) |arg_node, idx| {
                                    var arg_val = try emitExpression(ctx, mod, builder, scope, structs, libs, arg_node);
                                    if (idx + arg_base < param_count) {
                                        const ptype = func_param_types[idx + arg_base];
                                        // Contract parameter: build the fat pointer
                                        // `{ data, vtable }` for primitive/pointer args
                                        // (e.g. `show(40.0 + 2.0)` inside a receiver
                                        // lambda), mirroring the sibling-method path —
                                        // coerceArg alone would attach a null vtable.
                                        if (llvm.LLVMGetTypeKind(ptype) == llvm.LLVMStructTypeKind and
                                            llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(arg_val)) != llvm.LLVMStructTypeKind)
                                        {
                                            if (arg_node.resolved_type) |arg_rt| {
                                                const arg_c_name = switch (ts.extractBaseType(arg_rt).*) {
                                                    .Custom => |n| n,
                                                    .GenericInstance => |gi| gi.base_name,
                                                    .Int => "core_Int",
                                                    .Double => "core_Double",
                                                    .Bool => "core_Bool",
                                                    .String => "core_String",
                                                    .Pointer => "core_Pointer",
                                                    else => "",
                                                };
                                                if (arg_c_name.len > 0) {
                                                    var contract_c_name: []const u8 = "";
                                                    if (arg_node.expected_type) |et| {
                                                        const ebase = ts.extractBaseType(et);
                                                        if (ebase.* == .Custom) contract_c_name = ebase.Custom;
                                                    }
                                                    if (contract_c_name.len == 0) {
                                                        if (call.callee.resolved_type) |crt| {
                                                            const base_crt = ts.extractBaseType(crt);
                                                            if (base_crt.* == .Function and idx < base_crt.Function.params.len) {
                                                                switch (ts.extractBaseType(base_crt.Function.params[idx]).*) {
                                                                    .Custom => |n| contract_c_name = n,
                                                                    .GenericInstance => |gi| contract_c_name = gi.base_name,
                                                                    else => {},
                                                                }
                                                            }
                                                        }
                                                    }
                                                    if (contract_c_name.len > 0) {
                                                        arg_val = coerceToContract(ctx, mod, builder, arg_val, arg_c_name, contract_c_name) catch arg_val;
                                                    } else if (global_contracts_ast_ptr) |ca| {
                                                        var it = ca.iterator();
                                                        while (it.next()) |entry| {
                                                            const c_name = entry.key_ptr.*;
                                                            const test_fat = coerceToContractChecked(ctx, mod, builder, arg_val, arg_c_name, c_name) catch continue;
                                                            if (llvm.LLVMTypeOf(test_fat) == ptype) {
                                                                arg_val = test_fat;
                                                                break;
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                        arg_val = coerceArg(builder, arg_val, ptype);
                                    }
                                    arg_vals[idx + arg_base] = arg_val;
                                }

                                for (call.arguments.len + arg_base..total_args) |idx| {
                                    const expected_type = if (idx < param_count) func_param_types[idx] else llvm.LLVMPointerTypeInContext(ctx, 0);
                                    arg_vals[idx] = llvm.LLVMConstNull(expected_type);
                                }

                                var call_param_types = try std.heap.page_allocator.alloc(llvm.LLVMTypeRef, total_args);
                                defer std.heap.page_allocator.free(call_param_types);
                                for (arg_vals[0..total_args], 0..) |av, idx| {
                                    call_param_types[idx] = llvm.LLVMTypeOf(av);
                                }
                                const call_func_type = llvm.LLVMFunctionType(
                                    llvm.LLVMGetReturnType(func_type),
                                    call_param_types.ptr,
                                    @intCast(total_args),
                                    0,
                                );

                                return llvm.LLVMBuildCall2(
                                    builder,
                                    call_func_type,
                                    f_val,
                                    if (arg_vals.len > 0) arg_vals.ptr else null,
                                    @intCast(arg_vals.len),
                                    if (llvm.LLVMGetTypeKind(llvm.LLVMGetReturnType(func_type)) == llvm.LLVMVoidTypeKind) "" else "static_tmp",
                                );
                            }
                        }
                    }
                }
            }

            // String concatenation: `+` on String desugars to `.plus()`. In the
            // LLVM backend, String concatenation is emitted directly via inline
            // malloc + strlen + sprintf formatting.
            if (call.callee.data == .get_expr) {
                const g = call.callee.data.get_expr;
                const obj_rt_opt = g.object.resolved_type orelse blk: {
                    if (g.object.resolved_type) |irt| {
                        break :blk irt;
                    }
                    if (g.object.data == .call_expr) {
                        if (g.object.data.call_expr.callee.resolved_type) |crt| {
                            if (crt.* == .Function) {
                                break :blk crt.Function.return_type;
                            }
                        }
                    }
                    if (g.object.data == .identifier) {
                        const id = g.object.data.identifier;
                        if (id.is_class_property) {
                            const cur_parent_fn = llvm.LLVMGetBasicBlockParent(llvm.LLVMGetInsertBlock(builder));
                            const cur_fn_name_ptr = llvm.LLVMGetValueName(cur_parent_fn);
                            const cur_fn_name = std.mem.span(cur_fn_name_ptr);
                            var target_type_name: ?[]const u8 = id.owner_type_c_name;
                            if (target_type_name == null or structs.get(target_type_name.?) == null) {
                                if (std.mem.lastIndexOfScalar(u8, cur_fn_name, '_')) |last_underscore_idx| {
                                    target_type_name = cur_fn_name[0..last_underscore_idx];
                                }
                            }
                            if (target_type_name) |t_name| {
                                if (global_classes_ast_ptr) |ca| {
                                    if (ca.get(t_name)) |c_node| {
                                        for (c_node.data.type_decl.primary_constructor) |prop| {
                                            if (std.mem.eql(u8, prop.name, id.name)) {
                                                const prt = prop.resolved_type orelse prop.type_ref.resolved_type;
                                                if (prt) |p| break :blk p;
                                            }
                                        }
                                        for (c_node.data.type_decl.body_fields) |prop| {
                                            if (std.mem.eql(u8, prop.name, id.name)) {
                                                const prt = prop.resolved_type orelse prop.type_ref.resolved_type;
                                                if (prt) |p| break :blk p;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if (call.callee.resolved_type) |crt| {
                        if (crt.* == .Function) {
                            if (crt.Function.receiver != null) {
                                break :blk crt.Function.receiver.?;
                            }
                        }
                    }
                    break :blk null;
                };


                if (std.mem.eql(u8, g.name, "plus")) {
                    if (obj_rt_opt) |obj_rt| {
                        const obj_base = obj_rt.*;
                        const is_string_plus = obj_base == .String or (obj_base == .Custom and std.mem.eql(u8, obj_base.Custom, "String")) or
                            (obj_base == .Custom and std.mem.eql(u8, obj_base.Custom, "core_String"));
                        if (is_string_plus and call.arguments.len >= 1) {
                            const i64_type = llvm.LLVMInt64TypeInContext(ctx);
                            const i8_type = llvm.LLVMInt8TypeInContext(ctx);
                            const ptr_t = llvm.LLVMPointerTypeInContext(ctx, 0);

                            var inst_fields = [_]llvm.LLVMTypeRef{ ptr_t, i64_type };
                            const inst_struct_t = llvm.LLVMStructTypeInContext(ctx, &inst_fields, 2, 0);

                            var left_val = try emitExpression(ctx, mod, builder, scope, structs, libs, g.object);
                            left_val = coerceArg(builder, left_val, ptr_t);

                            var right_val = try emitExpression(ctx, mod, builder, scope, structs, libs, call.arguments[0]);
                            if (!isStringOperand(call.arguments[0])) {
                                right_val = try emitValueToString(ctx, mod, builder, right_val, call.arguments[0].resolved_type);
                            } else {
                                right_val = coerceArg(builder, right_val, ptr_t);
                            }



                            const left_is_null = llvm.LLVMBuildIsNull(builder, left_val, "l_null");
                            const right_is_null = llvm.LLVMBuildIsNull(builder, right_val, "r_null");

                            var empty_node = ast.ASTNode{
                                .data = .{ .string_literal = "" },
                                .line = g.object.line,
                                .column = g.object.column,
                            };
                            const empty_str_lit = try emitExpression(ctx, mod, builder, scope, structs, libs, &empty_node);
                            const safe_left = llvm.LLVMBuildSelect(builder, left_is_null, empty_str_lit, left_val, "safe_left");
                            const safe_right = llvm.LLVMBuildSelect(builder, right_is_null, empty_str_lit, right_val, "safe_right");

                            const a_data_ptr = llvm.LLVMBuildStructGEP2(builder, inst_struct_t, safe_left, 0, "a_data_ptr");
                            const a_data = llvm.LLVMBuildLoad2(builder, ptr_t, a_data_ptr, "a_data");
                            const a_len_ptr = llvm.LLVMBuildStructGEP2(builder, inst_struct_t, safe_left, 1, "a_len_ptr");
                            const a_len = llvm.LLVMBuildLoad2(builder, i64_type, a_len_ptr, "a_len");

                            const b_data_ptr = llvm.LLVMBuildStructGEP2(builder, inst_struct_t, safe_right, 0, "b_data_ptr");
                            const b_data = llvm.LLVMBuildLoad2(builder, ptr_t, b_data_ptr, "b_data");
                            const b_len_ptr = llvm.LLVMBuildStructGEP2(builder, inst_struct_t, safe_right, 1, "b_len_ptr");
                            const b_len = llvm.LLVMBuildLoad2(builder, i64_type, b_len_ptr, "b_len");

                            const total_len = llvm.LLVMBuildAdd(builder, a_len, b_len, "concat_len");
                            const total_alloc = llvm.LLVMBuildAdd(builder, total_len, llvm.LLVMConstInt(i64_type, 1, 0), "concat_alloc");

                            const gc_func = core.getHeapAllocFn(mod);
                            const gc_type = llvm.LLVMGlobalGetValueType(gc_func);
                            var gc_args = [_]llvm.LLVMValueRef{total_alloc};
                            const buf = llvm.LLVMBuildCall2(builder, gc_type, gc_func, &gc_args, 1, "concat_buf");

                            const memcpy_fn = llvm.LLVMGetNamedFunction(mod, "memcpy") orelse blk: {
                                var ps = [_]llvm.LLVMTypeRef{ ptr_t, ptr_t, i64_type };
                                const ft = llvm.LLVMFunctionType(ptr_t, &ps, 3, 0);
                                break :blk llvm.LLVMAddFunction(mod, "memcpy", ft);
                            };
                            const memcpy_ft = llvm.LLVMGlobalGetValueType(memcpy_fn);

                            var mc1_args = [_]llvm.LLVMValueRef{ buf, a_data, a_len };
                            _ = llvm.LLVMBuildCall2(builder, memcpy_ft, memcpy_fn, &mc1_args, 3, "mc1");

                            var a_len_idx = [_]llvm.LLVMValueRef{a_len};
                            const buf_offset = llvm.LLVMBuildGEP2(builder, i8_type, buf, &a_len_idx, 1, "buf_offset");
                            var mc2_args = [_]llvm.LLVMValueRef{ buf_offset, b_data, b_len };
                            _ = llvm.LLVMBuildCall2(builder, memcpy_ft, memcpy_fn, &mc2_args, 3, "mc2");

                            var tot_idx = [_]llvm.LLVMValueRef{total_len};
                            const nul_ptr = llvm.LLVMBuildGEP2(builder, i8_type, buf, &tot_idx, 1, "nul_ptr");
                            _ = llvm.LLVMBuildStore(builder, llvm.LLVMConstInt(i8_type, 0, 0), nul_ptr);

                            // Allocate 16 bytes for core_String { ptr, length }
                            var ga16 = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, 16, 0)};
                            const raw_inst = llvm.LLVMBuildCall2(builder, gc_type, gc_func, &ga16, 1, "str_inst_alloc");
                            const inst_ptr = llvm.LLVMBuildBitCast(builder, raw_inst, ptr_t, "str_inst");

                            const f0_ptr = llvm.LLVMBuildStructGEP2(builder, inst_struct_t, inst_ptr, 0, "f0_ptr");
                            _ = llvm.LLVMBuildStore(builder, buf, f0_ptr);

                            const f1_ptr = llvm.LLVMBuildStructGEP2(builder, inst_struct_t, inst_ptr, 1, "f1_ptr");
                            _ = llvm.LLVMBuildStore(builder, total_len, f1_ptr);

                            return inst_ptr;
                        }
                    }
                }


                if (std.mem.eql(u8, g.name, "hashCode") and call.arguments.len == 0) {
                    if (obj_rt_opt) |obj_rt| {
                        const base_obj = ts.extractBaseType(obj_rt).*;
                        if (base_obj == .Int) {
                            return try emitExpression(ctx, mod, builder, scope, structs, libs, g.object);
                        } else if (base_obj == .Bool) {
                            const b_val = try emitExpression(ctx, mod, builder, scope, structs, libs, g.object);
                            return llvm.LLVMBuildZExt(builder, b_val, llvm.LLVMInt64TypeInContext(ctx), "bool_hash");
                        } else if (base_obj == .Double) {
                            const d_val = try emitExpression(ctx, mod, builder, scope, structs, libs, g.object);
                            return llvm.LLVMBuildBitCast(builder, d_val, llvm.LLVMInt64TypeInContext(ctx), "double_hash");
                        }
                    }
                }

                if (obj_rt_opt) |obj_rt| {
                    var handled_vtable = false;
                    if (types_mapping.isContractType(obj_rt.*, global_contracts_ast_ptr)) {
                        // Contract method dispatch (Task 61.3): Fat Pointer { data_ptr, vtable_ptr }
                        const base_obj_rt = ts.extractBaseType(obj_rt);
                        var contract_name = switch (base_obj_rt.*) {
                            .Custom => |n| n,
                            .GenericInstance => |gi| gi.base_name,
                            else => "",
                        };
                        if (std.mem.eql(u8, g.name, "message")) {
                            contract_name = "Throwable";
                        }
                        var contract_node = if (global_contracts_ast_ptr) |ca| ca.get(contract_name) else null;
                        if (contract_node == null and global_contracts_ast_ptr != null) {
                            const ca = global_contracts_ast_ptr.?;
                            if (std.mem.indexOfScalar(u8, contract_name, '_')) |idx| {
                                contract_node = ca.get(contract_name[0..idx]);
                            }
                            if (contract_node == null) {
                                if (std.mem.lastIndexOfScalar(u8, contract_name, '_')) |idx| {
                                    contract_node = ca.get(contract_name[idx + 1 ..]);
                                }
                            }
                        }
                        if (contract_node) |cnode| {
                            if (cnode.data == .contract_decl) {
                                handled_vtable = true;
                                const c_decl = cnode.data.contract_decl;
                                var method_idx: ?usize = null;
                                var target_fun_decl: ?*ast.ASTNode = null;

                                var fun_idx: usize = 0;
                                for (c_decl.methods) |cm| {
                                    if (cm.data == .fun_decl) {
                                        if (std.mem.eql(u8, cm.data.fun_decl.name, g.name)) {
                                            method_idx = fun_idx;
                                            target_fun_decl = cm;
                                            break;
                                        }
                                        fun_idx += 1;
                                    }
                                }

                            if (method_idx) |m_idx| {
                                // Every vtable for this contract has the same layout
                                // (a struct of N fn pointers), so derive its LLVM type
                                // from the contract methods — works for both constant
                                // globals and runtime-loaded vtable pointers.
                                var vtable_fn_count: usize = 0;
                                for (c_decl.methods) |cm| {
                                    if (cm.data == .fun_decl) vtable_fn_count += 1;
                                }
                                const vtable_ptr_arr = try std.heap.page_allocator.alloc(llvm.LLVMTypeRef, vtable_fn_count);
                                defer std.heap.page_allocator.free(vtable_ptr_arr);
                                for (vtable_ptr_arr) |*p| p.* = llvm.LLVMPointerTypeInContext(ctx, 0);
                                const vtable_llvm_type = llvm.LLVMStructTypeInContext(ctx, vtable_ptr_arr.ptr, @intCast(vtable_fn_count), 0);

                                const fat_ptr = try emitExpression(ctx, mod, builder, scope, structs, libs, g.object);
                                const data_ptr = if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(fat_ptr)) == llvm.LLVMStructTypeKind)
                                    llvm.LLVMBuildExtractValue(builder, fat_ptr, 0, "fat_data")
                                else
                                    fat_ptr;

                                const i64_type = llvm.LLVMInt64TypeInContext(ctx);

                                const fun_data = target_fun_decl.?.data.fun_decl;
                                // Prefer the CALL's resolved return type: the
                                // contract method may declare a generic return
                                // (`Awaitable.await(): T`) that would map to a
                                // raw `ptr` here, but the concrete call returns
                                // e.g. `Int` (i64). Fall back to the declared
                                // method type only when the call isn't resolved.
                                const ret_t = if (node.resolved_type) |crt|
                                    types_mapping.getLLVMTypeWithContracts(ctx, crt.*, global_contracts_ast_ptr)
                                else if (target_fun_decl.?.resolved_type) |rt|
                                    types_mapping.getLLVMTypeWithContracts(ctx, rt.Function.return_type.*, global_contracts_ast_ptr)
                                else if (fun_data.type_ref) |tr|
                                    (if (tr.resolved_type) |rrt| types_mapping.getLLVMTypeWithContracts(ctx, rrt.*, global_contracts_ast_ptr) else i64_type)
                                else
                                    i64_type;

                                const emit_dispatch = struct {
                                    fn run(
                                        c_ctx: llvm.LLVMContextRef,
                                        c_mod: llvm.LLVMModuleRef,
                                        c_builder: llvm.LLVMBuilderRef,
                                        c_scope: *std.StringHashMap(llvm.LLVMValueRef),
                                        c_structs: *std.StringHashMap(core.StructInfo),
                                        c_libs: *const std.StringHashMap(std.StringHashMap([]const u8)),
                                        c_fat_ptr: llvm.LLVMValueRef,
                                        c_data_ptr: llvm.LLVMValueRef,
                                        c_vtable_t: llvm.LLVMTypeRef,
                                        c_m_idx: usize,
                                        c_target_fun_decl: *ast.ASTNode,
                                        c_ret_t: llvm.LLVMTypeRef,
                                        c_call: anytype,
                                    ) !llvm.LLVMValueRef {
                                        const c_ptr_type = llvm.LLVMPointerTypeInContext(c_ctx, 0);
                                        const c_vtable_ptr = if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(c_fat_ptr)) == llvm.LLVMStructTypeKind)
                                            llvm.LLVMBuildExtractValue(c_builder, c_fat_ptr, 1, "fat_vtable")
                                        else if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(c_fat_ptr)) == llvm.LLVMPointerTypeKind) blk: {
                                            const fat_t = types_mapping.getFatPointerType(c_ctx);
                                            const loaded_fat = llvm.LLVMBuildLoad2(c_builder, fat_t, c_fat_ptr, "fat_ptr_load");
                                            break :blk llvm.LLVMBuildExtractValue(c_builder, loaded_fat, 1, "fat_vtable");
                                        } else
                                            llvm.LLVMConstNull(c_ptr_type);

                                        const c_real_data_ptr = if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(c_fat_ptr)) == llvm.LLVMStructTypeKind)
                                            llvm.LLVMBuildExtractValue(c_builder, c_fat_ptr, 0, "fat_data")
                                        else if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(c_fat_ptr)) == llvm.LLVMPointerTypeKind) blk: {
                                            const fat_t = types_mapping.getFatPointerType(c_ctx);
                                            const loaded_fat = llvm.LLVMBuildLoad2(c_builder, fat_t, c_fat_ptr, "fat_ptr_load2");
                                            break :blk llvm.LLVMBuildExtractValue(c_builder, loaded_fat, 0, "fat_data");
                                        } else
                                            c_data_ptr;

                                        const c_i64_type = llvm.LLVMInt64TypeInContext(c_ctx);
                                        const parent_func = llvm.LLVMGetBasicBlockParent(llvm.LLVMGetInsertBlock(c_builder));
                                        const vt_ok_bb = llvm.LLVMAppendBasicBlockInContext(c_ctx, parent_func, "vt_ok");
                                        const vt_call_bb = llvm.LLVMAppendBasicBlockInContext(c_ctx, parent_func, "vt_call");
                                        const vt_null_bb = llvm.LLVMAppendBasicBlockInContext(c_ctx, parent_func, "vt_null");
                                        const vt_merge_bb = llvm.LLVMAppendBasicBlockInContext(c_ctx, parent_func, "vt_merge");

                                        // Branch on a null vtable BEFORE touching it — a primitives'
                                        // fat pointer has a null vtable (handled by vt_null), and a
                                        // speculative GEP/load on null would segfault instead.
                                        const is_vt_null = llvm.LLVMBuildIsNull(c_builder, c_vtable_ptr, "is_vt_null");
                                        _ = llvm.LLVMBuildCondBr(c_builder, is_vt_null, vt_null_bb, vt_ok_bb);

                                        llvm.LLVMPositionBuilderAtEnd(c_builder, vt_ok_bb);
                                        // The vtable's layout is a struct of N fn
                                        // pointers. Use the type derived from the
                                        // contract (NOT LLVMGlobalGetValueType, which
                                        // only works when the vtable is a constant
                                        // global — a fat pointer loaded at runtime
                                        // carries a runtime vtable pointer).
                                        const vtable_val_t = c_vtable_t;
                                        const fn_slot_ptr = if (llvm.LLVMGetTypeKind(vtable_val_t) == llvm.LLVMStructTypeKind) blk: {
                                            var gep2_indices = [_]llvm.LLVMValueRef{
                                                llvm.LLVMConstInt(llvm.LLVMInt32TypeInContext(c_ctx), 0, 0),
                                                llvm.LLVMConstInt(llvm.LLVMInt32TypeInContext(c_ctx), @intCast(c_m_idx), 0),
                                            };
                                            break :blk llvm.LLVMBuildGEP2(c_builder, vtable_val_t, c_vtable_ptr, &gep2_indices, 2, "vtable_slot_gep");
                                        } else blk: {
                                            var gep1_indices = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(c_i64_type, @intCast(c_m_idx), 0)};
                                            break :blk llvm.LLVMBuildGEP2(c_builder, c_ptr_type, c_vtable_ptr, &gep1_indices, 1, "vtable_slot_gep");
                                        };
                                        const fn_ptr = llvm.LLVMBuildLoad2(c_builder, c_ptr_type, fn_slot_ptr, "vtable_fn_ptr");

                                        const is_fn_null = llvm.LLVMBuildIsNull(c_builder, fn_ptr, "is_fn_null");
                                        _ = llvm.LLVMBuildCondBr(c_builder, is_fn_null, vt_null_bb, vt_call_bb);

                                        llvm.LLVMPositionBuilderAtEnd(c_builder, vt_call_bb);

                                        var param_types = try std.heap.page_allocator.alloc(llvm.LLVMTypeRef, 1 + c_call.arguments.len);
                                        defer std.heap.page_allocator.free(param_types);
                                        var arg_vals = try std.heap.page_allocator.alloc(llvm.LLVMValueRef, 1 + c_call.arguments.len);
                                        defer std.heap.page_allocator.free(arg_vals);
                                        param_types[0] = c_ptr_type;
                                        arg_vals[0] = c_real_data_ptr;

                                        for (c_call.arguments, 0..) |arg_node, i| {
                                            var arg_val = try emitExpression(c_ctx, c_mod, c_builder, c_scope, c_structs, c_libs, arg_node);
                                            var p_type = if (c_target_fun_decl.resolved_type) |rt|
                                                (if (rt.* == .Function and i < rt.Function.params.len) types_mapping.getLLVMTypeWithContracts(c_ctx, rt.Function.params[i].*, global_contracts_ast_ptr) else llvm.LLVMTypeOf(arg_val))
                                            else
                                                llvm.LLVMTypeOf(arg_val);
                                            if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(arg_val)) == llvm.LLVMStructTypeKind) {
                                                p_type = types_mapping.getFatPointerType(c_ctx);
                                            }
                                            arg_val = coerceArg(c_builder, arg_val, p_type);
                                            param_types[i + 1] = p_type;
                                            arg_vals[i + 1] = arg_val;
                                        }

                                        const dyn_fn_type = llvm.LLVMFunctionType(c_ret_t, param_types.ptr, @intCast(param_types.len), 0);
                                        const call_name: [*c]const u8 = if (llvm.LLVMGetTypeKind(c_ret_t) == llvm.LLVMVoidTypeKind) "" else "vcall_tmp";
                                        const ok_val = llvm.LLVMBuildCall2(c_builder, dyn_fn_type, fn_ptr, arg_vals.ptr, @intCast(arg_vals.len), call_name);
                                        const ok_end_bb = llvm.LLVMGetInsertBlock(c_builder);
                                        _ = llvm.LLVMBuildBr(c_builder, vt_merge_bb);

                                        llvm.LLVMPositionBuilderAtEnd(c_builder, vt_null_bb);
                                        // Primitives (Int/Bool/String as raw tagged values) have no
                                        // static contract vtable, so their fat-pointer vtable slot is
                                        // null. Route toString/hashCode through the runtime helpers
                                        // (small-int tagging + descriptor/string fast paths) — mirrors
                                        // the C backend's eiwa_to_string/eiwa_hash_code.
                                        // Void-returning contract methods have no value to null-fill
                                        // on the null-vtable path (the void merge below ignores
                                        // null_val). LLVMConstNull on a void type hits
                                        // Constant::getNullValue's llvm_unreachable and traps.
                                        var null_val: llvm.LLVMValueRef = if (llvm.LLVMGetTypeKind(c_ret_t) == llvm.LLVMVoidTypeKind)
                                            llvm.LLVMConstNull(llvm.LLVMInt32TypeInContext(c_ctx))
                                        else
                                            llvm.LLVMConstNull(c_ret_t);
                                        const m_name = c_target_fun_decl.data.fun_decl.name;
                                        const c_ptr_t = llvm.LLVMPointerTypeInContext(c_ctx, 0);
                                        if (std.mem.eql(u8, m_name, "toString")) {
                                            var helper = llvm.LLVMGetNamedFunction(c_mod, "eiwa_to_string");
                                            if (helper == null) {
                                                var ps = [_]llvm.LLVMTypeRef{c_ptr_t};
                                                const ft = llvm.LLVMFunctionType(c_ptr_t, &ps, 1, 0);
                                                helper = llvm.LLVMAddFunction(c_mod, "eiwa_to_string", ft);
                                            }
                                            const ft2 = llvm.LLVMGlobalGetValueType(helper.?);
                                            var a = [_]llvm.LLVMValueRef{c_data_ptr};
                                            const vt_str_raw = llvm.LLVMBuildCall2(c_builder, ft2, helper.?, &a, 1, "vt_str_res");
                                            null_val = vt_str_raw;
                                        } else if (std.mem.eql(u8, m_name, "hashCode")) {
                                            var helper = llvm.LLVMGetNamedFunction(c_mod, "eiwa_hash_code");
                                            if (helper == null) {
                                                var ps = [_]llvm.LLVMTypeRef{c_ptr_t};
                                                const ft = llvm.LLVMFunctionType(llvm.LLVMInt64TypeInContext(c_ctx), &ps, 1, 0);
                                                helper = llvm.LLVMAddFunction(c_mod, "eiwa_hash_code", ft);
                                            }
                                            const ft2 = llvm.LLVMGlobalGetValueType(helper.?);
                                            var a = [_]llvm.LLVMValueRef{c_data_ptr};
                                            null_val = llvm.LLVMBuildCall2(c_builder, ft2, helper.?, &a, 1, "vt_hash_res");
                                        }
                                        const null_end_bb = llvm.LLVMGetInsertBlock(c_builder);
                                        _ = llvm.LLVMBuildBr(c_builder, vt_merge_bb);

                                        llvm.LLVMPositionBuilderAtEnd(c_builder, vt_merge_bb);
                                        if (llvm.LLVMGetTypeKind(c_ret_t) == llvm.LLVMVoidTypeKind) {
                                            // Avoid leaving vt_merge unterminated: branch to a
                                            // fresh continuation block where the enclosing function
                                            // keeps emitting. Mirrors coerceArg/fat-pointer handling.
                                            const vt_cont_bb = llvm.LLVMAppendBasicBlockInContext(c_ctx, parent_func, "vt_cont");
                                            _ = llvm.LLVMBuildBr(c_builder, vt_cont_bb);
                                            llvm.LLVMPositionBuilderAtEnd(c_builder, vt_cont_bb);
                                            return ok_val;
                                        }
                                        const phi = llvm.LLVMBuildPhi(c_builder, c_ret_t, "vcall_res");
                                        var incoming_vals = [_]llvm.LLVMValueRef{ ok_val, null_val };
                                        var incoming_bbs = [_]llvm.LLVMBasicBlockRef{ ok_end_bb, null_end_bb };
                                        llvm.LLVMAddIncoming(phi, &incoming_vals, &incoming_bbs, 2);
                                        return phi;
                                    }
                                }.run;

                                if (g.is_safe) {
                                    const parent_func = llvm.LLVMGetBasicBlockParent(llvm.LLVMGetInsertBlock(builder));
                                    const then_bb = llvm.LLVMAppendBasicBlockInContext(ctx, parent_func, "safe_call_then");
                                    const else_bb = llvm.LLVMAppendBasicBlockInContext(ctx, parent_func, "safe_call_else");
                                    const merge_bb = llvm.LLVMAppendBasicBlockInContext(ctx, parent_func, "safe_call_merge");

                                    const data_null = llvm.LLVMBuildIsNull(builder, data_ptr, "is_data_null");
                                    const vt_ptr_val = if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(fat_ptr)) == llvm.LLVMStructTypeKind)
                                        llvm.LLVMBuildExtractValue(builder, fat_ptr, 1, "fat_vtable")
                                    else
                                        llvm.LLVMConstNull(llvm.LLVMPointerTypeInContext(ctx, 0));
                                    const vt_null = llvm.LLVMBuildIsNull(builder, vt_ptr_val, "is_vt_null");
                                    const is_null = llvm.LLVMBuildOr(builder, data_null, vt_null, "is_null");
                                    _ = llvm.LLVMBuildCondBr(builder, is_null, else_bb, then_bb);

                                    llvm.LLVMPositionBuilderAtEnd(builder, then_bb);
                                    const call_val = try emit_dispatch(ctx, mod, builder, scope, structs, libs, fat_ptr, data_ptr, vtable_llvm_type, m_idx, target_fun_decl.?, ret_t, call);
                                    const then_end_bb = llvm.LLVMGetInsertBlock(builder);
                                    _ = llvm.LLVMBuildBr(builder, merge_bb);

                                    llvm.LLVMPositionBuilderAtEnd(builder, else_bb);
                                    const null_val = if (node.resolved_type) |nrt|
                                        types_mapping.getLLVMTypeWithContracts(ctx, nrt.*, global_contracts_ast_ptr)
                                    else
                                        ret_t;
                                    const const_null = if (llvm.LLVMGetTypeKind(null_val) == llvm.LLVMVoidTypeKind)
                                        llvm.LLVMConstNull(llvm.LLVMInt32TypeInContext(ctx))
                                    else
                                        llvm.LLVMConstNull(null_val);
                                    const else_end_bb = llvm.LLVMGetInsertBlock(builder);
                                    _ = llvm.LLVMBuildBr(builder, merge_bb);

                                    llvm.LLVMPositionBuilderAtEnd(builder, merge_bb);
                                    if (llvm.LLVMGetTypeKind(ret_t) == llvm.LLVMVoidTypeKind) {
                                        // Void-returning safe call: there is no value to merge
                                        // across the null-check branches (a phi cannot carry
                                        // void). The call value is discarded; the enclosing
                                        // emitter continues at the merge block.
                                        return call_val;
                                    }
                                    const phi = llvm.LLVMBuildPhi(builder, llvm.LLVMTypeOf(const_null), "safe_call_res");
                                    var incoming_vals = [_]llvm.LLVMValueRef{ call_val, const_null };
                                    var incoming_blocks = [_]llvm.LLVMBasicBlockRef{ then_end_bb, else_end_bb };
                                    llvm.LLVMAddIncoming(phi, &incoming_vals, &incoming_blocks, 2);
                                    return phi;
                                } else {
                                    return try emit_dispatch(ctx, mod, builder, scope, structs, libs, fat_ptr, data_ptr, vtable_llvm_type, m_idx, target_fun_decl.?, ret_t, call);
                                }
                            } else {
                                if (std.mem.eql(u8, g.name, "toString")) {
                                    const fat_ptr = try emitExpression(ctx, mod, builder, scope, structs, libs, g.object);
                                    const data_ptr = if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(fat_ptr)) == llvm.LLVMStructTypeKind)
                                        llvm.LLVMBuildExtractValue(builder, fat_ptr, 0, "fat_data")
                                    else
                                        fat_ptr;
                                    var to_str_args = [_]llvm.LLVMValueRef{data_ptr};
                                    const ptr_t = llvm.LLVMPointerTypeInContext(ctx, 0);
                                    var to_str_param_types = [_]llvm.LLVMTypeRef{ptr_t};
                                    const ft = llvm.LLVMFunctionType(ptr_t, &to_str_param_types, 1, 0);
                                    const to_str_fn = llvm.LLVMGetNamedFunction(mod, "eiwa_to_string") orelse llvm.LLVMAddFunction(mod, "eiwa_to_string", ft);
                                    return llvm.LLVMBuildCall2(builder, ft, to_str_fn, &to_str_args, 1, "contract_to_str");
                                }
                                if (std.mem.eql(u8, g.name, "hashCode")) {
                                    const fat_ptr = try emitExpression(ctx, mod, builder, scope, structs, libs, g.object);
                                    const data_ptr = if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(fat_ptr)) == llvm.LLVMStructTypeKind)
                                        llvm.LLVMBuildExtractValue(builder, fat_ptr, 0, "fat_data")
                                    else
                                        fat_ptr;
                                    const i64_t = llvm.LLVMInt64TypeInContext(ctx);
                                    return llvm.LLVMBuildPtrToInt(builder, data_ptr, i64_t, "contract_hash");
                                }
                            }
                            }
                        }
                    }
                    if (!handled_vtable) {
                        var type_name: []const u8 = "";
                        var base_obj_rt = ts.extractBaseType(obj_rt);
                        // A raw `Pointer` receiver (element Void — e.g. the value
                        // returned by gcMalloc) dispatches to the `core_Pointer`
                        // methods. Capture it before the loop below unwraps the
                        // pointer into its element type (Void), which would leave
                        // `type_name` empty and route the call to a stub.
                        const is_raw_pointer = base_obj_rt.* == .Pointer and base_obj_rt.Pointer.* == .Void;
                        while (base_obj_rt.* == .Union or base_obj_rt.* == .Pointer) {
                            if (base_obj_rt.* == .Union) {
                                if (base_obj_rt.Union.left.* != .Null) {
                                    base_obj_rt = ts.extractBaseType(base_obj_rt.Union.left);
                                } else {
                                    base_obj_rt = ts.extractBaseType(base_obj_rt.Union.right);
                                }
                            } else if (base_obj_rt.* == .Pointer) {
                                base_obj_rt = ts.extractBaseType(base_obj_rt.Pointer);
                            }
                        }
                        if (is_raw_pointer) {
                            type_name = "core_Pointer";
                        } else if (base_obj_rt.* == .String or (base_obj_rt.* == .Custom and (std.mem.eql(u8, base_obj_rt.Custom, "String") or std.mem.eql(u8, base_obj_rt.Custom, "core_String")))) {
                            type_name = "core_String";
                        } else if (base_obj_rt.* == .Custom) {
                            type_name = base_obj_rt.Custom;
                        } else if (base_obj_rt.* == .GenericInstance) {
                            type_name = base_obj_rt.GenericInstance.base_name;
                        }
                        if (type_name.len > 0) {
                            if (structs.get(type_name)) |s_info| {
                                if (s_info.field_names.len == 3 and std.mem.eql(u8, s_info.field_names[1], "ordinal") and std.mem.eql(u8, s_info.field_names[2], "name")) {
                                    if (std.mem.eql(u8, g.name, "toString")) {
                                        const obj_val = try emitExpression(ctx, mod, builder, scope, structs, libs, g.object);
                                        const field_ptr = llvm.LLVMBuildStructGEP2(builder, s_info.struct_type, obj_val, 2, "enum_name_ptr");
                                        return llvm.LLVMBuildLoad2(builder, s_info.field_types[2], field_ptr, "enum_name_val");
                                    }
                                    if (std.mem.eql(u8, g.name, "hashCode")) {
                                        const obj_val = try emitExpression(ctx, mod, builder, scope, structs, libs, g.object);
                                        const field_ptr = llvm.LLVMBuildStructGEP2(builder, s_info.struct_type, obj_val, 1, "enum_ord_ptr");
                                        return llvm.LLVMBuildLoad2(builder, s_info.field_types[1], field_ptr, "enum_ord_val");
                                    }
                                }
                            }
                            const method_z = try std.fmt.allocPrint(std.heap.page_allocator, "{s}_{s}\x00", .{ type_name, g.name });
                            defer std.heap.page_allocator.free(method_z);

                            var target_func: ?llvm.LLVMValueRef = null;
                            if (call.callee.resolved_type) |crt| {
                                if (crt.* == .Function and crt.Function.c_name.len > 0) {
                                    const c_name_z = try std.heap.page_allocator.dupeZ(u8, crt.Function.c_name);
                                    defer std.heap.page_allocator.free(c_name_z);
                                    target_func = llvm.LLVMGetNamedFunction(mod, c_name_z.ptr);
                                }
                            }

                            // The type checker records the exact (overload-disambiguated)
                            // symbol on the callee get_expr. Prefer it over the plain
                            // `{type}_{method}` guess so overloaded methods (e.g.
                            // Logger.error with 1 and 2 args) resolve to the right
                            // signature instead of a receiver-less stub.
                            if (target_func == null) {
                                if (g.resolved_c_name) |rcn| {
                                    if (rcn.len > 0) {
                                        const rcn_z = try std.heap.page_allocator.dupeZ(u8, rcn);
                                        defer std.heap.page_allocator.free(rcn_z);
                                        target_func = llvm.LLVMGetNamedFunction(mod, rcn_z.ptr);
                                    }
                                }
                            }

                            if (target_func) |tf| {
                                if (llvm.LLVMIsAFunction(tf) != null) {
                                    const ft = llvm.LLVMGlobalGetValueType(tf);
                                    if (llvm.LLVMCountParamTypes(ft) != 1 + call.arguments.len) {
                                        target_func = null;
                                    }
                                } else {
                                    target_func = null;
                                }
                            }
                            if (target_func == null) {
                                const exact_fn = llvm.LLVMGetNamedFunction(mod, method_z.ptr);
                                if (exact_fn) |ef| {
                                    const ft = llvm.LLVMGlobalGetValueType(ef);
                                    if (llvm.LLVMCountParamTypes(ft) == call.arguments.len or llvm.LLVMCountParamTypes(ft) == 1 + call.arguments.len) {
                                        target_func = ef;
                                    }
                                }
                            }
                            if (target_func == null and type_name.len > 0) {
                                const target_suffix = try std.fmt.allocPrint(std.heap.page_allocator, "_{s}\x00", .{g.name});
                                defer std.heap.page_allocator.free(target_suffix);
                                var fn_it = llvm.LLVMGetFirstFunction(mod);
                                while (fn_it) |f| : (fn_it = llvm.LLVMGetNextFunction(f)) {
                                    const fn_name_ptr = llvm.LLVMGetValueName(f);
                                    const fn_name_s = std.mem.span(fn_name_ptr);
                                    if ((std.mem.startsWith(u8, fn_name_s, type_name) or std.mem.indexOf(u8, fn_name_s, type_name) != null) and std.mem.endsWith(u8, fn_name_s, target_suffix[0 .. target_suffix.len - 1])) {
                                        const ft = llvm.LLVMGlobalGetValueType(f);
                                        if (llvm.LLVMCountParamTypes(ft) == 1 + call.arguments.len or llvm.LLVMCountParamTypes(ft) == call.arguments.len) {
                                            target_func = f;
                                            break;
                                        }
                                    }
                                }
                            }

                            if (target_func) |func_val| {
                                const func_type = llvm.LLVMGlobalGetValueType(func_val);
                                const param_count = llvm.LLVMCountParamTypes(func_type);
                                const func_param_types = try std.heap.page_allocator.alloc(llvm.LLVMTypeRef, param_count);
                                defer std.heap.page_allocator.free(func_param_types);
                                llvm.LLVMGetParamTypes(func_type, func_param_types.ptr);

                                const is_object_call = param_count == call.arguments.len;

                                var arg_vals = try std.heap.page_allocator.alloc(llvm.LLVMValueRef, param_count);
                                defer std.heap.page_allocator.free(arg_vals);

                                var obj_val: llvm.LLVMValueRef = undefined;
                                if (!is_object_call and param_count > 0) {
                                    obj_val = try emitExpression(ctx, mod, builder, scope, structs, libs, g.object);
                                    if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(obj_val)) == llvm.LLVMStructTypeKind) {
                                        obj_val = llvm.LLVMBuildExtractValue(builder, obj_val, 0, "fat_data");
                                    }
                                    arg_vals[0] = coerceArg(builder, obj_val, func_param_types[0]);
                                } else {
                                    obj_val = llvm.LLVMConstNull(llvm.LLVMPointerTypeInContext(ctx, 0));
                                }

                                for (call.arguments, 0..) |arg_node, idx| {
                                    var arg_val = try emitExpression(ctx, mod, builder, scope, structs, libs, arg_node);
                                    const p_idx = if (is_object_call) idx else idx + 1;
                                    if (p_idx < param_count) {
                                        const ptype = func_param_types[p_idx];
                                        if (llvm.LLVMGetTypeKind(ptype) == llvm.LLVMStructTypeKind) {
                                            if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(arg_val)) != llvm.LLVMStructTypeKind) {
                                                if (arg_node.resolved_type) |arg_rt| {
                                                    const arg_c_name = switch (ts.extractBaseType(arg_rt).*) {
                                                        .Custom => |n| n,
                                                        .GenericInstance => |gi| gi.base_name,
                                                        .Int => "core_Int",
                                                        .Double => "core_Double",
                                                        .Bool => "core_Bool",
                                                        .String => "core_String",
                                                        .Pointer => "core_Pointer",
                                                        else => "",
                                                    };
                                                    if (arg_c_name.len > 0) {
                                                        var contract_c_name: []const u8 = "";
                                                        if (arg_node.expected_type) |et| {
                                                            const ebase = ts.extractBaseType(et);
                                                            if (ebase.* == .Custom) contract_c_name = ebase.Custom;
                                                        }
                                                        if (contract_c_name.len == 0) {
                                                            if (call.callee.resolved_type) |crt| {
                                                                const base_crt = ts.extractBaseType(crt);
                                                                if (base_crt.* == .Function and idx < base_crt.Function.params.len) {
                                                                    switch (ts.extractBaseType(base_crt.Function.params[idx]).*) {
                                                                        .Custom => |n| contract_c_name = n,
                                                                        .GenericInstance => |gi| contract_c_name = gi.base_name,
                                                                        else => {},
                                                                    }
                                                                }
                                                            }
                                                        }
                                                        if (contract_c_name.len > 0) {
                                                            arg_val = coerceToContract(ctx, mod, builder, arg_val, arg_c_name, contract_c_name) catch arg_val;
                                                        } else if (global_contracts_ast_ptr) |ca| {
                                                            var it = ca.iterator();
                                                            while (it.next()) |entry| {
                                                                const c_name = entry.key_ptr.*;
                                                                const test_fat = coerceToContractChecked(ctx, mod, builder, arg_val, arg_c_name, c_name) catch continue;
                                                                if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(test_fat)) == llvm.LLVMStructTypeKind) {
                                                                    arg_val = test_fat;
                                                                    break;
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                            if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(arg_val)) != llvm.LLVMStructTypeKind) {
                                                arg_val = coerceArg(builder, arg_val, ptype);
                                            }
                                        } else {
                                            arg_val = coerceArg(builder, arg_val, ptype);
                                        }
                                        arg_vals[p_idx] = arg_val;
                                    }
                                }

                                const provided_count = if (is_object_call) call.arguments.len else call.arguments.len + 1;
                                if (provided_count < param_count) {
                                    for (provided_count..param_count) |p_idx| {
                                        arg_vals[p_idx] = llvm.LLVMConstNull(func_param_types[p_idx]);
                                    }
                                }

                                const ret_t = llvm.LLVMGetReturnType(func_type);

                                if (g.is_safe) {
                                    const parent_func = llvm.LLVMGetBasicBlockParent(llvm.LLVMGetInsertBlock(builder));
                                    const then_bb = llvm.LLVMAppendBasicBlockInContext(ctx, parent_func, "safe_call_then");
                                    const else_bb = llvm.LLVMAppendBasicBlockInContext(ctx, parent_func, "safe_call_else");
                                    const merge_bb = llvm.LLVMAppendBasicBlockInContext(ctx, parent_func, "safe_call_merge");

                                    const ptr_to_check = if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(obj_val)) == llvm.LLVMStructTypeKind)
                                        llvm.LLVMBuildExtractValue(builder, obj_val, 0, "fat_data_ptr")
                                    else
                                        obj_val;
                                    const is_null = llvm.LLVMBuildIsNull(builder, ptr_to_check, "is_null");
                                    _ = llvm.LLVMBuildCondBr(builder, is_null, else_bb, then_bb);

                                    llvm.LLVMPositionBuilderAtEnd(builder, then_bb);
                                    const call_res = llvm.LLVMBuildCall2(
                                        builder,
                                        func_type,
                                        func_val,
                                        if (arg_vals.len > 0) arg_vals.ptr else null,
                                        @intCast(arg_vals.len),
                                        if (llvm.LLVMGetTypeKind(ret_t) == llvm.LLVMVoidTypeKind) "" else "method_tmp",
                                    );
                                    const then_end_bb = llvm.LLVMGetInsertBlock(builder);
                                    _ = llvm.LLVMBuildBr(builder, merge_bb);

                                    llvm.LLVMPositionBuilderAtEnd(builder, else_bb);
                                    // Void-returning methods have no value to null-fill on
                                    // the null branch (the void merge below ignores it);
                                    // LLVMConstNull(void) would hit getNullValue's
                                    // llvm_unreachable and trap.
                                    const const_null = if (llvm.LLVMGetTypeKind(ret_t) == llvm.LLVMVoidTypeKind)
                                        llvm.LLVMConstNull(llvm.LLVMInt32TypeInContext(ctx))
                                    else
                                        llvm.LLVMConstNull(ret_t);
                                    const else_end_bb = llvm.LLVMGetInsertBlock(builder);
                                    _ = llvm.LLVMBuildBr(builder, merge_bb);

                                    llvm.LLVMPositionBuilderAtEnd(builder, merge_bb);
                                    if (llvm.LLVMGetTypeKind(ret_t) == llvm.LLVMVoidTypeKind) {
                                        // No value to merge for a void-returning
                                        // method: route to a fresh continuation
                                        // block where the enclosing function keeps
                                        // emitting (mirrors the contract dispatch).
                                        const safe_cont_bb = llvm.LLVMAppendBasicBlockInContext(ctx, parent_func, "safe_call_cont");
                                        _ = llvm.LLVMBuildBr(builder, safe_cont_bb);
                                        llvm.LLVMPositionBuilderAtEnd(builder, safe_cont_bb);
                                        return call_res;
                                    }
                                    const phi = llvm.LLVMBuildPhi(builder, ret_t, "safe_call_val");
                                    var incoming_vals = [_]llvm.LLVMValueRef{ call_res, const_null };
                                    var incoming_bbs = [_]llvm.LLVMBasicBlockRef{ then_end_bb, else_end_bb };
                                    llvm.LLVMAddIncoming(phi, &incoming_vals, &incoming_bbs, 2);
                                    return phi;
                                }

                                const call_res = llvm.LLVMBuildCall2(
                                    builder,
                                    func_type,
                                    func_val,
                                    if (arg_vals.len > 0) arg_vals.ptr else null,
                                    @intCast(arg_vals.len),
                                    if (llvm.LLVMGetTypeKind(ret_t) == llvm.LLVMVoidTypeKind) "" else "method_tmp",
                                );

                                if (node.resolved_type) |nrt| {
                                    if ((nrt.* == .Int or nrt.* == .Bool) and llvm.LLVMGetTypeKind(ret_t) == llvm.LLVMPointerTypeKind) {
                                        const target_t = types_mapping.getLLVMType(ctx, nrt.*);
                                        return llvm.LLVMBuildPtrToInt(builder, call_res, target_t, "unbox_method_ret");
                                    }
                                }
                                return call_res;
                            }
                        }
                    }
                }
            }

            // Direct builtin/contract method pass-through: when callee is a 0-argument
            // `get_expr` on a builtin or contract property (.toString(), .toInt(), .toDouble(),
            // .hashCode()), `get_expr` already emitted the cast or helper call. Pass it through.
            if (call.callee.data == .get_expr and call.arguments.len == 0) {
                const g = call.callee.data.get_expr;
                const obj_rt: ?ts.EiwaType = if (g.object.resolved_type) |ort| ort.* else null;
                if (types_mapping.isDirectBuiltinMethod(g.name, obj_rt) or (std.mem.eql(u8, g.name, "hashCode") and g.object.data == .string_literal)) {
                    return emitExpression(ctx, mod, builder, scope, structs, libs, call.callee);
                }
            }

            // NativeArray builtins: `arr.get(i)`, `arr.set(i, v)`, `arr.push(v)`
            // on the raw buffer layout (slot 0 = size, slot 1 = capacity,
            // slots 2.. = elements). See the TODO(emitter) on `.length` above.
            if (call.callee.data == .get_expr) {
                const g = call.callee.data.get_expr;
                if (g.object.resolved_type) |obj_rt| {
                    const base_obj_rt = ts.extractBaseType(obj_rt);
                    if (base_obj_rt.* == .Array or (base_obj_rt.* == .Pointer and base_obj_rt.Pointer.* == .Array)) {
                        if (std.mem.eql(u8, g.name, "get") and call.arguments.len == 1) {
                            const arr_ptr = try emitExpression(ctx, mod, builder, scope, structs, libs, g.object);
                            const i_val = try emitExpression(ctx, mod, builder, scope, structs, libs, call.arguments[0]);
                            const elem_type = arrayElemLLVMType(ctx, g.object.resolved_type);
                            const elem_stride = arrayElemStride(ctx, elem_type);
                            const name_z = try std.heap.page_allocator.dupeZ(u8, "arr_get_gep");
                            defer std.heap.page_allocator.free(name_z);
                            const elem_ptr = arrayElemTypedPtr(builder, ctx, arr_ptr, i_val, elem_type, elem_stride, name_z.ptr);
                            return llvm.LLVMBuildLoad2(builder, elem_type, elem_ptr, "arr_get_val");
                        }
                        if (std.mem.eql(u8, g.name, "set") and call.arguments.len == 2) {
                            const arr_ptr = try emitExpression(ctx, mod, builder, scope, structs, libs, g.object);
                            const i_val = try emitExpression(ctx, mod, builder, scope, structs, libs, call.arguments[0]);
                            const val = try emitExpression(ctx, mod, builder, scope, structs, libs, call.arguments[1]);
                            const elem_type = arrayElemLLVMType(ctx, g.object.resolved_type);
                            const elem_stride = arrayElemStride(ctx, elem_type);
                            const name_z = try std.heap.page_allocator.dupeZ(u8, "arr_set_gep");
                            defer std.heap.page_allocator.free(name_z);
                            const elem_ptr = arrayElemTypedPtr(builder, ctx, arr_ptr, i_val, elem_type, elem_stride, name_z.ptr);
                            if (storeValue(val, elem_type)) |sv| {
                                _ = llvm.LLVMBuildStore(builder, sv, elem_ptr);
                            }
                            return val;
                        }
                        if (std.mem.eql(u8, g.name, "push") and call.arguments.len == 1) {
                            return try emitNativeArrayPush(ctx, mod, builder, scope, structs, libs, g.object, call.arguments[0]);
                        }
                    }
                }
            }

            // Dynamic Function / Lambda Call (closure fat pointer path)
            // All Function-typed callees are treated as closure fat pointers:
            //   closure_ptr -> { fn_ptr: ptr, env: ptr }
            // We load both fields, then call fn_ptr(env, args...).
            const is_fn_callee = if (call.callee.resolved_type) |rt| rt.* == .Function else false;

            if (is_fn_callee) {
                const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);

                // Determine ret_type and param_types from the Function type
                var ret_type: llvm.LLVMTypeRef = llvm.LLVMVoidTypeInContext(ctx);
                var param_types = try std.heap.page_allocator.alloc(llvm.LLVMTypeRef, call.arguments.len);
                defer std.heap.page_allocator.free(param_types);

                if (call.callee.resolved_type) |rt| {
                    ret_type = types_mapping.getLLVMTypeWithContracts(ctx, rt.Function.return_type.*, global_contracts_ast_ptr);
                    // Receiver lambdas (`T.() -> R`) bind the receiver as the
                    // leading argument, supplied by the caller as args[0].
                    const recv_param: ?llvm.LLVMTypeRef = if (rt.Function.receiver) |rec|
                        types_mapping.getLLVMTypeWithContracts(ctx, rec.*, global_contracts_ast_ptr)
                    else
                        null;
                    for (call.arguments, 0..) |_, idx| {
                        const p_idx: usize = if (recv_param != null) blk: {
                            if (idx == 0) {
                                param_types[idx] = recv_param.?;
                                continue;
                            }
                            break :blk idx - 1;
                        } else idx;
                        if (p_idx < rt.Function.params.len) {
                            param_types[idx] = types_mapping.getLLVMTypeWithContracts(ctx, rt.Function.params[p_idx].*, global_contracts_ast_ptr);
                        } else {
                            param_types[idx] = llvm.LLVMInt64TypeInContext(ctx);
                        }
                    }
                } else {
                    for (call.arguments, 0..) |_, idx| param_types[idx] = llvm.LLVMInt64TypeInContext(ctx);
                }

                // Emit callee — yields a closure_ptr (ptr to { fn_ptr: ptr, env: ptr })
                const callee_val = try emitExpression(ctx, mod, builder, scope, structs, libs, call.callee);

                // Load the closure struct from the heap
                var closure_field_types = [_]llvm.LLVMTypeRef{ ptr_type, ptr_type };
                const closure_struct_type = llvm.LLVMStructTypeInContext(ctx, &closure_field_types, 2, 0);
                const closure = llvm.LLVMBuildLoad2(builder, closure_struct_type, callee_val, "closure_load");

                const fn_ptr = llvm.LLVMBuildExtractValue(builder, closure, 0, "fn_ptr");
                const env_ptr = llvm.LLVMBuildExtractValue(builder, closure, 1, "env_ptr");

                // Build the full arg list: [env, args...]
                var full_arg_vals = try std.heap.page_allocator.alloc(llvm.LLVMValueRef, 1 + call.arguments.len);
                defer std.heap.page_allocator.free(full_arg_vals);
                full_arg_vals[0] = env_ptr;

                for (call.arguments, 0..) |arg_node, idx| {
                    var arg_val = try emitExpression(ctx, mod, builder, scope, structs, libs, arg_node);
                    const ptype = param_types[idx];
                    if (llvm.LLVMGetTypeKind(ptype) == llvm.LLVMStructTypeKind) {
                        if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(arg_val)) != llvm.LLVMStructTypeKind) {
                            if (arg_node.resolved_type) |arg_rt| {
                                const arg_c_name = switch (ts.extractBaseType(arg_rt).*) {
                                    .Custom => |n| n,
                                    .GenericInstance => |gi| gi.base_name,
                                    .Int => "core_Int",
                                    .Double => "core_Double",
                                    .Bool => "core_Bool",
                                    .String => "core_String",
                                    .Pointer => "core_Pointer",
                                    else => "",
                                };
                                if (arg_c_name.len > 0) {
                                    var contract_c_name: []const u8 = "";
                                    if (arg_node.expected_type) |et| {
                                        const ebase = ts.extractBaseType(et);
                                        if (ebase.* == .Custom) contract_c_name = ebase.Custom;
                                    }
                                    if (contract_c_name.len == 0) {
                                        if (call.callee.resolved_type) |crt| {
                                            const base_crt = ts.extractBaseType(crt);
                                            if (base_crt.* == .Function) {
                                                const p_idx: usize = if (base_crt.Function.receiver != null and idx == 0) 0 else idx;
                                                if (p_idx < base_crt.Function.params.len) {
                                                    switch (ts.extractBaseType(base_crt.Function.params[p_idx]).*) {
                                                        .Custom => |n| contract_c_name = n,
                                                        .GenericInstance => |gi| contract_c_name = gi.base_name,
                                                        else => {},
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    if (contract_c_name.len > 0) {
                                        arg_val = coerceToContract(ctx, mod, builder, arg_val, arg_c_name, contract_c_name) catch arg_val;
                                    } else if (global_contracts_ast_ptr) |ca| {
                                        var it = ca.iterator();
                                        while (it.next()) |entry| {
                                            const c_name = entry.key_ptr.*;
                                            const test_fat = coerceToContractChecked(ctx, mod, builder, arg_val, arg_c_name, c_name) catch continue;
                                            if (llvm.LLVMTypeOf(test_fat) == ptype) {
                                                arg_val = test_fat;
                                                break;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    } else if (llvm.LLVMGetTypeKind(ptype) != llvm.LLVMVoidTypeKind) {
                        arg_val = coerceArg(builder, arg_val, ptype);
                    }
                    full_arg_vals[1 + idx] = arg_val;
                }

                // fn_type: (ptr_env, ...param_types) -> ret_type
                var full_param_types = try std.heap.page_allocator.alloc(llvm.LLVMTypeRef, 1 + call.arguments.len);
                defer std.heap.page_allocator.free(full_param_types);
                full_param_types[0] = ptr_type;
                for (param_types, 0..) |pt, idx| full_param_types[1 + idx] = pt;

                const dyn_fn_type = llvm.LLVMFunctionType(ret_type, full_param_types.ptr, @intCast(1 + call.arguments.len), 0);
                const call_name: [*c]const u8 = if (llvm.LLVMGetTypeKind(ret_type) == llvm.LLVMVoidTypeKind) "" else "cl_calltmp";
                return llvm.LLVMBuildCall2(
                    builder,
                    dyn_fn_type,
                    fn_ptr,
                    full_arg_vals.ptr,
                    @intCast(1 + call.arguments.len),
                    call_name,
                );
            }

            // Non-Function call path
            const callee_val = try emitExpression(ctx, mod, builder, scope, structs, libs, call.callee);

            if (llvm.LLVMIsAFunction(callee_val) != null) {
                const func_type = llvm.LLVMGlobalGetValueType(callee_val);
                const param_count: usize = @intCast(llvm.LLVMCountParamTypes(func_type));
                const func_param_types = try std.heap.page_allocator.alloc(llvm.LLVMTypeRef, param_count);
                defer std.heap.page_allocator.free(func_param_types);
                if (param_count > 0) {
                    llvm.LLVMGetParamTypes(func_type, func_param_types.ptr);
                }

                var arg_vals = try std.heap.page_allocator.alloc(llvm.LLVMValueRef, call.arguments.len);
                defer std.heap.page_allocator.free(arg_vals);

                for (call.arguments, 0..) |arg_node, idx| {
                    var arg_val = try emitExpression(ctx, mod, builder, scope, structs, libs, arg_node);
                    if (idx < param_count) {
                        const expected_type = func_param_types[idx];
                        if (llvm.LLVMGetTypeKind(expected_type) == llvm.LLVMStructTypeKind) {
                            var arg_c_name: []const u8 = "";
                            var contract_c_name: []const u8 = "";
                            if (arg_node.expected_type) |et| {
                                const ebase = ts.extractBaseType(et);
                                if (ebase.* == .Custom) contract_c_name = ebase.Custom;
                            }
                            if (contract_c_name.len == 0) {
                                if (call.callee.resolved_type) |crt| {
                                    if (crt.* == .Function and idx < crt.Function.params.len) {
                                        switch (ts.extractBaseType(crt.Function.params[idx]).*) {
                                            .Custom => |n| contract_c_name = n,
                                            .GenericInstance => |gi| contract_c_name = gi.base_name,
                                            else => {},
                                        }
                                    }
                                }
                            }
                            if (arg_node.resolved_type) |art| {
                                const abase = ts.extractBaseType(art);
                                arg_c_name = switch (abase.*) {
                                    .Custom => |n| n,
                                    .GenericInstance => |gi| gi.base_name,
                                    .Int => "core_Int",
                                    .Double => "core_Double",
                                    .Bool => "core_Bool",
                                    .String => "core_String",
                                    .Pointer => "core_Pointer",
                                    else => "",
                                };
                            }
                            arg_val = coerceToContract(ctx, mod, builder, arg_val, arg_c_name, contract_c_name) catch coerceArg(builder, arg_val, expected_type);
                            if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(arg_val)) != llvm.LLVMStructTypeKind) {
                                arg_val = coerceArg(builder, arg_val, expected_type);
                            }
                        } else {
                            arg_val = coerceArg(builder, arg_val, expected_type);
                        }
                    }
                    arg_vals[idx] = arg_val;
                }

                const fn_ret_type = llvm.LLVMGetReturnType(func_type);
                const call_name: [*c]const u8 = if (llvm.LLVMGetTypeKind(fn_ret_type) == llvm.LLVMVoidTypeKind) "" else "calltmp";
                return llvm.LLVMBuildCall2(builder, func_type, callee_val, if (arg_vals.len > 0) arg_vals.ptr else null, @intCast(arg_vals.len), call_name);
            }

            var arg_vals = try std.heap.page_allocator.alloc(llvm.LLVMValueRef, call.arguments.len);
            defer std.heap.page_allocator.free(arg_vals);

            const ret_type: llvm.LLVMTypeRef = llvm.LLVMInt64TypeInContext(ctx);
            var param_types = try std.heap.page_allocator.alloc(llvm.LLVMTypeRef, call.arguments.len);
            defer std.heap.page_allocator.free(param_types);

            for (call.arguments, 0..) |_, idx| {
                param_types[idx] = llvm.LLVMInt64TypeInContext(ctx);
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

            var cond_val = try emitExpression(ctx, mod, builder, scope, structs, libs, i.condition);
            const cond_type = llvm.LLVMTypeOf(cond_val);
            if (llvm.LLVMGetTypeKind(cond_type) == llvm.LLVMPointerTypeKind) {
                cond_val = llvm.LLVMBuildIsNotNull(builder, cond_val, "cond_ptr_bool");
            } else if (llvm.LLVMGetTypeKind(cond_type) == llvm.LLVMIntegerTypeKind and llvm.LLVMGetIntTypeWidth(cond_type) != 1) {
                cond_val = llvm.LLVMBuildICmp(builder, llvm.LLVMIntNE, cond_val, llvm.LLVMConstNull(cond_type), "cond_int_bool");
            }

            const then_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "expr_if.then");
            const else_bb = if (i.else_branch != null) llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "expr_if.else") else null;
            const merge_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "expr_if.merge");

            const res_ptr = if (!is_void) llvm.LLVMBuildAlloca(builder, ret_type, "expr_if_res") else null;
            _ = llvm.LLVMBuildCondBr(builder, cond_val, then_bb, else_bb orelse merge_bb);

            llvm.LLVMPositionBuilderAtEnd(builder, then_bb);
            try emitBlockOrExpr(ctx, mod, builder, func_val, scope, structs, libs, i.then_branch, res_ptr);
            if (llvm.LLVMGetBasicBlockTerminator(llvm.LLVMGetInsertBlock(builder)) == null) {
                _ = llvm.LLVMBuildBr(builder, merge_bb);
            }

            if (i.else_branch) |else_node| {
                if (else_bb) |eb| {
                    llvm.LLVMPositionBuilderAtEnd(builder, eb);
                    try emitBlockOrExpr(ctx, mod, builder, func_val, scope, structs, libs, else_node, res_ptr);
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
                var subj_val = try emitExpression(ctx, mod, builder, scope, structs, libs, subj);
                if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(subj_val)) == llvm.LLVMStructTypeKind) {
                    subj_val = coerceArg(builder, subj_val, types_mapping.getFatPointerType(ctx));
                } else if (subj.resolved_type) |srt| {
                    if (types_mapping.isContractType(srt.*, global_contracts_ast_ptr)) {
                        subj_val = coerceArg(builder, subj_val, types_mapping.getFatPointerType(ctx));
                    }
                }
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
                    var cond_vals_buf: [16]llvm.LLVMValueRef = undefined;
                    var cond_vals_count: usize = 0;
                    for (case.conds) |cond| {
                        if (cond.data == .is_type_cond) {
                            // Type checks in `when (x) is T`: scalar types (< 0x1000000) are
                            // matched by value bounds, and heap pointers are matched via
                            // safe dereference of their payload/header.
                            const i1_type = llvm.LLVMInt1TypeInContext(ctx);
                            const type_cond = cond.data.is_type_cond;
                            const target_t = if (type_cond.type_ref.resolved_type) |rt| rt.* else ts.EiwaType.Unknown;
                            var target_c_name: []const u8 = type_cond.type_ref.name;
                            switch (target_t) {
                                .Custom => |cn| target_c_name = cn,
                                .Int => target_c_name = "core_Int",
                                .Double => target_c_name = "core_Double",
                                .Bool => target_c_name = "core_Bool",
                                .Null => target_c_name = "core_Null",
                                .String => target_c_name = "core_String",
                                else => {},
                            }
                            // Opaque pointers hide the alloca's pointee type, so a
                            // contract subject must be detected from the resolved
                            // type (not LLVMGetTypeKind) and then loaded with the
                            // explicit Fat Pointer type so extractvalue works.
                            const subj_is_fat = blk: {
                                if (w.subject) |s| {
                                    if (s.resolved_type) |rt| {
                                        if (types_mapping.isContractType(rt.*, global_contracts_ast_ptr)) break :blk true;
                                    }
                                }
                                if (subj_ptr) |sp| {
                                    const alloc_type = llvm.LLVMGetAllocatedType(sp);
                                    if (llvm.LLVMGetTypeKind(alloc_type) == llvm.LLVMStructTypeKind) break :blk true;
                                }
                                break :blk false;
                            };
                            const subj_load = if (subj_is_fat)
                                llvm.LLVMBuildLoad2(builder, types_mapping.getFatPointerType(ctx), subj_ptr.?, "when_subj_load")
                            else
                                llvm.LLVMBuildLoad2(builder, llvm.LLVMTypeOf(subj_ptr.?), subj_ptr.?, "when_subj_load");
                            // Contract subjects are Fat Pointers { data, vtable }.
                            // Type identity is carried by the vtable pointer (the C
                            // backend tags boxed values with EiwaTypeDescriptor*;
                            // the vtable slot plays that role here). Extract the data
                            // pointer + vtable so we never PtrToInt() the struct.
                            var subj_data = subj_load;
                            var subj_vtable: ?llvm.LLVMValueRef = null;
                            if (subj_is_fat) {
                                subj_data = llvm.LLVMBuildExtractValue(builder, subj_load, 0, "when_subj_data");
                                subj_vtable = llvm.LLVMBuildExtractValue(builder, subj_load, 1, "when_subj_vtable");
                            }
                            const i1_false = llvm.LLVMConstInt(i1_type, 0, 0);
                            const i1_true = llvm.LLVMConstInt(i1_type, 1, 0);
                            const subj_int = llvm.LLVMBuildPtrToInt(builder, subj_data, i64_type, "when_subj_int");
                            const is_heap = llvm.LLVMBuildICmp(builder, llvm.LLVMIntUGE, subj_int, llvm.LLVMConstInt(i64_type, 4096, 0), "is_heap");
                            const is_non_null = llvm.LLVMBuildIsNotNull(builder, subj_data, "is_non_null");
                            const is_small = llvm.LLVMBuildAnd(builder, is_non_null, llvm.LLVMBuildNot(builder, is_heap, "not_heap"), "is_small");

                            var is_match: llvm.LLVMValueRef = undefined;
                            if (std.mem.endsWith(u8, target_c_name, "Stringable") or std.mem.endsWith(u8, target_c_name, "Equatable") or std.mem.endsWith(u8, target_c_name, "Hashable") or std.mem.endsWith(u8, target_c_name, "Echoable")) {
                                is_match = i1_true;
                            } else if (std.mem.eql(u8, target_c_name, "core_Null") or std.mem.eql(u8, target_c_name, "Null")) {
                                is_match = llvm.LLVMBuildICmp(builder, llvm.LLVMIntEQ, subj_data, llvm.LLVMConstNull(ptr_type), "when_is_null");
                            } else if (std.mem.eql(u8, target_c_name, "Int") or std.mem.eql(u8, target_c_name, "core_Int") or std.mem.eql(u8, target_c_name, "std_core_Int") or std.mem.eql(u8, target_c_name, "core_Double") or std.mem.eql(u8, target_c_name, "Double")) {
                                is_match = if (subj_is_fat) i1_false else is_small;
                            } else if (std.mem.eql(u8, target_c_name, "Bool") or std.mem.eql(u8, target_c_name, "core_Bool") or std.mem.eql(u8, target_c_name, "std_core_Bool")) {
                                is_match = if (subj_is_fat) i1_false else is_small;
                            } else if (std.mem.eql(u8, target_c_name, "String") or std.mem.eql(u8, target_c_name, "core_String") or std.mem.eql(u8, target_c_name, "std_core_String")) {
                                if (subj_is_fat) {
                                    is_match = i1_false;
                                } else {
                                    const dummy_arr_t = llvm.LLVMArrayType2(i64_type, 2);
                                    const dummy_alloc = llvm.LLVMBuildAlloca(builder, dummy_arr_t, "dummy_str_check");
                                    _ = llvm.LLVMBuildStore(builder, llvm.LLVMConstNull(dummy_arr_t), dummy_alloc);
                                    const safe_val = llvm.LLVMBuildSelect(builder, is_heap, subj_data, dummy_alloc, "safe_val_ptr");

                                    var f0_idx = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, 0, 0)};
                                    const f0_ptr = llvm.LLVMBuildGEP2(builder, ptr_type, safe_val, &f0_idx, 1, "f0_ptr");
                                    const f0_val = llvm.LLVMBuildLoad2(builder, ptr_type, f0_ptr, "f0_val");
                                    const f0_int = llvm.LLVMBuildPtrToInt(builder, f0_val, i64_type, "f0_int");
                                    const f0_is_heap = llvm.LLVMBuildICmp(builder, llvm.LLVMIntUGE, f0_int, llvm.LLVMConstInt(i64_type, 4096, 0), "f0_is_heap");

                                    var f1_idx = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, 1, 0)};
                                    const f1_ptr = llvm.LLVMBuildGEP2(builder, i64_type, safe_val, &f1_idx, 1, "f1_ptr");
                                    const f1_val = llvm.LLVMBuildLoad2(builder, i64_type, f1_ptr, "f1_val");

                                    const strlen_func = llvm.LLVMGetNamedFunction(mod, "strlen") orelse blk: {
                                        var ps = [_]llvm.LLVMTypeRef{ptr_type};
                                        const ft = llvm.LLVMFunctionType(i64_type, &ps, 1, 0);
                                        break :blk llvm.LLVMAddFunction(mod, "strlen", ft);
                                    };
                                    const strlen_type = llvm.LLVMGlobalGetValueType(strlen_func);
                                    const safe_buf = llvm.LLVMBuildSelect(builder, f0_is_heap, f0_val, dummy_alloc, "safe_buf");
                                    var sl_args = [_]llvm.LLVMValueRef{safe_buf};
                                    const calc_len = llvm.LLVMBuildCall2(builder, strlen_type, strlen_func, &sl_args, 1, "str_check_len");
                                    const len_eq = llvm.LLVMBuildICmp(builder, llvm.LLVMIntEQ, calc_len, f1_val, "len_eq");

                                    const is_valid_str = llvm.LLVMBuildAnd(builder, f0_is_heap, len_eq, "is_valid_str");
                                    is_match = llvm.LLVMBuildAnd(builder, is_heap, is_valid_str, "is_str_res");
                                }
                            } else if (subj_is_fat) {
                                // Custom type from a contract subject: match by vtable
                                // identity. The subject's static contract tells us which
                                // vtable slot to expect for the target concrete type,
                                // so `when (v) is SomeType` == `v.vtable == &SomeType_Contract_vtable`.
                                 var subj_contract: []const u8 = "";
                                if (w.subject) |subj_node| {
                                    if (subj_node.resolved_type) |srt| {
                                        const sb = ts.extractBaseType(srt).*;
                                        switch (sb) {
                                            .Custom => |cn2| subj_contract = cn2,
                                            .GenericInstance => |gi| subj_contract = gi.base_name,
                                            else => {},
                                        }
                                    }
                                }
                                if (subj_vtable) |svt| {
                                    const svt_ptr = llvm.LLVMBuildBitCast(builder, svt, ptr_type, "when_vt_subj");
                                    var vt_match_or = llvm.LLVMConstInt(i1_type, 0, 0);

                                    var short_target = target_c_name;
                                    if (std.mem.lastIndexOfScalar(u8, target_c_name, '_')) |idx| short_target = target_c_name[idx + 1 ..];

                                    var g_iter = llvm.LLVMGetFirstGlobal(mod);
                                    while (g_iter != null) : (g_iter = llvm.LLVMGetNextGlobal(g_iter.?)) {
                                        const g_name_ptr = llvm.LLVMGetValueName(g_iter.?);
                                        const g_name_s = std.mem.span(g_name_ptr);
                                        if (std.mem.endsWith(u8, g_name_s, "_vtable") and (std.mem.indexOf(u8, g_name_s, target_c_name) != null or std.mem.indexOf(u8, g_name_s, short_target) != null)) {
                                            const exp_vt_ptr = llvm.LLVMBuildPointerCast(builder, g_iter.?, ptr_type, "exp_vt_ptr");
                                            const vt_eq = llvm.LLVMBuildICmp(builder, llvm.LLVMIntEQ, svt_ptr, exp_vt_ptr, "when_is_vt_eq");
                                            vt_match_or = llvm.LLVMBuildOr(builder, vt_match_or, vt_eq, "vt_match_or");
                                        }
                                    }
                                    const data_not_null = llvm.LLVMBuildIsNotNull(builder, subj_data, "fat_data_not_null");
                                    is_match = llvm.LLVMBuildAnd(builder, data_not_null, vt_match_or, "is_match_fat");
                                } else {
                                    is_match = i1_false;
                                }
                            } else {
                                is_match = llvm.LLVMBuildIsNotNull(builder, subj_data, "when_is_custom");
                            }
                            if (type_cond.is_not) {
                                is_match = llvm.LLVMBuildNot(builder, is_match, "when_is_not");
                            }
                            if (cond_vals_count < 16) {
                                cond_vals_buf[cond_vals_count] = is_match;
                                cond_vals_count += 1;
                            }
                        } else {
                            // Value check: subject == cond (or plain Bool condition).
                            var cond_val = try emitExpression(ctx, mod, builder, scope, structs, libs, cond);
                            if (subj_ptr != null) {
                                var subj_load = llvm.LLVMBuildLoad2(builder, llvm.LLVMTypeOf(subj_ptr.?), subj_ptr.?, "when_subj_load");
                                const s_type = llvm.LLVMTypeOf(subj_load);
                                const c_type = llvm.LLVMTypeOf(cond_val);
                                var already_eq = false;
                                const subj_is_string = w.subject != null and w.subject.?.resolved_type != null and isStringOperandType(w.subject.?.resolved_type.?);
                                if (subj_is_string and llvm.LLVMGetTypeKind(s_type) == llvm.LLVMPointerTypeKind and llvm.LLVMGetTypeKind(c_type) == llvm.LLVMPointerTypeKind) {
                                    // String == String: compare content via the
                                    // runtime helper (pointer identity would fail
                                    // for a heap String vs a string literal).
                                    const seq_fn = llvm.LLVMGetNamedFunction(mod, "eiwa_string_equals") orelse return error.StringEqualsNotFound;
                                    const seq_type = llvm.LLVMGlobalGetValueType(seq_fn);
                                    const ptr_t = llvm.LLVMPointerTypeInContext(ctx, 0);
                                    var sargs = [_]llvm.LLVMValueRef{ coerceArg(builder, subj_load, ptr_t), coerceArg(builder, cond_val, ptr_t) };
                                    cond_val = llvm.LLVMBuildCall2(builder, seq_type, seq_fn, &sargs, 2, "when_streq");
                                    already_eq = true;
                                } else if (llvm.LLVMGetTypeKind(s_type) == llvm.LLVMPointerTypeKind and llvm.LLVMGetTypeKind(c_type) == llvm.LLVMIntegerTypeKind) {
                                    subj_load = llvm.LLVMBuildPtrToInt(builder, subj_load, c_type, "subj_ptr2int");
                                } else if (llvm.LLVMGetTypeKind(s_type) == llvm.LLVMIntegerTypeKind and llvm.LLVMGetTypeKind(c_type) == llvm.LLVMPointerTypeKind) {
                                    cond_val = llvm.LLVMBuildPtrToInt(builder, cond_val, s_type, "cond_ptr2int");
                                }
                                if (!already_eq) {
                                    cond_val = llvm.LLVMBuildICmp(builder, llvm.LLVMIntEQ, subj_load, cond_val, "when_val_eq");
                                }
                            }
                            if (cond_vals_count < 16) {
                                cond_vals_buf[cond_vals_count] = cond_val;
                                cond_vals_count += 1;
                            }
                        }
                    }
                    if (cond_vals_count > 0) {
                        var combined = cond_vals_buf[0];
                        for (cond_vals_buf[1..cond_vals_count]) |c| {
                            combined = llvm.LLVMBuildOr(builder, combined, c, "when_or");
                        }
                        const i1_type = llvm.LLVMInt1TypeInContext(ctx);
                        const cond_i1 = if (llvm.LLVMTypeOf(combined) == i1_type)
                            combined
                        else
                            llvm.LLVMBuildICmp(builder, llvm.LLVMIntNE, combined, llvm.LLVMConstInt(i64_type, 0, 0), "when_cond_i1");
                        _ = llvm.LLVMBuildCondBr(builder, cond_i1, body_bb, next_bb orelse merge_bb);
                    } else {
                        _ = llvm.LLVMBuildBr(builder, body_bb);
                    }
                }

                llvm.LLVMPositionBuilderAtEnd(builder, body_bb);
                try emitBlockOrExpr(ctx, mod, builder, func_val, scope, structs, libs, case.body, res_ptr);
                if (llvm.LLVMGetBasicBlockTerminator(llvm.LLVMGetInsertBlock(builder)) == null) {
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
        .ternary_expr => |t| {
            const func_val = llvm.LLVMGetBasicBlockParent(llvm.LLVMGetInsertBlock(builder));
            const i1_type = llvm.LLVMInt1TypeInContext(ctx);
            const i64_type = llvm.LLVMInt64TypeInContext(ctx);

            // Alloca in the function entry block first, before any branches.
            const cond_val = try emitExpression(ctx, mod, builder, scope, structs, libs, t.condition);
            const cond_i1 = if (llvm.LLVMTypeOf(cond_val) == i1_type)
                cond_val
            else
                llvm.LLVMBuildICmp(builder, llvm.LLVMIntNE, cond_val, llvm.LLVMConstInt(i64_type, 0, 0), "ternary_cond_i1");

            const start_bb = llvm.LLVMGetInsertBlock(builder);
            const then_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "ternary_then");
            const else_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "ternary_else");
            const merge_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "ternary_merge");

            _ = llvm.LLVMBuildCondBr(builder, cond_i1, then_bb, else_bb);

            // Emit then branch
            llvm.LLVMPositionBuilderAtEnd(builder, then_bb);
            const then_val = try emitExpression(ctx, mod, builder, scope, structs, libs, t.then_branch);
            const then_end_bb = llvm.LLVMGetInsertBlock(builder);
            if (llvm.LLVMGetBasicBlockTerminator(then_end_bb) == null) {
                _ = llvm.LLVMBuildBr(builder, merge_bb);
            }
            if (llvm.LLVMGetBasicBlockTerminator(then_bb) == null) {
                llvm.LLVMPositionBuilderAtEnd(builder, then_bb);
                _ = llvm.LLVMBuildBr(builder, merge_bb);
            }

            // Emit else branch
            llvm.LLVMPositionBuilderAtEnd(builder, else_bb);
            const ret_type = llvm.LLVMTypeOf(then_val);
            const else_val: llvm.LLVMValueRef = if (t.else_branch) |eb|
                try emitExpression(ctx, mod, builder, scope, structs, libs, eb)
            else blk: {
                if (llvm.LLVMGetTypeKind(ret_type) == llvm.LLVMIntegerTypeKind) {
                    break :blk llvm.LLVMConstInt(ret_type, 0, 0);
                } else if (llvm.LLVMGetTypeKind(ret_type) == llvm.LLVMDoubleTypeKind) {
                    break :blk llvm.LLVMConstReal(ret_type, 0.0);
                } else {
                    break :blk llvm.LLVMConstNull(ret_type);
                }
            };
            const else_end_bb = llvm.LLVMGetInsertBlock(builder);
            if (llvm.LLVMGetBasicBlockTerminator(else_end_bb) == null) {
                _ = llvm.LLVMBuildBr(builder, merge_bb);
            }
            if (llvm.LLVMGetBasicBlockTerminator(else_bb) == null) {
                llvm.LLVMPositionBuilderAtEnd(builder, else_bb);
                _ = llvm.LLVMBuildBr(builder, merge_bb);
            }

            // Coerce types if needed (e.g. one branch returned i64 vs ptr) or use phi
            llvm.LLVMPositionBuilderAtEnd(builder, merge_bb);
            const phi_type = llvm.LLVMTypeOf(then_val);
            const phi = llvm.LLVMBuildPhi(builder, phi_type, "ternary_val");
            var incoming_vals = [_]llvm.LLVMValueRef{ then_val, else_val };
            var incoming_bbs = [_]llvm.LLVMBasicBlockRef{ then_end_bb, else_end_bb };
            llvm.LLVMAddIncoming(phi, &incoming_vals, &incoming_bbs, 2);

            _ = start_bb;
            return phi;
        },
        .is_expr => |i| {
            const target_type = if (i.type_ref.resolved_type) |rt| rt.* else .Unknown;

            // `x is Void` (or a value whose static type is Void) is a constant:
            // a Void-typed variable has no storage and its value is nothing, so
            // the check is trivially true (mirrors C emitting assert(1, ...)).
            if (target_type == .Void) {
                return llvm.LLVMConstInt(llvm.LLVMInt1TypeInContext(ctx), if (i.is_not) 0 else 1, 0);
            }
            if (i.value.resolved_type) |vr| {
                if (vr.* == .Void) {
                    return llvm.LLVMConstInt(llvm.LLVMInt1TypeInContext(ctx), if (i.is_not) 0 else 1, 0);
                }
            }

            const target_c_name = if (i.type_ref.resolved_type) |rt| switch (rt.*) {
                .Custom => |cn| cn,
                .GenericInstance => |gi| gi.base_name,
                .Int => "Int",
                .String => "String",
                .Bool => "Bool",
                .Double => "Double",
                else => i.type_ref.name,
            } else i.type_ref.name;

            const is_target_int = std.mem.eql(u8, target_c_name, "Int") or std.mem.endsWith(u8, target_c_name, "_Int") or target_type == .Int;
            const is_target_str = std.mem.eql(u8, target_c_name, "String") or std.mem.endsWith(u8, target_c_name, "_String") or target_type == .String;
            const is_target_bool = std.mem.eql(u8, target_c_name, "Bool") or std.mem.endsWith(u8, target_c_name, "_Bool") or target_type == .Bool;
            const is_target_double = std.mem.eql(u8, target_c_name, "Double") or std.mem.endsWith(u8, target_c_name, "_Double") or target_type == .Double;

            const val = try emitExpression(ctx, mod, builder, scope, structs, libs, i.value);

            const type_ref_name = i.type_ref.name;
            const is_core_contract = std.mem.indexOf(u8, target_c_name, "Stringable") != null or
                std.mem.indexOf(u8, type_ref_name, "Stringable") != null or
                std.mem.indexOf(u8, target_c_name, "Equatable") != null or
                std.mem.indexOf(u8, type_ref_name, "Equatable") != null or
                std.mem.indexOf(u8, target_c_name, "Hashable") != null or
                std.mem.indexOf(u8, type_ref_name, "Hashable") != null or
                std.mem.indexOf(u8, target_c_name, "Echoable") != null or
                std.mem.indexOf(u8, type_ref_name, "Echoable") != null;

            if (is_core_contract) {
                const res_c = llvm.LLVMConstInt(llvm.LLVMInt1TypeInContext(ctx), if (i.is_not) 0 else 1, 0);
                return res_c;
            }

            var res: llvm.LLVMValueRef = undefined;
            if (target_type == .Null) {
                if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(val)) == llvm.LLVMStructTypeKind) {
                    const data_ptr = llvm.LLVMBuildExtractValue(builder, val, 0, "is_null_data");
                    res = llvm.LLVMBuildIsNull(builder, data_ptr, "is_null_cmp");
                } else {
                    res = llvm.LLVMBuildIsNull(builder, val, "is_null_cmp");
                }
            } else if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(val)) == llvm.LLVMStructTypeKind) {
                const exc_vtable = llvm.LLVMBuildExtractValue(builder, val, 1, "is_vtable");
                const data_ptr = llvm.LLVMBuildExtractValue(builder, val, 0, "is_data_ptr");

                if (is_target_int or is_target_bool or is_target_double) {
                    const vtable_is_null = llvm.LLVMBuildIsNull(builder, exc_vtable, "vt_null");
                    const data_is_not_null = llvm.LLVMBuildIsNotNull(builder, data_ptr, "data_not_null");
                    res = llvm.LLVMBuildAnd(builder, vtable_is_null, data_is_not_null, "is_primitive_res");
                } else if (is_target_str) {
                    res = llvm.LLVMBuildIsNotNull(builder, data_ptr, "is_str_res");
                } else if (target_c_name.len > 0) {
                    var target_vt_opt = try findVtableGlobal(ctx, mod, target_c_name, "Throwable");
                    if (target_vt_opt == null) {
                        target_vt_opt = try findVtableGlobal(ctx, mod, target_c_name, "");
                    }
                    if (target_vt_opt == null) {
                        var glob = llvm.LLVMGetFirstGlobal(mod);
                        while (glob) |g_val| : (glob = llvm.LLVMGetNextGlobal(g_val)) {
                            const g_name_c = llvm.LLVMGetValueName(g_val);
                            const g_name = std.mem.span(g_name_c);
                            if (std.mem.endsWith(u8, g_name, "_vtable")) {
                                if (std.mem.startsWith(u8, g_name, target_c_name) or std.mem.indexOf(u8, g_name, target_c_name) != null) {
                                    target_vt_opt = g_val;
                                    break;
                                }
                            }
                        }
                    }
                    if (target_vt_opt) |target_vt| {
                        const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
                        const vt_cast = llvm.LLVMBuildPointerCast(builder, target_vt, ptr_type, "target_vt_cast");
                        const data_not_null = llvm.LLVMBuildIsNotNull(builder, data_ptr, "data_not_null");
                        const obj_vt = llvm.LLVMBuildLoad2(builder, ptr_type, data_ptr, "obj_vt");
                        const vt_eq1 = llvm.LLVMBuildICmp(builder, llvm.LLVMIntEQ, exc_vtable, vt_cast, "vt_eq1");
                        const vt_eq2 = llvm.LLVMBuildICmp(builder, llvm.LLVMIntEQ, obj_vt, vt_cast, "vt_eq2");
                        const vt_eq = llvm.LLVMBuildOr(builder, vt_eq1, vt_eq2, "vt_eq_or");
                        res = llvm.LLVMBuildAnd(builder, data_not_null, vt_eq, "is_vtable_eq");
                    } else {
                        res = llvm.LLVMBuildIsNotNull(builder, data_ptr, "is_not_null_cmp");
                    }
                } else {
                    res = llvm.LLVMBuildIsNotNull(builder, data_ptr, "is_not_null_cmp");
                }
            } else {
                const val_kind = llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(val));
                if (val_kind == llvm.LLVMIntegerTypeKind) {
                    if (is_target_int) {
                        res = llvm.LLVMConstInt(llvm.LLVMInt1TypeInContext(ctx), 1, 0);
                    } else {
                        res = llvm.LLVMConstInt(llvm.LLVMInt1TypeInContext(ctx), 0, 0);
                    }
                } else if (val_kind == llvm.LLVMPointerTypeKind) {
                    const i64_type = llvm.LLVMInt64TypeInContext(ctx);
                    const ptr_int = llvm.LLVMBuildPtrToInt(builder, val, i64_type, "ptr_int");
                    const is_heap = llvm.LLVMBuildICmp(builder, llvm.LLVMIntUGE, ptr_int, llvm.LLVMConstInt(i64_type, 4096, 0), "is_heap");
                    const not_null = llvm.LLVMBuildIsNotNull(builder, val, "not_null");
                    if (is_target_int or is_target_bool or is_target_double) {
                        const not_heap = llvm.LLVMBuildNot(builder, is_heap, "not_heap");
                        res = llvm.LLVMBuildAnd(builder, not_heap, not_null, "is_prim_res");
                    } else if (is_target_str) {
                        const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
                        const dummy_arr_t = llvm.LLVMArrayType2(i64_type, 2);
                        const dummy_alloc = llvm.LLVMBuildAlloca(builder, dummy_arr_t, "dummy_str_check");
                        _ = llvm.LLVMBuildStore(builder, llvm.LLVMConstNull(dummy_arr_t), dummy_alloc);
                        const safe_val = llvm.LLVMBuildSelect(builder, is_heap, val, dummy_alloc, "safe_val_ptr");

                        var f0_idx = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, 0, 0)};
                        const f0_ptr = llvm.LLVMBuildGEP2(builder, ptr_type, safe_val, &f0_idx, 1, "f0_ptr");
                        const f0_val = llvm.LLVMBuildLoad2(builder, ptr_type, f0_ptr, "f0_val");
                        const f0_int = llvm.LLVMBuildPtrToInt(builder, f0_val, i64_type, "f0_int");
                        const f0_is_heap = llvm.LLVMBuildICmp(builder, llvm.LLVMIntUGE, f0_int, llvm.LLVMConstInt(i64_type, 4096, 0), "f0_is_heap");

                        var f1_idx = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, 1, 0)};
                        const f1_ptr = llvm.LLVMBuildGEP2(builder, i64_type, safe_val, &f1_idx, 1, "f1_ptr");
                        const f1_val = llvm.LLVMBuildLoad2(builder, i64_type, f1_ptr, "f1_val");

                        const strlen_func = llvm.LLVMGetNamedFunction(mod, "strlen") orelse blk: {
                            var ps = [_]llvm.LLVMTypeRef{ptr_type};
                            const ft = llvm.LLVMFunctionType(i64_type, &ps, 1, 0);
                            break :blk llvm.LLVMAddFunction(mod, "strlen", ft);
                        };
                        const strlen_type = llvm.LLVMGlobalGetValueType(strlen_func);
                        const safe_buf = llvm.LLVMBuildSelect(builder, f0_is_heap, f0_val, dummy_alloc, "safe_buf");
                        var sl_args = [_]llvm.LLVMValueRef{safe_buf};
                        const calc_len = llvm.LLVMBuildCall2(builder, strlen_type, strlen_func, &sl_args, 1, "str_check_len");
                        const len_eq = llvm.LLVMBuildICmp(builder, llvm.LLVMIntEQ, calc_len, f1_val, "len_eq");

                        const is_valid_str = llvm.LLVMBuildAnd(builder, f0_is_heap, len_eq, "is_valid_str");
                        res = llvm.LLVMBuildAnd(builder, is_heap, is_valid_str, "is_str_res");
                    } else {
                        res = not_null;
                    }
                } else {
                    res = llvm.LLVMBuildIsNotNull(builder, val, "is_not_null_cmp");
                }
            }

            if (i.is_not) {
                res = llvm.LLVMBuildNot(builder, res, "is_not_res");
            }

            return res;
        },
        .map_literal => |m| {
            // Map literals construct a real `Map` the same way the C transpiler
            // does: a 16-slot bucket array -> `List<Node<K,V>?>` -> a
            // `MutableMap` over that list -> `MutableMap_put(k, v)` for each
            // pair -> finally a `Map` wrapping the same list. The `get`/`put`
            // logic then hashes keys and chains nodes (Phase-61 hash equality).
            // Bucket size (16) mirrors std/collections.ei and the C backend.
            const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
            if (node.resolved_type) |rt| {
                if (rt.* == .Custom and m.elements.len > 0) {
                    const custom = rt.Custom;
                    const inner = if (std.mem.startsWith(u8, custom, "collections_Map_"))
                        custom["collections_Map_".len..]
                    else if (std.mem.startsWith(u8, custom, "Map_"))
                        custom["Map_".len..]
                    else
                        custom;
                    if (inner.len == 0) return llvm.LLVMConstNull(ptr_type);

                    const list_name = try std.fmt.allocPrint(std.heap.page_allocator, "collections_List_collections_Node_{s}Opt\x00", .{inner});
                    defer std.heap.page_allocator.free(list_name);
                    const mmap_name = try std.fmt.allocPrint(std.heap.page_allocator, "collections_MutableMap_{s}\x00", .{inner});
                    defer std.heap.page_allocator.free(mmap_name);
                    const map_name = try std.fmt.allocPrint(std.heap.page_allocator, "collections_Map_{s}\x00", .{inner});
                    defer std.heap.page_allocator.free(map_name);
                    const put_name = try std.fmt.allocPrint(std.heap.page_allocator, "collections_MutableMap_{s}_put\x00", .{inner});
                    defer std.heap.page_allocator.free(put_name);

                    const list_ctor = llvm.LLVMGetNamedFunction(mod, list_name.ptr) orelse return error.MapLiteralListCtorMissing;
                    const mmap_ctor = llvm.LLVMGetNamedFunction(mod, mmap_name.ptr) orelse return error.MapLiteralMmapCtorMissing;
                    const map_ctor = llvm.LLVMGetNamedFunction(mod, map_name.ptr) orelse return error.MapLiteralMapCtorMissing;
                    const put_fn = llvm.LLVMGetNamedFunction(mod, put_name.ptr) orelse return error.MapLiteralPutMissing;

                    const i64_type = llvm.LLVMInt64TypeInContext(ctx);
                    const malloc_fn = core.getHeapAllocFn(mod);
                    const malloc_type = llvm.LLVMGlobalGetValueType(malloc_fn);

                    // 1. buckets buffer: [size, capacity, 16 x null]
                    const slot_count: i64 = 18;
                    const size_bytes: i64 = slot_count * 8;
                    var m_args = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, @bitCast(size_bytes), 0)};
                    const buckets = llvm.LLVMBuildCall2(builder, malloc_type, malloc_fn, &m_args, 1, "map_buckets");
                    var b0 = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, 0, 0)};
                    var b1 = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, 1, 0)};
                    const sixteen = llvm.LLVMConstInt(i64_type, 16, 0);
                    _ = llvm.LLVMBuildStore(builder, sixteen, llvm.LLVMBuildGEP2(builder, i64_type, buckets, &b0, 1, "bs0"));
                    _ = llvm.LLVMBuildStore(builder, sixteen, llvm.LLVMBuildGEP2(builder, i64_type, buckets, &b1, 1, "bs1"));
                    const null_ptr = llvm.LLVMConstNull(ptr_type);
                    for (2..18) |slot| {
                        var sidx = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, @intCast(slot), 0)};
                        _ = llvm.LLVMBuildStore(builder, null_ptr, llvm.LLVMBuildGEP2(builder, i64_type, buckets, &sidx, 1, "bs"));
                    }

                    // 2. List(items=buckets) -> 3. MutableMap(entries=list)
                    var l_args = [_]llvm.LLVMValueRef{buckets};
                    const list_t = llvm.LLVMGlobalGetValueType(list_ctor);
                    const list_val = llvm.LLVMBuildCall2(builder, list_t, list_ctor, &l_args, 1, "map_list");
                    var mm_args = [_]llvm.LLVMValueRef{list_val};
                    const mm_t = llvm.LLVMGlobalGetValueType(mmap_ctor);
                    const mmap_val = llvm.LLVMBuildCall2(builder, mm_t, mmap_ctor, &mm_args, 1, "map_mmap");

                    // 4. put(k, v) for each pair
                    const put_t = llvm.LLVMGlobalGetValueType(put_fn);
                    for (m.elements) |elem| {
                        if (elem.data == .call_expr and elem.data.call_expr.arguments.len >= 2) {
                            const k_val = try emitExpression(ctx, mod, builder, scope, structs, libs, elem.data.call_expr.arguments[0]);
                            const v_val = try emitExpression(ctx, mod, builder, scope, structs, libs, elem.data.call_expr.arguments[1]);
                            var p_args = [_]llvm.LLVMValueRef{ mmap_val, k_val, v_val };
                            _ = llvm.LLVMBuildCall2(builder, put_t, put_fn, &p_args, 3, "");
                        }
                    }

                    // 5. Map(entries=list)
                    var f_args = [_]llvm.LLVMValueRef{list_val};
                    const map_t = llvm.LLVMGlobalGetValueType(map_ctor);
                    return llvm.LLVMBuildCall2(builder, map_t, map_ctor, &f_args, 1, "map_literal");
                }
            }
            return llvm.LLVMConstNull(ptr_type);
        },
        .assignment => |a| {
            const func_val = llvm.LLVMGetBasicBlockParent(llvm.LLVMGetInsertBlock(builder));
            try statement.emitStatement(ctx, mod, builder, func_val, scope, structs, libs, node, null);
            const ret_t = llvm.LLVMGetReturnType(llvm.LLVMGlobalGetValueType(func_val));
            if (llvm.LLVMGetTypeKind(ret_t) == llvm.LLVMVoidTypeKind) {
                const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
                return llvm.LLVMConstNull(ptr_type);
            }
            // An assignment in expression position yields the assigned value
            // (mirrors the C backend; `{ x = 5 }` as a lambda body returns 5).
            const val = try emitExpression(ctx, mod, builder, scope, structs, libs, a.value);
            return coerceArg(builder, val, ret_t);
        },
        .as_expr => |as_e| {
            const val = try emitExpression(ctx, mod, builder, scope, structs, libs, as_e.value);
            // `Pointer as Type` is a memory view. The LLVM value model lays out
            // type structs WITHOUT the leading `_desc` header (the C backend
            // includes it), so a memory view must skip the 8-byte header: the
            // field offsets then line up with the real C layout.
            if (as_e.value.resolved_type) |v_rt| {
                if (ts.extractBaseType(v_rt).* == .Pointer) {
                    if (node.resolved_type) |nrt| {
                        if (ts.extractBaseType(nrt).* == .Custom) {
                            const ptr_t = llvm.LLVMPointerTypeInContext(ctx, 0);
                            const i64_t = llvm.LLVMInt64TypeInContext(ctx);
                            const as_int = llvm.LLVMBuildPtrToInt(builder, val, i64_t, "as_int");
                            const shifted = llvm.LLVMBuildAdd(builder, as_int, llvm.LLVMConstInt(i64_t, 8, 0), "as_shifted");
                            return llvm.LLVMBuildIntToPtr(builder, shifted, ptr_t, "as_ptr");
                        }
                    }
                }
            }
            // Numeric cast (Int <-> Double): a real runtime conversion.
            if (as_e.value.resolved_type) |v_rt| {
                const v_base = ts.extractBaseType(v_rt).*;
                if (node.resolved_type) |nrt| {
                    const n_base = ts.extractBaseType(nrt).*;
                    const is_num = struct {
                        fn f(t: ts.EiwaType) bool {
                            return switch (t) {
                                .Int, .Double => true,
                                .Custom => |n| std.mem.eql(u8, n, "core_Int") or std.mem.eql(u8, n, "core_Double") or std.mem.eql(u8, n, "Int") or std.mem.eql(u8, n, "Double"),
                                else => false,
                            };
                        }
                    }.f;
                    if (is_num(v_base) and is_num(n_base) and (v_base == .Int or (v_base == .Custom and std.mem.eql(u8, v_base.Custom, "core_Int"))) and (n_base == .Double or (n_base == .Custom and std.mem.eql(u8, n_base.Custom, "core_Double")))) {
                        const dbl_t = llvm.LLVMDoubleTypeInContext(ctx);
                        return llvm.LLVMBuildSIToFP(builder, val, dbl_t, "itod");
                    }
                    if (is_num(v_base) and is_num(n_base) and (v_base == .Double or (v_base == .Custom and std.mem.eql(u8, v_base.Custom, "core_Double"))) and (n_base == .Int or (n_base == .Custom and std.mem.eql(u8, n_base.Custom, "core_Int")))) {
                        const i64_t = llvm.LLVMInt64TypeInContext(ctx);
                        return llvm.LLVMBuildFPToSI(builder, val, i64_t, "dtoi");
                    }
                    if ((v_base == .Int or (v_base == .Custom and std.mem.eql(u8, v_base.Custom, "core_Int"))) and n_base == .Pointer) {
                        const ptr_t = llvm.LLVMPointerTypeInContext(ctx, 0);
                        return llvm.LLVMBuildIntToPtr(builder, val, ptr_t, "int_to_ptr");
                    }
                    if (v_base == .Pointer and (n_base == .Int or (n_base == .Custom and std.mem.eql(u8, n_base.Custom, "core_Int")))) {
                        const i64_t = llvm.LLVMInt64TypeInContext(ctx);
                        return llvm.LLVMBuildPtrToInt(builder, val, i64_t, "ptr_to_int");
                    }
                }
            }
            const target_rt_opt = node.resolved_type orelse as_e.type_ref.resolved_type;
            if (as_e.value.resolved_type) |v_rt| {
                if (target_rt_opt) |target_rt| {
                    if (types_mapping.isContractType(target_rt.*, global_contracts_ast_ptr)) {
                        const concrete_c = switch (v_rt.*) {
                            .Custom => |n| n,
                            .GenericInstance => |gi| gi.base_name,
                            else => "",
                        };
                        const target_c = switch (target_rt.*) {
                            .Custom => |n| n,
                            .GenericInstance => |gi| gi.base_name,
                            else => "",
                        };
                        if (concrete_c.len > 0 and target_c.len > 0) {
                            return coerceToContract(ctx, mod, builder, val, concrete_c, target_c) catch val;
                        }
                    }
                }
            }
            if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(val)) == llvm.LLVMStructTypeKind) {
                return llvm.LLVMBuildExtractValue(builder, val, 0, "fat_data");
            }
            return val;
        },
        else => {
            if (core.verbose) std.debug.print("LLVM Debug: unsupported expression node type {any}\n", .{node.data});
            return error.UnsupportedExpressionNode;
        },
    }
}

/// Emits a global constant null-terminated string buffer in LLVM IR,
/// handling escape sequences (\n, \t, \r, \xNN, etc.).
pub fn emitRawCharBuffer(
    ctx: llvm.LLVMContextRef,
    mod: llvm.LLVMModuleRef,
    builder: llvm.LLVMBuilderRef,
    str: []const u8,
) !llvm.LLVMValueRef {
    var unescaped = compat.ArrayList(u8).init(std.heap.page_allocator);
    defer unescaped.deinit();
    var i: usize = 0;
    while (i < str.len) : (i += 1) {
        if (str[i] == '\\' and i + 1 < str.len) {
            switch (str[i + 1]) {
                'n' => try unescaped.append('\n'),
                't' => try unescaped.append('\t'),
                'r' => try unescaped.append('\r'),
                'b' => try unescaped.append(0x08),
                '\\' => try unescaped.append('\\'),
                '"' => try unescaped.append('"'),
                '\'' => try unescaped.append('\''),
                'x' => {
                    if (i + 3 < str.len) {
                        const hi = hexDigit(str[i + 2]);
                        const lo = hexDigit(str[i + 3]);
                        if (hi) |h| {
                            if (lo) |l| {
                                try unescaped.append((h << 4) | l);
                                i += 3;
                                continue;
                            }
                        }
                    }
                    try unescaped.append('x');
                },
                else => try unescaped.append(str[i + 1]),
            }
            i += 1;
        } else {
            try unescaped.append(str[i]);
        }
    }
    const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
    const i64_type = llvm.LLVMInt64TypeInContext(ctx);
    const i8_type = llvm.LLVMInt8TypeInContext(ctx);

    const gc_alloc = core.getHeapAllocFn(mod);
    const gc_type = llvm.LLVMGlobalGetValueType(gc_alloc);

    const str_len = unescaped.items.len;
    var str_ga = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, @intCast(str_len + 1), 0)};
    const buf_raw = llvm.LLVMBuildCall2(builder, gc_type, gc_alloc, &str_ga, 1, "str_buf");
    const buf_ptr = llvm.LLVMBuildBitCast(builder, buf_raw, ptr_type, "str_buf_ptr");

    for (unescaped.items, 0..) |byte, idx| {
        var byte_idx = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, @intCast(idx), 0)};
        const byte_ptr = llvm.LLVMBuildGEP2(builder, i8_type, buf_ptr, &byte_idx, 1, "b_ptr");
        _ = llvm.LLVMBuildStore(builder, llvm.LLVMConstInt(i8_type, byte, 0), byte_ptr);
    }
    var nul_idx = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, @intCast(str_len), 0)};
    const nul_ptr = llvm.LLVMBuildGEP2(builder, i8_type, buf_ptr, &nul_idx, 1, "nul_ptr");
    _ = llvm.LLVMBuildStore(builder, llvm.LLVMConstInt(i8_type, 0, 0), nul_ptr);

    return buf_ptr;
}

pub fn emitStringLiteral(
    ctx: llvm.LLVMContextRef,
    mod: llvm.LLVMModuleRef,
    builder: llvm.LLVMBuilderRef,
    str: []const u8,
) !llvm.LLVMValueRef {
    const buf_ptr = try emitRawCharBuffer(ctx, mod, builder, str);
    const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
    const i64_type = llvm.LLVMInt64TypeInContext(ctx);
    var inst_fields = [_]llvm.LLVMTypeRef{ ptr_type, i64_type };
    const inst_struct_t = llvm.LLVMStructTypeInContext(ctx, &inst_fields, 2, 0);

    const gc_alloc = core.getHeapAllocFn(mod);
    const gc_type = llvm.LLVMGlobalGetValueType(gc_alloc);

    var ga = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, 16, 0)};
    const raw = llvm.LLVMBuildCall2(builder, gc_type, gc_alloc, &ga, 1, "str_lit");
    const inst_ptr = llvm.LLVMBuildBitCast(builder, raw, ptr_type, "str_inst");

    const f0_ptr = llvm.LLVMBuildStructGEP2(builder, inst_struct_t, inst_ptr, 0, "f0_ptr");
    _ = llvm.LLVMBuildStore(builder, buf_ptr, f0_ptr);

    const strlen_func = llvm.LLVMGetNamedFunction(mod, "strlen") orelse blk: {
        var ps = [_]llvm.LLVMTypeRef{ptr_type};
        const ft = llvm.LLVMFunctionType(i64_type, &ps, 1, 0);
        break :blk llvm.LLVMAddFunction(mod, "strlen", ft);
    };
    const strlen_type = llvm.LLVMGlobalGetValueType(strlen_func);
    var sl_args = [_]llvm.LLVMValueRef{buf_ptr};
    const len = llvm.LLVMBuildCall2(builder, strlen_type, strlen_func, &sl_args, 1, "lit_len");

    const f1_ptr = llvm.LLVMBuildStructGEP2(builder, inst_struct_t, inst_ptr, 1, "f1_ptr");
    _ = llvm.LLVMBuildStore(builder, len, f1_ptr);

    return inst_ptr;
}

/// Wraps a null-terminated char* into a String object (%core_String { ptr, length }):
/// allocates 16 bytes on the GC heap, stores ptr at offset 0 and length at offset 8.
fn wrapStringWithHeader(
    ctx: llvm.LLVMContextRef,
    mod: llvm.LLVMModuleRef,
    builder: llvm.LLVMBuilderRef,
    src: llvm.LLVMValueRef,
    name: [*:0]const u8,
) !llvm.LLVMValueRef {
    const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
    const i64_type = llvm.LLVMInt64TypeInContext(ctx);
    var inst_fields = [_]llvm.LLVMTypeRef{ ptr_type, i64_type };
    const inst_struct_t = llvm.LLVMStructTypeInContext(ctx, &inst_fields, 2, 0);

    const strlen_func = llvm.LLVMGetNamedFunction(mod, "strlen") orelse blk: {
        var ps = [_]llvm.LLVMTypeRef{ptr_type};
        const ft = llvm.LLVMFunctionType(i64_type, &ps, 1, 0);
        break :blk llvm.LLVMAddFunction(mod, "strlen", ft);
    };
    const strlen_type = llvm.LLVMGlobalGetValueType(strlen_func);
    var sl_args = [_]llvm.LLVMValueRef{src};
    const len = llvm.LLVMBuildCall2(builder, strlen_type, strlen_func, &sl_args, 1, "wrap_len");

    // Allocate 16 bytes for %core_String { ptr, length }
    const gc_alloc = core.getHeapAllocFn(mod);
    const gc_type = llvm.LLVMGlobalGetValueType(gc_alloc);
    var ga = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, 16, 0)};
    const raw = llvm.LLVMBuildCall2(builder, gc_type, gc_alloc, &ga, 1, name);
    const inst_ptr = llvm.LLVMBuildBitCast(builder, raw, ptr_type, "str_inst");

    const f0_ptr = llvm.LLVMBuildStructGEP2(builder, inst_struct_t, inst_ptr, 0, "f0_ptr");
    _ = llvm.LLVMBuildStore(builder, src, f0_ptr);

    const f1_ptr = llvm.LLVMBuildStructGEP2(builder, inst_struct_t, inst_ptr, 1, "f1_ptr");
    _ = llvm.LLVMBuildStore(builder, len, f1_ptr);

    return inst_ptr;
}

/// Returns the single non-null variant base type of a nullable union
/// (`T | null`), or null for multi-variant unions (which require runtime
/// discrimination).
fn unionPrimaryVariant(rt: *const ts.EiwaType) ?ts.EiwaType {
    var base = ts.extractBaseType(rt);
    while (base.* == .Union) {
        const u = base.Union;
        const left_null = u.left.* == .Null;
        const right_null = u.right.* == .Null;
        if (left_null and !right_null) {
            base = ts.extractBaseType(u.right);
        } else if (right_null and !left_null) {
            base = ts.extractBaseType(u.left);
        } else {
            return null;
        }
    }
    if (base.* == .Null or base.* == .Unknown) return null;
    return base.*;
}

/// Unboxes a union/boxed pointer value back to the raw scalar of `variant`
/// (Int → i64, Double → double, Bool → i1). String / Pointer / Custom variants
/// are already pointers and returned unchanged.
fn unboxUnionVariant(ctx: llvm.LLVMContextRef, builder: llvm.LLVMBuilderRef, variant: ts.EiwaType, boxed: llvm.LLVMValueRef) llvm.LLVMValueRef {
    const i64_t = llvm.LLVMInt64TypeInContext(ctx);
    switch (variant) {
        .Int => return llvm.LLVMBuildPtrToInt(builder, boxed, i64_t, "union_int"),
        .Bool => {
            const i64_val = llvm.LLVMBuildPtrToInt(builder, boxed, i64_t, "union_bool_i64");
            return llvm.LLVMBuildTrunc(builder, i64_val, llvm.LLVMInt1TypeInContext(ctx), "union_bool");
        },
        .Double => {
            const i64_val = llvm.LLVMBuildPtrToInt(builder, boxed, i64_t, "union_dbl_i64");
            return llvm.LLVMBuildBitCast(builder, i64_val, llvm.LLVMDoubleTypeInContext(ctx), "union_dbl");
        },
        else => return boxed,
    }
}

/// Emits a builtin primitive method (`toString` / `toInt` / `toDouble`) on a
/// nullable/union receiver (`T?`), honoring the safe-call (`?.`) null check and
/// boxing the result back into the union representation (a pointer).
fn emitUnionBuiltin(
    ctx: llvm.LLVMContextRef,
    mod: llvm.LLVMModuleRef,
    builder: llvm.LLVMBuilderRef,
    scope: *std.StringHashMap(llvm.LLVMValueRef),
    structs: *std.StringHashMap(core.StructInfo),
    libs: *const std.StringHashMap(std.StringHashMap([]const u8)),
    object: *ast.ASTNode,
    method: enum { to_string, to_int, to_double },
    is_safe: bool,
) !llvm.LLVMValueRef {
    const obj_rt = object.resolved_type orelse return error.UnsupportedUnionDispatch;
    const variant = unionPrimaryVariant(obj_rt) orelse return error.UnsupportedUnionDispatch;
    const obj_val = try emitExpression(ctx, mod, builder, scope, structs, libs, object);
    const ptr_t = llvm.LLVMPointerTypeInContext(ctx, 0);

    const emit_result = struct {
        fn run(
            c_ctx: llvm.LLVMContextRef,
            c_mod: llvm.LLVMModuleRef,
            c_builder: llvm.LLVMBuilderRef,
            c_variant: ts.EiwaType,
            c_boxed: llvm.LLVMValueRef,
            c_method: @TypeOf(method),
        ) !llvm.LLVMValueRef {
            switch (c_method) {
                .to_string => {
                    const is_str = switch (c_variant) {
                        .String => true,
                        .Custom => |n| std.mem.eql(u8, n, "String") or std.mem.eql(u8, n, "core_String") or std.mem.eql(u8, n, "std_core_String"),
                        else => false,
                    };
                    if (is_str) return c_boxed;
                    const unboxed = unboxUnionVariant(c_ctx, c_builder, c_variant, c_boxed);
                    return try emitValueToString(c_ctx, c_mod, c_builder, unboxed, &c_variant);
                },
                .to_int => {
                    const i64_t = llvm.LLVMInt64TypeInContext(c_ctx);
                    const unboxed = unboxUnionVariant(c_ctx, c_builder, c_variant, c_boxed);
                    const i64_val = switch (c_variant) {
                        .Double => llvm.LLVMBuildFPToSI(c_builder, unboxed, i64_t, "union_dbl_to_int"),
                        .Int => unboxed,
                        else => unboxed,
                    };
                    // Box back into the union pointer representation.
                    return llvm.LLVMBuildIntToPtr(c_builder, i64_val, llvm.LLVMPointerTypeInContext(c_ctx, 0), "union_int_box");
                },
                .to_double => {
                    const dbl_t = llvm.LLVMDoubleTypeInContext(c_ctx);
                    const unboxed = unboxUnionVariant(c_ctx, c_builder, c_variant, c_boxed);
                    const dbl_val = switch (c_variant) {
                        .Int => llvm.LLVMBuildSIToFP(c_builder, unboxed, dbl_t, "union_int_to_dbl"),
                        .Double => unboxed,
                        else => unboxed,
                    };
                    const i64_t = llvm.LLVMInt64TypeInContext(c_ctx);
                    const bits = llvm.LLVMBuildBitCast(c_builder, dbl_val, i64_t, "union_dbl_bits");
                    return llvm.LLVMBuildIntToPtr(c_builder, bits, llvm.LLVMPointerTypeInContext(c_ctx, 0), "union_dbl_box");
                },
            }
        }
    }.run;

    if (!is_safe) {
        return try emit_result(ctx, mod, builder, variant, obj_val, method);
    }

    const parent_func = llvm.LLVMGetBasicBlockParent(llvm.LLVMGetInsertBlock(builder));
    const then_bb = llvm.LLVMAppendBasicBlockInContext(ctx, parent_func, "safe_union_then");
    const else_bb = llvm.LLVMAppendBasicBlockInContext(ctx, parent_func, "safe_union_else");
    const merge_bb = llvm.LLVMAppendBasicBlockInContext(ctx, parent_func, "safe_union_merge");

    const is_null = llvm.LLVMBuildIsNull(builder, obj_val, "union_is_null");
    _ = llvm.LLVMBuildCondBr(builder, is_null, else_bb, then_bb);

    llvm.LLVMPositionBuilderAtEnd(builder, then_bb);
    const val_then = try emit_result(ctx, mod, builder, variant, obj_val, method);
    const then_end_bb = llvm.LLVMGetInsertBlock(builder);
    _ = llvm.LLVMBuildBr(builder, merge_bb);

    llvm.LLVMPositionBuilderAtEnd(builder, else_bb);
    const const_null = llvm.LLVMConstNull(ptr_t);
    const else_end_bb = llvm.LLVMGetInsertBlock(builder);
    _ = llvm.LLVMBuildBr(builder, merge_bb);

    llvm.LLVMPositionBuilderAtEnd(builder, merge_bb);
    const phi = llvm.LLVMBuildPhi(builder, ptr_t, "safe_union_val");
    var incoming_vals = [_]llvm.LLVMValueRef{ val_then, const_null };
    var incoming_bbs = [_]llvm.LLVMBasicBlockRef{ then_end_bb, else_end_bb };
    llvm.LLVMAddIncoming(phi, &incoming_vals, &incoming_bbs, 2);
    return phi;
}

/// Compares a nullable/union value (boxed pointer) against a scalar primitive
/// (`Double? == 42.0`, `Int? == 42`, `Bool? == true`), null-checking the union
/// first so `null` never compares equal to a zero scalar. Returns null when the
/// operand pair is not a (nullable union, scalar) combination.
fn emitNullableScalarCompare(
    ctx: llvm.LLVMContextRef,
    mod: llvm.LLVMModuleRef,
    builder: llvm.LLVMBuilderRef,
    left_val: llvm.LLVMValueRef,
    right_val: llvm.LLVMValueRef,
    left_rt: ?*const ts.EiwaType,
    right_rt: ?*const ts.EiwaType,
    is_eq: bool,
) !?llvm.LLVMValueRef {
    var is_union_left = false;
    const union_rt: ?*const ts.EiwaType = if (left_rt != null and left_rt.?.* == .Union) blk: {
        is_union_left = true;
        break :blk left_rt.?;
    } else if (right_rt != null and right_rt.?.* == .Union) blk: {
        break :blk right_rt.?;
    } else null;
    const urt = union_rt orelse return null;
    const variant = unionPrimaryVariant(urt) orelse return null;
    if (variant != .Int and variant != .Double and variant != .Bool) return null;

    const scalar_rt = if (is_union_left) right_rt else left_rt;
    const srt = scalar_rt orelse return null;
    const base = ts.extractBaseType(srt).*;
    const compatible = switch (variant) {
        .Double => base == .Double or base == .Int,
        .Int => base == .Int,
        .Bool => base == .Bool,
        else => false,
    };
    if (!compatible) return null;

    const union_val = if (is_union_left) left_val else right_val;
    var scalar_val = if (is_union_left) right_val else left_val;
    const i1_t = llvm.LLVMInt1TypeInContext(ctx);
    const dbl_t = llvm.LLVMDoubleTypeInContext(ctx);
    const i64_t = llvm.LLVMInt64TypeInContext(ctx);
    if (variant == .Double) scalar_val = coerceArg(builder, scalar_val, dbl_t);
    if (variant == .Int) scalar_val = coerceArg(builder, scalar_val, i64_t);

    const parent_func = llvm.LLVMGetBasicBlockParent(llvm.LLVMGetInsertBlock(builder));
    const then_bb = llvm.LLVMAppendBasicBlockInContext(ctx, parent_func, "nullable_cmp_then");
    const else_bb = llvm.LLVMAppendBasicBlockInContext(ctx, parent_func, "nullable_cmp_else");
    const merge_bb = llvm.LLVMAppendBasicBlockInContext(ctx, parent_func, "nullable_cmp_merge");

    const is_null = llvm.LLVMBuildIsNull(builder, union_val, "nullable_is_null");
    _ = llvm.LLVMBuildCondBr(builder, is_null, else_bb, then_bb);

    llvm.LLVMPositionBuilderAtEnd(builder, then_bb);
    const unboxed = unboxUnionVariant(ctx, builder, variant, union_val);
    const l_cmp = if (is_union_left) unboxed else scalar_val;
    const r_cmp = if (is_union_left) scalar_val else unboxed;
    const cmp_then = if (variant == .Double)
        (if (is_eq)
            llvm.LLVMBuildFCmp(builder, llvm.LLVMRealOEQ, l_cmp, r_cmp, "nullable_feq")
        else
            llvm.LLVMBuildFCmp(builder, llvm.LLVMRealUNE, l_cmp, r_cmp, "nullable_fne"))
    else
        (if (is_eq)
            llvm.LLVMBuildICmp(builder, llvm.LLVMIntEQ, l_cmp, r_cmp, "nullable_ieq")
        else
            llvm.LLVMBuildICmp(builder, llvm.LLVMIntNE, l_cmp, r_cmp, "nullable_ine"));
    const then_end_bb = llvm.LLVMGetInsertBlock(builder);
    _ = llvm.LLVMBuildBr(builder, merge_bb);

    llvm.LLVMPositionBuilderAtEnd(builder, else_bb);
    const null_result = llvm.LLVMConstInt(i1_t, if (is_eq) 0 else 1, 0);
    const else_end_bb = llvm.LLVMGetInsertBlock(builder);
    _ = llvm.LLVMBuildBr(builder, merge_bb);

    llvm.LLVMPositionBuilderAtEnd(builder, merge_bb);
    const phi = llvm.LLVMBuildPhi(builder, i1_t, "nullable_cmp_res");
    var incoming_vals = [_]llvm.LLVMValueRef{ cmp_then, null_result };
    var incoming_bbs = [_]llvm.LLVMBasicBlockRef{ then_end_bb, else_end_bb };
    llvm.LLVMAddIncoming(phi, &incoming_vals, &incoming_bbs, 2);
    _ = mod;
    return phi;
}

pub fn emitValueToString(
    ctx: llvm.LLVMContextRef,
    mod: llvm.LLVMModuleRef,
    builder: llvm.LLVMBuilderRef,
    val: llvm.LLVMValueRef,
    resolved_type: ?*const ts.EiwaType,
) !llvm.LLVMValueRef {
    const ptr_t = llvm.LLVMPointerTypeInContext(ctx, 0);
    const i64_t = llvm.LLVMInt64TypeInContext(ctx);

    if (resolved_type) |rt| {
        const base_rt = ts.extractBaseType(rt);
        switch (base_rt.*) {
            .Int => {
                const gc_func = core.getHeapAllocFn(mod);
                const gc_type = llvm.LLVMGlobalGetValueType(gc_func);
                const buf_size = llvm.LLVMConstInt(i64_t, 32, 0);
                var gc_args = [_]llvm.LLVMValueRef{buf_size};
                const buf = llvm.LLVMBuildCall2(builder, gc_type, gc_func, &gc_args, 1, "int_str_buf");

                const sprintf_func = llvm.LLVMGetNamedFunction(mod, "sprintf") orelse blk: {
                    var ps = [_]llvm.LLVMTypeRef{ ptr_t, ptr_t };
                    const ft = llvm.LLVMFunctionType(llvm.LLVMInt32TypeInContext(ctx), &ps, 2, 1);
                    break :blk llvm.LLVMAddFunction(mod, "sprintf", ft);
                };
                const sprintf_type = llvm.LLVMGlobalGetValueType(sprintf_func);
                const fmt = llvm.LLVMBuildGlobalStringPtr(builder, "%lld", "int_fmt");
                const int_val = coerceArg(builder, val, i64_t);
                var sprintf_args = [_]llvm.LLVMValueRef{ buf, fmt, int_val };
                _ = llvm.LLVMBuildCall2(builder, sprintf_type, sprintf_func, &sprintf_args, 3, "sprintf_res");
                return try wrapStringWithHeader(ctx, mod, builder, buf, "int_str");
            },
            .Bool => {
                const b_val = coerceArg(builder, val, llvm.LLVMInt1TypeInContext(ctx));
                const true_str = try emitStringLiteral(ctx, mod, builder, "true");
                const false_str = try emitStringLiteral(ctx, mod, builder, "false");
                return llvm.LLVMBuildSelect(builder, b_val, true_str, false_str, "bool_str");
            },
            .Double => {
                const gc_func = core.getHeapAllocFn(mod);
                const gc_type = llvm.LLVMGlobalGetValueType(gc_func);
                const buf_size = llvm.LLVMConstInt(i64_t, 64, 0);
                var gc_args = [_]llvm.LLVMValueRef{buf_size};
                const buf = llvm.LLVMBuildCall2(builder, gc_type, gc_func, &gc_args, 1, "double_str_buf");

                const sprintf_func = llvm.LLVMGetNamedFunction(mod, "sprintf") orelse blk: {
                    var ps = [_]llvm.LLVMTypeRef{ ptr_t, ptr_t };
                    const ft = llvm.LLVMFunctionType(llvm.LLVMInt32TypeInContext(ctx), &ps, 2, 1);
                    break :blk llvm.LLVMAddFunction(mod, "sprintf", ft);
                };
                const sprintf_type = llvm.LLVMGlobalGetValueType(sprintf_func);
                const dfmt = llvm.LLVMBuildGlobalStringPtr(builder, "%g", "double_fmt");
                const d_val = coerceArg(builder, val, llvm.LLVMDoubleTypeInContext(ctx));
                var sprintf_args = [_]llvm.LLVMValueRef{ buf, dfmt, d_val };
                _ = llvm.LLVMBuildCall2(builder, sprintf_type, sprintf_func, &sprintf_args, 3, "sprintf_res");
                return try wrapStringWithHeader(ctx, mod, builder, buf, "double_str");
            },
            .Custom => |name| {
                var buf_name: [128]u8 = undefined;
                var to_str_fn: ?llvm.LLVMValueRef = null;
                const to_str_mangled = std.fmt.bufPrint(&buf_name, "{s}_toString\x00", .{name}) catch "";
                if (to_str_mangled.len > 0) {
                    to_str_fn = llvm.LLVMGetNamedFunction(mod, to_str_mangled.ptr);
                }
                if (to_str_fn == null) {
                    var fn_it = llvm.LLVMGetFirstFunction(mod);
                    while (fn_it) |curr_fn| : (fn_it = llvm.LLVMGetNextFunction(curr_fn)) {
                        const fn_name_c = llvm.LLVMGetValueName(curr_fn);
                        const fn_name_s = std.mem.span(fn_name_c);
                        if (std.mem.endsWith(u8, fn_name_s, "_toString") and (std.mem.indexOf(u8, fn_name_s, name) != null or std.mem.eql(u8, fn_name_s, "toString"))) {
                            to_str_fn = curr_fn;
                            break;
                        }
                    }
                }
                if (to_str_fn) |fn_val| {
                    const to_str_type = llvm.LLVMGlobalGetValueType(fn_val);
                    const self_ptr = coerceArg(builder, val, ptr_t);
                    var args = [_]llvm.LLVMValueRef{self_ptr};
                    return llvm.LLVMBuildCall2(builder, to_str_type, fn_val, &args, 1, "to_str_call");
                }
            },
            else => {},
        }
    }

    const to_str_fn = llvm.LLVMGetNamedFunction(mod, "eiwa_to_string").?;
    const to_str_type = llvm.LLVMGlobalGetValueType(to_str_fn);
    const p_val = coerceArg(builder, val, ptr_t);
    var ts_args = [_]llvm.LLVMValueRef{p_val};
    return llvm.LLVMBuildCall2(builder, to_str_type, to_str_fn, &ts_args, 1, "ts_fallback");
}

/// `coerceArg` unifies argument types at function and contract call boundaries,
/// performing necessary boxing/unboxing between raw scalar integers and pointers.
/// Serves as the centralized choke-point for all argument coercion.
pub fn coerceArg(
    builder: llvm.LLVMBuilderRef,
    arg_val: llvm.LLVMValueRef,
    param_type: llvm.LLVMTypeRef,
) llvm.LLVMValueRef {
    const arg_type = llvm.LLVMTypeOf(arg_val);
    const arg_kind = llvm.LLVMGetTypeKind(arg_type);
    const param_kind = llvm.LLVMGetTypeKind(param_type);

    if ((arg_kind == llvm.LLVMPointerTypeKind or arg_kind == llvm.LLVMIntegerTypeKind or arg_kind == llvm.LLVMDoubleTypeKind) and param_kind == llvm.LLVMStructTypeKind) {
        const ptr_t = llvm.LLVMPointerTypeInContext(llvm.LLVMGetTypeContext(param_type), 0);
        const data_ptr = if (arg_kind == llvm.LLVMPointerTypeKind)
            arg_val
        else if (arg_kind == llvm.LLVMIntegerTypeKind)
            llvm.LLVMBuildIntToPtr(builder, arg_val, ptr_t, "int_ptr")
        else blk: {
            const i64_t = llvm.LLVMInt64TypeInContext(llvm.LLVMGetTypeContext(param_type));
            const i64_val = llvm.LLVMBuildBitCast(builder, arg_val, i64_t, "dbl_bits");
            break :blk llvm.LLVMBuildIntToPtr(builder, i64_val, ptr_t, "dbl_ptr");
        };
        const fat_type = types_mapping.getFatPointerType(llvm.LLVMGetTypeContext(param_type));
        const undef_fat = llvm.LLVMGetUndef(fat_type);
        const fat_with_data = llvm.LLVMBuildInsertValue(builder, undef_fat, data_ptr, 0, "fat_data");
        const null_vtable = llvm.LLVMConstNull(ptr_t);
        return llvm.LLVMBuildInsertValue(builder, fat_with_data, null_vtable, 1, "fat_val");
    }
    if (arg_kind == llvm.LLVMStructTypeKind and param_kind == llvm.LLVMPointerTypeKind) {
        const parent_bb = llvm.LLVMGetInsertBlock(builder);
        const mod = llvm.LLVMGetGlobalParent(llvm.LLVMGetBasicBlockParent(parent_bb));
        const c_ctx = llvm.LLVMGetTypeContext(param_type);
        const gc_alloc = core.getHeapAllocFn(mod);
        const sz = llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(c_ctx), 16, 0);
        const ft2 = llvm.LLVMGlobalGetValueType(gc_alloc);
        var args = [_]llvm.LLVMValueRef{sz};
        const heap_ptr = llvm.LLVMBuildCall2(builder, ft2, gc_alloc, &args, 1, "fat_box");
        _ = llvm.LLVMBuildStore(builder, arg_val, heap_ptr);
        return heap_ptr;
    }

    if (arg_kind == llvm.LLVMIntegerTypeKind and param_kind == llvm.LLVMIntegerTypeKind) {
        const arg_width = llvm.LLVMGetIntTypeWidth(arg_type);
        const param_width = llvm.LLVMGetIntTypeWidth(param_type);
        if (arg_width < param_width) {
            return llvm.LLVMBuildZExt(builder, arg_val, param_type, "zext_arg");
        } else if (arg_width > param_width) {
            return llvm.LLVMBuildTrunc(builder, arg_val, param_type, "trunc_arg");
        }
    }
    if (arg_kind == llvm.LLVMIntegerTypeKind and param_kind == llvm.LLVMDoubleTypeKind) {
        return llvm.LLVMBuildSIToFP(builder, arg_val, param_type, "int2double");
    }
    if (arg_kind == llvm.LLVMDoubleTypeKind and param_kind == llvm.LLVMIntegerTypeKind) {
        return llvm.LLVMBuildFPToSI(builder, arg_val, param_type, "double2int");
    }
    if (arg_kind == llvm.LLVMIntegerTypeKind and param_kind == llvm.LLVMPointerTypeKind) {
        return llvm.LLVMBuildIntToPtr(builder, arg_val, param_type, "box_arg");
    }
    if (arg_kind == llvm.LLVMDoubleTypeKind and param_kind == llvm.LLVMPointerTypeKind) {
        const i64_t = llvm.LLVMInt64TypeInContext(llvm.LLVMGetTypeContext(param_type));
        const bitcasted = llvm.LLVMBuildBitCast(builder, arg_val, i64_t, "dbl_to_i64");
        return llvm.LLVMBuildIntToPtr(builder, bitcasted, param_type, "box_dbl");
    }
    if (arg_kind == llvm.LLVMPointerTypeKind and param_kind == llvm.LLVMDoubleTypeKind) {
        const i64_t = llvm.LLVMInt64TypeInContext(llvm.LLVMGetTypeContext(param_type));
        const int_val = llvm.LLVMBuildPtrToInt(builder, arg_val, i64_t, "unbox_dbl_i64");
        return llvm.LLVMBuildBitCast(builder, int_val, param_type, "unbox_dbl");
    }
    if (arg_kind == llvm.LLVMPointerTypeKind and param_kind == llvm.LLVMIntegerTypeKind) {
        return llvm.LLVMBuildPtrToInt(builder, arg_val, param_type, "unbox_arg");
    }
    return arg_val;
}

/// Returns a value safe to `store` into `dest_type`. A void-typed value (the
/// result of a void-returning call, e.g. `result = block()` in
/// `Task<Void>.run()`) is not a valid store operand — LLVM's
/// `DataLayout::getTypeSizeInBits(void)` hits an `llvm_unreachable` that loops
/// forever in release builds, hanging the compiler. A nullable Void (`T?`
/// where T=Void) can only ever hold null, so a null constant of the
/// destination type is stored instead. Returns null when the store must be
/// skipped entirely (destination type is also void).
pub fn storeValue(val: llvm.LLVMValueRef, dest_type: llvm.LLVMTypeRef) ?llvm.LLVMValueRef {
    if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(val)) != llvm.LLVMVoidTypeKind) return val;
    if (llvm.LLVMGetTypeKind(dest_type) == llvm.LLVMVoidTypeKind) return null;
    return llvm.LLVMConstNull(dest_type);
}

/// Coerces a concrete type value (data_ptr) into a Fat Pointer { data, vtable } for a target contract.
/// Resolves the static vtable global symbol for a concrete type implementing a
/// contract, mirroring the multi-stage short-name fallback used by
/// `coerceToContract`. Returns null when no such vtable global exists in the
/// module. Used by `when (x) is SomeType` on contract subjects to type-check by
/// vtable identity.
fn isRealVtable(g: llvm.LLVMValueRef) bool {
    if (llvm.LLVMIsGlobalConstant(g) == 0) return false;
    const t = llvm.LLVMGlobalGetValueType(g);
    if (llvm.LLVMGetTypeKind(t) != llvm.LLVMStructTypeKind) return false;
    // Empty-struct vtables are legitimate: contracts with no methods (e.g.
    // `contract SerdeValue`) produce `constant {}`. Stubs created on the fly by
    // coerceToContract are `global {}` (not constant), so the constant check
    // above already excludes them. Extern vtable DECLARATIONS (split-emission
    // units, see docs/perf-plan-incremental-cache.md) carry no initializer —
    // they are still real vtables, defined by the owning unit at link time.
    return true;
}

fn lookupNamedVtable(mod: llvm.LLVMModuleRef, name_z: [:0]const u8) ?llvm.LLVMValueRef {
    if (llvm.LLVMGetNamedGlobal(mod, name_z.ptr)) |g| {
        if (isRealVtable(g)) return g;
    }
    return null;
}

pub fn findVtableGlobal(ctx: llvm.LLVMContextRef, mod: llvm.LLVMModuleRef, concrete_c_name: []const u8, contract_c_name: []const u8) anyerror!?llvm.LLVMValueRef {
    _ = ctx;
    var buf: [256]u8 = undefined;

    if (std.fmt.bufPrintZ(&buf, "{s}_{s}_vtable", .{ concrete_c_name, contract_c_name })) |name_z| {
        if (lookupNamedVtable(mod, name_z)) |g| return g;
    } else |_| {}

    var short_contract = contract_c_name;
    if (std.mem.lastIndexOfScalar(u8, contract_c_name, '_')) |idx| short_contract = contract_c_name[idx + 1 ..];
    var short_concrete = concrete_c_name;
    if (std.mem.lastIndexOfScalar(u8, concrete_c_name, '_')) |idx| short_concrete = concrete_c_name[idx + 1 ..];

    if (std.fmt.bufPrintZ(&buf, "{s}_{s}_vtable", .{ concrete_c_name, short_contract })) |name_z| {
        if (lookupNamedVtable(mod, name_z)) |g| return g;
    } else |_| {}

    if (std.fmt.bufPrintZ(&buf, "{s}_{s}_vtable", .{ short_concrete, short_contract })) |name_z| {
        if (lookupNamedVtable(mod, name_z)) |g| return g;
    } else |_| {}

    if (std.fmt.bufPrintZ(&buf, "core_{s}_{s}_vtable", .{ short_concrete, short_contract })) |name_z| {
        if (lookupNamedVtable(mod, name_z)) |g| return g;
    } else |_| {}

    if (std.fmt.bufPrintZ(&buf, "std_core_{s}_{s}_vtable", .{ short_concrete, short_contract })) |name_z| {
        if (lookupNamedVtable(mod, name_z)) |g| return g;
    } else |_| {}

    if (std.fmt.bufPrintZ(&buf, "core_{s}_core_{s}_vtable", .{ short_concrete, short_contract })) |name_z| {
        if (lookupNamedVtable(mod, name_z)) |g| return g;
    } else |_| {}

    if (std.fmt.bufPrintZ(&buf, "std_core_{s}_core_{s}_vtable", .{ short_concrete, short_contract })) |name_z| {
        if (lookupNamedVtable(mod, name_z)) |g| return g;
    } else |_| {}

    if (std.fmt.bufPrintZ(&buf, "std_core_{s}_std_core_{s}_vtable", .{ short_concrete, short_contract })) |name_z| {
        if (lookupNamedVtable(mod, name_z)) |g| return g;
    } else |_| {}

    // Fallback: search for a vtable belonging to this concrete type AND contract
    var g_it = llvm.LLVMGetFirstGlobal(mod);
    while (g_it) |g| : (g_it = llvm.LLVMGetNextGlobal(g)) {
        const g_name_ptr = llvm.LLVMGetValueName(g);
        const g_name_s = std.mem.span(g_name_ptr);
        if (std.mem.endsWith(u8, g_name_s, "_vtable") and
            (std.mem.startsWith(u8, g_name_s, concrete_c_name) or std.mem.startsWith(u8, g_name_s, short_concrete)))
        {
            if (short_contract.len == 0 or std.mem.containsAtLeast(u8, g_name_s, 1, short_contract)) {
                return g;
            }
        }
    }

    return null;
}

pub fn coerceToContract(
    ctx: llvm.LLVMContextRef,
    mod: llvm.LLVMModuleRef,
    builder: llvm.LLVMBuilderRef,
    data_val: llvm.LLVMValueRef,
    concrete_c_name: []const u8,
    contract_c_name: []const u8,
) !llvm.LLVMValueRef {
    const fat_type = types_mapping.getFatPointerType(ctx);
    if (llvm.LLVMTypeOf(data_val) == fat_type) {
        return data_val;
    }

    const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);

    // Box integer/bool/double values if needed
    var data_ptr = data_val;
    if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(data_val)) == llvm.LLVMIntegerTypeKind) {
        data_ptr = llvm.LLVMBuildIntToPtr(builder, data_val, ptr_type, "fat_data_box");
    } else if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(data_val)) == llvm.LLVMDoubleTypeKind) {
        const i64_t = llvm.LLVMInt64TypeInContext(ctx);
        const i64_val = llvm.LLVMBuildBitCast(builder, data_val, i64_t, "dbl_bits");
        data_ptr = llvm.LLVMBuildIntToPtr(builder, i64_val, ptr_type, "fat_data_box");
    }

    const vtable_global = try findVtableGlobal(ctx, mod, concrete_c_name, contract_c_name);

    const vtable_ptr = vtable_global orelse blk: {
        const vname = try std.fmt.allocPrint(std.heap.page_allocator, "{s}_{s}_vtable\x00", .{ concrete_c_name, contract_c_name });
        defer std.heap.page_allocator.free(vname);
        const empty_struct = llvm.LLVMStructTypeInContext(ctx, null, 0, 0);
        const g = llvm.LLVMAddGlobal(mod, empty_struct, vname.ptr);
        llvm.LLVMSetInitializer(g, llvm.LLVMConstNull(empty_struct));
        break :blk g;
    };

    var fat_val = llvm.LLVMGetUndef(fat_type);
    fat_val = llvm.LLVMBuildInsertValue(builder, fat_val, data_ptr, 0, "fat_data");
    fat_val = llvm.LLVMBuildInsertValue(builder, fat_val, vtable_ptr, 1, "fat_vtable");

    return fat_val;
}

/// Like `coerceToContract`, but fails when no real (non-stub) vtable exists for
/// the (concrete, contract) pair. Used by fallback scans that must not attach a
/// stub vtable to a fat pointer.
pub fn coerceToContractChecked(
    ctx: llvm.LLVMContextRef,
    mod: llvm.LLVMModuleRef,
    builder: llvm.LLVMBuilderRef,
    data_val: llvm.LLVMValueRef,
    concrete_c_name: []const u8,
    contract_c_name: []const u8,
) !llvm.LLVMValueRef {
    const fat_type = types_mapping.getFatPointerType(ctx);
    if (llvm.LLVMTypeOf(data_val) == fat_type) {
        return data_val;
    }
    const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
    var data_ptr = data_val;
    if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(data_val)) == llvm.LLVMIntegerTypeKind) {
        data_ptr = llvm.LLVMBuildIntToPtr(builder, data_val, ptr_type, "fat_data_box");
    } else if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(data_val)) == llvm.LLVMDoubleTypeKind) {
        const i64_t = llvm.LLVMInt64TypeInContext(ctx);
        const i64_val = llvm.LLVMBuildBitCast(builder, data_val, i64_t, "dbl_bits");
        data_ptr = llvm.LLVMBuildIntToPtr(builder, i64_val, ptr_type, "fat_data_box");
    }
    const vtable_global = try findVtableGlobal(ctx, mod, concrete_c_name, contract_c_name) orelse return error.ContractVtableNotFound;
    var fat_val = llvm.LLVMGetUndef(fat_type);
    fat_val = llvm.LLVMBuildInsertValue(builder, fat_val, data_ptr, 0, "fat_data");
    fat_val = llvm.LLVMBuildInsertValue(builder, fat_val, vtable_global, 1, "fat_vtable");
    return fat_val;
}

fn isStringOperandType(rt: *const ts.EiwaType) bool {
    const base_rt = ts.extractBaseType(rt);
    return switch (base_rt.*) {
        .String => true,
        .Custom => |n| std.mem.eql(u8, n, "core_String") or std.mem.eql(u8, n, "String") or std.mem.eql(u8, n, "std_core_String"),
        .Union => |u| isStringOperandType(u.left) or isStringOperandType(u.right),
        else => false,
    };
}

fn isStringOperand(node: *ast.ASTNode) bool {
    if (node.data == .string_literal) return true;
    const rt = node.resolved_type orelse return false;
    return isStringOperandType(rt);
}

fn isStrictString(node: *ast.ASTNode) bool {
    if (node.data == .string_literal) return true;
    const rt = node.resolved_type orelse return false;
    const base_rt = ts.extractBaseType(rt);
    return switch (base_rt.*) {
        .String => true,
        .Custom => |n| std.mem.eql(u8, n, "core_String") or std.mem.eql(u8, n, "String") or std.mem.eql(u8, n, "std_core_String"),
        else => false,
    };
}

/// Returns the resolved C name of a custom (non-primitive) type that declares
/// an `equals` method, or null. Mirrors the C backend's `string_or_custom_type`
/// + `has_equals` logic: unwraps nullable wrappers, excludes primitives and
/// String (handled separately), and requires a `{name}_equals` function to be
/// present in the module.
fn customEqualsClass(node: *ast.ASTNode, mod: llvm.LLVMModuleRef) ?[]const u8 {
    const rt = node.resolved_type orelse return null;
    var base = ts.extractBaseType(rt);
    var depth: usize = 0;
    while (depth < 8) : (depth += 1) {
        switch (base.*) {
            .Union => |u| {
                if (u.right.* == .Null) {
                    base = ts.extractBaseType(u.left);
                } else {
                    return null;
                }
            },
            .Pointer => base = ts.extractBaseType(base.Pointer),
            else => break,
        }
    }
    if (base.* != .Custom) return null;
    const cn = base.Custom;
    if (std.mem.eql(u8, cn, "core_String") or std.mem.eql(u8, cn, "String") or std.mem.eql(u8, cn, "std_core_String") or
        std.mem.eql(u8, cn, "core_Int") or std.mem.eql(u8, cn, "Int") or
        std.mem.eql(u8, cn, "core_Double") or std.mem.eql(u8, cn, "Double") or
        std.mem.eql(u8, cn, "core_Bool") or std.mem.eql(u8, cn, "Bool")) return null;
    const fn_name = std.fmt.allocPrint(std.heap.page_allocator, "{s}_equals", .{cn}) catch return null;
    defer std.heap.page_allocator.free(fn_name);
    const fn_z = std.heap.page_allocator.dupeZ(u8, fn_name) catch return null;
    defer std.heap.page_allocator.free(fn_z);
    if (llvm.LLVMGetNamedFunction(mod, fn_z.ptr) == null) return null;
    return cn;
}

/// Emits the custom-type `==` short-circuit used by the C backend:
/// `(a == b) || (a != 0 && b != 0 && {class_name}_equals(a, b))`.
/// Builds control-flow blocks since LLVM has no `||`/`&&` short-circuit op.
fn emitCustomEquals(
    ctx: llvm.LLVMContextRef,
    mod: llvm.LLVMModuleRef,
    builder: llvm.LLVMBuilderRef,
    left_val: llvm.LLVMValueRef,
    right_val: llvm.LLVMValueRef,
    class_name: []const u8,
) anyerror!llvm.LLVMValueRef {
    const i1_type = llvm.LLVMInt1TypeInContext(ctx);
    const fn_name = try std.fmt.allocPrint(std.heap.page_allocator, "{s}_equals", .{class_name});
    defer std.heap.page_allocator.free(fn_name);
    const fn_name_z = try std.heap.page_allocator.dupeZ(u8, fn_name);
    defer std.heap.page_allocator.free(fn_name_z);
    const eq_fn = llvm.LLVMGetNamedFunction(mod, fn_name_z.ptr) orelse return error.EqualsFunctionNotFound;

    const func_val = llvm.LLVMGetBasicBlockParent(llvm.LLVMGetInsertBlock(builder));
    const ptr_eq_bb = llvm.LLVMGetInsertBlock(builder);
    const ptr_eq = llvm.LLVMBuildICmp(builder, llvm.LLVMIntEQ, left_val, right_val, "eq_ptr");

    const guard_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "eq_guard");
    const call_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "eq_call");
    const merge_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "eq_merge");
    _ = llvm.LLVMBuildCondBr(builder, ptr_eq, merge_bb, guard_bb);

    llvm.LLVMPositionBuilderAtEnd(builder, guard_bb);
    const a_nz = llvm.LLVMBuildIsNotNull(builder, left_val, "eq_a_nz");
    const b_nz = llvm.LLVMBuildIsNotNull(builder, right_val, "eq_b_nz");
    const both = llvm.LLVMBuildAnd(builder, a_nz, b_nz, "eq_both_nz");
    const guard_end = llvm.LLVMGetInsertBlock(builder);
    _ = llvm.LLVMBuildCondBr(builder, both, call_bb, merge_bb);

    llvm.LLVMPositionBuilderAtEnd(builder, call_bb);
    const eq_fn_type = llvm.LLVMGlobalGetValueType(eq_fn);
    const param_count: usize = @intCast(llvm.LLVMCountParamTypes(eq_fn_type));
    const param_types = try std.heap.page_allocator.alloc(llvm.LLVMTypeRef, param_count);
    defer std.heap.page_allocator.free(param_types);
    llvm.LLVMGetParamTypes(eq_fn_type, param_types.ptr);
    var arg0 = left_val;
    var arg1: llvm.LLVMValueRef = undefined;
    if (param_count >= 2) {
        arg0 = coerceArg(builder, left_val, param_types[0]);
        if (llvm.LLVMGetTypeKind(param_types[1]) == llvm.LLVMStructTypeKind) {
            arg1 = try coerceToContract(ctx, mod, builder, right_val, class_name, "");
        } else {
            arg1 = coerceArg(builder, right_val, param_types[1]);
        }
    } else {
        arg1 = coerceArg(builder, right_val, llvm.LLVMPointerTypeInContext(ctx, 0));
    }    var eq_args = [_]llvm.LLVMValueRef{ arg0, arg1 };
    const eq_res = llvm.LLVMBuildCall2(builder, eq_fn_type, eq_fn, &eq_args, 2, "eq_res");
    const call_end = llvm.LLVMGetInsertBlock(builder);
    _ = llvm.LLVMBuildBr(builder, merge_bb);

    llvm.LLVMPositionBuilderAtEnd(builder, merge_bb);
    const phi = llvm.LLVMBuildPhi(builder, i1_type, "eq_phi");
    const t_val = llvm.LLVMConstInt(i1_type, 1, 0);
    const f_val = llvm.LLVMConstInt(i1_type, 0, 0);
    var in_vals = [_]llvm.LLVMValueRef{ t_val, f_val, eq_res };
    var in_bbs = [_]llvm.LLVMBasicBlockRef{ ptr_eq_bb, guard_end, call_end };
    llvm.LLVMAddIncoming(phi, &in_vals, &in_bbs, 3);
    return phi;
}

/// Maps the element type of an .Array-typed expression to its LLVM load type
/// for the raw buffer slots (8 bytes each). Reference types load as ptr,
/// Double as double (bitcast-compatible 8-byte slot), everything else as i64.
pub fn arrayElemLLVMType(ctx: llvm.LLVMContextRef, obj_rt: ?*const ts.EiwaType) llvm.LLVMTypeRef {
    if (obj_rt) |rt| {
        const base_rt = ts.extractBaseType(rt);
        if (base_rt.* == .Array) {
            return scalarElemLLVMType(ctx, base_rt.Array);
        }
        if (base_rt.* == .GenericInstance) {
            const targs = base_rt.GenericInstance.type_args;
            if (targs.len > 0) return scalarElemLLVMType(ctx, targs[0]);
        }
        if (base_rt.* == .Custom) {
            if (global_classes_ast_ptr) |ca| {
                if (ca.get(base_rt.Custom)) |c_node| {
                    if (c_node.data == .type_decl and c_node.data.type_decl.primary_constructor.len > 0) {
                        const first_prop = c_node.data.type_decl.primary_constructor[0];
                        if (first_prop.resolved_type) |prt| {
                            const p_base = ts.extractBaseType(prt);
                            if (p_base.* == .Array) {
                                return scalarElemLLVMType(ctx, p_base.Array);
                            }
                        }
                    }
                }
            }
        }
    }
    return llvm.LLVMInt64TypeInContext(ctx);
}

/// LLVM type used to store a single array element. Fat pointers (contract
/// values) map to `{ ptr, ptr }`; reference types map to pointers; scalars map
/// to their native type. Mirrors the C backend's element-type handling.
pub fn scalarElemLLVMType(ctx: llvm.LLVMContextRef, elem_t: *const ts.EiwaType) llvm.LLVMTypeRef {
    if (types_mapping.isContractType(elem_t.*, global_contracts_ast_ptr)) {
        return types_mapping.getFatPointerType(ctx);
    }
    switch (elem_t.*) {
        .Custom, .String, .Pointer, .Array, .Union, .Function, .GenericInstance => return llvm.LLVMPointerTypeInContext(ctx, 0),
        .Double => return llvm.LLVMDoubleTypeInContext(ctx),
        else => return llvm.LLVMInt64TypeInContext(ctx),
    }
}

/// Byte stride between consecutive array element slots in the raw buffer.
/// The buffer header (slot 0 = size, slot 1 = capacity) is always 16 bytes;
/// element slots occupy `elemStride` bytes each. Fat pointers (contract
/// values) are 16 bytes; everything else fits the legacy 8-byte slot model.
pub fn arrayElemStride(ctx: llvm.LLVMContextRef, elem_llvm_type: llvm.LLVMTypeRef) i64 {
    _ = ctx;
    if (llvm.LLVMGetTypeKind(elem_llvm_type) == llvm.LLVMStructTypeKind) return 16;
    return 8;
}

/// Builds a typed pointer to array element `idx`, whose base offset in the raw
/// buffer is `16 + idx * stride` (header is 2 x i64 slots). The returned pointer
/// is typed as `*elem_type` so loads/stores use the correct width.
pub fn arrayElemTypedPtr(
    builder: llvm.LLVMBuilderRef,
    ctx: llvm.LLVMContextRef,
    arr_ptr: llvm.LLVMValueRef,
    idx: llvm.LLVMValueRef,
    elem_llvm_type: llvm.LLVMTypeRef,
    stride: i64,
    name: [*c]const u8,
) llvm.LLVMValueRef {
    _ = elem_llvm_type;
    const i64_type = llvm.LLVMInt64TypeInContext(ctx);
    const i8_type = llvm.LLVMInt8TypeInContext(ctx);
    const header_bytes = llvm.LLVMConstInt(i64_type, 16, 0);
    const scaled = if (stride == 1)
        idx
    else
        llvm.LLVMBuildMul(builder, idx, llvm.LLVMConstInt(i64_type, @intCast(stride), 0), "elem_scaled");
    const byte_off = llvm.LLVMBuildAdd(builder, header_bytes, scaled, "elem_byte_off");
    var off_idx = [_]llvm.LLVMValueRef{byte_off};
    const i8_ptr = llvm.LLVMBuildGEP2(builder, i8_type, arr_ptr, &off_idx, 1, "elem_i8_ptr");
    const elem_ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
    const elem_type_ptr = llvm.LLVMBuildPointerCast(builder, i8_ptr, llvm.LLVMPointerTypeInContext(ctx, 0), name);
    _ = elem_ptr_type;
    return elem_type_ptr;
}

fn arrayLiteralElementContractName(node: *ast.ASTNode) []const u8 {
    const rt = node.resolved_type orelse return "";
    const base_rt = ts.extractBaseType(rt);
    if (base_rt.* == .GenericInstance and base_rt.GenericInstance.type_args.len > 0) {
        const ta = base_rt.GenericInstance.type_args[0].*;
        const c = switch (ta) {
            .Custom => |n| n,
            .GenericInstance => |gi| gi.base_name,
            else => "",
        };
        if (c.len > 0 and types_mapping.isContractType(ta, global_contracts_ast_ptr)) return c;
    } else if (base_rt.* == .Custom) {
        const name = base_rt.Custom;
        for ([_][]const u8{ "collections_List_", "collections_MutableList_" }) |p| {
            if (std.mem.startsWith(u8, name, p)) {
                const type_arg = name[p.len..];
                if (global_contracts_ast_ptr) |ca| {
                    if (ca.contains(type_arg)) return type_arg;
                    if (std.mem.lastIndexOfScalar(u8, type_arg, '_')) |idx| {
                        const short = type_arg[idx + 1 ..];
                        if (ca.contains(short)) return type_arg;
                    }
                }
            }
        }
    }
    return "";
}

fn arrayLiteralElementLLVMType(ctx: llvm.LLVMContextRef, node: *ast.ASTNode) llvm.LLVMTypeRef {
    const rt = node.resolved_type orelse return llvm.LLVMInt64TypeInContext(ctx);
    const base_rt = ts.extractBaseType(rt);
    if (base_rt.* == .Array) return arrayElemLLVMType(ctx, base_rt);

    // Monomorphized collection literal: `List<T>` / `MutableList<T>` resolve to
    // a `.Custom` struct whose element type arg is embedded in the name
    // (e.g. `collections_List_core_Stringable`). Contract element types become
    // fat pointers; everything else keeps the legacy 8-byte slot layout.
    var elem_t: llvm.LLVMTypeRef = llvm.LLVMInt64TypeInContext(ctx);
    var type_arg: []const u8 = "";
    if (base_rt.* == .GenericInstance and base_rt.GenericInstance.type_args.len > 0) {
        const ta = base_rt.GenericInstance.type_args[0].*;
        elem_t = scalarElemLLVMType(ctx, &ta);
        type_arg = switch (ta) {
            .Custom => |n| n,
            .GenericInstance => |gi| gi.base_name,
            else => "",
        };
    } else if (base_rt.* == .Custom) {
        const name = base_rt.Custom;
        var prefix: []const u8 = "";
        for ([_][]const u8{ "collections_List_", "collections_MutableList_" }) |p| {
            if (std.mem.startsWith(u8, name, p)) {
                prefix = p;
                break;
            }
        }
        if (prefix.len > 0) {
            type_arg = name[prefix.len..];
        }
    }
    if (type_arg.len > 0) {
        if (global_contracts_ast_ptr) |ca| {
            var is_contract = ca.contains(type_arg);
            if (!is_contract) {
                if (std.mem.lastIndexOfScalar(u8, type_arg, '_')) |idx| {
                    is_contract = ca.contains(type_arg[idx + 1 ..]);
                }
            }
            if (is_contract) {
                elem_t = types_mapping.getFatPointerType(ctx);
            }
        }
    }
    return elem_t;
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
/// slot 1 = capacity, slots 2.. = elements), growing via the active heap
/// reallocator (GC_realloc when prefer_gc_alloc — matching the C backend's
/// GC_REALLOC in EiwaArray_push) and writing the (possibly moved) buffer
/// pointer back to the lvalue.
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
    const elem_type = arrayElemLLVMType(ctx, object_node.resolved_type);
    const elem_stride = arrayElemStride(ctx, elem_type);

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
    const grow_bytes = llvm.LLVMBuildMul(builder, new_cap, llvm.LLVMConstInt(i64_type, @intCast(elem_stride), 0), "grow_bytes");
    const new_bytes = llvm.LLVMBuildAdd(builder, llvm.LLVMConstInt(i64_type, 16, 0), grow_bytes, "new_bytes");

    const realloc_fn = core.getHeapReallocFn(mod);
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

    const elem_ptr_name = try std.heap.page_allocator.dupeZ(u8, "push_elem_ptr");
    defer std.heap.page_allocator.free(elem_ptr_name);
    const elem_ptr = arrayElemTypedPtr(builder, ctx, phi, size_val, elem_type, elem_stride, elem_ptr_name.ptr);
    _ = llvm.LLVMBuildStore(builder, val, elem_ptr);

    const new_size = llvm.LLVMBuildAdd(builder, size_val, llvm.LLVMConstInt(i64_type, 1, 0), "new_size");
    var phi_idx0 = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, 0, 0)};
    const phi_size_ptr = llvm.LLVMBuildGEP2(builder, i64_type, phi, &phi_idx0, 1, "phi_size_ptr");
    _ = llvm.LLVMBuildStore(builder, new_size, phi_size_ptr);

    _ = llvm.LLVMBuildStore(builder, phi, arr_addr);
    return val;
}

fn emitBlockOrExpr(
    ctx: llvm.LLVMContextRef,
    mod: llvm.LLVMModuleRef,
    builder: llvm.LLVMBuilderRef,
    func_val: llvm.LLVMValueRef,
    scope: *std.StringHashMap(llvm.LLVMValueRef),
    structs: *std.StringHashMap(core.StructInfo),
    libs: *const std.StringHashMap(std.StringHashMap([]const u8)),
    node: *ast.ASTNode,
    res_ptr: ?llvm.LLVMValueRef,
) !void {
    if (node.data == .block) {
        const stmts = node.data.block.statements;
        if (stmts.len > 0) {
            for (stmts[0 .. stmts.len - 1]) |s| {
                try statement.emitStatement(ctx, mod, builder, func_val, scope, structs, libs, s, null);
            }
            const last_stmt = stmts[stmts.len - 1];
            switch (last_stmt.data) {
                .var_decl, .return_stmt, .while_stmt, .try_stmt, .throw_stmt, .block => {
                    try statement.emitStatement(ctx, mod, builder, func_val, scope, structs, libs, last_stmt, null);
                },
                else => {
                    const val = try emitExpression(ctx, mod, builder, scope, structs, libs, last_stmt);
                    if (res_ptr) |rp| {
                        if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(val)) != llvm.LLVMVoidTypeKind) {
                            _ = llvm.LLVMBuildStore(builder, val, rp);
                        }
                    }
                },
            }
        }
    } else {
        const val = try emitExpression(ctx, mod, builder, scope, structs, libs, node);
        if (res_ptr) |rp| {
            if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(val)) != llvm.LLVMVoidTypeKind) {
                _ = llvm.LLVMBuildStore(builder, val, rp);
            }
        }
    }
}

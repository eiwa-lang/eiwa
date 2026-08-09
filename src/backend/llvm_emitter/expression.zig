const std = @import("std");
const ast = @import("../../core/ast.zig");
const ts = @import("../../core/type_system.zig");
const compat = @import("../../core/compat.zig");
const types_mapping = @import("types.zig");
const statement = @import("statement.zig");
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
            if (i.is_class_property) return;
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
                try captures.append(.{ .name = i.name, .llvm_type = llvm_t });
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
                    try captures.append(.{ .name = a.name, .llvm_type = llvm_t });
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

/// Returns a monotonically increasing counter for unique lambda naming.
/// Uses a file-level variable (safe: single-threaded compilation).
var lambda_counter_val: usize = 0;
fn lambdaCounter() usize {
    const c = lambda_counter_val;
    lambda_counter_val += 1;
    return c;
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
                if (llvm.LLVMGetTypeKind(val_type) == llvm.LLVMPointerTypeKind) {
                    const elem_type = if (llvm.LLVMIsAAllocaInst(var_val) != null)
                        llvm.LLVMGetAllocatedType(var_val)
                    else if (node.resolved_type) |res_type|
                        (if (types_mapping.isContractType(res_type.*, global_contracts_ast_ptr)) types_mapping.getFatPointerType(ctx) else types_mapping.getLLVMType(ctx, res_type.*))
                    else
                        llvm.LLVMPointerTypeInContext(ctx, 0);
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

            std.debug.print("LLVM Emitter Error: Variable '{s}' not found in local or global scope.\n", .{name});
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
                // String.length — LLVM models String as a bare char*, so length
                // calls C's strlen directly.
                // TODO(emitter): SPECIAL CASE — review before promoting LLVM to default
                // backend. Bypasses method dispatch on String. If String is ever
                // materialized as a struct (e.g. length + ptr), this should read the field instead.
                if ((base == .String or base == .Pointer) and std.mem.eql(u8, get.name, "length")) {
                    const str_ptr = try emitExpression(ctx, mod, builder, scope, structs, libs, get.object);
                    const strlen_fn = llvm.LLVMGetNamedFunction(mod, "strlen") orelse blk: {
                        const p = llvm.LLVMPointerTypeInContext(ctx, 0);
                        var ps = [_]llvm.LLVMTypeRef{p};
                        const ft = llvm.LLVMFunctionType(llvm.LLVMInt64TypeInContext(ctx), &ps, 1, 0);
                        break :blk llvm.LLVMAddFunction(mod, "strlen", ft);
                    };
                    const ft = llvm.LLVMGlobalGetValueType(strlen_fn);
                    var args = [_]llvm.LLVMValueRef{str_ptr};
                    return llvm.LLVMBuildCall2(builder, ft, strlen_fn, &args, 1, "strlen_tmp");
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
                        if (obj_base == .Int) {
                            const i64_type = llvm.LLVMInt64TypeInContext(ctx);
                            const gc_func = llvm.LLVMGetNamedFunction(mod, "malloc") orelse llvm.LLVMGetNamedFunction(mod, "GC_malloc").?;
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
                            return buf;
                        } else if (obj_base == .Bool) {
                            const fn_val = llvm.LLVMGetNamedFunction(mod, "eiwa_to_string") orelse return error.ToStringHelperNotFound;
                            const fn_type = llvm.LLVMGlobalGetValueType(fn_val);
                            const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
                            const arg_val = llvm.LLVMBuildIntToPtr(builder, obj_val, ptr_type, "tostr_box");
                            var args = [_]llvm.LLVMValueRef{arg_val};
                            return llvm.LLVMBuildCall2(builder, fn_type, fn_val, &args, 1, "tostr_tmp");
                        } else if (obj_base == .Double) {
                            const i64_type = llvm.LLVMInt64TypeInContext(ctx);
                            const gc_func = llvm.LLVMGetNamedFunction(mod, "malloc") orelse llvm.LLVMGetNamedFunction(mod, "GC_malloc").?;
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
                            return buf;
                        } else {
                            const fn_val = llvm.LLVMGetNamedFunction(mod, "eiwa_to_string") orelse return error.ToStringHelperNotFound;
                            const fn_type = llvm.LLVMGlobalGetValueType(fn_val);
                            var args = [_]llvm.LLVMValueRef{obj_val};
                            return llvm.LLVMBuildCall2(builder, fn_type, fn_val, &args, 1, "tostr_tmp");
                        }
                    }
                }
            }

            // Primitive method: Double.toInt() and Int.toDouble()
            // TODO(emitter): SPECIAL CASE — review before promoting LLVM to default
            // backend. Primitive type conversions (Double <-> Int) bypass standard
            // method dispatch and emit direct LLVM cast instructions (FPToSI / SIToFP).
            if (std.mem.eql(u8, get.name, "toInt")) {
                if (get.object.resolved_type) |obj_rt| {
                    if (obj_rt.* == .Double) {
                        const obj_val = try emitExpression(ctx, mod, builder, scope, structs, libs, get.object);
                        return llvm.LLVMBuildFPToSI(builder, obj_val, llvm.LLVMInt64TypeInContext(ctx), "double_to_int");
                    } else if (obj_rt.* == .Int) {
                        return try emitExpression(ctx, mod, builder, scope, structs, libs, get.object);
                    }
                }
            }
            if (std.mem.eql(u8, get.name, "toDouble")) {
                if (get.object.resolved_type) |obj_rt| {
                    if (obj_rt.* == .Int) {
                        const obj_val = try emitExpression(ctx, mod, builder, scope, structs, libs, get.object);
                        return llvm.LLVMBuildSIToFP(builder, obj_val, llvm.LLVMDoubleTypeInContext(ctx), "int_to_double");
                    } else if (obj_rt.* == .Double) {
                        return try emitExpression(ctx, mod, builder, scope, structs, libs, get.object);
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
                    const obj_is_string = obj_base == .String or
                        (obj_base == .Custom and (std.mem.eql(u8, obj_base.Custom, "String") or std.mem.eql(u8, obj_base.Custom, "core_String")));
                    if (obj_is_string or obj_base == .Pointer) {
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
                } else if (get.object.data == .string_literal) {
                    const obj_val = try emitExpression(ctx, mod, builder, scope, structs, libs, get.object);
                    const fn_val = llvm.LLVMGetNamedFunction(mod, "eiwa_hash_string") orelse return error.HashStringHelperNotFound;
                    const fn_type = llvm.LLVMGlobalGetValueType(fn_val);
                    var args = [_]llvm.LLVMValueRef{obj_val};
                    return llvm.LLVMBuildCall2(builder, fn_type, fn_val, &args, 1, "hash_tmp");
                }
            }

            if (get.object.data == .identifier) {
                const id_name = get.object.data.identifier.name;
                const obj_c_name = get.object.data.identifier.resolved_c_name orelse id_name;
                if (scope.get(id_name) == null and scope.get(obj_c_name) == null) {
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
                }) else true;
                if (is_str) {
                    const strlen_func = llvm.LLVMGetNamedFunction(mod, "strlen") orelse blk: {
                        const i8_ptr = llvm.LLVMPointerTypeInContext(ctx, 0);
                        const fn_type = llvm.LLVMFunctionType(llvm.LLVMInt64TypeInContext(ctx), @constCast(&i8_ptr), 1, 0);
                        break :blk llvm.LLVMAddFunction(mod, "strlen", fn_type);
                    };
                    const strlen_type = llvm.LLVMGlobalGetValueType(strlen_func);
                    var str_args = [_]llvm.LLVMValueRef{obj_val};
                    return llvm.LLVMBuildCall2(builder, strlen_type, strlen_func, &str_args, 1, "str_len");
                }
            }
            if (get.object.resolved_type) |rt| {
                var base_rt = ts.extractBaseType(rt);
                if (base_rt.* == .String or (base_rt.* == .Custom and (std.mem.eql(u8, base_rt.Custom, "String") or std.mem.eql(u8, base_rt.Custom, "core_String") or std.mem.eql(u8, base_rt.Custom, "std_core_String")))) {
                    if (std.mem.eql(u8, get.name, "ptr") or std.mem.eql(u8, get.name, "data")) {
                        return obj_val;
                    }
                }
                while (base_rt.* == .Union or base_rt.* == .Pointer) {
                    if (base_rt.* == .Union) {
                        if (base_rt.Union.left.* != .Null) {
                            base_rt = ts.extractBaseType(base_rt.Union.left);
                        } else {
                            base_rt = ts.extractBaseType(base_rt.Union.right);
                        }
                    } else if (base_rt.* == .Pointer) {
                        base_rt = ts.extractBaseType(base_rt.Pointer);
                    }
                }
                var type_name: []const u8 = "";
                if (base_rt.* == .Custom) {
                    type_name = base_rt.Custom;
                } else if (base_rt.* == .GenericInstance) {
                    type_name = base_rt.GenericInstance.base_name;
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
                        if (std.mem.eql(u8, f_name, get.name)) {
                            const field_name_z = try std.heap.page_allocator.dupeZ(u8, f_name);
                            defer std.heap.page_allocator.free(field_name_z);

                            if (get.is_safe) {
                                const parent_func = llvm.LLVMGetBasicBlockParent(llvm.LLVMGetInsertBlock(builder));
                                const then_bb = llvm.LLVMAppendBasicBlockInContext(ctx, parent_func, "safe_get_then");
                                const else_bb = llvm.LLVMAppendBasicBlockInContext(ctx, parent_func, "safe_get_else");
                                const merge_bb = llvm.LLVMAppendBasicBlockInContext(ctx, parent_func, "safe_get_merge");

                                const ptr_to_check = if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(obj_val)) == llvm.LLVMStructTypeKind)
                                    llvm.LLVMBuildExtractValue(builder, obj_val, 0, "fat_data_ptr")
                                else
                                    obj_val;
                                const is_null = llvm.LLVMBuildIsNull(builder, ptr_to_check, "is_null");
                                _ = llvm.LLVMBuildCondBr(builder, is_null, else_bb, then_bb);

                                llvm.LLVMPositionBuilderAtEnd(builder, then_bb);
                                const field_ptr = llvm.LLVMBuildStructGEP2(builder, s_info.struct_type, obj_val, @intCast(f_idx), field_name_z.ptr);
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
                                const field_ptr = llvm.LLVMBuildStructGEP2(builder, s_info.struct_type, obj_val, @intCast(f_idx), field_name_z.ptr);
                                const field_type = s_info.field_types[f_idx];
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
            std.debug.print("LLVM Debug: PropertyNotFound get.name={s} obj.resolved_type={any}\n", .{ get.name, if (get.object.resolved_type) |rt| rt.* else null });
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
                    _ = llvm.LLVMBuildStore(builder, val, global_var);
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
                } else if (base_rt.* == .Pointer and base_rt.Pointer.* == .Custom) {
                    type_name = base_rt.Pointer.Custom;
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
            var arr_ptr = try emitExpression(ctx, mod, builder, scope, structs, libs, idx_expr.object);
            if (idx_expr.object.resolved_type) |rt| {
                const base_rt = ts.extractBaseType(rt);
                if (base_rt.* == .Custom or base_rt.* == .GenericInstance) {
                    const type_name = if (base_rt.* == .Custom) base_rt.Custom else base_rt.GenericInstance.base_name;
                    var s_info_opt = structs.get(type_name);
                    if (s_info_opt == null) {
                        var it = structs.iterator();
                        while (it.next()) |entry| {
                            const k = entry.key_ptr.*;
                            if (std.mem.eql(u8, k, type_name) or std.mem.endsWith(u8, k, type_name) or (std.mem.startsWith(u8, type_name, "MutableList") and std.mem.indexOf(u8, k, "MutableList") != null) or (std.mem.eql(u8, type_name, "List") and std.mem.indexOf(u8, k, "List") != null and std.mem.indexOf(u8, k, "MutableList") == null)) {
                                s_info_opt = entry.value_ptr.*;
                                break;
                            }
                        }
                    }
                    if (s_info_opt) |s_info| {
                        const f0_ptr = llvm.LLVMBuildStructGEP2(builder, s_info.struct_type, arr_ptr, 0, "wrapper_list_ptr");
                        const f0_type = s_info.field_types[0];
                        arr_ptr = llvm.LLVMBuildLoad2(builder, f0_type, f0_ptr, "inner_arr_ptr");
                        // If MutableList -> List (still a struct pointer wrapper), unwrap second layer to NativeArray
                        if (std.mem.startsWith(u8, type_name, "MutableList")) {
                            var it2 = structs.iterator();
                            while (it2.next()) |entry2| {
                                const k2 = entry2.key_ptr.*;
                                if (std.mem.indexOf(u8, k2, "List") != null and std.mem.indexOf(u8, k2, "MutableList") == null) {
                                    const s2_info = entry2.value_ptr.*;
                                    const f02_ptr = llvm.LLVMBuildStructGEP2(builder, s2_info.struct_type, arr_ptr, 0, "wrapper_list_ptr2");
                                    const f02_type = s2_info.field_types[0];
                                    arr_ptr = llvm.LLVMBuildLoad2(builder, f02_type, f02_ptr, "inner_arr_ptr2");
                                    break;
                                }
                            }
                        }
                    }
                }
            }
            const i_val = try emitExpression(ctx, mod, builder, scope, structs, libs, idx_expr.index);

            const i64_type = llvm.LLVMInt64TypeInContext(ctx);
            const offset_val = llvm.LLVMBuildAdd(builder, i_val, llvm.LLVMConstInt(i64_type, 2, 0), "offset");
            var elem_idx = [_]llvm.LLVMValueRef{offset_val};
            const elem_ptr = llvm.LLVMBuildGEP2(builder, i64_type, arr_ptr, &elem_idx, 1, "arr_idx_gep");
            const elem_type = arrayElemLLVMType(ctx, idx_expr.object.resolved_type);
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
                        var it = structs.iterator();
                        while (it.next()) |entry| {
                            const k = entry.key_ptr.*;
                            if (std.mem.eql(u8, k, type_name) or std.mem.endsWith(u8, k, type_name) or (std.mem.startsWith(u8, type_name, "MutableList") and std.mem.indexOf(u8, k, "MutableList") != null) or (std.mem.eql(u8, type_name, "List") and std.mem.indexOf(u8, k, "List") != null and std.mem.indexOf(u8, k, "MutableList") == null)) {
                                s_info_opt = entry.value_ptr.*;
                                break;
                            }
                        }
                    }
                    if (s_info_opt) |s_info| {
                        const f0_ptr = llvm.LLVMBuildStructGEP2(builder, s_info.struct_type, arr_ptr, 0, "wrapper_list_ptr");
                        const f0_type = s_info.field_types[0];
                        arr_ptr = llvm.LLVMBuildLoad2(builder, f0_type, f0_ptr, "inner_arr_ptr");
                        if (std.mem.startsWith(u8, type_name, "MutableList")) {
                            var it2 = structs.iterator();
                            while (it2.next()) |entry2| {
                                const k2 = entry2.key_ptr.*;
                                if (std.mem.indexOf(u8, k2, "List") != null and std.mem.indexOf(u8, k2, "MutableList") == null) {
                                    const s2_info = entry2.value_ptr.*;
                                    const f02_ptr = llvm.LLVMBuildStructGEP2(builder, s2_info.struct_type, arr_ptr, 0, "wrapper_list_ptr2");
                                    const f02_type = s2_info.field_types[0];
                                    arr_ptr = llvm.LLVMBuildLoad2(builder, f02_type, f02_ptr, "inner_arr_ptr2");
                                    break;
                                }
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
                        const is_zero = llvm.LLVMBuildICmp(builder, llvm.LLVMIntEQ, operand_val, llvm.LLVMConstInt(val_type, 0, 0), "is_zero");
                        return llvm.LLVMBuildZExt(builder, is_zero, val_type, "not_bool");
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

            const is_double = if (bin.left.resolved_type) |t| (t.* == .Double) else false;

            if (bin.op == .plus and (isStringOperand(bin.left) or isStringOperand(bin.right))) {
                const ptr_t = llvm.LLVMPointerTypeInContext(ctx, 0);
                const i64_t = llvm.LLVMInt64TypeInContext(ctx);
                const to_str_fn = llvm.LLVMGetNamedFunction(mod, "eiwa_to_string").?;
                const to_str_type = llvm.LLVMGlobalGetValueType(to_str_fn);

                if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(left_val)) == llvm.LLVMIntegerTypeKind) {
                    left_val = llvm.LLVMBuildIntToPtr(builder, left_val, ptr_t, "l_int2ptr");
                }
                if (!isStringOperand(bin.left)) {
                    var ts_args = [_]llvm.LLVMValueRef{left_val};
                    left_val = llvm.LLVMBuildCall2(builder, to_str_type, to_str_fn, &ts_args, 1, "l_str");
                }

                if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(right_val)) == llvm.LLVMIntegerTypeKind) {
                    right_val = llvm.LLVMBuildIntToPtr(builder, right_val, ptr_t, "r_int2ptr");
                }
                if (!isStringOperand(bin.right)) {
                    var ts_args = [_]llvm.LLVMValueRef{right_val};
                    right_val = llvm.LLVMBuildCall2(builder, to_str_type, to_str_fn, &ts_args, 1, "r_str");
                }

                const empty_str = llvm.LLVMBuildGlobalStringPtr(builder, "", "empty_str");
                const left_safe = llvm.LLVMBuildSelect(builder, llvm.LLVMBuildIsNull(builder, left_val, "l_null"), empty_str, left_val, "l_safe");
                const right_safe = llvm.LLVMBuildSelect(builder, llvm.LLVMBuildIsNull(builder, right_val, "r_null"), empty_str, right_val, "r_safe");

                const strlen_func = llvm.LLVMGetNamedFunction(mod, "strlen") orelse return error.StrlenNotFound;
                const strlen_type = llvm.LLVMGlobalGetValueType(strlen_func);
                var sl_args = [_]llvm.LLVMValueRef{left_safe};
                const len_a = llvm.LLVMBuildCall2(builder, strlen_type, strlen_func, &sl_args, 1, "strlen_a");
                var sr_args = [_]llvm.LLVMValueRef{right_safe};
                const len_b = llvm.LLVMBuildCall2(builder, strlen_type, strlen_func, &sr_args, 1, "strlen_b");
                const total = llvm.LLVMBuildAdd(builder, len_a, len_b, "concat_len");
                const total_plus_one = llvm.LLVMBuildAdd(builder, total, llvm.LLVMConstInt(i64_t, 1, 0), "concat_len1");

                const gc_func = llvm.LLVMGetNamedFunction(mod, "malloc") orelse llvm.LLVMGetNamedFunction(mod, "GC_malloc").?;
                const gc_type = llvm.LLVMGlobalGetValueType(gc_func);
                var gc_args = [_]llvm.LLVMValueRef{total_plus_one};
                const buf = llvm.LLVMBuildCall2(builder, gc_type, gc_func, &gc_args, 1, "concat_buf");

                const strcpy_fn = llvm.LLVMGetNamedFunction(mod, "strcpy") orelse blk: {
                    const p = llvm.LLVMPointerTypeInContext(ctx, 0);
                    var ps = [_]llvm.LLVMTypeRef{ p, p };
                    const ft = llvm.LLVMFunctionType(p, &ps, 2, 0);
                    break :blk llvm.LLVMAddFunction(mod, "strcpy", ft);
                };
                const strcpy_type = llvm.LLVMGlobalGetValueType(strcpy_fn);
                var sc_args = [_]llvm.LLVMValueRef{ buf, left_safe };
                _ = llvm.LLVMBuildCall2(builder, strcpy_type, strcpy_fn, &sc_args, 2, "concat_cpy");

                const strcat_fn = llvm.LLVMGetNamedFunction(mod, "strcat") orelse blk: {
                    const p = llvm.LLVMPointerTypeInContext(ctx, 0);
                    var ps = [_]llvm.LLVMTypeRef{ p, p };
                    const ft = llvm.LLVMFunctionType(p, &ps, 2, 0);
                    break :blk llvm.LLVMAddFunction(mod, "strcat", ft);
                };
                const strcat_type = llvm.LLVMGlobalGetValueType(strcat_fn);
                var cat_args = [_]llvm.LLVMValueRef{ buf, right_safe };
                _ = llvm.LLVMBuildCall2(builder, strcat_type, strcat_fn, &cat_args, 2, "concat_cat");

                return buf;
            }

            if (!is_double) {
                const l_type = llvm.LLVMTypeOf(left_val);
                const r_type = llvm.LLVMTypeOf(right_val);
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
                    if (isStringOperand(bin.left) or isStringOperand(bin.right)) {
                        const seq_fn = llvm.LLVMGetNamedFunction(mod, "eiwa_string_equals") orelse return error.StringEqualsNotFound;
                        const seq_type = llvm.LLVMGlobalGetValueType(seq_fn);
                        var args = [_]llvm.LLVMValueRef{ left_val, right_val };
                        return llvm.LLVMBuildCall2(builder, seq_type, seq_fn, &args, 2, "streq_tmp");
                    }
                    if (bin.right.data == .null_literal and llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(left_val)) == llvm.LLVMStructTypeKind) {
                        const data_ptr = llvm.LLVMBuildExtractValue(builder, left_val, 0, "eq_null_data");
                        return llvm.LLVMBuildIsNull(builder, data_ptr, "eq_null");
                    }
                    if (bin.left.data == .null_literal and llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(right_val)) == llvm.LLVMStructTypeKind) {
                        const data_ptr = llvm.LLVMBuildExtractValue(builder, right_val, 0, "eq_null_data");
                        return llvm.LLVMBuildIsNull(builder, data_ptr, "eq_null");
                    }
                    return llvm.LLVMBuildICmp(builder, llvm.LLVMIntEQ, left_val, right_val, "eqtmp");
                },
                .bang_eq => {
                    if (is_double) return llvm.LLVMBuildFCmp(builder, llvm.LLVMRealUNE, left_val, right_val, "fnetmp");
                    if (isStringOperand(bin.left) or isStringOperand(bin.right)) {
                        const seq_fn = llvm.LLVMGetNamedFunction(mod, "eiwa_string_equals") orelse return error.StringEqualsNotFound;
                        const seq_type = llvm.LLVMGlobalGetValueType(seq_fn);
                        var args = [_]llvm.LLVMValueRef{ left_val, right_val };
                        const seq_res = llvm.LLVMBuildCall2(builder, seq_type, seq_fn, &args, 2, "streq_tmp");
                        const zero = llvm.LLVMConstInt(llvm.LLVMTypeOf(seq_res), 0, 0);
                        return llvm.LLVMBuildICmp(builder, llvm.LLVMIntEQ, seq_res, zero, "strne_tmp");
                    }
                    if (bin.right.data == .null_literal and llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(left_val)) == llvm.LLVMStructTypeKind) {
                        const data_ptr = llvm.LLVMBuildExtractValue(builder, left_val, 0, "ne_null_data");
                        return llvm.LLVMBuildIsNotNull(builder, data_ptr, "ne_null");
                    }
                    if (bin.left.data == .null_literal and llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(right_val)) == llvm.LLVMStructTypeKind) {
                        const data_ptr = llvm.LLVMBuildExtractValue(builder, right_val, 0, "ne_null_data");
                        return llvm.LLVMBuildIsNotNull(builder, data_ptr, "ne_null");
                    }
                    return llvm.LLVMBuildICmp(builder, llvm.LLVMIntNE, left_val, right_val, "netmp");
                },
                .and_and => return llvm.LLVMBuildAnd(builder, left_val, right_val, "andtmp"),
                .or_or => return llvm.LLVMBuildOr(builder, left_val, right_val, "ortmp"),
                else => return error.UnsupportedBinaryOperator,
            }
        },
        .lambda_expr => |lam| {
            const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
            const i64_type = llvm.LLVMInt64TypeInContext(ctx);

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
                param_types[i] = i64_type;
            }
            // Handle implicit `it` param
            var it_param_type: ?llvm.LLVMTypeRef = null;
            if (lam.params.len == 0) {
                if (node.resolved_type) |rt| {
                    if (rt.* == .Function and rt.Function.params.len == 1) {
                        it_param_type = types_mapping.getLLVMTypeWithContracts(ctx, rt.Function.params[0].*, global_contracts_ast_ptr);
                    }
                }
            }

            var ret_type: llvm.LLVMTypeRef = llvm.LLVMVoidTypeInContext(ctx);
            if (node.resolved_type) |rt| {
                if (rt.* == .Function) {
                    ret_type = types_mapping.getLLVMTypeWithContracts(ctx, rt.Function.return_type.*, global_contracts_ast_ptr);
                }
            }

            // --- Step 3: Build env struct type (only when there are captures) ------
            const has_captures = captures.items.len > 0;
            var cap_type_arr = try std.heap.page_allocator.alloc(llvm.LLVMTypeRef, captures.items.len);
            defer std.heap.page_allocator.free(cap_type_arr);
            for (captures.items, 0..) |cap, ci| cap_type_arr[ci] = cap.llvm_type;
            // env_struct_type is only used inside `if (has_captures)` blocks below
            const env_struct_type = llvm.LLVMStructTypeInContext(ctx, cap_type_arr.ptr, @intCast(captures.items.len), 0);

            // --- Step 4: Build LLVM function signature (ptr_env, params...) → ret ---
            const n_user_params = if (it_param_type != null) @as(usize, 1) else lam.params.len;
            var full_param_types = try std.heap.page_allocator.alloc(llvm.LLVMTypeRef, 1 + n_user_params);
            defer std.heap.page_allocator.free(full_param_types);
            full_param_types[0] = ptr_type; // env
            if (it_param_type) |ipt| {
                full_param_types[1] = ipt;
            } else {
                for (param_types, 0..) |pt, idx| full_param_types[1 + idx] = pt;
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
            if (it_param_type != null) {
                const param_val = llvm.LLVMGetParam(func_val, 1);
                const alloca_ptr = llvm.LLVMBuildAlloca(builder, it_param_type.?, "it");
                _ = llvm.LLVMBuildStore(builder, param_val, alloca_ptr);
                try lam_scope.put("it", alloca_ptr);
            } else {
                for (lam.params, 0..) |p, i| {
                    const param_val = llvm.LLVMGetParam(func_val, @intCast(1 + i));
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
                    const field_ptr = llvm.LLVMBuildGEP2(builder, env_struct_type, env_param, &gep_idx, 2, cap_name_z.ptr);
                    const field_val = llvm.LLVMBuildLoad2(builder, cap.llvm_type, field_ptr, "cap_val");
                    const alloca_ptr = llvm.LLVMBuildAlloca(builder, cap.llvm_type, cap_name_z.ptr);
                    _ = llvm.LLVMBuildStore(builder, field_val, alloca_ptr);
                    try lam_scope.put(cap.name, alloca_ptr);
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
                    try statement.emitStatement(ctx, mod, builder, func_val, &lam_scope, structs, libs, stmt);
                }
                const last = lam.body[last_idx];
                if (last.data == .return_stmt) {
                    // Already a return — emit normally, terminator will be set
                    try statement.emitStatement(ctx, mod, builder, func_val, &lam_scope, structs, libs, last);
                } else {
                    // Implicit return: evaluate the expression and return its value
                    const ret_val = try emitExpression(ctx, mod, builder, &lam_scope, structs, libs, last);
                    _ = llvm.LLVMBuildRet(builder, ret_val);
                }
            } else {
                for (lam.body) |stmt| {
                    try statement.emitStatement(ctx, mod, builder, func_val, &lam_scope, structs, libs, stmt);
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

            // Get the malloc/GC_malloc function
            const malloc_fn = llvm.LLVMGetNamedFunction(mod, "malloc") orelse
                llvm.LLVMGetNamedFunction(mod, "GC_malloc") orelse return error.MallocNotFound;
            const malloc_type = llvm.LLVMGlobalGetValueType(malloc_fn);

            // Allocate and fill the env struct
            const env_ptr: llvm.LLVMValueRef = if (has_captures) blk: {
                const env_size = llvm.LLVMSizeOf(env_struct_type);
                var env_alloc_args = [_]llvm.LLVMValueRef{env_size};
                const env_mem = llvm.LLVMBuildCall2(builder, malloc_type, malloc_fn, &env_alloc_args, 1, "env_mem");
                // Fill each field with the current value from the outer scope
                for (captures.items, 0..) |cap, ci| {
                    const cap_name_for_scope = cap.name;
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
                    var gep_idx = [_]llvm.LLVMValueRef{
                        llvm.LLVMConstInt(llvm.LLVMInt32TypeInContext(ctx), 0, 0),
                        llvm.LLVMConstInt(llvm.LLVMInt32TypeInContext(ctx), @intCast(ci), 0),
                    };
                    const field_ptr = llvm.LLVMBuildGEP2(builder, env_struct_type, env_mem, &gep_idx, 2, "env_field");
                    _ = llvm.LLVMBuildStore(builder, outer_val, field_ptr);
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
                                try statement.emitStatement(ctx, mod, builder, llvm.LLVMGetBasicBlockParent(llvm.LLVMGetInsertBlock(builder)), &lam_scope, structs, libs, stmt);
                            }
                        }
                        return last_val;
                    }
                }

                const target_func_init = if (std.mem.indexOf(u8, callee_name, "randomBytes") != null)
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
                    // Fallback lookup if callee_name is mangled in LLVM module (e.g. log_Logger)
                    var func_it = llvm.LLVMGetFirstFunction(mod);
                    while (func_it) |f| : (func_it = llvm.LLVMGetNextFunction(f)) {
                        const name_ptr = llvm.LLVMGetValueName(f);
                        const f_name = std.mem.span(name_ptr);
                        const target_suffix = try std.fmt.allocPrint(std.heap.page_allocator, "_{s}", .{callee_name});
                        defer std.heap.page_allocator.free(target_suffix);
                        const init_suffix = try std.fmt.allocPrint(std.heap.page_allocator, "_{s}_init", .{callee_name});
                        defer std.heap.page_allocator.free(init_suffix);
                        const ctor_type_name = try std.fmt.allocPrint(std.heap.page_allocator, "{s}_type", .{callee_name});
                        defer std.heap.page_allocator.free(ctor_type_name);
                        if (std.mem.eql(u8, f_name, ctor_type_name) or std.mem.endsWith(u8, f_name, target_suffix) or std.mem.endsWith(u8, f_name, init_suffix) or std.mem.eql(u8, f_name, callee_name)) {
                            break :blk f;
                        }
                    }
                    break :blk null;
                };

                const target_func = target_func_init;

                if (target_func) |func_val| {
                    const func_type = llvm.LLVMGlobalGetValueType(func_val);
                    const param_count: usize = @intCast(llvm.LLVMCountParamTypes(func_type));
                    const total_args = @max(call.arguments.len, param_count);

                    var arg_vals = try std.heap.page_allocator.alloc(llvm.LLVMValueRef, total_args);
                    defer std.heap.page_allocator.free(arg_vals);

                    const func_param_types = try std.heap.page_allocator.alloc(llvm.LLVMTypeRef, param_count);
                    defer std.heap.page_allocator.free(func_param_types);
                    if (param_count > 0) {
                        llvm.LLVMGetParamTypes(func_type, func_param_types.ptr);
                    }

                    const arg_offset: usize = 0;

                    for (call.arguments, 0..) |arg_node, idx| {
                        var arg_val = try emitExpression(ctx, mod, builder, scope, structs, libs, arg_node);
                        const p_idx = idx + arg_offset;
                        if (p_idx < param_count) {
                            const expected_type = func_param_types[p_idx];
                            if (llvm.LLVMGetTypeKind(expected_type) == llvm.LLVMStructTypeKind) {
                                // Target parameter is a Fat Pointer { ptr data, ptr vtable }
                                if (arg_node.resolved_type) |arg_rt| {
                                    const arg_c_name = switch (arg_rt.*) {
                                        .Custom => |n| n,
                                        .GenericInstance => |gi| gi.base_name,
                                        else => "",
                                    };
                                    // Target contract name (from callee AST parameter if available)
                                    var contract_c_name: []const u8 = "";
                                    if (call.callee.resolved_type) |crt| {
                                        if (crt.* == .Function and idx < crt.Function.params.len) {
                                            switch (crt.Function.params[idx].*) {
                                                .Custom => |n| contract_c_name = n,
                                                .GenericInstance => |gi| contract_c_name = gi.base_name,
                                                else => {},
                                            }
                                        }
                                    }
                                    if (arg_c_name.len > 0) {
                                        if (contract_c_name.len == 0) {
                                            if (global_contracts_ast_ptr) |ca| {
                                                var it = ca.iterator();
                                                while (it.next()) |entry| {
                                                    const c_name = entry.key_ptr.*;
                                                    const test_fat = coerceToContract(ctx, mod, builder, arg_val, arg_c_name, c_name) catch arg_val;
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
                            arg_vals[idx] = llvm.LLVMBuildGlobalStringPtr(builder, "Assertion failed", "default_str");
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

                                const has_receiver = if (call.callee.data == .get_expr) blk: {
                                    const callee_obj = call.callee.data.get_expr.object;
                                    if (callee_obj.data == .identifier) {
                                        const id_name = callee_obj.data.identifier.name;
                                        const rcn = callee_obj.data.identifier.resolved_c_name orelse id_name;
                                        const var_val = scope.get(id_name) orelse scope.get(rcn);
                                        if (var_val != null) {
                                            break :blk true;
                                        }
                                        break :blk false;
                                    }
                                    break :blk true;
                                } else false;
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
                                        arg_val = coerceArg(builder, arg_val, func_param_types[idx + arg_base]);
                                    }
                                    arg_vals[idx + arg_base] = arg_val;
                                }

                                for (call.arguments.len + arg_base..total_args) |idx| {
                                    const expected_type = if (idx < param_count) func_param_types[idx] else llvm.LLVMPointerTypeInContext(ctx, 0);
                                    arg_vals[idx] = llvm.LLVMConstNull(expected_type);
                                }

                                return llvm.LLVMBuildCall2(
                                    builder,
                                    func_type,
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
                var obj_rt_opt = g.object.resolved_type orelse blk: {
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
                    if (call.callee.resolved_type) |crt| {
                        if (crt.* == .Function) {
                            if (crt.Function.receiver != null) {
                                break :blk crt.Function.receiver.?;
                            }
                        }
                    }
                    break :blk null;
                };

                const static_string_type = struct {
                    const t = ts.EiwaType{ .String = {} };
                };
                const is_known_string_method = std.mem.eql(u8, g.name, "indexOf") or
                    std.mem.eql(u8, g.name, "contains") or
                    std.mem.eql(u8, g.name, "replace") or
                    std.mem.eql(u8, g.name, "substring") or
                    std.mem.eql(u8, g.name, "plus") or
                    std.mem.eql(u8, g.name, "charAt") or
                    std.mem.eql(u8, g.name, "toLowerCase") or
                    std.mem.eql(u8, g.name, "toUpperCase");

                if (obj_rt_opt == null and is_known_string_method) {
                    obj_rt_opt = &static_string_type.t;
                }

                if (std.mem.eql(u8, g.name, "plus")) {
                    if (obj_rt_opt) |obj_rt| {
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

                            const strcpy_fn = llvm.LLVMGetNamedFunction(mod, "strcpy") orelse blk: {
                                const p = llvm.LLVMPointerTypeInContext(ctx, 0);
                                var ps = [_]llvm.LLVMTypeRef{ p, p };
                                const ft = llvm.LLVMFunctionType(p, &ps, 2, 0);
                                break :blk llvm.LLVMAddFunction(mod, "strcpy", ft);
                            };
                            const strcpy_type = llvm.LLVMGlobalGetValueType(strcpy_fn);
                            var sc_args = [_]llvm.LLVMValueRef{ buf, left_val };
                            _ = llvm.LLVMBuildCall2(builder, strcpy_type, strcpy_fn, &sc_args, 2, "concat_cpy");

                            const strcat_fn = llvm.LLVMGetNamedFunction(mod, "strcat") orelse blk: {
                                const p = llvm.LLVMPointerTypeInContext(ctx, 0);
                                var ps = [_]llvm.LLVMTypeRef{ p, p };
                                const ft = llvm.LLVMFunctionType(p, &ps, 2, 0);
                                break :blk llvm.LLVMAddFunction(mod, "strcat", ft);
                            };
                            const strcat_type = llvm.LLVMGlobalGetValueType(strcat_fn);
                            var cat_args = [_]llvm.LLVMValueRef{ buf, right_val };
                            _ = llvm.LLVMBuildCall2(builder, strcat_type, strcat_fn, &cat_args, 2, "concat_cat");

                            return buf;
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
                        } else {
                            const is_string = switch (base_obj) {
                                .String => true,
                                .Custom => |n| std.mem.eql(u8, n, "String") or std.mem.eql(u8, n, "core_String"),
                                .Pointer => |p| switch (p.*) {
                                    .String => true,
                                    .Custom => |n| std.mem.eql(u8, n, "String") or std.mem.eql(u8, n, "core_String"),
                                    else => false,
                                },
                                else => false,
                            };
                            if (is_string) {
                                const str_val = try emitExpression(ctx, mod, builder, scope, structs, libs, g.object);
                                const fn_val = llvm.LLVMGetNamedFunction(mod, "eiwa_hash_string") orelse return error.HashStringHelperNotFound;
                                const fn_type = llvm.LLVMGlobalGetValueType(fn_val);
                                var args = [_]llvm.LLVMValueRef{str_val};
                                return llvm.LLVMBuildCall2(builder, fn_type, fn_val, &args, 1, "string_hash");
                            }
                        }
                    }
                }

                if (std.mem.eql(u8, g.name, "indexOf")) {
                    if (obj_rt_opt) |obj_rt| {
                        const obj_base = ts.extractBaseType(obj_rt).*;
                        const is_string = switch (obj_base) {
                            .String => true,
                            .Custom => |n| std.mem.eql(u8, n, "String") or std.mem.eql(u8, n, "core_String"),
                            .Pointer => |p| switch (p.*) {
                                .String => true,
                                .Custom => |n| std.mem.eql(u8, n, "String") or std.mem.eql(u8, n, "core_String"),
                                else => false,
                            },
                            else => false,
                        };
                        if (is_string and call.arguments.len >= 1) {
                            const str_ptr = try emitExpression(ctx, mod, builder, scope, structs, libs, g.object);
                            const needle_ptr = try emitExpression(ctx, mod, builder, scope, structs, libs, call.arguments[0]);
                            const strstr_fn = llvm.LLVMGetNamedFunction(mod, "strstr") orelse blk: {
                                const p = llvm.LLVMPointerTypeInContext(ctx, 0);
                                var ps = [_]llvm.LLVMTypeRef{ p, p };
                                const ft = llvm.LLVMFunctionType(p, &ps, 2, 0);
                                break :blk llvm.LLVMAddFunction(mod, "strstr", ft);
                            };
                            const ft = llvm.LLVMGlobalGetValueType(strstr_fn);
                            var args = [_]llvm.LLVMValueRef{ str_ptr, needle_ptr };
                            const match_ptr = llvm.LLVMBuildCall2(builder, ft, strstr_fn, &args, 2, "strstr_res");

                            const i64_t = llvm.LLVMInt64TypeInContext(ctx);
                            const is_null = llvm.LLVMBuildIsNull(builder, match_ptr, "no_match");
                            const neg_one = llvm.LLVMConstInt(i64_t, @bitCast(@as(i64, -1)), 1);
                            const str_i64 = llvm.LLVMBuildPtrToInt(builder, str_ptr, i64_t, "s_i64");
                            const match_i64 = llvm.LLVMBuildPtrToInt(builder, match_ptr, i64_t, "m_i64");
                            const diff = llvm.LLVMBuildSub(builder, match_i64, str_i64, "idx_diff");
                            return llvm.LLVMBuildSelect(builder, is_null, neg_one, diff, "indexOf_res");
                        }
                    }
                }

                if (std.mem.eql(u8, g.name, "contains")) {
                    if (obj_rt_opt) |obj_rt| {
                        const obj_base = ts.extractBaseType(obj_rt).*;
                        const is_string = switch (obj_base) {
                            .String => true,
                            .Custom => |n| std.mem.eql(u8, n, "String") or std.mem.eql(u8, n, "core_String"),
                            .Pointer => |p| switch (p.*) {
                                .String => true,
                                .Custom => |n| std.mem.eql(u8, n, "String") or std.mem.eql(u8, n, "core_String"),
                                else => false,
                            },
                            else => false,
                        };
                        if (is_string and call.arguments.len >= 1) {
                            const str_ptr = try emitExpression(ctx, mod, builder, scope, structs, libs, g.object);
                            const needle_ptr = try emitExpression(ctx, mod, builder, scope, structs, libs, call.arguments[0]);
                            const strstr_fn = llvm.LLVMGetNamedFunction(mod, "strstr") orelse blk: {
                                const p = llvm.LLVMPointerTypeInContext(ctx, 0);
                                var ps = [_]llvm.LLVMTypeRef{ p, p };
                                const ft = llvm.LLVMFunctionType(p, &ps, 2, 0);
                                break :blk llvm.LLVMAddFunction(mod, "strstr", ft);
                            };
                            const ft = llvm.LLVMGlobalGetValueType(strstr_fn);
                            var args = [_]llvm.LLVMValueRef{ str_ptr, needle_ptr };
                            const match_ptr = llvm.LLVMBuildCall2(builder, ft, strstr_fn, &args, 2, "strstr_res");

                            const i64_t = llvm.LLVMInt64TypeInContext(ctx);
                            const is_not_null = llvm.LLVMBuildIsNotNull(builder, match_ptr, "has_match");
                            return llvm.LLVMBuildZExt(builder, is_not_null, i64_t, "contains_bool");
                        }
                    }
                }

                if (std.mem.eql(u8, g.name, "substring")) {
                    var is_string = g.object.data == .string_literal;
                    if (!is_string) {
                        if (obj_rt_opt) |obj_rt| {
                            const bt = ts.extractBaseType(obj_rt);
                            if (bt.* == .String) {
                                is_string = true;
                            } else if (bt.* == .Custom) {
                                is_string = std.mem.eql(u8, bt.Custom, "String") or std.mem.eql(u8, bt.Custom, "core_String") or std.mem.eql(u8, bt.Custom, "std_core_String");
                            } else if (bt.* == .Pointer) {
                                const pt = bt.Pointer;
                                if (pt.* == .String) {
                                    is_string = true;
                                } else if (pt.* == .Custom) {
                                    is_string = std.mem.eql(u8, pt.Custom, "String") or std.mem.eql(u8, pt.Custom, "core_String") or std.mem.eql(u8, pt.Custom, "std_core_String");
                                }
                            }
                        } else {
                            is_string = true;
                        }
                    }
                    if (is_string and call.arguments.len >= 2) {
                            const str_ptr = try emitExpression(ctx, mod, builder, scope, structs, libs, g.object);
                            const start_val = try emitExpression(ctx, mod, builder, scope, structs, libs, call.arguments[0]);
                            const end_val = try emitExpression(ctx, mod, builder, scope, structs, libs, call.arguments[1]);

                            const i64_t = llvm.LLVMInt64TypeInContext(ctx);
                            const len_val = llvm.LLVMBuildSub(builder, end_val, start_val, "sub_len");
                            const len_plus_one = llvm.LLVMBuildAdd(builder, len_val, llvm.LLVMConstInt(i64_t, 1, 0), "sub_alloc_len");

                            const gc_func = llvm.LLVMGetNamedFunction(mod, "malloc") orelse llvm.LLVMGetNamedFunction(mod, "GC_malloc").?;
                            const gc_type = llvm.LLVMGlobalGetValueType(gc_func);
                            var gc_args = [_]llvm.LLVMValueRef{len_plus_one};
                            const buf = llvm.LLVMBuildCall2(builder, gc_type, gc_func, &gc_args, 1, "sub_buf");

                            var s_indices = [_]llvm.LLVMValueRef{start_val};
                            const src_ptr = llvm.LLVMBuildGEP2(builder, llvm.LLVMInt8TypeInContext(ctx), str_ptr, &s_indices, 1, "sub_src");

                            const memcpy_fn = llvm.LLVMGetNamedFunction(mod, "memcpy") orelse blk: {
                                const p = llvm.LLVMPointerTypeInContext(ctx, 0);
                                var ps = [_]llvm.LLVMTypeRef{ p, p, i64_t };
                                const ft = llvm.LLVMFunctionType(p, &ps, 3, 0);
                                break :blk llvm.LLVMAddFunction(mod, "memcpy", ft);
                            };
                            const memcpy_type = llvm.LLVMGlobalGetValueType(memcpy_fn);
                            if (llvm.LLVMCountParamTypes(memcpy_type) == 4) {
                                var mc_args = [_]llvm.LLVMValueRef{ buf, src_ptr, len_val, llvm.LLVMConstInt(llvm.LLVMInt1TypeInContext(ctx), 0, 0) };
                                _ = llvm.LLVMBuildCall2(builder, memcpy_type, memcpy_fn, &mc_args, 4, "");
                            } else {
                                var mc_args = [_]llvm.LLVMValueRef{ buf, src_ptr, len_val };
                                _ = llvm.LLVMBuildCall2(builder, memcpy_type, memcpy_fn, &mc_args, 3, "");
                            }

                            var t_indices = [_]llvm.LLVMValueRef{len_val};
                            const term_ptr = llvm.LLVMBuildGEP2(builder, llvm.LLVMInt8TypeInContext(ctx), buf, &t_indices, 1, "sub_term");
                            _ = llvm.LLVMBuildStore(builder, llvm.LLVMConstInt(llvm.LLVMInt8TypeInContext(ctx), 0, 0), term_ptr);

                            return buf;
                        }
                    }

                if (obj_rt_opt) |obj_rt| {
                    var handled_vtable = false;
                    if (types_mapping.isContractType(obj_rt.*, global_contracts_ast_ptr)) {
                        // Contract method dispatch (Task 61.3): Fat Pointer { data_ptr, vtable_ptr }
                        const base_obj_rt = ts.extractBaseType(obj_rt);
                        const contract_name = switch (base_obj_rt.*) {
                            .Custom => |n| n,
                            .GenericInstance => |gi| gi.base_name,
                            else => "",
                        };
                        var contract_node = if (global_contracts_ast_ptr) |ca| ca.get(contract_name) else null;
                        if (contract_node == null) {
                            if (std.mem.lastIndexOfScalar(u8, contract_name, '_')) |idx| {
                                const short_name = contract_name[idx + 1 ..];
                                contract_node = if (global_contracts_ast_ptr) |ca| ca.get(short_name) else null;
                            }
                        }
                        if (contract_node) |cnode| {
                            if (cnode.data == .contract_decl) {
                                handled_vtable = true;
                                const c_decl = cnode.data.contract_decl;
                                var method_idx: ?usize = null;
                                var target_fun_decl: ?*ast.ASTNode = null;

                                for (c_decl.methods, 0..) |cm, idx| {
                                    if (cm.data == .fun_decl and std.mem.eql(u8, cm.data.fun_decl.name, g.name)) {
                                        method_idx = idx;
                                        target_fun_decl = cm;
                                        break;
                                    }
                                }

                            if (method_idx) |m_idx| {
                                const fat_ptr = try emitExpression(ctx, mod, builder, scope, structs, libs, g.object);
                                const data_ptr = llvm.LLVMBuildExtractValue(builder, fat_ptr, 0, "fat_data");

                                const i64_type = llvm.LLVMInt64TypeInContext(ctx);

                                const fun_data = target_fun_decl.?.data.fun_decl;
                                const ret_t = if (target_fun_decl.?.resolved_type) |rt|
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
                                        c_m_idx: usize,
                                        c_target_fun_decl: *ast.ASTNode,
                                        c_ret_t: llvm.LLVMTypeRef,
                                        c_call: anytype,
                                    ) !llvm.LLVMValueRef {
                                        const c_vtable_ptr = llvm.LLVMBuildExtractValue(c_builder, c_fat_ptr, 1, "fat_vtable");
                                        const c_ptr_type = llvm.LLVMPointerTypeInContext(c_ctx, 0);
                                        const c_i64_type = llvm.LLVMInt64TypeInContext(c_ctx);
                                        const parent_func = llvm.LLVMGetBasicBlockParent(llvm.LLVMGetInsertBlock(c_builder));
                                        const vt_ok_bb = llvm.LLVMAppendBasicBlockInContext(c_ctx, parent_func, "vt_ok");
                                        const vt_null_bb = llvm.LLVMAppendBasicBlockInContext(c_ctx, parent_func, "vt_null");
                                        const vt_merge_bb = llvm.LLVMAppendBasicBlockInContext(c_ctx, parent_func, "vt_merge");

                                        const is_vt_null = llvm.LLVMBuildIsNull(c_builder, c_vtable_ptr, "is_vt_null");
                                        _ = llvm.LLVMBuildCondBr(c_builder, is_vt_null, vt_null_bb, vt_ok_bb);

                                        llvm.LLVMPositionBuilderAtEnd(c_builder, vt_ok_bb);
                                        var gep_indices = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(c_i64_type, @intCast(c_m_idx), 0)};
                                        const fn_slot_ptr = llvm.LLVMBuildGEP2(c_builder, c_ptr_type, c_vtable_ptr, &gep_indices, 1, "vtable_slot_gep");
                                        const fn_ptr = llvm.LLVMBuildLoad2(c_builder, c_ptr_type, fn_slot_ptr, "vtable_fn_ptr");

                                        var param_types = try std.heap.page_allocator.alloc(llvm.LLVMTypeRef, 1 + c_call.arguments.len);
                                        defer std.heap.page_allocator.free(param_types);
                                        var arg_vals = try std.heap.page_allocator.alloc(llvm.LLVMValueRef, 1 + c_call.arguments.len);
                                        defer std.heap.page_allocator.free(arg_vals);
                                        param_types[0] = c_ptr_type;
                                        arg_vals[0] = c_data_ptr;

                                        for (c_call.arguments, 0..) |arg_node, i| {
                                            const p_type = if (c_target_fun_decl.resolved_type) |rt|
                                                (if (rt.* == .Function and i < rt.Function.params.len) types_mapping.getLLVMTypeWithContracts(c_ctx, rt.Function.params[i].*, global_contracts_ast_ptr) else c_i64_type)
                                            else
                                                c_i64_type;
                                            param_types[i + 1] = p_type;
                                            var arg_val = try emitExpression(c_ctx, c_mod, c_builder, c_scope, c_structs, c_libs, arg_node);
                                            arg_val = coerceArg(c_builder, arg_val, p_type);
                                            arg_vals[i + 1] = arg_val;
                                        }

                                        const dyn_fn_type = llvm.LLVMFunctionType(c_ret_t, param_types.ptr, @intCast(param_types.len), 0);
                                        const call_name: [*c]const u8 = if (llvm.LLVMGetTypeKind(c_ret_t) == llvm.LLVMVoidTypeKind) "" else "vcall_tmp";
                                        const ok_val = llvm.LLVMBuildCall2(c_builder, dyn_fn_type, fn_ptr, arg_vals.ptr, @intCast(arg_vals.len), call_name);
                                        const ok_end_bb = llvm.LLVMGetInsertBlock(c_builder);
                                        _ = llvm.LLVMBuildBr(c_builder, vt_merge_bb);

                                        llvm.LLVMPositionBuilderAtEnd(c_builder, vt_null_bb);
                                        const null_val = llvm.LLVMConstNull(c_ret_t);
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
                                    const vt_ptr_val = llvm.LLVMBuildExtractValue(builder, fat_ptr, 1, "fat_vtable");
                                    const vt_null = llvm.LLVMBuildIsNull(builder, vt_ptr_val, "is_vt_null");
                                    const is_null = llvm.LLVMBuildOr(builder, data_null, vt_null, "is_null");
                                    _ = llvm.LLVMBuildCondBr(builder, is_null, else_bb, then_bb);

                                    llvm.LLVMPositionBuilderAtEnd(builder, then_bb);
                                    const call_val = try emit_dispatch(ctx, mod, builder, scope, structs, libs, fat_ptr, data_ptr, m_idx, target_fun_decl.?, ret_t, call);
                                    const then_end_bb = llvm.LLVMGetInsertBlock(builder);
                                    _ = llvm.LLVMBuildBr(builder, merge_bb);

                                    llvm.LLVMPositionBuilderAtEnd(builder, else_bb);
                                    const null_val = if (node.resolved_type) |nrt|
                                        types_mapping.getLLVMTypeWithContracts(ctx, nrt.*, global_contracts_ast_ptr)
                                    else
                                        ret_t;
                                    const const_null = llvm.LLVMConstNull(null_val);
                                    const else_end_bb = llvm.LLVMGetInsertBlock(builder);
                                    _ = llvm.LLVMBuildBr(builder, merge_bb);

                                    llvm.LLVMPositionBuilderAtEnd(builder, merge_bb);
                                    const phi = llvm.LLVMBuildPhi(builder, llvm.LLVMTypeOf(const_null), "safe_call_res");
                                    var incoming_vals = [_]llvm.LLVMValueRef{ call_val, const_null };
                                    var incoming_blocks = [_]llvm.LLVMBasicBlockRef{ then_end_bb, else_end_bb };
                                    llvm.LLVMAddIncoming(phi, &incoming_vals, &incoming_blocks, 2);
                                    return phi;
                                } else {
                                    return try emit_dispatch(ctx, mod, builder, scope, structs, libs, fat_ptr, data_ptr, m_idx, target_fun_decl.?, ret_t, call);
                                }
                            }
                            }
                        }
                    }
                    if (!handled_vtable) {
                        var type_name: []const u8 = "";
                        var base_obj_rt = ts.extractBaseType(obj_rt);
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
                        if (base_obj_rt.* == .String or (base_obj_rt.* == .Custom and (std.mem.eql(u8, base_obj_rt.Custom, "String") or std.mem.eql(u8, base_obj_rt.Custom, "core_String")))) {
                            type_name = "core_String";
                        } else if (base_obj_rt.* == .Custom) {
                            type_name = base_obj_rt.Custom;
                        } else if (base_obj_rt.* == .GenericInstance) {
                            type_name = base_obj_rt.GenericInstance.base_name;
                        }
                        if (type_name.len > 0) {
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

                                if (target_func == null) {
                                    target_func = blk: {
                                        // TODO(llvm-backend): Replace iterative function scanning & string prefix matching
                                        // with exact AST resolved method symbol lookup from type_checker.
                                        const raw_sub = try std.fmt.allocPrint(std.heap.page_allocator, "{s}_{s}", .{ type_name, g.name });
                                        defer std.heap.page_allocator.free(raw_sub);

                                        var func_it = llvm.LLVMGetFirstFunction(mod);
                                        while (func_it) |f| : (func_it = llvm.LLVMGetNextFunction(f)) {
                                            const name_ptr = llvm.LLVMGetValueName(f);
                                            const f_name = std.mem.span(name_ptr);
                                            const matches = std.mem.startsWith(u8, f_name, raw_sub) or
                                                std.mem.eql(u8, f_name, raw_sub) or
                                                (f_name.len > 0 and f_name[0] == '_' and std.mem.startsWith(u8, f_name[1..], raw_sub)) or
                                                std.mem.indexOf(u8, f_name, raw_sub) != null;
                                            if (matches) {
                                                const mft = llvm.LLVMGlobalGetValueType(f);
                                                const pc = llvm.LLVMCountParamTypes(mft);
                                                if (pc >= call.arguments.len) {
                                                    break :blk f;
                                                }
                                            }
                                        }

                                        var base_type_name = type_name;
                                        if (std.mem.indexOf(u8, type_name, "_core_")) |idx| {
                                            if (idx > 0) base_type_name = type_name[0..idx];
                                        } else if (std.mem.indexOf(u8, type_name, "_collections_")) |idx| {
                                            if (idx > 0) base_type_name = type_name[0..idx];
                                        }

                                        const base_raw_sub = try std.fmt.allocPrint(std.heap.page_allocator, "{s}_{s}", .{ base_type_name, g.name });
                                        defer std.heap.page_allocator.free(base_raw_sub);

                                        func_it = llvm.LLVMGetFirstFunction(mod);
                                        while (func_it) |f| : (func_it = llvm.LLVMGetNextFunction(f)) {
                                            const name_ptr = llvm.LLVMGetValueName(f);
                                            const f_name = std.mem.span(name_ptr);
                                            if (std.mem.startsWith(u8, f_name, base_raw_sub) or std.mem.eql(u8, f_name, base_raw_sub)) {
                                                const mft = llvm.LLVMGlobalGetValueType(f);
                                                const pc = llvm.LLVMCountParamTypes(mft);
                                                if (pc >= call.arguments.len) {
                                                    break :blk f;
                                                }
                                            }
                                        }

                                        break :blk null;
                                    };
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
                                    arg_vals[0] = obj_val;
                                } else {
                                    obj_val = llvm.LLVMConstNull(llvm.LLVMPointerTypeInContext(ctx, 0));
                                }

                                for (call.arguments, 0..) |arg_node, idx| {
                                    var arg_val = try emitExpression(ctx, mod, builder, scope, structs, libs, arg_node);
                                    const p_idx = if (is_object_call) idx else idx + 1;
                                    if (p_idx < param_count) {
                                        arg_val = coerceArg(builder, arg_val, func_param_types[p_idx]);
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
                                    const const_null = llvm.LLVMConstNull(ret_t);
                                    const else_end_bb = llvm.LLVMGetInsertBlock(builder);
                                    _ = llvm.LLVMBuildBr(builder, merge_bb);

                                    llvm.LLVMPositionBuilderAtEnd(builder, merge_bb);
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
                if ((std.mem.eql(u8, g.name, "toInt") or std.mem.eql(u8, g.name, "toDouble")) and call.arguments.len == 0) {
                    if (g.object.resolved_type) |obj_rt| {
                        if (obj_rt.* == .Double or obj_rt.* == .Int) {
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
                    const base_obj_rt = ts.extractBaseType(obj_rt);
                    if (base_obj_rt.* == .Array or (base_obj_rt.* == .Pointer and base_obj_rt.Pointer.* == .Array)) {
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
                        const base_obj = ts.extractBaseType(obj_rt).*;
                        if (base_obj == .String or (base_obj == .Custom and (std.mem.eql(u8, base_obj.Custom, "String") or std.mem.eql(u8, base_obj.Custom, "core_String")))) {
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
                    for (call.arguments, 0..) |_, idx| {
                        if (idx < rt.Function.params.len) {
                            param_types[idx] = types_mapping.getLLVMTypeWithContracts(ctx, rt.Function.params[idx].*, global_contracts_ast_ptr);
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
                        if (arg_node.resolved_type) |arg_rt| {
                            const arg_c_name = switch (arg_rt.*) {
                                .Custom => |n| n,
                                .GenericInstance => |gi| gi.base_name,
                                else => "",
                            };
                            if (arg_c_name.len > 0) {
                                if (global_contracts_ast_ptr) |ca| {
                                    var it = ca.iterator();
                                    while (it.next()) |entry| {
                                        const c_name = entry.key_ptr.*;
                                        const test_fat = coerceToContract(ctx, mod, builder, arg_val, arg_c_name, c_name) catch arg_val;
                                        if (llvm.LLVMTypeOf(test_fat) == ptype) {
                                            arg_val = test_fat;
                                            break;
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
                            const contract_c_name: []const u8 = "";
                            if (arg_node.resolved_type) |art| {
                                const abase = ts.extractBaseType(art);
                                if (abase.* == .Custom) arg_c_name = abase.Custom;
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

            const cond_val = try emitExpression(ctx, mod, builder, scope, structs, libs, i.condition);

            const then_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "expr_if.then");
            const else_bb = if (i.else_branch != null) llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "expr_if.else") else null;
            const merge_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func_val, "expr_if.merge");

            const res_ptr = if (!is_void) llvm.LLVMBuildAlloca(builder, ret_type, "expr_if_res") else null;
            _ = llvm.LLVMBuildCondBr(builder, cond_val, then_bb, else_bb orelse merge_bb);

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
                            const i1_type = llvm.LLVMInt1TypeInContext(ctx);
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
                            // Contract subjects are Fat Pointers { data, vtable }.
                            // Type identity is carried by the vtable pointer (the C
                            // backend tags boxed values with EiwaTypeDescriptor*;
                            // the vtable slot plays that role here). Extract the data
                            // pointer + vtable so we never PtrToInt() the struct.
                            const subj_is_fat = llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(subj_load)) == llvm.LLVMStructTypeKind;
                            var subj_data = subj_load;
                            var subj_vtable: ?llvm.LLVMValueRef = null;
                            if (subj_is_fat) {
                                subj_data = llvm.LLVMBuildExtractValue(builder, subj_load, 0, "when_subj_data");
                                subj_vtable = llvm.LLVMBuildExtractValue(builder, subj_load, 1, "when_subj_vtable");
                            }
                            const subj_int = if (subj_is_fat)
                                llvm.LLVMConstInt(i64_type, 0, 0)
                            else
                                llvm.LLVMBuildPtrToInt(builder, subj_load, i64_type, "when_subj_int");
                            const i1_false = llvm.LLVMConstInt(i1_type, 0, 0);
                            const i1_true = llvm.LLVMConstInt(i1_type, 1, 0);
                            var is_match: llvm.LLVMValueRef = undefined;
                            if (std.mem.eql(u8, target_c_name, "core_Null")) {
                                is_match = llvm.LLVMBuildICmp(builder, llvm.LLVMIntEQ, subj_data, llvm.LLVMConstNull(ptr_type), "when_is_null");
                            } else if (std.mem.eql(u8, target_c_name, "core_Int") or std.mem.eql(u8, target_c_name, "core_Double") or std.mem.eql(u8, target_c_name, "Double")) {
                                // A Fat Pointer (contract subject) is never a primitive.
                                is_match = if (subj_is_fat) i1_false else llvm.LLVMBuildICmp(builder, llvm.LLVMIntULT, subj_int, llvm.LLVMConstInt(i64_type, 0x10000, 0), "when_is_small");
                            } else if (std.mem.eql(u8, target_c_name, "core_Bool")) {
                                is_match = if (subj_is_fat) i1_false else llvm.LLVMBuildICmp(builder, llvm.LLVMIntULE, subj_int, llvm.LLVMConstInt(i64_type, 1, 0), "when_is_bool");
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
                                    if (subj_contract.len > 0) {
                                        if (try findVtableGlobal(mod, target_c_name, subj_contract)) |vglob| {
                                            const vg_ptr = llvm.LLVMBuildBitCast(builder, vglob, ptr_type, "when_vt_global");
                                            const svt_ptr = llvm.LLVMBuildBitCast(builder, svt, ptr_type, "when_vt_subj");
                                            is_match = llvm.LLVMBuildICmp(builder, llvm.LLVMIntEQ, svt_ptr, vg_ptr, "when_is_obj_of_type");
                                        } else {
                                            is_match = i1_false;
                                        }
                                    } else {
                                        is_match = i1_false;
                                    }
                                } else {
                                    is_match = i1_true;
                                }
                            } else {
                                // Non-contract boxed pointer: pointer-range heuristic
                                // (unchanged for the non-contract path).
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
                                var subj_load = llvm.LLVMBuildLoad2(builder, llvm.LLVMTypeOf(subj_ptr.?), subj_ptr.?, "when_subj_load");
                                const s_type = llvm.LLVMTypeOf(subj_load);
                                const c_type = llvm.LLVMTypeOf(cond_val);
                                if (llvm.LLVMGetTypeKind(s_type) == llvm.LLVMPointerTypeKind and llvm.LLVMGetTypeKind(c_type) == llvm.LLVMIntegerTypeKind) {
                                    subj_load = llvm.LLVMBuildPtrToInt(builder, subj_load, c_type, "subj_ptr2int");
                                } else if (llvm.LLVMGetTypeKind(s_type) == llvm.LLVMIntegerTypeKind and llvm.LLVMGetTypeKind(c_type) == llvm.LLVMPointerTypeKind) {
                                    cond_val = llvm.LLVMBuildPtrToInt(builder, cond_val, s_type, "cond_ptr2int");
                                }
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
            const val_type = if (i.value.resolved_type) |rt| rt.* else .Unknown;
            const target_type = if (i.type_ref.resolved_type) |rt| rt.* else .Unknown;

            const is_contract_val = types_mapping.isContractType(val_type, global_contracts_ast_ptr);
            const val = try emitExpression(ctx, mod, builder, scope, structs, libs, i.value);

            var ptr_to_check: llvm.LLVMValueRef = val;
            if (is_contract_val and llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(val)) == llvm.LLVMStructTypeKind) {
                ptr_to_check = llvm.LLVMBuildExtractValue(builder, val, 0, "is_data_ptr");
            }

            var res: llvm.LLVMValueRef = undefined;
            if (target_type == .Null) {
                res = llvm.LLVMBuildIsNull(builder, ptr_to_check, "is_null_cmp");
            } else {
                if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(ptr_to_check)) == llvm.LLVMIntegerTypeKind) {
                    res = llvm.LLVMConstInt(llvm.LLVMInt1TypeInContext(ctx), 1, 0);
                } else {
                    res = llvm.LLVMBuildIsNotNull(builder, ptr_to_check, "is_not_null_cmp");
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
            // TODO(emitter): PREVIOUSLY returned `LLVMConstNull(ptr)` (a null
            // receiver) — any map literal crashed on the first `map[k]`. The
            // bucket size (16) mirrors std/collections.ei and the C backend.
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
                    const malloc_fn = llvm.LLVMGetNamedFunction(mod, "malloc") orelse llvm.LLVMGetNamedFunction(mod, "GC_malloc").?;
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
        .assignment => {
            const func_val = llvm.LLVMGetBasicBlockParent(llvm.LLVMGetInsertBlock(builder));
            try statement.emitStatement(ctx, mod, builder, func_val, scope, structs, libs, node);
            const ret_t = llvm.LLVMGetReturnType(llvm.LLVMGlobalGetValueType(func_val));
            if (llvm.LLVMGetTypeKind(ret_t) == llvm.LLVMVoidTypeKind) {
                const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
                return llvm.LLVMConstNull(ptr_type);
            }
            return llvm.LLVMConstNull(ret_t);
        },
        .as_expr => |as_e| {
            const val = try emitExpression(ctx, mod, builder, scope, structs, libs, as_e.value);
            if (as_e.value.resolved_type) |v_rt| {
                if (node.resolved_type) |target_rt| {
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
            return val;
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
pub fn coerceArg(
    builder: llvm.LLVMBuilderRef,
    arg_val: llvm.LLVMValueRef,
    param_type: llvm.LLVMTypeRef,
) llvm.LLVMValueRef {
    const arg_type = llvm.LLVMTypeOf(arg_val);
    const arg_kind = llvm.LLVMGetTypeKind(arg_type);
    const param_kind = llvm.LLVMGetTypeKind(param_type);

    if (arg_kind == llvm.LLVMPointerTypeKind and param_kind == llvm.LLVMStructTypeKind) {
        const fat_type = types_mapping.getFatPointerType(llvm.LLVMGetTypeContext(param_type));
        const undef_fat = llvm.LLVMGetUndef(fat_type);
        const fat_with_data = llvm.LLVMBuildInsertValue(builder, undef_fat, arg_val, 0, "fat_data");
        const null_vtable = llvm.LLVMConstNull(llvm.LLVMPointerTypeInContext(llvm.LLVMGetTypeContext(param_type), 0));
        return llvm.LLVMBuildInsertValue(builder, fat_with_data, null_vtable, 1, "fat_val");
    }
    if (arg_kind == llvm.LLVMStructTypeKind and param_kind == llvm.LLVMPointerTypeKind) {
        return llvm.LLVMBuildExtractValue(builder, arg_val, 0, "fat_data_extracted");
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

/// Coerces a concrete type value (data_ptr) into a Fat Pointer { data, vtable } for a target contract.
/// Resolves the static vtable global symbol for a concrete type implementing a
/// contract, mirroring the multi-stage short-name fallback used by
/// `coerceToContract`. Returns null when no such vtable global exists in the
/// module. Used by `when (x) is SomeType` on contract subjects to type-check by
/// vtable identity.
fn findVtableGlobal(mod: llvm.LLVMModuleRef, concrete_c_name: []const u8, contract_c_name: []const u8) anyerror!?llvm.LLVMValueRef {
    const first_name = try std.fmt.allocPrint(std.heap.page_allocator, "{s}_{s}_vtable", .{ concrete_c_name, contract_c_name });
    defer std.heap.page_allocator.free(first_name);
    const first_z = try std.heap.page_allocator.dupeZ(u8, first_name);
    defer std.heap.page_allocator.free(first_z);
    if (llvm.LLVMGetNamedGlobal(mod, first_z.ptr)) |g| return g;

    var short_contract = contract_c_name;
    if (std.mem.lastIndexOfScalar(u8, contract_c_name, '_')) |idx| short_contract = contract_c_name[idx + 1 ..];
    var short_concrete = concrete_c_name;
    if (std.mem.lastIndexOfScalar(u8, concrete_c_name, '_')) |idx| short_concrete = concrete_c_name[idx + 1 ..];

    const alt1 = try std.fmt.allocPrint(std.heap.page_allocator, "{s}_{s}_vtable", .{ concrete_c_name, short_contract });
    defer std.heap.page_allocator.free(alt1);
    const alt1_z = try std.heap.page_allocator.dupeZ(u8, alt1);
    defer std.heap.page_allocator.free(alt1_z);
    if (llvm.LLVMGetNamedGlobal(mod, alt1_z.ptr)) |g2| return g2;

    const alt2 = try std.fmt.allocPrint(std.heap.page_allocator, "{s}_{s}_vtable", .{ short_concrete, short_contract });
    defer std.heap.page_allocator.free(alt2);
    const alt2_z = try std.heap.page_allocator.dupeZ(u8, alt2);
    defer std.heap.page_allocator.free(alt2_z);
    if (llvm.LLVMGetNamedGlobal(mod, alt2_z.ptr)) |g3| return g3;

    var g_iter = llvm.LLVMGetFirstGlobal(mod);
    while (g_iter != null) : (g_iter = llvm.LLVMGetNextGlobal(g_iter.?)) {
        const g_name_ptr = llvm.LLVMGetValueName(g_iter.?);
        const g_name_s = std.mem.span(g_name_ptr);
        if ((std.mem.startsWith(u8, g_name_s, concrete_c_name) or std.mem.startsWith(u8, g_name_s, short_concrete)) and std.mem.endsWith(u8, g_name_s, "_vtable")) {
            return g_iter.?;
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

    // Box integer/bool values if needed
    var data_ptr = data_val;
    if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(data_val)) == llvm.LLVMIntegerTypeKind) {
        data_ptr = llvm.LLVMBuildIntToPtr(builder, data_val, ptr_type, "fat_data_box");
    }

    // TODO(llvm-backend): Standardize static vtable symbol naming scheme ({concrete}_{contract}_vtable)
    // across passes to avoid multi-stage short name fallback global lookups.
    const vtable_name_raw = try std.fmt.allocPrint(std.heap.page_allocator, "{s}_{s}_vtable", .{ concrete_c_name, contract_c_name });
    defer std.heap.page_allocator.free(vtable_name_raw);
    const vtable_name = try std.heap.page_allocator.dupeZ(u8, vtable_name_raw);
    defer std.heap.page_allocator.free(vtable_name);

    var vtable_global = llvm.LLVMGetNamedGlobal(mod, vtable_name.ptr);
    if (vtable_global == null) {
        var short_contract = contract_c_name;
        if (std.mem.lastIndexOfScalar(u8, contract_c_name, '_')) |idx| {
            short_contract = contract_c_name[idx + 1 ..];
        }
        var short_concrete = concrete_c_name;
        if (std.mem.lastIndexOfScalar(u8, concrete_c_name, '_')) |idx| {
            short_concrete = concrete_c_name[idx + 1 ..];
        }
        const alt_raw1 = try std.fmt.allocPrint(std.heap.page_allocator, "{s}_{s}_vtable", .{ concrete_c_name, short_contract });
        defer std.heap.page_allocator.free(alt_raw1);
        const alt_vtable1 = try std.heap.page_allocator.dupeZ(u8, alt_raw1);
        defer std.heap.page_allocator.free(alt_vtable1);
        vtable_global = llvm.LLVMGetNamedGlobal(mod, alt_vtable1.ptr);
        if (vtable_global == null) {
            const alt_raw2 = try std.fmt.allocPrint(std.heap.page_allocator, "{s}_{s}_vtable", .{ short_concrete, short_contract });
            defer std.heap.page_allocator.free(alt_raw2);
            const alt_vtable2 = try std.heap.page_allocator.dupeZ(u8, alt_raw2);
            defer std.heap.page_allocator.free(alt_vtable2);
            vtable_global = llvm.LLVMGetNamedGlobal(mod, alt_vtable2.ptr);
        }
        if (vtable_global == null) {
            var g_iter = llvm.LLVMGetFirstGlobal(mod);
            const fallback_short_concrete = if (std.mem.lastIndexOfScalar(u8, concrete_c_name, '_')) |idx| concrete_c_name[idx + 1 ..] else concrete_c_name;
            while (g_iter != null) : (g_iter = llvm.LLVMGetNextGlobal(g_iter.?)) {
                const g_name_ptr = llvm.LLVMGetValueName(g_iter.?);
                const g_name_s = std.mem.span(g_name_ptr);
                if ((std.mem.startsWith(u8, g_name_s, concrete_c_name) or std.mem.startsWith(u8, g_name_s, fallback_short_concrete)) and std.mem.endsWith(u8, g_name_s, "_vtable")) {
                    vtable_global = g_iter.?;
                    break;
                }
            }
        }
    }

    const vtable_ptr = vtable_global orelse llvm.LLVMConstNull(ptr_type);

    var fat_val = llvm.LLVMGetUndef(fat_type);
    fat_val = llvm.LLVMBuildInsertValue(builder, fat_val, data_ptr, 0, "fat_data");
    fat_val = llvm.LLVMBuildInsertValue(builder, fat_val, vtable_ptr, 1, "fat_vtable");

    return fat_val;
}

fn isStringOperand(node: *ast.ASTNode) bool {
    if (node.data == .string_literal) return true;
    if (node.data == .call_expr) {
        if (node.data.call_expr.callee.data == .get_expr) {
            const name = node.data.call_expr.callee.data.get_expr.name;
            if (std.mem.eql(u8, name, "substring") or std.mem.eql(u8, name, "toString") or std.mem.eql(u8, name, "format") or std.mem.eql(u8, name, "replace")) return true;
        }
    }
    const rt = node.resolved_type orelse return false;
    const base_rt = ts.extractBaseType(rt);
    return switch (base_rt.*) {
        .String => true,
        .Custom => |n| std.mem.eql(u8, n, "core_String") or std.mem.eql(u8, n, "String") or std.mem.eql(u8, n, "std_core_String"),
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

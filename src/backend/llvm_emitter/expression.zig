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
                    const res_type = node.resolved_type orelse return var_val;
                    const is_contract = types_mapping.isContractType(res_type.*, global_contracts_ast_ptr);
                    const elem_type = if (is_contract) types_mapping.getFatPointerType(ctx) else types_mapping.getLLVMType(ctx, res_type.*);
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
                        const fn_val = llvm.LLVMGetNamedFunction(mod, "eiwa_to_string") orelse return error.ToStringHelperNotFound;
                        const fn_type = llvm.LLVMGlobalGetValueType(fn_val);
                        // eiwa_to_string takes a ptr (boxed value). Int/Bool are
                        // raw i64 in the LLVM model, so box them via inttoptr.
                        var arg_val = obj_val;
                        if (obj_base == .Int or obj_base == .Bool) {
                            const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
                            arg_val = llvm.LLVMBuildIntToPtr(builder, obj_val, ptr_type, "tostr_box");
                        } else if (obj_base == .Double) {
                            const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
                            const i64_val = llvm.LLVMBuildBitCast(builder, obj_val, llvm.LLVMInt64TypeInContext(ctx), "double_i64_box");
                            arg_val = llvm.LLVMBuildIntToPtr(builder, i64_val, ptr_type, "tostr_box");
                        }
                        var args = [_]llvm.LLVMValueRef{arg_val};
                        return llvm.LLVMBuildCall2(builder, fn_type, fn_val, &args, 1, "tostr_tmp");
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
                } else if (rt.* == .GenericInstance) {
                    type_name = rt.GenericInstance.base_name;
                } else if (rt.* == .Pointer) {
                    if (rt.Pointer.* == .Custom) {
                        type_name = rt.Pointer.Custom;
                    } else if (rt.Pointer.* == .GenericInstance) {
                        type_name = rt.Pointer.GenericInstance.base_name;
                    }
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
            std.debug.print("LLVM Debug: PropertyNotFound get.name={s} obj.resolved_type={any}\n", .{ get.name, if (get.object.resolved_type) |rt| rt.* else null });
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
            // Elvis (?:) needs short-circuit: don't evaluate right if left is non-null.
            // Implement as a ternary: left != 0/null ? left : right
            if (bin.op == .elvis) {
                const func_val = llvm.LLVMGetBasicBlockParent(llvm.LLVMGetInsertBlock(builder));
                const lhs_val = try emitExpression(ctx, mod, builder, scope, structs, libs, bin.left);
                const i64_type = llvm.LLVMInt64TypeInContext(ctx);
                const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
                const is_ptr = llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(lhs_val)) == llvm.LLVMPointerTypeKind;
                const not_null = if (is_ptr)
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

            var left_val = try emitExpression(ctx, mod, builder, scope, structs, libs, bin.left);
            var right_val = try emitExpression(ctx, mod, builder, scope, structs, libs, bin.right);

            const is_double = if (bin.left.resolved_type) |t| (t.* == .Double) else false;

            if (!is_double) {
                const l_type = llvm.LLVMTypeOf(left_val);
                const r_type = llvm.LLVMTypeOf(right_val);
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
                            const expected_type = func_param_types[idx];
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
                                                    if (llvm.LLVMTypeOf(test_fat) == expected_type) {
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
                            } else {
                                arg_val = coerceArg(builder, arg_val, expected_type);
                            }
                        }
                        arg_vals[idx] = arg_val;
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
                    if (obj_rt.* == .String) {
                        type_name = "core_String";
                    } else if (obj_rt.* == .Custom) {
                        type_name = obj_rt.Custom;
                    } else if (obj_rt.* == .GenericInstance) {
                        type_name = obj_rt.GenericInstance.base_name;
                    } else if (obj_rt.* == .Pointer) {
                        if (obj_rt.Pointer.* == .Custom) {
                            type_name = obj_rt.Pointer.Custom;
                        } else if (obj_rt.Pointer.* == .GenericInstance) {
                            type_name = obj_rt.Pointer.GenericInstance.base_name;
                        }
                    }
                    if (type_name.len > 0) {
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

                            const call_res = llvm.LLVMBuildCall2(
                                builder,
                                func_type,
                                func_val,
                                if (arg_vals.len > 0) arg_vals.ptr else null,
                                @intCast(arg_vals.len),
                                if (llvm.LLVMGetTypeKind(llvm.LLVMGetReturnType(func_type)) == llvm.LLVMVoidTypeKind) "" else "method_tmp",
                            );

                            const ret_t = llvm.LLVMGetReturnType(func_type);
                            if (node.resolved_type) |nrt| {
                                if ((nrt.* == .Int or nrt.* == .Bool) and llvm.LLVMGetTypeKind(ret_t) == llvm.LLVMPointerTypeKind) {
                                    const target_t = types_mapping.getLLVMType(ctx, nrt.*);
                                    return llvm.LLVMBuildPtrToInt(builder, call_res, target_t, "unbox_method_ret");
                                }
                            }
                            return call_res;
                        }
                    } else if (types_mapping.isContractType(obj_rt.*, global_contracts_ast_ptr)) {
                        // Contract method dispatch (Task 61.3): Fat Pointer { data_ptr, vtable_ptr }
                        const contract_name = switch (obj_rt.*) {
                            .Custom => |n| n,
                            .GenericInstance => |gi| gi.base_name,
                            else => "",
                        };
                        const contract_node = if (global_contracts_ast_ptr) |ca| ca.get(contract_name) else null;
                        if (contract_node) |cnode| {
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
                                const vtable_ptr = llvm.LLVMBuildExtractValue(builder, fat_ptr, 1, "fat_vtable");

                                const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
                                const i64_type = llvm.LLVMInt64TypeInContext(ctx);

                                // GEP to vtable method slot
                                var gep_indices = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, @intCast(m_idx), 0)};
                                const fn_slot_ptr = llvm.LLVMBuildGEP2(builder, ptr_type, vtable_ptr, &gep_indices, 1, "vtable_slot_gep");
                                const fn_ptr = llvm.LLVMBuildLoad2(builder, ptr_type, fn_slot_ptr, "vtable_fn_ptr");

                                // Build dynamic function type for call: (this: ptr, args...) -> ret_type
                                const fun_data = target_fun_decl.?.data.fun_decl;
                                const ret_t = if (target_fun_decl.?.resolved_type) |rt|
                                    types_mapping.getLLVMType(ctx, rt.Function.return_type.*)
                                else if (fun_data.type_ref) |tr|
                                    (if (tr.resolved_type) |rrt| types_mapping.getLLVMType(ctx, rrt.*) else i64_type)
                                else
                                    i64_type;

                                var param_types = try std.heap.page_allocator.alloc(llvm.LLVMTypeRef, 1 + call.arguments.len);
                                defer std.heap.page_allocator.free(param_types);
                                var arg_vals = try std.heap.page_allocator.alloc(llvm.LLVMValueRef, 1 + call.arguments.len);
                                defer std.heap.page_allocator.free(arg_vals);
                                param_types[0] = ptr_type;
                                arg_vals[0] = data_ptr;

                                for (call.arguments, 0..) |arg_node, i| {
                                    const p_type = if (target_fun_decl.?.resolved_type) |rt|
                                        (if (rt.* == .Function and i < rt.Function.params.len) types_mapping.getLLVMType(ctx, rt.Function.params[i].*) else i64_type)
                                    else
                                        i64_type;
                                    param_types[i + 1] = p_type;
                                    var arg_val = try emitExpression(ctx, mod, builder, scope, structs, libs, arg_node);
                                    arg_val = coerceArg(builder, arg_val, p_type);
                                    arg_vals[i + 1] = arg_val;
                                }

                                const dyn_fn_type = llvm.LLVMFunctionType(ret_t, param_types.ptr, @intCast(param_types.len), 0);
                                const call_name: [*c]const u8 = if (llvm.LLVMGetTypeKind(ret_t) == llvm.LLVMVoidTypeKind) "" else "vcall_tmp";
                                return llvm.LLVMBuildCall2(builder, dyn_fn_type, fn_ptr, arg_vals.ptr, @intCast(arg_vals.len), call_name);
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

            // Non-Function dynamic call (fallback — should rarely be reached)
            const callee_val = try emitExpression(ctx, mod, builder, scope, structs, libs, call.callee);

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
        .map_literal => {
            // Map literals emit Map constructor instance pointer
            const ptr_type = llvm.LLVMPointerTypeInContext(ctx, 0);
            return llvm.LLVMConstNull(ptr_type);
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

/// Coerces a concrete type value (data_ptr) into a Fat Pointer { data, vtable } for a target contract.
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

    // Look up static vtable global `{concrete_c_name}_{contract_c_name}_vtable`
    const vtable_name = try std.fmt.allocPrint(std.heap.page_allocator, "{s}_{s}_vtable\x00", .{ concrete_c_name, contract_c_name });
    defer std.heap.page_allocator.free(vtable_name);

    const vtable_global = llvm.LLVMGetNamedGlobal(mod, vtable_name.ptr) orelse return data_val;
    const vtable_ptr = vtable_global;

    var fat_val = llvm.LLVMGetUndef(fat_type);
    fat_val = llvm.LLVMBuildInsertValue(builder, fat_val, data_ptr, 0, "fat_data");
    fat_val = llvm.LLVMBuildInsertValue(builder, fat_val, vtable_ptr, 1, "fat_vtable");

    return fat_val;
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

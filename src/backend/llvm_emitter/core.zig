const std = @import("std");
const builtin = @import("builtin");
const ast = @import("../../core/ast.zig");
const compat = @import("../../core/compat.zig");
const ArrayList = compat.ArrayList;
const types_mapping = @import("types.zig");
const statement = @import("statement.zig");
const expression = @import("expression.zig");
const c_bindings = @import("c_bindings.zig");
const llvm = c_bindings.llvm;

pub const StructInfo = struct {
    struct_type: llvm.LLVMTypeRef,
    field_names: [][]const u8,
    field_types: []llvm.LLVMTypeRef,
};

/// In-Memory LLVM IR Emitter and Execution Driver.
pub const LLVMEmitter = struct {
    allocator: std.mem.Allocator,
    context: llvm.LLVMContextRef,
    module: ?llvm.LLVMModuleRef,
    builder: llvm.LLVMBuilderRef,
    is_release: bool,
    functions: std.StringHashMap(llvm.LLVMValueRef),
    structs: std.StringHashMap(StructInfo),
    /// Maps lib-block names (e.g. "Console") to their set of functions.
    libs: std.StringHashMap(std.StringHashMap([]const u8)),

    pub fn init(allocator: std.mem.Allocator, module_name: []const u8, is_release: bool) !LLVMEmitter {
        _ = llvm.LLVMInitializeNativeTarget();
        _ = llvm.LLVMInitializeNativeAsmPrinter();
        _ = llvm.LLVMInitializeNativeAsmParser();

        const context = llvm.LLVMContextCreate();
        const mod_name_c = try allocator.dupeZ(u8, module_name);
        defer allocator.free(mod_name_c);
        const module = llvm.LLVMModuleCreateWithNameInContext(mod_name_c.ptr, context);
        const builder = llvm.LLVMCreateBuilderInContext(context);

        return LLVMEmitter{
            .allocator = allocator,
            .context = context,
            .module = module,
            .builder = builder,
            .is_release = is_release,
            .functions = std.StringHashMap(llvm.LLVMValueRef).init(allocator),
            .structs = std.StringHashMap(StructInfo).init(allocator),
            .libs = std.StringHashMap(std.StringHashMap([]const u8)).init(allocator),
        };
    }

    pub fn deinit(self: *LLVMEmitter) void {
        self.functions.deinit();
        self.structs.deinit();
        var lib_it = self.libs.valueIterator();
        while (lib_it.next()) |v| {
            v.*.deinit();
        }
        self.libs.deinit();
        llvm.LLVMDisposeBuilder(self.builder);
        if (self.module) |m| {
            llvm.LLVMDisposeModule(m);
            self.module = null;
        }
        llvm.LLVMContextDispose(self.context);
    }

    /// Emits LLVM IR for top-level functions, expressions, and statements.
    pub fn emitModule(self: *LLVMEmitter, ast_root: *ast.ASTNode) !void {
        const mod = self.module orelse return error.ModuleAlreadyDisposed;

        if (ast_root.data != .program) return error.InvalidASTRoot;

        // Pass 0: Declare memory allocation prototypes
        const ptr_type = llvm.LLVMPointerTypeInContext(self.context, 0);
        const size_t_type = llvm.LLVMInt64TypeInContext(self.context);
        var gc_params = [_]llvm.LLVMTypeRef{size_t_type};
        const gc_type = llvm.LLVMFunctionType(ptr_type, &gc_params, 1, 0);
        _ = llvm.LLVMAddFunction(mod, "GC_malloc", gc_type);
        _ = llvm.LLVMAddFunction(mod, "malloc", gc_type);

        // Declare printf prototype for builtin print calls
        const i32_type = llvm.LLVMInt32TypeInContext(self.context);
        var printf_params = [_]llvm.LLVMTypeRef{ptr_type};
        const printf_type = llvm.LLVMFunctionType(i32_type, &printf_params, 1, 1); // varargs = 1
        _ = llvm.LLVMAddFunction(mod, "printf", printf_type);

        // Exception-handling runtime (setjmp/longjmp model, mirrors eiwa_runtime.h)
        const void_type = llvm.LLVMVoidTypeInContext(self.context);
        var setjmp_params = [_]llvm.LLVMTypeRef{ptr_type};
        const setjmp_type = llvm.LLVMFunctionType(i32_type, &setjmp_params, 1, 0);
        _ = llvm.LLVMAddFunction(mod, "setjmp", setjmp_type);

        var longjmp_params = [_]llvm.LLVMTypeRef{ ptr_type, i32_type };
        const longjmp_type = llvm.LLVMFunctionType(void_type, &longjmp_params, 2, 0);
        _ = llvm.LLVMAddFunction(mod, "longjmp", longjmp_type);

        var exit_params = [_]llvm.LLVMTypeRef{i32_type};
        const exit_type = llvm.LLVMFunctionType(void_type, &exit_params, 1, 0);
        _ = llvm.LLVMAddFunction(mod, "exit", exit_type);

        // Exception stack + active exception globals.
        const exc_stack_global = llvm.LLVMAddGlobal(mod, ptr_type, "eiwa_exception_stack");
        llvm.LLVMSetInitializer(exc_stack_global, llvm.LLVMConstNull(ptr_type));
        const active_exc_global = llvm.LLVMAddGlobal(mod, ptr_type, "eiwa_active_exception");
        llvm.LLVMSetInitializer(active_exc_global, llvm.LLVMConstNull(ptr_type));

        // struct EiwaExceptionFrame { jmp_buf buf; EiwaExceptionFrame* next; }
        // jmp_buf is modeled as a 512-byte buffer ([64 x i64]) to be safe across platforms.
        // TODO(emitter): Modeling jmp_buf as a fixed [64 x i64] works on the
        // platforms LLVM 21 targets here but is fragile: the real jmp_buf size
        // is platform/arch-specific, and setjmp/longjmp are used via raw symbol
        // linkage without knowing the actual target layout. Proper fix: emit the
        // frame with the real `jmp_buf` size for the target (or follow the C
        // transpiler, which includes eiwa_runtime.h and lets the C compiler
        // size it), instead of hardcoding 512 bytes.
        // INHERITED GAMBIARRA: the EiwaExceptionFrame + setjmp/longjmp model came
        // from the C backend — see PRE-EXISTING comment in
        // src/backend/c_transpiler/statement.zig (try_stmt) and the frame
        // struct in src/backend/c_transpiler/eiwa_runtime.h. The C version
        // declares the frame as real C types (`jmp_buf`); this LLVM copy
        // hardcodes the buffer size because it has no C header to include.
        const frame_struct = llvm.LLVMStructCreateNamed(self.context, "EiwaExceptionFrame");
        const buf_type = llvm.LLVMArrayType(llvm.LLVMInt64TypeInContext(self.context), 64);
        var frame_fields = [_]llvm.LLVMTypeRef{ buf_type, ptr_type };
        llvm.LLVMStructSetBody(frame_struct, &frame_fields, 2, 0);

        // sprintf prototype for lib `Standard` (sprintfInt) and Int.toString boxing.
        var sprintf_params = [_]llvm.LLVMTypeRef{ ptr_type, ptr_type };
        const sprintf_type = llvm.LLVMFunctionType(i32_type, &sprintf_params, 2, 1); // varargs = 1
        _ = llvm.LLVMAddFunction(mod, "sprintf", sprintf_type);

        // strlen prototype for lib `NativeString` and String concat.
        var strlen_params = [_]llvm.LLVMTypeRef{ptr_type};
        const strlen_type = llvm.LLVMFunctionType(size_t_type, &strlen_params, 1, 0);
        _ = llvm.LLVMAddFunction(mod, "strlen", strlen_type);

        // strstr/memcpy prototypes for the eiwa_str_replace helper.
        var strstr_params = [_]llvm.LLVMTypeRef{ ptr_type, ptr_type };
        const strstr_type = llvm.LLVMFunctionType(ptr_type, &strstr_params, 2, 0);
        _ = llvm.LLVMAddFunction(mod, "strstr", strstr_type);

        var memcpy_params = [_]llvm.LLVMTypeRef{ ptr_type, ptr_type, size_t_type };
        const memcpy_type = llvm.LLVMFunctionType(ptr_type, &memcpy_params, 3, 0);
        _ = llvm.LLVMAddFunction(mod, "memcpy", memcpy_type);

        // eiwa_to_string(i64) -> i8* — mirrors the eiwa_runtime.h heuristic:
        //   val == 0 -> "null"; val == 1 -> "true"; val < 0x10000 -> int via sprintf; else it's a String (char*) as-is.
        try self.emitToStringHelper(mod);
        try self.emitHashStringHelper(mod);
        try self.emitStrReplaceHelper(mod);

        // Collect the entry module and every module it (transitively) imports.
        var modules = ArrayList(*ast.ASTNode).init(self.allocator);
        defer modules.deinit();
        var visited = std.AutoHashMap(*ast.ASTNode, void).init(self.allocator);
        defer visited.deinit();
        try self.collectModules(ast_root, &modules, &visited);

        // Pass 1a: Declare all user-defined types (structs & constructors)
        for (modules.items) |m| {
            if (m.data != .program) continue;
            for (m.data.program.statements) |stmt| {
                if (stmt.data == .type_decl) {
                    try self.declareType(mod, stmt);
                }
            }
        }

        // Pass 1b: Declare all lib blocks (external FFI prototypes)
        for (modules.items) |m| {
            if (m.data != .program) continue;
            for (m.data.program.statements) |stmt| {
                if (stmt.data == .lib_decl) {
                    try self.declareLib(mod, stmt);
                }
            }
        }

        // Pass 1c: Declare all function signatures (top-level + type methods + object members)
        for (modules.items) |m| {
            if (m.data != .program) continue;
            for (m.data.program.statements) |stmt| {
                if (stmt.data == .fun_decl) {
                    try self.declareFunction(mod, stmt);
                } else if (stmt.data == .type_decl) {
                    // Generic templates are never emitted directly; only
                    // monomorphized instances (which have generic_params empty)
                    // produce code. Mirrors the C transpiler.
                    if (stmt.data.type_decl.generic_params.len > 0) continue;
                    for (stmt.data.type_decl.methods) |m_node| {
                        if (m_node.data != .fun_decl) continue;
                        try self.declareFunction(mod, m_node);
                    }
                } else if (stmt.data == .object_decl) {
                    for (stmt.data.object_decl.members) |member| {
                        if (member.data != .fun_decl) continue;
                        try self.declareFunction(mod, member);
                    }
                }
            }
        }

        // Pass 1d: Declare object member globals (`Env.isLoaded` etc.), named
        // `{object_c_name}_{var}` per infer_decl.zig inferVarDecl.
        for (modules.items) |m| {
            if (m.data != .program) continue;
            for (m.data.program.statements) |stmt| {
                if (stmt.data != .object_decl) continue;
                const obj = stmt.data.object_decl;
                if (obj.resolved_c_name == null) continue;
                for (obj.members) |member| {
                    if (member.data != .var_decl) continue;
                    const v = member.data.var_decl;
                    const var_name = v.resolved_c_name orelse v.name;
                    const llvm_type = if (member.resolved_type) |rt|
                        types_mapping.getLLVMType(self.context, rt.*)
                    else
                        llvm.LLVMInt64TypeInContext(self.context);
                    const var_name_z = try self.allocator.dupeZ(u8, var_name);
                    defer self.allocator.free(var_name_z);
                    const global = llvm.LLVMAddGlobal(mod, llvm_type, var_name_z.ptr);
                    llvm.LLVMSetInitializer(global, llvm.LLVMConstNull(llvm_type));
                }
            }
        }

        // Pass 2: Emit function bodies (top-level functions + type methods).
        // Only functions transitively reachable from the entry module's
        // top-level statements are emitted. Everything else is still declared
        // (Pass 1c) so calls resolve, but has no body — drastically cutting
        // the JIT-compiled module size (the full stdlib is otherwise pulled in
        // via the implicit-import closure).
        var top_level_stmts = ArrayList(*ast.ASTNode).init(self.allocator);
        defer top_level_stmts.deinit();

        var reachable = std.StringHashMap(void).init(self.allocator);
        defer {
            var it = reachable.keyIterator();
            while (it.next()) |k| self.allocator.free(k.*);
            reachable.deinit();
        }
        var worklist = ArrayList([]const u8).init(self.allocator);
        defer worklist.deinit();

        // Seed: every function declared in the entry module plus callees of the
        // entry module's top-level statements (which become main()).
        if (ast_root.data == .program) {
            for (ast_root.data.program.statements) |stmt| {
                try self.collectCallees(stmt, &reachable, &worklist);
            }
            for (ast_root.data.program.statements) |stmt| {
                if (stmt.data == .fun_decl) {
                    if (stmt.data.fun_decl.generic_params.len > 0) continue;
                    const name = stmt.data.fun_decl.resolved_c_name orelse stmt.data.fun_decl.name;
                    try self.markReachable(name, &reachable, &worklist);
                } else if (stmt.data == .type_decl) {
                    if (stmt.data.type_decl.generic_params.len > 0) continue;
                    for (stmt.data.type_decl.methods) |m_node| {
                        if (m_node.data != .fun_decl) continue;
                        if (m_node.data.fun_decl.generic_params.len > 0) continue;
                        const name = m_node.data.fun_decl.resolved_c_name orelse m_node.data.fun_decl.name;
                        try self.markReachable(name, &reachable, &worklist);
                    }
                } else if (stmt.data == .object_decl) {
                    for (stmt.data.object_decl.members) |member| {
                        if (member.data != .fun_decl) continue;
                        if (member.data.fun_decl.generic_params.len > 0) continue;
                        const name = member.data.fun_decl.resolved_c_name orelse member.data.fun_decl.name;
                        try self.markReachable(name, &reachable, &worklist);
                    }
                }
            }
        }

        // Fixpoint: walk every reachable function's body to find more callees.
        // TODO(emitter): The reachability pass below is O(functions^2) and the
        // fun_decl/type_decl/object_decl branches are copy-pasted three times
        // (seeding, fixpoint walk, emission), so they drift easily. Proper fix:
        // build a `StringHashMap(name -> *ASTNode)` index of all functions once
        // (covering top-level fun_decls, type_decl.methods and object members),
        // then seed/walk/emit against that map. Also consider matching on a
        // `resolved_type.Function.c_name` when available instead of stringly
        // name comparison, which is fragile across monomorphization.
        // LLVM-SPECIFIC (NOT inherited from C): the C transpiler emits every
        // function and lets the C linker dead-strip; the LLVM emitter adds this
        // pass only to keep JIT compile time/IR size down (the stdlib would
        // otherwise be pulled in wholesale). It has no C-side counterpart.
        var wi: usize = 0;
        while (wi < worklist.items.len) : (wi += 1) {
            const fname = worklist.items[wi];
            for (modules.items) |m| {
                if (m.data != .program) continue;
                for (m.data.program.statements) |stmt| {
                    if (stmt.data == .fun_decl) {
                        if (stmt.data.fun_decl.generic_params.len > 0) continue;
                        const name = stmt.data.fun_decl.resolved_c_name orelse stmt.data.fun_decl.name;
                        if (std.mem.eql(u8, name, fname)) {
                            try self.collectCallees(stmt, &reachable, &worklist);
                            break;
                        }
                    } else if (stmt.data == .type_decl) {
                        if (stmt.data.type_decl.generic_params.len > 0) continue;
                        for (stmt.data.type_decl.methods) |m_node| {
                            if (m_node.data != .fun_decl) continue;
                            if (m_node.data.fun_decl.generic_params.len > 0) continue;
                            const name = m_node.data.fun_decl.resolved_c_name orelse m_node.data.fun_decl.name;
                            if (std.mem.eql(u8, name, fname)) {
                                try self.collectCallees(m_node, &reachable, &worklist);
                                break;
                            }
                        }
                    } else if (stmt.data == .object_decl) {
                        for (stmt.data.object_decl.members) |member| {
                            if (member.data != .fun_decl) continue;
                            if (member.data.fun_decl.generic_params.len > 0) continue;
                            const name = member.data.fun_decl.resolved_c_name orelse member.data.fun_decl.name;
                            if (std.mem.eql(u8, name, fname)) {
                                try self.collectCallees(member, &reachable, &worklist);
                                break;
                            }
                        }
                    }
                }
            }
        }

        for (modules.items) |m| {
            if (m.data != .program) continue;
            for (m.data.program.statements) |stmt| {
                if (stmt.data == .fun_decl) {
                    if (stmt.data.fun_decl.generic_params.len > 0) continue;
                    const fname = stmt.data.fun_decl.resolved_c_name orelse stmt.data.fun_decl.name;
                    if (!reachable.contains(fname)) continue;
                    if (m != ast_root) {
                        self.emitFunctionBody(mod, stmt) catch |err| {
                            std.debug.print("LLVM Warning: emitting stub for {s} (unsupported: {})\n", .{ fname, err });
                            self.emitFunctionStub(mod, fname) catch {};
                            continue;
                        };
                    } else {
                        try self.emitFunctionBody(mod, stmt);
                    }
                } else if (stmt.data == .type_decl) {
                    // Generic templates are never emitted directly; only
                    // monomorphized instances (which have generic_params empty)
                    // produce code. Mirrors the C transpiler.
                    if (stmt.data.type_decl.generic_params.len > 0) continue;
                    // TODO(emitter): Primitive/String methods (core_String,
                    // core_Int, core_Bool, core_Double) are skipped and handled
                    // by inline emitter special-cases (eiwa_to_string, String
                    // concat, etc.) instead of their Eiwa bodies, because those
                    // bodies rely on struct fields (this.length, this.ptr) the
                    // LLVM value model doesn't materialize. This hardcoded name
                    // list is a shortcut: it will silently misbehave if a user
                    // defines a type named "String" or extends the primitive
                    // method set. Proper fix: have the type checker expose the
                    // primitive-ness of a type (like the C transpiler's
                    // is_boxed/isPrimitive flags) and skip on that, not on names.
                    // INHERITED GAMBIARRA: the notion that primitives/String are
                    // special-cased rather than fully materialized comes from the
                    // C backend's value model (see PRE-EXISTING comments in
                    // src/backend/c_transpiler/eiwa_runtime.h and the C
                    // transpiler's is_boxed flags). The C backend can still emit
                    // primitive method bodies; the LLVM model cannot, hence the
                    // skip list. Fixing the value model in LLVM removes this list.
                    const t_name = stmt.data.type_decl.resolved_c_name orelse stmt.data.type_decl.name;
                    const is_inline = std.mem.eql(u8, t_name, "core_String") or
                        std.mem.eql(u8, t_name, "String") or
                        std.mem.eql(u8, t_name, "core_Int") or
                        std.mem.eql(u8, t_name, "core_Bool") or
                        std.mem.eql(u8, t_name, "core_Double");
                    if (is_inline) continue;
                    for (stmt.data.type_decl.methods) |m_node| {
                        if (m_node.data != .fun_decl) continue;
                        if (m_node.data.fun_decl.generic_params.len > 0) continue;
                        const fname = m_node.data.fun_decl.resolved_c_name orelse m_node.data.fun_decl.name;
                        if (!reachable.contains(fname)) continue;
                        // TODO(emitter): Method bodies degrade to skip-with-
                        // warning even in the root module because monomorphized
                        // std types (List<T>, Serializable derivations, etc.)
                        // are injected into the root program by the type
                        // checker (type_checker/core.zig validate()) and may
                        // contain constructs the emitter doesn't support yet
                        // (e.g. contract dispatch — Phase 61). If the body is
                        // actually called at runtime, the JIT/linker will fail
                        // on the bodiless declaration. Remove this tolerance
                        // once Phase 61 lands and parity is reached.
                        self.emitFunctionBody(mod, m_node) catch |err| {
                            std.debug.print("LLVM Warning: emitting stub for {s} (unsupported: {})\n", .{ fname, err });
                            self.emitFunctionStub(mod, fname) catch {};
                            continue;
                        };
                    }
                } else if (stmt.data == .object_decl) {
                    for (stmt.data.object_decl.members) |member| {
                        if (member.data != .fun_decl) continue;
                        if (member.data.fun_decl.generic_params.len > 0) continue;
                        const fname = member.data.fun_decl.resolved_c_name orelse member.data.fun_decl.name;
                        if (!reachable.contains(fname)) continue;
                        self.emitFunctionBody(mod, member) catch |err| {
                            std.debug.print("LLVM Warning: emitting stub for {s} (unsupported: {})\n", .{ fname, err });
                            self.emitFunctionStub(mod, fname) catch {};
                            continue;
                        };
                    }
                } else if (m == ast_root and stmt.data != .type_decl and stmt.data != .lib_decl) {
                try top_level_stmts.append(stmt);
            }
        }
        }

        // Pass 3: Handle Hybrid Main (top-level statements inside main())
        if (top_level_stmts.items.len > 0) {
            var main_func = llvm.LLVMGetNamedFunction(mod, "main");
            if (main_func == null) {
                const func_type = llvm.LLVMFunctionType(i32_type, null, 0, 0);
                main_func = llvm.LLVMAddFunction(mod, "main", func_type);
                const entry_block = llvm.LLVMAppendBasicBlockInContext(self.context, main_func.?, "entry");
                llvm.LLVMPositionBuilderAtEnd(self.builder, entry_block);

                var scope = std.StringHashMap(llvm.LLVMValueRef).init(self.allocator);
                defer scope.deinit();

                for (top_level_stmts.items, 0..) |stmt, stmt_idx| {
                    _ = stmt_idx;
                    try statement.emitStatement(self.context, mod, self.builder, main_func.?, &scope, &self.structs, &self.libs, stmt);
                }

                const cur_bb = llvm.LLVMGetInsertBlock(self.builder);
                if (llvm.LLVMGetBasicBlockTerminator(cur_bb) == null) {
                    const zero = llvm.LLVMConstInt(i32_type, 0, 0);
                    _ = llvm.LLVMBuildRet(self.builder, zero);
                }
            }
        }
    }

    /// Recursively collects the given module and all modules it imports.
    /// Cycles are broken via the `visited` set. Imported module ASTs are linked
    /// by the type checker through `import_stmt.module_ast`.
    fn collectModules(
        self: *LLVMEmitter,
        module: *ast.ASTNode,
        modules: *ArrayList(*ast.ASTNode),
        visited: *std.AutoHashMap(*ast.ASTNode, void),
    ) !void {
        if (module.data != .program) return;
        if (visited.contains(module)) return;
        try visited.put(module, {});
        try modules.append(module);

        for (module.data.program.statements) |stmt| {
            if (stmt.data == .import_stmt) {
                if (stmt.data.import_stmt.module_ast) |mod_ast| {
                    try self.collectModules(mod_ast, modules, visited);
                }
            }
        }
    }

    /// Marks a function name as reachable, enqueueing it for body walking.
    fn markReachable(
        self: *LLVMEmitter,
        name: []const u8,
        reachable: *std.StringHashMap(void),
        worklist: *ArrayList([]const u8),
    ) !void {
        if (reachable.contains(name)) return;
        const owned = try self.allocator.dupe(u8, name);
        try reachable.put(owned, {});
        try worklist.append(owned);
    }

    /// Walks an AST subtree, adding every function symbol it may reference to
    /// the reachable set. This mirrors the callee-resolution in expression.zig
    /// (direct identifier calls, object/static methods via resolved Function
    /// c_name, FFI lib calls, and `{Type}_{method}` mangled method calls).
    fn collectCallees(
        self: *LLVMEmitter,
        node: *ast.ASTNode,
        reachable: *std.StringHashMap(void),
        worklist: *ArrayList([]const u8),
    ) !void {
        switch (node.data) {
            .program => |p| for (p.statements) |s| try self.collectCallees(s, reachable, worklist),
            .block => |b| for (b.statements) |s| try self.collectCallees(s, reachable, worklist),
            .fun_decl => |f| {
                if (f.generic_params.len > 0) return;
                if (f.is_expr_body) {
                    try self.collectCallees(f.body, reachable, worklist);
                } else {
                    try self.collectCallees(f.body, reachable, worklist);
                }
            },
            .var_decl => |v| if (v.initializer) |i| try self.collectCallees(i, reachable, worklist),
            .assignment => |a| try self.collectCallees(a.value, reachable, worklist),
            .if_expr => |i| {
                try self.collectCallees(i.condition, reachable, worklist);
                try self.collectCallees(i.then_branch, reachable, worklist);
                if (i.else_branch) |e| try self.collectCallees(e, reachable, worklist);
            },
            .while_stmt => |w| {
                try self.collectCallees(w.condition, reachable, worklist);
                try self.collectCallees(w.body, reachable, worklist);
            },
            .for_stmt => |f| {
                try self.collectCallees(f.iterable, reachable, worklist);
                try self.collectCallees(f.body, reachable, worklist);
            },
            .return_stmt => |r| if (r.value) |v| try self.collectCallees(v, reachable, worklist),
            .throw_stmt => |t| try self.collectCallees(t.expr, reachable, worklist),
            .try_stmt => |t| {
                try self.collectCallees(t.body, reachable, worklist);
                for (t.catches) |c| try self.collectCallees(c.body, reachable, worklist);
            },
            .when_expr => |w| {
                if (w.subject) |s| try self.collectCallees(s, reachable, worklist);
                for (w.cases) |case| {
                    for (case.conds) |cond| try self.collectCallees(cond, reachable, worklist);
                    try self.collectCallees(case.body, reachable, worklist);
                }
            },
            .lambda_expr => |l| for (l.body) |s| try self.collectCallees(s, reachable, worklist),
            .binary_expr => |b| {
                try self.collectCallees(b.left, reachable, worklist);
                try self.collectCallees(b.right, reachable, worklist);
            },
            .unary_expr => |u| try self.collectCallees(u.operand, reachable, worklist),
            .ternary_expr => |t| {
                try self.collectCallees(t.condition, reachable, worklist);
                try self.collectCallees(t.then_branch, reachable, worklist);
                if (t.else_branch) |e| try self.collectCallees(e, reachable, worklist);
            },
            .as_expr => |a| try self.collectCallees(a.value, reachable, worklist),
            .is_expr => |i| try self.collectCallees(i.value, reachable, worklist),
            .index_expr => |i| {
                try self.collectCallees(i.object, reachable, worklist);
                try self.collectCallees(i.index, reachable, worklist);
            },
            .index_set_expr => |i| {
                try self.collectCallees(i.object, reachable, worklist);
                try self.collectCallees(i.index, reachable, worklist);
                try self.collectCallees(i.value, reachable, worklist);
            },
            .array_literal => |a| for (a.elements) |e| try self.collectCallees(e, reachable, worklist),
            .map_literal => |m| for (m.elements) |e| try self.collectCallees(e, reachable, worklist),
            .set_expr => |s| {
                try self.collectCallees(s.object, reachable, worklist);
                try self.collectCallees(s.value, reachable, worklist);
            },
            .get_expr => |g| {
                // `{Type}_{method}` mangled method call on a struct instance.
                if (g.object.resolved_type) |obj_rt| {
                    var type_name: []const u8 = "";
                    if (obj_rt.* == .Custom) {
                        type_name = obj_rt.Custom;
                    } else if (obj_rt.* == .Pointer and obj_rt.Pointer.* == .Custom) {
                        type_name = obj_rt.Pointer.Custom;
                    }
                    if (type_name.len > 0 and self.structs.get(type_name) != null) {
                        const buf = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ type_name, g.name });
                        try self.markReachable(buf, reachable, worklist);
                        self.allocator.free(buf);
                    }
                }
                try self.collectCallees(g.object, reachable, worklist);
            },
            .call_expr => |c| {
                if (c.callee.data == .identifier) {
                    const ident = c.callee.data.identifier;
                    const name = ident.resolved_c_name orelse ident.name;
                    const is_string_ctor = std.mem.eql(u8, name, "core_String") or std.mem.eql(u8, name, "String");
                    if (!is_string_ctor) {
                        try self.markReachable(name, reachable, worklist);
                    }
                } else if (c.callee.data == .get_expr) {
                    const g = c.callee.data.get_expr;
                    // FFI lib method call: object is an identifier naming a lib.
                    if (g.object.data != .identifier or self.libs.get(g.object.data.identifier.name) == null) {
                        // Object/static method call resolved to an exact mangled symbol.
                        if (c.callee.resolved_type) |rt| {
                            if (rt.* == .Function and rt.Function.c_name.len > 0) {
                                try self.markReachable(rt.Function.c_name, reachable, worklist);
                            }
                        }
                        // `{Type}_{method}` mangled call via object's struct type.
                        try self.collectCallees(g.object, reachable, worklist);
                    }
                }
                try self.collectCallees(c.callee, reachable, worklist);
                for (c.arguments) |arg| try self.collectCallees(arg, reachable, worklist);
            },
            else => {},
        }
    }

    /// Emits the `eiwa_to_string` equivalent used for contract dispatch of
    /// `toString()` on a `Stringable`-typed value. Values are modeled as raw
    /// i64 (null/bool/int boxed) or char pointers (String), mirroring the
    /// C runtime heuristic in eiwa_runtime.h.
    ///
    /// TODO(emitter): This reimplements the runtime's eiwa_to_string heuristic
    /// (val == 0 -> "null", val == 1 -> "true", val < 0x10000 -> int, else it's
    /// a String / custom boxed pointer) as LLVM IR. It is duplicated logic with
    /// `emitHashStringHelper` below and with the runtime, so the three can
    /// drift apart. It also cannot distinguish a String from a custom object
    /// (both are char* >= 0x10000) — a real eiwa_to_string would inspect a type
    /// descriptor. Proper fix: link the actual runtime C helper (or a generated
    /// eiwa_to_string) instead of re-emitting it, and add type descriptors to
    /// the LLVM model so toString is exact for custom types.
    /// INHERITED GAMBIARRA: the heuristic itself came from the C backend — see
    /// the PRE-EXISTING comment in src/backend/c_transpiler/eiwa_runtime.h
    /// (eiwa_to_string). The C version is exact (checks the type descriptor
    /// and dispatches through the Stringable vtable); this LLVM re-emission is
    /// the degraded copy. The 0x10000 tag constant is shared and must not drift.
    fn emitToStringHelper(self: *LLVMEmitter, mod: llvm.LLVMModuleRef) !void {
        const i64_type = llvm.LLVMInt64TypeInContext(self.context);
        const ptr_type = llvm.LLVMPointerTypeInContext(self.context, 0);

        var params = [_]llvm.LLVMTypeRef{ptr_type};
        const fn_type = llvm.LLVMFunctionType(ptr_type, &params, 1, 0);
        const fn_val = llvm.LLVMAddFunction(mod, "eiwa_to_string", fn_type);
        const entry = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const null_bb = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "is_null");
        const bool_bb = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "is_bool");
        const true_bb = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "is_true");
        const small_bb = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "is_small");
        const int_bb = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "is_int");
        const str_bb = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "is_str");

        llvm.LLVMPositionBuilderAtEnd(self.builder, entry);
        const val = llvm.LLVMGetParam(fn_val, 0);
        const null_ptr = llvm.LLVMConstNull(ptr_type);
        const is_null = llvm.LLVMBuildICmp(self.builder, llvm.LLVMIntEQ, val, null_ptr, "ts_null");
        _ = llvm.LLVMBuildCondBr(self.builder, is_null, null_bb, bool_bb);

        llvm.LLVMPositionBuilderAtEnd(self.builder, null_bb);
        const null_str = llvm.LLVMBuildGlobalStringPtr(self.builder, "null", "ts_null_str");
        _ = llvm.LLVMBuildRet(self.builder, null_str);

        llvm.LLVMPositionBuilderAtEnd(self.builder, bool_bb);
        const int_val = llvm.LLVMBuildPtrToInt(self.builder, val, i64_type, "ts_int");
        const one = llvm.LLVMConstInt(i64_type, 1, 0);
        const is_one = llvm.LLVMBuildICmp(self.builder, llvm.LLVMIntEQ, int_val, one, "ts_one");
        _ = llvm.LLVMBuildCondBr(self.builder, is_one, true_bb, small_bb);

        llvm.LLVMPositionBuilderAtEnd(self.builder, true_bb);
        const true_str = llvm.LLVMBuildGlobalStringPtr(self.builder, "true", "ts_true_str");
        _ = llvm.LLVMBuildRet(self.builder, true_str);

        llvm.LLVMPositionBuilderAtEnd(self.builder, small_bb);
        const max_small = llvm.LLVMConstInt(i64_type, 0x10000, 0);
        const is_small = llvm.LLVMBuildICmp(self.builder, llvm.LLVMIntULT, int_val, max_small, "ts_small");
        _ = llvm.LLVMBuildCondBr(self.builder, is_small, int_bb, str_bb);

        llvm.LLVMPositionBuilderAtEnd(self.builder, int_bb);
        // buf = malloc(32); sprintf(buf, "%lld", val); ret buf
        // TODO(emitter): malloc-first ordering is a libgc-linking workaround —
        // see the identical note in emitTypeConstructor. buf is capped at 32
        // bytes, matching the runtime's core_Int_toString bound.
        // LLVM-SPECIFIC (NOT inherited from C): the C runtime's core_Int_toString
        // uses GC_MALLOC via eiwa_runtime.h; this fallback is only because the
        // `eiwa` host binary doesn't link libgc.
        const gc_func = llvm.LLVMGetNamedFunction(mod, "malloc") orelse llvm.LLVMGetNamedFunction(mod, "GC_malloc").?;
        const gc_type = llvm.LLVMGlobalGetValueType(gc_func);
        const buf_size = llvm.LLVMConstInt(i64_type, 32, 0);
        var gc_args = [_]llvm.LLVMValueRef{buf_size};
        const buf = llvm.LLVMBuildCall2(self.builder, gc_type, gc_func, &gc_args, 1, "ts_buf");

        const sprintf_func = llvm.LLVMGetNamedFunction(mod, "sprintf") orelse return error.SprintfNotFound;
        const sprintf_type = llvm.LLVMGlobalGetValueType(sprintf_func);
        const fmt = llvm.LLVMBuildGlobalStringPtr(self.builder, "%lld", "ts_fmt");
        var sp_args = [_]llvm.LLVMValueRef{ buf, fmt, val };
        _ = llvm.LLVMBuildCall2(self.builder, sprintf_type, sprintf_func, &sp_args, 3, "ts_sprintf");
        _ = llvm.LLVMBuildRet(self.builder, buf);

        llvm.LLVMPositionBuilderAtEnd(self.builder, str_bb);
        _ = llvm.LLVMBuildRet(self.builder, val);
    }

    /// Emits `eiwa_hash_string(i8*) -> i64` — the djb2 hash over a char buffer,
    /// equivalent to `String.hashCode()` in core.ei (`hash = hash * 33 + c`).
    ///
    /// TODO(emitter): Like emitToStringHelper, this is a hand-emitted copy of
    /// runtime/stdlib behavior (String.hashCode) because the LLVM model treats
    /// String as a bare char* and can't run the stdlib body (which reads
    /// this.length/this.ptr). If the String representation is ever materialized
    /// (see the String-concat TODO), this helper becomes redundant with the
    /// stdlib body and should be deleted.
    /// INHERITED GAMBIARRA: the name-based hashCode dispatch + small-int tagging
    /// came from the C backend — see PRE-EXISTING comments in
    /// src/backend/c_transpiler/expression.zig (get_expr hashCode) and
    /// src/backend/c_transpiler/eiwa_runtime.h (eiwa_hash_code). The C version
    /// dispatches through the Hashable vtable for custom types; this LLVM copy
    /// only handles char* strings and boxes ints.
    fn emitHashStringHelper(self: *LLVMEmitter, mod: llvm.LLVMModuleRef) !void {
        const i64_type = llvm.LLVMInt64TypeInContext(self.context);
        const i8_type = llvm.LLVMInt8TypeInContext(self.context);
        const ptr_type = llvm.LLVMPointerTypeInContext(self.context, 0);

        var params = [_]llvm.LLVMTypeRef{ptr_type};
        const fn_type = llvm.LLVMFunctionType(i64_type, &params, 1, 0);
        const fn_val = llvm.LLVMAddFunction(mod, "eiwa_hash_string", fn_type);
        const entry = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const loop_head = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop_head");
        const loop_body_bb = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop_body");
        const done_bb = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "done");
        llvm.LLVMPositionBuilderAtEnd(self.builder, entry);

        const str = llvm.LLVMGetParam(fn_val, 0);
        const hash_ptr = llvm.LLVMBuildAlloca(self.builder, i64_type, "hash");
        const seed = llvm.LLVMConstInt(i64_type, 5381, 0);
        _ = llvm.LLVMBuildStore(self.builder, seed, hash_ptr);
        const idx_ptr = llvm.LLVMBuildAlloca(self.builder, i64_type, "i");
        const zero = llvm.LLVMConstInt(i64_type, 0, 0);
        _ = llvm.LLVMBuildStore(self.builder, zero, idx_ptr);
        const null_ptr = llvm.LLVMConstNull(ptr_type);
        const is_null = llvm.LLVMBuildICmp(self.builder, llvm.LLVMIntEQ, str, null_ptr, "hs_null");
        _ = llvm.LLVMBuildCondBr(self.builder, is_null, done_bb, loop_head);

        llvm.LLVMPositionBuilderAtEnd(self.builder, loop_head);
        const idx = llvm.LLVMBuildLoad2(self.builder, i64_type, idx_ptr, "hs_i");
        var hs_idx = [_]llvm.LLVMValueRef{idx};
        const char_ptr = llvm.LLVMBuildGEP2(self.builder, i8_type, str, &hs_idx, 1, "hs_char_ptr");
        const char_val = llvm.LLVMBuildLoad2(self.builder, i8_type, char_ptr, "hs_char");
        const zero_i8 = llvm.LLVMConstInt(i8_type, 0, 0);
        const not_end = llvm.LLVMBuildICmp(self.builder, llvm.LLVMIntNE, char_val, zero_i8, "hs_cond");
        _ = llvm.LLVMBuildCondBr(self.builder, not_end, loop_body_bb, done_bb);

        llvm.LLVMPositionBuilderAtEnd(self.builder, loop_body_bb);
        const hash_val = llvm.LLVMBuildLoad2(self.builder, i64_type, hash_ptr, "hs_hash");
        const mul = llvm.LLVMBuildMul(self.builder, hash_val, llvm.LLVMConstInt(i64_type, 33, 0), "hs_mul");
        const char_ext = llvm.LLVMBuildSExt(self.builder, char_val, i64_type, "hs_ext");
        const add = llvm.LLVMBuildAdd(self.builder, mul, char_ext, "hs_add");
        _ = llvm.LLVMBuildStore(self.builder, add, hash_ptr);
        const next = llvm.LLVMBuildAdd(self.builder, idx, llvm.LLVMConstInt(i64_type, 1, 0), "hs_next");
        _ = llvm.LLVMBuildStore(self.builder, next, idx_ptr);
        _ = llvm.LLVMBuildBr(self.builder, loop_head);

        llvm.LLVMPositionBuilderAtEnd(self.builder, done_bb);
        const final_hash = llvm.LLVMBuildLoad2(self.builder, i64_type, hash_ptr, "hs_final");
        _ = llvm.LLVMBuildRet(self.builder, final_hash);
    }

    /// Emits `eiwa_str_replace(i8* s, i8* old, i8* new) -> i8*` — replace all
    /// occurrences of `old` by `new` in `s`, mirroring `String.replace` in
    /// std/core.ei (strstr + memcpy loop).
    ///
    /// TODO(emitter): SPECIAL CASE — review before promoting LLVM to default.
    /// Like emitToStringHelper/emitHashStringHelper, this is a hand-emitted
    /// copy of the stdlib body because the LLVM model treats String as a bare
    /// char* and can't run `core_String.replace` (which reads this.ptr /
    /// this.length). malloc-first ordering is the libgc-linking workaround
    /// (the stdlib body uses Standard.gcMalloc). LLVM-SPECIFIC (NOT inherited
    /// from C): the C backend emits the real core_String.replace body.
    fn emitStrReplaceHelper(self: *LLVMEmitter, mod: llvm.LLVMModuleRef) !void {
        const i64_type = llvm.LLVMInt64TypeInContext(self.context);
        const ptr_type = llvm.LLVMPointerTypeInContext(self.context, 0);

        var params = [_]llvm.LLVMTypeRef{ ptr_type, ptr_type, ptr_type };
        const fn_type = llvm.LLVMFunctionType(ptr_type, &params, 3, 0);
        const fn_val = llvm.LLVMAddFunction(mod, "eiwa_str_replace", fn_type);

        const entry = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const count_head = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "count_head");
        const count_body = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "count_body");
        const count_done = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "count_done");
        const no_match_bb = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "no_match");
        const alloc_bb = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "alloc");
        const copy_head = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "copy_head");
        const copy_body = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "copy_body");
        const tail_bb = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "tail");

        const strlen_fn = llvm.LLVMGetNamedFunction(mod, "strlen") orelse return error.StrlenNotFound;
        const strlen_type = llvm.LLVMGlobalGetValueType(strlen_fn);
        const strstr_fn = llvm.LLVMGetNamedFunction(mod, "strstr") orelse return error.StrstrNotFound;
        const strstr_type = llvm.LLVMGlobalGetValueType(strstr_fn);
        const memcpy_fn = llvm.LLVMGetNamedFunction(mod, "memcpy") orelse return error.MemcpyNotFound;
        const memcpy_type = llvm.LLVMGlobalGetValueType(memcpy_fn);
        const malloc_fn = llvm.LLVMGetNamedFunction(mod, "malloc") orelse return error.MallocNotFound;
        const malloc_type = llvm.LLVMGlobalGetValueType(malloc_fn);

        llvm.LLVMPositionBuilderAtEnd(self.builder, entry);
        const s = llvm.LLVMGetParam(fn_val, 0);
        const old = llvm.LLVMGetParam(fn_val, 1);
        const new_str = llvm.LLVMGetParam(fn_val, 2);

        var slen_args = [_]llvm.LLVMValueRef{s};
        const slen = llvm.LLVMBuildCall2(self.builder, strlen_type, strlen_fn, &slen_args, 1, "slen");
        var olen_args = [_]llvm.LLVMValueRef{old};
        const olen = llvm.LLVMBuildCall2(self.builder, strlen_type, strlen_fn, &olen_args, 1, "olen");
        var nlen_args = [_]llvm.LLVMValueRef{new_str};
        const nlen = llvm.LLVMBuildCall2(self.builder, strlen_type, strlen_fn, &nlen_args, 1, "nlen");

        const count_ptr = llvm.LLVMBuildAlloca(self.builder, i64_type, "count");
        _ = llvm.LLVMBuildStore(self.builder, llvm.LLVMConstInt(i64_type, 0, 0), count_ptr);
        const curr_ptr = llvm.LLVMBuildAlloca(self.builder, ptr_type, "curr");
        _ = llvm.LLVMBuildStore(self.builder, s, curr_ptr);
        _ = llvm.LLVMBuildBr(self.builder, count_head);

        // Pass 1: count occurrences
        llvm.LLVMPositionBuilderAtEnd(self.builder, count_head);
        const curr1 = llvm.LLVMBuildLoad2(self.builder, ptr_type, curr_ptr, "curr1");
        var strstr_args1 = [_]llvm.LLVMValueRef{ curr1, old };
        const match1 = llvm.LLVMBuildCall2(self.builder, strstr_type, strstr_fn, &strstr_args1, 2, "match1");
        const found1 = llvm.LLVMBuildICmp(self.builder, llvm.LLVMIntNE, match1, llvm.LLVMConstNull(ptr_type), "found1");
        _ = llvm.LLVMBuildCondBr(self.builder, found1, count_body, count_done);

        llvm.LLVMPositionBuilderAtEnd(self.builder, count_body);
        const c_val = llvm.LLVMBuildLoad2(self.builder, i64_type, count_ptr, "c_val");
        _ = llvm.LLVMBuildStore(self.builder, llvm.LLVMBuildAdd(self.builder, c_val, llvm.LLVMConstInt(i64_type, 1, 0), "c_inc"), count_ptr);
        const match1_int = llvm.LLVMBuildPtrToInt(self.builder, match1, i64_type, "match1_int");
        const next_curr = llvm.LLVMBuildAdd(self.builder, match1_int, olen, "next_curr");
        _ = llvm.LLVMBuildStore(self.builder, llvm.LLVMBuildIntToPtr(self.builder, next_curr, ptr_type, "next_curr_ptr"), curr_ptr);
        _ = llvm.LLVMBuildBr(self.builder, count_head);

        llvm.LLVMPositionBuilderAtEnd(self.builder, count_done);
        const final_count = llvm.LLVMBuildLoad2(self.builder, i64_type, count_ptr, "final_count");
        const has_match = llvm.LLVMBuildICmp(self.builder, llvm.LLVMIntNE, final_count, llvm.LLVMConstInt(i64_type, 0, 0), "has_match");
        _ = llvm.LLVMBuildCondBr(self.builder, has_match, alloc_bb, no_match_bb);

        llvm.LLVMPositionBuilderAtEnd(self.builder, no_match_bb);
        _ = llvm.LLVMBuildRet(self.builder, s);

        // newlen = slen + count * (nlen - olen); buf = malloc(newlen + 1)
        llvm.LLVMPositionBuilderAtEnd(self.builder, alloc_bb);
        const delta = llvm.LLVMBuildSub(self.builder, nlen, olen, "delta");
        const total_delta = llvm.LLVMBuildMul(self.builder, final_count, delta, "total_delta");
        const newlen = llvm.LLVMBuildAdd(self.builder, slen, total_delta, "newlen");
        const alloc_size = llvm.LLVMBuildAdd(self.builder, newlen, llvm.LLVMConstInt(i64_type, 1, 0), "alloc_size");
        var malloc_args = [_]llvm.LLVMValueRef{alloc_size};
        const buf = llvm.LLVMBuildCall2(self.builder, malloc_type, malloc_fn, &malloc_args, 1, "buf");

        _ = llvm.LLVMBuildStore(self.builder, s, curr_ptr);
        const out_ptr = llvm.LLVMBuildAlloca(self.builder, ptr_type, "out");
        _ = llvm.LLVMBuildStore(self.builder, buf, out_ptr);
        _ = llvm.LLVMBuildBr(self.builder, copy_head);

        // Pass 2: copy segments interleaved with the replacement
        llvm.LLVMPositionBuilderAtEnd(self.builder, copy_head);
        const curr2 = llvm.LLVMBuildLoad2(self.builder, ptr_type, curr_ptr, "curr2");
        var strstr_args2 = [_]llvm.LLVMValueRef{ curr2, old };
        const match2 = llvm.LLVMBuildCall2(self.builder, strstr_type, strstr_fn, &strstr_args2, 2, "match2");
        const found2 = llvm.LLVMBuildICmp(self.builder, llvm.LLVMIntNE, match2, llvm.LLVMConstNull(ptr_type), "found2");
        _ = llvm.LLVMBuildCondBr(self.builder, found2, copy_body, tail_bb);

        llvm.LLVMPositionBuilderAtEnd(self.builder, copy_body);
        const out1 = llvm.LLVMBuildLoad2(self.builder, ptr_type, out_ptr, "out1");
        const seg_len = llvm.LLVMBuildSub(self.builder, llvm.LLVMBuildPtrToInt(self.builder, match2, i64_type, "m2i"), llvm.LLVMBuildPtrToInt(self.builder, curr2, i64_type, "c2i"), "seg_len");
        var cp1_args = [_]llvm.LLVMValueRef{ out1, curr2, seg_len };
        _ = llvm.LLVMBuildCall2(self.builder, memcpy_type, memcpy_fn, &cp1_args, 3, "cp_seg");
        const out1_int = llvm.LLVMBuildPtrToInt(self.builder, out1, i64_type, "out1_int");
        const out2 = llvm.LLVMBuildIntToPtr(self.builder, llvm.LLVMBuildAdd(self.builder, out1_int, seg_len, "out2_int"), ptr_type, "out2");
        var cp2_args = [_]llvm.LLVMValueRef{ out2, new_str, nlen };
        _ = llvm.LLVMBuildCall2(self.builder, memcpy_type, memcpy_fn, &cp2_args, 3, "cp_new");
        const out2_int = llvm.LLVMBuildPtrToInt(self.builder, out2, i64_type, "out2_int2");
        _ = llvm.LLVMBuildStore(self.builder, llvm.LLVMBuildIntToPtr(self.builder, llvm.LLVMBuildAdd(self.builder, out2_int, nlen, "out3_int"), ptr_type, "out3"), out_ptr);
        const m2_int = llvm.LLVMBuildPtrToInt(self.builder, match2, i64_type, "m2_int");
        _ = llvm.LLVMBuildStore(self.builder, llvm.LLVMBuildIntToPtr(self.builder, llvm.LLVMBuildAdd(self.builder, m2_int, olen, "next2_int"), ptr_type, "next2"), curr_ptr);
        _ = llvm.LLVMBuildBr(self.builder, copy_head);

        // Copy the tail (including NUL terminator) and return
        llvm.LLVMPositionBuilderAtEnd(self.builder, tail_bb);
        const curr3 = llvm.LLVMBuildLoad2(self.builder, ptr_type, curr_ptr, "curr3");
        const out4 = llvm.LLVMBuildLoad2(self.builder, ptr_type, out_ptr, "out4");
        var tail_len_args = [_]llvm.LLVMValueRef{curr3};
        const tail_len = llvm.LLVMBuildCall2(self.builder, strlen_type, strlen_fn, &tail_len_args, 1, "tail_len");
        const tail_len_nul = llvm.LLVMBuildAdd(self.builder, tail_len, llvm.LLVMConstInt(i64_type, 1, 0), "tail_len_nul");
        var cp3_args = [_]llvm.LLVMValueRef{ out4, curr3, tail_len_nul };
        _ = llvm.LLVMBuildCall2(self.builder, memcpy_type, memcpy_fn, &cp3_args, 3, "cp_tail");
        _ = llvm.LLVMBuildRet(self.builder, buf);
    }

    fn declareLib(self: *LLVMEmitter, mod: llvm.LLVMModuleRef, lib_node: *ast.ASTNode) !void {
        const lib = lib_node.data.lib_decl;
        var func_names = std.StringHashMap([]const u8).init(self.allocator);
        for (lib.functions) |func_node| {
            if (func_node.data == .fun_decl) {
                const f = func_node.data.fun_decl;
                // Lib functions map to their C symbol, optionally via @Alias("...").
                var c_name: []const u8 = f.name;
                for (f.annotations) |ann| {
                    if (std.mem.eql(u8, ann.name, "Alias") and ann.arguments.len > 0) {
                        c_name = ann.arguments[0];
                        break;
                    }
                }
                try func_names.put(f.name, c_name);
                // Declare under the resolved C name so FFI calls can find it.
                try self.declareFunctionNamed(mod, func_node, c_name);
            }
        }
        try self.libs.put(lib.name, func_names);
    }

    fn declareFunctionNamed(self: *LLVMEmitter, mod: llvm.LLVMModuleRef, func_node: *ast.ASTNode, c_name: []const u8) !void {
        if (func_node.data != .fun_decl) return;
        const f = func_node.data.fun_decl;
        if (f.generic_params.len > 0) return;

        var param_types = try self.allocator.alloc(llvm.LLVMTypeRef, f.params.len);
        defer self.allocator.free(param_types);

        var ret_type: llvm.LLVMTypeRef = llvm.LLVMInt64TypeInContext(self.context);

        if (func_node.resolved_type) |rt| {
            if (rt.* == .Function) {
                ret_type = types_mapping.getLLVMType(self.context, rt.Function.return_type.*);
                for (f.params, 0..) |_, i| {
                    if (i < rt.Function.params.len) {
                        param_types[i] = types_mapping.getLLVMType(self.context, rt.Function.params[i].*);
                    } else {
                        param_types[i] = llvm.LLVMInt64TypeInContext(self.context);
                    }
                }
            }
        } else if (f.type_ref) |tr| {
            // Lib functions carry their resolved types on the type_refs
            // (inferLibDecl resolves them, but leaves func_node.resolved_type unset).
            if (tr.resolved_type) |rrt| {
                ret_type = types_mapping.getLLVMType(self.context, rrt.*);
            }
            for (f.params, 0..) |p, i| {
                if (p.type_ref) |ptr| {
                    if (ptr.resolved_type) |prt| {
                        param_types[i] = types_mapping.getLLVMType(self.context, prt.*);
                        continue;
                    }
                }
                param_types[i] = llvm.LLVMPointerTypeInContext(self.context, 0);
            }
        } else {
            for (f.params, 0..) |_, i| {
                param_types[i] = llvm.LLVMInt64TypeInContext(self.context);
            }
        }

        const func_type = llvm.LLVMFunctionType(ret_type, if (param_types.len > 0) param_types.ptr else null, @intCast(param_types.len), 0);

        const name_z = try self.allocator.dupeZ(u8, c_name);
        defer self.allocator.free(name_z);

        const existed = llvm.LLVMGetNamedFunction(mod, name_z.ptr) != null;
        if (!existed) {
            const func_val = llvm.LLVMAddFunction(mod, name_z.ptr, func_type);
            try self.functions.put(c_name, func_val);
        }
    }

    fn declareType(self: *LLVMEmitter, mod: llvm.LLVMModuleRef, type_node: *ast.ASTNode) !void {
        const t = type_node.data.type_decl;
        const name = t.resolved_c_name orelse t.name;

        const struct_name_z = try self.allocator.dupeZ(u8, name);
        defer self.allocator.free(struct_name_z);

        const struct_type = llvm.LLVMStructCreateNamed(self.context, struct_name_z.ptr);

        var field_names = ArrayList([]const u8).init(self.allocator);
        var field_types = ArrayList(llvm.LLVMTypeRef).init(self.allocator);

        for (t.primary_constructor) |prop| {
            try field_names.append(prop.name);
            const f_llvm_type = if (prop.resolved_type) |rt| types_mapping.getLLVMType(self.context, rt.*) else llvm.LLVMInt64TypeInContext(self.context);
            try field_types.append(f_llvm_type);
        }

        llvm.LLVMStructSetBody(struct_type, if (field_types.items.len > 0) field_types.items.ptr else null, @intCast(field_types.items.len), 0);

        const field_names_owned = try field_names.toOwnedSlice();
        const field_types_owned = try field_types.toOwnedSlice();

        try self.structs.put(name, .{
            .struct_type = struct_type,
            .field_names = field_names_owned,
            .field_types = field_types_owned,
        });

        // Declare constructor function: name(params...) -> ptr
        const ptr_type = llvm.LLVMPointerTypeInContext(self.context, 0);
        const ctor_type = llvm.LLVMFunctionType(ptr_type, if (field_types_owned.len > 0) field_types_owned.ptr else null, @intCast(field_types_owned.len), 0);

        const ctor_val = llvm.LLVMAddFunction(mod, struct_name_z.ptr, ctor_type);
        try self.functions.put(name, ctor_val);

        // Emit constructor body
        const entry_block = llvm.LLVMAppendBasicBlockInContext(self.context, ctor_val, "entry");
        llvm.LLVMPositionBuilderAtEnd(self.builder, entry_block);

        // Call malloc or GC_malloc.
        // TODO(emitter): Preferring `malloc` over `GC_malloc` is a workaround:
        // the `eiwa` host binary does not link libgc, so JIT'd code calling
        // GC_malloc resolves to null/garbage and hangs. Using raw malloc means
        // JIT-allocated objects are never GC-collected (leaks) and the memory
        // model diverges from the C backend. Proper fix: link libgc into the
        // host (or provide a stub GC_malloc that forwards to malloc), then
        // revert to GC_malloc-first ordering. Also see the fixed 128-byte
        // allocation below — it should be the struct's actual byte size
        // (LLVMStoreSizeOfType), not a hardcoded upper bound.
        // LLVM-SPECIFIC (NOT inherited from C): the C transpiler's constructors
        // allocate via GC_MALLOC (see eiwa_runtime.h); no libgc in the host is
        // a JIT-only constraint, so the C backend has no such workaround.
        const gc_func = llvm.LLVMGetNamedFunction(mod, "malloc") orelse llvm.LLVMGetNamedFunction(mod, "GC_malloc").?;
        const gc_func_type = llvm.LLVMGlobalGetValueType(gc_func);
        const size_val = llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(self.context), 128, 0);
        var gc_args = [_]llvm.LLVMValueRef{size_val};
        const raw_ptr = llvm.LLVMBuildCall2(self.builder, gc_func_type, gc_func, &gc_args, 1, "raw_inst");

        // Store constructor parameters into struct fields
        for (field_names_owned, 0..) |_, idx| {
            const param_val = llvm.LLVMGetParam(ctor_val, @intCast(idx));
            const field_ptr = llvm.LLVMBuildStructGEP2(self.builder, struct_type, raw_ptr, @intCast(idx), "field_gep");
            _ = llvm.LLVMBuildStore(self.builder, param_val, field_ptr);
        }

        _ = llvm.LLVMBuildRet(self.builder, raw_ptr);

        // Pass 1a2: Emit member methods inside type
        for (t.methods) |m_node| {
            if (m_node.data == .fun_decl) {
                if (m_node.data.fun_decl.generic_params.len > 0) continue;
                try self.declareFunction(mod, m_node);
            }
        }
    }

    fn declareFunction(self: *LLVMEmitter, mod: llvm.LLVMModuleRef, func_node: *ast.ASTNode) !void {
        const f = func_node.data.fun_decl;
        if (f.generic_params.len > 0) return; // Skip generic functions (monomorphized on demand)
        const name = f.resolved_c_name orelse f.name;

        // Methods carry the receiver (`this`) as an implicit leading parameter.
        const receiver_type = if (func_node.resolved_type) |rt|
            (if (rt.* == .Function) rt.Function.receiver else null)
        else
            null;

        const param_count: usize = f.params.len + @intFromBool(receiver_type != null);
        var param_types = try self.allocator.alloc(llvm.LLVMTypeRef, param_count);
        defer self.allocator.free(param_types);

        var ret_type: llvm.LLVMTypeRef = llvm.LLVMInt64TypeInContext(self.context);

        if (func_node.resolved_type) |rt| {
            if (rt.* == .Function) {
                ret_type = types_mapping.getLLVMType(self.context, rt.Function.return_type.*);
                var param_idx: usize = 0;
                if (rt.Function.receiver) |rec| {
                    param_types[0] = types_mapping.getLLVMType(self.context, rec.*);
                    param_idx = 1;
                }
                for (f.params, 0..) |_, i| {
                    if (i < rt.Function.params.len) {
                        param_types[param_idx] = types_mapping.getLLVMType(self.context, rt.Function.params[i].*);
                    } else {
                        param_types[param_idx] = llvm.LLVMInt64TypeInContext(self.context);
                    }
                    param_idx += 1;
                }
            } else {
                ret_type = types_mapping.getLLVMType(self.context, rt.*);
                for (f.params, 0..) |_, i| {
                    param_types[i] = llvm.LLVMInt64TypeInContext(self.context);
                }
            }
        } else {
            for (f.params, 0..) |_, i| {
                param_types[i] = llvm.LLVMInt64TypeInContext(self.context);
            }
        }

        const func_type = llvm.LLVMFunctionType(ret_type, if (param_types.len > 0) param_types.ptr else null, @intCast(param_types.len), 0);

        const name_z = try self.allocator.dupeZ(u8, name);
        defer self.allocator.free(name_z);

        const existed = llvm.LLVMGetNamedFunction(mod, name_z.ptr) != null;
        if (!existed) {
            const func_val = llvm.LLVMAddFunction(mod, name_z.ptr, func_type);
            try self.functions.put(name, func_val);
        }
    }

    fn emitFunctionBody(self: *LLVMEmitter, mod: llvm.LLVMModuleRef, func_node: *ast.ASTNode) !void {
        const f = func_node.data.fun_decl;
        // Check if function is an external prototype without body
        if (f.body.data == .block and f.body.data.block.statements.len == 0) return;

        const name = f.resolved_c_name orelse f.name;
        const func_val = self.functions.get(name) orelse return error.FunctionNotFound;

        const entry_block = llvm.LLVMAppendBasicBlockInContext(self.context, func_val, "entry");
        llvm.LLVMPositionBuilderAtEnd(self.builder, entry_block);

        var scope = std.StringHashMap(llvm.LLVMValueRef).init(self.allocator);
        defer scope.deinit();

        // Methods bind the receiver (`this`) as the leading parameter.
        var param_base: usize = 0;
        if (func_node.resolved_type) |rt| {
            if (rt.* == .Function) {
                if (rt.Function.receiver != null) {
                    const this_val = llvm.LLVMGetParam(func_val, 0);
                    const this_type = llvm.LLVMTypeOf(this_val);
                    const this_z = try self.allocator.dupeZ(u8, "this");
                    defer self.allocator.free(this_z);
                    const this_ptr = llvm.LLVMBuildAlloca(self.builder, this_type, this_z.ptr);
                    _ = llvm.LLVMBuildStore(self.builder, this_val, this_ptr);
                    try scope.put("this", this_ptr);
                    param_base = 1;
                }
            }
        }

        // Allocate and store parameters in local scope
        for (f.params, 0..) |p, i| {
            const param_val = llvm.LLVMGetParam(func_val, @intCast(i + param_base));
            const param_type = llvm.LLVMTypeOf(param_val);

            const p_name_z = try self.allocator.dupeZ(u8, p.name);
            defer self.allocator.free(p_name_z);

            const alloca_ptr = llvm.LLVMBuildAlloca(self.builder, param_type, p_name_z.ptr);
            _ = llvm.LLVMBuildStore(self.builder, param_val, alloca_ptr);
            try scope.put(p.name, alloca_ptr);
        }

        // Expression-bodied functions (`fun f(...) = expr`) return the value directly.
        if (f.is_expr_body) {
            const ret_val = try expression.emitExpression(self.context, mod, self.builder, &scope, &self.structs, &self.libs, f.body);
            _ = llvm.LLVMBuildRet(self.builder, ret_val);
            return;
        }

        try statement.emitStatement(self.context, mod, self.builder, func_val, &scope, &self.structs, &self.libs, f.body);

        const cur_bb = llvm.LLVMGetInsertBlock(self.builder);
        if (llvm.LLVMGetBasicBlockTerminator(cur_bb) == null) {
            const func_type = llvm.LLVMGlobalGetValueType(func_val);
            const ret_type = llvm.LLVMGetReturnType(func_type);
            const kind = llvm.LLVMGetTypeKind(ret_type);

            if (kind == llvm.LLVMVoidTypeKind) {
                _ = llvm.LLVMBuildRetVoid(self.builder);
            } else if (kind == llvm.LLVMIntegerTypeKind) {
                const zero = llvm.LLVMConstInt(ret_type, 0, 0);
                _ = llvm.LLVMBuildRet(self.builder, zero);
            } else if (kind == llvm.LLVMDoubleTypeKind) {
                const zero = llvm.LLVMConstReal(ret_type, 0.0);
                _ = llvm.LLVMBuildRet(self.builder, zero);
            } else if (kind == llvm.LLVMPointerTypeKind) {
                const null_ptr = llvm.LLVMConstNull(ret_type);
                _ = llvm.LLVMBuildRet(self.builder, null_ptr);
            } else {
                _ = llvm.LLVMBuildRetVoid(self.builder);
            }
        }
    }

    /// Runs LLVM PassBuilder optimization passes (mem2reg for dev, default<O3> for release).
    pub fn optimizeModule(self: *LLVMEmitter, target_machine: llvm.LLVMTargetMachineRef) !void {
        const mod = self.module orelse return error.ModuleAlreadyDisposed;
        const pass_pipeline = if (self.is_release) "default<O3>" else "mem2reg";
        const pass_z = try self.allocator.dupeZ(u8, pass_pipeline);
        defer self.allocator.free(pass_z);

        const options = llvm.LLVMCreatePassBuilderOptions();
        defer llvm.LLVMDisposePassBuilderOptions(options);

        const err = llvm.LLVMRunPasses(mod, pass_z.ptr, target_machine, options);
        if (err != null) {
            const err_str = llvm.LLVMGetErrorMessage(err);
            if (err_str != null) {
                std.debug.print("LLVM Pass Warning: {s}\n", .{err_str});
                llvm.LLVMDisposeErrorMessage(err_str);
            }
        }
    }

    /// Direct native binary emission using LLVMTargetMachineEmitToFile.
    pub fn emitNativeBinary(self: *LLVMEmitter, output_filename: []const u8, io: std.Io) !void {
        const mod = self.module orelse return error.ModuleAlreadyDisposed;

        const triple = llvm.LLVMGetDefaultTargetTriple();
        defer llvm.LLVMDisposeMessage(triple);

        var target: llvm.LLVMTargetRef = undefined;
        var err_msg: [*c]u8 = null;
        if (llvm.LLVMGetTargetFromTriple(triple, &target, &err_msg) != 0) {
            if (err_msg != null) {
                std.debug.print("LLVM Target Error: {s}\n", .{err_msg});
                llvm.LLVMDisposeMessage(err_msg);
            }
            return error.LLVMTargetError;
        }

        const cpu = llvm.LLVMGetHostCPUName();
        defer llvm.LLVMDisposeMessage(cpu);

        const features = llvm.LLVMGetHostCPUFeatures();
        defer llvm.LLVMDisposeMessage(features);

        const opt_level: llvm.LLVMCodeGenOptLevel = if (self.is_release) llvm.LLVMCodeGenLevelAggressive else llvm.LLVMCodeGenLevelNone;

        const target_machine = llvm.LLVMCreateTargetMachine(
            target,
            triple,
            cpu,
            features,
            opt_level,
            llvm.LLVMRelocPIC,
            llvm.LLVMCodeModelDefault,
        ) orelse return error.LLVMTargetMachineFailed;
        defer llvm.LLVMDisposeTargetMachine(target_machine);

        // Run passes
        try self.optimizeModule(target_machine);

        // Emit object file directly from RAM to temp object
        const obj_filename = "temp_llvm.o";
        const obj_z = try self.allocator.dupeZ(u8, obj_filename);
        defer self.allocator.free(obj_z);

        if (llvm.LLVMTargetMachineEmitToFile(target_machine, mod, obj_z.ptr, llvm.LLVMObjectFile, &err_msg) != 0) {
            if (err_msg != null) {
                std.debug.print("LLVM Emit Object Error: {s}\n", .{err_msg});
                llvm.LLVMDisposeMessage(err_msg);
            }
            return error.LLVMEmitObjectFailed;
        }
        defer std.Io.Dir.cwd().deleteFile(io, obj_filename) catch {};

        // Link object file into native binary via zig cc
        const actual_zig = "zig";
        var cc_argv = ArrayList([]const u8).init(self.allocator);
        defer cc_argv.deinit();

        const opt_flag = if (self.is_release) "-O3" else "-O0";
        try cc_argv.appendSlice(&[_][]const u8{ actual_zig, "cc", opt_flag, "-fwrapv" });
        if (builtin.target.os.tag == .macos) {
            try cc_argv.appendSlice(&[_][]const u8{ "-I", "/opt/homebrew/include", "-L", "/opt/homebrew/lib" });
        }
        try cc_argv.appendSlice(&[_][]const u8{
            obj_filename,
            "-o",
            output_filename,
            "-lgc",
        });

        var child = try std.process.spawn(io, .{
            .argv = cc_argv.items,
        });

        const term = try child.wait(io);
        if (term != .exited or term.exited != 0) {
            std.debug.print("Linking LLVM object failed.\n", .{});
            return error.LinkingFailed;
        }
    }

    const c_bindings_dump_enabled = false;

    /// Removes any partially-emitted basic blocks from a function whose body
    /// failed to emit, leaving a clean external declaration. Without this the
    /// module keeps half-built IR (unterminated blocks) and the JIT hangs or
    /// the verifier fails.
    fn discardPartialBody(self: *LLVMEmitter, mod: llvm.LLVMModuleRef, fname: []const u8) void {
        const func_val = self.functions.get(fname) orelse blk: {
            const fname_z = self.allocator.dupeZ(u8, fname) catch return;
            defer self.allocator.free(fname_z);
            break :blk llvm.LLVMGetNamedFunction(mod, fname_z.ptr) orelse return;
        };
        while (llvm.LLVMGetFirstBasicBlock(func_val)) |bb| {
            llvm.LLVMDeleteBasicBlock(bb);
        }
    }

    /// Replaces a function whose body could not be emitted with a stub that
    /// returns the type's default value. Skipping-without-a-body leaves an
    /// undefined symbol that breaks JIT linking and `emitNativeBinary`
    /// (undefined symbol error) even when the function is never called.
    fn emitFunctionStub(self: *LLVMEmitter, mod: llvm.LLVMModuleRef, fname: []const u8) !void {
        const func_val = self.functions.get(fname) orelse blk: {
            const fname_z = try self.allocator.dupeZ(u8, fname);
            defer self.allocator.free(fname_z);
            break :blk llvm.LLVMGetNamedFunction(mod, fname_z.ptr) orelse return error.FunctionNotFound;
        };
        self.discardPartialBody(mod, fname);
        const entry_block = llvm.LLVMAppendBasicBlockInContext(self.context, func_val, "stub");
        llvm.LLVMPositionBuilderAtEnd(self.builder, entry_block);
        const func_type = llvm.LLVMGlobalGetValueType(func_val);
        const ret_type = llvm.LLVMGetReturnType(func_type);
        const kind = llvm.LLVMGetTypeKind(ret_type);
        if (kind == llvm.LLVMVoidTypeKind) {
            _ = llvm.LLVMBuildRetVoid(self.builder);
        } else if (kind == llvm.LLVMIntegerTypeKind) {
            _ = llvm.LLVMBuildRet(self.builder, llvm.LLVMConstInt(ret_type, 0, 0));
        } else if (kind == llvm.LLVMDoubleTypeKind) {
            _ = llvm.LLVMBuildRet(self.builder, llvm.LLVMConstReal(ret_type, 0.0));
        } else if (kind == llvm.LLVMPointerTypeKind) {
            _ = llvm.LLVMBuildRet(self.builder, llvm.LLVMConstNull(ret_type));
        } else {
            _ = llvm.LLVMBuildRetVoid(self.builder);
        }
    }

    /// Executes the in-memory LLVM module via JIT (for `eiwa run --backend=llvm`).
    pub fn executeJIT(self: *LLVMEmitter) !i32 {
        const mod = self.module orelse return error.ModuleAlreadyDisposed;
        if (c_bindings_dump_enabled) llvm.LLVMDumpModule(mod);
        {
            var verify_err: [*c]u8 = null;
            if (llvm.LLVMVerifyModule(mod, llvm.LLVMPrintMessageAction, &verify_err) != 0) {
                if (verify_err != null) {
                    std.debug.print("LLVM Verify Error: {s}\n", .{verify_err});
                    llvm.LLVMDisposeMessage(verify_err);
                }
            }
        }
        var engine: llvm.LLVMExecutionEngineRef = undefined;
        var err_msg: [*c]u8 = null;

        if (llvm.LLVMCreateExecutionEngineForModule(&engine, mod, &err_msg) != 0) {
            if (err_msg != null) {
                std.debug.print("LLVM JIT Error: {s}\n", .{err_msg});
                llvm.LLVMDisposeMessage(err_msg);
            }
            return error.LLVMJITFailed;
        }
        // Ownership of mod transferred to engine!
        self.module = null;
        defer llvm.LLVMDisposeExecutionEngine(engine);

        const main_func = llvm.LLVMGetNamedFunction(mod, "main") orelse return error.MainNotFound;
        const main_fn_ptr = llvm.LLVMGetPointerToGlobal(engine, main_func);
        const main_type = llvm.LLVMGlobalGetValueType(main_func);
        if (llvm.LLVMGetTypeKind(llvm.LLVMGetReturnType(main_type)) == llvm.LLVMVoidTypeKind) {
            const main_fn: *const fn () callconv(.c) void = @ptrCast(@alignCast(main_fn_ptr));
            main_fn();
            return 0;
        }
        const main_fn: *const fn () callconv(.c) i32 = @ptrCast(@alignCast(main_fn_ptr));
        return main_fn();
    }
};

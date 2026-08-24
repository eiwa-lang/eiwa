const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const eiwa_home = @import("../../core/eiwa_home.zig");
const ast = @import("../../core/ast.zig");
const ts = @import("../../core/type_system.zig");
const tc_core = @import("../../core/type_checker/core.zig");
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

/// Resolves a repo-relative `src/...` path against the eiwa source tree
/// (mirrors the C transpiler). Non-`src/` paths are returned unchanged.
fn resolveRepoPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, path, "src/")) return path;
    const src_dir = eiwa_home.resolve(allocator);
    const repo_root = std.fs.path.dirname(src_dir) orelse return path;
    return try std.fs.path.join(allocator, &.{ repo_root, path });
}

/// In-Memory LLVM IR Emitter and Execution Driver.
/// When true, the LLVM emitter prints diagnostic logs (per-function emit
/// errors, PropertyNotFound debugging, stub fallbacks). Defaults to false so
/// normal builds stay quiet; enable with `EIWA_LLVM_VERBOSE=1`.
pub var verbose: bool = false;

/// True when the host `eiwac` binary itself links libgc (build option set by
/// build.zig's findLibgcPath). Only then can JIT'd code resolve GC_* symbols
/// from the host process (Bloco B).
pub const has_gc = build_options.has_gc;

/// When true, emitted code allocates via GC_malloc/GC_realloc (zeroed,
/// GC-managed memory, parity with the C backend) instead of raw malloc/realloc
/// (never collected, never zeroed). Set by main.zig before emitModule:
/// always for native builds (the binary links -lgc), and for the JIT only
/// when the host links libgc (`has_gc`). When false the emitter keeps the
/// historical malloc-first ordering and everything behaves as before.
pub var prefer_gc_alloc: bool = false;

/// libgc bindings into the host process. Only referenced when `has_gc` is
/// true (Zig lazily compiles externs, so hosts without libgc never link these).
const gc = struct {
    pub extern "c" fn GC_init() void;
    /// Registers [low, high_plus_1) as a root segment scanned by the collector.
    pub extern "c" fn GC_add_roots(low: *anyopaque, high_plus_1: *anyopaque) void;
};

/// Returns the heap allocation function emitted code should call:
/// GC_malloc-first when `prefer_gc_alloc`, malloc-first otherwise. Both
/// prototypes are always declared in emitModule's pass 0, so the lookup
/// never fails.
pub fn getHeapAllocFn(mod: llvm.LLVMModuleRef) llvm.LLVMValueRef {
    const primary: [*:0]const u8 = if (prefer_gc_alloc) "GC_malloc" else "malloc";
    const fallback: [*:0]const u8 = if (prefer_gc_alloc) "malloc" else "GC_malloc";
    return llvm.LLVMGetNamedFunction(mod, primary) orelse llvm.LLVMGetNamedFunction(mod, fallback).?;
}

/// Same ordering policy as getHeapAllocFn, for buffer growth:
/// GC_realloc-first when `prefer_gc_alloc` (GC_realloc is a real exported
/// libgc function, unlike the GC_REALLOC macro), realloc-first otherwise.
pub fn getHeapReallocFn(mod: llvm.LLVMModuleRef) llvm.LLVMValueRef {
    const ptr_type = llvm.LLVMPointerTypeInContext(llvm.LLVMGetModuleContext(mod), 0);
    const size_t_type = llvm.LLVMInt64TypeInContext(llvm.LLVMGetModuleContext(mod));
    const primary: [*:0]const u8 = if (prefer_gc_alloc) "GC_realloc" else "realloc";
    const fallback: [*:0]const u8 = if (prefer_gc_alloc) "realloc" else "GC_realloc";
    return llvm.LLVMGetNamedFunction(mod, primary) orelse
        (llvm.LLVMGetNamedFunction(mod, fallback) orelse blk: {
            var ps = [_]llvm.LLVMTypeRef{ ptr_type, size_t_type };
            const ft = llvm.LLVMFunctionType(ptr_type, &ps, 2, 0);
            break :blk llvm.LLVMAddFunction(mod, fallback, ft);
        });
}

pub const LLVMEmitter = struct {
    allocator: std.mem.Allocator,
    context: llvm.LLVMContextRef,
    module: ?llvm.LLVMModuleRef,
    builder: llvm.LLVMBuilderRef,
    is_release: bool,
    is_test_mode: bool = false,
    source_file: []const u8 = "",
    /// Program arguments forwarded to the JIT entry (run mode), mirroring the
    /// C backend's child argv.
    program_argv: []const []const u8 = &.{},
    /// The host process's real argv (argv[0] = program name), set by main.zig.
    /// The entry shim stores these into eiwa_argc/eiwa_argv for Process.args().
    host_argv: []const []const u8 = &.{},
    functions: std.StringHashMap(llvm.LLVMValueRef),
    structs: std.StringHashMap(StructInfo),
    /// Maps lib-block names (e.g. "Console") to their set of functions.
    libs: std.StringHashMap(std.StringHashMap([]const u8)),
    contracts_ast: ?*std.StringHashMap(*ast.ASTNode) = null,
    /// Build requirements declared by `lib` annotations (@Source/@Include/@Define/@Link),
    /// mirroring the C transpiler (Phase 65 — LLVM backend compiles the C sources too).
    c_sources: std.StringHashMap(void),
    c_includes: std.StringHashMap(void),
    c_defines: std.StringHashMap(void),
    link_libraries: std.StringHashMap(void),
    /// Extra C flags forwarded from the CLI (`-I`, `-L`, `-l`, `-D`) so lib
    /// compilation in the JIT can reach non-default library locations (e.g.
    /// Homebrew keg-only libpq needs `-L/opt/homebrew/opt/libpq/lib`).
    cli_c_flags: []const []const u8 = &.{},
    /// Module registry (set by main.zig) — used to resolve `@Source`/`@Include`
    /// relative paths against the DECLARING module's file (not the entry file).
    registry: ?*tc_core.ModuleRegistry = null,

    pub fn init(allocator: std.mem.Allocator, module_name: []const u8, is_release: bool) !LLVMEmitter {
        _ = llvm.LLVMInitializeNativeTarget();
        _ = llvm.LLVMInitializeNativeAsmPrinter();
        _ = llvm.LLVMInitializeNativeAsmParser();

        const verbose_z = "EIWA_LLVM_VERBOSE";
        if (std.c.getenv(verbose_z)) |v| verbose = std.mem.eql(u8, std.mem.span(v), "1");

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
            .source_file = module_name,
            .functions = std.StringHashMap(llvm.LLVMValueRef).init(allocator),
            .structs = std.StringHashMap(StructInfo).init(allocator),
            .libs = std.StringHashMap(std.StringHashMap([]const u8)).init(allocator),
            .c_sources = std.StringHashMap(void).init(allocator),
            .c_includes = std.StringHashMap(void).init(allocator),
            .c_defines = std.StringHashMap(void).init(allocator),
            .link_libraries = std.StringHashMap(void).init(allocator),
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
        self.c_sources.deinit();
        self.c_includes.deinit();
        self.c_defines.deinit();
        self.link_libraries.deinit();
        llvm.LLVMDisposeBuilder(self.builder);
        if (self.module) |m| {
            llvm.LLVMDisposeModule(m);
            self.module = null;
            llvm.LLVMContextDispose(self.context);
        }
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
        {
            var realloc_params = [_]llvm.LLVMTypeRef{ ptr_type, size_t_type };
            const realloc_type = llvm.LLVMFunctionType(ptr_type, &realloc_params, 2, 0);
            _ = llvm.LLVMAddFunction(mod, "GC_realloc", realloc_type);
            _ = llvm.LLVMAddFunction(mod, "realloc", realloc_type);
        }

        // `GC_MALLOC` (all-caps) is referenced by FFI `@Alias("GC_MALLOC")` code
        // (e.g. std.random's NativeMemory.allocate / randomBytes). MCJIT cannot
        // resolve it from the host binary, and the stub pass would otherwise
        // replace it with `ret null`, crashing any program that allocates via
        // the FFI. Give it a real body that forwards to the active heap
        // allocator (GC_malloc when prefer_gc_alloc, malloc otherwise — the
        // same ordering used everywhere else in the emitter).
        {
            const gc_malloc_ffi = llvm.LLVMAddFunction(mod, "GC_MALLOC", gc_type);
            const entry_bb = llvm.LLVMAppendBasicBlockInContext(self.context, gc_malloc_ffi, "entry");
            llvm.LLVMPositionBuilderAtEnd(self.builder, entry_bb);
            const n_param = llvm.LLVMGetParam(gc_malloc_ffi, 0);
            const alloc_fn = getHeapAllocFn(mod);
            const alloc_type = llvm.LLVMGlobalGetValueType(alloc_fn);
            var margs = [_]llvm.LLVMValueRef{n_param};
            const alloc = llvm.LLVMBuildCall2(self.builder, alloc_type, alloc_fn, &margs, 1, "gc_alloc");
            _ = llvm.LLVMBuildRet(self.builder, alloc);
        }

        // Same for `GC_REALLOC` (FFI @Alias("GC_REALLOC"), e.g. Standard.gcRealloc):
        // a macro in gc.h, so MCJIT can't resolve it. Forward to the active
        // heap reallocator (GC_realloc when prefer_gc_alloc, libc realloc
        // otherwise — both accept NULL and behave like the alloc variant).
        {
            var r_params = [_]llvm.LLVMTypeRef{ ptr_type, size_t_type };
            const r_type = llvm.LLVMFunctionType(ptr_type, &r_params, 2, 0);
            const gc_realloc_ffi = llvm.LLVMAddFunction(mod, "GC_REALLOC", r_type);
            const entry_bb = llvm.LLVMAppendBasicBlockInContext(self.context, gc_realloc_ffi, "entry");
            llvm.LLVMPositionBuilderAtEnd(self.builder, entry_bb);
            const old_p = llvm.LLVMGetParam(gc_realloc_ffi, 0);
            const new_s = llvm.LLVMGetParam(gc_realloc_ffi, 1);
            const realloc_fn = getHeapReallocFn(mod);
            const realloc_type = llvm.LLVMGlobalGetValueType(realloc_fn);
            var rargs = [_]llvm.LLVMValueRef{ old_p, new_s };
            const ralloc = llvm.LLVMBuildCall2(self.builder, realloc_type, realloc_fn, &rargs, 2, "gc_realloc");
            _ = llvm.LLVMBuildRet(self.builder, ralloc);
        }

        // Declare printf and sprintf prototypes
        const i32_type = llvm.LLVMInt32TypeInContext(self.context);
        var printf_params = [_]llvm.LLVMTypeRef{ptr_type};
        const printf_type = llvm.LLVMFunctionType(i32_type, &printf_params, 1, 1); // varargs = 1
        _ = llvm.LLVMAddFunction(mod, "printf", printf_type);

        var puts_params = [_]llvm.LLVMTypeRef{ptr_type};
        const puts_type = llvm.LLVMFunctionType(i32_type, &puts_params, 1, 0);
        _ = llvm.LLVMAddFunction(mod, "puts", puts_type);

        var sprintf_params = [_]llvm.LLVMTypeRef{ ptr_type, ptr_type };
        const sprintf_type = llvm.LLVMFunctionType(i32_type, &sprintf_params, 2, 1); // varargs = 1
        _ = llvm.LLVMAddFunction(mod, "sprintf", sprintf_type);

        // Exception-handling runtime (setjmp/longjmp model, mirrors eiwa_runtime.h)
        const void_type = llvm.LLVMVoidTypeInContext(self.context);
        const void_fn_type = llvm.LLVMFunctionType(void_type, null, 0, 0);
        _ = llvm.LLVMAddFunction(mod, "GC_init", void_fn_type);

        // Bloco B: native binaries (eiwac build) allocate via GC_malloc when
        // prefer_gc_alloc, so the Boehm GC must be initialized before main.
        // Emit a global constructor that calls GC_init — covers every entry
        // shape (plain main, eiwa_test_main) without touching each one. The
        // JIT path does NOT rely on this (MCJIT never runs global ctors);
        // executeJIT calls GC_init from the host side.
        if (prefer_gc_alloc) {
            const ctor_fn = llvm.LLVMAddFunction(mod, "__eiwa_gc_init_ctor", void_fn_type);
            const ctor_bb = llvm.LLVMAppendBasicBlockInContext(self.context, ctor_fn, "entry");
            llvm.LLVMPositionBuilderAtEnd(self.builder, ctor_bb);
            const gc_init_fn = llvm.LLVMGetNamedFunction(mod, "GC_init").?;
            _ = llvm.LLVMBuildCall2(self.builder, void_fn_type, gc_init_fn, null, 0, "");
            _ = llvm.LLVMBuildRetVoid(self.builder);

            var ctor_entry_fields = [_]llvm.LLVMTypeRef{ i32_type, ptr_type, ptr_type };
            const ctor_entry_type = llvm.LLVMStructTypeInContext(self.context, &ctor_entry_fields, 3, 0);
            var ctor_entry_vals = [_]llvm.LLVMValueRef{
                llvm.LLVMConstInt(i32_type, 65535, 0),
                ctor_fn,
                llvm.LLVMConstNull(ptr_type),
            };
            const ctor_entry = llvm.LLVMConstStructInContext(self.context, &ctor_entry_vals, 3, 0);
            var ctor_arr_vals = [_]llvm.LLVMValueRef{ctor_entry};
            const ctor_arr = llvm.LLVMConstArray(ctor_entry_type, &ctor_arr_vals, 1);
            const ctors_global = llvm.LLVMAddGlobal(mod, llvm.LLVMTypeOf(ctor_arr), "llvm.global_ctors");
            llvm.LLVMSetLinkage(ctors_global, llvm.LLVMAppendingLinkage);
            llvm.LLVMSetInitializer(ctors_global, ctor_arr);
        }

        var setjmp_params = [_]llvm.LLVMTypeRef{ptr_type};
        const setjmp_type = llvm.LLVMFunctionType(i32_type, &setjmp_params, 1, 0);
        _ = llvm.LLVMAddFunction(mod, "_setjmp", setjmp_type);

        var longjmp_params = [_]llvm.LLVMTypeRef{ ptr_type, i32_type };
        const longjmp_type = llvm.LLVMFunctionType(void_type, &longjmp_params, 2, 0);
        _ = llvm.LLVMAddFunction(mod, "_longjmp", longjmp_type);

        var exit_params = [_]llvm.LLVMTypeRef{i32_type};
        const exit_type = llvm.LLVMFunctionType(void_type, &exit_params, 1, 0);
        _ = llvm.LLVMAddFunction(mod, "exit", exit_type);

        var fflush_params = [_]llvm.LLVMTypeRef{ptr_type};
        const fflush_type = llvm.LLVMFunctionType(i32_type, &fflush_params, 1, 0);
        _ = llvm.LLVMAddFunction(mod, "fflush", fflush_type);

        var time_params = [_]llvm.LLVMTypeRef{ptr_type};
        const time_type = llvm.LLVMFunctionType(size_t_type, &time_params, 1, 0);
        _ = llvm.LLVMAddFunction(mod, "time", time_type);

        // Exception stack + active exception globals.
        const exc_stack_global = llvm.LLVMAddGlobal(mod, ptr_type, "eiwa_exception_stack");
        llvm.LLVMSetInitializer(exc_stack_global, llvm.LLVMConstNull(ptr_type));
        const fat_type = types_mapping.getFatPointerType(self.context);
        const active_exc_global = llvm.LLVMAddGlobal(mod, fat_type, "eiwa_active_exception");
        llvm.LLVMSetInitializer(active_exc_global, llvm.LLVMConstNull(fat_type));

        // struct EiwaExceptionFrame { jmp_buf buf; EiwaExceptionFrame* next; }
        // jmp_buf is modeled as a 512-byte buffer ([64 x i64]) to be safe across platforms.
        // TODO(emitter): Modeling jmp_buf as a fixed [64 x i64] works on the
        // platforms LLVM 21 targets here but is fragile: the real jmp_buf size
        // is platform/arch-specific, and setjmp/longjmp are used via raw symbol
        // linkage without knowing the actual target layout. Proper fix: emit the
        // frame with the real `jmp_buf` size for the target (or follow the C
        // transpiler, which included eiwa_runtime.h and let the C compiler
        // size it), instead of hardcoding 512 bytes.
        // INHERITED GAMBIARRA: the EiwaExceptionFrame + setjmp/longjmp model came
        // from the C backend — see the PRE-EXISTING try_stmt comment and the
        // frame struct in the original C runtime. The C version
        // declared the frame as real C types (`jmp_buf`); this LLVM copy
        // hardcodes the buffer size because it has no C header to include.
        const frame_struct = llvm.LLVMStructCreateNamed(self.context, "EiwaExceptionFrame");
        const buf_type = llvm.LLVMArrayType(llvm.LLVMInt64TypeInContext(self.context), 64);
        var frame_fields = [_]llvm.LLVMTypeRef{ buf_type, ptr_type };
        llvm.LLVMStructSetBody(frame_struct, &frame_fields, 2, 0);


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

        try self.emitStdlibIntrinsics(mod);

        // eiwa_to_string(i64) -> i8* — mirrors the eiwa_runtime.h heuristic:
        //   val == 0 -> "null"; val == 1 -> "true"; val < 0x10000 -> int via sprintf; else it's a String (char*) as-is.
        try self.emitToStringHelper(mod);
        try self.emitHashStringHelper(mod);
        try self.emitStrReplaceHelper(mod);
        try self.emitStringEqualsHelper(mod);
        try self.emitCharAtHelper(mod);
        try self.emitWriteByteHelper(mod);
        try self.emitRandomBytesHelper(mod);
        try self.emitNowMillisHelper(mod);

        expression.global_contracts_ast_ptr = self.contracts_ast;

        // Collect the entry module and every module it (transitively) imports.
        var modules = ArrayList(*ast.ASTNode).init(self.allocator);
        defer modules.deinit();
        var visited = std.AutoHashMap(*ast.ASTNode, void).init(self.allocator);
        defer visited.deinit();
        try self.collectModules(ast_root, &modules, &visited);

        // Pass 1a: Declare all user-defined types (structs & constructors) & enums
        for (modules.items) |m| {
            if (m.data != .program) continue;
            for (m.data.program.statements) |stmt| {
                if (stmt.data == .type_decl) {
                    try self.declareType(mod, stmt);
                } else if (stmt.data == .enum_decl) {
                    try self.declareEnum(mod, stmt);
                }
            }
        }

        // Pass 1b: Declare all lib blocks (external FFI prototypes)
        for (modules.items) |m| {
            if (m.data != .program) continue;
            // Real filesystem path of this module, so relative @Source/@Include
            // resolve against the DECLARING file (not the entry file).
            var module_path: ?[]const u8 = null;
            if (self.registry) |reg| {
                var it = reg.modules.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.ast_root == m) {
                        module_path = entry.value_ptr.filename;
                        break;
                    }
                }
            }
            for (m.data.program.statements) |stmt| {
                if (stmt.data == .lib_decl) {
                    try self.declareLib(mod, stmt, module_path);
                }
            }
        }

        // Pass 1c: Declare all function signatures (top-level + type methods + object members)
        for (modules.items) |m| {
            if (m.data != .program) continue;
            for (m.data.program.statements) |stmt| {
                if (stmt.data == .fun_decl) {
                    // In test mode the entry point is `eiwa_test_main`, not a
                    // user `fun main()`. Declaring a `main` from an imported
                    // module (e.g. the CLI binary imported by cli/test) would
                    // collide with the test-runner entry symbol.
                    if (self.is_test_mode and std.mem.eql(u8, stmt.data.fun_decl.resolved_c_name orelse stmt.data.fun_decl.name, "main")) continue;
                    try self.declareFunction(mod, stmt, false);
                } else if (stmt.data == .object_decl) {
                    for (stmt.data.object_decl.members) |member| {
                        if (member.data != .fun_decl) continue;
                        try self.declareFunction(mod, member, true);
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
                const obj_c_name = obj.resolved_c_name orelse (obj.name orelse "Object");
                for (obj.members) |member| {
                    if (member.data != .var_decl) continue;
                    const v = member.data.var_decl;
                    const var_name = if (v.resolved_c_name) |rcn| rcn else try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ obj_c_name, v.name });
                    defer if (v.resolved_c_name == null) self.allocator.free(var_name);
                    const llvm_type = if (member.resolved_type) |rt|
                        types_mapping.getLLVMType(self.context, rt.*)
                    else
                        llvm.LLVMInt64TypeInContext(self.context);
                    const var_name_z = try self.allocator.dupeZ(u8, var_name);
                    defer self.allocator.free(var_name_z);
                    if (llvm.LLVMGetNamedGlobal(mod, var_name_z.ptr) == null) {
                        const global = llvm.LLVMAddGlobal(mod, llvm_type, var_name_z.ptr);
                        llvm.LLVMSetInitializer(global, llvm.LLVMConstNull(llvm_type));
                    }
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
            // In test mode ast_root is a synthetic wrapper that only holds
            // import_stmt's; the actual `test "..." { }` bodies live in the
            // imported modules. Seed their callees so the functions tests call
            // are considered reachable and get real bodies emitted.
            if (self.is_test_mode) {
                for (modules.items) |m| {
                    if (m.data != .program) continue;
                    for (m.data.program.statements) |stmt| {
                        if (stmt.data == .test_decl) {
                            try self.collectCallees(stmt, &reachable, &worklist);
                        }
                    }
                }
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
        // A name -> *ASTNode index makes each worklist lookup O(1) instead of
        // rescanning every statement of every module per function (O(F*S)).
        // The C transpiler emits every function and lets the linker dead-strip;
        // this pass exists only to keep JIT compile time/IR size down (the
        // stdlib would otherwise be pulled in wholesale). LLVM-SPECIFIC.
        var func_index = try self.buildFuncIndex(&modules);
        defer func_index.deinit();
        try self.drainReachableWorklist(&func_index, &reachable, &worklist);

        // Pass 1e: Emit static vtables for implemented contracts of reachable types (Task 61.1)
        // Named `{type_c_name}_{contract_c_name}_vtable`
        for (modules.items) |m| {
            if (m.data != .program) continue;
            for (m.data.program.statements) |stmt| {
                if (stmt.data == .type_decl) {
                    const t = stmt.data.type_decl;
                    if (t.generic_params.len > 0) continue;
                    const type_c_name = t.resolved_c_name orelse t.name;


                    for (t.contracts) |contract_src| {
                        var contract_node = if (self.contracts_ast) |ca| ca.get(contract_src) else null;
                        if (contract_node == null) {
                            if (std.mem.lastIndexOfScalar(u8, contract_src, '_')) |cidx| {
                                const short_c = contract_src[cidx + 1 ..];
                                contract_node = if (self.contracts_ast) |ca| ca.get(short_c) else null;
                            }
                        }
                        if (contract_node == null or contract_node.?.data != .contract_decl) continue;
                        const c_decl = contract_node.?.data.contract_decl;

                        var vtable_funcs = ArrayList(llvm.LLVMValueRef).init(self.allocator);
                        defer vtable_funcs.deinit();

                        for (c_decl.methods) |cm| {
                            if (cm.data != .fun_decl) continue;
                            const cm_name = cm.data.fun_decl.name;
                            var impl_fn: ?llvm.LLVMValueRef = null;

                            // Look for matching method implementation in the type.
                            // `startsWith` covers the exact method plus overload
                            // suffixes, but the character after the prefix MUST be
                            // an overload separator (`_`) — otherwise a longer
                            // method name that merely starts with this one would
                            // match (`rows` must not pick `rowsAffected`). Neither
                            // a bare `endsWith` (a monomorphized method of another
                            // type can end with this prefix via its type arg).
                            const target_prefix = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ type_c_name, cm_name });
                            defer self.allocator.free(target_prefix);

                            var fit = self.functions.iterator();
                            while (fit.next()) |entry| {
                                const fk = entry.key_ptr.*;
                                if (std.mem.eql(u8, fk, target_prefix)) {
                                    impl_fn = entry.value_ptr.*;
                                    try self.markReachable(fk, &reachable, &worklist);
                                    break;
                                }
                                if (std.mem.startsWith(u8, fk, target_prefix) and fk.len > target_prefix.len and fk[target_prefix.len] == '_') {
                                    impl_fn = entry.value_ptr.*;
                                    try self.markReachable(fk, &reachable, &worklist);
                                    break;
                                }
                            }
                            if (impl_fn) |fn_val| {
                                try vtable_funcs.append(fn_val);
                            } else {
                                try vtable_funcs.append(llvm.LLVMConstNull(ptr_type));
                            }
                        }

                        const vtable_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}_vtable", .{ type_c_name, c_decl.name });
                        defer self.allocator.free(vtable_name);
                        const vtable_name_z = try self.allocator.dupeZ(u8, vtable_name);
                        defer self.allocator.free(vtable_name_z);

                        const vtable_const = llvm.LLVMConstStructInContext(self.context, vtable_funcs.items.ptr, @intCast(vtable_funcs.items.len), 0);
                        const vtable_global = llvm.LLVMAddGlobal(mod, llvm.LLVMTypeOf(vtable_const), vtable_name_z.ptr);
                        llvm.LLVMSetInitializer(vtable_global, vtable_const);
                        llvm.LLVMSetGlobalConstant(vtable_global, 1);

                        if (!std.mem.eql(u8, contract_src, c_decl.name)) {
                            const alt_vname = try std.fmt.allocPrint(self.allocator, "{s}_{s}_vtable", .{ type_c_name, contract_src });
                            defer self.allocator.free(alt_vname);
                            const alt_vname_z = try self.allocator.dupeZ(u8, alt_vname);
                            defer self.allocator.free(alt_vname_z);
                            const alt_global = llvm.LLVMAddGlobal(mod, llvm.LLVMTypeOf(vtable_const), alt_vname_z.ptr);
                            llvm.LLVMSetInitializer(alt_global, vtable_const);
                            llvm.LLVMSetGlobalConstant(alt_global, 1);
                        }
                    }
                }
            }
        }

        // The vtable pass above marks each contract implementation reachable
        // (so its body is emitted), but that happens after the fixpoint walk —
        // drain the worklist again so the callees of those implementations
        // (e.g. getAnsiColor called from within the TextFormatter.format
        // skill) are also collected and don't degrade to stubs.
        try self.drainReachableWorklist(&func_index, &reachable, &worklist);

        for (modules.items) |m| {
            if (m.data != .program) continue;
            for (m.data.program.statements) |stmt| {
                if (stmt.data == .fun_decl) {
                    if (stmt.data.fun_decl.generic_params.len > 0) continue;
                    const fname = stmt.data.fun_decl.resolved_c_name orelse stmt.data.fun_decl.name;
                    if (!reachable.contains(fname)) continue;
                    // In test mode the entry point is `eiwa_test_main`, not a
                    // user `fun main()`. A `main` declared in an imported module
                    // (e.g. the CLI binary imported by cli/test helpers) would
                    // collide with the test-runner entry symbol, silently
                    // shadowing the test runner. Skip it in test mode.
                    if (self.is_test_mode and std.mem.eql(u8, fname, "main")) continue;
                    if (m != ast_root) {
                        self.emitFunctionBodyOrStub(mod, stmt, fname, false);
                    } else {
                        try self.emitFunctionBody(mod, stmt, false);
                    }
                } else if (stmt.data == .type_decl) {
                    // Generic templates are never emitted directly; only
                    // monomorphized instances (which have generic_params empty)
                    // produce code. Mirrors the C transpiler.
                    const is_template = stmt.data.type_decl.generic_params.len > 0 and (stmt.data.type_decl.methods.len == 0 or stmt.data.type_decl.methods[0].data.fun_decl.resolved_c_name == null);
                    if (is_template) continue;
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
                    // C backend's value model (see PRE-EXISTING comments in the
                    // original C runtime and its is_boxed flags). The C backend
                    // could emit
                    // primitive method bodies; the LLVM model cannot, hence the
                    // skip list. Fixing the value model in LLVM removes this list.
                    const t_name = stmt.data.type_decl.resolved_c_name orelse stmt.data.type_decl.name;
                    const is_inline = std.mem.eql(u8, t_name, "core_String") or
                        std.mem.eql(u8, t_name, "String") or
                        std.mem.eql(u8, t_name, "core_Int") or
                        std.mem.eql(u8, t_name, "core_Bool") or
                        std.mem.eql(u8, t_name, "core_Double");
                    if (is_inline) {
                        // Primitives are skipped wholesale because their intrinsic
                        // method bodies reference struct fields (this.ptr,
                        // this.length) the LLVM value model never materializes
                        // (String == char pointer here). Skill-injected methods
                        // (flagged `from_skill` by the type checker) only touch
                        // `this` and their block parameter, so their real bodies
                        // ARE emitted.
                        for (stmt.data.type_decl.methods) |m_node| {
                            if (m_node.data != .fun_decl) continue;
                            if (m_node.data.fun_decl.generic_params.len > 0) continue;
                            if (!m_node.data.fun_decl.from_skill) continue;
                            const fname = m_node.data.fun_decl.resolved_c_name orelse try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ t_name, m_node.data.fun_decl.name });
                            if (!reachable.contains(fname)) continue;
                            self.emitFunctionBodyOrStub(mod, m_node, fname, true);
                        }
                        continue;
                    }
                    for (stmt.data.type_decl.methods) |m_node| {
                        if (m_node.data != .fun_decl) continue;
                        if (m_node.data.fun_decl.generic_params.len > 0) continue;
                        const fname = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ t_name, m_node.data.fun_decl.name });
                        if (!reachable.contains(fname)) continue;
                        // TODO(emitter): Method bodies degrade to skip-with-
                        // warning (stub returning the type's default) even in the
                        // root module because auto-generated stdlib methods
                        // (default toString/hashCode/equals for every type +
                        // monomorphized List/Map/Serializable derivations) may
                        // still reference constructs the emitter can't emit
                        // cleanly. Verified Aug 2026 (Phase 61-64 "parity" did NOT
                        // remove the need): a strict no-stub build fails on
                        // `IntVar.toString` (get_expr `.toString()` on a bare
                        // Pointer), `IntVar.hashCode` (call_expr re-called the
                        // get_expr result as a function pointer) and
                        // `JsonValue.toString` (`.toString()` on enum/custom
                        // types dispatches through the closure path). Two of
                        // those were fixed as real emitter bugs, but custom/enum
                        // `.toString()` still needs the structural String
                        // representation work (Task 64.11) before this tolerance
                        // can be removed. Keeping it avoids hard compile errors
                        // for reachable-but-uninvoked methods.
                        self.emitFunctionBodyOrStub(mod, m_node, fname, true);
                    }
                } else if (stmt.data == .object_decl) {
                    for (stmt.data.object_decl.members) |member| {
                        if (member.data != .fun_decl) continue;
                        if (member.data.fun_decl.generic_params.len > 0) continue;
                        const fname = member.data.fun_decl.resolved_c_name orelse member.data.fun_decl.name;
                        if (!reachable.contains(fname)) continue;
                        self.emitFunctionBodyOrStub(mod, member, fname, true);
                    }
                }
                if (m == ast_root and
                    stmt.data != .fun_decl and stmt.data != .type_decl and stmt.data != .enum_decl and
                    stmt.data != .contract_decl and stmt.data != .skill_decl and stmt.data != .object_decl and
                    stmt.data != .lib_decl and stmt.data != .import_stmt and stmt.data != .test_decl)
                {
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
                    try statement.emitStatement(self.context, mod, self.builder, main_func.?, &scope, &self.structs, &self.libs, stmt, null);
                }

                const cur_bb = llvm.LLVMGetInsertBlock(self.builder);
                if (llvm.LLVMGetBasicBlockTerminator(cur_bb) == null) {
                    const zero = llvm.LLVMConstInt(i32_type, 0, 0);
                    _ = llvm.LLVMBuildRet(self.builder, zero);
                }
            }
        }

        // Pass 4: Test runner (only when is_test_mode == true).
        // Emit each `test "name" { ... }` block as `void eiwa_test_N()` and
        // generate a synthetic main() that calls each and prints [PASS].
        if (self.is_test_mode) {
            var test_funcs = ArrayList(llvm.LLVMValueRef).init(self.allocator);
            defer test_funcs.deinit();
            var test_names_list = ArrayList([]const u8).init(self.allocator);
            defer test_names_list.deinit();

            for (modules.items) |m| {
                if (m.data != .program) continue;
                for (m.data.program.statements) |stmt| {
                    if (stmt.data != .test_decl) continue;
                    const decl = stmt.data.test_decl;
                    const test_id = test_funcs.items.len;

                    const fn_name = try std.fmt.allocPrint(self.allocator, "eiwa_test_{d}", .{test_id});
                    defer self.allocator.free(fn_name);
                    const fn_name_z = try self.allocator.dupeZ(u8, fn_name);
                    defer self.allocator.free(fn_name_z);
                    const test_fn_type = llvm.LLVMFunctionType(void_type, null, 0, 0);
                    const test_fn = llvm.LLVMAddFunction(mod, fn_name_z.ptr, test_fn_type);
                    const entry_bb = llvm.LLVMAppendBasicBlockInContext(self.context, test_fn, "entry");
                    llvm.LLVMPositionBuilderAtEnd(self.builder, entry_bb);

                    var test_scope = std.StringHashMap(llvm.LLVMValueRef).init(self.allocator);
                    defer test_scope.deinit();

                    switch (decl.body.data) {
                        .block => |b| {
                            for (b.statements) |s| {
                                try statement.emitStatement(self.context, mod, self.builder, test_fn, &test_scope, &self.structs, &self.libs, s, null);
                            }
                        },
                        else => {},
                    }
                    if (llvm.LLVMGetBasicBlockTerminator(llvm.LLVMGetInsertBlock(self.builder)) == null) {
                        _ = llvm.LLVMBuildRetVoid(self.builder);
                    }

                    try test_funcs.append(test_fn);
                    try test_names_list.append(decl.name);
                }
            }

            if (test_funcs.items.len > 0) {
                const main_fn_type = llvm.LLVMFunctionType(i32_type, null, 0, 0);
                const main_fn = llvm.LLVMAddFunction(mod, "eiwa_test_main", main_fn_type);
                const main_entry = llvm.LLVMAppendBasicBlockInContext(self.context, main_fn, "entry");
                llvm.LLVMPositionBuilderAtEnd(self.builder, main_entry);

                if (llvm.LLVMGetNamedFunction(mod, "GC_init")) |gc_init| {
                    const gci_type = llvm.LLVMGlobalGetValueType(gc_init);
                    _ = llvm.LLVMBuildCall2(self.builder, gci_type, gc_init, null, 0, "");
                }

                try self.emitEnumInitializers(mod, &modules);

                var obj_scope = std.StringHashMap(llvm.LLVMValueRef).init(self.allocator);
                defer obj_scope.deinit();
                try self.emitObjectInitializers(mod, &modules, &obj_scope);

                const puts_fn = llvm.LLVMGetNamedFunction(mod, "puts").?;
                const puts_call_type = llvm.LLVMGlobalGetValueType(puts_fn);
                const fflush_fn_opt = llvm.LLVMGetNamedFunction(mod, "fflush");

                const fflush_ft_opt = if (fflush_fn_opt) |ff| llvm.LLVMGlobalGetValueType(ff) else null;
                const ptr_type_rt = llvm.LLVMPointerTypeInContext(self.context, 0);
                const frame_type = llvm.LLVMGetTypeByName(mod, "EiwaExceptionFrame") orelse return error.ExceptionRuntimeMissing;
                const stack_global = llvm.LLVMGetNamedGlobal(mod, "eiwa_exception_stack") orelse return error.ExceptionRuntimeMissing;
                const active_global = llvm.LLVMGetNamedGlobal(mod, "eiwa_active_exception") orelse return error.ExceptionRuntimeMissing;
                const setjmp_func = (llvm.LLVMGetNamedFunction(mod, "_setjmp") orelse llvm.LLVMGetNamedFunction(mod, "setjmp")) orelse return error.ExceptionRuntimeMissing;
                const sj_type = llvm.LLVMGlobalGetValueType(setjmp_func);

                // Failed-test counter returned as the process exit code, so the
                // test run signals failure without dying on the first throw.
                const failed_var = llvm.LLVMBuildAlloca(self.builder, i32_type, "test_failed");
                _ = llvm.LLVMBuildStore(self.builder, llvm.LLVMConstInt(i32_type, 0, 0), failed_var);

                for (test_funcs.items, 0..) |test_fn, i| {
                    const test_fn_type_call = llvm.LLVMGlobalGetValueType(test_fn);

                    // Push a fresh exception frame and setjmp around the test so
                    // a thrown exception (e.g. failed `assert`) is caught and
                    // reported as [FAIL] instead of exiting the process silently.
                    const frame_ptr = llvm.LLVMBuildAlloca(self.builder, frame_type, "exc_frame");
                    llvm.LLVMSetAlignment(frame_ptr, 16);

                    const cur_stack = llvm.LLVMBuildLoad2(self.builder, ptr_type_rt, stack_global, "run_cur_stack");
                    const next_gep = llvm.LLVMBuildStructGEP2(self.builder, frame_type, frame_ptr, 1, "run_frame_next");
                    _ = llvm.LLVMBuildStore(self.builder, cur_stack, next_gep);
                    _ = llvm.LLVMBuildStore(self.builder, frame_ptr, stack_global);

                    const buf_gep = llvm.LLVMBuildStructGEP2(self.builder, frame_type, frame_ptr, 0, "run_frame_buf");
                    const buf_ptr = llvm.LLVMBuildBitCast(self.builder, buf_gep, ptr_type_rt, "run_fbuf");
                    var sj_args = [_]llvm.LLVMValueRef{buf_ptr};
                    const sj_ret = llvm.LLVMBuildCall2(self.builder, sj_type, setjmp_func, &sj_args, 1, "run_setjmp");
                    const zero_i32 = llvm.LLVMConstInt(i32_type, 0, 0);
                    const is_try = llvm.LLVMBuildICmp(self.builder, llvm.LLVMIntEQ, sj_ret, zero_i32, "run_is_try");

                    const try_bb = llvm.LLVMAppendBasicBlockInContext(self.context, main_fn, "run.try");
                    const catch_bb = llvm.LLVMAppendBasicBlockInContext(self.context, main_fn, "run.fail");
                    const after_bb = llvm.LLVMAppendBasicBlockInContext(self.context, main_fn, "run.after");
                    _ = llvm.LLVMBuildCondBr(self.builder, is_try, try_bb, catch_bb);

                    // try path: run test, pop frame, print [PASS].
                    llvm.LLVMPositionBuilderAtEnd(self.builder, try_bb);
                    _ = llvm.LLVMBuildCall2(self.builder, test_fn_type_call, test_fn, null, 0, "");
                    {
                        const st = llvm.LLVMBuildLoad2(self.builder, ptr_type_rt, stack_global, "run_stack_pop");
                        const ng = llvm.LLVMBuildStructGEP2(self.builder, frame_type, st, 1, "run_next_pop");
                        const nv = llvm.LLVMBuildLoad2(self.builder, ptr_type_rt, ng, "run_next_val");
                        _ = llvm.LLVMBuildStore(self.builder, nv, stack_global);
                    }
                    const pass_fmt_s = try std.fmt.allocPrint(self.allocator, "[PASS] {s}", .{test_names_list.items[i]});
                    defer self.allocator.free(pass_fmt_s);
                    const pass_fmt = try self.allocator.dupeZ(u8, pass_fmt_s);
                    defer self.allocator.free(pass_fmt);
                    const pass_str = llvm.LLVMBuildGlobalStringPtr(self.builder, pass_fmt.ptr, "pass_msg");
                    var pass_args = [_]llvm.LLVMValueRef{pass_str};
                    _ = llvm.LLVMBuildCall2(self.builder, puts_call_type, puts_fn, &pass_args, 1, "");
                    if (fflush_fn_opt != null) {
                        var null_arg = [_]llvm.LLVMValueRef{llvm.LLVMConstNull(ptr_type_rt)};
                        _ = llvm.LLVMBuildCall2(self.builder, fflush_ft_opt.?, fflush_fn_opt.?, &null_arg, 1, "");
                    }
                    if (llvm.LLVMGetBasicBlockTerminator(llvm.LLVMGetInsertBlock(self.builder)) == null) {
                        _ = llvm.LLVMBuildBr(self.builder, after_bb);
                    }

                    // catch path: pop frame, clear active exception, count failure,
                    // print [FAIL]. Do NOT rethrow or exit — let the harness move on.
                    llvm.LLVMPositionBuilderAtEnd(self.builder, catch_bb);
                    {
                        const st = llvm.LLVMBuildLoad2(self.builder, ptr_type_rt, stack_global, "run_stack_pop2");
                        const ng = llvm.LLVMBuildStructGEP2(self.builder, frame_type, st, 1, "run_next_pop2");
                        const nv = llvm.LLVMBuildLoad2(self.builder, ptr_type_rt, ng, "run_next_val2");
                        _ = llvm.LLVMBuildStore(self.builder, nv, stack_global);
                    }
                    const fat_type_rt = types_mapping.getFatPointerType(self.context);
                    _ = llvm.LLVMBuildLoad2(self.builder, fat_type_rt, active_global, "exc_obj");
                    _ = llvm.LLVMBuildStore(self.builder, llvm.LLVMConstNull(fat_type_rt), active_global);
                    const failed_prev = llvm.LLVMBuildLoad2(self.builder, i32_type, failed_var, "failed_prev");
                    const failed_inc = llvm.LLVMBuildAdd(self.builder, failed_prev, llvm.LLVMConstInt(i32_type, 1, 0), "failed_inc");
                    _ = llvm.LLVMBuildStore(self.builder, failed_inc, failed_var);
                    // Print `[FAIL] {name}: {message}`. The message is read from
                    // field 0 of the thrown object: Eiwa exceptions are
                    // `type X(val text: String)` → `{ ptr }`, and String is a
                    const fail_fmt_s = try std.fmt.allocPrint(self.allocator, "*[FAIL] {s}: Assertion failed", .{test_names_list.items[i]});
                    defer self.allocator.free(fail_fmt_s);
                    const fail_fmt = try self.allocator.dupeZ(u8, fail_fmt_s);
                    defer self.allocator.free(fail_fmt);
                    const fail_str = llvm.LLVMBuildGlobalStringPtr(self.builder, fail_fmt.ptr, "fail_msg");
                    var fail_args = [_]llvm.LLVMValueRef{fail_str};
                    _ = llvm.LLVMBuildCall2(self.builder, puts_call_type, puts_fn, &fail_args, 1, "");
                    if (fflush_fn_opt != null) {
                        var null_arg = [_]llvm.LLVMValueRef{llvm.LLVMConstNull(ptr_type_rt)};
                        _ = llvm.LLVMBuildCall2(self.builder, fflush_ft_opt.?, fflush_fn_opt.?, &null_arg, 1, "");
                    }
                    if (llvm.LLVMGetBasicBlockTerminator(llvm.LLVMGetInsertBlock(self.builder)) == null) {
                        _ = llvm.LLVMBuildBr(self.builder, after_bb);
                    }

                    llvm.LLVMPositionBuilderAtEnd(self.builder, after_bb);
                }

                const failed_final = llvm.LLVMBuildLoad2(self.builder, i32_type, failed_var, "failed_final");
                _ = llvm.LLVMBuildRet(self.builder, failed_final);

            } else {
                std.debug.print("No tests found.\n", .{});
            }
        }

        // Stub pass: emit no-op bodies for any externally-declared functions
        // that have no body (e.g. exceptions_assert_Bool_String, io_println, etc.).
        // Without this the LLVM JIT/linker resolves them to null/undefined → segfault/link error.
        var fn_iter = llvm.LLVMGetFirstFunction(mod);
        while (fn_iter != null) : (fn_iter = llvm.LLVMGetNextFunction(fn_iter.?)) {
            if (llvm.LLVMCountBasicBlocks(fn_iter.?) == 0) {
                // Only stub Eiwa-mangled functions (not libc: printf, malloc, exit…)
                const fn_name_ptr = llvm.LLVMGetValueName(fn_iter.?);
                const fn_name_s = std.mem.span(fn_name_ptr);
                // libm math functions are resolved by MCJIT from the host, so
                // they must NOT get a no-op stub (e.g. `pow` → ret 0.0) or any
                // math test silently returns wrong results.
                const libm_names = [_][]const u8{ "pow", "sqrt", "cbrt", "fabs", "floor", "ceil", "round", "trunc", "nearbyint", "rint", "fmod", "remainder", "exp", "exp2", "expm1", "log", "log2", "log10", "log1p", "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "sinh", "cosh", "tanh", "ldexp", "frexp", "modf", "hypot" };
                var is_libm = false;
                for (libm_names) |n| {
                    if (std.mem.eql(u8, fn_name_s, n)) {
                        is_libm = true;
                        break;
                    }
                }
                var is_lib_fn = false;
                var lib_it = self.libs.valueIterator();
                while (lib_it.next()) |fmap| {
                    var fn_it2 = fmap.valueIterator();
                    while (fn_it2.next()) |cname| {
                        if (std.mem.eql(u8, fn_name_s, cname.*)) {
                            is_lib_fn = true;
                            break;
                        }
                    }
                    if (is_lib_fn) break;
                }
                const is_libc = is_libm or is_lib_fn or
                    std.mem.eql(u8, fn_name_s, "printf") or
                    std.mem.eql(u8, fn_name_s, "malloc") or
                    std.mem.eql(u8, fn_name_s, "realloc") or
                    // libgc symbols resolved from the host process when the
                    // host links libgc (Bloco B). Without the allowlist the
                    // stub pass would rewrite GC_init to a no-op and
                    // GC_realloc to `ret null`, silently breaking GC mode.
                    std.mem.eql(u8, fn_name_s, "GC_malloc") or
                    std.mem.eql(u8, fn_name_s, "GC_realloc") or
                    std.mem.eql(u8, fn_name_s, "GC_init") or
                    std.mem.eql(u8, fn_name_s, "setjmp") or
                    std.mem.eql(u8, fn_name_s, "_setjmp") or
                    std.mem.eql(u8, fn_name_s, "longjmp") or
                    std.mem.eql(u8, fn_name_s, "_longjmp") or
                    std.mem.eql(u8, fn_name_s, "exit") or
                    std.mem.eql(u8, fn_name_s, "fflush") or
                    std.mem.eql(u8, fn_name_s, "memcpy") or
                    std.mem.eql(u8, fn_name_s, "strcpy") or
                    std.mem.eql(u8, fn_name_s, "strcat") or
                    std.mem.eql(u8, fn_name_s, "strcmp") or
                    std.mem.eql(u8, fn_name_s, "strstr") or
                    std.mem.eql(u8, fn_name_s, "strlen") or
                    std.mem.eql(u8, fn_name_s, "snprintf") or
                    std.mem.eql(u8, fn_name_s, "sprintf") or
                    std.mem.eql(u8, fn_name_s, "time") or
                    std.mem.eql(u8, fn_name_s, "puts") or
                    std.mem.eql(u8, fn_name_s, "rand") or
                    std.mem.eql(u8, fn_name_s, "abs") or
                    std.mem.eql(u8, fn_name_s, "labs") or
                    std.mem.eql(u8, fn_name_s, "llabs") or
                    // POSIX socket helpers hand-emitted by emitSocketHelpers
                    // (equivalents of the original C backend's net_helpers.h).
                    // These are real libc functions; without the allowlist the
                    // undefined-function stub pass below rewrites them to
                    // `ret 0`, so socket() creates no socket and bind/accept
                    // silently "succeed" with a bogus fd 0.
                    std.mem.eql(u8, fn_name_s, "socket") or
                    std.mem.eql(u8, fn_name_s, "setsockopt") or
                    std.mem.eql(u8, fn_name_s, "bind") or
                    std.mem.eql(u8, fn_name_s, "listen") or
                    std.mem.eql(u8, fn_name_s, "accept") or
                    std.mem.eql(u8, fn_name_s, "read") or
                    std.mem.eql(u8, fn_name_s, "write") or
                    std.mem.eql(u8, fn_name_s, "fcntl") or
                    std.mem.eql(u8, fn_name_s, "close") or
                    std.mem.eql(u8, fn_name_s, "memset") or
                    std.mem.eql(u8, fn_name_s, "calloc") or
                    std.mem.startsWith(u8, fn_name_s, "eiwa_");
                if (!is_libc) {
                    self.emitFunctionStub(mod, fn_name_s) catch {};
                }
            }
        }

        try self.emitArgvSupport(mod);
        try self.emitEntryShim(mod, &modules);
    }

    /// Emits `main(i32 argc, ptr argv)` — the real C entry the OS runtime
    /// calls. It stores argv into eiwa_argc/eiwa_argv (for Process.args())
    /// and forwards to the program entry: `eiwa_test_main` in test mode, or
    /// the user's `main` renamed to `__eiwa_prog_main` in run/build mode.
    ///
    /// In run/build mode it also runs the enum + object singleton initializers
    /// (mirroring the C backend's `__eiwa_main`, which seeded object member
    /// globals like `Log.rootLogger` before any user code ran). Test mode emits
    /// the same initializers at the top of `eiwa_test_main` instead.
    fn emitEntryShim(
        self: *LLVMEmitter,
        mod: llvm.LLVMModuleRef,
        modules: *ArrayList(*ast.ASTNode),
    ) !void {
        const ptr_type = llvm.LLVMPointerTypeInContext(self.context, 0);
        const i32_type = llvm.LLVMInt32TypeInContext(self.context);

        var real_main: llvm.LLVMValueRef = undefined;
        if (self.is_test_mode) {
            real_main = llvm.LLVMGetNamedFunction(mod, "eiwa_test_main") orelse return error.MainNotFound;
        } else {
            real_main = llvm.LLVMGetNamedFunction(mod, "main") orelse return error.MainNotFound;
            const new_name_z = try self.allocator.dupeZ(u8, "__eiwa_prog_main");
            defer self.allocator.free(new_name_z);
            _ = llvm.LLVMSetValueName2(real_main, new_name_z.ptr, "__eiwa_prog_main".len);
        }
        const real_main_type = llvm.LLVMGlobalGetValueType(real_main);

        var shim_params = [_]llvm.LLVMTypeRef{ i32_type, ptr_type };
        const shim_type = llvm.LLVMFunctionType(i32_type, &shim_params, 2, 0);
        const shim = llvm.LLVMAddFunction(mod, "main", shim_type);
        const shim_entry = llvm.LLVMAppendBasicBlockInContext(self.context, shim, "entry");
        llvm.LLVMPositionBuilderAtEnd(self.builder, shim_entry);
        const argc_val = llvm.LLVMGetParam(shim, 0);
        const argv_val = llvm.LLVMGetParam(shim, 1);

        // Store argv for Process.args().
        const argc_global = llvm.LLVMGetNamedGlobal(mod, "eiwa_argc") orelse blk: {
            const g = llvm.LLVMAddGlobal(mod, i32_type, "eiwa_argc");
            llvm.LLVMSetInitializer(g, llvm.LLVMConstInt(i32_type, 0, 0));
            break :blk g;
        };
        const argv_global = llvm.LLVMGetNamedGlobal(mod, "eiwa_argv") orelse blk: {
            const g = llvm.LLVMAddGlobal(mod, ptr_type, "eiwa_argv");
            llvm.LLVMSetInitializer(g, llvm.LLVMConstNull(ptr_type));
            break :blk g;
        };
        _ = llvm.LLVMBuildStore(self.builder, argc_val, argc_global);
        _ = llvm.LLVMBuildStore(self.builder, argv_val, argv_global);

        // Run enum + object singleton initializers before any user code.
        // Only in run/build mode; test mode already emits them at the top of
        // `eiwa_test_main`. Enum instances (e.g. LogLevel.INFO) must be seeded
        // first so object initializers that reference them (Logger() default
        // args) resolve to real instances instead of null.
        if (!self.is_test_mode) {
            var obj_scope = std.StringHashMap(llvm.LLVMValueRef).init(self.allocator);
            defer obj_scope.deinit();
            try self.emitEnumInitializers(mod, modules);
            try self.emitObjectInitializers(mod, modules, &obj_scope);
        }

        // Call the real program main.
        const ret_kind = llvm.LLVMGetTypeKind(llvm.LLVMGetReturnType(real_main_type));
        if (ret_kind == llvm.LLVMVoidTypeKind) {
            _ = llvm.LLVMBuildCall2(self.builder, real_main_type, real_main, null, 0, "");
            _ = llvm.LLVMBuildRet(self.builder, llvm.LLVMConstInt(i32_type, 0, 0));
        } else {
            const r = llvm.LLVMBuildCall2(self.builder, real_main_type, real_main, null, 0, "prog_ret");
            _ = llvm.LLVMBuildRet(self.builder, r);
        }
    }

    /// Exposes the program argv to `Process.args()` (eiwa_args_count/eiwa_args_get).
    /// The old @MainWrapper entry populated these from `main(i32, ptr)` params;
    /// without it, populate from `program_argv` (set by main.zig for run mode).
    fn emitArgvSupport(self: *LLVMEmitter, mod: llvm.LLVMModuleRef) !void {
        const ptr_type = llvm.LLVMPointerTypeInContext(self.context, 0);
        const i32_type = llvm.LLVMInt32TypeInContext(self.context);
        const i64_type = llvm.LLVMInt64TypeInContext(self.context);

        const argc_global = llvm.LLVMGetNamedGlobal(mod, "eiwa_argc") orelse blk: {
            const g = llvm.LLVMAddGlobal(mod, i32_type, "eiwa_argc");
            llvm.LLVMSetInitializer(g, llvm.LLVMConstInt(i32_type, 0, 0));
            break :blk g;
        };
        const argv_global = llvm.LLVMGetNamedGlobal(mod, "eiwa_argv") orelse blk: {
            const g = llvm.LLVMAddGlobal(mod, ptr_type, "eiwa_argv");
            llvm.LLVMSetInitializer(g, llvm.LLVMConstNull(ptr_type));
            break :blk g;
        };

        // Build a const array of the program argv strings and store it in a
        // global; point eiwa_argv at it and store the count.
        if (self.program_argv.len > 0) {
            const str_ptr_type = llvm.LLVMPointerTypeInContext(self.context, 0);
            var elems = try self.allocator.alloc(llvm.LLVMValueRef, self.program_argv.len + 1);
            defer self.allocator.free(elems);
            for (self.program_argv, 0..) |arg, i| {
                const z = try self.allocator.dupeZ(u8, arg);
                defer self.allocator.free(z);
                elems[i] = llvm.LLVMBuildGlobalStringPtr(self.builder, z.ptr, "prog_arg");
            }
            elems[self.program_argv.len] = llvm.LLVMConstNull(str_ptr_type);
            const arr_type = llvm.LLVMArrayType(str_ptr_type, @intCast(self.program_argv.len + 1));
            const arr_global = llvm.LLVMAddGlobal(mod, arr_type, "eiwa_argv_storage");
            llvm.LLVMSetInitializer(arr_global, llvm.LLVMConstArray(str_ptr_type, elems.ptr, @intCast(self.program_argv.len + 1)));
            llvm.LLVMSetInitializer(argv_global, llvm.LLVMConstBitCast(arr_global, ptr_type));
        }
        llvm.LLVMSetInitializer(argc_global, llvm.LLVMConstInt(i32_type, @intCast(self.program_argv.len), 0));

        // eiwa_args_count() -> Int.
        {
            var p = [_]llvm.LLVMTypeRef{};
            const fty = llvm.LLVMFunctionType(i64_type, &p, 0, 0);
            const f = llvm.LLVMGetNamedFunction(mod, "eiwa_args_count") orelse llvm.LLVMAddFunction(mod, "eiwa_args_count", fty);
            if (llvm.LLVMCountBasicBlocks(f) == 0) {
                const bb = llvm.LLVMAppendBasicBlockInContext(self.context, f, "entry");
                llvm.LLVMPositionBuilderAtEnd(self.builder, bb);
                const v = llvm.LLVMBuildLoad2(self.builder, i32_type, argc_global, "argc");
                const ext = llvm.LLVMBuildZExt(self.builder, v, i64_type, "argc_ext");
                _ = llvm.LLVMBuildRet(self.builder, ext);
            }
        }
        // eiwa_args_get(i) -> ptr.
        {
            var p = [_]llvm.LLVMTypeRef{ i64_type };
            const fty = llvm.LLVMFunctionType(ptr_type, &p, 1, 0);
            const f = llvm.LLVMGetNamedFunction(mod, "eiwa_args_get") orelse llvm.LLVMAddFunction(mod, "eiwa_args_get", fty);
            if (llvm.LLVMCountBasicBlocks(f) == 0) {
                const bb = llvm.LLVMAppendBasicBlockInContext(self.context, f, "entry");
                llvm.LLVMPositionBuilderAtEnd(self.builder, bb);
                const argv_ptr = llvm.LLVMBuildLoad2(self.builder, ptr_type, argv_global, "argv");
                const idx = llvm.LLVMGetParam(f, 0);
                var idxs = [_]llvm.LLVMValueRef{ idx };
                const slot = llvm.LLVMBuildGEP2(self.builder, ptr_type, argv_ptr, &idxs, 1, "slot");
                const val = llvm.LLVMBuildLoad2(self.builder, ptr_type, slot, "arg");
                _ = llvm.LLVMBuildRet(self.builder, val);
            }
        }
    }


    fn declareEnum(self: *LLVMEmitter, mod: llvm.LLVMModuleRef, node: *ast.ASTNode) !void {
        const ed = node.data.enum_decl;
        const name = ed.resolved_c_name orelse ed.name;
        const struct_name_z = try self.allocator.dupeZ(u8, name);
        defer self.allocator.free(struct_name_z);

        const ptr_type = llvm.LLVMPointerTypeInContext(self.context, 0);
        const i64_type = llvm.LLVMInt64TypeInContext(self.context);

        const struct_type = llvm.LLVMStructCreateNamed(self.context, struct_name_z.ptr);
        var field_types = [_]llvm.LLVMTypeRef{ ptr_type, i64_type, ptr_type };
        llvm.LLVMStructSetBody(struct_type, &field_types, 3, 0);

        var field_names = ArrayList([]const u8).init(self.allocator);
        try field_names.append("_desc");
        try field_names.append("ordinal");
        try field_names.append("name");

        try self.structs.put(name, .{
            .struct_type = struct_type,
            .field_names = try field_names.toOwnedSlice(),
            .field_types = try self.allocator.dupe(llvm.LLVMTypeRef, &field_types),
        });

        for (ed.variants) |variant| {
            const v_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ name, variant.name });
            defer self.allocator.free(v_name);
            const v_name_z = try self.allocator.dupeZ(u8, v_name);
            defer self.allocator.free(v_name_z);

            const global = llvm.LLVMAddGlobal(mod, ptr_type, v_name_z.ptr);
            llvm.LLVMSetInitializer(global, llvm.LLVMConstNull(ptr_type));
        }
    }

    fn emitEnumInitializers(
        self: *LLVMEmitter,
        mod: llvm.LLVMModuleRef,
        modules: *ArrayList(*ast.ASTNode),
    ) !void {
        const ptr_type = llvm.LLVMPointerTypeInContext(self.context, 0);
        const i64_type = llvm.LLVMInt64TypeInContext(self.context);

        const gc_func = getHeapAllocFn(mod);
        const gc_type = llvm.LLVMGlobalGetValueType(gc_func);

        for (modules.items) |m| {
            if (m.data != .program) continue;
            for (m.data.program.statements) |stmt| {
                if (stmt.data != .enum_decl) continue;
                const ed = stmt.data.enum_decl;
                const enum_name = ed.resolved_c_name orelse ed.name;
                const s_info = self.structs.get(enum_name) orelse continue;

                for (ed.variants, 0..) |variant, idx| {
                    const v_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ enum_name, variant.name });
                    defer self.allocator.free(v_name);
                    const v_name_z = try self.allocator.dupeZ(u8, v_name);
                    defer self.allocator.free(v_name_z);

                    if (llvm.LLVMGetNamedGlobal(mod, v_name_z.ptr)) |global| {
                        const size_val = llvm.LLVMSizeOf(s_info.struct_type);
                        var gc_args = [_]llvm.LLVMValueRef{size_val};
                        const inst_ptr = llvm.LLVMBuildCall2(self.builder, gc_type, gc_func, &gc_args, 1, "enum_inst");

                        // Field 0: _desc (null)
                        const desc_ptr = llvm.LLVMBuildStructGEP2(self.builder, s_info.struct_type, inst_ptr, 0, "enum_desc");
                        _ = llvm.LLVMBuildStore(self.builder, llvm.LLVMConstNull(ptr_type), desc_ptr);

                        // Field 1: ordinal (idx)
                        const ord_ptr = llvm.LLVMBuildStructGEP2(self.builder, s_info.struct_type, inst_ptr, 1, "enum_ord");
                        _ = llvm.LLVMBuildStore(self.builder, llvm.LLVMConstInt(i64_type, @intCast(idx), 0), ord_ptr);

                        // Field 2: name (string ptr). variant.name is a
                        // bundled []const u8 into the source buffer, so it must
                        // be null-terminated before BuildGlobalStringPtr or the
                        // whole remaining source leaks into the global.
                        const name_z = try self.allocator.dupeZ(u8, variant.name);
                        defer self.allocator.free(name_z);
                        const name_ptr = llvm.LLVMBuildStructGEP2(self.builder, s_info.struct_type, inst_ptr, 2, "enum_name");
                        const str_val = llvm.LLVMBuildGlobalStringPtr(self.builder, name_z.ptr, "enum_str");
                        _ = llvm.LLVMBuildStore(self.builder, str_val, name_ptr);

                        _ = llvm.LLVMBuildStore(self.builder, inst_ptr, global);
                    }
                }
            }
        }
    }

    fn emitObjectInitializers(
        self: *LLVMEmitter,
        mod: llvm.LLVMModuleRef,
        modules: *ArrayList(*ast.ASTNode),
        scope: *std.StringHashMap(llvm.LLVMValueRef),
    ) !void {
        for (modules.items) |m| {
            if (m.data != .program) continue;
            for (m.data.program.statements) |stmt| {
                if (stmt.data != .object_decl) continue;
                const obj = stmt.data.object_decl;
                const obj_c_name = obj.resolved_c_name orelse (obj.name orelse "Object");
                for (obj.members) |member| {
                    if (member.data != .var_decl) continue;
                    const v = member.data.var_decl;
                    const init_expr = v.initializer orelse continue;
                    const var_name = if (v.resolved_c_name) |rcn| rcn else try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ obj_c_name, v.name });
                    defer if (v.resolved_c_name == null) self.allocator.free(var_name);
                    const var_name_z = try self.allocator.dupeZ(u8, var_name);
                    defer self.allocator.free(var_name_z);
                    if (llvm.LLVMGetNamedGlobal(mod, var_name_z.ptr)) |global| {
                        var val = try expression.emitExpression(self.context, mod, self.builder, scope, &self.structs, &self.libs, init_expr);
                        const global_type = llvm.LLVMGlobalGetValueType(global);
                        if (llvm.LLVMGetTypeKind(global_type) == llvm.LLVMStructTypeKind and llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(val)) == llvm.LLVMPointerTypeKind) {
                            if (member.resolved_type) |v_rt| {
                                const target_c_name = switch (v_rt.*) {
                                    .Custom => |n| n,
                                    .GenericInstance => |gi| gi.base_name,
                                    else => "",
                                };
                                if (init_expr.resolved_type) |init_rt| {
                                    const init_c_name = switch (init_rt.*) {
                                        .Custom => |n| n,
                                        .GenericInstance => |gi| gi.base_name,
                                        else => "",
                                    };
                                    if (init_c_name.len > 0 and target_c_name.len > 0) {
                                        val = expression.coerceToContract(self.context, mod, self.builder, val, init_c_name, target_c_name) catch val;
                                    }
                                }
                            }
                        }
                        _ = llvm.LLVMBuildStore(self.builder, val, global);
                    } else {
                        if (verbose) std.debug.print("LLVM Debug: Object global NOT FOUND for {s}\n", .{var_name});
                    }
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

        const prefix = try std.fmt.allocPrint(self.allocator, "{s}_", .{name});
        defer self.allocator.free(prefix);
        const suffix = try std.fmt.allocPrint(self.allocator, "_{s}_", .{name});
        defer self.allocator.free(suffix);

        var it = self.functions.keyIterator();
        while (it.next()) |k| {
            if (std.mem.eql(u8, k.*, name) or std.mem.startsWith(u8, k.*, prefix) or std.mem.indexOf(u8, k.*, suffix) != null or std.mem.endsWith(u8, k.*, suffix[0 .. suffix.len - 1])) {
                if (!reachable.contains(k.*)) {
                    const func_owned = try self.allocator.dupe(u8, k.*);
                    try reachable.put(func_owned, {});
                    try worklist.append(func_owned);
                }
            }
        }
    }

    /// Builds a single index of every non-generic function's resolved name
    /// (`resolved_c_name orelse name`) -> its AST node, covering top-level
    /// `fun_decl`s, `type_decl.methods` and `object` members. Keys are
    /// borrowed from the AST, so the map owns nothing. First declaration wins,
    /// mirroring the old module-scan lookup.
    fn buildFuncIndex(
        self: *LLVMEmitter,
        modules: *ArrayList(*ast.ASTNode),
    ) !std.StringHashMap(*ast.ASTNode) {
        var index = std.StringHashMap(*ast.ASTNode).init(self.allocator);
        errdefer index.deinit();
        for (modules.items) |m| {
            if (m.data != .program) continue;
            for (m.data.program.statements) |stmt| {
                if (stmt.data == .fun_decl) {
                    const f = stmt.data.fun_decl;
                    if (f.generic_params.len > 0) continue;
                    const name = f.resolved_c_name orelse f.name;
                    if (!index.contains(name)) try index.put(name, stmt);
                } else if (stmt.data == .type_decl) {
                    const t = stmt.data.type_decl;
                    const is_template = t.generic_params.len > 0 and (t.methods.len == 0 or t.methods[0].data.fun_decl.resolved_c_name == null);
                    if (is_template) continue;
                    for (t.methods) |m_node| {
                        if (m_node.data != .fun_decl) continue;
                        if (m_node.data.fun_decl.generic_params.len > 0) continue;
                        const name = m_node.data.fun_decl.resolved_c_name orelse m_node.data.fun_decl.name;
                        if (!index.contains(name)) try index.put(name, m_node);
                    }
                } else if (stmt.data == .object_decl) {
                    for (stmt.data.object_decl.members) |member| {
                        if (member.data != .fun_decl) continue;
                        if (member.data.fun_decl.generic_params.len > 0) continue;
                        const name = member.data.fun_decl.resolved_c_name orelse member.data.fun_decl.name;
                        if (!index.contains(name)) try index.put(name, member);
                    }
                }
            }
        }
        return index;
    }

    /// Processes the reachability worklist until fixpoint: for each function
    /// symbol, looks up its AST node in the name index and walks its body to
    /// collect callees. Idempotent — safe to call again after more symbols are
    /// marked reachable (e.g. by the vtable pass).
    fn drainReachableWorklist(
        self: *LLVMEmitter,
        func_index: *std.StringHashMap(*ast.ASTNode),
        reachable: *std.StringHashMap(void),
        worklist: *ArrayList([]const u8),
    ) !void {
        var wi: usize = 0;
        while (wi < worklist.items.len) : (wi += 1) {
            const fname = worklist.items[wi];
            if (func_index.get(fname)) |node| {
                try self.collectCallees(node, reachable, worklist);
            }
        }
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
            .test_decl => |t| try self.collectCallees(t.body, reachable, worklist),
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
            .map_literal => |m| {
                for (m.elements) |e| try self.collectCallees(e, reachable, worklist);
                // The map literal emitter calls `MutableMap_{K,V}_put` for each
                // pair via a bare LLVMGetNamedFunction, so `collectCallees`
                // would never discover it and the stub pass would reduce it to
                // a no-op `ret`, silently dropping every insertion. Mark it
                // reachable (its body walk pulls in Node ctor, List ops, etc).
                if (node.resolved_type) |rt| {
                    var inner: []const u8 = "";
                    if (rt.* == .Custom) {
                        const custom = rt.Custom;
                        if (std.mem.startsWith(u8, custom, "collections_Map_"))
                            inner = custom["collections_Map_".len..]
                        else if (std.mem.startsWith(u8, custom, "Map_"))
                            inner = custom["Map_".len..]
                        else
                            inner = custom;
                    }
                    if (inner.len > 0) {
                        const buf = try std.fmt.allocPrint(self.allocator, "collections_MutableMap_{s}_put", .{inner});
                        try self.markReachable(buf, reachable, worklist);
                        self.allocator.free(buf);
                    }
                }
            },
            .set_expr => |s| {
                try self.collectCallees(s.object, reachable, worklist);
                try self.collectCallees(s.value, reachable, worklist);
            },
            .get_expr => |g| {
                // `{Type}_{method}` mangled method call on a struct instance.
                if (g.object.resolved_type) |obj_rt| {
                    var type_name: []const u8 = "";
                    switch (obj_rt.*) {
                        .Custom => |n| type_name = n,
                        .GenericInstance => |gi| type_name = gi.base_name,
                        .String => type_name = "core_String",
                        .Int => type_name = "core_Int",
                        .Bool => type_name = "core_Bool",
                        .Double => type_name = "core_Double",
                        .Pointer => |p| {
                            // Raw pointer (element Void) → core_Pointer; a typed
                            // pointer dispatches by its element type.
                            if (p.* == .Custom) {
                                type_name = p.Custom;
                            } else if (p.* == .String) {
                                type_name = "core_String";
                            } else if (p.* == .Void) {
                                type_name = "core_Pointer";
                            }
                        },
                        else => {},
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
                // `cFunctionPtr(fn)`: the trampoline forwards to `fn`, so keep it
                // reachable (otherwise the stub pass reduces it to a no-op `ret`).
                if (c.c_fn_ptr) |tramp_name| {
                    try self.markReachable(tramp_name["eiwa_cb_".len..], reachable, worklist);
                }
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
                        const static_string_type = struct {
                            const t = ts.EiwaType{ .String = {} };
                        };
                        const obj_rt_opt = g.object.resolved_type orelse blk: {
                            if (c.callee.resolved_type) |crt| {
                                if (crt.* == .Function) {
                                    if (crt.Function.receiver != null) break :blk crt.Function.receiver.?;
                                    if (crt.Function.c_name.len > 0 and (std.mem.startsWith(u8, crt.Function.c_name, "core_String_") or std.mem.startsWith(u8, crt.Function.c_name, "String_"))) {
                                        break :blk &static_string_type.t;
                                    }
                                }
                            }
                            break :blk null;
                        };
                        if (obj_rt_opt) |obj_rt| {
                            const base = ts.extractBaseType(obj_rt);
                            const rec_name = switch (base.*) {
                                .String => "core_String",
                                .Custom => |n| n,
                                .GenericInstance => |gi| gi.base_name,
                                else => "",
                            };
                            const base_rec_name = if (std.mem.indexOf(u8, rec_name, "_core_")) |idx|
                                rec_name[0..idx]
                            else if (std.mem.indexOf(u8, rec_name, "_collections_")) |idx|
                                rec_name[0..idx]
                            else
                                rec_name;

                            if (base_rec_name.len > 0) {
                                const method_c_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ base_rec_name, g.name });
                                try self.markReachable(method_c_name, reachable, worklist);
                            }
                        }
                        try self.collectCallees(g.object, reachable, worklist);
                    }
                }
                try self.collectCallees(c.callee, reachable, worklist);
                for (c.arguments) |arg| try self.collectCallees(arg, reachable, worklist);
            },
            .type_decl => |t| {
                // Constructor default args are cloned into call sites, so they
                // are already walked there. Body-field initializers live only
                // in the ctor — walk them so their callees stay reachable.
                for (t.primary_constructor) |prop| {
                    if (prop.initializer) |init_node| try self.collectCallees(init_node, reachable, worklist);
                }
                for (t.body_fields) |prop| {
                    if (prop.initializer) |init_node| try self.collectCallees(init_node, reachable, worklist);
                }
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
    fn emitStdlibIntrinsics(self: *LLVMEmitter, mod: llvm.LLVMModuleRef) !void {
        const ptr_t = llvm.LLVMPointerTypeInContext(self.context, 0);
        const i64_t = llvm.LLVMInt64TypeInContext(self.context);
        const i8_t = llvm.LLVMInt8TypeInContext(self.context);
        const void_t = llvm.LLVMVoidTypeInContext(self.context);

        // eiwa_char_at(ptr, idx) -> i64
        {
            var params = [_]llvm.LLVMTypeRef{ ptr_t, i64_t };
            const fn_t = llvm.LLVMFunctionType(i64_t, &params, 2, 0);
            const func = llvm.LLVMGetNamedFunction(mod, "eiwa_char_at") orelse llvm.LLVMAddFunction(mod, "eiwa_char_at", fn_t);
            if (llvm.LLVMCountBasicBlocks(func) == 0) {
                const bb = llvm.LLVMAppendBasicBlockInContext(self.context, func, "entry");
                llvm.LLVMPositionBuilderAtEnd(self.builder, bb);
                const str_p = llvm.LLVMGetParam(func, 0);
                const idx_v = llvm.LLVMGetParam(func, 1);
                var idx_arr = [_]llvm.LLVMValueRef{idx_v};
                const gep = llvm.LLVMBuildGEP2(self.builder, i8_t, str_p, &idx_arr, 1, "gep");
                const ch = llvm.LLVMBuildLoad2(self.builder, i8_t, gep, "ch");
                const res = llvm.LLVMBuildZExt(self.builder, ch, i64_t, "res");
                _ = llvm.LLVMBuildRet(self.builder, res);
            }
        }

        // eiwa_write_byte(ptr, idx, val) -> void
        {
            var params = [_]llvm.LLVMTypeRef{ ptr_t, i64_t, i64_t };
            const fn_t = llvm.LLVMFunctionType(void_t, &params, 3, 0);
            const func = llvm.LLVMGetNamedFunction(mod, "eiwa_write_byte") orelse llvm.LLVMAddFunction(mod, "eiwa_write_byte", fn_t);
            if (llvm.LLVMCountBasicBlocks(func) == 0) {
                const bb = llvm.LLVMAppendBasicBlockInContext(self.context, func, "entry");
                llvm.LLVMPositionBuilderAtEnd(self.builder, bb);
                const buf_p = llvm.LLVMGetParam(func, 0);
                const idx_v = llvm.LLVMGetParam(func, 1);
                const val_v = llvm.LLVMGetParam(func, 2);
                var idx_arr = [_]llvm.LLVMValueRef{idx_v};
                const gep = llvm.LLVMBuildGEP2(self.builder, i8_t, buf_p, &idx_arr, 1, "gep");
                const val_i8 = llvm.LLVMBuildTrunc(self.builder, val_v, i8_t, "val8");
                _ = llvm.LLVMBuildStore(self.builder, val_i8, gep);
                _ = llvm.LLVMBuildRetVoid(self.builder);
            }
        }

        // eiwa_read_byte(ptr, idx) -> i64
        {
            var params = [_]llvm.LLVMTypeRef{ ptr_t, i64_t };
            const fn_t = llvm.LLVMFunctionType(i64_t, &params, 2, 0);
            const func = llvm.LLVMGetNamedFunction(mod, "eiwa_read_byte") orelse llvm.LLVMAddFunction(mod, "eiwa_read_byte", fn_t);
            if (llvm.LLVMCountBasicBlocks(func) == 0) {
                const bb = llvm.LLVMAppendBasicBlockInContext(self.context, func, "entry");
                llvm.LLVMPositionBuilderAtEnd(self.builder, bb);
                const buf_p = llvm.LLVMGetParam(func, 0);
                const idx_v = llvm.LLVMGetParam(func, 1);
                var idx_arr = [_]llvm.LLVMValueRef{idx_v};
                const gep = llvm.LLVMBuildGEP2(self.builder, i8_t, buf_p, &idx_arr, 1, "gep");
                const b = llvm.LLVMBuildLoad2(self.builder, i8_t, gep, "byte");
                const res = llvm.LLVMBuildZExt(self.builder, b, i64_t, "res");
                _ = llvm.LLVMBuildRet(self.builder, res);
            }
        }

        // eiwa_load_int64(ptr) -> i64
        // TODO(emitter): same review bucket as the other reimplemented runtime
        // helpers above — inline IR duplicates eiwa_runtime.h; the proper fix is
        // to link the actual runtime C helper instead of re-emitting it.
        {
            var params = [_]llvm.LLVMTypeRef{ ptr_t };
            const fn_t = llvm.LLVMFunctionType(i64_t, &params, 1, 0);
            const func = llvm.LLVMGetNamedFunction(mod, "eiwa_load_int64") orelse llvm.LLVMAddFunction(mod, "eiwa_load_int64", fn_t);
            if (llvm.LLVMCountBasicBlocks(func) == 0) {
                const bb = llvm.LLVMAppendBasicBlockInContext(self.context, func, "entry");
                llvm.LLVMPositionBuilderAtEnd(self.builder, bb);
                const p = llvm.LLVMGetParam(func, 0);
                const val = llvm.LLVMBuildLoad2(self.builder, i64_t, p, "val");
                _ = llvm.LLVMBuildRet(self.builder, val);
            }
        }

        // eiwa_store_int64(ptr, val) -> void
        // TODO(emitter): same review bucket as above — inline IR duplicates
        // eiwa_runtime.h; link the runtime helper instead of re-emitting it.
        {
            var params = [_]llvm.LLVMTypeRef{ ptr_t, i64_t };
            const fn_t = llvm.LLVMFunctionType(void_t, &params, 2, 0);
            const func = llvm.LLVMGetNamedFunction(mod, "eiwa_store_int64") orelse llvm.LLVMAddFunction(mod, "eiwa_store_int64", fn_t);
            if (llvm.LLVMCountBasicBlocks(func) == 0) {
                const bb = llvm.LLVMAppendBasicBlockInContext(self.context, func, "entry");
                llvm.LLVMPositionBuilderAtEnd(self.builder, bb);
                const p = llvm.LLVMGetParam(func, 0);
                const val = llvm.LLVMGetParam(func, 1);
                _ = llvm.LLVMBuildStore(self.builder, val, p);
                _ = llvm.LLVMBuildRetVoid(self.builder);
            }
        }

        // eiwa_random_bytes(ptr, len) -> void
        {
            var params = [_]llvm.LLVMTypeRef{ ptr_t, i64_t };
            const fn_t = llvm.LLVMFunctionType(void_t, &params, 2, 0);
            const func = llvm.LLVMGetNamedFunction(mod, "eiwa_random_bytes") orelse llvm.LLVMAddFunction(mod, "eiwa_random_bytes", fn_t);
            if (llvm.LLVMCountBasicBlocks(func) == 0) {
                const rand_fn = llvm.LLVMGetNamedFunction(mod, "rand") orelse blk: {
                    const ft = llvm.LLVMFunctionType(llvm.LLVMInt32TypeInContext(self.context), null, 0, 0);
                    break :blk llvm.LLVMAddFunction(mod, "rand", ft);
                };
                const rand_type = llvm.LLVMGlobalGetValueType(rand_fn);

                const entry_bb = llvm.LLVMAppendBasicBlockInContext(self.context, func, "entry");
                const loop_bb = llvm.LLVMAppendBasicBlockInContext(self.context, func, "loop");
                const body_bb = llvm.LLVMAppendBasicBlockInContext(self.context, func, "body");
                const done_bb = llvm.LLVMAppendBasicBlockInContext(self.context, func, "done");

                llvm.LLVMPositionBuilderAtEnd(self.builder, entry_bb);
                const buf_p = llvm.LLVMGetParam(func, 0);
                const len_v = llvm.LLVMGetParam(func, 1);
                const i_alloca = llvm.LLVMBuildAlloca(self.builder, i64_t, "i_ptr");
                _ = llvm.LLVMBuildStore(self.builder, llvm.LLVMConstInt(i64_t, 0, 0), i_alloca);
                _ = llvm.LLVMBuildBr(self.builder, loop_bb);

                llvm.LLVMPositionBuilderAtEnd(self.builder, loop_bb);
                const cur_i = llvm.LLVMBuildLoad2(self.builder, i64_t, i_alloca, "cur_i");
                const cond = llvm.LLVMBuildICmp(self.builder, llvm.LLVMIntULT, cur_i, len_v, "cond");
                _ = llvm.LLVMBuildCondBr(self.builder, cond, body_bb, done_bb);

                llvm.LLVMPositionBuilderAtEnd(self.builder, body_bb);
                const r_val32 = llvm.LLVMBuildCall2(self.builder, rand_type, rand_fn, null, 0, "r32");
                const r_byte = llvm.LLVMBuildTrunc(self.builder, r_val32, i8_t, "r8");
                var idx_arr = [_]llvm.LLVMValueRef{cur_i};
                const gep = llvm.LLVMBuildGEP2(self.builder, i8_t, buf_p, &idx_arr, 1, "gep");
                _ = llvm.LLVMBuildStore(self.builder, r_byte, gep);

                const next_i = llvm.LLVMBuildAdd(self.builder, cur_i, llvm.LLVMConstInt(i64_t, 1, 0), "next_i");
                _ = llvm.LLVMBuildStore(self.builder, next_i, i_alloca);
                _ = llvm.LLVMBuildBr(self.builder, loop_bb);

                llvm.LLVMPositionBuilderAtEnd(self.builder, done_bb);
                _ = llvm.LLVMBuildRetVoid(self.builder);
            }
        }

        // eiwa_now_millis() -> i64
        {
            const fn_t = llvm.LLVMFunctionType(i64_t, null, 0, 0);
            const func = llvm.LLVMGetNamedFunction(mod, "eiwa_now_millis") orelse llvm.LLVMAddFunction(mod, "eiwa_now_millis", fn_t);
            if (llvm.LLVMCountBasicBlocks(func) == 0) {
                const bb = llvm.LLVMAppendBasicBlockInContext(self.context, func, "entry");
                llvm.LLVMPositionBuilderAtEnd(self.builder, bb);

                const time_func = llvm.LLVMGetNamedFunction(mod, "time").?;
                const time_type = llvm.LLVMGlobalGetValueType(time_func);
                var time_args = [_]llvm.LLVMValueRef{llvm.LLVMConstNull(ptr_t)};
                const sec_v = llvm.LLVMBuildCall2(self.builder, time_type, time_func, &time_args, 1, "sec");
                const ms_v = llvm.LLVMBuildMul(self.builder, sec_v, llvm.LLVMConstInt(i64_t, 1000, 0), "ms");
                _ = llvm.LLVMBuildRet(self.builder, ms_v);
            }
        }

        // The net helpers (eiwa_tcp_bind/accept, eiwa_socket_read/write,
        // eiwa_tcp_set_nonblocking, eiwa_socket_close) lived as `static inline`
        // in the original C backend's net_helpers.h, which that backend
        // #included into its generated code. The LLVM backend has no C
        // to inject the header into and the JIT dylib never compiles it, so the
        // externs would resolve to null (EXC_BAD_ACCESS on the first call).
        // Hand-emit their bodies as IR, like eiwa_to_string/eiwa_now_millis.
        try self.emitSocketHelpers(mod);
    }

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
        const double_bb = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "is_double");
        _ = llvm.LLVMBuildCondBr(self.builder, is_small, int_bb, str_bb);

        llvm.LLVMPositionBuilderAtEnd(self.builder, int_bb);
        // buf = alloc(32); sprintf(buf, "%lld", val); ret buf. buf is capped
        // at 32 bytes, matching the runtime's core_Int_toString bound.
        const gc_func = getHeapAllocFn(mod);
        const gc_type = llvm.LLVMGlobalGetValueType(gc_func);
        const buf_size = llvm.LLVMConstInt(i64_type, 32, 0);
        var gc_args = [_]llvm.LLVMValueRef{buf_size};
        const buf = llvm.LLVMBuildCall2(self.builder, gc_type, gc_func, &gc_args, 1, "ts_buf");

        const sprintf_func = llvm.LLVMGetNamedFunction(mod, "sprintf") orelse return error.SprintfNotFound;
        const sprintf_type = llvm.LLVMGlobalGetValueType(sprintf_func);
        const fmt = llvm.LLVMBuildGlobalStringPtr(self.builder, "%lld", "ts_fmt");
        var sp_args = [_]llvm.LLVMValueRef{ buf, fmt, int_val };
        _ = llvm.LLVMBuildCall2(self.builder, sprintf_type, sprintf_func, &sp_args, 3, "ts_sprintf");
        _ = llvm.LLVMBuildRet(self.builder, buf);

        llvm.LLVMPositionBuilderAtEnd(self.builder, double_bb);
        // Check if value looks like a Double (bitcast val to double, then formatted) vs char pointer (> 0x10000 pointer)
        // If val >= 0x10000 and < 0x7FFFFFFFFFFFFFFF, or if formatted via %g:
        const d_buf = llvm.LLVMBuildCall2(self.builder, gc_type, gc_func, &gc_args, 1, "ts_dbuf");
        const d_i64 = llvm.LLVMBuildPtrToInt(self.builder, val, i64_type, "ts_di64");
        const d_val = llvm.LLVMBuildBitCast(self.builder, d_i64, llvm.LLVMDoubleTypeInContext(self.context), "ts_dval");
        const dfmt = llvm.LLVMBuildGlobalStringPtr(self.builder, "%g", "ts_dfmt");
        var dsp_args = [_]llvm.LLVMValueRef{ d_buf, dfmt, d_val };
        _ = llvm.LLVMBuildCall2(self.builder, sprintf_type, sprintf_func, &dsp_args, 3, "ts_dsprintf");
        _ = llvm.LLVMBuildRet(self.builder, d_buf);

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
    /// came from the C backend — see PRE-EXISTING comments in the original C
    /// backend (get_expr hashCode) and its runtime (eiwa_hash_code). The C
    /// version dispatches through the Hashable vtable for custom types; this
    /// LLVM copy only handles char* strings and boxes ints.
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
    /// this.length). Allocation follows the active heap allocator (GC_malloc
    /// when prefer_gc_alloc). LLVM-SPECIFIC (NOT inherited from C): the C
    /// backend emits the real core_String.replace body.
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
        const malloc_fn = getHeapAllocFn(mod);
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

    fn emitStringEqualsHelper(self: *LLVMEmitter, mod: llvm.LLVMModuleRef) !void {
        const ptr_type = llvm.LLVMPointerTypeInContext(self.context, 0);
        const i1_type = llvm.LLVMInt1TypeInContext(self.context);
        const i32_type = llvm.LLVMInt32TypeInContext(self.context);

        var params = [_]llvm.LLVMTypeRef{ ptr_type, ptr_type };
        const fn_type = llvm.LLVMFunctionType(i1_type, &params, 2, 0);
        const fn_val = llvm.LLVMAddFunction(mod, "eiwa_string_equals", fn_type);

        const entry = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const ptr_diff = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "ptr_diff");
        const do_strcmp = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "do_strcmp");
        const ret_false = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "ret_false");
        const ret_true = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "ret_true");

        llvm.LLVMPositionBuilderAtEnd(self.builder, entry);
        const a = llvm.LLVMGetParam(fn_val, 0);
        const b = llvm.LLVMGetParam(fn_val, 1);
        const is_same = llvm.LLVMBuildICmp(self.builder, llvm.LLVMIntEQ, a, b, "seq_same");
        _ = llvm.LLVMBuildCondBr(self.builder, is_same, ret_true, ptr_diff);

        llvm.LLVMPositionBuilderAtEnd(self.builder, ptr_diff);
        const i64_type = llvm.LLVMInt64TypeInContext(self.context);
        const a_int = llvm.LLVMBuildPtrToInt(self.builder, a, i64_type, "seq_aint");
        const b_int = llvm.LLVMBuildPtrToInt(self.builder, b, i64_type, "seq_bint");
        const threshold = llvm.LLVMConstInt(i64_type, 0x1000000, 0);
        const a_invalid = llvm.LLVMBuildICmp(self.builder, llvm.LLVMIntULT, a_int, threshold, "seq_ainvalid");
        const b_invalid = llvm.LLVMBuildICmp(self.builder, llvm.LLVMIntULT, b_int, threshold, "seq_binvalid");
        const any_invalid = llvm.LLVMBuildOr(self.builder, a_invalid, b_invalid, "seq_anyinvalid");
        _ = llvm.LLVMBuildCondBr(self.builder, any_invalid, ret_false, do_strcmp);

        llvm.LLVMPositionBuilderAtEnd(self.builder, do_strcmp);
        const strcmp_fn = llvm.LLVMGetNamedFunction(mod, "strcmp") orelse blk: {
            var ps = [_]llvm.LLVMTypeRef{ ptr_type, ptr_type };
            const ft = llvm.LLVMFunctionType(i32_type, &ps, 2, 0);
            break :blk llvm.LLVMAddFunction(mod, "strcmp", ft);
        };
        const strcmp_ft = llvm.LLVMGlobalGetValueType(strcmp_fn);
        var args = [_]llvm.LLVMValueRef{ a, b };
        const cmp = llvm.LLVMBuildCall2(self.builder, strcmp_ft, strcmp_fn, &args, 2, "seq_cmp");
        const zero = llvm.LLVMConstInt(i32_type, 0, 0);
        const is_eq = llvm.LLVMBuildICmp(self.builder, llvm.LLVMIntEQ, cmp, zero, "seq_eq");
        _ = llvm.LLVMBuildCondBr(self.builder, is_eq, ret_true, ret_false);

        llvm.LLVMPositionBuilderAtEnd(self.builder, ret_true);
        _ = llvm.LLVMBuildRet(self.builder, llvm.LLVMConstInt(i1_type, 1, 0));

        llvm.LLVMPositionBuilderAtEnd(self.builder, ret_false);
        _ = llvm.LLVMBuildRet(self.builder, llvm.LLVMConstInt(i1_type, 0, 0));
    }

    fn emitCharAtHelper(self: *LLVMEmitter, mod: llvm.LLVMModuleRef) !void {
        const ptr_type = llvm.LLVMPointerTypeInContext(self.context, 0);
        const i64_type = llvm.LLVMInt64TypeInContext(self.context);
        const i8_type = llvm.LLVMInt8TypeInContext(self.context);

        var params = [_]llvm.LLVMTypeRef{ ptr_type, i64_type };
        const fn_type = llvm.LLVMFunctionType(i64_type, &params, 2, 0);
        const fn_val = llvm.LLVMAddFunction(mod, "eiwa_char_at", fn_type);

        const entry = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        llvm.LLVMPositionBuilderAtEnd(self.builder, entry);
        const ptr_val = llvm.LLVMGetParam(fn_val, 0);
        const idx_val = llvm.LLVMGetParam(fn_val, 1);
        var idx_args = [_]llvm.LLVMValueRef{idx_val};
        const elem_ptr = llvm.LLVMBuildGEP2(self.builder, i8_type, ptr_val, &idx_args, 1, "elem_ptr");
        const byte_val = llvm.LLVMBuildLoad2(self.builder, i8_type, elem_ptr, "byte");
        const zext = llvm.LLVMBuildZExt(self.builder, byte_val, i64_type, "zext");
        _ = llvm.LLVMBuildRet(self.builder, zext);
    }

    fn emitWriteByteHelper(self: *LLVMEmitter, mod: llvm.LLVMModuleRef) !void {
        const ptr_type = llvm.LLVMPointerTypeInContext(self.context, 0);
        const i64_type = llvm.LLVMInt64TypeInContext(self.context);
        const i8_type = llvm.LLVMInt8TypeInContext(self.context);
        const void_type = llvm.LLVMVoidTypeInContext(self.context);

        var params = [_]llvm.LLVMTypeRef{ ptr_type, i64_type, i64_type };
        const fn_type = llvm.LLVMFunctionType(void_type, &params, 3, 0);
        const fn_val = llvm.LLVMAddFunction(mod, "eiwa_write_byte", fn_type);

        const entry = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        llvm.LLVMPositionBuilderAtEnd(self.builder, entry);
        const ptr_val = llvm.LLVMGetParam(fn_val, 0);
        const idx_val = llvm.LLVMGetParam(fn_val, 1);
        const val_val = llvm.LLVMGetParam(fn_val, 2);
        const trunc = llvm.LLVMBuildTrunc(self.builder, val_val, i8_type, "trunc");
        var idx_args = [_]llvm.LLVMValueRef{idx_val};
        const elem_ptr = llvm.LLVMBuildGEP2(self.builder, i8_type, ptr_val, &idx_args, 1, "elem_ptr");
        _ = llvm.LLVMBuildStore(self.builder, trunc, elem_ptr);
        _ = llvm.LLVMBuildRetVoid(self.builder);
    }

    fn emitRandomBytesHelper(self: *LLVMEmitter, mod: llvm.LLVMModuleRef) !void {
        const ptr_type = llvm.LLVMPointerTypeInContext(self.context, 0);
        const i64_type = llvm.LLVMInt64TypeInContext(self.context);
        const void_type = llvm.LLVMVoidTypeInContext(self.context);

        var params = [_]llvm.LLVMTypeRef{ ptr_type, i64_type };
        const fn_type = llvm.LLVMFunctionType(void_type, &params, 2, 0);
        const fn_val = llvm.LLVMAddFunction(mod, "eiwa_random_bytes", fn_type);

        const entry = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        llvm.LLVMPositionBuilderAtEnd(self.builder, entry);
        const buf_val = llvm.LLVMGetParam(fn_val, 0);
        const len_val = llvm.LLVMGetParam(fn_val, 1);

        const rand_fn = llvm.LLVMGetNamedFunction(mod, "arc4random_buf") orelse blk: {
            var ps = [_]llvm.LLVMTypeRef{ ptr_type, i64_type };
            const ft = llvm.LLVMFunctionType(void_type, &ps, 2, 0);
            break :blk llvm.LLVMAddFunction(mod, "arc4random_buf", ft);
        };
        const rand_ft = llvm.LLVMGlobalGetValueType(rand_fn);
        var args = [_]llvm.LLVMValueRef{ buf_val, len_val };
        _ = llvm.LLVMBuildCall2(self.builder, rand_ft, rand_fn, &args, 2, "");
        _ = llvm.LLVMBuildRetVoid(self.builder);
    }

    /// Hand-emits the POSIX socket helpers used by `std.net`
    /// (eiwa_tcp_bind/accept, eiwa_socket_read/write, eiwa_tcp_set_nonblocking,
    /// eiwa_socket_close). These were `static inline` in the original C
    /// backend's net_helpers.h — that backend #included
    /// the header into generated code, but the LLVM module has no C to inject
    /// into and the JIT dylib never compiles the header, so the externs would
    /// resolve to null and crash on first call. Kept in sync with the C
    /// versions (sockaddr_in layout and fd/port are i32 at the C boundary,
    /// sign-extended to Eiwa's i64 Int).
    fn emitSocketHelpers(self: *LLVMEmitter, mod: llvm.LLVMModuleRef) !void {
        const ctx = self.context;
        const b = self.builder;
        const i64_t = llvm.LLVMInt64TypeInContext(ctx);
        const i32_t = llvm.LLVMInt32TypeInContext(ctx);
        const i8_t = llvm.LLVMInt8TypeInContext(ctx);
        const ptr_t = llvm.LLVMPointerTypeInContext(ctx, 0);
        const void_t = llvm.LLVMVoidTypeInContext(ctx);
        const arr16_t = llvm.LLVMArrayType(i8_t, 16);

        const is_macos = builtin.target.os.tag == .macos;
        const sol_socket: i64 = if (is_macos) 65535 else 1;
        const so_reuseaddr: i64 = if (is_macos) 4 else 2;
        const o_nonblock: i64 = if (is_macos) 4 else 2048;
        const fam_offset: i64 = if (is_macos) 1 else 0;

        const c0_32 = llvm.LLVMConstInt(i32_t, 0, 0);
        const c1_32 = llvm.LLVMConstInt(i32_t, 1, 0);
        const c2_32 = llvm.LLVMConstInt(i32_t, 2, 0);
        const c3_32 = llvm.LLVMConstInt(i32_t, 3, 0);
        const c4_32 = llvm.LLVMConstInt(i32_t, 4, 0);
        const c8_32 = llvm.LLVMConstInt(i32_t, 8, 0);
        const c10_32 = llvm.LLVMConstInt(i32_t, 10, 0);
        const c16_32 = llvm.LLVMConstInt(i32_t, 16, 0);
        const c16_64 = llvm.LLVMConstInt(i64_t, 16, 0);
        const neg1_64 = llvm.LLVMConstInt(i64_t, 0xffffffffffffffff, 1);

        var s3 = [_]llvm.LLVMTypeRef{ i32_t, i32_t, i32_t };
        var s5 = [_]llvm.LLVMTypeRef{ i32_t, i32_t, i32_t, ptr_t, i32_t };
        const socket_f = llvm.LLVMGetNamedFunction(mod, "socket") orelse llvm.LLVMAddFunction(mod, "socket", llvm.LLVMFunctionType(i32_t, &s3, 3, 0));
        const setsockopt_f = llvm.LLVMGetNamedFunction(mod, "setsockopt") orelse llvm.LLVMAddFunction(mod, "setsockopt", llvm.LLVMFunctionType(i32_t, &s5, 5, 0));
        const bind_f = llvm.LLVMGetNamedFunction(mod, "bind") orelse blk: {
            var ps = [_]llvm.LLVMTypeRef{ i32_t, ptr_t, i32_t };
            break :blk llvm.LLVMAddFunction(mod, "bind", llvm.LLVMFunctionType(i32_t, &ps, 3, 0));
        };
        const listen_f = llvm.LLVMGetNamedFunction(mod, "listen") orelse llvm.LLVMAddFunction(mod, "listen", llvm.LLVMFunctionType(i32_t, &s3, 2, 0));
        const accept_f = llvm.LLVMGetNamedFunction(mod, "accept") orelse blk: {
            var ps = [_]llvm.LLVMTypeRef{ i32_t, ptr_t, ptr_t };
            break :blk llvm.LLVMAddFunction(mod, "accept", llvm.LLVMFunctionType(i32_t, &ps, 3, 0));
        };
        const read_f = llvm.LLVMGetNamedFunction(mod, "read") orelse blk: {
            var ps = [_]llvm.LLVMTypeRef{ i32_t, ptr_t, i64_t };
            break :blk llvm.LLVMAddFunction(mod, "read", llvm.LLVMFunctionType(i64_t, &ps, 3, 0));
        };
        const write_f = llvm.LLVMGetNamedFunction(mod, "write") orelse blk: {
            var ps = [_]llvm.LLVMTypeRef{ i32_t, ptr_t, i64_t };
            break :blk llvm.LLVMAddFunction(mod, "write", llvm.LLVMFunctionType(i64_t, &ps, 3, 0));
        };
        const fcntl_f = llvm.LLVMGetNamedFunction(mod, "fcntl") orelse llvm.LLVMAddFunction(mod, "fcntl", llvm.LLVMFunctionType(i32_t, &s3, 3, 0));
        const close_f = llvm.LLVMGetNamedFunction(mod, "close") orelse blk: {
            var ps = [_]llvm.LLVMTypeRef{i32_t};
            break :blk llvm.LLVMAddFunction(mod, "close", llvm.LLVMFunctionType(i32_t, &ps, 1, 0));
        };
        const memset_f = llvm.LLVMGetNamedFunction(mod, "memset") orelse blk: {
            var ps = [_]llvm.LLVMTypeRef{ ptr_t, i32_t, i64_t };
            break :blk llvm.LLVMAddFunction(mod, "memset", llvm.LLVMFunctionType(ptr_t, &ps, 3, 0));
        };

        const socket_ft = llvm.LLVMGlobalGetValueType(socket_f);
        const setsockopt_ft = llvm.LLVMGlobalGetValueType(setsockopt_f);
        const bind_ft = llvm.LLVMGlobalGetValueType(bind_f);
        const listen_ft = llvm.LLVMGlobalGetValueType(listen_f);
        const accept_ft = llvm.LLVMGlobalGetValueType(accept_f);
        const read_ft = llvm.LLVMGlobalGetValueType(read_f);
        const write_ft = llvm.LLVMGlobalGetValueType(write_f);
        const fcntl_ft = llvm.LLVMGlobalGetValueType(fcntl_f);
        const close_ft = llvm.LLVMGlobalGetValueType(close_f);
        const memset_ft = llvm.LLVMGlobalGetValueType(memset_f);

        // eiwa_tcp_bind(i64 port) -> i64
        {
            var ps = [_]llvm.LLVMTypeRef{i64_t};
            const fn_t = llvm.LLVMFunctionType(i64_t, &ps, 1, 0);
            const func = llvm.LLVMGetNamedFunction(mod, "eiwa_tcp_bind") orelse llvm.LLVMAddFunction(mod, "eiwa_tcp_bind", fn_t);
            if (llvm.LLVMCountBasicBlocks(func) == 0) {
                const entry = llvm.LLVMAppendBasicBlockInContext(ctx, func, "entry");
                const sock_fail = llvm.LLVMAppendBasicBlockInContext(ctx, func, "sock_fail");
                const after_sock = llvm.LLVMAppendBasicBlockInContext(ctx, func, "after_sock");
                const bind_fail = llvm.LLVMAppendBasicBlockInContext(ctx, func, "bind_fail");
                const after_bind = llvm.LLVMAppendBasicBlockInContext(ctx, func, "after_bind");
                const listen_fail = llvm.LLVMAppendBasicBlockInContext(ctx, func, "listen_fail");
                const done = llvm.LLVMAppendBasicBlockInContext(ctx, func, "done");
                llvm.LLVMPositionBuilderAtEnd(b, entry);

                const port32 = llvm.LLVMBuildTrunc(b, llvm.LLVMGetParam(func, 0), i32_t, "port32");
                var sock_args = [_]llvm.LLVMValueRef{ c2_32, c1_32, c0_32 };
                const fd32 = llvm.LLVMBuildCall2(b, socket_ft, socket_f, &sock_args, 3, "fd");
                const fd_neg = llvm.LLVMBuildICmp(b, llvm.LLVMIntSLT, fd32, c0_32, "fd_neg");
                _ = llvm.LLVMBuildCondBr(b, fd_neg, sock_fail, after_sock);

                llvm.LLVMPositionBuilderAtEnd(b, sock_fail);
                _ = llvm.LLVMBuildRet(b, neg1_64);

                llvm.LLVMPositionBuilderAtEnd(b, after_sock);
                const opt_ptr = llvm.LLVMBuildAlloca(b, i32_t, "opt");
                _ = llvm.LLVMBuildStore(b, c1_32, opt_ptr);
                var ss_args = [_]llvm.LLVMValueRef{ fd32, llvm.LLVMConstInt(i32_t, sol_socket, 0), llvm.LLVMConstInt(i32_t, so_reuseaddr, 0), opt_ptr, c4_32 };
                _ = llvm.LLVMBuildCall2(b, setsockopt_ft, setsockopt_f, &ss_args, 5, "");

                const addr_ptr = llvm.LLVMBuildArrayAlloca(b, i8_t, c16_64, "sockaddr");
                var m_args = [_]llvm.LLVMValueRef{ addr_ptr, c0_32, c16_64 };
                _ = llvm.LLVMBuildCall2(b, memset_ft, memset_f, &m_args, 3, "");

                var fam_idx = [_]llvm.LLVMValueRef{ llvm.LLVMConstInt(i64_t, 0, 0), llvm.LLVMConstInt(i64_t, fam_offset, 0) };
                const fam_ptr = llvm.LLVMBuildGEP2(b, arr16_t, addr_ptr, &fam_idx, 2, "fam");
                _ = llvm.LLVMBuildStore(b, llvm.LLVMBuildTrunc(b, c2_32, i8_t, "fam8"), fam_ptr);

                const port_lo = llvm.LLVMBuildTrunc(b, port32, i8_t, "port_lo");
                const port_hi = llvm.LLVMBuildTrunc(b, llvm.LLVMBuildLShr(b, port32, c8_32, "sh"), i8_t, "port_hi");
                // sockaddr_in.sin_port is big-endian (network order): the high
                // byte goes at offset 2 and the low byte at offset 3.
                var lo_idx = [_]llvm.LLVMValueRef{ llvm.LLVMConstInt(i64_t, 0, 0), llvm.LLVMConstInt(i64_t, 2, 0) };
                var hi_idx = [_]llvm.LLVMValueRef{ llvm.LLVMConstInt(i64_t, 0, 0), llvm.LLVMConstInt(i64_t, 3, 0) };
                _ = llvm.LLVMBuildStore(b, port_hi, llvm.LLVMBuildGEP2(b, arr16_t, addr_ptr, &lo_idx, 2, "plo"));
                _ = llvm.LLVMBuildStore(b, port_lo, llvm.LLVMBuildGEP2(b, arr16_t, addr_ptr, &hi_idx, 2, "phi"));

                var b_args = [_]llvm.LLVMValueRef{ fd32, addr_ptr, c16_32 };
                const bres = llvm.LLVMBuildCall2(b, bind_ft, bind_f, &b_args, 3, "bindres");
                const b_neg = llvm.LLVMBuildICmp(b, llvm.LLVMIntSLT, bres, c0_32, "b_neg");
                _ = llvm.LLVMBuildCondBr(b, b_neg, bind_fail, after_bind);

                llvm.LLVMPositionBuilderAtEnd(b, bind_fail);
                var c_args = [_]llvm.LLVMValueRef{fd32};
                _ = llvm.LLVMBuildCall2(b, close_ft, close_f, &c_args, 1, "");
                _ = llvm.LLVMBuildRet(b, neg1_64);

                llvm.LLVMPositionBuilderAtEnd(b, after_bind);
                var l_args = [_]llvm.LLVMValueRef{ fd32, c10_32 };
                const lres = llvm.LLVMBuildCall2(b, listen_ft, listen_f, &l_args, 2, "listenres");
                const l_neg = llvm.LLVMBuildICmp(b, llvm.LLVMIntSLT, lres, c0_32, "l_neg");
                _ = llvm.LLVMBuildCondBr(b, l_neg, listen_fail, done);

                llvm.LLVMPositionBuilderAtEnd(b, listen_fail);
                var c2_args = [_]llvm.LLVMValueRef{fd32};
                _ = llvm.LLVMBuildCall2(b, close_ft, close_f, &c2_args, 1, "");
                _ = llvm.LLVMBuildRet(b, neg1_64);

                llvm.LLVMPositionBuilderAtEnd(b, done);
                _ = llvm.LLVMBuildRet(b, llvm.LLVMBuildSExt(b, fd32, i64_t, "fd64"));
            }
        }

        // eiwa_tcp_accept(i64 fd) -> i64
        {
            var ps = [_]llvm.LLVMTypeRef{i64_t};
            const fn_t = llvm.LLVMFunctionType(i64_t, &ps, 1, 0);
            const func = llvm.LLVMGetNamedFunction(mod, "eiwa_tcp_accept") orelse llvm.LLVMAddFunction(mod, "eiwa_tcp_accept", fn_t);
            if (llvm.LLVMCountBasicBlocks(func) == 0) {
                const entry = llvm.LLVMAppendBasicBlockInContext(ctx, func, "entry");
                llvm.LLVMPositionBuilderAtEnd(b, entry);
                const fd32 = llvm.LLVMBuildTrunc(b, llvm.LLVMGetParam(func, 0), i32_t, "fd32");
                const addr_ptr = llvm.LLVMBuildArrayAlloca(b, i8_t, c16_64, "addr");
                const len_ptr = llvm.LLVMBuildAlloca(b, i32_t, "addrlen");
                _ = llvm.LLVMBuildStore(b, c16_32, len_ptr);
                var a_args = [_]llvm.LLVMValueRef{ fd32, addr_ptr, len_ptr };
                const res32 = llvm.LLVMBuildCall2(b, accept_ft, accept_f, &a_args, 3, "accepted");
                _ = llvm.LLVMBuildRet(b, llvm.LLVMBuildSExt(b, res32, i64_t, "fd64"));
            }
        }

        // eiwa_socket_read(i64 fd, ptr buf, i64 max_len) -> i64
        {
            var ps = [_]llvm.LLVMTypeRef{ i64_t, ptr_t, i64_t };
            const fn_t = llvm.LLVMFunctionType(i64_t, &ps, 3, 0);
            const func = llvm.LLVMGetNamedFunction(mod, "eiwa_socket_read") orelse llvm.LLVMAddFunction(mod, "eiwa_socket_read", fn_t);
            if (llvm.LLVMCountBasicBlocks(func) == 0) {
                const entry = llvm.LLVMAppendBasicBlockInContext(ctx, func, "entry");
                llvm.LLVMPositionBuilderAtEnd(b, entry);
                const fd32 = llvm.LLVMBuildTrunc(b, llvm.LLVMGetParam(func, 0), i32_t, "fd32");
                var r_args = [_]llvm.LLVMValueRef{ fd32, llvm.LLVMGetParam(func, 1), llvm.LLVMGetParam(func, 2) };
                const res = llvm.LLVMBuildCall2(b, read_ft, read_f, &r_args, 3, "nread");
                _ = llvm.LLVMBuildRet(b, res);
            }
        }

        // eiwa_socket_write(i64 fd, ptr data, i64 len) -> i64
        {
            var ps = [_]llvm.LLVMTypeRef{ i64_t, ptr_t, i64_t };
            const fn_t = llvm.LLVMFunctionType(i64_t, &ps, 3, 0);
            const func = llvm.LLVMGetNamedFunction(mod, "eiwa_socket_write") orelse llvm.LLVMAddFunction(mod, "eiwa_socket_write", fn_t);
            if (llvm.LLVMCountBasicBlocks(func) == 0) {
                const entry = llvm.LLVMAppendBasicBlockInContext(ctx, func, "entry");
                llvm.LLVMPositionBuilderAtEnd(b, entry);
                const fd32 = llvm.LLVMBuildTrunc(b, llvm.LLVMGetParam(func, 0), i32_t, "fd32");
                var w_args = [_]llvm.LLVMValueRef{ fd32, llvm.LLVMGetParam(func, 1), llvm.LLVMGetParam(func, 2) };
                const res = llvm.LLVMBuildCall2(b, write_ft, write_f, &w_args, 3, "nwritten");
                _ = llvm.LLVMBuildRet(b, res);
            }
        }

        // eiwa_tcp_set_nonblocking(i64 fd) -> i64
        {
            var ps = [_]llvm.LLVMTypeRef{i64_t};
            const fn_t = llvm.LLVMFunctionType(i64_t, &ps, 1, 0);
            const func = llvm.LLVMGetNamedFunction(mod, "eiwa_tcp_set_nonblocking") orelse llvm.LLVMAddFunction(mod, "eiwa_tcp_set_nonblocking", fn_t);
            if (llvm.LLVMCountBasicBlocks(func) == 0) {
                const entry = llvm.LLVMAppendBasicBlockInContext(ctx, func, "entry");
                const fail_bb = llvm.LLVMAppendBasicBlockInContext(ctx, func, "fail");
                const done = llvm.LLVMAppendBasicBlockInContext(ctx, func, "done");
                llvm.LLVMPositionBuilderAtEnd(b, entry);
                const fd32 = llvm.LLVMBuildTrunc(b, llvm.LLVMGetParam(func, 0), i32_t, "fd32");
                var g_args = [_]llvm.LLVMValueRef{ fd32, c3_32, c0_32 };
                const flags = llvm.LLVMBuildCall2(b, fcntl_ft, fcntl_f, &g_args, 3, "flags");
                const fl_neg = llvm.LLVMBuildICmp(b, llvm.LLVMIntSLT, flags, c0_32, "fl_neg");
                _ = llvm.LLVMBuildCondBr(b, fl_neg, fail_bb, done);

                llvm.LLVMPositionBuilderAtEnd(b, fail_bb);
                _ = llvm.LLVMBuildRet(b, neg1_64);

                llvm.LLVMPositionBuilderAtEnd(b, done);
                const newflags = llvm.LLVMBuildOr(b, flags, llvm.LLVMConstInt(i32_t, o_nonblock, 0), "newflags");
                var s_args = [_]llvm.LLVMValueRef{ fd32, c4_32, newflags };
                const res32 = llvm.LLVMBuildCall2(b, fcntl_ft, fcntl_f, &s_args, 3, "setres");
                _ = llvm.LLVMBuildRet(b, llvm.LLVMBuildSExt(b, res32, i64_t, "res64"));
            }
        }

        // eiwa_socket_close(i64 fd) -> void
        {
            var ps = [_]llvm.LLVMTypeRef{i64_t};
            const fn_t = llvm.LLVMFunctionType(void_t, &ps, 1, 0);
            const func = llvm.LLVMGetNamedFunction(mod, "eiwa_socket_close") orelse llvm.LLVMAddFunction(mod, "eiwa_socket_close", fn_t);
            if (llvm.LLVMCountBasicBlocks(func) == 0) {
                const entry = llvm.LLVMAppendBasicBlockInContext(ctx, func, "entry");
                llvm.LLVMPositionBuilderAtEnd(b, entry);
                const fd32 = llvm.LLVMBuildTrunc(b, llvm.LLVMGetParam(func, 0), i32_t, "fd32");
                var c_args = [_]llvm.LLVMValueRef{fd32};
                _ = llvm.LLVMBuildCall2(b, close_ft, close_f, &c_args, 1, "");
                _ = llvm.LLVMBuildRetVoid(b);
            }
        }
    }

        fn emitNowMillisHelper(self: *LLVMEmitter, mod: llvm.LLVMModuleRef) !void {
        const ptr_type = llvm.LLVMPointerTypeInContext(self.context, 0);
        const i64_type = llvm.LLVMInt64TypeInContext(self.context);

        const fn_type = llvm.LLVMFunctionType(i64_type, null, 0, 0);
        const fn_val = llvm.LLVMAddFunction(mod, "eiwa_now_millis", fn_type);

        const entry = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        llvm.LLVMPositionBuilderAtEnd(self.builder, entry);

        const time_fn = llvm.LLVMGetNamedFunction(mod, "time") orelse blk: {
            var ps = [_]llvm.LLVMTypeRef{ptr_type};
            const ft = llvm.LLVMFunctionType(i64_type, &ps, 1, 0);
            break :blk llvm.LLVMAddFunction(mod, "time", ft);
        };
        const time_ft = llvm.LLVMGlobalGetValueType(time_fn);
        var args = [_]llvm.LLVMValueRef{llvm.LLVMConstNull(ptr_type)};
        const sec = llvm.LLVMBuildCall2(self.builder, time_ft, time_fn, &args, 1, "sec");
        const millis = llvm.LLVMBuildMul(self.builder, sec, llvm.LLVMConstInt(i64_type, 1000, 0), "millis");
        _ = llvm.LLVMBuildRet(self.builder, millis);
    }

    fn declareLib(self: *LLVMEmitter, mod: llvm.LLVMModuleRef, lib_node: *ast.ASTNode, module_path: ?[]const u8) !void {
        const lib = lib_node.data.lib_decl;

        // Collect build requirements from lib annotations so the backend can
        // compile and link the vendored C sources (mirrors the C transpiler,
        // Phase 65). `@Header` only matters for the C transpiler's generated
        // code; the LLVM module has no C to inject includes into.
        for (lib.annotations) |ann| {
            if (std.mem.eql(u8, ann.name, "Link")) {
                for (ann.arguments) |arg| try self.link_libraries.put(arg, {});
            } else if (std.mem.eql(u8, ann.name, "Source")) {
                for (ann.arguments) |arg| {
                    // `./`/`../` resolve relative to the importing .ei file (like
                    // @Include); anything else goes through resolveRepoPath
                    // (maps `src/...` to the compiler repo).
                    if ((std.mem.startsWith(u8, arg, "./") or std.mem.startsWith(u8, arg, "../"))) {
                        const base = module_path orelse self.source_file;
                        const dir = std.fs.path.dirname(base) orelse ".";
                        try self.c_sources.put(try std.fs.path.join(self.allocator, &.{ dir, arg }), {});
                    } else {
                        try self.c_sources.put(try resolveRepoPath(self.allocator, arg), {});
                    }
                }
            } else if (std.mem.eql(u8, ann.name, "Include")) {
                for (ann.arguments) |arg| {
                    if ((std.mem.startsWith(u8, arg, "./") or std.mem.startsWith(u8, arg, "../"))) {
                        const base = module_path orelse self.source_file;
                        const dir = std.fs.path.dirname(base) orelse ".";
                        try self.c_includes.put(try std.fs.path.join(self.allocator, &.{ dir, arg }), {});
                    } else {
                        try self.c_includes.put(try resolveRepoPath(self.allocator, arg), {});
                    }
                }
            } else if (std.mem.eql(u8, ann.name, "Define")) {
                for (ann.arguments) |arg| try self.c_defines.put(arg, {});
            }
        }

        var func_names = std.StringHashMap([]const u8).init(self.allocator);
        for (lib.functions) |func_node| {
            if (func_node.data == .fun_decl) {
                const f = func_node.data.fun_decl;
                // Lib functions map to their C symbol, optionally via @Alias("...").
                var c_name: []const u8 = f.name;
                if (std.mem.eql(u8, f.name, "abs")) {
                    c_name = "labs";
                }
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

        // A varargs parameter (`T...`) maps to the C `...` tail: it is not a
        // fixed parameter, but makes the declared function variadic (Phase 66).
        const has_vararg = f.params.len > 0 and f.params[f.params.len - 1].is_varargs;
        const fixed_count = if (has_vararg) f.params.len - 1 else f.params.len;

        const ptr_type_def = llvm.LLVMPointerTypeInContext(self.context, 0);
        var param_types = try self.allocator.alloc(llvm.LLVMTypeRef, fixed_count);
        defer self.allocator.free(param_types);

        var ret_type: llvm.LLVMTypeRef = ptr_type_def;

        if (func_node.resolved_type) |rt| {
            if (rt.* == .Function) {
                ret_type = types_mapping.getLLVMTypeWithContracts(self.context, rt.Function.return_type.*, self.contracts_ast);
                for (0..fixed_count) |i| {
                    if (i < rt.Function.params.len) {
                        param_types[i] = types_mapping.getLLVMTypeWithContracts(self.context, rt.Function.params[i].*, self.contracts_ast);
                    } else {
                        param_types[i] = ptr_type_def;
                    }
                }
            }
        } else if (f.type_ref) |tr| {
            // Lib functions carry their resolved types on the type_refs
            // (inferLibDecl resolves them, but leaves func_node.resolved_type unset).
            if (tr.resolved_type) |rrt| {
                ret_type = types_mapping.getLLVMType(self.context, rrt.*);
            }
            for (0..fixed_count) |i| {
                const p = f.params[i];
                if (p.type_ref) |ptr| {
                    if (ptr.resolved_type) |prt| {
                        param_types[i] = types_mapping.getLLVMType(self.context, prt.*);
                        continue;
                    }
                    param_types[i] = types_mapping.getLLVMTypeWithContracts(self.context, ts.EiwaType{ .Custom = ptr.name }, self.contracts_ast);
                    continue;
                }
                param_types[i] = ptr_type_def;
            }
        } else {
            for (0..fixed_count) |i| {
                const p = f.params[i];
                if (p.type_ref) |ptr| {
                    if (ptr.resolved_type) |prt| {
                        param_types[i] = types_mapping.getLLVMType(self.context, prt.*);
                        continue;
                    }
                    param_types[i] = types_mapping.getLLVMTypeWithContracts(self.context, ts.EiwaType{ .Custom = ptr.name }, self.contracts_ast);
                    continue;
                }
                param_types[i] = ptr_type_def;
            }
        }

        const func_type = llvm.LLVMFunctionType(ret_type, if (param_types.len > 0) param_types.ptr else null, @intCast(param_types.len), if (has_vararg) 1 else 0);

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
        const name = if (t.resolved_c_name) |rcn| (if (rcn.len > 0) rcn else t.name) else t.name;

        const struct_name_z = try self.allocator.dupeZ(u8, name);
        defer self.allocator.free(struct_name_z);

        const struct_type = llvm.LLVMStructCreateNamed(self.context, struct_name_z.ptr);

        var field_names = ArrayList([]const u8).init(self.allocator);
        var field_types = ArrayList(llvm.LLVMTypeRef).init(self.allocator);

        for (t.primary_constructor) |prop| {
            try field_names.append(prop.name);
            const ptr_type_fallback = llvm.LLVMPointerTypeInContext(self.context, 0);
            if (prop.is_boxed) {
                // Boxed capture: the field stores a pointer to the shared heap
                // value cell (mutable capture propagating to the outer var).
                try field_types.append(ptr_type_fallback);
                continue;
            }
            const f_llvm_type = if (prop.resolved_type) |rt|
                types_mapping.getLLVMTypeWithContracts(self.context, rt.*, self.contracts_ast)
            else blk: {
                if (self.contracts_ast) |ca| {
                    const tr = prop.type_ref;
                    var tr_short = tr.name;
                    if (std.mem.lastIndexOfScalar(u8, tr.name, '_')) |sidx| {
                        tr_short = tr.name[sidx + 1 ..];
                    }
                    if (ca.contains(tr.name) or ca.contains(tr_short) or
                        std.mem.endsWith(u8, tr_short, "Writer") or
                        std.mem.endsWith(u8, tr_short, "Formatter") or
                        std.mem.endsWith(u8, tr_short, "able") or
                        std.mem.endsWith(u8, tr_short, "Opt") or
                        std.mem.endsWith(u8, tr_short, "Contract"))
                    {
                        break :blk types_mapping.getFatPointerType(self.context);
                    }
                }
                break :blk ptr_type_fallback;
            };
            try field_types.append(f_llvm_type);
        }

        // Body fields (declared in the type body, not ctor args) are part of
        // the struct layout but NOT constructor parameters. Their initializers
        // are evaluated in the ctor body (see below).
        for (t.body_fields) |prop| {
            try field_names.append(prop.name);
            const f_llvm_type = if (prop.resolved_type) |rt|
                types_mapping.getLLVMTypeWithContracts(self.context, rt.*, self.contracts_ast)
            else
                llvm.LLVMPointerTypeInContext(self.context, 0);
            try field_types.append(f_llvm_type);
        }
        const ctor_param_count = t.primary_constructor.len;

        llvm.LLVMStructSetBody(struct_type, if (field_types.items.len > 0) field_types.items.ptr else null, @intCast(field_types.items.len), 0);

        const field_names_owned = try field_names.toOwnedSlice();
        const field_types_owned = try field_types.toOwnedSlice();

        try self.structs.put(name, .{
            .struct_type = struct_type,
            .field_names = field_names_owned,
            .field_types = field_types_owned,
        });
        if (verbose) std.debug.print(">>> REGISTER_STRUCT: name='{s}'\n", .{name});
        if (!std.mem.eql(u8, name, t.name)) {
            try self.structs.put(t.name, .{
                .struct_type = struct_type,
                .field_names = field_names_owned,
                .field_types = field_types_owned,
            });
            if (verbose) std.debug.print(">>> REGISTER_STRUCT_SHORT: name='{s}'\n", .{t.name});
        }

        // Declare constructor function: name(primary ctor params...) -> ptr.
        // Body fields are NOT parameters — they are initialized in the ctor.
        const ptr_type = llvm.LLVMPointerTypeInContext(self.context, 0);
        const ctor_param_types = field_types_owned[0..ctor_param_count];
        const ctor_type = llvm.LLVMFunctionType(ptr_type, if (ctor_param_types.len > 0) ctor_param_types.ptr else null, @intCast(ctor_param_types.len), 0);

        const ctor_val = llvm.LLVMAddFunction(mod, struct_name_z.ptr, ctor_type);
        try self.functions.put(name, ctor_val);

        // Emit constructor body
        const entry_block = llvm.LLVMAppendBasicBlockInContext(self.context, ctor_val, "entry");
        llvm.LLVMPositionBuilderAtEnd(self.builder, entry_block);

        // Allocate the instance via the active heap allocator (GC_malloc when
        // prefer_gc_alloc, malloc otherwise).
        // TODO(emitter): the fixed 128-byte allocation below should be the
        // struct's actual byte size (LLVMStoreSizeOfType), not a hardcoded
        // upper bound.
        const gc_func = getHeapAllocFn(mod);
        const gc_func_type = llvm.LLVMGlobalGetValueType(gc_func);
        const size_val = llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(self.context), 128, 0);
        var gc_args = [_]llvm.LLVMValueRef{size_val};
        const raw_ptr = llvm.LLVMBuildCall2(self.builder, gc_func_type, gc_func, &gc_args, 1, "raw_inst");

        // Store constructor parameters into struct fields
        for (0..ctor_param_count) |idx| {
            var param_val = llvm.LLVMGetParam(ctor_val, @intCast(idx));
            if (idx < field_types_owned.len) {
                const field_type = field_types_owned[idx];
                const p_type = llvm.LLVMTypeOf(param_val);
                if (llvm.LLVMGetTypeKind(p_type) == llvm.LLVMIntegerTypeKind and llvm.LLVMGetTypeKind(field_type) == llvm.LLVMIntegerTypeKind) {
                    const p_bits = llvm.LLVMGetIntTypeWidth(p_type);
                    const f_bits = llvm.LLVMGetIntTypeWidth(field_type);
                    if (p_bits < f_bits) {
                        param_val = llvm.LLVMBuildZExt(self.builder, param_val, field_type, "zext_ctor_param");
                    } else if (p_bits > f_bits) {
                        param_val = llvm.LLVMBuildTrunc(self.builder, param_val, field_type, "trunc_ctor_param");
                    }
                }
            }
            const field_ptr = llvm.LLVMBuildStructGEP2(self.builder, struct_type, raw_ptr, @intCast(idx), "field_gep");
            _ = llvm.LLVMBuildStore(self.builder, param_val, field_ptr);
        }

        // Evaluate body-field initializers in declaration order with `this`
        // bound to the freshly allocated instance, storing into each field.
        // Constructor fields are also bound (by their names) so an initializer
        // can reference ctor params/properties, Kotlin-style.
        if (t.body_fields.len > 0) {
            var this_scope = std.StringHashMap(llvm.LLVMValueRef).init(self.allocator);
            defer this_scope.deinit();
            const this_z = try self.allocator.dupeZ(u8, "this");
            defer self.allocator.free(this_z);
            const this_alloca = llvm.LLVMBuildAlloca(self.builder, ptr_type, this_z.ptr);
            _ = llvm.LLVMBuildStore(self.builder, raw_ptr, this_alloca);
            try this_scope.put("this", this_alloca);

            for (t.primary_constructor, 0..) |prop, i| {
                const p_name_z = try self.allocator.dupeZ(u8, prop.name);
                defer self.allocator.free(p_name_z);
                const field_ptr = llvm.LLVMBuildStructGEP2(self.builder, struct_type, raw_ptr, @intCast(i), p_name_z.ptr);
                const field_t = field_types_owned[i];
                const val = llvm.LLVMBuildLoad2(self.builder, field_t, field_ptr, "ctor_field_load");
                const alloca_ptr = llvm.LLVMBuildAlloca(self.builder, field_t, p_name_z.ptr);
                _ = llvm.LLVMBuildStore(self.builder, val, alloca_ptr);
                try this_scope.put(prop.name, alloca_ptr);
            }

            for (t.body_fields, 0..) |prop, i| {
                const init_node = prop.initializer orelse continue;
                const field_idx = ctor_param_count + i;
                const field_type = field_types_owned[field_idx];
                var init_val = try expression.emitExpression(self.context, mod, self.builder, &this_scope, &self.structs, &self.libs, init_node);
                if (llvm.LLVMTypeOf(init_val) != field_type) {
                    init_val = expression.coerceArg(self.builder, init_val, field_type);
                }
                const field_ptr = llvm.LLVMBuildStructGEP2(self.builder, struct_type, raw_ptr, @intCast(field_idx), "bfield_gep");
                _ = llvm.LLVMBuildStore(self.builder, init_val, field_ptr);
            }
        }

        _ = llvm.LLVMBuildRet(self.builder, raw_ptr);

        // Pass 1a2: Emit member methods inside type
        for (t.methods) |m_node| {
            if (m_node.data == .fun_decl) {
                if (m_node.data.fun_decl.generic_params.len > 0) continue;
                try self.declareFunction(mod, m_node, false);
            }
        }
    }

    fn isStructReceiver(self: *LLVMEmitter, rec_opt: ?*const ts.EiwaType) bool {
        const rec = rec_opt orelse return false;
        const base = ts.extractBaseType(rec);
        const rec_name = switch (base.*) {
            .Custom => |n| n,
            .GenericInstance => |gi| gi.base_name,
            else => return false,
        };
        if (self.structs.contains(rec_name)) return true;
        const suffix = std.fmt.allocPrint(self.allocator, "_{s}", .{rec_name}) catch return false;
        defer self.allocator.free(suffix);
        var it = self.structs.keyIterator();
        while (it.next()) |k| {
            if (std.mem.endsWith(u8, k.*, suffix) or std.mem.eql(u8, k.*, rec_name)) return true;
        }
        return false;
    }

    fn declareFunction(self: *LLVMEmitter, mod: llvm.LLVMModuleRef, func_node: *ast.ASTNode, is_object_method: bool) !void {
        const f = func_node.data.fun_decl;
        var name = f.resolved_c_name orelse f.name;
        if (is_object_method or (func_node.resolved_type != null and func_node.resolved_type.?.* == .Function and func_node.resolved_type.?.Function.receiver != null)) {
            if (f.resolved_c_name == null or std.mem.eql(u8, name, "toString") or std.mem.eql(u8, name, "hashCode") or std.mem.eql(u8, name, "equals")) {
                if (func_node.resolved_type) |rt| {
                    if (rt.* == .Function and rt.Function.receiver != null) {
                        const rec_t = ts.extractBaseType(rt.Function.receiver.?);
                        const rec_name = switch (rec_t.*) {
                            .Custom => |cn| cn,
                            .String => "core_String",
                            .Int => "core_Int",
                            .Double => "core_Double",
                            .Bool => "core_Bool",
                            else => "type",
                        };
                        name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ rec_name, f.name });
                    }
                }
            }
        }

        // Methods bind the receiver (`this`) as the leading parameter (not an
        // object method). Any instance method with a receiver takes `this`,
        // including primitive receivers (String/Int/Bool/Double) — gating this
        // on `isStructReceiver` dropped the receiver for those and produced a
        // zero-arg/stubbed hashCode etc.
        const has_rec = if (is_object_method) false else (if (func_node.resolved_type) |rt|
            (if (rt.* == .Function) rt.Function.receiver != null else false)
        else
            false);

        const param_count: usize = f.params.len + @intFromBool(has_rec);
        var param_types = try self.allocator.alloc(llvm.LLVMTypeRef, param_count);
        defer self.allocator.free(param_types);

        const ptr_type_def = llvm.LLVMPointerTypeInContext(self.context, 0);
        var ret_type: llvm.LLVMTypeRef = ptr_type_def;

        if (func_node.resolved_type) |rt| {
            if (rt.* == .Function) {
                ret_type = types_mapping.getLLVMTypeWithContracts(self.context, rt.Function.return_type.*, self.contracts_ast);
                var param_idx: usize = 0;
                if (has_rec) {
                    param_types[0] = types_mapping.getLLVMTypeWithContracts(self.context, rt.Function.receiver.?.*, self.contracts_ast);
                    param_idx = 1;
                }
                for (f.params, 0..) |_, i| {
                    if (i < rt.Function.params.len) {
                        param_types[param_idx] = types_mapping.getLLVMTypeWithContracts(self.context, rt.Function.params[i].*, self.contracts_ast);
                    } else {
                        param_types[param_idx] = ptr_type_def;
                    }
                    param_idx += 1;
                }
            } else {
                ret_type = types_mapping.getLLVMTypeWithContracts(self.context, rt.*, self.contracts_ast);
                for (f.params, 0..) |_, i| {
                    param_types[i] = ptr_type_def;
                }
            }
        } else {
            for (f.params, 0..) |_, i| {
                param_types[i] = ptr_type_def;
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

    fn emitFunctionBody(self: *LLVMEmitter, mod: llvm.LLVMModuleRef, func_node: *ast.ASTNode, _is_object_method: bool) !void {
        _ = _is_object_method;
        const f = func_node.data.fun_decl;
        // Check if function is an external prototype without body
        if (f.body.data == .block and f.body.data.block.statements.len == 0) return;

        const name = f.resolved_c_name orelse f.name;
        const func_val = self.functions.get(name) orelse return error.FunctionNotFound;

        const entry_block = llvm.LLVMAppendBasicBlockInContext(self.context, func_val, "entry");
        llvm.LLVMPositionBuilderAtEnd(self.builder, entry_block);

        var scope = std.StringHashMap(llvm.LLVMValueRef).init(self.allocator);
        defer scope.deinit();

        const total_param_count = llvm.LLVMCountParams(func_val);
        var param_base: usize = 0;
        if (total_param_count > f.params.len) {
            const this_val = llvm.LLVMGetParam(func_val, 0);
            const this_type = llvm.LLVMTypeOf(this_val);
            const this_z = try self.allocator.dupeZ(u8, "this");
            defer self.allocator.free(this_z);
            const this_ptr = llvm.LLVMBuildAlloca(self.builder, this_type, this_z.ptr);
            _ = llvm.LLVMBuildStore(self.builder, this_val, this_ptr);
            try scope.put("this", this_ptr);
            param_base = 1;
        }

        // Allocate and store parameters in local scope
        for (f.params, 0..) |p, i| {
            const param_val = llvm.LLVMGetParam(func_val, @intCast(i + param_base));
            const param_type = llvm.LLVMTypeOf(param_val);

            const p_name_z = try self.allocator.dupeZ(u8, p.name);
            defer self.allocator.free(p_name_z);

            const p_llvm_type = if (p.type_ref) |tr| (if (tr.resolved_type) |rt| (if (types_mapping.isContractType(rt.*, expression.global_contracts_ast_ptr)) types_mapping.getFatPointerType(self.context) else param_type) else param_type) else param_type;
            const alloca_ptr = llvm.LLVMBuildAlloca(self.builder, p_llvm_type, p_name_z.ptr);
            _ = llvm.LLVMBuildStore(self.builder, param_val, alloca_ptr);
            try scope.put(p.name, alloca_ptr);
        }

        // Expression-bodied functions (`fun f(...) = expr`) return the value directly.
        if (f.is_expr_body) {
            var ret_val = try expression.emitExpression(self.context, mod, self.builder, &scope, &self.structs, &self.libs, f.body);
            const func_type = llvm.LLVMGlobalGetValueType(func_val);
            const expected_ret_type = llvm.LLVMGetReturnType(func_type);
            if (llvm.LLVMGetTypeKind(expected_ret_type) == llvm.LLVMVoidTypeKind) {
                _ = llvm.LLVMBuildRetVoid(self.builder);
            } else {
                // A contract return type is a Fat Pointer — coerce the concrete
                // value with its real vtable, otherwise coerceArg would attach a
                // null vtable. The declared return type pins the exact contract
                // (deterministic vtable lookup).
                const fat_type = types_mapping.getFatPointerType(self.context);
                if (expected_ret_type == fat_type and llvm.LLVMTypeOf(ret_val) != fat_type) {
                    var ret_contract: []const u8 = "";
                    if (f.type_ref) |tr| {
                        if (tr.resolved_type) |rt| {
                            ret_contract = switch (ts.extractBaseType(rt).*) {
                                .Custom => |n| n,
                                else => "",
                            };
                        }
                    }
                    if (f.body.resolved_type) |val_rt| {
                        const val_c_name = switch (ts.extractBaseType(val_rt).*) {
                            .Custom => |n| n,
                            .GenericInstance => |gi| gi.base_name,
                            else => "",
                        };
                        if (val_c_name.len > 0) {
                            ret_val = expression.coerceToContract(self.context, mod, self.builder, ret_val, val_c_name, ret_contract) catch ret_val;
                        }
                    }
                }
                if (llvm.LLVMTypeOf(ret_val) != expected_ret_type) {
                    ret_val = expression.coerceArg(self.builder, ret_val, expected_ret_type);
                }
                _ = llvm.LLVMBuildRet(self.builder, ret_val);
            }
            return;
        }

        const declared_ret: ?*const ts.EiwaType = if (f.type_ref) |tr| tr.resolved_type else null;
        try statement.emitStatement(self.context, mod, self.builder, func_val, &scope, &self.structs, &self.libs, f.body, declared_ret);

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
            } else if (kind == llvm.LLVMPointerTypeKind or kind == llvm.LLVMStructTypeKind) {
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

    /// Picks the C compiler/linker driver for the native link / shared-lib
    /// steps. Prefers the system compiler (`cc`/`clang`/`gcc`) so `eiwac`
    /// does not hard-require zig at runtime; `zig cc` is only a fallback when
    /// no system compiler is on PATH. The whole point of the LLVM backend is
    /// to avoid extra toolchain deps — a plain C compiler is enough to link.
    fn pickLinkDriver(self: *LLVMEmitter, io: std.Io) []const u8 {
        const candidates = [_][]const u8{ "cc", "clang", "gcc", "zig" };
        for (candidates) |name| {
            if (self.executableOnPath(io, name)) return name;
        }
        return "cc";
    }

    fn executableOnPath(self: *LLVMEmitter, io: std.Io, name: []const u8) bool {
        const path_env = (std.c.getenv("PATH") orelse return false);
        var it = std.mem.splitScalar(u8, std.mem.span(path_env), ':');
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            const full = std.fs.path.join(self.allocator, &.{ dir, name }) catch continue;
            const found = blk: {
                std.Io.Dir.cwd().access(io, full, .{}) catch break :blk false;
                break :blk true;
            };
            self.allocator.free(full);
            if (found) return true;
        }
        return false;
    }

    /// Appends the `<driver>` prefix for a link/compile invocation: `zig cc`
    /// takes the subcommand, the system compilers are invoked directly.
    fn appendLinkDriverPrefix(argv: *ArrayList([]const u8), driver: []const u8) !void {
        if (std.mem.eql(u8, driver, "zig")) {
            try argv.appendSlice(&[_][]const u8{ "zig", "cc" });
        } else {
            try argv.append(driver);
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

        // Host CPU tuning by default; set EIWA_BASELINE_CPU=1 to emit a
        // portable binary (baseline x86_64/arm64, no host-only features like
        // AVX-512). Needed so releases built on modern CI runners keep working
        // on older CPUs / emulators (e.g. Rosetta 2, which lacks AVX-512).
        const use_host_cpu = std.c.getenv("EIWA_BASELINE_CPU") == null;
        var cpu: [*c]const u8 = "";
        var features: [*c]const u8 = "";
        if (use_host_cpu) {
            cpu = llvm.LLVMGetHostCPUName();
            features = llvm.LLVMGetHostCPUFeatures();
        }
        defer if (use_host_cpu) llvm.LLVMDisposeMessage(@ptrCast(@constCast(cpu)));

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

        // Link object file into native binary. Prefers the system C compiler
        // (no zig required at runtime); falls back to `zig cc` when no system
        // compiler is on PATH.
        const link_driver = self.pickLinkDriver(io);
        var cc_argv = ArrayList([]const u8).init(self.allocator);
        defer cc_argv.deinit();

        const opt_flag = if (self.is_release) "-O3" else "-O0";
        try appendLinkDriverPrefix(&cc_argv, link_driver);
        try cc_argv.appendSlice(&[_][]const u8{ opt_flag, "-fwrapv" });
        if (builtin.target.os.tag == .macos) {
            const brew = if (builtin.target.cpu.arch == .aarch64) "/opt/homebrew" else "/usr/local";
            try cc_argv.appendSlice(&[_][]const u8{ "-I", brew ++ "/include", "-L", brew ++ "/lib" });
        }
        try cc_argv.appendSlice(&[_][]const u8{
            obj_filename,
            "-o",
            output_filename,
            "-lgc",
        });
        for (self.cli_c_flags) |flag| try cc_argv.append(flag);

        // Build requirements declared by `lib` annotations (@Include/@Define/@Source/@Link),
        // so vendored C sources compile and link into the native binary.
        try self.appendLibRequirements(&cc_argv);

        var child = try std.process.spawn(io, .{
            .argv = cc_argv.items,
        });

        const term = try child.wait(io);
        if (term != .exited or term.exited != 0) {
            std.debug.print("Linking LLVM object failed.\n", .{});
            return error.LinkingFailed;
        }
    }

    /// Appends the compiler/linker flags declared by `lib` annotations
    /// (@Include/@Define/@Source/@Link) plus the vendored runtime include dirs.
    /// Used by the native-binary link and by the JIT shared-lib build.
    fn appendLibRequirements(self: *LLVMEmitter, argv: *ArrayList([]const u8)) !void {
        const src_dir = eiwa_home.resolve(self.allocator);
        const repo_root = std.fs.path.dirname(src_dir) orelse ".";
        const inc_third_party = try std.fs.path.join(self.allocator, &.{ repo_root, "src/runtime/third_party" });
        try argv.appendSlice(&[_][]const u8{ "-I", inc_third_party });

        var inc_it = self.c_includes.keyIterator();
        while (inc_it.next()) |dir| {
            try argv.append(try std.fmt.allocPrint(self.allocator, "-I{s}", .{dir.*}));
        }
        var def_it = self.c_defines.keyIterator();
        while (def_it.next()) |def| {
            try argv.append(try std.fmt.allocPrint(self.allocator, "-D{s}", .{def.*}));
        }
        var src_it = self.c_sources.keyIterator();
        while (src_it.next()) |src| {
            try argv.append(src.*);
        }
        var lib_it = self.link_libraries.keyIterator();
        while (lib_it.next()) |lib_name| {
            try argv.append(try std.fmt.allocPrint(self.allocator, "-l{s}", .{lib_name.*}));
            const macro = try std.fmt.allocPrint(self.allocator, "-DEIWA_USE_{s}", .{lib_name.*});
            for (macro) |*c| c.* = std.ascii.toUpper(c.*);
            try argv.append(macro);
        }
    }

    /// Compiles the lib-declared C sources into a shared library and loads it
    /// into the JIT process so MCJIT can resolve the FFI externs (Phase 65).
    /// The shared library is keyed by the compile inputs, so an identical lib
    /// (e.g. the neco runtime, present in every test file) is compiled once and
    /// reused across processes instead of recompiled per file.
    fn loadLibSourcesIntoJIT(self: *LLVMEmitter, io: std.Io) !void {
        if (self.c_sources.count() == 0 and self.c_includes.count() == 0 and self.c_defines.count() == 0 and self.link_libraries.count() == 0) return;

        var h = std.hash.Wyhash.init(0);
        var src_it = self.c_sources.keyIterator();
        while (src_it.next()) |s| h.update(s.*);
        var def_it = self.c_defines.keyIterator();
        while (def_it.next()) |d| h.update(d.*);
        var inc_it = self.c_includes.keyIterator();
        while (inc_it.next()) |i| h.update(i.*);
        var link_it = self.link_libraries.keyIterator();
        while (link_it.next()) |l| h.update(l.*);
        const key = h.final();

        const lib_filename = try std.fmt.allocPrint(self.allocator, "/tmp/eiwa_llvm_libs_{x}.dylib", .{key});
        defer self.allocator.free(lib_filename);

        const cached = blk: {
            var f = std.Io.Dir.cwd().openFile(io, lib_filename, .{}) catch break :blk false;
            f.close(io);
            break :blk true;
        };
        if (!cached) {
            var cc_argv = ArrayList([]const u8).init(self.allocator);
            defer cc_argv.deinit();

            const link_driver = self.pickLinkDriver(io);
            try appendLinkDriverPrefix(&cc_argv, link_driver);
            try cc_argv.appendSlice(&[_][]const u8{ "-shared", "-O0", "-fwrapv" });
            if (builtin.target.os.tag == .macos) {
                const brew = if (builtin.target.cpu.arch == .aarch64) "/opt/homebrew" else "/usr/local";
                try cc_argv.appendSlice(&[_][]const u8{ "-I", brew ++ "/include", "-L", brew ++ "/lib" });
            }
            try cc_argv.appendSlice(&[_][]const u8{ "-o", lib_filename, "-lgc" });
            for (self.cli_c_flags) |flag| try cc_argv.append(flag);
            try self.appendLibRequirements(&cc_argv);

            var child = try std.process.spawn(io, .{ .argv = cc_argv.items });
            const term = try child.wait(io);
            if (term != .exited or term.exited != 0) {
                std.debug.print("Compiling lib C sources for JIT failed.\n", .{});
                return error.LibSourceCompileFailed;
            }
        }

        // dlopen with RTLD_GLOBAL so the MCJIT symbol resolver (dlsym
        // RTLD_DEFAULT) finds the externs. LLVM 21 dropped the
        // LLVMLoadLibraryPermanently C API, so use the std loader directly.
        const dynlib = std.DynLib.open(lib_filename) catch {
            std.debug.print("Could not load lib C sources into JIT.\n", .{});
            return error.LibSourceLoadFailed;
        };
        _ = dynlib;
    }

    /// Returns true if the emitted function body is well-formed LLVM IR
    /// (all blocks terminated, operand types consistent, etc.). Uses LLVM's
    /// own per-function verifier so it catches type mismatches and bad calls
    /// that a simple terminator scan would miss.
    fn functionIsWellFormed(func_val: llvm.LLVMValueRef) bool {
        if (llvm.LLVMVerifyFunction(func_val, llvm.LLVMReturnStatusAction) == 0) return true;
        if (verbose) _ = llvm.LLVMVerifyFunction(func_val, llvm.LLVMPrintMessageAction);
        return false;
    }

    /// Emits a function body, falling back to a complete stub when the body
    /// either fails to emit OR emits malformed IR (e.g. `when`/smart-cast or
    /// contract dispatch that leaves an unterminated block, an icmp on a
    /// struct, or a return-type mismatch without raising an error). The stub
    /// keeps the module verifiable for the JIT/linker.
    fn emitFunctionBodyOrStub(self: *LLVMEmitter, mod: llvm.LLVMModuleRef, func_node: *ast.ASTNode, fname: []const u8, is_object_method: bool) void {
        // Record the lambda counter so lambdas emitted while building this
        // body can be cleaned up if the emission fails: the partial body is
        // discarded, so they are orphaned and often malformed (unterminated
        // blocks) — leaving them in the module crashes LLVM codegen
        // (prepareDwarfEH) instead of producing a stubbed binary.
        const lam_counter_before = expression.currentLambdaCounter();
        var emitted_ok = true;
        self.emitFunctionBody(mod, func_node, is_object_method) catch |err| {
            if (verbose) std.debug.print("LLVM Emitter Error in {s}: {}\n", .{ fname, err });
            emitted_ok = false;
        };
        if (emitted_ok) {
            const func_val_opt = self.functions.get(fname) orelse blk: {
                const fname_z = self.allocator.dupeZ(u8, fname) catch break :blk null;
                defer self.allocator.free(fname_z);
                break :blk llvm.LLVMGetNamedFunction(mod, fname_z.ptr);
            };
            if (func_val_opt) |func_val| {
                if (functionIsWellFormed(func_val)) return;
                if (verbose) std.debug.print("LLVM Emitter: {s} produced invalid IR; stubbed.\n", .{fname});
            }
        }
        self.emitFunctionStub(mod, fname) catch {};
        // Delete lambdas orphaned by the failed/invalid body emission. Stub
        // emission already removed the parent's partial blocks, so the
        // lambdas have no remaining uses. Forward order (outermost first):
        // a nested lambda's only use lives in its parent's blocks, and
        // deleting a function with live uses would assert in LLVM.
        var lam_n = lam_counter_before;
        const lam_counter_end = expression.currentLambdaCounter();
        while (lam_n < lam_counter_end) : (lam_n += 1) {
            const lam_name = std.fmt.allocPrint(self.allocator, "lambda_anon_{d}\x00", .{lam_n}) catch break;
            defer self.allocator.free(lam_name);
            if (llvm.LLVMGetNamedFunction(mod, lam_name.ptr)) |lam_f| {
                llvm.LLVMDeleteFunction(lam_f);
            }
        }
    }

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
        } else if (kind == llvm.LLVMPointerTypeKind or kind == llvm.LLVMStructTypeKind) {
            _ = llvm.LLVMBuildRet(self.builder, llvm.LLVMConstNull(ret_type));
        } else {
            _ = llvm.LLVMBuildRetVoid(self.builder);
        }
    }

    /// Registers every JIT'd module global as a Boehm GC root segment
    /// (Bloco B). JIT globals live in MCJIT-mmap'd memory, which the
    /// collector does NOT scan by default — unlike a native binary's
    /// .data/.bss. Without this, objects only reachable from globals
    /// (object/enum singletons, eiwa_exception_stack, eiwa_active_exception)
    /// could be collected while still alive. Must run after engine creation
    /// (so global addresses are materialized) and before main runs.
    fn registerJITGlobalsAsRoots(engine: llvm.LLVMExecutionEngineRef, mod: llvm.LLVMModuleRef) void {
        const tm = llvm.LLVMGetExecutionEngineTargetMachine(engine);
        const td = llvm.LLVMCreateTargetDataLayout(tm);
        defer llvm.LLVMDisposeTargetData(td);

        var glob_it = llvm.LLVMGetFirstGlobal(mod);
        while (glob_it) |glob| : (glob_it = llvm.LLVMGetNextGlobal(glob)) {
            if (llvm.LLVMIsDeclaration(glob) != 0) continue;
            const addr = llvm.LLVMGetPointerToGlobal(engine, glob) orelse continue;
            const size = llvm.LLVMABISizeOfType(td, llvm.LLVMGlobalGetValueType(glob));
            if (size == 0) continue;
            const base: [*]u8 = @ptrCast(addr);
            // Roots stay registered until process exit: the execution engine
            // is intentionally never disposed (see executeJIT below), so the
            // segments remain valid for the whole program lifetime.
            gc.GC_add_roots(base, base + @as(usize, @intCast(size)));
        }
    }

    /// Executes the in-memory LLVM module via JIT (for `eiwa run --backend=llvm`).
    pub fn executeJIT(self: *LLVMEmitter, io: std.Io) !i32 {
        const mod = self.module orelse return error.ModuleAlreadyDisposed;
        // Bloco B: initialize the Boehm GC before any JIT'd code can call
        // GC_malloc. executeJIT is the sole GC_init caller for programs
        // without neco, so GC_malloc would SIGABRT without it. Idempotent.
        // has_gc is comptime: hosts without libgc compile this out entirely.
        if (has_gc) gc.GC_init();
        {
            var verify_err: [*c]u8 = null;
            if (llvm.LLVMVerifyModule(mod, llvm.LLVMReturnStatusAction, &verify_err) != 0) {
                if (verify_err != null) {
                    std.debug.print("LLVM Verify Error: {s}\n", .{verify_err});
                    llvm.LLVMDisposeMessage(verify_err);
                }
            }
        }
        // Compile and load lib-declared C sources (@Source) so MCJIT can resolve
        // the FFI externs (e.g. neco/curl). Phase 65.
        try self.loadLibSourcesIntoJIT(io);
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
        // Do not dispose execution engine here; disposing MCJIT before process exit
        // unmaps JIT'd memory pages while host unwinder runs, causing segfaults.
        // defer llvm.LLVMDisposeExecutionEngine(engine);

        // Bloco B: with the engine materialized, register JIT globals as GC
        // roots before any GC_malloc from the program can trigger a collection.
        if (has_gc) registerJITGlobalsAsRoots(engine, mod);

        // The entry is always the shim `main(i32 argc, ptr argv)` (emitted by
        // emitEntryShim), which stores argv and forwards to the program main.
        const main_func = llvm.LLVMGetNamedFunction(mod, "main") orelse return error.MainNotFound;
        const main_fn_ptr = llvm.LLVMGetPointerToGlobal(engine, main_func);
        const main_type = llvm.LLVMGlobalGetValueType(main_func);
        const ret_kind = llvm.LLVMGetTypeKind(llvm.LLVMGetReturnType(main_type));

        // Pass the host process's real argv so Process.args()/argAt() see the
        // actual command line. host_argv (set by main.zig) is argv[0..]; the
        // compile-time program_argv is the fallback (prog name + positionals).
        const args_list: []const []const u8 = if (self.host_argv.len > 0) self.host_argv else self.program_argv;
        const argv_slice = try self.allocator.alloc(?*anyopaque, args_list.len + 1);
        for (args_list, 0..) |arg, i| {
            const z = try self.allocator.dupeZ(u8, arg);
            argv_slice[i] = @ptrCast(z.ptr);
        }
        argv_slice[args_list.len] = null;
        const argv_ptrs = argv_slice.ptr;

        if (ret_kind == llvm.LLVMVoidTypeKind) {
            const main_fn: *const fn (c_int, [*]?*anyopaque) callconv(.c) void = @ptrCast(@alignCast(main_fn_ptr));
            main_fn(@intCast(args_list.len), argv_ptrs);
            return 0;
        }
        const main_fn: *const fn (c_int, [*]?*anyopaque) callconv(.c) i32 = @ptrCast(@alignCast(main_fn_ptr));
        const res = main_fn(@intCast(args_list.len), argv_ptrs);
        const code: u8 = if (res < 0) 1 else @intCast(@min(res, 255));
        std.process.exit(code);
    }
};

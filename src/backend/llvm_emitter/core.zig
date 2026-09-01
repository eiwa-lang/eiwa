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
const diagnostics = @import("../../core/diagnostics.zig");

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
/// from the host process.
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
    pub extern "c" fn GC_allow_register_threads() void;
    pub extern "c" fn GC_malloc(size: usize) ?*anyopaque;
    pub extern "c" fn GC_malloc_uncollectable(size: usize) ?*anyopaque;
    pub extern "c" fn GC_realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque;
    pub extern "c" fn GC_get_stack_base(sb: ?*anyopaque) c_int;
    pub extern "c" fn GC_register_my_thread(sb: ?*anyopaque) c_int;
    pub extern "c" fn GC_unregister_my_thread() c_int;
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

/// Returns the heap allocation function for uncollectable permanent roots (enums/static data):
/// GC_malloc_uncollectable-first when `prefer_gc_alloc`, malloc-first otherwise.
pub fn getHeapUncollectableAllocFn(mod: llvm.LLVMModuleRef) llvm.LLVMValueRef {
    const primary: [*:0]const u8 = if (prefer_gc_alloc) "GC_malloc_uncollectable" else "malloc";
    const fallback: [*:0]const u8 = if (prefer_gc_alloc) "malloc" else "GC_malloc_uncollectable";
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

/// Returns the size in 64-bit words for `jmp_buf` in `EiwaExceptionFrame`
/// based on target OS and CPU architecture.
pub fn getJmpBufWords(os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) usize {
    return switch (os) {
        .macos, .ios, .watchos, .tvos, .visionos => switch (arch) {
            .aarch64 => 24, // 192 bytes (_JBLEN = 48 ints)
            .x86_64 => 19,  // 152 bytes (_JBLEN = 37 ints + 4-byte pad)
            else => 32,
        },
        .linux => switch (arch) {
            .x86_64 => 25,  // 200 bytes (glibc __jmp_buf + __sigset_t)
            .aarch64 => 39, // 312 bytes (glibc __jmp_buf + __sigset_t)
            .arm, .armeb => 33, // 264 bytes
            .riscv64 => 25,
            .x86 => 20,
            else => 32,
        },
        .windows => switch (arch) {
            .x86_64 => 32, // 256 bytes (SETJMP_FLOAT128[16])
            .aarch64 => 24, // 192 bytes
            .x86 => 8,     // 64 bytes
            else => 32,
        },
        .freebsd, .openbsd, .netbsd => 32,
        else => 64, // conservative fallback for unlisted targets
    };
}

pub const LibDeclEntry = struct {
    lib_node: *ast.ASTNode,
    module_path: ?[]const u8,
};

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
    classes_ast: ?*std.StringHashMap(*ast.ASTNode) = null,
    /// Build requirements declared by `lib` annotations (@Source/@Include/@Define/@Link),
    /// mirroring the C transpiler (Phase 65 — LLVM backend compiles the C sources too).
    lib_declarations: std.StringHashMap(LibDeclEntry),
    used_libs: std.StringHashMap(void),
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
    target_info: ?tc_core.TargetInfo = null,
    /// Incremental split-emission mode (docs/perf-plan-incremental-cache.md,
    /// Phase A3). When set, this unit emits definitions only for modules in
    /// the set; all other modules are declared extern. null = legacy
    /// whole-program single-module emission.
    unit_modules: ?*std.AutoHashMap(*ast.ASTNode, void) = null,
    /// The entry unit additionally owns: program entry shim, argv support,
    /// GC ctor, runtime globals (exception stack, eiwa_argc/argv), object/enum
    /// initializers, top-level statements and the test runner.
    unit_is_entry: bool = true,
    /// Lazily-built index: underscore-delimited token -> names in `functions`
    /// containing that token as a component. Lets the "related mangled
    /// variants" lookups (markReachable, vtable pass) scan a small candidate
    /// set instead of the entire functions map. Rebuilt if `functions` grows.
    fn_token_index: ?std.StringHashMap(ArrayList([]const u8)) = null,
    fn_token_index_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, module_name: []const u8, is_release: bool) !LLVMEmitter {
        llvm.LLVMLinkInMCJIT();
        _ = llvm.LLVMInitializeAllTargets();
        _ = llvm.LLVMInitializeAllTargetInfos();
        _ = llvm.LLVMInitializeAllTargetMCs();
        _ = llvm.LLVMInitializeAllAsmPrinters();
        _ = llvm.LLVMInitializeAllAsmParsers();
        _ = llvm.LLVMInitializeNativeTarget();
        _ = llvm.LLVMInitializeNativeAsmPrinter();
        _ = llvm.LLVMInitializeNativeAsmParser();
        _ = llvm.LLVMInitializeNativeDisassembler();

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
            .lib_declarations = std.StringHashMap(LibDeclEntry).init(allocator),
            .used_libs = std.StringHashMap(void).init(allocator),
            .c_sources = std.StringHashMap(void).init(allocator),
            .c_includes = std.StringHashMap(void).init(allocator),
            .c_defines = std.StringHashMap(void).init(allocator),
            .link_libraries = std.StringHashMap(void).init(allocator),
            .target_info = null,
        };
    }

    pub fn deinit(self: *LLVMEmitter) void {
        self.functions.deinit();
        if (self.fn_token_index) |*idx| {
            var tok_it = idx.valueIterator();
            while (tok_it.next()) |v| v.deinit();
            idx.deinit();
        }
        self.structs.deinit();
        var lib_it = self.libs.valueIterator();
        while (lib_it.next()) |v| {
            v.*.deinit();
        }
        self.libs.deinit();
        self.lib_declarations.deinit();
        self.used_libs.deinit();
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

    pub fn matchesTarget(self: *LLVMEmitter, targets: []const []const u8) bool {
        if (targets.len == 0) return true;
        if (self.target_info) |ti| {
            return ti.matchesAny(targets);
        }
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const host_ti = tc_core.TargetInfo.detectHost(arena.allocator());
        return host_ti.matchesAny(targets);
    }

    /// Emits LLVM IR for top-level functions, expressions, and statements.
    /// Split-mode ownership: true when this unit emits definitions for `m`.
    /// Legacy whole-program mode owns everything.
    fn unitOwns(self: *LLVMEmitter, m: *ast.ASTNode) bool {
        const set = self.unit_modules orelse return true;
        return set.contains(m);
    }

    /// Marks compiler-emitted helper functions (intrinsics, GC wrappers,
    /// string helpers) as internal so every split unit can carry a private
    /// copy without colliding at link time. No-op in legacy mode. Also covers
    /// `.N` auto-renamed duplicates created by re-declaration (e.g. FFI lib
    /// prototypes colliding with the prologue definitions).
    fn makeHelpersInternal(self: *LLVMEmitter, mod: llvm.LLVMModuleRef) void {
        if (self.unit_modules == null) return;
        const names = [_][]const u8{
            "GC_MALLOC",           "GC_REALLOC",          "eiwa_to_string",
            "eiwa_str_replace",    "eiwa_string_equals",  "eiwa_char_at",
            "eiwa_write_byte",     "eiwa_random_bytes",   "eiwa_now_millis",
            "eiwa_load_int64",     "eiwa_store_int64",    "eiwa_read_byte",
            "eiwa_atomic_cas_bool", "eiwa_atomic_cas_val", "eiwa_atomic_fetch_add",
            "eiwa_atomic_test_and_set",
        };
        for (names) |n| {
            const nz = self.allocator.dupeZ(u8, n) catch continue;
            defer self.allocator.free(nz);
            if (llvm.LLVMGetNamedFunction(mod, nz.ptr)) |f| {
                llvm.LLVMSetLinkage(f, llvm.LLVMInternalLinkage);
            }
        }
        // Sweep `.N` renamed duplicates (LLVM re-declaration artifacts) and
        // anonymous lambdas. Lambda names come from a per-process global
        // counter (expression.zig), so two split units can generate the same
        // `lambda_anon_N` — internal linkage keeps them private per object.
        var f = llvm.LLVMGetFirstFunction(mod);
        while (f != null) : (f = llvm.LLVMGetNextFunction(f.?)) {
            const fname = std.mem.span(llvm.LLVMGetValueName(f.?));
            if (std.mem.startsWith(u8, fname, "lambda_anon")) {
                llvm.LLVMSetLinkage(f.?, llvm.LLVMInternalLinkage);
                continue;
            }
            var base_len = fname.len;
            if (std.mem.lastIndexOfScalar(u8, fname, '.')) |dot| {
                base_len = dot;
            }
            for (names) |n| {
                if (base_len == n.len and std.mem.eql(u8, fname[0..base_len], n)) {
                    llvm.LLVMSetLinkage(f.?, llvm.LLVMInternalLinkage);
                    break;
                }
            }
        }
    }

    pub fn emitModule(self: *LLVMEmitter, ast_root: *ast.ASTNode) !void {
        const mod = self.module orelse return error.ModuleAlreadyDisposed;
        const split = self.unit_modules != null;
        const is_entry = self.unit_is_entry;

        if (self.target_info) |ti| {
            const triple_z = try self.allocator.dupeZ(u8, ti.triple);
            defer self.allocator.free(triple_z);
            llvm.LLVMSetTarget(mod, triple_z.ptr);
        }

        if (ast_root.data != .program) return error.InvalidASTRoot;

        // Pass 0: Declare memory allocation prototypes
        const ptr_type = llvm.LLVMPointerTypeInContext(self.context, 0);
        const size_t_type = llvm.LLVMInt64TypeInContext(self.context);
        var gc_params = [_]llvm.LLVMTypeRef{size_t_type};
        const gc_type = llvm.LLVMFunctionType(ptr_type, &gc_params, 1, 0);
        _ = llvm.LLVMAddFunction(mod, "GC_malloc", gc_type);
        _ = llvm.LLVMAddFunction(mod, "GC_malloc_uncollectable", gc_type);
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
        _ = llvm.LLVMAddFunction(mod, "GC_allow_register_threads", void_fn_type);

        // Native binaries (eiwac build) allocate via GC_malloc when
        // prefer_gc_alloc, so the Boehm GC must be initialized before main.
        // Emit a global constructor that calls GC_init and GC_allow_register_threads —
        // covers every entry shape (plain main, eiwa_test_main) without touching each one.
        // The JIT path does NOT rely on this (MCJIT never runs global ctors);
        // executeJIT calls GC_init and GC_allow_register_threads from the host side.
        // Split mode: only the entry unit defines the ctor (it owns main).
        if (prefer_gc_alloc and (!split or is_entry)) {
            const ctor_fn = llvm.LLVMAddFunction(mod, "__eiwa_gc_init_ctor", void_fn_type);
            const ctor_bb = llvm.LLVMAppendBasicBlockInContext(self.context, ctor_fn, "entry");
            llvm.LLVMPositionBuilderAtEnd(self.builder, ctor_bb);
            const gc_init_fn = llvm.LLVMGetNamedFunction(mod, "GC_init").?;
            _ = llvm.LLVMBuildCall2(self.builder, void_fn_type, gc_init_fn, null, 0, "");
            const gc_allow_fn = llvm.LLVMGetNamedFunction(mod, "GC_allow_register_threads").?;
            _ = llvm.LLVMBuildCall2(self.builder, void_fn_type, gc_allow_fn, null, 0, "");
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

        const is_windows = if (self.target_info) |ti| ti.os_tag == .windows else (builtin.target.os.tag == .windows);
        const setjmp_name: [*:0]const u8 = if (is_windows) "setjmp" else "_setjmp";
        const longjmp_name: [*:0]const u8 = if (is_windows) "longjmp" else "_longjmp";

        var setjmp_params = [_]llvm.LLVMTypeRef{ptr_type};
        const setjmp_type = llvm.LLVMFunctionType(i32_type, &setjmp_params, 1, 0);
        _ = llvm.LLVMAddFunction(mod, setjmp_name, setjmp_type);

        var longjmp_params = [_]llvm.LLVMTypeRef{ ptr_type, i32_type };
        const longjmp_type = llvm.LLVMFunctionType(void_type, &longjmp_params, 2, 0);
        _ = llvm.LLVMAddFunction(mod, longjmp_name, longjmp_type);

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
        // Split mode: defined (with initializer) only by the entry unit —
        // cross-module exception propagation requires a single shared
        // instance; other units reference them as extern declarations.
        const exc_stack_global = llvm.LLVMAddGlobal(mod, ptr_type, "eiwa_exception_stack");
        if (!split or is_entry) llvm.LLVMSetInitializer(exc_stack_global, llvm.LLVMConstNull(ptr_type));
        const fat_type = types_mapping.getFatPointerType(self.context);
        const active_exc_global = llvm.LLVMAddGlobal(mod, fat_type, "eiwa_active_exception");
        if (!split or is_entry) llvm.LLVMSetInitializer(active_exc_global, llvm.LLVMConstNull(fat_type));

        // struct EiwaExceptionFrame { jmp_buf buf; EiwaExceptionFrame* next; }
        // jmp_buf size is target-dependent (OS/architecture).
        const frame_struct = llvm.LLVMStructCreateNamed(self.context, "EiwaExceptionFrame");
        const target_os = if (self.target_info) |ti| ti.os_tag else builtin.target.os.tag;
        const target_arch = if (self.target_info) |ti| ti.arch else builtin.target.cpu.arch;
        const jmp_buf_words = getJmpBufWords(target_os, target_arch);
        const buf_type = llvm.LLVMArrayType(llvm.LLVMInt64TypeInContext(self.context), @intCast(jmp_buf_words));
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
        try self.emitStrReplaceHelper(mod);
        try self.emitStringEqualsHelper(mod);
        try self.emitCharAtHelper(mod);
        try self.emitWriteByteHelper(mod);
        try self.emitRandomBytesHelper(mod);
        try self.emitNowMillisHelper(mod);

        expression.global_contracts_ast_ptr = self.contracts_ast;
        expression.global_classes_ast_ptr = self.classes_ast;

        // Collect the entry module and every module it (transitively) imports.
        var modules = ArrayList(*ast.ASTNode).init(self.allocator);
        defer modules.deinit();
        var visited = std.AutoHashMap(*ast.ASTNode, void).init(self.allocator);
        defer visited.deinit();
        try self.collectModules(ast_root, &modules, &visited);

        // Split mode, entry unit: types whose type_decl appears in a DEP
        // module's statements are dep-owned (the deps object defines their
        // ctor, methods and vtables). Monomorphized instances are cloned into
        // every using module's statement list, so a type can show up in both
        // units' modules — ownership must follow "appears in a dep module",
        // which is a function of dep sources alone (keeps the deps object
        // cache key entry-independent).
        var dep_owned_types = std.StringHashMap(void).init(self.allocator);
        defer dep_owned_types.deinit();
        var dep_owned_fns = std.StringHashMap(void).init(self.allocator);
        defer dep_owned_fns.deinit();
        if (split and is_entry) {
            for (modules.items) |m| {
                if (m.data != .program) continue;
                if (self.unitOwns(m)) continue;
                for (m.data.program.statements) |stmt| {
                    if (stmt.data == .type_decl) {
                        const t = stmt.data.type_decl;
                        // The ctor symbol exists for generic templates too
                        // (declareType emits it) — record the name; methods of
                        // templates are not emitted directly, so skip them.
                        const t_name = t.resolved_c_name orelse t.name;
                        try dep_owned_types.put(t_name, {});
                        try dep_owned_fns.put(t_name, {});
                        if (t.generic_params.len > 0) continue;
                        for (t.methods) |m_node| {
                            if (m_node.data != .fun_decl) continue;
                            if (m_node.data.fun_decl.generic_params.len > 0) continue;
                            if (m_node.data.fun_decl.resolved_c_name) |rcn| try dep_owned_fns.put(rcn, {});
                            try dep_owned_fns.put(try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ t_name, m_node.data.fun_decl.name }), {});
                        }
                    } else if (stmt.data == .fun_decl) {
                        if (stmt.data.fun_decl.generic_params.len > 0) continue;
                        try dep_owned_fns.put(stmt.data.fun_decl.resolved_c_name orelse stmt.data.fun_decl.name, {});
                    } else if (stmt.data == .object_decl) {
                        for (stmt.data.object_decl.members) |member| {
                            if (member.data != .fun_decl) continue;
                            if (member.data.fun_decl.generic_params.len > 0) continue;
                            try dep_owned_fns.put(member.data.fun_decl.resolved_c_name orelse member.data.fun_decl.name, {});
                        }
                    }
                }
            }
        }

        // Pass 1a: Declare all user-defined types (structs & constructors) & enums
        // Split mode: monomorphized clones appear in several modules' statement
        // lists; LLVMAddFunction re-adds under a `.N` rename, and two units
        // producing the same `.N` collide at link. Dedupe by resolved name —
        // first declaration wins (same semantics as the existing function).
        var seen_types = std.StringHashMap(void).init(self.allocator);
        defer seen_types.deinit();
        for (modules.items) |m| {
            if (m.data != .program) continue;
            const own = self.unitOwns(m);
            for (m.data.program.statements) |stmt| {
                if (stmt.data == .type_decl) {
                    const t = stmt.data.type_decl;
                    const t_c_name = t.resolved_c_name orelse t.name;
                    if (split) {
                        if (seen_types.contains(t_c_name)) continue;
                        try seen_types.put(t_c_name, {});
                    }
                    const dep_owned = split and is_entry and dep_owned_types.contains(t_c_name);
                    try self.declareType(mod, stmt, own and !dep_owned);
                } else if (stmt.data == .enum_decl) {
                    try self.declareEnum(mod, stmt, own);
                }
            }
        }
        if (self.classes_ast) |ca| {
            var c_it = ca.iterator();
            while (c_it.next()) |entry| {
                const c_node = entry.value_ptr.*;
                if (c_node.data == .type_decl) {
                    // Dep-owned pool types are defined by the deps unit.
                    const t = c_node.data.type_decl;
                    const t_c_name = t.resolved_c_name orelse t.name;
                    if (split and is_entry and dep_owned_types.contains(t_c_name)) continue;
                    if (split) {
                        if (seen_types.contains(t_c_name)) continue;
                        try seen_types.put(t_c_name, {});
                    }
                    // Monomorphized pool types belong to the entry unit in
                    // split mode (linker resolves cross-unit references).
                    try self.declareType(mod, c_node, !split or is_entry);
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
                    if (!self.matchesTarget(stmt.data.lib_decl.platform_targets)) continue;
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
                    if (!self.matchesTarget(stmt.data.object_decl.platform_targets)) continue;
                    for (stmt.data.object_decl.members) |member| {
                        if (member.data != .fun_decl) continue;
                        try self.declareFunction(mod, member, true);
                    }
                }
            }
        }

        // Pass 1d: Declare object member globals (`Env.isLoaded` etc.), named
        // `{object_c_name}_{var}` per infer_decl.zig inferVarDecl.
        // Split mode: owning unit defines (with initializer); other units
        // reference the global as an extern declaration.
        for (modules.items) |m| {
            if (m.data != .program) continue;
            const own = self.unitOwns(m);
            for (m.data.program.statements) |stmt| {
                if (stmt.data != .object_decl) continue;
                const obj = stmt.data.object_decl;
                if (!self.matchesTarget(obj.platform_targets)) continue;
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
                        if (!split or own) {
                            const const_init = if (v.initializer) |ie| tryGetConstLLVMValue(ie, llvm_type) else null;
                            if (const_init) |ci| {
                                llvm.LLVMSetInitializer(global, ci);
                            } else {
                                llvm.LLVMSetInitializer(global, llvm.LLVMConstNull(llvm_type));
                            }
                        }
                    }
                }
            }
        }

        // Split mode skips the reachability pass below (every own body is
        // emitted), so mark every declared lib as used — link requirements
        // (@Source/@Link) are then collected for the whole program.
        if (split) {
            for (modules.items) |m| {
                if (m.data != .program) continue;
                for (m.data.program.statements) |stmt| {
                    if (stmt.data == .lib_decl) {
                        try self.used_libs.put(stmt.data.lib_decl.name, {});
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
        // Split mode: skipped — every body of an owned module is emitted and
        // the linker dead-strips the rest, so no reachability is computed.
        var func_index = try self.buildFuncIndex(&modules);
        defer func_index.deinit();
        if (!split) {
            if (ast_root.data == .program) {
                for (ast_root.data.program.statements) |stmt| {
                    if (stmt.data == .lib_decl) {
                        try self.used_libs.put(stmt.data.lib_decl.name, {});
                    }
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
                // Seed callees of object member initializers from all modules so functions
                // invoked during entry object initialization get real bodies emitted.
                for (modules.items) |m| {
                    if (m.data != .program) continue;
                    for (m.data.program.statements) |stmt| {
                        if (stmt.data == .object_decl) {
                            for (stmt.data.object_decl.members) |member| {
                                if (member.data == .var_decl) {
                                    if (member.data.var_decl.initializer) |init_e| {
                                        try self.collectCallees(init_e, &reachable, &worklist);
                                    }
                                }
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
                        const t_name = stmt.data.type_decl.resolved_c_name orelse stmt.data.type_decl.name;
                        for (stmt.data.type_decl.methods) |m_node| {
                            if (m_node.data != .fun_decl) continue;
                            if (m_node.data.fun_decl.generic_params.len > 0) continue;
                            const name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ t_name, m_node.data.fun_decl.name });
                            defer self.allocator.free(name);
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
            try self.drainReachableWorklist(&func_index, &reachable, &worklist);
        } // if (!split reachability seed/fixpoint)

        // Pass 1e: Emit static vtables for implemented contracts of reachable types (Task 61.1)
        // Named `{type_c_name}_{contract_c_name}_vtable`.
        // Split mode: the owning unit defines the vtable; other units declare
        // it extern (constant, no initializer) so `when (x) is Contract`
        // checks — which iterate every `_vtable` global in the module — see
        // the complete whole-program set in every unit.
        for (modules.items) |m| {
            if (m.data != .program) continue;
            const own_body_vt = self.unitOwns(m);
            for (m.data.program.statements) |stmt| {
                if (stmt.data == .type_decl) {
                    const t = stmt.data.type_decl;
                    if (t.generic_params.len > 0) continue;
                    const type_c_name = t.resolved_c_name orelse t.name;
                    const own_vt = own_body_vt and !(split and is_entry and dep_owned_types.contains(type_c_name));


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

                        // Non-owning split unit: extern declaration only.
                        if (split and !own_vt) {
                            var method_count: usize = 0;
                            for (c_decl.methods) |cm| {
                                if (cm.data == .fun_decl) method_count += 1;
                            }
                            const slot_types = try self.allocator.alloc(llvm.LLVMTypeRef, method_count);
                            defer self.allocator.free(slot_types);
                            for (slot_types) |*st| st.* = ptr_type;
                            const ext_type = llvm.LLVMStructTypeInContext(self.context, slot_types.ptr, @intCast(method_count), 0);

                            const ext_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}_vtable", .{ type_c_name, c_decl.name });
                            defer self.allocator.free(ext_name);
                            const ext_name_z = try self.allocator.dupeZ(u8, ext_name);
                            defer self.allocator.free(ext_name_z);
                            if (llvm.LLVMGetNamedGlobal(mod, ext_name_z.ptr) == null) {
                                const g = llvm.LLVMAddGlobal(mod, ext_type, ext_name_z.ptr);
                                llvm.LLVMSetGlobalConstant(g, 1);
                            }
                            if (!std.mem.eql(u8, contract_src, c_decl.name)) {
                                const alt_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}_vtable", .{ type_c_name, contract_src });
                                defer self.allocator.free(alt_name);
                                const alt_name_z = try self.allocator.dupeZ(u8, alt_name);
                                defer self.allocator.free(alt_name_z);
                                if (llvm.LLVMGetNamedGlobal(mod, alt_name_z.ptr) == null) {
                                    const g2 = llvm.LLVMAddGlobal(mod, ext_type, alt_name_z.ptr);
                                    llvm.LLVMSetGlobalConstant(g2, 1);
                                }
                            }
                            continue;
                        }

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

                            if (try self.fnCandidates(target_prefix)) |candidates| {
                                for (candidates) |fk| {
                                    if (std.mem.eql(u8, fk, target_prefix) or
                                        (std.mem.startsWith(u8, fk, target_prefix) and fk.len > target_prefix.len and fk[target_prefix.len] == '_'))
                                    {
                                        impl_fn = self.functions.get(fk);
                                        if (!split) try self.markReachable(fk, &reachable, &worklist);
                                        break;
                                    }
                                }
                            } else {
                                var fit = self.functions.iterator();
                                while (fit.next()) |entry| {
                                    const fk = entry.key_ptr.*;
                                    if (std.mem.eql(u8, fk, target_prefix) or
                                        (std.mem.startsWith(u8, fk, target_prefix) and fk.len > target_prefix.len and fk[target_prefix.len] == '_'))
                                    {
                                        impl_fn = entry.value_ptr.*;
                                        if (!split) try self.markReachable(fk, &reachable, &worklist);
                                        break;
                                    }
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
        if (!split) try self.drainReachableWorklist(&func_index, &reachable, &worklist);

        // Split-mode ownership sets for the stub pass below: a bodyless
        // declaration may only be stubbed by the unit that owns it (the
        // owning unit's real definition would otherwise collide at link).
        var owned_names = std.StringHashMap(void).init(self.allocator);
        defer owned_names.deinit();
        var foreign_names = std.StringHashMap(void).init(self.allocator);
        defer foreign_names.deinit();

        for (modules.items) |m| {
            if (m.data != .program) continue;
            const own_body = self.unitOwns(m);
            for (m.data.program.statements) |stmt| {
                if (stmt.data == .fun_decl) {
                    if (stmt.data.fun_decl.generic_params.len > 0) continue;
                    const fname = stmt.data.fun_decl.resolved_c_name orelse stmt.data.fun_decl.name;
                    if (split) {
                        if (own_body) try owned_names.put(fname, {}) else {
                            try foreign_names.put(fname, {});
                            continue;
                        }
                    } else if (!reachable.contains(fname)) continue;
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
                    // Generic templates are not emitted directly; only monomorphized
                    // instances (which have generic_params empty) produce code.
                    const is_template = stmt.data.type_decl.generic_params.len > 0 and (stmt.data.type_decl.methods.len == 0 or stmt.data.type_decl.methods[0].data.fun_decl.resolved_c_name == null);
                    if (is_template) continue;
                    const t_name = stmt.data.type_decl.resolved_c_name orelse stmt.data.type_decl.name;
                    // Dep-owned type (entry unit): the deps object holds the
                    // ctor, methods and vtables — reference them extern.
                    const skip_dep_owned = split and is_entry and dep_owned_types.contains(t_name);
                    if (split) {
                        // The constructor symbol is the type name itself.
                        if (own_body and !skip_dep_owned) try owned_names.put(t_name, {}) else try foreign_names.put(t_name, {});
                    }

                    for (stmt.data.type_decl.methods) |m_node| {
                        if (m_node.data != .fun_decl) continue;
                        if (m_node.data.fun_decl.generic_params.len > 0) continue;
                        const fname = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ t_name, m_node.data.fun_decl.name });
                        if (split) {
                            if (own_body and !skip_dep_owned) try owned_names.put(fname, {}) else {
                                try foreign_names.put(fname, {});
                                continue;
                            }
                        } else if (!reachable.contains(fname)) continue;
                        // Emit the method body, with graceful stub fallback for synthetic
                        // or unmaterialized stdlib derivations that are marked reachable.
                        self.emitFunctionBodyOrStub(mod, m_node, fname, true);
                    }
                } else if (stmt.data == .object_decl) {
                    for (stmt.data.object_decl.members) |member| {
                        if (member.data != .fun_decl) continue;
                        if (member.data.fun_decl.generic_params.len > 0) continue;
                        const fname = member.data.fun_decl.resolved_c_name orelse member.data.fun_decl.name;
                        if (split) {
                            if (own_body) try owned_names.put(fname, {}) else {
                                try foreign_names.put(fname, {});
                                continue;
                            }
                        } else if (!reachable.contains(fname)) continue;
                        self.emitFunctionBodyOrStub(mod, member, fname, true);
                    }
                }
                // Split mode: only the entry unit synthesizes `main` from
                // top-level statements (the deps object must not define it).
                if (m == ast_root and (!split or self.unitOwns(m)) and
                    stmt.data != .fun_decl and stmt.data != .type_decl and stmt.data != .enum_decl and
                    stmt.data != .contract_decl and stmt.data != .skill_decl and stmt.data != .object_decl and
                    stmt.data != .lib_decl and stmt.data != .import_stmt and stmt.data != .test_decl)
                {
                    try top_level_stmts.append(stmt);
                }
            }
        }
        // Monomorphized pool methods belong to the entry unit in split mode.
        if ((!split or is_entry)) {
            if (self.classes_ast) |ca| {
                var c_it = ca.iterator();
                while (c_it.next()) |entry| {
                    const c_node = entry.value_ptr.*;
                if (c_node.data == .type_decl) {
                    const stmt = c_node;
                    if (stmt.data.type_decl.generic_params.len > 0) continue;
                    const t_name = stmt.data.type_decl.resolved_c_name orelse stmt.data.type_decl.name;
                    // Dep-owned pool type: the deps object defines it.
                    if (split and is_entry and dep_owned_types.contains(t_name)) continue;
                    if (split) try owned_names.put(t_name, {});
                        for (stmt.data.type_decl.methods) |m_node| {
                            if (m_node.data != .fun_decl) continue;
                            if (m_node.data.fun_decl.generic_params.len > 0) continue;
                            const fname = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ t_name, m_node.data.fun_decl.name });
                            defer self.allocator.free(fname);
                            if (split) {
                                // dupe: fname is freed at iteration end.
                                try owned_names.put(try self.allocator.dupe(u8, fname), {});
                            } else if (!reachable.contains(fname) and !reachable.contains(m_node.data.fun_decl.name)) continue;
                            self.emitFunctionBodyOrStub(mod, m_node, fname, true);
                        }
                    }
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
                if (llvm.LLVMGetNamedFunction(mod, "GC_allow_register_threads")) |gc_allow| {
                    const gca_type = llvm.LLVMGlobalGetValueType(gc_allow);
                    _ = llvm.LLVMBuildCall2(self.builder, gca_type, gc_allow, null, 0, "");
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
                const passed_var = llvm.LLVMBuildAlloca(self.builder, i32_type, "test_passed");
                _ = llvm.LLVMBuildStore(self.builder, llvm.LLVMConstInt(i32_type, 0, 0), passed_var);

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
                    const passed_prev = llvm.LLVMBuildLoad2(self.builder, i32_type, passed_var, "passed_prev");
                    const passed_inc = llvm.LLVMBuildAdd(self.builder, passed_prev, llvm.LLVMConstInt(i32_type, 1, 0), "passed_inc");
                    _ = llvm.LLVMBuildStore(self.builder, passed_inc, passed_var);
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

                const passed_final = llvm.LLVMBuildLoad2(self.builder, i32_type, passed_var, "passed_final");
                const failed_final = llvm.LLVMBuildLoad2(self.builder, i32_type, failed_var, "failed_final");

                // Machine-parseable per-run summary so the parent test harness
                // counts test BLOCKS (not files) across parallel child processes.
                const printf_fn = llvm.LLVMGetNamedFunction(mod, "printf") orelse blk: {
                    var sum_params = [_]llvm.LLVMTypeRef{ptr_type_rt};
                    const ft = llvm.LLVMFunctionType(i32_type, &sum_params, 1, 1);
                    break :blk llvm.LLVMAddFunction(mod, "printf", ft);
                };
                const sum_printf_type = llvm.LLVMGlobalGetValueType(printf_fn);
                const sum_fmt = try self.allocator.dupeZ(u8, "[SUMMARY] %d passed, %d failed\n");
                defer self.allocator.free(sum_fmt);
                const sum_str = llvm.LLVMBuildGlobalStringPtr(self.builder, sum_fmt.ptr, "summary_msg");
                var sum_args = [_]llvm.LLVMValueRef{ sum_str, passed_final, failed_final };
                _ = llvm.LLVMBuildCall2(self.builder, sum_printf_type, printf_fn, &sum_args, 3, "");
                if (fflush_fn_opt != null) {
                    var null_arg = [_]llvm.LLVMValueRef{llvm.LLVMConstNull(ptr_type_rt)};
                    _ = llvm.LLVMBuildCall2(self.builder, fflush_ft_opt.?, fflush_fn_opt.?, &null_arg, 1, "");
                }
                _ = llvm.LLVMBuildRet(self.builder, failed_final);

            } else {
                std.debug.print("No tests found.\n", .{});
            }
        }

        // Stub pass: emit no-op bodies for any externally-declared functions
        // that have no body (e.g. exceptions_assert_Bool_String, io_println, etc.).
        // Without this the LLVM JIT/linker resolves them to null/undefined → segfault/link error.
        var ffi_symbols = std.StringHashMap(void).init(self.allocator);
        defer ffi_symbols.deinit();
        {
            var lib_it = self.libs.valueIterator();
            while (lib_it.next()) |fmap| {
                var fn_it2 = fmap.valueIterator();
                while (fn_it2.next()) |cname| {
                    try ffi_symbols.put(cname.*, {});
                }
            }
        }

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
                const is_posix_target = if (self.target_info) |ti| ti.family == .posix else (!is_windows);
                const is_lib_fn = if (is_windows) false else ffi_symbols.contains(fn_name_s);
                const is_libc = is_libm or is_lib_fn or
                    std.mem.eql(u8, fn_name_s, "printf") or
                    std.mem.eql(u8, fn_name_s, "malloc") or
                    std.mem.eql(u8, fn_name_s, "realloc") or
                    (prefer_gc_alloc and (
                        std.mem.eql(u8, fn_name_s, "GC_malloc") or
                        std.mem.eql(u8, fn_name_s, "GC_malloc_uncollectable") or
                        std.mem.eql(u8, fn_name_s, "GC_realloc") or
                        std.mem.eql(u8, fn_name_s, "GC_init") or
                        std.mem.eql(u8, fn_name_s, "GC_allow_register_threads") or
                        std.mem.eql(u8, fn_name_s, "GC_get_stack_base") or
                        std.mem.eql(u8, fn_name_s, "GC_register_my_thread") or
                        std.mem.eql(u8, fn_name_s, "GC_unregister_my_thread")
                    )) or
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
                    std.mem.eql(u8, fn_name_s, "memset") or
                    std.mem.eql(u8, fn_name_s, "calloc") or
                    (is_posix_target and (
                        std.mem.eql(u8, fn_name_s, "socket") or
                        std.mem.eql(u8, fn_name_s, "setsockopt") or
                        std.mem.eql(u8, fn_name_s, "bind") or
                        std.mem.eql(u8, fn_name_s, "listen") or
                        std.mem.eql(u8, fn_name_s, "accept") or
                        std.mem.eql(u8, fn_name_s, "read") or
                        std.mem.eql(u8, fn_name_s, "write") or
                        std.mem.eql(u8, fn_name_s, "close") or
                        std.mem.eql(u8, fn_name_s, "sysconf") or
                        std.mem.eql(u8, fn_name_s, "gettimeofday") or
                        std.mem.eql(u8, fn_name_s, "poll")
                    ));
                if (!is_libc) {
                    // Split mode: only stub symbols this unit owns — the other
                    // unit holds the real definition (stubbing it here would
                    // collide at link). The entry unit additionally stubs
                    // leftover synthetic names owned by no module (mirrors
                    // legacy whole-program behavior).
                    if (split and !owned_names.contains(fn_name_s) and
                        !(is_entry and !dep_owned_types.contains(fn_name_s) and !dep_owned_fns.contains(fn_name_s)))
                    {
                        continue;
                    }
                    self.emitFunctionStub(mod, fn_name_s) catch {};
                }
            }
        }

        try self.emitNonGCHelpers(mod);
        // Split mode: helpers/intrinsics and anonymous lambdas (all created
        // during body emission) become internal so each unit's object carries
        // a private copy — run AFTER every body is emitted.
        self.makeHelpersInternal(mod);
        // Split mode: program entry (argv support + main shim) lives only in
        // the entry unit.
        if (!split or is_entry) {
            try self.emitArgvSupport(mod);
            try self.emitEntryShim(mod, &modules);
        }
    }

    fn emitNonGCHelpers(self: *LLVMEmitter, mod: llvm.LLVMModuleRef) !void {
        if (prefer_gc_alloc) return;

        // GC_init -> ret void
        if (llvm.LLVMGetNamedFunction(mod, "GC_init")) |f| {
            if (llvm.LLVMCountBasicBlocks(f) == 0) {
                const bb = llvm.LLVMAppendBasicBlockInContext(self.context, f, "entry");
                llvm.LLVMPositionBuilderAtEnd(self.builder, bb);
                _ = llvm.LLVMBuildRetVoid(self.builder);
            }
        }
        // GC_allow_register_threads -> ret void
        if (llvm.LLVMGetNamedFunction(mod, "GC_allow_register_threads")) |f| {
            if (llvm.LLVMCountBasicBlocks(f) == 0) {
                const bb = llvm.LLVMAppendBasicBlockInContext(self.context, f, "entry");
                llvm.LLVMPositionBuilderAtEnd(self.builder, bb);
                _ = llvm.LLVMBuildRetVoid(self.builder);
            }
        }
        // GC_get_stack_base -> ret 0
        if (llvm.LLVMGetNamedFunction(mod, "GC_get_stack_base")) |f| {
            if (llvm.LLVMCountBasicBlocks(f) == 0) {
                const bb = llvm.LLVMAppendBasicBlockInContext(self.context, f, "entry");
                llvm.LLVMPositionBuilderAtEnd(self.builder, bb);
                const ret_type = llvm.LLVMGetReturnType(llvm.LLVMGlobalGetValueType(f));
                _ = llvm.LLVMBuildRet(self.builder, llvm.LLVMConstNull(ret_type));
            }
        }
        // GC_register_my_thread -> ret 0
        if (llvm.LLVMGetNamedFunction(mod, "GC_register_my_thread")) |f| {
            if (llvm.LLVMCountBasicBlocks(f) == 0) {
                const bb = llvm.LLVMAppendBasicBlockInContext(self.context, f, "entry");
                llvm.LLVMPositionBuilderAtEnd(self.builder, bb);
                const ret_type = llvm.LLVMGetReturnType(llvm.LLVMGlobalGetValueType(f));
                _ = llvm.LLVMBuildRet(self.builder, llvm.LLVMConstNull(ret_type));
            }
        }
        // GC_unregister_my_thread -> ret 0
        if (llvm.LLVMGetNamedFunction(mod, "GC_unregister_my_thread")) |f| {
            if (llvm.LLVMCountBasicBlocks(f) == 0) {
                const bb = llvm.LLVMAppendBasicBlockInContext(self.context, f, "entry");
                llvm.LLVMPositionBuilderAtEnd(self.builder, bb);
                const ret_type = llvm.LLVMGetReturnType(llvm.LLVMGlobalGetValueType(f));
                _ = llvm.LLVMBuildRet(self.builder, llvm.LLVMConstNull(ret_type));
            }
        }
        // GC_malloc -> call malloc
        if (llvm.LLVMGetNamedFunction(mod, "GC_malloc")) |f| {
            if (llvm.LLVMCountBasicBlocks(f) == 0) {
                const bb = llvm.LLVMAppendBasicBlockInContext(self.context, f, "entry");
                llvm.LLVMPositionBuilderAtEnd(self.builder, bb);
                const size_val = llvm.LLVMGetParam(f, 0);
                const malloc_fn = llvm.LLVMGetNamedFunction(mod, "malloc").?;
                const m_type = llvm.LLVMGlobalGetValueType(malloc_fn);
                var args = [_]llvm.LLVMValueRef{size_val};
                const res = llvm.LLVMBuildCall2(self.builder, m_type, malloc_fn, &args, 1, "gc_m");
                _ = llvm.LLVMBuildRet(self.builder, res);
            }
        }
        // GC_malloc_uncollectable -> call malloc
        if (llvm.LLVMGetNamedFunction(mod, "GC_malloc_uncollectable")) |f| {
            if (llvm.LLVMCountBasicBlocks(f) == 0) {
                const bb = llvm.LLVMAppendBasicBlockInContext(self.context, f, "entry");
                llvm.LLVMPositionBuilderAtEnd(self.builder, bb);
                const size_val = llvm.LLVMGetParam(f, 0);
                const malloc_fn = llvm.LLVMGetNamedFunction(mod, "malloc").?;
                const m_type = llvm.LLVMGlobalGetValueType(malloc_fn);
                var args = [_]llvm.LLVMValueRef{size_val};
                const res = llvm.LLVMBuildCall2(self.builder, m_type, malloc_fn, &args, 1, "gc_mu");
                _ = llvm.LLVMBuildRet(self.builder, res);
            }
        }
        // GC_realloc -> call realloc
        if (llvm.LLVMGetNamedFunction(mod, "GC_realloc")) |f| {
            if (llvm.LLVMCountBasicBlocks(f) == 0) {
                const bb = llvm.LLVMAppendBasicBlockInContext(self.context, f, "entry");
                llvm.LLVMPositionBuilderAtEnd(self.builder, bb);
                const ptr_val = llvm.LLVMGetParam(f, 0);
                const size_val = llvm.LLVMGetParam(f, 1);
                const realloc_fn = llvm.LLVMGetNamedFunction(mod, "realloc").?;
                const r_type = llvm.LLVMGlobalGetValueType(realloc_fn);
                var args = [_]llvm.LLVMValueRef{ ptr_val, size_val };
                const res = llvm.LLVMBuildCall2(self.builder, r_type, realloc_fn, &args, 2, "gc_r");
                _ = llvm.LLVMBuildRet(self.builder, res);
            }
        }
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

        const is_windows = if (self.target_info) |ti| ti.os_tag == .windows else (builtin.target.os.tag == .windows);
        if (is_windows) {
            if (llvm.LLVMGetNamedGlobal(mod, "_fltused") == null) {
                const fltused = llvm.LLVMAddGlobal(mod, i32_type, "_fltused");
                llvm.LLVMSetInitializer(fltused, llvm.LLVMConstInt(i32_type, 1, 0));
            }
        }

        if (llvm.LLVMGetNamedFunction(mod, "GC_init")) |gc_init| {
            const gci_type = llvm.LLVMGlobalGetValueType(gc_init);
            _ = llvm.LLVMBuildCall2(self.builder, gci_type, gc_init, null, 0, "");
        }
        if (llvm.LLVMGetNamedFunction(mod, "GC_allow_register_threads")) |gc_allow| {
            const gca_type = llvm.LLVMGlobalGetValueType(gc_allow);
            _ = llvm.LLVMBuildCall2(self.builder, gca_type, gc_allow, null, 0, "");
        }

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


    fn declareEnum(self: *LLVMEmitter, mod: llvm.LLVMModuleRef, node: *ast.ASTNode, define: bool) !void {
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
            // Split mode: only the owning unit defines the variant global;
            // other units reference it as an extern declaration.
            if (define) llvm.LLVMSetInitializer(global, llvm.LLVMConstNull(ptr_type));
        }
    }

    fn emitEnumInitializers(
        self: *LLVMEmitter,
        mod: llvm.LLVMModuleRef,
        modules: *ArrayList(*ast.ASTNode),
    ) !void {
        const ptr_type = llvm.LLVMPointerTypeInContext(self.context, 0);
        const i64_type = llvm.LLVMInt64TypeInContext(self.context);

        const gc_func = getHeapUncollectableAllocFn(mod);
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

                        // Field 2: name (%core_String { ptr, length })
                        var name_buf_args = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, variant.name.len + 1, 0)};
                        const name_buf = llvm.LLVMBuildCall2(self.builder, gc_type, gc_func, &name_buf_args, 1, "enum_name_buf");
                        const i8_type = llvm.LLVMInt8TypeInContext(self.context);
                        for (variant.name, 0..) |c, ci| {
                            var b_idx = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, @intCast(ci), 0)};
                            const b_ptr = llvm.LLVMBuildGEP2(self.builder, i8_type, name_buf, &b_idx, 1, "b_ptr");
                            _ = llvm.LLVMBuildStore(self.builder, llvm.LLVMConstInt(i8_type, c, 0), b_ptr);
                        }
                        var nul_idx = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, variant.name.len, 0)};
                        const nul_ptr = llvm.LLVMBuildGEP2(self.builder, i8_type, name_buf, &nul_idx, 1, "nul_ptr");
                        _ = llvm.LLVMBuildStore(self.builder, llvm.LLVMConstInt(i8_type, 0, 0), nul_ptr);

                        var str_inst_args = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, 16, 0)};
                        const str_inst = llvm.LLVMBuildCall2(self.builder, gc_type, gc_func, &str_inst_args, 1, "enum_str_inst");
                        var inst_fields = [_]llvm.LLVMTypeRef{ ptr_type, i64_type };
                        const inst_struct_t = llvm.LLVMStructTypeInContext(self.context, &inst_fields, 2, 0);
                        const f0_ptr = llvm.LLVMBuildStructGEP2(self.builder, inst_struct_t, str_inst, 0, "f0_ptr");
                        _ = llvm.LLVMBuildStore(self.builder, name_buf, f0_ptr);
                        const f1_ptr = llvm.LLVMBuildStructGEP2(self.builder, inst_struct_t, str_inst, 1, "f1_ptr");
                        _ = llvm.LLVMBuildStore(self.builder, llvm.LLVMConstInt(i64_type, variant.name.len, 0), f1_ptr);

                        const name_ptr = llvm.LLVMBuildStructGEP2(self.builder, s_info.struct_type, inst_ptr, 2, "enum_name");
                        _ = llvm.LLVMBuildStore(self.builder, str_inst, name_ptr);

                        _ = llvm.LLVMBuildStore(self.builder, inst_ptr, global);
                    }
                }
            }
        }
    }

    fn tryGetConstLLVMValue(node: *ast.ASTNode, llvm_type: llvm.LLVMTypeRef) ?llvm.LLVMValueRef {
        return switch (node.data) {
            .int_literal => |val| llvm.LLVMConstInt(llvm_type, @bitCast(val), 1),
            .bool_literal => |val| llvm.LLVMConstInt(llvm_type, if (val) 1 else 0, 0),
            .double_literal => |val| llvm.LLVMConstReal(llvm_type, val),
            .null_literal => llvm.LLVMConstNull(llvm_type),
            .unary_expr => |u| {
                if (u.operator == .minus and u.operand.data == .int_literal) {
                    return llvm.LLVMConstInt(llvm_type, @bitCast(-u.operand.data.int_literal), 1);
                } else if (u.operator == .minus and u.operand.data == .double_literal) {
                    return llvm.LLVMConstReal(llvm_type, -u.operand.data.double_literal);
                } else if (u.operator == .bang and u.operand.data == .bool_literal) {
                    return llvm.LLVMConstInt(llvm_type, if (u.operand.data.bool_literal) 0 else 1, 0);
                }
                return null;
            },
            else => null,
        };
    }

    fn emitObjectInitializers(
        self: *LLVMEmitter,
        mod: llvm.LLVMModuleRef,
        modules: *ArrayList(*ast.ASTNode),
        scope: *std.StringHashMap(llvm.LLVMValueRef),
    ) !void {
        const ptr_type = llvm.LLVMPointerTypeInContext(self.context, 0);
        const i64_type = llvm.LLVMInt64TypeInContext(self.context);
        const gc_uncoll = getHeapUncollectableAllocFn(mod);
        const gc_uncoll_type = llvm.LLVMGlobalGetValueType(gc_uncoll);

        var total_vars: usize = 0;
        for (modules.items) |m| {
            if (m.data != .program) continue;
            for (m.data.program.statements) |stmt| {
                if (stmt.data != .object_decl) continue;
                if (!self.matchesTarget(stmt.data.object_decl.platform_targets)) continue;
                for (stmt.data.object_decl.members) |member| {
                    if (member.data == .var_decl and member.data.var_decl.initializer != null) {
                        const v = member.data.var_decl;
                        const llvm_type = if (member.resolved_type) |rt|
                            types_mapping.getLLVMType(self.context, rt.*)
                        else
                            llvm.LLVMInt64TypeInContext(self.context);
                        if (tryGetConstLLVMValue(v.initializer.?, llvm_type) == null) {
                            total_vars += 1;
                        }
                    }
                }
            }
        }

        var roots_table: ?llvm.LLVMValueRef = null;
        if (total_vars > 0) {
            const table_size = llvm.LLVMConstInt(i64_type, @intCast(total_vars * 16), 0);
            var alloc_args = [_]llvm.LLVMValueRef{table_size};
            roots_table = llvm.LLVMBuildCall2(self.builder, gc_uncoll_type, gc_uncoll, &alloc_args, 1, "gc_roots_table");
            const roots_global = llvm.LLVMAddGlobal(mod, ptr_type, "__eiwa_gc_roots_table");
            llvm.LLVMSetInitializer(roots_global, llvm.LLVMConstNull(ptr_type));
            _ = llvm.LLVMBuildStore(self.builder, roots_table.?, roots_global);
        }

        var var_idx: usize = 0;
        for (modules.items) |m| {
            if (m.data != .program) continue;
            for (m.data.program.statements) |stmt| {
                if (stmt.data != .object_decl) continue;
                const obj = stmt.data.object_decl;
                if (!self.matchesTarget(obj.platform_targets)) continue;
                const obj_c_name = obj.resolved_c_name orelse (obj.name orelse "Object");
                for (obj.members) |member| {
                    if (member.data != .var_decl) continue;
                    const v = member.data.var_decl;
                    const init_expr = v.initializer orelse continue;
                    const llvm_type = if (member.resolved_type) |rt|
                        types_mapping.getLLVMType(self.context, rt.*)
                    else
                        llvm.LLVMInt64TypeInContext(self.context);
                    if (tryGetConstLLVMValue(init_expr, llvm_type) != null) continue;
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
                        if (roots_table) |rt_val| {
                            var elem_idx = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, @intCast(var_idx), 0)};
                            const slot_ptr = llvm.LLVMBuildGEP2(self.builder, ptr_type, rt_val, &elem_idx, 1, "root_slot");
                            var ptr_val = val;
                            if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(ptr_val)) == llvm.LLVMStructTypeKind) {
                                ptr_val = llvm.LLVMBuildExtractValue(self.builder, ptr_val, 0, "root_data_ptr");
                            }
                            ptr_val = expression.coerceArg(self.builder, ptr_val, ptr_type);
                            _ = llvm.LLVMBuildStore(self.builder, ptr_val, slot_ptr);
                            var_idx += 1;
                        }
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

        // Mark related mangled variants: monomorphized methods and helpers
        // are named after their type (`{name}_*`, `*_{name}_*`, `*_{name}`),
        // so marking a base name must pull them in. The token index narrows
        // this from a full scan of `functions` to a small candidate set.
        if (try self.fnCandidates(name)) |candidates| {
            for (candidates) |k| {
                if (matchesRelatedName(k, name)) try markReachableExact(self.allocator, k, reachable, worklist);
            }
        } else {
            var it = self.functions.keyIterator();
            while (it.next()) |k| {
                if (matchesRelatedName(k.*, name)) try markReachableExact(self.allocator, k.*, reachable, worklist);
            }
        }
    }

    fn markReachableExact(
        allocator: std.mem.Allocator,
        name: []const u8,
        reachable: *std.StringHashMap(void),
        worklist: *ArrayList([]const u8),
    ) !void {
        if (reachable.contains(name)) return;
        const func_owned = try allocator.dupe(u8, name);
        try reachable.put(func_owned, {});
        try worklist.append(func_owned);
    }

    /// True when `k` equals `name` or contains it as an underscore-delimited
    /// component run (`name_*`, `*_name_*`, `*_name`). Allocation-free
    /// equivalent of the old prefix/suffix string checks.
    fn matchesRelatedName(k: []const u8, name: []const u8) bool {
        if (std.mem.eql(u8, k, name)) return true;
        if (k.len <= name.len) return false;
        // prefix: k == name ++ "_" ++ rest
        if (k[name.len] == '_' and std.mem.eql(u8, k[0..name.len], name)) return true;
        // suffix: k == rest ++ "_" ++ name
        if (k[k.len - name.len - 1] == '_' and std.mem.endsWith(u8, k, name)) return true;
        // infix: k contains "_" ++ name ++ "_"
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, k, pos, name)) |i| {
            if (i > 0 and k[i - 1] == '_' and i + name.len < k.len and k[i + name.len] == '_') return true;
            pos = i + 1;
        }
        return false;
    }

    /// Builds (or rebuilds, when `functions` has grown) the token index over
    /// function names. Keys are borrowed from `functions`, so the index must
    /// be rebuilt if that map is mutated — the count check covers growth;
    /// the reachability passes only add entries, never remove/rehash keys.
    fn ensureFnTokenIndex(self: *LLVMEmitter) !void {
        if (self.fn_token_index != null and self.fn_token_index_count == self.functions.count()) return;
        if (self.fn_token_index) |*idx| {
            var tok_it = idx.valueIterator();
            while (tok_it.next()) |v| v.deinit();
            idx.deinit();
        }
        var index = std.StringHashMap(ArrayList([]const u8)).init(self.allocator);
        errdefer index.deinit();
        var kit = self.functions.keyIterator();
        while (kit.next()) |k| {
            const key = k.*;
            var tok_it = std.mem.splitScalar(u8, key, '_');
            while (tok_it.next()) |tok| {
                if (tok.len == 0) continue;
                const gop = try index.getOrPut(tok);
                if (!gop.found_existing) {
                    gop.value_ptr.* = ArrayList([]const u8).init(self.allocator);
                } else if (gop.value_ptr.items[gop.value_ptr.items.len - 1].ptr == key.ptr) {
                    // Same key, repeated token: occurrences of one key are
                    // appended consecutively, so comparing with the last
                    // append dedupes them.
                    continue;
                }
                try gop.value_ptr.append(key);
            }
        }
        self.fn_token_index = index;
        self.fn_token_index_count = self.functions.count();
    }

    /// Returns the smallest token bucket that any key related to `query`
    /// must belong to (a related key contains every token of `query`, so the
    /// rarest token's bucket is a superset of all matches). Empty slice when
    /// no key can match; null when `query` has no usable token and the
    /// caller must fall back to a full scan.
    fn fnCandidates(self: *LLVMEmitter, query: []const u8) !?[]const []const u8 {
        try self.ensureFnTokenIndex();
        const index = &self.fn_token_index.?;
        var best: ?[]const []const u8 = null;
        var tok_it = std.mem.splitScalar(u8, query, '_');
        while (tok_it.next()) |tok| {
            if (tok.len == 0) continue;
            if (index.get(tok)) |bucket| {
                if (best == null or bucket.items.len < best.?.len) best = bucket.items;
            } else {
                return &.{}; // a required token appears in no key at all
            }
        }
        return best;
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
                    const t_name = t.resolved_c_name orelse t.name;
                    for (t.methods) |m_node| {
                        if (m_node.data != .fun_decl) continue;
                        if (m_node.data.fun_decl.generic_params.len > 0) continue;
                        const name = m_node.data.fun_decl.resolved_c_name orelse m_node.data.fun_decl.name;
                        if (!index.contains(name)) try index.put(name, m_node);
                        const mangled = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ t_name, m_node.data.fun_decl.name });
                        if (!index.contains(mangled)) try index.put(mangled, m_node);
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
        if (self.classes_ast) |ca| {
            var c_it = ca.iterator();
            while (c_it.next()) |entry| {
                const c_node = entry.value_ptr.*;
                if (c_node.data == .type_decl) {
                    const t = c_node.data.type_decl;
                    if (t.generic_params.len > 0) continue;
                    const t_name = t.resolved_c_name orelse t.name;
                    for (t.methods) |m_node| {
                        if (m_node.data != .fun_decl) continue;
                        if (m_node.data.fun_decl.generic_params.len > 0) continue;
                        const name = m_node.data.fun_decl.resolved_c_name orelse m_node.data.fun_decl.name;
                        if (!index.contains(name)) try index.put(name, m_node);
                        const mangled = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ t_name, m_node.data.fun_decl.name });
                        if (!index.contains(mangled)) try index.put(mangled, m_node);
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
                if (b.op == .plus) {
                    if (b.left.resolved_type) |lt| {
                        const l_base = ts.extractBaseType(lt);
                        if (l_base.* == .Custom) {
                            const buf = try std.fmt.allocPrint(self.allocator, "{s}_toString", .{l_base.Custom});
                            try self.markReachable(buf, reachable, worklist);
                            self.allocator.free(buf);
                        }
                    }
                    if (b.right.resolved_type) |rt| {
                        const r_base = ts.extractBaseType(rt);
                        if (r_base.* == .Custom) {
                            const buf = try std.fmt.allocPrint(self.allocator, "{s}_toString", .{r_base.Custom});
                            try self.markReachable(buf, reachable, worklist);
                            self.allocator.free(buf);
                        }
                    }
                }
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
            .identifier => |i| {
                if (self.libs.get(i.name) != null) {
                    try self.used_libs.put(i.name, {});
                }
            },
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
                    if (type_name.len > 0) {
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
                    try self.markReachable(name, reachable, worklist);
                } else if (c.callee.data == .get_expr) {
                    const g = c.callee.data.get_expr;
                    // FFI lib method call: object is an identifier naming a lib.
                    if (g.object.data == .identifier and self.libs.get(g.object.data.identifier.name) != null) {
                        try self.used_libs.put(g.object.data.identifier.name, {});
                    } else {
                        // Object/static method call resolved to an exact mangled symbol.
                        if (c.callee.resolved_type) |rt| {
                            if (rt.* == .Function and rt.Function.c_name.len > 0) {
                                try self.markReachable(rt.Function.c_name, reachable, worklist);
                            }
                        }
                        const obj_rt_opt = g.object.resolved_type orelse blk: {
                            if (c.callee.resolved_type) |crt| {
                                if (crt.* == .Function) {
                                    if (crt.Function.receiver != null) break :blk crt.Function.receiver.?;
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

    /// Emits standard library intrinsics used for string conversion, pointer
    /// access, and byte-level operations.
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

        try self.emitAtomicHelpers(mod);
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
        const false_bb = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "is_false");
        const small_bb = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "is_small");
        const int_bb = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "is_int");
        const str_bb = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "is_str");

        var inst_fields = [_]llvm.LLVMTypeRef{ ptr_type, i64_type };
        const inst_struct_t = llvm.LLVMStructTypeInContext(self.context, &inst_fields, 2, 0);
        const i32_type = llvm.LLVMInt32TypeInContext(self.context);

        var idx0 = [_]llvm.LLVMValueRef{ llvm.LLVMConstInt(i64_type, 0, 0), llvm.LLVMConstInt(i32_type, 0, 0) };
        var idx1 = [_]llvm.LLVMValueRef{ llvm.LLVMConstInt(i64_type, 0, 0), llvm.LLVMConstInt(i32_type, 1, 0) };

        const gc_func = getHeapAllocFn(mod);
        const gc_type = llvm.LLVMGlobalGetValueType(gc_func);

        llvm.LLVMPositionBuilderAtEnd(self.builder, entry);
        const val = llvm.LLVMGetParam(fn_val, 0);
        const null_ptr = llvm.LLVMConstNull(ptr_type);
        const is_null = llvm.LLVMBuildICmp(self.builder, llvm.LLVMIntEQ, val, null_ptr, "ts_null");
        _ = llvm.LLVMBuildCondBr(self.builder, is_null, null_bb, bool_bb);

        const i8_type = llvm.LLVMInt8TypeInContext(self.context);

        llvm.LLVMPositionBuilderAtEnd(self.builder, null_bb);
        var ga5 = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, 5, 0)};
        const null_buf = llvm.LLVMBuildCall2(self.builder, gc_type, gc_func, &ga5, 1, "null_buf");
        for ("null\x00", 0..) |c, i| {
            var b_idx = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, @intCast(i), 0)};
            const b_ptr = llvm.LLVMBuildGEP2(self.builder, i8_type, null_buf, &b_idx, 1, "nb_ptr");
            _ = llvm.LLVMBuildStore(self.builder, llvm.LLVMConstInt(i8_type, c, 0), b_ptr);
        }
        var ga16 = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, 16, 0)};
        const raw_null = llvm.LLVMBuildCall2(self.builder, gc_type, gc_func, &ga16, 1, "raw_null");
        const f0_null = llvm.LLVMBuildGEP2(self.builder, inst_struct_t, raw_null, &idx0, 2, "f0_null");
        _ = llvm.LLVMBuildStore(self.builder, null_buf, f0_null);
        const f1_null = llvm.LLVMBuildGEP2(self.builder, inst_struct_t, raw_null, &idx1, 2, "f1_null");
        _ = llvm.LLVMBuildStore(self.builder, llvm.LLVMConstInt(i64_type, 4, 0), f1_null);
        _ = llvm.LLVMBuildRet(self.builder, raw_null);

        llvm.LLVMPositionBuilderAtEnd(self.builder, bool_bb);
        const int_val = llvm.LLVMBuildPtrToInt(self.builder, val, i64_type, "ts_int");
        const one = llvm.LLVMConstInt(i64_type, 1, 0);
        const is_one = llvm.LLVMBuildICmp(self.builder, llvm.LLVMIntEQ, int_val, one, "ts_one");
        const is_zero = llvm.LLVMBuildICmp(self.builder, llvm.LLVMIntEQ, int_val, llvm.LLVMConstInt(i64_type, 0, 0), "ts_zero");
        const not_one_bb = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "ts_not_one");
        _ = llvm.LLVMBuildCondBr(self.builder, is_one, true_bb, not_one_bb);

        llvm.LLVMPositionBuilderAtEnd(self.builder, not_one_bb);
        _ = llvm.LLVMBuildCondBr(self.builder, is_zero, false_bb, small_bb);

        llvm.LLVMPositionBuilderAtEnd(self.builder, true_bb);
        const true_buf = llvm.LLVMBuildCall2(self.builder, gc_type, gc_func, &ga5, 1, "true_buf");
        for ("true\x00", 0..) |c, i| {
            var b_idx = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, @intCast(i), 0)};
            const b_ptr = llvm.LLVMBuildGEP2(self.builder, i8_type, true_buf, &b_idx, 1, "tb_ptr");
            _ = llvm.LLVMBuildStore(self.builder, llvm.LLVMConstInt(i8_type, c, 0), b_ptr);
        }
        const raw_true = llvm.LLVMBuildCall2(self.builder, gc_type, gc_func, &ga16, 1, "raw_true");
        const f0_true = llvm.LLVMBuildGEP2(self.builder, inst_struct_t, raw_true, &idx0, 2, "f0_true");
        _ = llvm.LLVMBuildStore(self.builder, true_buf, f0_true);
        const f1_true = llvm.LLVMBuildGEP2(self.builder, inst_struct_t, raw_true, &idx1, 2, "f1_true");
        _ = llvm.LLVMBuildStore(self.builder, llvm.LLVMConstInt(i64_type, 4, 0), f1_true);
        _ = llvm.LLVMBuildRet(self.builder, raw_true);

        llvm.LLVMPositionBuilderAtEnd(self.builder, false_bb);
        var ga6 = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, 6, 0)};
        const false_buf = llvm.LLVMBuildCall2(self.builder, gc_type, gc_func, &ga6, 1, "false_buf");
        for ("false\x00", 0..) |c, i| {
            var b_idx = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(i64_type, @intCast(i), 0)};
            const b_ptr = llvm.LLVMBuildGEP2(self.builder, i8_type, false_buf, &b_idx, 1, "fb_ptr");
            _ = llvm.LLVMBuildStore(self.builder, llvm.LLVMConstInt(i8_type, c, 0), b_ptr);
        }
        const raw_false = llvm.LLVMBuildCall2(self.builder, gc_type, gc_func, &ga16, 1, "raw_false");
        const f0_false = llvm.LLVMBuildGEP2(self.builder, inst_struct_t, raw_false, &idx0, 2, "f0_false");
        _ = llvm.LLVMBuildStore(self.builder, false_buf, f0_false);
        const f1_false = llvm.LLVMBuildGEP2(self.builder, inst_struct_t, raw_false, &idx1, 2, "f1_false");
        _ = llvm.LLVMBuildStore(self.builder, llvm.LLVMConstInt(i64_type, 5, 0), f1_false);
        _ = llvm.LLVMBuildRet(self.builder, raw_false);

        llvm.LLVMPositionBuilderAtEnd(self.builder, small_bb);
        const max_small = llvm.LLVMConstInt(i64_type, 0x10000, 0);
        const is_small = llvm.LLVMBuildICmp(self.builder, llvm.LLVMIntULT, int_val, max_small, "ts_small");
        _ = llvm.LLVMBuildCondBr(self.builder, is_small, int_bb, str_bb);

        llvm.LLVMPositionBuilderAtEnd(self.builder, int_bb);
        const buf_size = llvm.LLVMConstInt(i64_type, 32, 0);
        var gc_args = [_]llvm.LLVMValueRef{buf_size};
        const buf = llvm.LLVMBuildCall2(self.builder, gc_type, gc_func, &gc_args, 1, "ts_buf");

        const sprintf_func = llvm.LLVMGetNamedFunction(mod, "sprintf") orelse return error.SprintfNotFound;
        const sprintf_type = llvm.LLVMGlobalGetValueType(sprintf_func);
        const fmt = llvm.LLVMBuildGlobalStringPtr(self.builder, "%lld", "ts_fmt");
        var sp_args = [_]llvm.LLVMValueRef{ buf, fmt, int_val };
        _ = llvm.LLVMBuildCall2(self.builder, sprintf_type, sprintf_func, &sp_args, 3, "ts_sprintf");

        const strlen_func = llvm.LLVMGetNamedFunction(mod, "strlen") orelse blk: {
            var ps = [_]llvm.LLVMTypeRef{ptr_type};
            const ft = llvm.LLVMFunctionType(i64_type, &ps, 1, 0);
            break :blk llvm.LLVMAddFunction(mod, "strlen", ft);
        };
        const strlen_type = llvm.LLVMGlobalGetValueType(strlen_func);
        var sl_args = [_]llvm.LLVMValueRef{buf};
        const int_len = llvm.LLVMBuildCall2(self.builder, strlen_type, strlen_func, &sl_args, 1, "int_len");

        const raw_int = llvm.LLVMBuildCall2(self.builder, gc_type, gc_func, &ga16, 1, "raw_int");
        const f0_int = llvm.LLVMBuildGEP2(self.builder, inst_struct_t, raw_int, &idx0, 2, "f0_int");
        _ = llvm.LLVMBuildStore(self.builder, buf, f0_int);
        const f1_int = llvm.LLVMBuildGEP2(self.builder, inst_struct_t, raw_int, &idx1, 2, "f1_int");
        _ = llvm.LLVMBuildStore(self.builder, int_len, f1_int);
        _ = llvm.LLVMBuildRet(self.builder, raw_int);

        llvm.LLVMPositionBuilderAtEnd(self.builder, str_bb);
        _ = llvm.LLVMBuildRet(self.builder, val);
    }



    /// Emits `eiwa_str_replace(i8* s, i8* old, i8* new) -> i8*` — replaces all
    /// occurrences of `old` with `new` in `s`, allocating with the active heap allocator.
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
        const i64_type = llvm.LLVMInt64TypeInContext(self.context);

        var inst_fields = [_]llvm.LLVMTypeRef{ ptr_type, i64_type };
        const inst_struct_t = llvm.LLVMStructTypeInContext(self.context, &inst_fields, 2, 0);

        var params = [_]llvm.LLVMTypeRef{ ptr_type, ptr_type };
        const fn_type = llvm.LLVMFunctionType(i1_type, &params, 2, 0);
        const fn_val = llvm.LLVMAddFunction(mod, "eiwa_string_equals", fn_type);

        const entry = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const ptr_diff = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "ptr_diff");
        const check_len = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "check_len");
        const do_strcmp = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "do_strcmp");
        const ret_false = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "ret_false");
        const ret_true = llvm.LLVMAppendBasicBlockInContext(self.context, fn_val, "ret_true");

        llvm.LLVMPositionBuilderAtEnd(self.builder, entry);
        const a = llvm.LLVMGetParam(fn_val, 0);
        const b = llvm.LLVMGetParam(fn_val, 1);
        const is_same = llvm.LLVMBuildICmp(self.builder, llvm.LLVMIntEQ, a, b, "seq_same");
        _ = llvm.LLVMBuildCondBr(self.builder, is_same, ret_true, ptr_diff);

        llvm.LLVMPositionBuilderAtEnd(self.builder, ptr_diff);
        const a_null = llvm.LLVMBuildIsNull(self.builder, a, "a_null");
        const b_null = llvm.LLVMBuildIsNull(self.builder, b, "b_null");
        const any_null = llvm.LLVMBuildOr(self.builder, a_null, b_null, "any_null");
        _ = llvm.LLVMBuildCondBr(self.builder, any_null, ret_false, check_len);

        llvm.LLVMPositionBuilderAtEnd(self.builder, check_len);
        const a_len_ptr = llvm.LLVMBuildStructGEP2(self.builder, inst_struct_t, a, 1, "a_len_ptr");
        const b_len_ptr = llvm.LLVMBuildStructGEP2(self.builder, inst_struct_t, b, 1, "b_len_ptr");
        const a_len = llvm.LLVMBuildLoad2(self.builder, i64_type, a_len_ptr, "a_len");
        const b_len = llvm.LLVMBuildLoad2(self.builder, i64_type, b_len_ptr, "b_len");
        const len_eq = llvm.LLVMBuildICmp(self.builder, llvm.LLVMIntEQ, a_len, b_len, "len_eq");
        _ = llvm.LLVMBuildCondBr(self.builder, len_eq, do_strcmp, ret_false);

        llvm.LLVMPositionBuilderAtEnd(self.builder, do_strcmp);
        const a_data_ptr = llvm.LLVMBuildStructGEP2(self.builder, inst_struct_t, a, 0, "a_data_ptr");
        const b_data_ptr = llvm.LLVMBuildStructGEP2(self.builder, inst_struct_t, b, 0, "b_data_ptr");
        const a_data = llvm.LLVMBuildLoad2(self.builder, ptr_type, a_data_ptr, "a_data");
        const b_data = llvm.LLVMBuildLoad2(self.builder, ptr_type, b_data_ptr, "b_data");

        const strcmp_fn = llvm.LLVMGetNamedFunction(mod, "strcmp") orelse blk: {
            var ps = [_]llvm.LLVMTypeRef{ ptr_type, ptr_type };
            const ft = llvm.LLVMFunctionType(i32_type, &ps, 2, 0);
            break :blk llvm.LLVMAddFunction(mod, "strcmp", ft);
        };
        const strcmp_ft = llvm.LLVMGlobalGetValueType(strcmp_fn);
        var args = [_]llvm.LLVMValueRef{ a_data, b_data };
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



    fn emitAtomicHelpers(self: *LLVMEmitter, mod: llvm.LLVMModuleRef) !void {
        const ctx = self.context;
        const b = self.builder;
        const i64_t = llvm.LLVMInt64TypeInContext(ctx);
        const i1_t = llvm.LLVMInt1TypeInContext(ctx);
        const ptr_t = llvm.LLVMPointerTypeInContext(ctx, 0);

        // 1. eiwa_atomic_cas_bool(ptr: Pointer, old_val: Int, new_val: Int) -> Bool
        {
            var params = [_]llvm.LLVMTypeRef{ ptr_t, i64_t, i64_t };
            const fn_t = llvm.LLVMFunctionType(i1_t, &params, 3, 0);
            const func = llvm.LLVMGetNamedFunction(mod, "eiwa_atomic_cas_bool") orelse llvm.LLVMAddFunction(mod, "eiwa_atomic_cas_bool", fn_t);
            if (llvm.LLVMCountBasicBlocks(func) == 0) {
                const bb = llvm.LLVMAppendBasicBlockInContext(ctx, func, "entry");
                llvm.LLVMPositionBuilderAtEnd(b, bb);
                const ptr_param = llvm.LLVMGetParam(func, 0);
                const old_param = llvm.LLVMGetParam(func, 1);
                const new_param = llvm.LLVMGetParam(func, 2);
                const cmpxchg_res = llvm.LLVMBuildAtomicCmpXchg(
                    b,
                    ptr_param,
                    old_param,
                    new_param,
                    llvm.LLVMAtomicOrderingSequentiallyConsistent,
                    llvm.LLVMAtomicOrderingSequentiallyConsistent,
                    0,
                );
                const ok = llvm.LLVMBuildExtractValue(b, cmpxchg_res, 1, "cas_ok");
                _ = llvm.LLVMBuildRet(b, ok);
            }
        }

        // 2. eiwa_atomic_cas_val(ptr: Pointer, old_val: Int, new_val: Int) -> Int
        {
            var params = [_]llvm.LLVMTypeRef{ ptr_t, i64_t, i64_t };
            const fn_t = llvm.LLVMFunctionType(i64_t, &params, 3, 0);
            const func = llvm.LLVMGetNamedFunction(mod, "eiwa_atomic_cas_val") orelse llvm.LLVMAddFunction(mod, "eiwa_atomic_cas_val", fn_t);
            if (llvm.LLVMCountBasicBlocks(func) == 0) {
                const bb = llvm.LLVMAppendBasicBlockInContext(ctx, func, "entry");
                llvm.LLVMPositionBuilderAtEnd(b, bb);
                const ptr_param = llvm.LLVMGetParam(func, 0);
                const old_param = llvm.LLVMGetParam(func, 1);
                const new_param = llvm.LLVMGetParam(func, 2);
                const cmpxchg_res = llvm.LLVMBuildAtomicCmpXchg(
                    b,
                    ptr_param,
                    old_param,
                    new_param,
                    llvm.LLVMAtomicOrderingSequentiallyConsistent,
                    llvm.LLVMAtomicOrderingSequentiallyConsistent,
                    0,
                );
                const old_val_read = llvm.LLVMBuildExtractValue(b, cmpxchg_res, 0, "cas_val");
                _ = llvm.LLVMBuildRet(b, old_val_read);
            }
        }

        // 3. eiwa_atomic_fetch_add(ptr: Pointer, delta: Int) -> Int
        {
            var params = [_]llvm.LLVMTypeRef{ ptr_t, i64_t };
            const fn_t = llvm.LLVMFunctionType(i64_t, &params, 2, 0);
            const func = llvm.LLVMGetNamedFunction(mod, "eiwa_atomic_fetch_add") orelse llvm.LLVMAddFunction(mod, "eiwa_atomic_fetch_add", fn_t);
            if (llvm.LLVMCountBasicBlocks(func) == 0) {
                const bb = llvm.LLVMAppendBasicBlockInContext(ctx, func, "entry");
                llvm.LLVMPositionBuilderAtEnd(b, bb);
                const ptr_param = llvm.LLVMGetParam(func, 0);
                const delta_param = llvm.LLVMGetParam(func, 1);
                const prev = llvm.LLVMBuildAtomicRMW(
                    b,
                    llvm.LLVMAtomicRMWBinOpAdd,
                    ptr_param,
                    delta_param,
                    llvm.LLVMAtomicOrderingSequentiallyConsistent,
                    0,
                );
                _ = llvm.LLVMBuildRet(b, prev);
            }
        }

        // 4. eiwa_atomic_test_and_set(ptr: Pointer, val: Int) -> Int
        {
            var params = [_]llvm.LLVMTypeRef{ ptr_t, i64_t };
            const fn_t = llvm.LLVMFunctionType(i64_t, &params, 2, 0);
            const func = llvm.LLVMGetNamedFunction(mod, "eiwa_atomic_test_and_set") orelse llvm.LLVMAddFunction(mod, "eiwa_atomic_test_and_set", fn_t);
            if (llvm.LLVMCountBasicBlocks(func) == 0) {
                const bb = llvm.LLVMAppendBasicBlockInContext(ctx, func, "entry");
                llvm.LLVMPositionBuilderAtEnd(b, bb);
                const ptr_param = llvm.LLVMGetParam(func, 0);
                const val_param = llvm.LLVMGetParam(func, 1);
                const prev = llvm.LLVMBuildAtomicRMW(
                    b,
                    llvm.LLVMAtomicRMWBinOpXchg,
                    ptr_param,
                    val_param,
                    llvm.LLVMAtomicOrderingSequentiallyConsistent,
                    0,
                );
                _ = llvm.LLVMBuildRet(b, prev);
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

        // struct timeval { i64 tv_sec, i64 tv_usec }
        const tv_type = llvm.LLVMStructCreateNamed(self.context, "struct.timeval");
        var tv_fields = [_]llvm.LLVMTypeRef{ i64_type, i64_type };
        llvm.LLVMStructSetBody(tv_type, &tv_fields, 2, 0);

        const tv_alloca = llvm.LLVMBuildAlloca(self.builder, tv_type, "tv");
        const gtod_fn = llvm.LLVMGetNamedFunction(mod, "gettimeofday") orelse blk: {
            var ps = [_]llvm.LLVMTypeRef{ ptr_type, ptr_type };
            const i32_type = llvm.LLVMInt32TypeInContext(self.context);
            const ft = llvm.LLVMFunctionType(i32_type, &ps, 2, 0);
            break :blk llvm.LLVMAddFunction(mod, "gettimeofday", ft);
        };
        const gtod_ft = llvm.LLVMGlobalGetValueType(gtod_fn);
        var args = [_]llvm.LLVMValueRef{ tv_alloca, llvm.LLVMConstNull(ptr_type) };
        _ = llvm.LLVMBuildCall2(self.builder, gtod_ft, gtod_fn, &args, 2, "");

        const sec_ptr = llvm.LLVMBuildStructGEP2(self.builder, tv_type, tv_alloca, 0, "sec_ptr");
        const sec = llvm.LLVMBuildLoad2(self.builder, i64_type, sec_ptr, "sec");
        const usec_ptr = llvm.LLVMBuildStructGEP2(self.builder, tv_type, tv_alloca, 1, "usec_ptr");
        const usec = llvm.LLVMBuildLoad2(self.builder, i64_type, usec_ptr, "usec");

        const sec_ms = llvm.LLVMBuildMul(self.builder, sec, llvm.LLVMConstInt(i64_type, 1000, 0), "sec_ms");
        const usec_ms = llvm.LLVMBuildSDiv(self.builder, usec, llvm.LLVMConstInt(i64_type, 1000, 0), "usec_ms");
        const total_ms = llvm.LLVMBuildAdd(self.builder, sec_ms, usec_ms, "total_ms");
        _ = llvm.LLVMBuildRet(self.builder, total_ms);
    }

    fn declareLib(self: *LLVMEmitter, mod: llvm.LLVMModuleRef, lib_node: *ast.ASTNode, module_path: ?[]const u8) !void {
        const lib = lib_node.data.lib_decl;
        if (!self.matchesTarget(lib.platform_targets)) return;

        try self.lib_declarations.put(lib.name, .{ .lib_node = lib_node, .module_path = module_path });

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

    fn collectUsedLibAnnotations(self: *LLVMEmitter) !void {
        var it = self.used_libs.keyIterator();
        while (it.next()) |lib_name_ptr| {
            if (self.lib_declarations.get(lib_name_ptr.*)) |entry| {
                const lib = entry.lib_node.data.lib_decl;
                for (lib.annotations) |ann| {
                    if (std.mem.eql(u8, ann.name, "Link")) {
                        for (ann.arguments) |arg| try self.link_libraries.put(arg, {});
                    } else if (std.mem.eql(u8, ann.name, "Source")) {
                        for (ann.arguments) |arg| {
                            if (std.mem.startsWith(u8, arg, "./") or std.mem.startsWith(u8, arg, "../")) {
                                const base = entry.module_path orelse self.source_file;
                                const dir = std.fs.path.dirname(base) orelse ".";
                                try self.c_sources.put(try std.fs.path.join(self.allocator, &.{ dir, arg }), {});
                            } else {
                                try self.c_sources.put(try resolveRepoPath(self.allocator, arg), {});
                            }
                        }
                    } else if (std.mem.eql(u8, ann.name, "Include")) {
                        for (ann.arguments) |arg| {
                            if (std.mem.startsWith(u8, arg, "./") or std.mem.startsWith(u8, arg, "../")) {
                                const base = entry.module_path orelse self.source_file;
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
            }
        }
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
            } else {
                ret_type = types_mapping.getLLVMTypeWithContracts(self.context, ts.EiwaType{ .Custom = tr.name }, self.contracts_ast);
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
            const owned_key = try self.allocator.dupe(u8, c_name);
            try self.functions.put(owned_key, func_val);
        }
    }

    fn declareMethod(self: *LLVMEmitter, mod: llvm.LLVMModuleRef, func_node: *ast.ASTNode, struct_name: []const u8, c_name: []const u8) !void {
        if (func_node.data != .fun_decl) return;
        const f = func_node.data.fun_decl;
        if (f.generic_params.len > 0) return;

        const total_params = 1 + f.params.len;

        const ptr_type_def = llvm.LLVMPointerTypeInContext(self.context, 0);
        var param_types = try self.allocator.alloc(llvm.LLVMTypeRef, total_params);
        defer self.allocator.free(param_types);

        // Parameter 0 is receiver `this`
        param_types[0] = ptr_type_def;

        var ret_type: llvm.LLVMTypeRef = ptr_type_def;

        if (func_node.resolved_type) |rt| {
            if (rt.* == .Function) {
                ret_type = types_mapping.getLLVMTypeWithContracts(self.context, rt.Function.return_type.*, self.contracts_ast);
                for (0..f.params.len) |i| {
                    if (i < rt.Function.params.len) {
                        param_types[1 + i] = types_mapping.getLLVMTypeWithContracts(self.context, rt.Function.params[i].*, self.contracts_ast);
                    } else {
                        param_types[1 + i] = ptr_type_def;
                    }
                }
            }
        } else if (f.type_ref) |tr| {
            if (tr.resolved_type) |rrt| {
                ret_type = types_mapping.getLLVMType(self.context, rrt.*);
            } else {
                ret_type = types_mapping.getLLVMTypeWithContracts(self.context, ts.EiwaType{ .Custom = tr.name }, self.contracts_ast);
            }
            for (0..f.params.len) |i| {
                const p = f.params[i];
                if (p.type_ref) |ptr| {
                    if (ptr.resolved_type) |prt| {
                        param_types[1 + i] = types_mapping.getLLVMType(self.context, prt.*);
                        continue;
                    }
                    param_types[1 + i] = types_mapping.getLLVMTypeWithContracts(self.context, ts.EiwaType{ .Custom = ptr.name }, self.contracts_ast);
                    continue;
                }
                param_types[1 + i] = ptr_type_def;
            }
        } else {
            for (0..f.params.len) |i| {
                const p = f.params[i];
                if (p.type_ref) |ptr| {
                    if (ptr.resolved_type) |prt| {
                        param_types[1 + i] = types_mapping.getLLVMType(self.context, prt.*);
                        continue;
                    }
                    param_types[1 + i] = types_mapping.getLLVMTypeWithContracts(self.context, ts.EiwaType{ .Custom = ptr.name }, self.contracts_ast);
                    continue;
                }
                param_types[1 + i] = ptr_type_def;
            }
        }

        const func_type = llvm.LLVMFunctionType(ret_type, param_types.ptr, @intCast(total_params), 0);

        const name_z = try self.allocator.dupeZ(u8, c_name);
        defer self.allocator.free(name_z);

        const existed = llvm.LLVMGetNamedFunction(mod, name_z.ptr) != null;
        if (!existed) {
            const func_val = llvm.LLVMAddFunction(mod, name_z.ptr, func_type);
            const owned_key = try self.allocator.dupe(u8, c_name);
            try self.functions.put(owned_key, func_val);
        }
        _ = struct_name;
    }

    fn declareType(self: *LLVMEmitter, mod: llvm.LLVMModuleRef, type_node: *ast.ASTNode, define_body: bool) !void {
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

        // Split mode: the constructor body is a definition — only the owning
        // unit emits it; other units keep the extern declaration.
if (define_body) {
        // Emit constructor body
            const entry_block = llvm.LLVMAppendBasicBlockInContext(self.context, ctor_val, "entry");
            llvm.LLVMPositionBuilderAtEnd(self.builder, entry_block);

            // Allocate the instance via the active heap allocator (GC_malloc when
            // prefer_gc_alloc, malloc otherwise) sized to the struct's actual byte size.
            const gc_func = getHeapAllocFn(mod);
            const gc_func_type = llvm.LLVMGlobalGetValueType(gc_func);
            const size_val = llvm.LLVMSizeOf(struct_type);
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
        } // if (define_body)

        // Pass 1a2: Emit member methods inside type
        for (t.methods) |m_node| {
            if (m_node.data == .fun_decl) {
                if (m_node.data.fun_decl.generic_params.len > 0) continue;
                const m_c_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ name, m_node.data.fun_decl.name });
                defer self.allocator.free(m_c_name);
                try self.declareMethod(mod, m_node, name, m_c_name);
                if (m_node.data.fun_decl.resolved_c_name) |rcn| {
                    if (!std.mem.eql(u8, rcn, m_c_name)) {
                        try self.declareMethod(mod, m_node, name, rcn);
                    }
                }
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
    /// no system compiler is on PATH or when cross-compiling to another target.
    fn pickLinkDriver(self: *LLVMEmitter, io: std.Io) []const u8 {
        if (self.target_info) |ti| {
            if (!ti.is_host) return "zig";
        }
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

    fn getProcessId() u32 {
        if (builtin.os.tag == .windows) {
            return @intCast(std.os.windows.GetCurrentProcessId());
        } else {
            return @intCast(std.c.getpid());
        }
    }

    /// Direct native binary emission using LLVMTargetMachineEmitToFile.
    /// Thin wrapper: emit the module to a temp object file, then link.
    /// (Split into emitObjectFile/linkObjects for the incremental cache —
    /// see docs/perf-plan-incremental-cache.md, Phase A2.)
    pub fn emitNativeBinary(self: *LLVMEmitter, output_filename: []const u8, io: std.Io) !void {
        const is_windows = if (self.target_info) |ti| ti.os_tag == .windows else (builtin.target.os.tag == .windows);
        const obj_ext = if (is_windows) "obj" else "o";
        // Unique per process so concurrent eiwac runs in the same directory
        // (e.g. two `eiwa run` builds) never collide on the temp object.
        const obj_filename = try std.fmt.allocPrint(self.allocator, "temp_llvm_{d}.{s}", .{ getProcessId(), obj_ext });
        defer self.allocator.free(obj_filename);

        try self.emitObjectFile(obj_filename);
        defer std.Io.Dir.cwd().deleteFile(io, obj_filename) catch {};

        const obj_paths = [_][]const u8{obj_filename};
        try self.linkObjects(&obj_paths, output_filename, io);
    }

    /// Emits the current LLVM module to an object file at `obj_path`
    /// (verify → optimize → codegen). The module is mutated by the pass
    /// pipeline, so call at most once per module.
    pub fn emitObjectFile(self: *LLVMEmitter, obj_path: []const u8) !void {
        const mod = self.module orelse return error.ModuleAlreadyDisposed;
        try self.collectUsedLibAnnotations();

        const is_host = if (self.target_info) |ti| ti.is_host else true;
        const default_triple_c = if (self.target_info == null) llvm.LLVMGetDefaultTargetTriple() else null;
        defer if (default_triple_c) |dt| llvm.LLVMDisposeMessage(dt);

        var llvm_triple_str: []const u8 = if (self.target_info) |ti| ti.triple else std.mem.span(default_triple_c.?);
        if (self.target_info) |ti| {
            if (ti.os_tag == .windows) {
                llvm_triple_str = if (ti.arch == .aarch64) "aarch64-pc-windows-msvc" else "x86_64-pc-windows-msvc";
            }
        }
        const triple = try self.allocator.dupeZ(u8, llvm_triple_str);
        defer self.allocator.free(triple);

        var target: llvm.LLVMTargetRef = undefined;
        var err_msg: [*c]u8 = null;
        if (llvm.LLVMGetTargetFromTriple(triple, &target, &err_msg) != 0) {
            if (err_msg != null) {
                std.debug.print("LLVM Target Error: {s}\n", .{err_msg});
                llvm.LLVMDisposeMessage(err_msg);
            }
            return error.LLVMTargetError;
        }

        // Host CPU tuning by default when compiling for host; set EIWA_BASELINE_CPU=1 to emit a
        // portable binary (baseline x86_64/arm64, no host-only features like
        // AVX-512). Needed so releases built on modern CI runners keep working
        // on older CPUs / emulators (e.g. Rosetta 2, which lacks AVX-512).
        const use_host_cpu = is_host and (std.c.getenv("EIWA_BASELINE_CPU") == null);
        var cpu: [*c]const u8 = "";
        var features: [*c]const u8 = "";
        if (use_host_cpu) {
            cpu = llvm.LLVMGetHostCPUName();
            features = llvm.LLVMGetHostCPUFeatures();
        }
        defer if (use_host_cpu) llvm.LLVMDisposeMessage(@ptrCast(@constCast(cpu)));

        const opt_level: llvm.LLVMCodeGenOptLevel = if (self.is_release) llvm.LLVMCodeGenLevelAggressive else llvm.LLVMCodeGenLevelNone;

        const reloc_mode: llvm.LLVMRelocMode = if (self.target_info != null and self.target_info.?.os_tag == .windows)
            llvm.LLVMRelocDefault
        else
            llvm.LLVMRelocPIC;

        const target_machine = llvm.LLVMCreateTargetMachine(
            target,
            triple,
            cpu,
            features,
            opt_level,
            reloc_mode,
            llvm.LLVMCodeModelDefault,
        ) orelse return error.LLVMTargetMachineFailed;
        defer llvm.LLVMDisposeTargetMachine(target_machine);

        const target_data = llvm.LLVMCreateTargetDataLayout(target_machine);
        defer llvm.LLVMDisposeTargetData(target_data);
        const data_layout_str = llvm.LLVMCopyStringRepOfTargetData(target_data);
        defer llvm.LLVMDisposeMessage(data_layout_str);

        llvm.LLVMSetTarget(mod, triple);
        llvm.LLVMSetDataLayout(mod, data_layout_str);

        // Verify IR correctness before optimization and machine emission
        {
            var verify_err: [*c]u8 = null;
            if (llvm.LLVMVerifyModule(mod, llvm.LLVMReturnStatusAction, &verify_err) != 0) {
                if (verify_err != null) {
                    const err_slice = std.mem.sliceTo(verify_err, 0);
                    diagnostics.printICE("LLVM module verification failed during native compilation", err_slice);
                    llvm.LLVMDisposeMessage(verify_err);
                } else {
                    diagnostics.printICE("LLVM module verification failed during native compilation", null);
                }
                return error.LLVMVerificationFailed;
            }
        }

        // Run passes
        try self.optimizeModule(target_machine);

        const obj_z = try self.allocator.dupeZ(u8, obj_path);
        defer self.allocator.free(obj_z);

        if (llvm.LLVMTargetMachineEmitToFile(target_machine, mod, obj_z.ptr, llvm.LLVMObjectFile, &err_msg) != 0) {
            if (err_msg != null) {
                std.debug.print("LLVM Emit Object Error: {s}\n", .{err_msg});
                llvm.LLVMDisposeMessage(err_msg);
            }
            return error.LLVMEmitObjectFailed;
        }
    }

    /// Links object files into a native binary. Prefers the system C compiler
    /// (no zig required at runtime); falls back to `zig cc` when no system
    /// compiler is on PATH or when cross-compiling.
    pub fn linkObjects(self: *LLVMEmitter, obj_paths: []const []const u8, output_filename: []const u8, io: std.Io) !void {
        const is_host = if (self.target_info) |ti| ti.is_host else true;
        const link_driver = self.pickLinkDriver(io);
        var cc_argv = ArrayList([]const u8).init(self.allocator);
        defer cc_argv.deinit();

        const opt_flag = if (self.is_release) "-O3" else "-O0";
        try appendLinkDriverPrefix(&cc_argv, link_driver);
        if (self.target_info) |ti| {
            if (!ti.is_host) {
                try cc_argv.appendSlice(&[_][]const u8{ "-target", ti.triple });
            }
        }
        try cc_argv.appendSlice(&[_][]const u8{ opt_flag, "-fwrapv" });
        if (is_host and builtin.target.os.tag == .macos) {
            const brew = if (builtin.target.cpu.arch == .aarch64) "/opt/homebrew" else "/usr/local";
            try cc_argv.appendSlice(&[_][]const u8{ "-I", brew ++ "/include", "-L", brew ++ "/lib" });
        } else if (is_host and (builtin.target.os.tag == .windows or builtin.os.tag == .windows)) {
            var found = false;
            for ([_][*:0]const u8{ "GC_PATH", "LLVM_PATH", "MINGW_PREFIX", "MSYSTEM_PREFIX" }) |key| {
                if (std.c.getenv(key)) |p_z| {
                    const p = std.mem.sliceTo(p_z, 0);
                    const inc = try std.fmt.allocPrint(self.allocator, "{s}/include", .{p});
                    const lib = try std.fmt.allocPrint(self.allocator, "{s}/lib", .{p});
                    try cc_argv.appendSlice(&[_][]const u8{ "-I", inc, "-L", lib });
                    found = true;
                    break;
                }
            }
            if (!found) {
                try cc_argv.appendSlice(&[_][]const u8{ "-I", "C:/msys64/ucrt64/include", "-L", "C:/msys64/ucrt64/lib" });
            }
        }
        for (obj_paths) |p| try cc_argv.append(p);
        try cc_argv.appendSlice(&[_][]const u8{ "-o", output_filename });
        if (is_host or prefer_gc_alloc) {
            try cc_argv.append("-lgc");
        }
        if (self.target_info != null and self.target_info.?.os_tag == .windows) {
            try cc_argv.append("-lws2_32");
        }
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
        try self.collectUsedLibAnnotations();
        if (self.c_sources.count() == 0 and self.c_includes.count() == 0 and self.c_defines.count() == 0 and self.link_libraries.count() == 0) return;

        var h = std.hash.Wyhash.init(0);
        {
            var src_it = self.c_sources.keyIterator();
            while (src_it.next()) |s| {
                h.update(s.*);
                if (std.Io.Dir.cwd().openFile(io, s.*, .{})) |f| {
                    if (f.stat(io)) |st| {
                        h.update(std.mem.asBytes(&st.mtime));
                        h.update(std.mem.asBytes(&st.size));
                    } else |_| {}
                    f.close(io);
                } else |_| {}
            }
            var def_it = self.c_defines.keyIterator();
            while (def_it.next()) |d| h.update(d.*);
            var inc_it = self.c_includes.keyIterator();
            while (inc_it.next()) |i| h.update(i.*);
            var link_it = self.link_libraries.keyIterator();
            while (link_it.next()) |l| h.update(l.*);
        }
        const key = h.final();

        const ext = if (builtin.target.os.tag == .macos) ".dylib" else ".so";
        const lib_filename = try std.fmt.allocPrint(self.allocator, "/tmp/eiwa_llvm_libs_{x}{s}", .{ key, ext });
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
            try cc_argv.appendSlice(&[_][]const u8{ "-shared", "-fPIC", "-O0", "-fwrapv" });
            if (builtin.target.os.tag == .linux) {
                try cc_argv.appendSlice(&[_][]const u8{ "-Wl,--no-as-needed" });
            }
            if (builtin.target.os.tag == .macos) {
                const brew = if (builtin.target.cpu.arch == .aarch64) "/opt/homebrew" else "/usr/local";
                try cc_argv.appendSlice(&[_][]const u8{ "-I", brew ++ "/include", "-L", brew ++ "/lib" });
            }
            try cc_argv.appendSlice(&[_][]const u8{ "-o", lib_filename });
            for (self.cli_c_flags) |flag| try cc_argv.append(flag);

            const src_dir = eiwa_home.resolve(self.allocator);
            const repo_root = std.fs.path.dirname(src_dir) orelse ".";
            const inc_third_party = try std.fs.path.join(self.allocator, &.{ repo_root, "src/runtime/third_party" });
            try cc_argv.appendSlice(&[_][]const u8{ "-I", inc_third_party });

            var inc_it = self.c_includes.keyIterator();
            while (inc_it.next()) |dir| {
                try cc_argv.append(try std.fmt.allocPrint(self.allocator, "-I{s}", .{dir.*}));
            }
            var def_it = self.c_defines.keyIterator();
            while (def_it.next()) |def| {
                try cc_argv.append(try std.fmt.allocPrint(self.allocator, "-D{s}", .{def.*}));
            }
            var src_it = self.c_sources.keyIterator();
            while (src_it.next()) |src| {
                try cc_argv.append(src.*);
            }
            if (self.c_sources.count() == 0) {
                try cc_argv.appendSlice(&[_][]const u8{ "-x", "c", "/dev/null" });
            }

            try cc_argv.append("-lgc");
            var lib_it = self.link_libraries.keyIterator();
            while (lib_it.next()) |lib_name| {
                try cc_argv.append(try std.fmt.allocPrint(self.allocator, "-l{s}", .{lib_name.*}));
                const macro = try std.fmt.allocPrint(self.allocator, "-DEIWA_USE_{s}", .{lib_name.*});
                for (macro) |*c| c.* = std.ascii.toUpper(c.*);
                try cc_argv.append(macro);
            }

            var child = try std.process.spawn(io, .{ .argv = cc_argv.items });
            const term = try child.wait(io);
            if (term != .exited or term.exited != 0) {
                std.debug.print("Compiling lib C sources for JIT failed. Term: {any}, Command:", .{term});
                for (cc_argv.items) |arg| std.debug.print(" {s}", .{arg});
                std.debug.print("\n", .{});
                return error.LibSourceCompileFailed;
            }
        }

        // Load with RTLD_GLOBAL (or LoadLibrary on Windows) so the MCJIT symbol
        // resolver finds the externs. LLVM 21 dropped the LLVMLoadLibraryPermanently
        // C API, so use platform-native dynamic library loading.
        const lib_filename_z = try self.allocator.dupeZ(u8, lib_filename);
        defer self.allocator.free(lib_filename_z);

        if (builtin.os.tag == .windows) {
            const win_c = struct {
                extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
            };
            const handle = win_c.LoadLibraryA(lib_filename_z.ptr);
            if (handle == null) {
                std.debug.print("Could not load lib C sources into JIT: {s}\n", .{lib_filename});
                return error.LibSourceLoadFailed;
            }
        } else {
            const c_dl = struct {
                extern "c" fn dlopen(filename: ?[*:0]const u8, flags: c_int) ?*anyopaque;
            };
            const rtld_lazy: c_int = 1;
            const rtld_global: c_int = if (builtin.target.os.tag == .macos) 8 else 256;
            const handle = c_dl.dlopen(lib_filename_z.ptr, rtld_lazy | rtld_global);
            if (handle == null) {
                std.debug.print("Could not load lib C sources into JIT: {s}\n", .{lib_filename});
                return error.LibSourceLoadFailed;
            }
        }
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

    pub fn isLibFunction(self: *LLVMEmitter, name: []const u8) bool {
        var it = self.libs.valueIterator();
        while (it.next()) |func_map| {
            var f_it = func_map.valueIterator();
            while (f_it.next()) |c_name| {
                if (std.mem.eql(u8, c_name.*, name)) return true;
            }
        }
        return false;
    }

    /// Emits a function body, falling back to a complete stub when the body
    /// either fails to emit OR emits malformed IR (e.g. `when`/smart-cast or
    /// contract dispatch that leaves an unterminated block, an icmp on a
    /// struct, or a return-type mismatch without raising an error). The stub
    /// keeps the module verifiable for the JIT/linker.
    fn emitFunctionBodyOrStub(self: *LLVMEmitter, mod: llvm.LLVMModuleRef, func_node: *ast.ASTNode, fname: []const u8, is_object_method: bool) void {
        if (self.isLibFunction(fname)) return;
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
        if (self.isLibFunction(fname)) return;
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

    /// Registers every JIT'd module global as a Boehm GC root segment.
    /// JIT globals live in MCJIT-mmap'd memory, which the
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
        // Initialize the Boehm GC before any JIT'd code can call
        // GC_malloc. executeJIT is the sole GC_init caller for programs
        // without neco, so GC_malloc would SIGABRT without it. Idempotent.
        // has_gc is comptime: hosts without libgc compile this out entirely.
        if (has_gc) {
            gc.GC_init();
            gc.GC_allow_register_threads();
        }
        {
            var verify_err: [*c]u8 = null;
            if (llvm.LLVMVerifyModule(mod, llvm.LLVMReturnStatusAction, &verify_err) != 0) {
                if (verify_err != null) {
                    const err_slice = std.mem.sliceTo(verify_err, 0);
                    diagnostics.printICE("LLVM module verification failed during JIT compilation", err_slice);
                    llvm.LLVMDisposeMessage(verify_err);
                } else {
                    diagnostics.printICE("LLVM module verification failed during JIT compilation", null);
                }
                return error.LLVMVerificationFailed;
            }
        }
        if (verbose) llvm.LLVMDumpModule(mod);
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

        if (has_gc) {
            const gc_syms = [_]struct { name: [:0]const u8, ptr: *const anyopaque }{
                .{ .name = "GC_init", .ptr = @ptrCast(&gc.GC_init) },
                .{ .name = "GC_allow_register_threads", .ptr = @ptrCast(&gc.GC_allow_register_threads) },
                .{ .name = "GC_malloc", .ptr = @ptrCast(&gc.GC_malloc) },
                .{ .name = "GC_malloc_uncollectable", .ptr = @ptrCast(&gc.GC_malloc_uncollectable) },
                .{ .name = "GC_realloc", .ptr = @ptrCast(&gc.GC_realloc) },
                .{ .name = "GC_get_stack_base", .ptr = @ptrCast(&gc.GC_get_stack_base) },
                .{ .name = "GC_register_my_thread", .ptr = @ptrCast(&gc.GC_register_my_thread) },
                .{ .name = "GC_unregister_my_thread", .ptr = @ptrCast(&gc.GC_unregister_my_thread) },
            };
            for (gc_syms) |sym| {
                if (llvm.LLVMGetNamedFunction(mod, sym.name.ptr)) |f| {
                    llvm.LLVMAddGlobalMapping(engine, f, @constCast(sym.ptr));
                }
            }
        }

        // The entry is always the shim `main(i32 argc, ptr argv)` (emitted by
        // emitEntryShim), which stores argv and forwards to the program main.
        const main_func = llvm.LLVMGetNamedFunction(mod, "main") orelse return error.MainNotFound;
        const fn_addr = llvm.LLVMGetFunctionAddress(engine, "main");
        const main_fn_ptr: *anyopaque = if (fn_addr != 0)
            @ptrFromInt(fn_addr)
        else
            (llvm.LLVMGetPointerToGlobal(engine, main_func) orelse return error.MainJITCompilationFailed);
        const main_type = llvm.LLVMGlobalGetValueType(main_func);
        const ret_kind = llvm.LLVMGetTypeKind(llvm.LLVMGetReturnType(main_type));

        // With the engine materialized and compiled, register JIT globals as GC
        // roots before any GC_malloc from the program can trigger a collection.
        if (has_gc) registerJITGlobalsAsRoots(engine, mod);

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

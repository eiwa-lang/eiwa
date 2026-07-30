const std = @import("std");
const builtin = @import("builtin");
const ast = @import("../../core/ast.zig");
const compat = @import("../../core/compat.zig");
const ArrayList = compat.ArrayList;
const types_mapping = @import("types.zig");
const statement = @import("statement.zig");
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
        };
    }

    pub fn deinit(self: *LLVMEmitter) void {
        self.functions.deinit();
        self.structs.deinit();
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
        const prog = ast_root.data.program;

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

        // Pass 1a: Declare all user-defined types (structs & constructors)
        for (prog.statements) |stmt| {
            if (stmt.data == .type_decl) {
                try self.declareType(mod, stmt);
            }
        }

        // Pass 1b: Declare all function signatures
        for (prog.statements) |stmt| {
            if (stmt.data == .fun_decl) {
                try self.declareFunction(mod, stmt);
            }
        }

        // Pass 2: Emit function bodies
        var top_level_stmts = ArrayList(*ast.ASTNode).init(self.allocator);
        defer top_level_stmts.deinit();

        for (prog.statements) |stmt| {
            if (stmt.data == .fun_decl) {
                try self.emitFunctionBody(mod, stmt);
            } else if (stmt.data != .type_decl) {
                try top_level_stmts.append(stmt);
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

                for (top_level_stmts.items) |stmt| {
                    try statement.emitStatement(self.context, mod, self.builder, main_func.?, &scope, &self.structs, stmt);
                }

                const cur_bb = llvm.LLVMGetInsertBlock(self.builder);
                if (llvm.LLVMGetBasicBlockTerminator(cur_bb) == null) {
                    const zero = llvm.LLVMConstInt(i32_type, 0, 0);
                    _ = llvm.LLVMBuildRet(self.builder, zero);
                }
            }
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

        // Call malloc or GC_malloc
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
                try self.declareFunction(mod, m_node);
            }
        }
    }

    fn declareFunction(self: *LLVMEmitter, mod: llvm.LLVMModuleRef, func_node: *ast.ASTNode) !void {
        const f = func_node.data.fun_decl;
        const name = f.resolved_c_name orelse f.name;

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

        const func_val = llvm.LLVMAddFunction(mod, name_z.ptr, func_type);
        try self.functions.put(name, func_val);
    }

    fn emitFunctionBody(self: *LLVMEmitter, mod: llvm.LLVMModuleRef, func_node: *ast.ASTNode) !void {
        const f = func_node.data.fun_decl;
        const name = f.resolved_c_name orelse f.name;
        const func_val = self.functions.get(name) orelse return error.FunctionNotFound;

        const entry_block = llvm.LLVMAppendBasicBlockInContext(self.context, func_val, "entry");
        llvm.LLVMPositionBuilderAtEnd(self.builder, entry_block);

        var scope = std.StringHashMap(llvm.LLVMValueRef).init(self.allocator);
        defer scope.deinit();

        // Allocate and store parameters in local scope
        for (f.params, 0..) |p, i| {
            const param_val = llvm.LLVMGetParam(func_val, @intCast(i));
            const param_type = llvm.LLVMTypeOf(param_val);

            const p_name_z = try self.allocator.dupeZ(u8, p.name);
            defer self.allocator.free(p_name_z);

            const alloca_ptr = llvm.LLVMBuildAlloca(self.builder, param_type, p_name_z.ptr);
            _ = llvm.LLVMBuildStore(self.builder, param_val, alloca_ptr);
            try scope.put(p.name, alloca_ptr);
        }

        try statement.emitStatement(self.context, mod, self.builder, func_val, &scope, &self.structs, f.body);

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

    /// Executes the in-memory LLVM module via JIT (for `eiwa run --backend=llvm`).
    pub fn executeJIT(self: *LLVMEmitter) !i32 {
        const mod = self.module orelse return error.ModuleAlreadyDisposed;
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
        const main_fn: *const fn () callconv(.c) i32 = @ptrCast(@alignCast(main_fn_ptr));

        return main_fn();
    }
};

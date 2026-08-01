const std = @import("std");
const compat = @import("../../core/compat.zig");
const ArrayList = compat.ArrayList;
const core = @import("core.zig");
const type_system = @import("../../core/type_system.zig");

const ASTNode = core.ASTNode;
const CTranspiler = core.CTranspiler;

fn getBoxTypeName(allocator: std.mem.Allocator, c_type: []const u8) anyerror![]const u8 {
    var safe = ArrayList(u8).init(allocator);
    for (c_type) |c| {
        if (c == '*') {
            try safe.appendSlice("Ptr");
        } else if (c == ' ') {
            try safe.appendSlice("_");
        } else {
            try safe.append(c);
        }
    }
    return try std.fmt.allocPrint(allocator, "Box_{s}", .{safe.items});
}

fn emitCatchTypeCheck(self: *CTranspiler, target_t: *const type_system.EiwaType) anyerror!void {
    switch (target_t.*) {
        .Custom => |cname| {
            const actual = if (self.alias_map) |am| (am.get(cname) orelse cname) else cname;
            if (self.isContract(actual)) {
                try self.writer.writer().print("eiwa_implements(*(const EiwaTypeDescriptor**)(__exc), &{s}_contract)", .{actual});
            } else {
                try self.writer.writer().print("*(const EiwaTypeDescriptor**)(__exc) == &{s}_descriptor", .{actual});
            }
        },
        .Union => |u| {
            try self.writer.appendSlice("(");
            try emitCatchTypeCheck(self, u.left);
            try self.writer.appendSlice(" || ");
            try emitCatchTypeCheck(self, u.right);
            try self.writer.appendSlice(")");
        },
        else => {},
    }
}

pub fn emitStatement(self: *CTranspiler, node: *ASTNode) anyerror!void {
    switch (node.data) {
        .var_decl => |v| {
            if (node.resolved_type) |rt| {
                if (rt.* == .Void) {
                    if (v.initializer) |init_node| {
                        try self.writer.appendSlice("    ");
                        try self.emitExpression(init_node);
                        try self.writer.appendSlice(";\n");
                    }
                    return;
                }
            }
            var type_str: []const u8 = "int";
            if (node.resolved_type) |rt| {
                type_str = try self.cType(rt);
            }
            if (v.is_boxed) {
                const box_type = try getBoxTypeName(self.allocator, type_str);
                if (!self.classes.contains(box_type)) {
                    try self.classes.put(box_type, {});
                    try self.header_writer.writer().print("typedef struct {{\n    {s} value;\n}} {s};\n\n", .{type_str, box_type});
                }

                const var_name = try core.cIdent(self.allocator, v.name);
                try self.writer.writer().print("    {s}* {s} = GC_MALLOC(sizeof({s}))", .{box_type, var_name, box_type});
                if (v.initializer) |init_node| {
                    try self.writer.appendSlice(";\n");
                    try self.writer.writer().print("    {s}->value = ", .{var_name});
                    try self.emitExpression(init_node);
                }
                try self.writer.appendSlice(";\n");
            } else {
                try self.writer.writer().print("    {s} {s}", .{ type_str, try core.cIdent(self.allocator, v.name) });
                if (v.initializer) |init_node| {
                    try self.writer.appendSlice(" = ");
                    if (std.mem.eql(u8, type_str, "void*") and init_node.resolved_type != null and (init_node.resolved_type.?.* == .Int or init_node.resolved_type.?.* == .Bool)) {
                        try self.writer.writer().print("(void*)(intptr_t)(", .{});
                        try self.emitExpression(init_node);
                        try self.writer.appendSlice(")");
                    } else {
                        try self.emitExpression(init_node);
                    }
                }
                try self.writer.appendSlice(";\n");
            }
        },
        .if_expr => |i| {
            try self.writer.appendSlice("    if (");
            try self.emitExpression(i.condition);
            try self.writer.appendSlice(") ");
            if (i.then_branch.data == .block) {
                try self.emitStatement(i.then_branch);
            } else {
                try self.writer.appendSlice("{\n    ");
                try self.emitStatement(i.then_branch);
                try self.writer.appendSlice("    }\n");
            }
            if (i.else_branch) |eb| {
                try self.writer.appendSlice("    else ");
                if (eb.data == .block) {
                    try self.emitStatement(eb);
                } else {
                    try self.writer.appendSlice("{\n    ");
                    try self.emitStatement(eb);
                    try self.writer.appendSlice("    }\n");
                }
            }
        },
        .while_stmt => |w| {
            try self.writer.appendSlice("    while (");
            try self.emitExpression(w.condition);
            try self.writer.appendSlice(") {\n");
            
            switch (w.body.data) {
                .block => |b| {
                    for (b.statements) |stmt| {
                        try self.emitStatement(stmt);
                    }
                },
                else => {
                    try self.emitStatement(w.body);
                }
            }
            try self.writer.appendSlice("    }\n");
        },
        .for_stmt => |f| {
            if (f.iterable.resolved_type) |rt| {
                if (rt.* == .Array) {
                    const inner_c_type = try self.cType(rt.Array);
                    var safe_inner = ArrayList(u8).init(self.allocator);
                    for (inner_c_type) |c| {
                        if (c == '*') continue;
                        if (c == ' ') continue;
                        try safe_inner.append(c);
                    }
                    const struct_name = try std.fmt.allocPrint(self.allocator, "EiwaArray_{s}", .{safe_inner.items});
                    
                    try self.writer.appendSlice("    {\n");
                    try self.writer.writer().print("        {s}* _arr = ", .{struct_name});
                    try self.emitExpression(f.iterable);
                    try self.writer.appendSlice(";\n");
                    try self.writer.appendSlice("        for (size_t _i = 0; _i < _arr->length; _i++) {\n");
                    try self.writer.writer().print("            {s} {s} = _arr->data[_i];\n", .{inner_c_type, f.item_name});
                    
                    switch (f.body.data) {
                        .block => |b| {
                            for (b.statements) |stmt| {
                                try self.emitStatement(stmt);
                            }
                        },
                        else => {
                            try self.emitStatement(f.body);
                        }
                    }
                    try self.writer.appendSlice("        }\n");
                    try self.writer.appendSlice("    }\n");
                }
            }
        },
        .return_stmt => |r| {
            if (r.value) |v| {
                if (v.resolved_type != null and v.resolved_type.?.* == .Void) {
                    // Void-typed value (e.g. generic T instantiated as Void):
                    // emit the expression for side effects, then a bare return.
                    try self.writer.appendSlice("    ");
                    try self.emitExpression(v);
                    try self.writer.appendSlice(";\n    return;\n");
                    return;
                }
            }
            try self.writer.appendSlice("    return ");
            if (r.value) |v| {
                try self.emitExpression(v);
            }
            try self.writer.appendSlice(";\n");
        },
        .throw_stmt => |th| {
            try self.writer.appendSlice("    eiwa_throw(");
            try self.emitExpression(th.expr);
            try self.writer.appendSlice(");\n");
        },
        .try_stmt => |ts| {
            // PRE-EXISTING: exceptions use the setjmp/longjmp frame model
            // (EiwaExceptionFrame + eiwa_push/pop_exception_frame) — this
            // predates the LLVM emitter, which reimplemented the same model in
            // IR (see llvm_emitter/statement.zig try_stmt/throw_stmt). It
            // relies on the C runtime's frame helpers, so it is exact here.
            // Recommendation: the LLVM emitter should keep following this
            // layout (or ideally call these same runtime helpers), so the two
            // backends stay behaviorally identical. Note: this C path handles
            // typed multi-catch and else-rethrow (lines below); the LLVM
            // emitter only handles catches[0] — see its TODO.
            try self.writer.appendSlice("    {\n");
            try self.writer.appendSlice("        EiwaExceptionFrame __frame;\n");
            try self.writer.appendSlice("        eiwa_push_exception_frame(&__frame);\n");
            try self.writer.appendSlice("        if (setjmp(__frame.buf) == 0) {\n");
            
            if (ts.body.data == .block) {
                for (ts.body.data.block.statements) |stmt| {
                    try self.emitStatement(stmt);
                }
            } else {
                try self.emitStatement(ts.body);
            }
            
            try self.writer.appendSlice("            eiwa_pop_exception_frame();\n");
            try self.writer.appendSlice("        } else {\n");
            try self.writer.appendSlice("            eiwa_pop_exception_frame();\n");
            try self.writer.appendSlice("            void* __exc = eiwa_active_exception;\n");
            
            if (ts.catches.len > 0) {
                for (ts.catches, 0..) |c, catch_i| {
                    const prefix = if (catch_i == 0) "if" else "else if";
                    
                    if (c.var_name) |var_name| {
                        try self.writer.writer().print("            {s} (__exc != 0 && (", .{prefix});
                        for (c.types, 0..) |tr, tr_i| {
                            if (tr_i > 0) try self.writer.appendSlice(" || ");
                            if (tr.resolved_type) |rt| {
                                try emitCatchTypeCheck(self, rt);
                            } else if (tr.name.len > 0) {
                                const actual_type_name = if (self.alias_map) |am| (am.get(tr.name) orelse tr.name) else tr.name;
                                if (self.isContract(actual_type_name)) {
                                    try self.writer.writer().print("eiwa_implements(*(const EiwaTypeDescriptor**)(__exc), &{s}_contract)", .{actual_type_name});
                                } else {
                                    try self.writer.writer().print("*(const EiwaTypeDescriptor**)(__exc) == &{s}_descriptor", .{actual_type_name});
                                }
                            }
                        }
                        try self.writer.appendSlice(")) {\n");
                        try self.writer.writer().print("                eiwa_active_exception = 0;\n", .{});
                        var var_c_type: []const u8 = "void*";
                        if (c.types.len == 1) {
                            if (c.types[0].resolved_type) |rt| {
                                var_c_type = try self.cType(rt);
                            }
                        }
                        try self.writer.writer().print("                {s} {s} = ({s})__exc;\n", .{ var_c_type, var_name, var_c_type });
                        
                        if (c.body.data == .block) {
                            for (c.body.data.block.statements) |stmt| {
                                try self.emitStatement(stmt);
                            }
                        } else {
                            try self.emitStatement(c.body);
                        }
                        
                        try self.writer.appendSlice("            }\n");
                    } else {
                        if (catch_i == 0) {
                            try self.writer.appendSlice("            {\n");
                        } else {
                            try self.writer.appendSlice("            else {\n");
                        }
                        try self.writer.writer().print("                eiwa_active_exception = 0;\n", .{});
                        
                        if (c.body.data == .block) {
                            for (c.body.data.block.statements) |stmt| {
                                try self.emitStatement(stmt);
                            }
                        } else {
                            try self.emitStatement(c.body);
                        }
                        
                        try self.writer.appendSlice("            }\n");
                    }
                }
                
                const last_catch_is_typed = ts.catches[ts.catches.len - 1].var_name != null;
                if (last_catch_is_typed) {
                    try self.writer.appendSlice("            else {\n");
                    try self.writer.appendSlice("                eiwa_throw(__exc);\n");
                    try self.writer.appendSlice("            }\n");
                }
            } else {
                try self.writer.appendSlice("            eiwa_active_exception = 0;\n");
            }
            
            try self.writer.appendSlice("        }\n");
            try self.writer.appendSlice("    }\n");
        },
        .block => |b| {
            try self.writer.appendSlice("    {\n");
            for (b.statements) |stmt| {
                try self.emitStatement(stmt);
            }
            try self.writer.appendSlice("    }\n");
        },
        else => {
            try self.writer.appendSlice("    ");
            try self.emitExpression(node);
            try self.writer.appendSlice(";\n");
        },
    }
}

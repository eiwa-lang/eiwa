const std = @import("std");
const ast = @import("../ast.zig");
const core = @import("core.zig");
const infer_stmt_mod = @import("infer_stmt.zig");

const ASTNode = core.ASTNode;
const TypeChecker = core.TypeChecker;
const Scope = core.Scope;
const EiwaType = core.EiwaType;

pub fn inferWhenExpr(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    const w = &node.data.when_expr;

    var subject_type: ?*const EiwaType = null;
    if (w.subject) |subj| {
        subject_type = try self.inferNode(subj, scope);
    }

    var resolved_type: ?*const EiwaType = null;
    var has_else = false;

    for (w.cases, 0..) |case, i| {
        if (case.is_else) {
            has_else = true;
            if (i != w.cases.len - 1) {
                self.reportError(node.line, node.column, "TypeError: else branch must be the last branch in when expression.", .{});
                return error.TypeError;
            }
        }

        // 1. Validate case conditions
        for (case.conds) |cond| {
            if (subject_type) |subj_t| {
                if (cond.data == .is_type_cond) {
                    const type_cond = cond.data.is_type_cond;
                    const target_t = try self.resolveTypeRef(type_cond.type_ref);
                    const r_t = try self.allocator.create(EiwaType);
                    r_t.* = .Bool;
                    cond.resolved_type = r_t;

                    // Verify compatibility (upcast/downcast)
                    const base_subj = core.extractBaseType(subj_t);
                    const base_target = core.extractBaseType(target_t);

                    if (base_subj.* == .Custom and base_target.* == .Custom) {
                        const is_upcast = self.conformsTo(base_subj.Custom, base_target.Custom);
                        const is_downcast = self.conformsTo(base_target.Custom, base_subj.Custom);
                        if (!is_upcast and !is_downcast) {
                            self.reportError(cond.line, cond.column, "TypeError: Incompatible types for when type check: {s} does not conform to {s}.", .{ base_subj.Custom, base_target.Custom });
                            return error.TypeError;
                        }
                    } else {
                        if (!self.isCompatible(target_t, subj_t) and !self.isCompatible(subj_t, target_t)) {
                            self.reportError(cond.line, cond.column, "TypeError: Cannot check if {} is {}.", .{ subj_t.*, target_t.* });
                            return error.TypeError;
                        }
                    }
                } else {
                    // Value check
                    const val_t = try self.inferNode(cond, scope);
                    if (!self.isCompatible(subj_t, val_t) and !self.isCompatible(val_t, subj_t)) {
                        self.reportError(cond.line, cond.column, "TypeError: Incompatible types in when condition: expected {} but found {}.", .{ subj_t.*, val_t.* });
                        return error.TypeError;
                    }
                }
            } else {
                // No subject: conditions must be Bool
                const cond_t = try self.inferNode(cond, scope);
                if (!core.isBool(cond_t)) {
                    self.reportError(cond.line, cond.column, "TypeError: when condition without subject must be Bool. Found {}.", .{cond_t.*});
                    return error.TypeError;
                }
            }
        }

        // 2. Set up case body scope (supporting smart casting)
        var case_scope = Scope.init(self.allocator, scope);
        defer case_scope.deinit();

        if (subject_type != null and w.subject.?.data == .identifier and case.conds.len == 1) {
            const cond = case.conds[0];
            if (cond.data == .is_type_cond and !cond.data.is_type_cond.is_not) {
                const var_name = w.subject.?.data.identifier.name;
                const target_t = try self.resolveTypeRef(cond.data.is_type_cond.type_ref);
                
                try case_scope.define(var_name, target_t, false, false);
            }
        }

        if (node.expected_type) |et| {
            case.body.expected_type = et;
        }

        if (w.is_value) infer_stmt_mod.markTrailingValue(case.body, true);

        // 3. Infer case body type (null = diverging body: `return`/`throw`
        //    as the last statement, Kotlin `Nothing` — no fall-through value)
        const body_type = if (case.body.data == .block)
            try self.inferBlockAsExpression(case.body, &case_scope)
        else
            try self.inferNode(case.body, &case_scope);

        // 4. Accumulate/verify return type (diverging bodies are skipped)
        if (body_type) |bt| {
            if (node.expected_type) |exp_t| {
                if (!self.isCompatible(exp_t, bt)) {
                    self.reportError(case.body.line, case.body.column, "TypeError: when branch has type {} which is incompatible with expected type {}.", .{ bt.*, exp_t.* });
                    return error.TypeError;
                }
                resolved_type = exp_t;
            } else if (resolved_type) |curr_res| {
                if (curr_res.* == .Void or bt.* == .Void) {
                    const void_t = try self.allocator.create(EiwaType);
                    void_t.* = .Void;
                    resolved_type = void_t;
                } else if (self.isCompatible(curr_res, bt)) {
                    resolved_type = curr_res;
                } else if (self.isCompatible(bt, curr_res)) {
                    resolved_type = bt;
                } else {
                    self.reportError(case.body.line, case.body.column, "TypeError: when branches have incompatible types: {} and {}.", .{ curr_res.*, bt.* });
                    return error.TypeError;
                }
            } else {
                resolved_type = bt;
            }
        }
    }

    // Default to Void if empty
    const void_type = EiwaType{ .Void = {} };
    const final_t = resolved_type orelse &void_type;

    // 5. Exclusivity/Exhaustiveness check for expressions (non-Void return type)
    if (final_t.* != .Void and !has_else) {
        self.reportError(node.line, node.column, "TypeError: when expression returning non-Void type ({}) must be exhaustive. Missing 'else' branch.", .{final_t.*});
        return error.TypeError;
    }

    t.* = final_t.*;
    node.resolved_type = t;
}

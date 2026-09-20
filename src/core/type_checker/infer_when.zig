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

    // Nullable subject narrows to `T` where null is unobservable; `else` only when null is covered.
    var nullable_subject_name: ?[]const u8 = null;
    var nullable_stripped: ?*const EiwaType = null;
    if (subject_type != null and w.subject.?.data == .identifier) {
        const nm = w.subject.?.data.identifier.name;
        if (try self.narrowedBinding(scope, nm)) |stripped| {
            nullable_subject_name = nm;
            nullable_stripped = stripped;
        }
    }
    var saw_null_branch = false;

    for (w.cases, 0..) |case, i| {
        if (case.is_else) {
            has_else = true;
            if (i != w.cases.len - 1) {
                self.reportError(node.line, node.column, "TypeError: else branch must be the last branch in when expression.", .{});
                return error.TypeError;
            }
        }

        // 1. Validate case conditions
        var case_matches_null = false;
        var case_has_negated = false;
        for (case.conds) |cond| {
            if (cond.data == .null_literal) {
                case_matches_null = true;
            } else if (cond.data == .is_type_cond and cond.data.is_type_cond.is_not) {
                case_has_negated = true;
            }
            if (subject_type) |subj_t| {
                if (cond.data == .is_type_cond) {
                    const type_cond = cond.data.is_type_cond;
                    const target_t = try self.resolveTypeRef(type_cond.type_ref);
                    if (target_t.* == .Null) case_matches_null = true;
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
                            self.reportError(cond.line, cond.column, "TypeError: Cannot check if {f} is {f}.", .{ subj_t.*, target_t.* });
                            return error.TypeError;
                        }
                    }
                } else {
                    if (cond.expected_type == null and self.typeHasEnum(subj_t)) cond.expected_type = subj_t;
                    const val_t = try self.inferNode(cond, scope);
                    if (!self.isCompatible(subj_t, val_t) and !self.isCompatible(val_t, subj_t)) {
                        self.reportError(cond.line, cond.column, "TypeError: Incompatible types in when condition: expected {f} but found {f}.", .{ subj_t.*, val_t.* });
                        return error.TypeError;
                    }
                }
            } else {
                // No subject: conditions must be Bool
                const cond_t = try self.inferNode(cond, scope);
                if (!core.isBool(cond_t)) {
                    self.reportError(cond.line, cond.column, "TypeError: when condition without subject must be Bool. Found {f}.", .{cond_t.*});
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

        // Single positive `is` uses the target narrowing above.
        if (nullable_subject_name) |nm| {
            if (nullable_stripped) |nt| {
                if (case.is_else) {
                    if (saw_null_branch) try self.defineNarrowed(&case_scope, nm, nt);
                } else if (!case_matches_null and !case_has_negated) {
                    const single_pos_is = case.conds.len == 1 and case.conds[0].data == .is_type_cond and !case.conds[0].data.is_type_cond.is_not;
                    if (!single_pos_is) try self.defineNarrowed(&case_scope, nm, nt);
                }
            }
        }
        if (case_matches_null) saw_null_branch = true;

        if (node.expected_type) |et| {
            case.body.expected_type = et;
        }

        if (w.is_value or (node.expected_type != null and node.expected_type.?.* != .Void)) infer_stmt_mod.markTrailingValue(case.body, true);

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
                    self.reportError(case.body.line, case.body.column, "TypeError: when branch has type {f} which is incompatible with expected type {f}.", .{ bt.*, exp_t.* });
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
                } else if (curr_res.* == .Null or bt.* == .Null) {
                    const non_null = if (curr_res.* == .Null) bt else curr_res;
                    if (non_null.* == .Null) {
                        resolved_type = curr_res;
                    } else if (core.isNullable(non_null)) {
                        resolved_type = non_null;
                    } else {
                        const left_t = try self.allocator.create(EiwaType);
                        left_t.* = non_null.*;
                        const right_t = try self.allocator.create(EiwaType);
                        right_t.* = .Null;
                        const union_t = try self.allocator.create(EiwaType);
                        union_t.* = .{ .Union = .{ .left = left_t, .right = right_t } };
                        resolved_type = union_t;
                    }
                } else {
                    self.reportError(case.body.line, case.body.column, "TypeError: when branches have incompatible types: {f} and {f}.", .{ curr_res.*, bt.* });
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
        self.reportError(node.line, node.column, "TypeError: when expression returning non-Void type ({f}) must be exhaustive. Missing 'else' branch.", .{final_t.*});
        return error.TypeError;
    }

    t.* = final_t.*;
    node.resolved_type = t;
}

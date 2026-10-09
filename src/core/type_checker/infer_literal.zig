const std = @import("std");
const compat = @import("../compat.zig");
const ArrayList = compat.ArrayList;
const ast = @import("../ast.zig");
const core = @import("core.zig");
const type_system = @import("../type_system.zig");

const ASTNode = core.ASTNode;
const TypeChecker = core.TypeChecker;
const Scope = core.Scope;
const EiwaType = core.EiwaType;

pub fn inferArrayLiteral(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    const a = node.data.array_literal;
    if (a.elements.len == 0) {
        if (node.expected_type) |expected| {
            var expected_base = type_system.extractBaseType(expected);
            if (expected_base.* == .Union) {
                if (expected_base.Union.right.* == .Null) {
                    expected_base = expected_base.Union.left;
                } else if (expected_base.Union.left.* == .Null) {
                    expected_base = expected_base.Union.right;
                }
            }
            if (expected_base.* == .Array or expected_base.* == .Custom or expected_base.* == .GenericInstance) {
                t.* = expected_base.*;
                return;
            }
        }
        self.reportError(node.line, node.column, "TypeError: Cannot infer type of empty array literal.", .{});
        return error.TypeError;
    }
    
    var first_type: *const EiwaType = undefined;
    var expected_elem_t: ?*const EiwaType = null;

    if (node.expected_type) |exp| {
        const exp_base = type_system.extractBaseType(exp);
        if (exp_base.* == .Custom) {
            const name = exp_base.Custom;
            if (std.mem.startsWith(u8, name, "NativeArray<") and std.mem.endsWith(u8, name, ">")) {
                const inner = name[12 .. name.len - 1];
                expected_elem_t = self.resolveHintTypeName(inner, false) orelse (
                    if (std.mem.startsWith(u8, inner, "std_core_")) self.resolveHintTypeName(inner[9..], false)
                    else if (std.mem.startsWith(u8, inner, "core_")) self.resolveHintTypeName(inner[5..], false)
                    else null
                );
            } else if (std.mem.indexOf(u8, name, "List_")) |idx| {
                const inner = name[idx + 5 ..];
                expected_elem_t = self.resolveHintTypeName(inner, false) orelse (
                    if (std.mem.startsWith(u8, inner, "std_core_")) self.resolveHintTypeName(inner[9..], false)
                    else if (std.mem.startsWith(u8, inner, "core_")) self.resolveHintTypeName(inner[5..], false)
                    else null
                );
            } else {
                const actual_c = self.alias_map.get(name) orelse name;
                if (self.classes_ast.get(actual_c)) |cn| {
                    if (cn.data.type_decl.primary_constructor.len > 0) {
                        const prop0 = cn.data.type_decl.primary_constructor[0];
                        if (prop0.resolved_type) |pt| {
                            if (pt.* == .Array) {
                                expected_elem_t = pt.Array;
                            }
                        }
                    }
                }
            }
        } else if (exp_base.* == .GenericInstance) {
            if (exp_base.GenericInstance.type_args.len > 0) {
                expected_elem_t = exp_base.GenericInstance.type_args[0];
            }
        } else if (exp_base.* == .Array) {
            expected_elem_t = exp_base.Array;
        }
    }

    if (expected_elem_t) |ee_t| {
        first_type = ee_t;
        for (a.elements) |elem| {
            const elem_type = try self.inferNode(elem, scope);
            if (!self.isCompatible(first_type, elem_type)) {
                self.reportError(node.line, node.column, "TypeError: Incompatible types in array literal. Expected {f} but found {f}.", .{ first_type.*, elem_type.* });
                return error.TypeError;
            }
            // Phase 80: raw scalars bound to a nullable element type must be
            // heap-boxed by the emitter.
            if (type_system.isNullableScalar(ee_t) and type_system.isRawScalar(elem_type)) {
                elem.box_nullable_scalar = true;
            }
            // Int elements bound to a Double slot must be converted by the
            // emitter (storing raw i64 bits reads back as garbage double).
            elem.expected_type = ee_t;
        }
    } else {
        first_type = try self.inferNode(a.elements[0], scope);
        for (a.elements[1..]) |elem| {
            const elem_type = try self.inferNode(elem, scope);
            if (!self.isCompatible(first_type, elem_type)) {
                self.reportError(node.line, node.column, "TypeError: Incompatible types in array literal. Expected {f} but found {f}.", .{ first_type.*, elem_type.* });
                return error.TypeError;
            }
        }
    }
    const array_type = try self.allocator.create(EiwaType);
    array_type.* = .{ .Array = first_type };
    
    // Simulate List<T> instantiation
    const list_c_name = self.alias_map.get("List") orelse "List";
    const class_node = self.classes_ast.get(list_c_name);
    if (class_node == null) {
        self.reportError(node.line, node.column, "TypeError: Class 'List' not found for array literal.", .{});
        return error.TypeError;
    }
    const type_decl = class_node.?.data.type_decl;
    var type_args = try self.allocator.alloc(*const EiwaType, 1);
    type_args[0] = first_type;
    
    // O mangled name deve ser baseado no nome importado (list_c_name), nao string "List"
    var mangled = ArrayList(u8).init(self.allocator);
    try mangled.appendSlice(list_c_name);
    try mangled.appendSlice("_");
    try first_type.formatSafe(mangled.writer());
    const mangled_name = try mangled.toOwnedSlice();
    try self.monomorphizeClass(type_decl.name, type_args, mangled_name);
    
    t.* = .{ .Custom = self.alias_map.get(mangled_name) orelse mangled_name };
}

/// Union value type behind an expected map name: matches the inferred key
/// exactly, then requires every literal value to fit a member of the
/// expected-V union entry (declared or anonymous). Returns the rebuilt
/// union type for node layout, or null to keep the legacy tail check.
fn mapLiteralUnionFit(self: *TypeChecker, exp_mangled: []const u8, elements: []const *ASTNode) ?*const EiwaType {
    const exp_tail = if (std.mem.indexOf(u8, exp_mangled, "Map_")) |idx| exp_mangled[idx + 4 ..] else return null;
    const k_t = elements[0].data.call_expr.arguments[0].resolved_type orelse return null;
    var k_buf = ArrayList(u8).init(self.allocator);
    defer k_buf.deinit();
    k_t.formatSafe(k_buf.writer()) catch return null;
    if (!std.mem.startsWith(u8, exp_tail, k_buf.items)) return null;
    const rest = exp_tail[k_buf.items.len..];
    if (rest.len == 0 or rest[0] != '_') return null;
    const unode = self.unions_ast.get(rest[1..]) orelse return null;
    if (unode.data.union_decl.members.len < 2) return null;
    for (elements) |elem| {
        if (elem.data != .call_expr) return null;
        const args = elem.data.call_expr.arguments;
        if (args.len < 2) return null;
        const v_t = args[1].resolved_type orelse return null;
        var fits = false;
        for (unode.data.union_decl.members) |mm| {
            if (mm.is_string) {
                if (v_t.* == .String) fits = true;
            } else if (v_t.* == .Custom) {
                if (std.mem.eql(u8, v_t.Custom, mm.name) or std.mem.eql(u8, EiwaType.shortName(v_t.Custom), EiwaType.shortName(mm.name))) fits = true;
            }
            if (fits) break;
        }
        if (!fits) return null;
    }
    var acc: ?*EiwaType = null;
    for (unode.data.union_decl.members) |mm| {
        const leaf = self.allocator.create(EiwaType) catch return null;
        if (mm.is_string) {
            leaf.* = .String;
        } else {
            leaf.* = .{ .Custom = self.alias_map.get(mm.name) orelse mm.name };
        }
        if (acc) |a| {
            const u = self.allocator.create(EiwaType) catch return null;
            u.* = .{ .Union = .{ .left = a, .right = leaf } };
            acc = u;
        } else acc = leaf;
    }
    return acc;
}

pub fn inferMapLiteral(self: *TypeChecker, node: *ASTNode, scope: *Scope, t: *EiwaType) anyerror!void {
    const m = node.data.map_literal;
    if (m.elements.len == 0) {
        self.reportError(node.line, node.column, "TypeError: Cannot infer type of empty map literal.", .{});
        return error.TypeError;
    }
    
    // Evaluate the first pair
    var first_key_type: *const EiwaType = undefined;
    var first_value_type: *const EiwaType = undefined;
    
    for (m.elements, 0..) |elem, i| {
        // Element is a `.kw_of` binary expression. Let's infer it, which transforms it into a Node constructor.
        _ = try self.inferNode(elem, scope);
        
        // At this point elem is a call_expr to Node<K, V>
        if (elem.data != .call_expr) {
            self.reportError(elem.line, elem.column, "TypeError: Map literal elements must be 'of' pairs.", .{});
            return error.TypeError;
        }
        
        const k_type = elem.data.call_expr.arguments[0].resolved_type.?;
        const v_type = elem.data.call_expr.arguments[1].resolved_type.?;
        
        if (i == 0) {
            first_key_type = k_type;
            first_value_type = v_type;
        } else {
            if (!self.isCompatible(first_key_type, k_type) or !self.isCompatible(first_value_type, v_type)) {
                self.reportError(elem.line, elem.column, "TypeError: Incompatible types in map literal.", .{});
                return error.TypeError;
            }
        }
    }
    
    // Union-typed values (`["k" of A(...)]` for `Map<String, A | B>` or a
    // declared union): fit every element against the expected-V union entry
    // and rebuild U from its members. Anything else keeps the legacy
    // inferred-V behavior below.
    var fit_val_t: *const EiwaType = first_value_type;
    var union_path = false;
    if (node.expected_type) |exp| {
        const exp_base = type_system.extractBaseType(exp);
        if (exp_base.* == .Custom) {
            if (mapLiteralUnionFit(self, exp_base.Custom, m.elements)) |U| {
                fit_val_t = U;
                union_path = true;
                for (m.elements) |elem| {
                    elem.data.call_expr.arguments[1].expected_type = U;
                }
            }
        }
    }

    // Simulate Map instantiation
    const node_base = self.alias_map.get("Node") orelse "Node";
    const mmap_base = self.alias_map.get("MutableMap") orelse "MutableMap";
    const map_base = self.alias_map.get("Map") orelse "Map";

    var map_mangled_str = ArrayList(u8).init(self.allocator);
    try map_mangled_str.appendSlice(map_base);
    try map_mangled_str.appendSlice("_");
    try first_key_type.formatSafe(map_mangled_str.writer());
    try map_mangled_str.appendSlice("_");
    try fit_val_t.formatSafe(map_mangled_str.writer());
    const mangled_name = try map_mangled_str.toOwnedSlice();
    
    var node_mangled_str = ArrayList(u8).init(self.allocator);
    try node_mangled_str.appendSlice(node_base);
    try node_mangled_str.appendSlice("_");
    try first_key_type.formatSafe(node_mangled_str.writer());
    try node_mangled_str.appendSlice("_");
    try fit_val_t.formatSafe(node_mangled_str.writer());
    const node_mangled = try node_mangled_str.toOwnedSlice();
    
    var mmap_mangled_str = ArrayList(u8).init(self.allocator);
    try mmap_mangled_str.appendSlice(mmap_base);
    try mmap_mangled_str.appendSlice("_");
    try first_key_type.formatSafe(mmap_mangled_str.writer());
    try mmap_mangled_str.appendSlice("_");
    try fit_val_t.formatSafe(mmap_mangled_str.writer());
    const mmap_mangled = try mmap_mangled_str.toOwnedSlice();
    
    var type_args = try self.allocator.alloc(*const EiwaType, 2);
    type_args[0] = first_key_type;
    type_args[1] = fit_val_t;
    
    if (self.classes_ast.get(node_base) == null or self.classes_ast.get(mmap_base) == null or self.classes_ast.get(map_base) == null) {
        self.reportError(node.line, node.column, "TypeError: Required Map classes not found.", .{});
        return error.TypeError;
    }
    
    try self.monomorphizeClass(node_base, type_args, node_mangled);
    try self.monomorphizeClass(mmap_base, type_args, mmap_mangled);
    try self.monomorphizeClass(map_base, type_args, mangled_name);

    if (node.expected_type) |exp| {
        const exp_base = type_system.extractBaseType(exp);
        if (exp_base.* == .Custom and !union_path) {
            const exp_tail = if (std.mem.indexOf(u8, exp_base.Custom, "Map_")) |idx| exp_base.Custom[idx + 4 ..] else exp_base.Custom;
            const inf_tail = if (std.mem.indexOf(u8, mangled_name, "Map_")) |idx| mangled_name[idx + 4 ..] else mangled_name;
            if (!std.mem.eql(u8, exp_tail, inf_tail)) {
                self.reportError(node.line, node.column, "TypeError: Incompatible types in map literal.", .{});
                return error.TypeError;
            }
        }
    }

    t.* = .{ .Custom = self.alias_map.get(mangled_name) orelse mangled_name };
}

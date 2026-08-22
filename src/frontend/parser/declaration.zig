const std = @import("std");
const compat = @import("../../core/compat.zig");
const ArrayList = compat.ArrayList;
const ast = @import("../../core/ast.zig");
const ASTNode = ast.ASTNode;
const TokenType = ast.TokenType;
const Param = ast.Param;
const Parser = @import("core.zig").Parser;

pub fn declaration(self: *Parser) anyerror!*ASTNode {
    const annotations = try self.parseAnnotations();
    const modifiers = try self.parseModifiers();

    if (self.match(.kw_lib)) return try self.libDeclaration(annotations);

    if (self.match(.kw_val)) {
        if (modifiers.len > 0) { self.errorAtCurrent("Modifiers not allowed on val"); return error.ParseError; }
        return try self.varDeclaration(false);
    }
    if (self.match(.kw_var)) {
        if (modifiers.len > 0) { self.errorAtCurrent("Modifiers not allowed on var"); return error.ParseError; }
        return try self.varDeclaration(true);
    }
    if (self.match(.kw_fun)) {
        return try self.funDeclaration(annotations, modifiers, false);
    }
    if (self.match(.kw_type)) {
        if (modifiers.len > 0) { self.errorAtCurrent("Modifiers not allowed on type"); return error.ParseError; }
        return try self.typeDeclaration(annotations);
    }
    if (self.match(.kw_contract)) {
        if (modifiers.len > 0) { self.errorAtCurrent("Modifiers not allowed on contract"); return error.ParseError; }
        return try self.contractDeclaration(annotations);
    }
    if (self.match(.kw_skill)) {
        if (modifiers.len > 0) { self.errorAtCurrent("Modifiers not allowed on skill"); return error.ParseError; }
        return try self.skillDeclaration(annotations);
    }
    if (self.match(.kw_object)) {
        if (modifiers.len > 0) { self.errorAtCurrent("Modifiers not allowed on object"); return error.ParseError; }
        return try self.objectDeclaration(annotations);
    }
    if (self.match(.kw_enum)) {
        if (modifiers.len > 0) { self.errorAtCurrent("Modifiers not allowed on enum"); return error.ParseError; }
        return try self.enumDeclaration(annotations);
    }
    
    if (modifiers.len > 0) {
        self.errorAtCurrent("Modifiers must precede a function declaration");
        return error.ParseError;
    }

    if (self.match(.kw_import)) return try self.importDeclaration();
    if (self.match(.kw_test)) return try self.testDeclaration();
    if (self.match(.kw_while)) return try self.whileStatement();
    if (self.match(.kw_for)) return try self.forStatement();
    if (self.match(.kw_return)) return try self.returnStatement();
    if (self.match(.kw_try)) return try self.tryStatement();
    if (self.match(.kw_throw)) return try self.throwStatement();
    return try self.expression();
}

pub fn parseModifiers(self: *Parser) anyerror![]TokenType {
    var modifiers = ArrayList(TokenType).init(self.allocator);
    while (self.match(.kw_implement) or self.match(.kw_operator)) {
        try modifiers.append(self.previous.token_type);
    }
    return try modifiers.toOwnedSlice();
}

pub fn parseAnnotations(self: *Parser) anyerror![]ast.Annotation {
    var annotations = ArrayList(ast.Annotation).init(self.allocator);
    while (self.match(.at)) {
        try self.consume(.identifier, "Expected annotation name after '@'.");
        const name = self.previous.lexeme;
        
        var arguments = ArrayList([]const u8).init(self.allocator);
        if (self.match(.l_paren)) {
            if (!self.check(.r_paren)) {
                while (true) {
                    try self.consume(.string_literal, "Expected string literal as annotation argument.");
                    const str_with_quotes = self.previous.lexeme;
                    const str = str_with_quotes[1 .. str_with_quotes.len - 1];
                    try arguments.append(str);
                    if (!self.match(.comma)) break;
                }
            }
            try self.consume(.r_paren, "Expected ')' after annotation arguments.");
        }
        try annotations.append(.{
            .name = name,
            .arguments = try arguments.toOwnedSlice(),
        });
    }
    return try annotations.toOwnedSlice();
}

pub fn libDeclaration(self: *Parser, annotations: []ast.Annotation) anyerror!*ASTNode {
    const line = self.previous.line;
    const col = self.previous.column;
    
    try self.consume(.identifier, "Expected lib name.");
    const name = self.previous.lexeme;
    
    try self.consume(.l_brace, "Expected '{' before lib body.");
    var functions = ArrayList(*ASTNode).init(self.allocator);
    while (!self.check(.r_brace) and !self.check(.eof)) {
        const fun_annotations = try self.parseAnnotations();
        if (self.match(.kw_fun)) {
            const func = try self.funDeclaration(fun_annotations, &[_]TokenType{}, true);
            try functions.append(func);
        } else {
            self.errorAtCurrent("Only functions are allowed inside 'lib' blocks.");
            return error.ParseError;
        }
    }
    try self.consume(.r_brace, "Expected '}' after lib body.");
    
    return try self.createNodeAt(.{ .lib_decl = .{
        .annotations = annotations,
        .name = name,
        .functions = try functions.toOwnedSlice(),
    } }, line, col);
}

pub fn varDeclaration(self: *Parser, is_mut: bool) anyerror!*ASTNode {
    const line = self.previous.line;
    const col = self.previous.column;
    
    try self.consume(.identifier, "Expected variable name.");
    const name = self.previous.lexeme;

    const parsed_type = try self.parseTypeAnnotation();

    var initializer: ?*ASTNode = null;
    if (self.match(.eq)) {
        initializer = try self.expression();
    }

    return try self.createNodeAt(.{ .var_decl = .{
        .is_mut = is_mut,
        .name = name,
        .type_ref = parsed_type,
        .initializer = initializer,
    } }, line, col);
}

pub fn testDeclaration(self: *Parser) anyerror!*ASTNode {
    const line = self.previous.line;
    const col = self.previous.column;

    try self.consume(.string_literal, "Expected test description string.");
    
    var name = self.previous.lexeme;
    if (name.len >= 2 and name[0] == '"' and name[name.len - 1] == '"') {
        name = name[1 .. name.len - 1];
    }

    try self.consume(.l_brace, "Expected '{' before test body.");
    var stmts = ArrayList(*ASTNode).init(self.allocator);
    while (!self.check(.r_brace) and !self.check(.eof)) {
        try stmts.append(try self.declaration());
    }
    try self.consume(.r_brace, "Expected '}' after block.");
    const body = try self.createNode(.{ .block = .{ .statements = try stmts.toOwnedSlice() } });

    return try self.createNodeAt(.{ .test_decl = .{
        .name = name,
        .body = body,
    } }, line, col);
}

pub fn importDeclaration(self: *Parser) anyerror!*ASTNode {
    const line = self.previous.line;
    const col = self.previous.column;
    
    try self.consume(.l_brace, "Expected '{' after import.");
    
    var destructured = ArrayList([]const u8).init(self.allocator);
    
    if (!self.check(.r_brace)) {
        while (true) {
            try self.consume(.identifier, "Expected identifier in import list.");
            try destructured.append(self.previous.lexeme);
            if (!self.match(.comma)) break;
        }
    }
    
    try self.consume(.r_brace, "Expected '}' after import list.");
    try self.consume(.kw_from, "Expected 'from' after import list.");
    try self.consume(.string_literal, "Expected module path string.");
    
    const path_with_quotes = self.previous.lexeme;
    const path = path_with_quotes[1 .. path_with_quotes.len - 1];
    
    return try self.createNodeAt(.{ .import_stmt = .{
        .module_path = path,
        .destructured = try destructured.toOwnedSlice(),
        .module_ast = null,
    } }, line, col);
}

pub fn funDeclaration(self: *Parser, annotations: []const ast.Annotation, modifiers: []const TokenType, allow_no_body: bool) anyerror!*ASTNode {
    const line = self.previous.line;
    const col = self.previous.column;
    
    try self.consume(.identifier, "Expected function name.");
    const name = self.previous.lexeme;

    var generic_params = ArrayList([]const u8).init(self.allocator);
    if (self.match(.less)) {
        if (!self.check(.greater)) {
            while (true) {
                try self.consume(.identifier, "Expected generic parameter name.");
                try generic_params.append(self.previous.lexeme);
                if (!self.match(.comma)) break;
            }
        }
        try self.consume(.greater, "Expected '>' after generic parameters.");
    }

    try self.consume(.l_paren, "Expected '(' after function name.");
    var params = ArrayList(Param).init(self.allocator);
    
    if (!self.check(.r_paren)) {
        while (true) {
            try self.consume(.identifier, "Expected parameter name.");
            const param_name = self.previous.lexeme;
            const parsed_type = try self.parseTypeAnnotation();

            // Varargs (`name: T...`) — the last parameter accepts N trailing
            // arguments, exposed as `List<T>` inside the body.
            const is_varargs = self.match(.ellipsis);
            if (is_varargs) {
                if (self.check(.comma)) {
                    self.reportLexerError(self.previous.line, self.previous.column, "Syntax Error: varargs parameter ('...') must be the last parameter.", .{});
                    return error.ParseError;
                }
                if (!self.check(.r_paren)) {
                    self.reportLexerError(self.current.line, self.current.column, "Syntax Error: varargs parameter ('...') must be the last parameter.", .{});
                    return error.ParseError;
                }
            }

            var initializer: ?*ASTNode = null;
            if (self.match(.eq)) {
                initializer = try self.expression();
            }

            try params.append(.{
                .name = param_name,
                .type_ref = parsed_type,
                .initializer = initializer,
                .is_varargs = is_varargs,
            });

            if (!self.match(.comma)) break;
        }
    }
    try self.consume(.r_paren, "Expected ')' after parameters.");

    const parsed_ret = try self.parseTypeAnnotation();

    var body: *ASTNode = undefined;
    var is_expr = false;

    if (self.match(.eq)) {
        body = try self.expression();
        is_expr = true;
    } else if (self.match(.l_brace)) {
        var stmts = ArrayList(*ASTNode).init(self.allocator);
        while (!self.check(.r_brace) and !self.check(.eof)) {
            try stmts.append(try self.declaration());
        }
        try self.consume(.r_brace, "Expected '}' after block.");
        body = try self.createNode(.{ .block = .{ .statements = try stmts.toOwnedSlice() } });
    } else if (allow_no_body) {
        body = try self.createNode(.{ .block = .{ .statements = &[_]*ASTNode{} } });
    } else {
        self.errorAtCurrent("Invalid function body.");
        return error.ParseError;
    }

    return try self.createNodeAt(.{ .fun_decl = .{
        .annotations = annotations,
        .modifiers = modifiers,
        .name = name,
        .generic_params = try generic_params.toOwnedSlice(),
        .params = try params.toOwnedSlice(),
        .type_ref = parsed_ret,
        .body = body,
        .is_expr_body = is_expr,
        .resolved_c_name = null,
    }}, line, col);
}

pub fn typeDeclaration(self: *Parser, annotations: []ast.Annotation) anyerror!*ASTNode {
    const line = self.previous.line;
    const col = self.previous.column;

    if (self.check(.kw_default)) {
        self.reportLexerError(self.current.line, self.current.column, "Syntax Error: 'default' is a reserved keyword in Eiwa.", .{});
        return error.ParseError;
    }
    var name: []const u8 = "";
    if (self.match(.identifier)) {
        name = self.previous.lexeme;
    }

    var generic_params = ArrayList([]const u8).init(self.allocator);
    if (self.match(.less)) {
        if (!self.check(.greater)) {
            while (true) {
                try self.consume(.identifier, "Expected generic parameter name.");
                try generic_params.append(self.previous.lexeme);
                if (self.match(.colon)) {
                    _ = try self.parseType();
                }
                if (!self.match(.comma)) break;
            }
        }
        try self.consume(.greater, "Expected '>' after generic parameters.");
    }

    var props = ArrayList(ast.ClassProp).init(self.allocator);
    if (self.match(.l_paren)) {
        if (!self.check(.r_paren)) {
            while (true) {
                var is_property = true;
                var is_mut = false;
                if (self.match(.kw_var)) {
                    is_mut = true;
                } else if (self.match(.kw_val)) {
                    is_mut = false;
                } else {
                    is_property = false;
                }

                try self.consume(.identifier, "Expected parameter or property name.");
                const prop_name = self.previous.lexeme;

                const parsed_type = try self.parseTypeAnnotation() orelse {
                    self.errorAtCurrent("Expected parameter or property type.");
                    return error.ParseError;
                };

                var initializer: ?*ASTNode = null;
                if (self.match(.eq)) {
                    initializer = try self.expression();
                }

                try props.append(.{
                    .is_mut = is_mut,
                    .name = prop_name,
                    .type_ref = parsed_type,
                    .is_property = is_property,
                    .initializer = initializer,
                });

                if (!self.match(.comma)) break;
            }
        }
        try self.consume(.r_paren, "Expected ')' after type primary constructor.");
    }

    var contracts = ArrayList([]const u8).init(self.allocator);
    var skills = ArrayList([]const u8).init(self.allocator);
    while (true) {
        if (self.match(.colon)) {
            while (true) {
                try self.consume(.identifier, "Expected contract name after ':'.");
                try contracts.append(self.previous.lexeme);
                if (self.match(.less)) {
                    var depth: usize = 1;
                    while (depth > 0 and !self.check(.eof)) {
                        if (self.match(.less)) {
                            depth += 1;
                        } else if (self.match(.greater)) {
                            depth -= 1;
                        } else {
                            _ = self.advance();
                        }
                    }
                }
                if (!self.match(.comma)) break;
            }
        } else if (self.match(.plus)) {
            while (true) {
                try self.consume(.identifier, "Expected skill name after '+'.");
                try skills.append(self.previous.lexeme);
                if (self.match(.less)) {
                    var depth: usize = 1;
                    while (depth > 0 and !self.check(.eof)) {
                        if (self.match(.less)) {
                            depth += 1;
                        } else if (self.match(.greater)) {
                            depth -= 1;
                        } else {
                            _ = self.advance();
                        }
                    }
                }
                if (!self.match(.comma)) break;
            }
        } else {
            break;
        }
    }

    var methods = ArrayList(*ASTNode).init(self.allocator);
    var body_fields = ArrayList(ast.ClassProp).init(self.allocator);
    if (self.match(.l_brace)) {
        while (!self.check(.r_brace) and !self.check(.eof)) {
            const member_annotations = try self.parseAnnotations();
            const modifiers = try self.parseModifiers();

            if (self.match(.kw_fun)) {
                try methods.append(try self.funDeclaration(member_annotations, modifiers, false));
            } else if (self.match(.kw_var)) {
                // Body field: `var name: Type = expr` (mutable, not a ctor arg).
                try body_fields.append(try self.parseBodyField(true, modifiers));
            } else if (self.match(.kw_val)) {
                // Body field: `val name: Type = expr` (immutable, not a ctor arg).
                try body_fields.append(try self.parseBodyField(false, modifiers));
            } else {
                self.errorAtCurrent("Only methods and `var`/`val` fields are supported inside types.");
                return error.ParseError;
            }
        }
        try self.consume(.r_brace, "Expected '}' after type body.");
    }

    return try self.createNodeAt(.{ .type_decl = .{
        .annotations = annotations,
        .name = name,
        .generic_params = try generic_params.toOwnedSlice(),
        .primary_constructor = try props.toOwnedSlice(),
        .methods = try methods.toOwnedSlice(),
        .resolved_c_name = null,
        .contracts = try contracts.toOwnedSlice(),
        .skills = try skills.toOwnedSlice(),
        .body_fields = try body_fields.toOwnedSlice(),
    } }, line, col);
}

/// Parses a body field declaration: `var`/`val` already consumed.
///   `var x: T = expr`   (non-null requires initializer; nullable may omit → null)
///   `val x: T = expr`   (initializer REQUIRED — Kotlin-style body property)
/// Returns a `ClassProp` (is_property = true) that is NOT a constructor arg.
pub fn parseBodyField(self: *Parser, is_mut: bool, modifiers: []const ast.TokenType) !ast.ClassProp {
    if (modifiers.len > 0) {
        self.errorAtCurrent("Modifiers not allowed on body fields.");
        return error.ParseError;
    }
    try self.consume(.identifier, "Expected body field name.");
    const field_name = self.previous.lexeme;

    const parsed_type = try self.parseTypeAnnotation() orelse {
        self.errorAtCurrent("Expected body field type.");
        return error.ParseError;
    };

    var initializer: ?*ASTNode = null;
    if (self.match(.eq)) {
        initializer = try self.expression();
    } else if (parsed_type.is_nullable) {
        // Nullable body fields may omit the initializer and default to null.
        initializer = try self.createNodeAt(.null_literal, self.previous.line, self.previous.column);
    } else if (!is_mut) {
        self.errorAtCurrent("Body `val` fields must have an initializer (Kotlin-style).");
        return error.ParseError;
    } else {
        self.errorAtCurrent("Body `var` fields of non-nullable type must have an initializer.");
        return error.ParseError;
    }

    return .{
        .is_mut = is_mut,
        .name = field_name,
        .type_ref = parsed_type,
        .is_property = true,
        .initializer = initializer,
    };
}

pub fn contractDeclaration(self: *Parser, annotations: []ast.Annotation) anyerror!*ASTNode {
    const line = self.previous.line;
    const col = self.previous.column;

    try self.consume(.identifier, "Expected contract name.");
    const name = self.previous.lexeme;

    var generic_params = ArrayList([]const u8).init(self.allocator);
    if (self.match(.less)) {
        if (!self.check(.greater)) {
            while (true) {
                try self.consume(.identifier, "Expected generic parameter name.");
                try generic_params.append(self.previous.lexeme);
                if (!self.match(.comma)) break;
            }
        }
        try self.consume(.greater, "Expected '>' after generic parameters.");
    }

    var methods = ArrayList(*ASTNode).init(self.allocator);
    // Braces are optional for empty (marker) contracts: `contract Animal`
    if (self.match(.l_brace)) {
        while (!self.check(.r_brace) and !self.check(.eof)) {
            const member_annotations = try self.parseAnnotations();
            const modifiers = try self.parseModifiers();

            if (self.match(.kw_fun)) {
                const func = try self.funDeclaration(member_annotations, modifiers, true);
                const f = func.data.fun_decl;
                if (f.is_expr_body or f.body.data.block.statements.len > 0) {
                    self.errorAtCurrent("Contract methods cannot have a body.");
                    return error.ParseError;
                }
                try methods.append(func);
            } else {
                self.errorAtCurrent("Contracts may only declare methods (no state, no constructors).");
                return error.ParseError;
            }
        }
        try self.consume(.r_brace, "Expected '}' after contract body.");
    }

    return try self.createNodeAt(.{ .contract_decl = .{
        .annotations = annotations,
        .name = name,
        .generic_params = try generic_params.toOwnedSlice(),
        .methods = try methods.toOwnedSlice(),
        .resolved_c_name = null,
    } }, line, col);
}

pub fn skillDeclaration(self: *Parser, annotations: []ast.Annotation) anyerror!*ASTNode {
    const line = self.previous.line;
    const col = self.previous.column;

    try self.consume(.identifier, "Expected skill name.");
    const name = self.previous.lexeme;

    var generic_params = ArrayList([]const u8).init(self.allocator);
    if (self.match(.less)) {
        if (!self.check(.greater)) {
            while (true) {
                try self.consume(.identifier, "Expected generic parameter name.");
                try generic_params.append(self.previous.lexeme);
                if (!self.match(.comma)) break;
            }
        }
        try self.consume(.greater, "Expected '>' after generic parameters.");
    }

    var required_contracts = ArrayList([]const u8).init(self.allocator);
    if (self.match(.colon)) {
        while (true) {
            try self.consume(.identifier, "Expected contract name after ':'.");
            try required_contracts.append(self.previous.lexeme);
            if (self.match(.less)) {
                var depth: usize = 1;
                while (depth > 0 and !self.check(.eof)) {
                    if (self.match(.less)) {
                        depth += 1;
                    } else if (self.match(.greater)) {
                        depth -= 1;
                    } else {
                        _ = self.advance();
                    }
                }
            }
            if (!self.match(.comma)) break;
        }
    }

    try self.consume(.l_brace, "Expected '{' before skill body.");
    var methods = ArrayList(*ASTNode).init(self.allocator);
    while (!self.check(.r_brace) and !self.check(.eof)) {
        const member_annotations = try self.parseAnnotations();
        const modifiers = try self.parseModifiers();

        if (self.match(.kw_fun)) {
            try methods.append(try self.funDeclaration(member_annotations, modifiers, false));
        } else {
            self.errorAtCurrent("Skills may only declare methods (no state, no constructors).");
            return error.ParseError;
        }
    }
    try self.consume(.r_brace, "Expected '}' after skill body.");

    return try self.createNodeAt(.{ .skill_decl = .{
        .annotations = annotations,
        .name = name,
        .generic_params = try generic_params.toOwnedSlice(),
        .required_contracts = try required_contracts.toOwnedSlice(),
        .methods = try methods.toOwnedSlice(),
        .resolved_c_name = null,
    } }, line, col);
}

pub fn objectDeclaration(self: *Parser, annotations: []ast.Annotation) anyerror!*ASTNode {
    const line = self.previous.line;
    const col = self.previous.column;
    
    var name: ?[]const u8 = null;
    if (self.match(.identifier)) {
        name = self.previous.lexeme;
    }

    var contracts = ArrayList([]const u8).init(self.allocator);
    var skills = ArrayList([]const u8).init(self.allocator);
    if (self.match(.colon)) {
        while (true) {
            try self.consume(.identifier, "Expected contract name after ':'.");
            try contracts.append(self.previous.lexeme);
            if (self.match(.less)) {
                var depth: usize = 1;
                while (depth > 0 and !self.check(.eof)) {
                    if (self.match(.less)) {
                        depth += 1;
                    } else if (self.match(.greater)) {
                        depth -= 1;
                    } else {
                        _ = self.advance();
                    }
                }
            }
            if (!self.match(.comma)) break;
        }

        while (true) {
            if (self.match(.plus)) {
                while (true) {
                    try self.consume(.identifier, "Expected skill name after '+'.");
                    try skills.append(self.previous.lexeme);
                    if (self.match(.less)) {
                        var depth: usize = 1;
                        while (depth > 0 and !self.check(.eof)) {
                            if (self.match(.less)) {
                                depth += 1;
                            } else if (self.match(.greater)) {
                                depth -= 1;
                            } else {
                                _ = self.advance();
                            }
                        }
                    }
                    if (!self.match(.comma)) break;
                }
            } else {
                break;
            }
        }
    }
    
    try self.consume(.l_brace, "Expected '{' before object body.");
    var members = ArrayList(*ASTNode).init(self.allocator);
    while (!self.check(.r_brace) and !self.check(.eof)) {
        const member_annotations = try self.parseAnnotations();
        const modifiers = try self.parseModifiers();

        if (self.match(.kw_fun)) {
            const func = try self.funDeclaration(member_annotations, modifiers, false);
            try members.append(func);
        } else if (self.match(.kw_val)) {
            if (modifiers.len > 0) { self.errorAtCurrent("Modifiers not allowed on val"); return error.ParseError; }
            const v = try self.varDeclaration(false);
            try members.append(v);
        } else if (self.match(.kw_var)) {
            if (modifiers.len > 0) { self.errorAtCurrent("Modifiers not allowed on var"); return error.ParseError; }
            const v = try self.varDeclaration(true);
            try members.append(v);
        } else {
            self.errorAtCurrent("Expected function or variable declaration inside object.");
            return error.ParseError;
        }
    }
    try self.consume(.r_brace, "Expected '}' after object body.");
    
    return try self.createNodeAt(.{ .object_decl = .{
        .annotations = annotations,
        .name = name,
        .members = try members.toOwnedSlice(),
        .resolved_c_name = null,
        .contracts = try contracts.toOwnedSlice(),
        .skills = try skills.toOwnedSlice(),
    } }, line, col);
}

pub fn enumDeclaration(self: *Parser, annotations: []ast.Annotation) anyerror!*ASTNode {
    const line = self.previous.line;
    const col = self.previous.column;
    try self.consume(.identifier, "Expected enum name.");
    const enum_name = self.previous.lexeme;

    try self.consume(.l_brace, "Expected '{' before enum body.");
    var variants = ArrayList(ast.EnumVariant).init(self.allocator);
    var ordinal: usize = 0;

    while (!self.check(.r_brace) and !self.check(.eof)) {
        try self.consume(.identifier, "Expected enum variant name.");
        try variants.append(.{
            .name = self.previous.lexeme,
            .ordinal = ordinal,
        });
        ordinal += 1;

        if (self.match(.comma)) {
            // optional trailing or separating comma
        }
    }
    try self.consume(.r_brace, "Expected '}' after enum body.");

    return try self.createNodeAt(.{ .enum_decl = .{
        .annotations = annotations,
        .name = enum_name,
        .variants = try variants.toOwnedSlice(),
        .resolved_c_name = null,
    } }, line, col);
}

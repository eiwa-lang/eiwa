const std = @import("std");
const compat = @import("../../core/compat.zig");
const ArrayList = compat.ArrayList;
const ast = @import("../../core/ast.zig");
const ASTNode = ast.ASTNode;
const TokenType = ast.TokenType;
const Parser = @import("core.zig").Parser;

pub fn expression(self: *Parser) anyerror!*ASTNode {
    return try self.assignment();
}

pub fn assignment(self: *Parser) anyerror!*ASTNode {
    const expr = try self.ternary();

    if (self.match(.eq)) {
        const line = self.previous.line;
        const col = self.previous.column;
        
        const value = try self.assignment();

        if (expr.data == .identifier) {
            const name = expr.data.identifier.name;
            return try self.createNodeAt(.{ .assignment = .{ .name = name, .value = value } }, line, col);
        } else if (expr.data == .get_expr) {
            return try self.createNodeAt(.{ .set_expr = .{ 
                .object = expr.data.get_expr.object, 
                .name = expr.data.get_expr.name, 
                .is_safe = expr.data.get_expr.is_safe,
                .value = value 
            } }, line, col);
        } else if (expr.data == .index_expr) {
            return try self.createNodeAt(.{ .index_set_expr = .{
                .object = expr.data.index_expr.object,
                .index = expr.data.index_expr.index,
                .value = value
            } }, line, col);
        }

        self.errorAtCurrent("Invalid assignment target.");
    }

    return expr;
}

pub fn ternary(self: *Parser) anyerror!*ASTNode {
    const expr = try self.elvis();

    if (self.match(.question)) {
        const line = self.previous.line;
        const col = self.previous.column;
        
        const then_branch = try self.expression();
        
        var else_branch: ?*ASTNode = null;
        if (self.match(.colon)) {
            else_branch = try self.ternary();
        }
        
        return try self.createNodeAt(.{ .ternary_expr = .{
            .condition = expr,
            .then_branch = then_branch,
            .else_branch = else_branch,
        } }, line, col);
    }

    return expr;
}

pub fn elvis(self: *Parser) anyerror!*ASTNode {
    var expr = try self.logicOr();

    while (self.match(.elvis)) {
        const op = self.previous.token_type;
        const line = self.previous.line;
        const col = self.previous.column;
        const right = try self.logicOr();
        expr = try self.createNodeAt(.{ .binary_expr = .{ .left = expr, .op = op, .right = right } }, line, col);
    }
    return expr;
}

pub fn logicOr(self: *Parser) anyerror!*ASTNode {
    var expr = try self.logicAnd();

    while (self.match(.or_or)) {
        const op = self.previous.token_type;
        const line = self.previous.line;
        const col = self.previous.column;
        const right = try self.logicAnd();
        expr = try self.createNodeAt(.{ .binary_expr = .{ .left = expr, .op = op, .right = right } }, line, col);
    }
    return expr;
}

pub fn logicAnd(self: *Parser) anyerror!*ASTNode {
    var expr = try self.equality();

    while (self.match(.and_and)) {
        const op = self.previous.token_type;
        const line = self.previous.line;
        const col = self.previous.column;
        const right = try self.equality();
        expr = try self.createNodeAt(.{ .binary_expr = .{ .left = expr, .op = op, .right = right } }, line, col);
    }
    return expr;
}

pub fn equality(self: *Parser) anyerror!*ASTNode {
    var expr = try self.ofOperator();

    while (self.match(.eq_eq) or self.match(.bang_eq)) {
        const op = self.previous.token_type;
        const line = self.previous.line;
        const col = self.previous.column;
        const right = try self.ofOperator();
        expr = try self.createNodeAt(.{ .binary_expr = .{ .left = expr, .op = op, .right = right } }, line, col);
    }
    return expr;
}

pub fn ofOperator(self: *Parser) anyerror!*ASTNode {
    var expr = try self.comparison();

    while (self.match(.kw_of)) {
        const op = self.previous.token_type;
        const line = self.previous.line;
        const col = self.previous.column;
        const right = try self.comparison();
        expr = try self.createNodeAt(.{ .binary_expr = .{ .left = expr, .op = op, .right = right } }, line, col);
    }
    return expr;
}
pub fn comparison(self: *Parser) anyerror!*ASTNode {
    var expr = try self.typeCheckOrCast();

    while (self.match(.greater) or self.match(.greater_eq) or self.match(.less) or self.match(.less_eq)) {
        const op = self.previous.token_type;
        const line = self.previous.line;
        const col = self.previous.column;
        const right = try self.typeCheckOrCast();
        expr = try self.createNodeAt(.{ .binary_expr = .{ .left = expr, .op = op, .right = right } }, line, col);
    }
    return expr;
}

pub fn typeCheckOrCast(self: *Parser) anyerror!*ASTNode {
    var expr = try self.term();

    while (true) {
        if (self.match(.kw_as)) {
            const line = self.previous.line;
            const col = self.previous.column;
            const type_ref = try self.parseType();
            expr = try self.createNodeAt(.{ .as_expr = .{ .value = expr, .type_ref = type_ref } }, line, col);
        } else if (self.check(.kw_is)) {
            var temp_lexer = self.lexer;
            var is_when_branch = false;
            while (true) {
                const tok = temp_lexer.scanToken();
                if (tok.token_type == .arrow) {
                    is_when_branch = true;
                    break;
                }
                if (tok.token_type == .l_brace or tok.token_type == .r_brace or tok.token_type == .eof) {
                    break;
                }
            }
            if (is_when_branch) break;

            _ = self.match(.kw_is);
            const line = self.previous.line;
            const col = self.previous.column;
            const type_ref = try self.parseType();
            expr = try self.createNodeAt(.{ .is_expr = .{ .value = expr, .type_ref = type_ref, .is_not = false } }, line, col);
        } else if (self.check(.kw_not_is)) {
            var temp_lexer = self.lexer;
            var is_when_branch = false;
            while (true) {
                const tok = temp_lexer.scanToken();
                if (tok.token_type == .arrow) {
                    is_when_branch = true;
                    break;
                }
                if (tok.token_type == .l_brace or tok.token_type == .r_brace or tok.token_type == .eof) {
                    break;
                }
            }
            if (is_when_branch) break;

            _ = self.match(.kw_not_is);
            const line = self.previous.line;
            const col = self.previous.column;
            const type_ref = try self.parseType();
            expr = try self.createNodeAt(.{ .is_expr = .{ .value = expr, .type_ref = type_ref, .is_not = true } }, line, col);
        } else {
            break;
        }
    }
    return expr;
}


pub fn term(self: *Parser) anyerror!*ASTNode {
    var expr = try self.factor();

    while (self.match(.minus) or self.match(.plus)) {
        const op = self.previous.token_type;
        const line = self.previous.line;
        const col = self.previous.column;
        const right = try self.factor();
        expr = try self.createNodeAt(.{ .binary_expr = .{ .left = expr, .op = op, .right = right } }, line, col);
    }
    return expr;
}

pub fn factor(self: *Parser) anyerror!*ASTNode {
    var expr = try self.unary();

    while (self.match(.slash) or self.match(.star)) {
        const op = self.previous.token_type;
        const line = self.previous.line;
        const col = self.previous.column;
        const right = try self.unary();
        expr = try self.createNodeAt(.{ .binary_expr = .{ .left = expr, .op = op, .right = right } }, line, col);
    }
    return expr;
}

pub fn unary(self: *Parser) anyerror!*ASTNode {
    if (self.match(.bang) or self.match(.minus)) {
        const op = self.previous.token_type;
        const line = self.previous.line;
        const col = self.previous.column;
        const right = try self.unary();
        return try self.createNodeAt(.{ .unary_expr = .{ .operator = op, .operand = right } }, line, col);
    }
    return try self.call();
}

pub fn call(self: *Parser) anyerror!*ASTNode {
    var expr = try self.primary();

    if (expr.data == .identifier and self.check(.less)) {
        const saved = self.*;
        self.suppress_errors = true;
        var type_args = ArrayList(*const ast.ASTTypeRef).init(self.allocator);
        var ok = true;

        _ = self.match(.less);
        if (self.check(.greater)) {
            ok = false;
        } else {
            while (true) {
                const arg = self.parseType() catch {
                    ok = false;
                    break;
                };
                try type_args.append(arg);
                if (!self.match(.comma)) break;
            }
        }

        if (ok and self.match(.greater) and (self.check(.l_paren) or self.check(.l_brace))) {
            self.suppress_errors = saved.suppress_errors;
            const owned_type_args = try type_args.toOwnedSlice();
            if (self.match(.l_paren)) {
                expr = try self.finishCall(expr, owned_type_args);
            } else {
                expr = try self.createNodeAt(.{ .call_expr = .{ .callee = expr, .arguments = &.{}, .type_args = owned_type_args } }, self.previous.line, self.previous.column);
            }
            if (self.match(.l_brace)) {
                const line = self.previous.line;
                const col = self.previous.column;
                const lambda = try parseLambdaLiteral(self, line, col);
                if (expr.data == .call_expr) {
                    var new_args = ArrayList(*ASTNode).init(self.allocator);
                    try new_args.appendSlice(expr.data.call_expr.arguments);
                    try new_args.append(lambda);
                    expr.data.call_expr.arguments = try new_args.toOwnedSlice();
                }
            }
        } else {
            self.* = saved;
        }
    }

    while (true) {
        if (self.match(.l_paren)) {
            expr = try self.finishCall(expr, &.{});
            if (self.match(.l_brace)) {
                const line = self.previous.line;
                const col = self.previous.column;
                const lambda = try parseLambdaLiteral(self, line, col);
                if (expr.data == .call_expr) {
                    var new_args = ArrayList(*ASTNode).init(self.allocator);
                    try new_args.appendSlice(expr.data.call_expr.arguments);
                    try new_args.append(lambda);
                    expr.data.call_expr.arguments = try new_args.toOwnedSlice();
                }
            }
        } else if (self.match(.l_brace)) {
            const line = self.previous.line;
            const col = self.previous.column;
            const lambda = try parseLambdaLiteral(self, line, col);
            const args = try self.allocator.alloc(*ASTNode, 1);
            args[0] = lambda;
            expr = try self.createNodeAt(.{ .call_expr = .{
                .callee = expr,
                .arguments = args,
            } }, line, col);
        } else if (self.match(.dot) or self.match(.question_dot)) {
            const is_safe = self.previous.token_type == .question_dot;
            try self.consume(.identifier, "Expected property name.");
            const name = self.previous.lexeme;
            expr = try self.createNode(.{ .get_expr = .{ .object = expr, .name = name, .is_safe = is_safe } });
            if (expr.data == .get_expr and self.check(.less)) {
                const saved = self.*;
                self.suppress_errors = true;
                var type_args = ArrayList(*const ast.ASTTypeRef).init(self.allocator);
                var ok = true;
                _ = self.match(.less);
                if (self.check(.greater)) {
                    ok = false;
                } else {
                    while (true) {
                        const arg = self.parseType() catch {
                            ok = false;
                            break;
                        };
                        try type_args.append(arg);
                        if (!self.match(.comma)) break;
                    }
                }
                if (ok and self.match(.greater) and self.check(.l_paren)) {
                    self.suppress_errors = saved.suppress_errors;
                    _ = self.match(.l_paren);
                    expr = try self.finishCall(expr, try type_args.toOwnedSlice());
                    if (self.match(.l_brace)) {
                        const line = self.previous.line;
                        const col = self.previous.column;
                        const lambda = try parseLambdaLiteral(self, line, col);
                        if (expr.data == .call_expr) {
                            var new_args = ArrayList(*ASTNode).init(self.allocator);
                            try new_args.appendSlice(expr.data.call_expr.arguments);
                            try new_args.append(lambda);
                            expr.data.call_expr.arguments = try new_args.toOwnedSlice();
                        }
                    }
                } else {
                    self.* = saved;
                }
            }
        } else if (self.match(.bang_bang)) {
            expr = try self.createNode(.{ .unary_expr = .{ .operator = .bang_bang, .operand = expr } });
        } else if (self.match(.l_bracket)) {
            const index = try self.expression();
            try self.consume(.r_bracket, "Expected ']' after index.");
            expr = try self.createNode(.{ .index_expr = .{ .object = expr, .index = index } });
        } else {
            break;
        }
    }

    return expr;
}

pub fn finishCall(self: *Parser, callee: *ASTNode, type_args: []const *const ast.ASTTypeRef) anyerror!*ASTNode {
    const line = self.previous.line;
    const col = self.previous.column;
    var args = ArrayList(*ASTNode).init(self.allocator);
    if (!self.check(.r_paren)) {
        while (true) {
            try args.append(try self.expression());
            if (!self.match(.comma)) break;
        }
    }
    try self.consume(.r_paren, "Expected ')' after arguments.");
    return try self.createNodeAt(.{ .call_expr = .{ .callee = callee, .arguments = try args.toOwnedSlice(), .type_args = type_args } }, line, col);
}

pub fn parseLambdaLiteral(self: *Parser, line: usize, col: usize) anyerror!*ASTNode {
    var params = ArrayList(ast.Param).init(self.allocator);
    var temp_lexer = self.lexer;
    var has_arrow = false;
    var brace_depth: usize = 0;
    while (true) {
        const tok = temp_lexer.scanToken();
        if (tok.token_type == .eof) break;
        if (tok.token_type == .l_brace) brace_depth += 1;
        if (tok.token_type == .r_brace) {
            if (brace_depth == 0) break;
            brace_depth -= 1;
        }
        if (tok.token_type == .arrow and brace_depth == 0) {
            has_arrow = true;
            break;
        }
    }

    if (has_arrow) {
        while (!self.check(.arrow) and !self.check(.eof)) {
            try self.consume(.identifier, "Expected parameter name in lambda.");
            const p_name = self.previous.lexeme;
            var p_type: ?*const ast.ASTTypeRef = null;
            if (self.match(.colon)) {
                p_type = try self.parseType();
            }
            try params.append(ast.Param{
                .name = p_name,
                .type_ref = p_type,
                .initializer = null,
            });
            if (!self.match(.comma)) break;
        }
        try self.consume(.arrow, "Expected '->' after lambda parameters.");
    }

    var body_stmts = ArrayList(*ASTNode).init(self.allocator);
    while (!self.check(.r_brace) and !self.check(.eof)) {
        try body_stmts.append(try self.declaration());
    }
    try self.consume(.r_brace, "Expected '}' at the end of lambda expression.");

    return try self.createNodeAt(.{ .lambda_expr = .{
        .params = try params.toOwnedSlice(),
        .body = try body_stmts.toOwnedSlice(),
    } }, line, col);
}

pub fn primary(self: *Parser) anyerror!*ASTNode {
    const line = self.current.line;
    const col = self.current.column;
    
    if (self.check(.kw_default)) {
        self.reportLexerError(self.current.line, self.current.column, "Syntax Error: 'default' is a reserved keyword in Eiwa.", .{});
        return error.ParseError;
    }

    if (self.match(.kw_null)) {
        return try self.createNode(.{ .null_literal = {} });
    }

    if (self.match(.kw_if)) {
        try self.consume(.l_paren, "Expected '(' after 'if'.");
        const condition = try self.expression();
        try self.consume(.r_paren, "Expected ')' after condition.");
        
        var then_branch: *ASTNode = undefined;
        if (self.match(.l_brace)) {
            var stmts = ArrayList(*ASTNode).init(self.allocator);
            while (!self.check(.r_brace) and !self.check(.eof)) {
                try stmts.append(try self.declaration());
            }
            try self.consume(.r_brace, "Expected '}'.");
            then_branch = try self.createNode(.{ .block = .{ .statements = try stmts.toOwnedSlice() } });
        } else {
            then_branch = try self.expression();
        }
        
        var else_branch: ?*ASTNode = null;
        if (self.match(.kw_else)) {
            if (self.match(.l_brace)) {
                var stmts = ArrayList(*ASTNode).init(self.allocator);
                while (!self.check(.r_brace) and !self.check(.eof)) {
                    try stmts.append(try self.declaration());
                }
                try self.consume(.r_brace, "Expected '}'.");
                else_branch = try self.createNode(.{ .block = .{ .statements = try stmts.toOwnedSlice() } });
            } else {
                else_branch = try self.expression();
            }
        }
        return try self.createNodeAt(.{ .if_expr = .{ .condition = condition, .then_branch = then_branch, .else_branch = else_branch } }, line, col);
    }

    if (self.match(.kw_when)) {
        var subject: ?*ASTNode = null;
        if (self.match(.l_paren)) {
            subject = try self.expression();
            try self.consume(.r_paren, "Expected ')' after subject.");
        }

        try self.consume(.l_brace, "Expected '{' after 'when'.");

        var cases = ArrayList(ast.WhenCase).init(self.allocator);
        while (!self.check(.r_brace) and !self.check(.eof)) {
            var conds = ArrayList(*ASTNode).init(self.allocator);
            var is_else = false;

            if (self.match(.kw_else)) {
                is_else = true;
            } else {
                while (true) {
                    if (self.match(.kw_is)) {
                        const tc_line = self.previous.line;
                        const tc_col = self.previous.column;
                        const type_ref = try self.parseType();
                        const cond_node = try self.createNodeAt(.{ .is_type_cond = .{ .type_ref = type_ref, .is_not = false } }, tc_line, tc_col);
                        try conds.append(cond_node);
                    } else if (self.match(.kw_not_is)) {
                        const tc_line = self.previous.line;
                        const tc_col = self.previous.column;
                        const type_ref = try self.parseType();
                        const cond_node = try self.createNodeAt(.{ .is_type_cond = .{ .type_ref = type_ref, .is_not = true } }, tc_line, tc_col);
                        try conds.append(cond_node);
                    } else {
                        try conds.append(try self.expression());
                    }

                    if (!self.match(.comma)) break;
                }
            }

            try self.consume(.arrow, "Expected '->' after condition.");

            var body: *ASTNode = undefined;
            if (self.match(.l_brace)) {
                var stmts = ArrayList(*ASTNode).init(self.allocator);
                while (!self.check(.r_brace) and !self.check(.eof)) {
                    try stmts.append(try self.declaration());
                }
                try self.consume(.r_brace, "Expected '}' after block body.");
                body = try self.createNode(.{ .block = .{ .statements = try stmts.toOwnedSlice() } });
            } else {
                body = try self.expression();
            }

            try cases.append(ast.WhenCase{
                .conds = try conds.toOwnedSlice(),
                .body = body,
                .is_else = is_else,
            });
        }
        try self.consume(.r_brace, "Expected '}' at the end of 'when' expression.");
        return try self.createNodeAt(.{ .when_expr = .{ .subject = subject, .cases = try cases.toOwnedSlice() } }, line, col);
    }
    
    if (self.match(.bool_literal)) {
        return try self.createNodeAt(.{ .bool_literal = std.mem.eql(u8, self.previous.lexeme, "true") }, line, col);
    }
    
    if (self.match(.l_brace)) {
        return try parseLambdaLiteral(self, line, col);
    }
    
    if (self.match(.l_paren)) {
        const expr = try self.expression();
        try self.consume(.r_paren, "Expected ')' after expression.");
        return expr;
    }
    
    if (self.match(.int_literal)) {
        const value = try std.fmt.parseInt(i64, self.previous.lexeme, 10);
        return try self.createNodeAt(.{ .int_literal = value }, line, col);
    }
    if (self.match(.string_literal)) {
        const lexeme = self.previous.lexeme;
        const value = lexeme[1 .. lexeme.len - 1];
        return try self.createNodeAt(.{ .string_literal = value }, line, col);
    }
    if (self.match(.identifier)) {
        return try self.createNodeAt(.{ .identifier = .{
            .name = self.previous.lexeme,
            .resolved_c_name = null,
        } }, line, col);
    }
    
    if (self.match(.l_bracket)) {
        var elements = ArrayList(*ASTNode).init(self.allocator);
        var is_map = false;
        
        if (!self.check(.r_bracket)) {
            while (true) {
                const expr = try self.expression();
                if (expr.data == .binary_expr and expr.data.binary_expr.op == .kw_of) {
                    is_map = true;
                }
                try elements.append(expr);
                if (!self.match(.comma)) break;
            }
        }
        try self.consume(.r_bracket, "Expected ']' after array elements.");
        
        if (is_map) {
            return try self.createNodeAt(.{ .map_literal = .{ .elements = try elements.toOwnedSlice() } }, line, col);
        } else {
            return try self.createNodeAt(.{ .array_literal = .{ .elements = try elements.toOwnedSlice() } }, line, col);
        }
    }

    self.errorAtCurrent("Expected expression.");
    return error.ParseError;
}

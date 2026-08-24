const std = @import("std");
const compat = @import("../../core/compat.zig");
const ArrayList = compat.ArrayList;
const ast = @import("../../core/ast.zig");
const ASTNode = ast.ASTNode;
const TokenType = ast.TokenType;
const Parser = @import("core.zig").Parser;

pub fn whileStatement(self: *Parser) anyerror!*ASTNode {
    const line = self.previous.line;
    const col = self.previous.column;
    try self.consume(.l_paren, "Expected '(' after 'while'.");
    const condition = try self.expression();
    try self.consume(.r_paren, "Expected ')' after condition.");
    
    var body: *ASTNode = undefined;
    if (self.match(.l_brace)) {
        var stmts = ArrayList(*ASTNode).init(self.allocator);
        while (!self.check(.r_brace) and !self.check(.eof)) {
            try stmts.append(try self.declaration());
        }
        try self.consume(.r_brace, "Expected '}'.");
        body = try self.createNode(.{ .block = .{ .statements = try stmts.toOwnedSlice() } });
    } else {
        body = try self.expression();
    }

    return try self.createNodeAt(.{ .while_stmt = .{ .condition = condition, .body = body } }, line, col);
}

pub fn forStatement(self: *Parser) anyerror!*ASTNode {
    const line = self.previous.line;
    const col = self.previous.column;
    try self.consume(.l_paren, "Expected '(' after 'for'.");
    const iterable = try self.expression();
    try self.consume(.r_paren, "Expected ')' after iterable.");

    try self.consume(.l_brace, "Expected '{' for 'for' loop body.");

    var item_name: []const u8 = "it";

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
        try self.consume(.identifier, "Expected parameter name in for loop.");
        item_name = self.previous.lexeme;
        if (self.match(.colon)) {
            _ = try self.parseType();
        }
        try self.consume(.arrow, "Expected '->' after parameter in for loop.");
    }

    var stmts = ArrayList(*ASTNode).init(self.allocator);
    while (!self.check(.r_brace) and !self.check(.eof)) {
        try stmts.append(try self.declaration());
    }
    try self.consume(.r_brace, "Expected '}'.");
    const body = try self.createNode(.{ .block = .{ .statements = try stmts.toOwnedSlice() } });

    return try self.createNodeAt(.{ .for_stmt = .{ .item_name = item_name, .iterable = iterable, .body = body } }, line, col);
}

pub fn returnStatement(self: *Parser) anyerror!*ASTNode {
    const line = self.previous.line;
    const col = self.previous.column;
    var value: ?*ASTNode = null;
    if (!self.check(.r_brace) and !self.check(.eof)) {
        value = try self.expression();
    }
    
    return try self.createNodeAt(.{ .return_stmt = .{ .value = value } }, line, col);
}

pub fn throwStatement(self: *Parser) anyerror!*ASTNode {
    const line = self.previous.line;
    const col = self.previous.column;
    const expr = try self.expression();
    return try self.createNodeAt(.{ .throw_stmt = .{ .expr = expr } }, line, col);
}

pub fn tryStatement(self: *Parser) anyerror!*ASTNode {
    const line = self.previous.line;
    const col = self.previous.column;
    
    try self.consume(.l_brace, "Expected '{' after 'try'.");
    var try_stmts = ArrayList(*ASTNode).init(self.allocator);
    while (!self.check(.r_brace) and !self.check(.eof)) {
        try try_stmts.append(try self.declaration());
    }
    try self.consume(.r_brace, "Expected '}' after 'try' block.");
    const try_body = try self.createNode(.{ .block = .{ .statements = try try_stmts.toOwnedSlice() } });
    
    var catches = ArrayList(ast.CatchBlock).init(self.allocator);
    while (self.match(.kw_catch)) {
        var var_name: ?[]const u8 = null;
        var types = ArrayList(*const ast.ASTTypeRef).init(self.allocator);
        
        if (self.match(.l_paren)) {
            try self.consume(.identifier, "Expected exception variable name.");
            var_name = self.previous.lexeme;
            if (self.match(.colon)) {
                while (true) {
                    const t_ref = try self.parseType();
                    try types.append(t_ref);
                    if (!self.match(.pipe)) break;
                }
            } else {
                const t_ref = try self.allocator.create(ast.ASTTypeRef);
                t_ref.* = .{
                    .name = "Throwable",
                    .generic_args = &.{},
                    .is_array = false,
                    .is_nullable = false,
                };
                try types.append(t_ref);
            }

            try self.consume(.r_paren, "Expected ')' after catch parameter.");
        }

        try self.consume(.l_brace, "Expected '{' after catch declaration.");
        var catch_stmts = ArrayList(*ASTNode).init(self.allocator);
        while (!self.check(.r_brace) and !self.check(.eof)) {
            try catch_stmts.append(try self.declaration());
        }
        try self.consume(.r_brace, "Expected '}' after catch block.");
        const catch_body = try self.createNode(.{ .block = .{ .statements = try catch_stmts.toOwnedSlice() } });
        
        try catches.append(.{
            .var_name = var_name,
            .types = try types.toOwnedSlice(),
            .body = catch_body,
        });
    }
    
    return try self.createNodeAt(.{ .try_stmt = .{
        .body = try_body,
        .catches = try catches.toOwnedSlice(),
    } }, line, col);
}


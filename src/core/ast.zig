const std = @import("std");
const type_system = @import("type_system.zig");

/// Token types supported by the Eiwa compiler.
pub const TokenType = enum {
    // Keywords
    kw_val,
    kw_var,
    kw_fun,
    kw_type,
    kw_contract,
    kw_skill,
    kw_implement,
    kw_operator,
    kw_null,
    kw_if,
    kw_else,
    kw_return,
    kw_while,
    kw_import,
    kw_from,
    kw_test,
    kw_lib,
    kw_in,
    kw_for,
    kw_of,
    kw_as,
    kw_is,
    kw_not_is,
    kw_try,
    kw_catch,
    kw_throw,
    kw_when,
    kw_object,
    kw_default,
    kw_enum,

    // Symbols and Operators
    eq,         // =
    pipe,       // |
    l_paren,    // (
    r_paren,    // )
    l_brace,    // {
    r_brace,    // }
    l_bracket,  // [
    r_bracket,  // ]
    at,         // @
    colon,      // :
    comma,      // ,
    dot,        // .
    ellipsis,   // ...
    question,   // ?
    question_dot, // ?.
    elvis,      // ?:
    bang_bang,  // !!
    plus,       // +
    minus,      // -
    star,       // *
    slash,      // /
    eq_eq,      // ==
    bang,       // !
    bang_eq,    // !=
    less,       // <
    greater,    // >
    less_eq,    // <=
    greater_eq, // >=
    and_and,    // &&
    or_or,      // ||
    arrow,      // ->

    // Identifiers and Literals
    identifier,
    string_literal,
    int_literal,
    double_literal,
    bool_literal,

    invalid,
    eof,
};

/// Structure representing an individual token read by the Lexer.
pub const Token = struct {
    token_type: TokenType,
    lexeme: []const u8,
    line: usize,
    column: usize,
};

pub const Annotation = struct {
    name: []const u8,
    arguments: []const []const u8,
};

pub const ASTTypeRef = struct {
    name: []const u8,
    generic_args: []const *const ASTTypeRef,
    is_array: bool,
    is_nullable: bool,
    is_function: bool = false,
    union_types: []const *const ASTTypeRef = &.{},
    receiver_type: ?*const ASTTypeRef = null,
    return_type: ?*const ASTTypeRef = null,
    resolved_type: ?*const type_system.EiwaType = null,
};

/// Auxiliary structures for the AST
pub const Param = struct {
    name: []const u8,
    type_ref: ?*const ASTTypeRef,
    initializer: ?*ASTNode = null,
    /// Varargs parameter (`name: T...`): accepts N trailing call arguments,
    /// exposed as `List<T>` inside the body (Phase 66).
    is_varargs: bool = false,
};

pub const ClassProp = struct {
    is_mut: bool,
    name: []const u8,
    type_ref: *const ASTTypeRef,
    resolved_type: ?*const type_system.EiwaType = null,
    is_property: bool = true,
    initializer: ?*ASTNode = null,
    /// True when the field holds a box pointer to a shared mutable capture;
    /// the emitter stores/loads through the box (stackless task capture).
    is_boxed: bool = false,
};

pub const CatchBlock = struct {
    var_name: ?[]const u8,
    types: []const *const ASTTypeRef,
    body: *ASTNode,
};

pub const WhenCase = struct {
    conds: []const *ASTNode,
    body: *ASTNode,
    is_else: bool,
};

pub const EnumVariant = struct {
    name: []const u8,
    ordinal: usize,
};

pub const ASTNode = struct {
    line: usize,
    column: usize,
    resolved_type: ?*const type_system.EiwaType = null,
    expected_type: ?*const type_system.EiwaType = null,
    data: ASTNodeType,
};

/// Native Zig Union Type (Tagged Union) representing an AST node's data.
pub const ASTNodeType = union(enum) {
    program: struct {
        statements: []const *ASTNode,
    },
    import_stmt: struct {
        module_path: []const u8,
        destructured: []const []const u8,
        module_ast: ?*ASTNode,
    },
    var_decl: struct {
        is_mut: bool,
        name: []const u8,
        type_ref: ?*const ASTTypeRef, // Optional due to inference
        initializer: ?*ASTNode,
        is_boxed: bool = false,
        resolved_c_name: ?[]const u8 = null,
    },
    fun_decl: struct {
        annotations: []const Annotation,
        modifiers: []const TokenType,
        name: []const u8,
        generic_params: []const []const u8,
        params: []Param,
        type_ref: ?*const ASTTypeRef,
        body: *ASTNode,
        is_expr_body: bool, // true for `= a + b`, false for `{ ... }`
        resolved_c_name: ?[]const u8,
        from_skill: bool = false, // true when the method was cloned from a skill into a type
        /// True when the function (transitively) contains a call to an `@Suspend`
        /// function (detected by the coroutine pass, not by the parser).
        is_suspend: bool = false,
    },
    type_decl: struct {
        annotations: []const Annotation,
        name: []const u8,
        generic_params: []const []const u8,
        primary_constructor: []ClassProp,
        methods: []const *ASTNode,
        resolved_c_name: ?[]const u8,
        contracts: []const []const u8,
        skills: []const []const u8,
        skills_composed: bool = false,
        serde_generated: bool = false,
        /// Mutable/immutable fields declared in the type body (outside the
        /// primary constructor), e.g. `var count: Int = 0`. Each requires an
        /// initializer evaluated at construction. They are NOT constructor
        /// parameters — callers construct the type without them.
        body_fields: []ClassProp = &.{},
    },
    contract_decl: struct {
        annotations: []const Annotation,
        name: []const u8,
        generic_params: []const []const u8 = &.{},
        methods: []const *ASTNode,
        resolved_c_name: ?[]const u8,
    },
    skill_decl: struct {
        annotations: []const Annotation,
        name: []const u8,
        generic_params: []const []const u8 = &.{},
        required_contracts: []const []const u8,
        methods: []const *ASTNode,
        resolved_c_name: ?[]const u8,
    },
    test_decl: struct {
        name: []const u8,
        body: *ASTNode,
    },
    lib_decl: struct {
        annotations: []const Annotation,
        name: []const u8,
        functions: []const *ASTNode,
    },
    object_decl: struct {
        annotations: []const Annotation,
        name: ?[]const u8,
        members: []const *ASTNode,
        resolved_c_name: ?[]const u8,
        contracts: []const []const u8 = &.{},
        skills: []const []const u8 = &.{},
    },
    enum_decl: struct {
        annotations: []const Annotation,
        name: []const u8,
        variants: []const EnumVariant,
        resolved_c_name: ?[]const u8 = null,
    },
    
    // Literals
    int_literal: i64,
    double_literal: f64,
    string_literal: []const u8,
    bool_literal: bool,
    array_literal: struct {
        elements: []const *ASTNode,
    },
    map_literal: struct {
        elements: []const *ASTNode,
    },
    null_literal: void,
    
    // Identifiers
    identifier: struct {
        name: []const u8,
        resolved_c_name: ?[]const u8,
        is_class_property: bool = false,
        is_boxed: bool = false,
        /// True when the identifier must yield the box *pointer* (single deref
        /// of the boxed var's alloca) instead of the boxed *value* (double
        /// deref) — used for passing a shared mutable capture into a task ctor.
        is_box_ref: bool = false,
        owner_type_c_name: ?[]const u8 = null,
    },

    // Expressions
    unary_expr: struct {
        operator: TokenType,
        operand: *ASTNode,
    },
    binary_expr: struct {
        left: *ASTNode,
        op: TokenType,
        right: *ASTNode,
    },
    call_expr: struct {
        callee: *ASTNode,
        arguments: []const *ASTNode,
        type_args: []const *const ASTTypeRef = &.{},
        /// When `cFunctionPtr(fn)` is used, the C name of the generated
        /// trampoline for `fn`; the backend emits `&trampoline` instead of a call.
        c_fn_ptr: ?[]const u8 = null,
        /// True when this call targets a suspend function (marked by the
        /// coroutine detection pass). The emitter transforms the caller.
        is_suspend_call: bool = false,
    },
    named_arg: struct {
        name: []const u8,
        value: *ASTNode,
    },
    if_expr: struct {
        condition: *ASTNode,
        then_branch: *ASTNode,
        else_branch: ?*ASTNode,
    },
    index_expr: struct {
        object: *ASTNode,
        index: *ASTNode,
    },
    index_set_expr: struct {
        object: *ASTNode,
        index: *ASTNode,
        value: *ASTNode,
    },
    assignment: struct {
        name: []const u8,
        value: *ASTNode,
        is_boxed: bool = false,
        is_class_property: bool = false,
        owner_type_c_name: ?[]const u8 = null,
    },
    get_expr: struct {
        object: *ASTNode,
        name: []const u8,
        is_safe: bool,
        resolved_c_name: ?[]const u8 = null,
        /// True when the field holds a box pointer (captured mutable var) and
        /// reads must double-deref to reach the value (stackless task capture).
        is_boxed: bool = false,
    },
    set_expr: struct {
        object: *ASTNode,
        name: []const u8,
        value: *ASTNode,
        is_safe: bool,
        /// True when the field holds a box pointer (captured mutable var) and
        /// writes must store through the box (stackless task capture).
        is_boxed: bool = false,
    },
    block: struct {
        statements: []const *ASTNode,
    },
    while_stmt: struct {
        condition: *ASTNode,
        body: *ASTNode,
    },
    for_stmt: struct {
        index_name: ?[]const u8 = null,
        item_name: []const u8,
        iterable: *ASTNode,
        body: *ASTNode,
    },
    return_stmt: struct {
        value: ?*ASTNode,
    },
    ternary_expr: struct {
        condition: *ASTNode,
        then_branch: *ASTNode,
        else_branch: ?*ASTNode,
    },
    as_expr: struct {
        value: *ASTNode,
        type_ref: *const ASTTypeRef,
    },
    is_expr: struct {
        value: *ASTNode,
        type_ref: *const ASTTypeRef,
        is_not: bool,
    },
    try_stmt: struct {
        body: *ASTNode,
        catches: []const CatchBlock,
    },
    throw_stmt: struct {
        expr: *ASTNode,
    },
    is_type_cond: struct {
        type_ref: *const ASTTypeRef,
        is_not: bool,
    },
    when_expr: struct {
        subject: ?*ASTNode,
        cases: []const WhenCase,
    },
    lambda_expr: struct {
        params: []const Param,
        body: []const *ASTNode,
    },
};

test "ASTNode Tagged Union size check" {
    // A simple test to ensure the tagged union works properly
    try std.testing.expect(@sizeOf(ASTNodeType) > 0);
    
    const literal = ASTNodeType{ .int_literal = 42 };
    try std.testing.expect(literal.int_literal == 42);
    
    switch (literal) {
        .int_literal => |val| try std.testing.expect(val == 42),
        else => unreachable,
    }
}

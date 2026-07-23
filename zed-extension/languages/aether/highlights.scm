; Aether highlights — based on tree-sitter-kotlin grammar (Aether's syntax is Kotlin-inspired).
; Aether-specific keywords (from, lib, test, of) are not Kotlin grammar tokens,
; so they are matched as identifiers below.

; Identifiers
(simple_identifier) @variable

; `it` keyword inside lambdas
((simple_identifier) @variable.builtin
  (#eq? @variable.builtin "it"))

; `this` keyword inside classes
(this_expression) @variable.builtin

; `super` keyword inside classes
(super_expression) @variable.builtin

; Aether-specific declarations
(import_header
  "import" @include
  "from" @include)

(test_declaration
  "test" @keyword
  (string_literal) @string)

(lib_declaration
  "lib" @keyword)

; `of` operator (parses as Kotlin infix call)
(infix_expression
  (simple_identifier) @operator
  (#eq? @operator "of"))

(class_parameter
  (simple_identifier) @property)

(class_body
  (property_declaration
    (variable_declaration
      (simple_identifier) @property)))

; id_1.id_2.id_3: `id_2` and `id_3` are assumed as object properties
(_
  (navigation_suffix
    (simple_identifier) @property))

(enum_entry
  (simple_identifier) @constant)

(type_identifier) @type

((type_identifier) @type.builtin
  (#any-of? @type.builtin
    "Int" "Float" "Double" "Long" "Char" "Bool" "Boolean" "String" "Void"
    "Pointer" "OpaquePointer" "Array" "List" "Map" "Set"))

(label) @label

; Function definitions
(function_declaration
  (simple_identifier) @function)

(getter
  "get" @function.builtin)

(setter
  "set" @function.builtin)

(primary_constructor) @constructor

(secondary_constructor
  "constructor" @constructor)

(constructor_invocation
  (user_type
    (type_identifier) @constructor))

(anonymous_initializer
  "init" @constructor)

(parameter
  (simple_identifier) @parameter)

(parameter_with_optional_type
  (simple_identifier) @parameter)

; lambda parameters
(lambda_literal
  (lambda_parameters
    (variable_declaration
      (simple_identifier) @parameter)))

; Function calls
(call_expression
  (simple_identifier) @function)

(call_expression
  (navigation_expression
    (navigation_suffix
      (simple_identifier) @function)))

; Aether standard library builtins
(call_expression
  (simple_identifier) @function.builtin
  (#any-of? @function.builtin
    "print" "println" "error" "assert" "require" "repeat" "TODO"))

; Literals
[
  (line_comment)
  (multiline_comment)
  (shebang_line)
] @comment

(real_literal) @float

[
  (integer_literal)
  (long_literal)
  (hex_literal)
  (bin_literal)
  (unsigned_literal)
] @number

[
  (null_literal)
  (boolean_literal)
] @boolean

(character_literal) @character

(string_literal) @string

(character_escape_seq) @string.escape

; Keywords
[
  (class_modifier)
  (member_modifier)
  (function_modifier)
  (property_modifier)
  (parameter_modifier)
  (visibility_modifier)
  (inheritance_modifier)
] @keyword

[
  "if"
  "else"
  "when"
  "for"
  "while"
  "do"
  "try"
  "catch"
  "throw"
  "finally"
  "val"
  "var"
  "class"
  "object"
  "companion"
  "import"
] @keyword

((simple_identifier) @keyword
  (#any-of? @keyword "is" "!is" "in" "!in" "as" "as?"))

(function_declaration
  "fun" @keyword.function)

(jump_expression) @keyword.return

(annotation
  "@" @attribute
  (use_site_target)? @attribute)

(annotation
  (user_type
    (type_identifier) @attribute))

(annotation
  (constructor_invocation
    (user_type
      (type_identifier) @attribute)))

; Operators & Punctuation
[
  "!"
  "!="
  "!=="
  "="
  "=="
  "==="
  ">"
  ">="
  "<"
  "<="
  "||"
  "&&"
  "+"
  "++"
  "+="
  "-"
  "--"
  "-="
  "*"
  "*="
  "/"
  "/="
  "%"
  "%="
  "?."
  "?:"
  "?"
  "!!"
  ".."
  "->"
  "|"
] @operator

[
  "("
  ")"
  "["
  "]"
  "{"
  "}"
] @punctuation.bracket

[
  "."
  ","
  ";"
  ":"
  "::"
] @punctuation.delimiter

(interpolation_identifier_start) @punctuation.special
(interpolated_identifier) @none
(interpolation_expression_start) @punctuation.special
(interpolated_expression) @none
(interpolation_expression_end) @punctuation.special

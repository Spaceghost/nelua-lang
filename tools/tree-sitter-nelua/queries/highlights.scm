(comment) @comment
(preprocessor) @preproc
(preprocess_expression) @preproc
(preprocess_name) @preproc
(string) @string
(long_string) @string
(number) @number
(boolean) @boolean
(nil) @constant.builtin
(nilptr) @constant.builtin
(identifier) @variable
(annotation (identifier) @attribute)
(function_declaration name: (identifier) @function)
(call_expression (identifier) @function.call)
(type_field (identifier) @property)
["local" "global" "function" "end" "if" "then" "elseif" "else" "switch" "case" "for" "in" "do" "while" "repeat" "until" "defer" "return" "goto"] @keyword
[(break_statement) (continue_statement) (fallthrough_statement)] @keyword
["record" "union" "enum" "array" "pointer" "variant"] @type.builtin

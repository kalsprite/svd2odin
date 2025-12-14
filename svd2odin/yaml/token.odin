// YAML tokenizer token definitions
// Designed for StrictYAML subset - block style only, no anchors/tags/flow
package yaml

import "core:strings"

Token :: struct {
	kind: Token_Kind,
	text: string,
	pos:  Pos,
}

Pos :: struct {
	file:   string,
	offset: int, // starting at 0
	line:   int, // starting at 1
	column: int, // starting at 1
}

pos_compare :: proc(lhs, rhs: Pos) -> int {
	if lhs.offset != rhs.offset {
		return -1 if (lhs.offset < rhs.offset) else +1
	}
	if lhs.line != rhs.line {
		return -1 if (lhs.line < rhs.line) else +1
	}
	if lhs.column != rhs.column {
		return -1 if (lhs.column < rhs.column) else +1
	}
	return strings.compare(lhs.file, rhs.file)
}

// Token kinds for StrictYAML subset
// We only support block-style YAML with no anchors, tags, or flow syntax
Token_Kind :: enum u32 {
	Invalid,
	EOF,
	Comment,        // # comment

	// Block structure tokens
	Newline,        // \n (significant in YAML)
	Indent,         // Indentation increase
	Dedent,         // Indentation decrease

	// Punctuation
	Colon,          // : (key-value separator)
	Dash,           // - (sequence item marker)
	Pipe,           // | (literal block scalar)
	Greater,        // > (folded block scalar)

	// Values
	Scalar,         // Any scalar value (string, number, etc - parsed as string)

	// Optional: Quoted strings (if we want to distinguish them)
	String_Single,  // 'single quoted'
	String_Double,  // "double quoted"
	String_Literal, // | literal block
	String_Folded,  // > folded block
}

tokens := [Token_Kind]string {
	.Invalid        = "Invalid",
	.EOF            = "EOF",
	.Comment        = "Comment",
	.Newline        = "Newline",
	.Indent         = "Indent",
	.Dedent         = "Dedent",
	.Colon          = ":",
	.Dash           = "-",
	.Pipe           = "|",
	.Greater        = ">",
	.Scalar         = "Scalar",
	.String_Single  = "String",
	.String_Double  = "String",
	.String_Literal = "Literal",
	.String_Folded  = "Folded",
}

token_to_string :: proc(tok: Token) -> string {
	return to_string(tok.kind)
}

to_string :: proc(kind: Token_Kind) -> string {
	return tokens[kind]
}

is_literal :: proc(kind: Token_Kind) -> bool {
	#partial switch kind {
	case .Scalar, .String_Single, .String_Double, .String_Literal, .String_Folded:
		return true
	}
	return false
}

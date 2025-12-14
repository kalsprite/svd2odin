// YAML tokenizer for StrictYAML subset
package yaml

import "core:fmt"
import "core:unicode"
import "core:unicode/utf8"

Error_Handler :: #type proc(pos: Pos, fmt: string, args: ..any)

Tokenizer :: struct {
	// Immutable data
	path: string,
	src:  string,
	err:  Error_Handler,

	// Tokenizing state
	ch:          rune,
	offset:      int,
	read_offset: int,
	line_offset: int,
	line_count:  int,

	// YAML-specific state
	indent_stack: [dynamic]int,  // Stack of indentation levels
	current_indent: int,          // Current line's indentation
	at_line_start: bool,          // Are we at the start of a line?
	pending_dedents: int,         // Number of dedent tokens to emit

	// Mutable data
	error_count: int,
}

init :: proc(t: ^Tokenizer, src: string, path := "", err: Error_Handler = default_error_handler) {
	t.src = src
	t.err = err
	t.path = path
	t.ch = ' '
	t.offset = 0
	t.read_offset = 0
	t.line_offset = 0
	t.line_count = len(src) > 0 ? 1 : 0
	t.error_count = 0

	// YAML state
	t.indent_stack = make([dynamic]int, 0, 16)
	append(&t.indent_stack, 0)  // Base indentation level
	t.current_indent = 0
	t.at_line_start = true
	t.pending_dedents = 0

	advance_rune(t)
	if t.ch == utf8.RUNE_BOM {
		advance_rune(t)
	}
}

destroy :: proc(t: ^Tokenizer) {
	delete(t.indent_stack)
}

@(private)
offset_to_pos :: proc(t: ^Tokenizer, offset: int) -> Pos {
	line := t.line_count
	column := offset - t.line_offset + 1

	return Pos {
		file = t.path,
		offset = offset,
		line = line,
		column = column,
	}
}

default_error_handler :: proc(pos: Pos, msg: string, args: ..any) {
	fmt.eprintf("%s(%d:%d) ", pos.file, pos.line, pos.column)
	fmt.eprintf(msg, ..args)
	fmt.eprintf("\n")
}

error :: proc(t: ^Tokenizer, offset: int, msg: string, args: ..any) {
	pos := offset_to_pos(t, offset)
	if t.err != nil {
		t.err(pos, msg, ..args)
	}
	t.error_count += 1
}

advance_rune :: proc(t: ^Tokenizer) {
	if t.read_offset < len(t.src) {
		t.offset = t.read_offset
		if t.ch == '\n' {
			t.line_offset = t.offset
			t.line_count += 1
		}
		r, w := rune(t.src[t.read_offset]), 1
		switch {
		case r == 0:
			error(t, t.offset, "illegal character NUL")
		case r >= utf8.RUNE_SELF:
			r, w = utf8.decode_rune_in_string(t.src[t.read_offset:])
			if r == utf8.RUNE_ERROR && w == 1 {
				error(t, t.offset, "illegal UTF-8 encoding")
			} else if r == utf8.RUNE_BOM && t.offset > 0 {
				error(t, t.offset, "illegal byte order mark")
			}
		}
		t.read_offset += w
		t.ch = r
	} else {
		t.offset = len(t.src)
		if t.ch == '\n' {
			t.line_offset = t.offset
			t.line_count += 1
		}
		t.ch = -1
	}
}

peek_byte :: proc(t: ^Tokenizer, offset := 0) -> byte {
	if t.read_offset+offset < len(t.src) {
		return t.src[t.read_offset+offset]
	}
	return 0
}

peek_rune :: proc(t: ^Tokenizer) -> rune {
	if t.read_offset < len(t.src) {
		r, _ := utf8.decode_rune_in_string(t.src[t.read_offset:])
		return r
	}
	return -1
}

// Count spaces at current position (for indentation)
// Counts from the current offset (t.offset), where t.ch is located
count_spaces :: proc(t: ^Tokenizer) -> int {
	count := 0
	offset := t.offset
	for offset < len(t.src) {
		ch := t.src[offset]
		if ch == ' ' {
			count += 1
			offset += 1
		} else if ch == '\t' {
			// Tabs are not allowed in YAML indentation (strictyaml)
			error(t, offset, "tabs not allowed for indentation, use spaces")
			return -1
		} else {
			break
		}
	}
	return count
}

// Main tokenization function
scan :: proc(t: ^Tokenizer) -> Token {
	// Handle pending dedent tokens
	if t.pending_dedents > 0 {
		t.pending_dedents -= 1
		pos := offset_to_pos(t, t.offset)
		return Token{kind = .Dedent, text = "", pos = pos}
	}

	// Handle line start (check for indent/dedent)
	if t.at_line_start {
		t.at_line_start = false

		// Skip empty lines and lines with only whitespace
		for t.ch == '\n' || (t.ch == ' ' && peek_byte(t) == '\n') {
			if t.ch == '\n' {
				advance_rune(t)
			} else {
				for t.ch == ' ' {
					advance_rune(t)
				}
			}
		}

		// Check for EOF or comment line - don't process indentation
		if t.ch < 0 || t.ch == '#' {
			// Continue to regular processing
		} else {
			// Count indentation of this line
			indent := count_spaces(t)
			if indent < 0 {
				// Error already reported (tab character)
				return Token{kind = .Invalid, text = "", pos = offset_to_pos(t, t.offset)}
			}

			// Skip spaces
			for i := 0; i < indent; i += 1 {
				advance_rune(t)
			}

			current_level := t.indent_stack[len(t.indent_stack)-1]

			// Debug
			// fmt.printfln("DEBUG: indent=%d, current_level=%d, ch='%c' offset=%d", indent, current_level, t.ch, t.offset)

			if indent > current_level {
				// Indent
				append(&t.indent_stack, indent)
				pos := offset_to_pos(t, t.offset)
				return Token{kind = .Indent, text = "", pos = pos}
			} else if indent < current_level {
				// Dedent - pop stack until we find matching level
				dedent_count := 0
				for len(t.indent_stack) > 1 && t.indent_stack[len(t.indent_stack)-1] > indent {
					pop(&t.indent_stack)
					dedent_count += 1
				}

				// Check if indent level matches
				if t.indent_stack[len(t.indent_stack)-1] != indent {
					error(t, t.offset, "inconsistent indentation")
				}

				// Emit first dedent, queue the rest
				if dedent_count > 0 {
					t.pending_dedents = dedent_count - 1
					pos := offset_to_pos(t, t.offset)
					return Token{kind = .Dedent, text = "", pos = pos}
				}
			}
		}
	}

	// Skip spaces (not at line start)
	for t.ch == ' ' {
		advance_rune(t)
	}

	pos := offset_to_pos(t, t.offset)
	offset := t.offset

	// End of file
	if t.ch < 0 {
		// Emit remaining dedents
		if len(t.indent_stack) > 1 {
			pop(&t.indent_stack)
			t.pending_dedents = len(t.indent_stack) - 1
			return Token{kind = .Dedent, text = "", pos = pos}
		}
		return Token{kind = .EOF, text = "", pos = pos}
	}

	// Single-character tokens
	switch t.ch {
	case '\n':
		advance_rune(t)
		t.at_line_start = true
		return Token{kind = .Newline, text = "\n", pos = pos}

	case '#':
		return scan_comment(t)

	case ':':
		advance_rune(t)
		// Colon must be followed by space or newline in YAML
		if t.ch != ' ' && t.ch != '\n' && t.ch != '\r' && t.ch < 0 {
			error(t, t.offset, "colon must be followed by space or newline")
		}
		return Token{kind = .Colon, text = ":", pos = pos}

	case '-':
		// Could be list item or scalar starting with dash
		if peek_byte(t) == ' ' || peek_byte(t) == '\n' {
			advance_rune(t)
			return Token{kind = .Dash, text = "-", pos = pos}
		}
		// Otherwise it's part of a scalar
		return scan_scalar(t)

	case '\'':
		return scan_single_quoted(t)

	case '"':
		return scan_double_quoted(t)

	case '|':
		advance_rune(t)
		return Token{kind = .Pipe, text = "|", pos = pos}

	case '>':
		advance_rune(t)
		return Token{kind = .Greater, text = ">", pos = pos}
	}

	// Default: scan as scalar
	return scan_scalar(t)
}

scan_comment :: proc(t: ^Tokenizer) -> Token {
	pos := offset_to_pos(t, t.offset)
	offset := t.offset

	advance_rune(t) // skip '#'

	// Read until end of line
	for t.ch != '\n' && t.ch >= 0 {
		advance_rune(t)
	}

	return Token{kind = .Comment, text = t.src[offset:t.offset], pos = pos}
}

scan_scalar :: proc(t: ^Tokenizer) -> Token {
	pos := offset_to_pos(t, t.offset)
	offset := t.offset

	// Read until colon, newline, or comment
	for {
		if t.ch < 0 || t.ch == '\n' || t.ch == '#' {
			break
		}
		// Check for colon followed by space (key indicator)
		if t.ch == ':' && (peek_byte(t) == ' ' || peek_byte(t) == '\n' || peek_byte(t) == '\r') {
			break
		}
		advance_rune(t)
	}

	text := t.src[offset:t.offset]

	// Trim trailing whitespace
	for len(text) > 0 && text[len(text)-1] == ' ' {
		text = text[:len(text)-1]
	}

	return Token{kind = .Scalar, text = text, pos = pos}
}

scan_single_quoted :: proc(t: ^Tokenizer) -> Token {
	pos := offset_to_pos(t, t.offset)
	offset := t.offset

	advance_rune(t) // skip opening '

	for {
		if t.ch < 0 {
			error(t, t.offset, "unterminated single-quoted string")
			break
		}
		if t.ch == '\'' {
			advance_rune(t)
			// Check for escaped quote ''
			if t.ch == '\'' {
				advance_rune(t)
				continue
			}
			break
		}
		advance_rune(t)
	}

	return Token{kind = .String_Single, text = t.src[offset:t.offset], pos = pos}
}

scan_double_quoted :: proc(t: ^Tokenizer) -> Token {
	pos := offset_to_pos(t, t.offset)
	offset := t.offset

	advance_rune(t) // skip opening "

	for {
		if t.ch < 0 {
			error(t, t.offset, "unterminated double-quoted string")
			break
		}
		if t.ch == '"' {
			advance_rune(t)
			break
		}
		if t.ch == '\\' {
			advance_rune(t) // skip backslash
			advance_rune(t) // skip escaped character
			continue
		}
		advance_rune(t)
	}

	return Token{kind = .String_Double, text = t.src[offset:t.offset], pos = pos}
}

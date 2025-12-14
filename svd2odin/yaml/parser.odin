// YAML Parser for StrictYAML subset
package yaml

import "core:fmt"
import "core:mem"

Parser :: struct {
	tok: Tokenizer,
	err: Error_Handler,

	prev_tok: Token,
	curr_tok: Token,

	error_count: int,
	allocator: mem.Allocator,
}

parser_error :: proc(p: ^Parser, pos: Pos, msg: string, args: ..any) {
	if p.err != nil {
		p.err(pos, msg, ..args)
	}
	p.error_count += 1
}

// Initialize parser with source
init_parser :: proc(p: ^Parser, src: string, path := "", err: Error_Handler = default_error_handler, allocator := context.allocator) {
	p.err = err
	p.error_count = 0
	p.allocator = allocator
	init(&p.tok, src, path, err)

	// Prime the pump - get first token
	advance_token(p)
}

destroy_parser :: proc(p: ^Parser) {
	destroy(&p.tok)
}

// Advance to next token, skipping comments and newlines
advance_token :: proc(p: ^Parser) {
	p.prev_tok = p.curr_tok

	for {
		p.curr_tok = scan(&p.tok)

		// Skip comments - we don't preserve them in strictyaml
		if p.curr_tok.kind == .Comment {
			continue
		}

		break
	}
}

// Peek at current token kind
peek :: proc(p: ^Parser) -> Token_Kind {
	return p.curr_tok.kind
}

// Expect a specific token kind
expect_token :: proc(p: ^Parser, kind: Token_Kind) -> Token {
	if p.curr_tok.kind != kind {
		parser_error(p, p.curr_tok.pos, "expected %v, got %v", kind, p.curr_tok.kind)
		return Token{kind = .Invalid, pos = p.curr_tok.pos}
	}

	tok := p.curr_tok
	advance_token(p)
	return tok
}

// Skip newlines
skip_newlines :: proc(p: ^Parser) {
	for p.curr_tok.kind == .Newline {
		advance_token(p)
	}
}

// Main parsing entry point
parse :: proc(p: ^Parser) -> ^Document {
	skip_newlines(p)

	if p.curr_tok.kind == .EOF {
		// Empty document
		return make_document(nil, p.allocator)
	}

	root := parse_value(p)
	return make_document(root, p.allocator)
}

// Parse any value (Scalar, Mapping, or Sequence)
parse_value :: proc(p: ^Parser) -> ^Node {
	skip_newlines(p)

	#partial switch p.curr_tok.kind {
	case .Dash:
		// Sequence
		return parse_sequence(p)

	case .Scalar, .String_Single, .String_Double:
		// Could be a scalar, or the start of a mapping
		// Look ahead to see if there's a colon
		scalar_tok := p.curr_tok
		advance_token(p)

		if p.curr_tok.kind == .Colon {
			// It's a mapping - rewind and parse as mapping
			// We need to go back - let's handle this differently
			// For now, we'll parse mappings explicitly
			key := make_scalar(scalar_tok.text, scalar_tok, p.allocator)
			return parse_mapping_with_first_key(p, key)
		} else {
			// Just a scalar
			return make_scalar(scalar_tok.text, scalar_tok, p.allocator)
		}

	case .Indent:
		// Unexpected indent
		parser_error(p, p.curr_tok.pos, "unexpected indentation")
		advance_token(p)
		return parse_value(p)

	case .EOF:
		return nil
	}

	// Fallback for unhandled tokens
	return nil
}

// Parse a mapping (key: value pairs)
parse_mapping_with_first_key :: proc(p: ^Parser, first_key: ^Scalar) -> ^Node {
	mapping := make_mapping(p.allocator)
	mapping.pos = first_key.pos

	// Parse first pair (we already have the key)
	expect_token(p, .Colon)

	value := parse_inline_or_block_value(p)

	append(&mapping.pairs, Mapping_Pair{
		key = first_key,
		value = value,
		colon_pos = p.prev_tok.pos,
	})

	// Continue parsing more key-value pairs at the same indentation level
	in_indent_block := false
	for {
		skip_newlines(p)

		// If we see an Indent, enter the indented block and continue parsing pairs there
		if p.curr_tok.kind == .Indent {
			advance_token(p)
			in_indent_block = true
		}

		// Check if we're done (dedent or EOF)
		if p.curr_tok.kind == .Dedent || p.curr_tok.kind == .EOF {
			break
		}

		// Must be a scalar followed by colon
		if p.curr_tok.kind != .Scalar && p.curr_tok.kind != .String_Single && p.curr_tok.kind != .String_Double {
			break
		}

		key_tok := p.curr_tok
		advance_token(p)

		if p.curr_tok.kind != .Colon {
			// Not a mapping pair, we're done
			parser_error(p, p.curr_tok.pos, "expected colon after key")
			break
		}

		advance_token(p) // consume colon

		key := make_scalar(key_tok.text, key_tok, p.allocator)
		value := parse_inline_or_block_value(p)

		append(&mapping.pairs, Mapping_Pair{
			key = key,
			value = value,
			colon_pos = p.prev_tok.pos,
		})

		// If we entered an indent, we stay in the loop and parse more pairs at this level
		// until we see a dedent
	}

	// If we entered an indent block, consume the dedent
	if in_indent_block && p.curr_tok.kind == .Dedent {
		advance_token(p)
	}

	if len(mapping.pairs) > 0 {
		last_pair := mapping.pairs[len(mapping.pairs)-1]
		if last_pair.value != nil {
			mapping.end = last_pair.value.end
		}
	}

	return mapping
}

// Parse a value that appears after a colon (could be inline or on next line indented)
parse_inline_or_block_value :: proc(p: ^Parser) -> ^Node {
	skip_newlines(p)

	// Check if value is on same line or indented block
	if p.curr_tok.kind == .Indent {
		advance_token(p) // consume indent
		value := parse_value(p)
		expect_token(p, .Dedent)
		return value
	}

	// Inline value
	return parse_value(p)
}

// Parse a sequence (list with dashes)
parse_sequence :: proc(p: ^Parser) -> ^Node {
	seq := make_sequence(p.allocator)
	seq.pos = p.curr_tok.pos

	for p.curr_tok.kind == .Dash {
		dash_pos := p.curr_tok.pos
		advance_token(p) // consume dash

		value := parse_inline_or_block_value(p)

		append(&seq.items, Sequence_Item{
			value = value,
			dash_pos = dash_pos,
		})

		skip_newlines(p)

		// Check if there's more items or if we've dedented
		if p.curr_tok.kind == .Dedent || p.curr_tok.kind == .EOF {
			break
		}
	}

	if len(seq.items) > 0 {
		last_item := seq.items[len(seq.items)-1]
		if last_item.value != nil {
			seq.end = last_item.value.end
		}
	}

	return seq
}

// Parse a complete YAML document from source
parse_string :: proc(src: string, path := "", allocator := context.allocator) -> (doc: ^Document, ok: bool) {
	parser: Parser
	init_parser(&parser, src, path, allocator = allocator)
	defer destroy_parser(&parser)

	doc = parse(&parser)
	ok = parser.error_count == 0

	return doc, ok
}

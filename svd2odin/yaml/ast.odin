// YAML Abstract Syntax Tree
package yaml

// Base node for all YAML AST nodes
Node :: struct {
	pos: Pos,
	end: Pos,
	derived: Any_Node,
}

// All possible YAML node types (for strictyaml subset)
Any_Node :: union {
	^Document,
	^Scalar,
	^Mapping,
	^Sequence,
}

// Document is the root of a YAML file
Document :: struct {
	using node: Node,
	root: ^Node, // The root node (can be Scalar, Mapping, or Sequence)
}

// Scalar represents a simple value (always stored as string in strictyaml)
Scalar :: struct {
	using node: Node,
	value: string,
	tok: Token, // The original token
}

// Mapping represents key-value pairs (YAML map/dict)
Mapping :: struct {
	using node: Node,
	pairs: [dynamic]Mapping_Pair,
}

Mapping_Pair :: struct {
	key: ^Scalar,   // Keys are always scalars in YAML
	value: ^Node,   // Value can be Scalar, Mapping, or Sequence
	colon_pos: Pos, // Position of the colon
}

// Sequence represents a list (YAML array)
Sequence :: struct {
	using node: Node,
	items: [dynamic]Sequence_Item,
}

Sequence_Item :: struct {
	value: ^Node,  // Can be Scalar, Mapping, or Sequence
	dash_pos: Pos, // Position of the dash
}

// Helpers for creating nodes

make_scalar :: proc(value: string, tok: Token, allocator := context.allocator) -> ^Scalar {
	s := new(Scalar, allocator)
	s.value = value
	s.tok = tok
	s.pos = tok.pos
	s.end = tok.pos
	s.end.column += len(tok.text)
	s.derived = s
	return s
}

make_mapping :: proc(allocator := context.allocator) -> ^Mapping {
	m := new(Mapping, allocator)
	m.pairs = make([dynamic]Mapping_Pair, allocator)
	m.derived = m
	return m
}

make_sequence :: proc(allocator := context.allocator) -> ^Sequence {
	s := new(Sequence, allocator)
	s.items = make([dynamic]Sequence_Item, allocator)
	s.derived = s
	return s
}

make_document :: proc(root: ^Node, allocator := context.allocator) -> ^Document {
	d := new(Document, allocator)
	d.root = root
	d.derived = d
	if root != nil {
		d.pos = root.pos
		d.end = root.end
	}
	return d
}

// Cleanup procedures

destroy_node :: proc(n: ^Node, allocator := context.allocator) {
	if n == nil {
		return
	}

	switch v in n.derived {
	case ^Document:
		destroy_node(v.root, allocator)
		free(v, allocator)

	case ^Scalar:
		free(v, allocator)

	case ^Mapping:
		for pair in v.pairs {
			destroy_node(pair.key, allocator)
			destroy_node(pair.value, allocator)
		}
		delete(v.pairs)
		free(v, allocator)

	case ^Sequence:
		for item in v.items {
			destroy_node(item.value, allocator)
		}
		delete(v.items)
		free(v, allocator)
	}
}

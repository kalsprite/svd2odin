package yaml_test

import "core:fmt"
import "core:testing"
import yaml "../"

@(test)
test_parse_scalar :: proc(t: ^testing.T) {
	src := "hello"
	doc, ok := yaml.parse_string(src, "test.yaml")
	defer yaml.destroy_node(doc)

	testing.expect(t, ok, "parse should succeed")
	testing.expect(t, doc.root != nil, "root should not be nil")

	scalar, is_scalar := doc.root.derived.(^Scalar)
	testing.expect(t, is_scalar, "root should be scalar")
	if is_scalar {
		testing.expect(t, scalar.value == "hello", "value should be 'hello'")
	}
}

@(test)
test_parse_simple_mapping :: proc(t: ^testing.T) {
	src := `key: value`
	doc, ok := yaml.parse_string(src, "test.yaml")
	defer yaml.destroy_node(doc)

	testing.expect(t, ok, "parse should succeed")

	mapping, is_mapping := doc.root.derived.(^Mapping)
	testing.expect(t, is_mapping, "root should be mapping")
	if is_mapping {
		testing.expect(t, len(mapping.pairs) == 1, "should have 1 pair")
		if len(mapping.pairs) > 0 {
			testing.expect(t, mapping.pairs[0].key.value == "key", "key should be 'key'")

			value_scalar, is_scalar := mapping.pairs[0].value.derived.(^Scalar)
			testing.expect(t, is_scalar, "value should be scalar")
			if is_scalar {
				testing.expect(t, value_scalar.value == "value", "value should be 'value'")
			}
		}
	}
}

@(test)
test_parse_multiple_pairs :: proc(t: ^testing.T) {
	src := `name: John
age: 30
city: Boston`

	doc, ok := yaml.parse_string(src, "test.yaml")
	defer yaml.destroy_node(doc)

	testing.expect(t, ok, "parse should succeed")

	mapping, is_mapping := doc.root.derived.(^Mapping)
	testing.expect(t, is_mapping, "root should be mapping")
	if is_mapping {
		testing.expect(t, len(mapping.pairs) == 3, "should have 3 pairs")
	}
}

@(test)
test_parse_simple_sequence :: proc(t: ^testing.T) {
	src := `- item1
- item2
- item3`

	doc, ok := yaml.parse_string(src, "test.yaml")
	defer yaml.destroy_node(doc)

	testing.expect(t, ok, "parse should succeed")

	seq, is_seq := doc.root.derived.(^Sequence)
	testing.expect(t, is_seq, "root should be sequence")
	if is_seq {
		testing.expect(t, len(seq.items) == 3, "should have 3 items")
	}
}

@(test)
test_parse_nested_mapping :: proc(t: ^testing.T) {
	src := `parent:
  child: value`

	doc, ok := yaml.parse_string(src, "test.yaml")
	defer yaml.destroy_node(doc)

	testing.expect(t, ok, "parse should succeed")

	mapping, is_mapping := doc.root.derived.(^Mapping)
	testing.expect(t, is_mapping, "root should be mapping")
	if is_mapping {
		testing.expect(t, len(mapping.pairs) == 1, "should have 1 pair")
		if len(mapping.pairs) > 0 {
			testing.expect(t, mapping.pairs[0].key.value == "parent", "key should be 'parent'")

			// Check nested mapping
			nested_mapping, is_nested := mapping.pairs[0].value.derived.(^Mapping)
			testing.expect(t, is_nested, "value should be mapping")
			if is_nested {
				testing.expect(t, len(nested_mapping.pairs) == 1, "nested should have 1 pair")
			}
		}
	}
}

@(test)
test_parse_sequence_of_mappings :: proc(t: ^testing.T) {
	src := `- name: Alice
  age: 30
- name: Bob
  age: 25`

	doc, ok := yaml.parse_string(src, "test.yaml")
	defer yaml.destroy_node(doc)

	testing.expect(t, ok, "parse should succeed")

	seq, is_seq := doc.root.derived.(^Sequence)
	testing.expect(t, is_seq, "root should be sequence")
	if is_seq {
		testing.expect(t, len(seq.items) == 2, "should have 2 items")

		// Check first item is a mapping
		if len(seq.items) > 0 {
			first_mapping, is_mapping := seq.items[0].value.derived.(^Mapping)
			testing.expect(t, is_mapping, "first item should be mapping")
			if is_mapping {
				testing.expect(t, len(first_mapping.pairs) == 2, "first mapping should have 2 pairs")
			}
		}
	}
}

// Manual test for debugging
parser_main :: proc() {
	test_config :: proc() {
		src := `# STM32F303 Configuration
name: stm32f3discovery
memory:
  flash_origin: 0x08000000
  flash_size: 256K
  ram_origin: 0x20000000
  ram_size: 40K
leds:
  - name: LED_N
    gpio: GPIOE
    pin: 9
  - name: LED_NE
    gpio: GPIOE
    pin: 10`

		fmt.println("=== Parsing YAML ===")
		doc, ok := yaml.parse_string(src, "config.yaml")
		if !ok {
			fmt.println("Parse failed!")
			return
		}
		defer yaml.destroy_node(doc)

		fmt.println("Parse succeeded!")
		print_node(doc.root, 0)
	}

	test_simple :: proc() {
		src := `key: value
name: test`

		fmt.println("\n=== Simple Test ===")
		doc, ok := yaml.parse_string(src)
		if !ok {
			fmt.println("Parse failed!")
			return
		}
		defer yaml.destroy_node(doc)

		fmt.println("Parse succeeded!")
		print_node(doc.root, 0)
	}

	test_config()
	test_simple()
}

// Helper to print AST
print_node :: proc(n: ^Node, indent: int) {
	if n == nil {
		return
	}

	print_indent :: proc(level: int) {
		for i in 0..<level {
			fmt.print("  ")
		}
	}

	switch v in n.derived {
	case ^Document:
		print_indent(indent)
		fmt.println("Document:")
		print_node(v.root, indent + 1)

	case ^Scalar:
		print_indent(indent)
		fmt.printfln("Scalar: '%s'", v.value)

	case ^Mapping:
		print_indent(indent)
		fmt.printfln("Mapping (%d pairs):", len(v.pairs))
		for pair in v.pairs {
			print_indent(indent + 1)
			fmt.printf("Key: ")
			print_node(pair.key, 0)
			print_indent(indent + 1)
			fmt.println("Value:")
			print_node(pair.value, indent + 2)
		}

	case ^Sequence:
		print_indent(indent)
		fmt.printfln("Sequence (%d items):", len(v.items))
		for item in v.items {
			print_node(item.value, indent + 1)
		}
	}
}

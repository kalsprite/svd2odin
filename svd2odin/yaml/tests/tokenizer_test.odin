package yaml_test

import "core:fmt"
import "core:testing"
import yaml "../"

@(test)
test_basic_tokens :: proc(t: ^testing.T) {
	src := "key: value"
	tokenizer: yaml.Tokenizer
	yaml.init(&tokenizer, src, "test.yaml")
	defer yaml.destroy(&tokenizer)

	tokens: [dynamic]yaml.Token
	defer delete(tokens)

	for {
		tok := yaml.scan(&tokenizer)
		append(&tokens, tok)
		if tok.kind == .EOF {
			break
		}
	}

	testing.expect(t, len(tokens) >= 3, "expected at least 3 tokens")
	testing.expect(t, tokens[0].kind == .Scalar, "expected scalar")
	testing.expect(t, tokens[0].text == "key", "expected 'key'")
	testing.expect(t, tokens[1].kind == .Colon, "expected colon")
	testing.expect(t, tokens[2].kind == .Scalar, "expected scalar")
	testing.expect(t, tokens[2].text == "value", "expected 'value'")
}

@(test)
test_list :: proc(t: ^testing.T) {
	src := `- item1
- item2`

	tokenizer: yaml.Tokenizer
	yaml.init(&tokenizer, src, "test.yaml")
	defer yaml.destroy(&tokenizer)

	tokens: [dynamic]yaml.Token
	defer delete(tokens)

	for {
		tok := yaml.scan(&tokenizer)
		append(&tokens, tok)
		if tok.kind == .EOF {
			break
		}
	}

	// Should have: Dash, Scalar, Newline, Dash, Scalar, EOF
	expected_kinds := []Token_Kind{.Dash, .Scalar, .Newline, .Dash, .Scalar, .EOF}

	for kind, i in expected_kinds {
		testing.expectf(t, i < len(tokens), "missing token at index %d", i)
		if i < len(tokens) {
			testing.expectf(t, tokens[i].kind == kind,
				"token %d: expected %v, got %v", i, kind, tokens[i].kind)
		}
	}
}

@(test)
test_indentation :: proc(t: ^testing.T) {
	src := `parent:
  child: value
  child2: value2`

	tokenizer: yaml.Tokenizer
	yaml.init(&tokenizer, src, "test.yaml")
	defer yaml.destroy(&tokenizer)

	tokens: [dynamic]yaml.Token
	defer delete(tokens)

	for {
		tok := scan(&tokenizer)
		append(&tokens, tok)
		fmt.printfln("Token: %v '%s'", tok.kind, tok.text)
		if tok.kind == .EOF {
			break
		}
	}

	// Verify we got indent and dedent tokens
	has_indent := false
	has_dedent := false

	for tok in tokens {
		if tok.kind == .Indent {
			has_indent = true
		}
		if tok.kind == .Dedent {
			has_dedent = true
		}
	}

	testing.expect(t, has_indent, "expected indent token")
	testing.expect(t, has_dedent, "expected dedent token")
}

@(test)
test_comment :: proc(t: ^testing.T) {
	src := `# This is a comment
key: value  # inline comment`

	tokenizer: yaml.Tokenizer
	yaml.init(&tokenizer, src, "test.yaml")
	defer yaml.destroy(&tokenizer)

	tokens: [dynamic]yaml.Token
	defer delete(tokens)

	for {
		tok := yaml.scan(&tokenizer)
		append(&tokens, tok)
		if tok.kind == .EOF {
			break
		}
	}

	has_comment := false
	for tok in tokens {
		if tok.kind == .Comment {
			has_comment = true
		}
	}

	testing.expect(t, has_comment, "expected comment token")
}

@(test)
test_quoted_strings :: proc(t: ^testing.T) {
	src := `single: 'hello world'
double: "hello world"`

	tokenizer: yaml.Tokenizer
	yaml.init(&tokenizer, src, "test.yaml")
	defer yaml.destroy(&tokenizer)

	tokens: [dynamic]yaml.Token
	defer delete(tokens)

	for {
		tok := yaml.scan(&tokenizer)
		append(&tokens, tok)
		if tok.kind == .EOF {
			break
		}
	}

	has_single := false
	has_double := false

	for tok in tokens {
		if tok.kind == .String_Single {
			has_single = true
		}
		if tok.kind == .String_Double {
			has_double = true
		}
	}

	testing.expect(t, has_single, "expected single-quoted string")
	testing.expect(t, has_double, "expected double-quoted string")
}

// Manual test for debugging
tokenizer_main :: proc() {
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
    pin: 9`

	tokenizer: yaml.Tokenizer
	yaml.init(&tokenizer, src, "config.yaml")
	defer yaml.destroy(&tokenizer)

	fmt.println("=== YAML Tokenizer Test ===")
	for {
		tok := yaml.scan(&tokenizer)
		fmt.printfln("%v: '%s' (line %d, col %d)",
			tok.kind, tok.text, tok.pos.line, tok.pos.column)

		if tok.kind == .EOF || tok.kind == .Invalid {
			break
		}
	}

	if tokenizer.error_count > 0 {
		fmt.printfln("\nErrors: %d", tokenizer.error_count)
	}
}

#+feature dynamic-literals
package yaml_test

import "core:fmt"
import "core:strings"
import "core:testing"
import yaml "../"

@(test)
test_marshal_simple_types :: proc(t: ^testing.T) {
	// Test integer
	{
		i := 42
		val, err := yaml.marshal(i)
		testing.expect(t, err == nil, "marshal int should succeed")
		testing.expect(t, val == "42", "expected '42'")
	}

	// Test string
	{
		s := "hello"
		val, err := yaml.marshal(s)
		testing.expect(t, err == nil, "marshal string should succeed")
		testing.expect(t, val == "hello", "expected 'hello'")
	}

	// Test bool
	{
		b := true
		val, err := yaml.marshal(b)
		testing.expect(t, err == nil, "marshal bool should succeed")
		testing.expect(t, val == "true", "expected 'true'")
	}
}

@(test)
test_marshal_struct :: proc(t: ^testing.T) {
	Person :: struct {
		name: string,
		age:  int,
	}

	person := Person{name = "Alice", age = 30}
	val, err := yaml.marshal(person)

	testing.expect(t, err == nil, "marshal should succeed")
	fmt.println("Marshal struct output:")
	fmt.println(val)

	// Check that output contains expected fields
	testing.expect(t, strings.contains(val, "name: Alice"), "should contain name")
	testing.expect(t, strings.contains(val, "age: 30"), "should contain age")
}

@(test)
test_marshal_struct_with_tags :: proc(t: ^testing.T) {
	Config :: struct {
		flash_address: u32 `yaml:"flash_origin"`,
		ram_address:   u32 `yaml:"ram_origin"`,
		board_name:    string `yaml:"name"`,
		skip_me:       int `yaml:"-"`,
	}

	config := Config{
		flash_address = 0x08000000,
		ram_address   = 0x20000000,
		board_name    = "stm32f3",
		skip_me       = 999,
	}

	val, err := yaml.marshal(config)

	testing.expect(t, err == nil, "marshal should succeed")
	fmt.println("Marshal with tags output:")
	fmt.println(val)

	// Should use tag names
	testing.expect(t, strings.contains(val, "flash_origin:"), "should use tag name 'flash_origin'")
	testing.expect(t, strings.contains(val, "ram_origin:"), "should use tag name 'ram_origin'")
	testing.expect(t, strings.contains(val, "name:"), "should use tag name 'name'")

	// Should NOT contain field with tag "-"
	testing.expect(t, !strings.contains(val, "skip_me"), "should skip field with tag '-'")
	testing.expect(t, !strings.contains(val, "999"), "should skip field value")
}

@(test)
test_marshal_nested_struct :: proc(t: ^testing.T) {
	Address :: struct {
		street: string,
		city:   string,
	}

	Person :: struct {
		name:    string,
		address: Address,
	}

	person := Person{
		name = "Bob",
		address = Address{street = "Main St", city = "Boston"},
	}

	val, err := yaml.marshal(person)

	testing.expect(t, err == nil, "marshal should succeed")
	fmt.println("Marshal nested struct output:")
	fmt.println(val)

	testing.expect(t, strings.contains(val, "name: Bob"), "should contain name")
	testing.expect(t, strings.contains(val, "address:"), "should contain address field")
	testing.expect(t, strings.contains(val, "street: Main St"), "should contain nested street")
}

@(test)
test_marshal_array :: proc(t: ^testing.T) {
	items := [dynamic]string{"apple", "banana", "cherry"}
	defer delete(items)

	val, err := yaml.marshal(items)

	testing.expect(t, err == nil, "marshal should succeed")
	fmt.println("Marshal array output:")
	fmt.println(val)

	testing.expect(t, strings.contains(val, "- apple"), "should contain apple")
	testing.expect(t, strings.contains(val, "- banana"), "should contain banana")
	testing.expect(t, strings.contains(val, "- cherry"), "should contain cherry")
}

@(test)
test_marshal_array_of_structs :: proc(t: ^testing.T) {
	LED :: struct {
		name: string,
		pin:  int,
	}

	leds := [dynamic]LED{
		{name = "LED_N", pin = 9},
		{name = "LED_E", pin = 11},
	}
	defer delete(leds)

	val, err := yaml.marshal(leds)

	testing.expect(t, err == nil, "marshal should succeed")
	fmt.println("Marshal array of structs output:")
	fmt.println(val)

	testing.expect(t, strings.contains(val, "- "), "should have list markers")
	testing.expect(t, strings.contains(val, "name: LED_N"), "should contain first LED")
	testing.expect(t, strings.contains(val, "pin: 9"), "should contain first pin")
}

@(test)
test_marshal_round_trip :: proc(t: ^testing.T) {
	Person :: struct {
		name: string,
		age:  int,
	}

	original := Person{name = "Charlie", age = 25}

	// yaml.Marshal
	val, yaml.marshal_err := yaml.marshal(original)
	testing.expect(t, yaml.marshal_err == nil, "marshal should succeed")
	fmt.println("Round trip YAML:")
	fmt.println(val)

	// Unmarshal
	restored: Person
	unmarshal_err := unmarshal(val, &restored)
	testing.expect(t, unmarshal_err == nil, "unmarshal should succeed")

	// Compare
	testing.expect(t, restored.name == original.name, "name should match")
	testing.expect(t, restored.age == original.age, "age should match")
}

// Manual test
marshal_main :: proc() {
	fmt.println("=== YAML yaml.Marshal Tests ===\n")

	// Test 1: Simple struct with tags
	{
		Board :: struct {
			flash_address: u32 `yaml:"flash_origin"`,
			flash_amount:  string `yaml:"flash_size"`,
			name:          string,
		}

		board := Board{
			flash_address = 0x08000000,
			flash_amount  = "256K",
			name          = "stm32f3discovery",
		}

		val, err := yaml.marshal(board)
		fmt.println("Test 1: Struct with tags")
		fmt.printfln("Error: %v", err)
		fmt.println(val)
		fmt.println()
	}

	// Test 2: Array of structs
	{
		LED :: struct {
			name: string,
			gpio: string `yaml:"port"`,
			pin:  int,
		}

		leds := [dynamic]LED{
			{name = "LED_N", gpio = "GPIOE", pin = 9},
			{name = "LED_E", gpio = "GPIOE", pin = 11},
		}
		defer delete(leds)

		val, err := yaml.marshal(leds)
		fmt.println("Test 2: Array of structs with tags")
		fmt.printfln("Error: %v", err)
		fmt.println(val)
		fmt.println()
	}

	// Test 3: Full config
	{
		LED :: struct {
			name: string,
			desc: string `yaml:"description"`,
			gpio: string,
			pin:  int,
		}

		Memory :: struct {
			flash_origin: u32,
			flash_size:   string,
		}

		Board :: struct {
			name:   string,
			memory: Memory,
			leds:   [dynamic]LED,
		}

		board := Board{
			name = "stm32f3discovery",
			memory = Memory{
				flash_origin = 0x08000000,
				flash_size   = "256K",
			},
			leds = {
				{name = "LED_N", desc = "Blue - North", gpio = "GPIOE", pin = 9},
				{name = "LED_E", desc = "Orange - East", gpio = "GPIOE", pin = 11},
			},
		}
		defer delete(board.leds)

		val, err := yaml.marshal(board)
		fmt.println("Test 3: Full board config")
		fmt.printfln("Error: %v", err)
		fmt.println(val)
	}
}

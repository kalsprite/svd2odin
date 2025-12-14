package yaml_test

import "core:fmt"
import "core:testing"
import yaml "../"

// Test structures matching STM32 config format

LED_Config :: struct {
	name:        string,
	description: string,
	gpio:        string,
	pin:         int,
}

Button_Config :: struct {
	name:        string,
	gpio:        string,
	pin:         int,
	pull:        string,
	active_high: bool,
}

Memory_Config :: struct {
	flash_origin: u32,
	flash_size:   string,
	ram_origin:   u32,
	ram_size:     string,
}

Board_Config :: struct {
	name:   string,
	memory: Memory_Config,
	leds:   [dynamic]LED_Config,
}

@(test)
test_unmarshal_simple_struct :: proc(t: ^testing.T) {
	Person :: struct {
		name: string,
		age:  int,
	}

	src := `name: Alice
age: 30`

	person: Person
	err := yaml.unmarshal(src, &person)

	testing.expect(t, err == .None, "unmarshal should succeed")
	testing.expect(t, person.name == "Alice", "name should be Alice")
	testing.expect(t, person.age == 30, "age should be 30")
}

@(test)
test_unmarshal_nested_struct :: proc(t: ^testing.T) {
	Address :: struct {
		street: string,
		city:   string,
	}

	Person :: struct {
		name:    string,
		address: Address,
	}

	src := `name: Bob
address:
  street: Main St
  city: Boston`

	person: Person
	err := yaml.unmarshal(src, &person)

	testing.expect(t, err == .None, "unmarshal should succeed")
	testing.expect(t, person.name == "Bob", "name should be Bob")
	testing.expect(t, person.address.city == "Boston", "city should be Boston")
}

@(test)
test_unmarshal_sequence :: proc(t: ^testing.T) {
	Config :: struct {
		items: [dynamic]string,
	}

	src := `items:
  - apple
  - banana
  - cherry`

	config: Config
	defer delete(config.items)

	err := yaml.unmarshal(src, &config)

	testing.expect(t, err == .None, "unmarshal should succeed")
	testing.expect(t, len(config.items) == 3, "should have 3 items")
	if len(config.items) >= 3 {
		testing.expect(t, config.items[0] == "apple", "first item should be apple")
		testing.expect(t, config.items[1] == "banana", "second item should be banana")
	}
}

@(test)
test_unmarshal_sequence_of_structs :: proc(t: ^testing.T) {
	Person :: struct {
		name: string,
		age:  int,
	}

	Config :: struct {
		people: [dynamic]Person,
	}

	src := `people:
  - name: Alice
    age: 30
  - name: Bob
    age: 25`

	config: Config
	defer delete(config.people)

	err := yaml.unmarshal(src, &config)

	testing.expect(t, err == .None, "unmarshal should succeed")
	testing.expect(t, len(config.people) == 2, "should have 2 people")
	if len(config.people) >= 2 {
		testing.expect(t, config.people[0].name == "Alice", "first person name")
		testing.expect(t, config.people[0].age == 30, "first person age")
		testing.expect(t, config.people[1].name == "Bob", "second person name")
	}
}

@(test)
test_unmarshal_stm32_config :: proc(t: ^testing.T) {
	src := `name: stm32f3discovery
memory:
  flash_origin: 0x08000000
  flash_size: 256K
  ram_origin: 0x20000000
  ram_size: 40K
leds:
  - name: LED_N
    description: Blue - North
    gpio: GPIOE
    pin: 9
  - name: LED_NE
    description: Red - North-East
    gpio: GPIOE
    pin: 10`

	config: Board_Config
	defer delete(config.leds)

	err := yaml.unmarshal(src, &config)

	testing.expect(t, err == .None, "unmarshal should succeed")
	testing.expect(t, config.name == "stm32f3discovery", "board name")
	testing.expect(t, config.memory.flash_origin == 0x08000000, "flash origin")
	testing.expect(t, config.memory.flash_size == "256K", "flash size")
	testing.expect(t, len(config.leds) == 2, "should have 2 LEDs")

	if len(config.leds) >= 2 {
		testing.expect(t, config.leds[0].name == "LED_N", "first LED name")
		testing.expect(t, config.leds[0].pin == 9, "first LED pin")
		testing.expect(t, config.leds[1].name == "LED_NE", "second LED name")
	}
}

// Manual test
unmarshal_main :: proc() {
	fmt.println("=== Testing YAML Unmarshalling ===\n")

	// Test 1: Simple struct
	{
		Person :: struct {
			name: string,
			age:  int,
		}

		src := `name: Alice
age: 30`

		person: Person
		err := yaml.unmarshal(src, &person)

		fmt.println("Test 1: Simple struct")
		fmt.printfln("  Error: %v", err)
		fmt.printfln("  Name: %s, Age: %d\n", person.name, person.age)
	}

	// Test 2: Sequence of structs
	{
		LED_Config :: struct {
			name: string,
			gpio: string,
			pin:  int,
		}

		Config :: struct {
			leds: [dynamic]LED_Config,
		}

		src := `leds:
  - name: LED_N
    gpio: GPIOE
    pin: 9
  - name: LED_NE
    gpio: GPIOE
    pin: 10`

		config: Config
		defer delete(config.leds)

		err := yaml.unmarshal(src, &config)

		fmt.println("Test 2: Sequence of structs")
		fmt.printfln("  Error: %v", err)
		fmt.printfln("  LEDs: %d", len(config.leds))
		for led, i in config.leds {
			fmt.printfln("    [%d] %s: %s pin %d", i, led.name, led.gpio, led.pin)
		}
		fmt.println()
	}

	// Test 3: Full STM32 config
	{
		src := `name: stm32f3discovery
memory:
  flash_origin: 0x08000000
  flash_size: 256K
  ram_origin: 0x20000000
  ram_size: 40K
leds:
  - name: LED_N
    description: Blue - North
    gpio: GPIOE
    pin: 9
  - name: LED_NE
    description: Red - North-East
    gpio: GPIOE
    pin: 10`

		config: Board_Config
		defer delete(config.leds)

		err := yaml.unmarshal(src, &config)

		fmt.println("Test 3: Full STM32 Config")
		fmt.printfln("  Error: %v", err)
		fmt.printfln("  Board: %s", config.name)
		fmt.printfln("  Flash: 0x%X (%s)", config.memory.flash_origin, config.memory.flash_size)
		fmt.printfln("  RAM: 0x%X (%s)", config.memory.ram_origin, config.memory.ram_size)
		fmt.printfln("  LEDs: %d", len(config.leds))
		for led in config.leds {
			fmt.printfln("    - %s: %s (pin %d)", led.name, led.description, led.pin)
		}
	}
}

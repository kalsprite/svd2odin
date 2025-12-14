package yaml

import "core:fmt"

// Example: Using YAML unmarshalling for STM32 board configuration

main :: proc() {
	// Define your config structure
	LED :: struct {
		name:        string,
		description: string,
		gpio:        string,
		pin:         int,
	}

	Memory :: struct {
		flash_origin: u32,
		flash_size:   string,
		ram_origin:   u32,
		ram_size:     string,
	}

	Board_Config :: struct {
		name:   string,
		memory: Memory,
		leds:   [dynamic]LED,
	}

	// YAML config (could be loaded from file)
	yaml_config := `name: stm32f3discovery
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
    pin: 10
  - name: LED_E
    description: Orange - East
    gpio: GPIOE
    pin: 11`

	// Unmarshal into struct
	config: Board_Config
	defer delete(config.leds)

	err := unmarshal(yaml_config, &config)
	if err != .None {
		fmt.printfln("Error: %v", err)
		return
	}

	// Use the config
	fmt.printfln("Board: %s", config.name)
	fmt.printfln("Flash: 0x%08X (%s)", config.memory.flash_origin, config.memory.flash_size)
	fmt.printfln("RAM:   0x%08X (%s)", config.memory.ram_origin, config.memory.ram_size)
	fmt.printfln("\nLEDs: %d configured", len(config.leds))
	for led in config.leds {
		fmt.printfln("  - %-6s on %s pin %d (%s)",
			led.name, led.gpio, led.pin, led.description)
	}

}

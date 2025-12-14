package svd2odin

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// GPIO register constants (used in generated code)
GPIO_MODE_MASK     :: "0x3"  // 2-bit mask for MODER
GPIO_MODE_INPUT    :: "0x0"  // 00 = Input
GPIO_MODE_OUTPUT   :: "0x1"  // 01 = Output
GPIO_MODE_AF       :: "0x2"  // 10 = Alternate function
GPIO_MODE_ANALOG   :: "0x3"  // 11 = Analog

GPIO_PUPD_MASK     :: "0x3"  // 2-bit mask for PUPDR
GPIO_PUPD_NONE     :: "0x0"  // 00 = No pull
GPIO_PUPD_UP       :: "0x1"  // 01 = Pull-up
GPIO_PUPD_DOWN     :: "0x2"  // 10 = Pull-down

GPIO_AF_MASK       :: "0xF"  // 4-bit mask for AFR
GPIO_AFR_PIN_THRESHOLD :: 8  // Pins >= 8 use AFRH, < 8 use AFRL

// Helper: Write GPIO alternate function configuration to string builder
// Generates code to configure a pin as alternate function with specified AF number
write_gpio_af_config :: proc(b: ^strings.Builder, port: string, pin: int, af: int, signal_name: string) {
    fmt.sbprintfln(b, "    // Configure %s%d (%s) as AF%d", port, pin, signal_name, af)
    fmt.sbprintfln(b, "    hal.reg_modify(&device.%s.MODER, .Clear, %s << (%d * 2))", port, GPIO_MODE_MASK, pin)
    fmt.sbprintfln(b, "    hal.reg_modify(&device.%s.MODER, .Set, %s << (%d * 2))", port, GPIO_MODE_AF, pin)

    af_reg := "AFRL"
    af_pin := pin
    if pin >= GPIO_AFR_PIN_THRESHOLD {
        af_reg = "AFRH"
        af_pin = pin - GPIO_AFR_PIN_THRESHOLD
    }
    fmt.sbprintfln(b, "    hal.reg_modify(&device.%s.%s, .Clear, %s << (%d * 4))", port, af_reg, GPIO_AF_MASK, af_pin)
    fmt.sbprintfln(b, "    hal.reg_modify(&device.%s.%s, .Set, %d << (%d * 4))", port, af_reg, af, af_pin)
    fmt.sbprintln(b, "")
}

// Helper: Check if any peripheral with given interface exists in board config
has_peripheral :: proc(peripherals: []Peripheral_Config, interface: string) -> bool {
    for periph in peripherals {
        if periph.interface == interface {
            return true
        }
    }
    return false
}

// Peripheral bus information parsed from RCC
Peripheral_Bus_Info :: struct {
    gpio_clock_prefix: string,  // "IOP" or "GPIO"
    gpio_ahb_register: string,  // "AHBENR" or "AHB1ENR" or "AHB2ENR"
}

// Parse RCC peripheral to determine GPIO clock naming
parse_rcc_gpio_info :: proc(device: Device) -> Peripheral_Bus_Info {
    info := Peripheral_Bus_Info{}

    // Find RCC peripheral
    for periph in device.peripherals {
        if periph.name == "RCC" {
            // Look through all enable registers
            for reg in periph.registers {
                reg_name := reg.name

                // Check for GPIO clock pattern in AHB enable registers
                if strings.has_suffix(reg_name, "ENR") && strings.contains(reg_name, "AHB") {
                    for field in reg.fields {
                        // Check if it's IOPAEN (STM32F3) or GPIOAEN (STM32F4/F7)
                        if strings.has_prefix(field.name, "IOP") && strings.has_suffix(field.name, "EN") {
                            if len(info.gpio_clock_prefix) == 0 {
                                info.gpio_clock_prefix = "IOP"
                                info.gpio_ahb_register = reg_name
                            }
                        } else if strings.has_prefix(field.name, "GPIO") && strings.has_suffix(field.name, "EN") {
                            if len(info.gpio_clock_prefix) == 0 {
                                info.gpio_clock_prefix = "GPIO"
                                info.gpio_ahb_register = reg_name
                            }
                        }
                    }
                }
            }
            break
        }
    }

    // Defaults if not detected
    if len(info.gpio_clock_prefix) == 0 {
        info.gpio_clock_prefix = "GPIO"
        info.gpio_ahb_register = "AHB1ENR"
    }

    return info
}

// Check if GPIO peripherals have a BRR (Bit Reset Register)
// F1 family has separate BRR register, F2+ uses BSRR[31:16] for reset
gpio_has_brr :: proc(device: Device) -> bool {
    // Check any GPIO peripheral (they all have the same register layout)
    for periph in device.peripherals {
        if strings.has_prefix(periph.name, "GPIO") {
            for reg in periph.registers {
                if reg.name == "BRR" {
                    return true
                }
            }
            // Only need to check one GPIO peripheral
            break
        }
    }
    return false
}

// Check if UART peripherals use new-style registers (ISR/TDR/RDR) or old-style (SR/DR)
// F3 family uses ISR/TDR/RDR/ICR, F1/F2/F4 use SR/DR
uart_uses_isr :: proc(device: Device) -> bool {
    // Check any USART peripheral
    for periph in device.peripherals {
        if strings.has_prefix(periph.name, "USART") || strings.has_prefix(periph.name, "UART") {
            for reg in periph.registers {
                if reg.name == "ISR" {
                    return true  // New style (F3)
                }
                if reg.name == "SR" {
                    return false  // Old style (F1/F2/F4)
                }
            }
            // If derived, need to check base peripheral
            // For now, default to old style
            return false
        }
    }
    return false  // Default to old style
}

// Get the base peripheral name, resolving derivedFrom if necessary
// For example, GPIOE might be derived from GPIOC, so we return "GPIOC"
get_peripheral_base_name :: proc(device: Device, periph_name: string) -> string {
    for periph in device.peripherals {
        if periph.name == periph_name {
            if len(periph.derived_from) > 0 {
                return periph.derived_from
            }
            return periph_name
        }
    }
    return periph_name
}

// Find peripheral by name in board configuration
find_peripheral :: proc(peripherals: []Peripheral_Config, name: string) -> (^Peripheral_Config, bool) {
    for &periph in peripherals {
        if periph.name == name {
            return &periph, true
        }
    }
    return nil, false
}

// Generate board-specific code from Board_Config
generate_board_code :: proc(board: Board_Config, device: Device, board_dir: string) -> bool {
    // Generate board.odin
    board_file := fmt.tprintf("%s/board.odin", board_dir)
    if !generate_board_init_file(board, device, board_file) {
        return false
    }

    // Copy debug/driver.odin from template
    if !copy_debug_driver_template(board_dir) {
        return false
    }

    // Generate debug/init.odin (board-specific initialization)
    debug_init_file := fmt.tprintf("%s/debug/init.odin", board_dir)
    if !generate_debug_init_file(board, debug_init_file) {
        return false
    }

    fmt.printfln("Generated board init: %s", board_file)
    fmt.printfln("Copied debug driver template")
    fmt.printfln("Generated debug init: %s", debug_init_file)
    return true
}

// Copy debug driver template
copy_debug_driver_template :: proc(board_dir: string) -> bool {
    exe_path := os.args[0]
    exe_dir := filepath.dir(exe_path)
    template_path := filepath.join({exe_dir, "driver_templates", "debug", "driver.odin"})

    template_data, ok := os.read_entire_file(template_path)
    if !ok {
        fmt.eprintfln("Failed to read debug template: %s", template_path)
        return false
    }
    defer delete(template_data)

    dest_file := fmt.tprintf("%s/debug/driver.odin", board_dir)
    write_ok := os.write_entire_file(dest_file, template_data)
    if !write_ok {
        fmt.eprintfln("Failed to write debug driver: %s", dest_file)
        return false
    }

    return true
}

// Generate board.odin with initialization and LED/button APIs
generate_board_init_file :: proc(board: Board_Config, device: Device, filename: string) -> bool {
    b := strings.builder_make()
    defer strings.builder_destroy(&b)

    // Parse RCC to detect GPIO clock naming (IOP vs GPIO, AHBENR vs AHB1ENR)
    rcc_info := parse_rcc_gpio_info(device)

    // Detect GPIO control method
    has_brr := gpio_has_brr(device)
    use_odr := board.device.gpio_use_odr

    // Check which peripheral types are defined
    has_spi   := has_peripheral(board.peripherals, "spi")
    has_i2s   := has_peripheral(board.peripherals, "i2s")
    has_timer := has_peripheral(board.peripherals, "timer")
    has_rtc   := has_peripheral(board.peripherals, "rtc")
    has_iwdg  := has_peripheral(board.peripherals, "iwdg")
    has_wwdg  := has_peripheral(board.peripherals, "wwdg")

    // Package and imports
    fmt.sbprintln(&b, "package board")
    fmt.sbprintln(&b, "")
    fmt.sbprintln(&b, "// GENERATED FILE - DO NOT EDIT")
    fmt.sbprintln(&b, "// Generated from board.yaml by svd2odin")
    fmt.sbprintln(&b, "")
    fmt.sbprintln(&b, "import \"../cmsis/device\"")
    fmt.sbprintln(&b, "import hal \"../hal\"")
    fmt.sbprintln(&b, "import debug \"./debug\"")
    if has_spi {
        fmt.sbprintln(&b, "import spi \"../drivers/spi\"")
    }
    if has_i2s {
        fmt.sbprintln(&b, "import i2s \"../drivers/i2s\"")
    }
    if has_timer {
        fmt.sbprintln(&b, "import timer \"../drivers/timer\"")
    }
    if has_rtc {
        fmt.sbprintln(&b, "import rtc_driver \"../drivers/rtc\"")
    }
    if has_iwdg {
        fmt.sbprintln(&b, "import iwdg \"../drivers/iwdg\"")
    }
    if has_wwdg {
        fmt.sbprintln(&b, "import wwdg \"../drivers/wwdg\"")
    }
    fmt.sbprintln(&b, "")

    // Clock constants
    fmt.sbprintln(&b, "// ============================================================================")
    fmt.sbprintln(&b, "// Clock Configuration")
    fmt.sbprintln(&b, "// ============================================================================")
    fmt.sbprintln(&b, "")
    fmt.sbprintfln(&b, "SYSTEM_CLOCK_HZ :: %d", board.clocks.system_hz)
    fmt.sbprintfln(&b, "PCLK1_HZ :: %d", board.clocks.pclk1_hz)
    fmt.sbprintfln(&b, "PCLK2_HZ :: %d", board.clocks.pclk2_hz)
    fmt.sbprintln(&b, "LSE_HZ :: 32768  // Low-speed external crystal (standard)")
    // LSI frequency: use board config if specified, otherwise default to 40000
    lsi_hz := board.clocks.lsi_hz
    if lsi_hz == 0 {
        lsi_hz = 40000
    }
    fmt.sbprintfln(&b, "LSI_HZ :: %d  // Low-speed internal RC oscillator", lsi_hz)
    fmt.sbprintln(&b, "")

    // Generate SPI handles if any SPI peripherals are defined
    if has_spi {
        fmt.sbprintln(&b, "// ============================================================================")
        fmt.sbprintln(&b, "// SPI Peripherals")
        fmt.sbprintln(&b, "// ============================================================================")
        fmt.sbprintln(&b, "")
        for periph in board.peripherals {
            if periph.interface == "spi" {
                fmt.sbprintfln(&b, "%s: spi.SPI_Handle", periph.name)
            }
        }
        fmt.sbprintln(&b, "")
    }

    // Generate I2S handles if any I2S peripherals are defined
    if has_i2s {
        fmt.sbprintln(&b, "// ============================================================================")
        fmt.sbprintln(&b, "// I2S Peripherals")
        fmt.sbprintln(&b, "// ============================================================================")
        fmt.sbprintln(&b, "")
        for periph in board.peripherals {
            if periph.interface == "i2s" {
                fmt.sbprintfln(&b, "%s: i2s.I2S_Handle", periph.name)
            }
        }
        fmt.sbprintln(&b, "")
    }

    // Generate timer handles if any timer peripherals are defined
    if has_timer {
        fmt.sbprintln(&b, "// ============================================================================")
        fmt.sbprintln(&b, "// Timer Peripherals")
        fmt.sbprintln(&b, "// ============================================================================")
        fmt.sbprintln(&b, "")
        for periph in board.peripherals {
            if periph.interface == "timer" {
                fmt.sbprintfln(&b, "%s: timer.Timer_Handle", periph.name)
            }
        }
        fmt.sbprintln(&b, "")
    }

    // Generate RTC handle if defined
    if has_rtc {
        fmt.sbprintln(&b, "// ============================================================================")
        fmt.sbprintln(&b, "// RTC (Onboard)")
        fmt.sbprintln(&b, "// ============================================================================")
        fmt.sbprintln(&b, "")
        for periph in board.peripherals {
            if periph.interface == "rtc" {
                fmt.sbprintfln(&b, "%s: rtc_driver.RTC_Handle", periph.name)
            }
        }
        fmt.sbprintln(&b, "")
    }

    // Generate IWDG handle if defined
    if has_iwdg {
        fmt.sbprintln(&b, "// ============================================================================")
        fmt.sbprintln(&b, "// IWDG (Independent Watchdog)")
        fmt.sbprintln(&b, "// ============================================================================")
        fmt.sbprintln(&b, "")
        for periph in board.peripherals {
            if periph.interface == "iwdg" {
                fmt.sbprintfln(&b, "%s: iwdg.IWDG_Handle", periph.name)
            }
        }
        fmt.sbprintln(&b, "")
    }

    // Generate WWDG handle if defined
    if has_wwdg {
        fmt.sbprintln(&b, "// ============================================================================")
        fmt.sbprintln(&b, "// WWDG (Window Watchdog)")
        fmt.sbprintln(&b, "// ============================================================================")
        fmt.sbprintln(&b, "")
        for periph in board.peripherals {
            if periph.interface == "wwdg" {
                fmt.sbprintfln(&b, "%s: wwdg.WWDG_Handle", periph.name)
            }
        }
        fmt.sbprintln(&b, "")
    }

    // Collect all GPIOs (from board.gpio and peripherals[].gpio)
    all_gpios := [dynamic]GPIO_Config{}
    defer delete(all_gpios)

    for gpio in board.gpio {
        append(&all_gpios, gpio)
    }

    for periph in board.peripherals {
        for gpio in periph.gpio {
            append(&all_gpios, gpio)
        }
    }

    // Generate GPIO enum and functions if we have any GPIOs
    if len(all_gpios) > 0 {
        fmt.sbprintln(&b, "// ============================================================================")
        fmt.sbprintln(&b, "// GPIO Configuration")
        fmt.sbprintln(&b, "// ============================================================================")
        fmt.sbprintln(&b, "")

        // Generate GPIO_Pin enum
        fmt.sbprintln(&b, "GPIO_Pin :: enum {")
        for gpio in all_gpios {
            fmt.sbprintfln(&b, "    %s,  // %s", gpio.name, gpio.description)
        }
        fmt.sbprintln(&b, "}")
        fmt.sbprintln(&b, "")

        // Generate generic GPIO control functions using switch statements
        fmt.sbprintln(&b, "// ============================================================================")
        fmt.sbprintln(&b, "// Generic GPIO Functions")
        fmt.sbprintln(&b, "// ============================================================================")
        fmt.sbprintln(&b, "")

        // gpio_set function
        fmt.sbprintln(&b, "// Set GPIO pin high")
        fmt.sbprintln(&b, "gpio_set :: proc \"c\" (gpio: GPIO_Pin) {")
        fmt.sbprintln(&b, "    #partial switch gpio {")
        for gpio in all_gpios {
            if gpio.mode == "output" {
                if use_odr {
                    // Use ODR for broken BSRR silicon
                    fmt.sbprintfln(&b, "    case .%s: hal.reg_modify(&device.%s.ODR, .Set, 1 << %d)", gpio.name, gpio.port, gpio.pin)
                } else {
                    // Use BSRR (works on all families for SET)
                    fmt.sbprintfln(&b, "    case .%s: hal.reg_write(&device.%s.BSRR, 1 << %d)", gpio.name, gpio.port, gpio.pin)
                }
            }
        }
        fmt.sbprintln(&b, "    }")
        fmt.sbprintln(&b, "}")
        fmt.sbprintln(&b, "")

        // gpio_clear function
        fmt.sbprintln(&b, "// Set GPIO pin low")
        fmt.sbprintln(&b, "gpio_clear :: proc \"c\" (gpio: GPIO_Pin) {")
        fmt.sbprintln(&b, "    #partial switch gpio {")
        for gpio in all_gpios {
            if gpio.mode == "output" {
                if use_odr {
                    // Use ODR for broken BSRR silicon
                    fmt.sbprintfln(&b, "    case .%s: hal.reg_modify(&device.%s.ODR, .Clear, 1 << %d)", gpio.name, gpio.port, gpio.pin)
                } else if has_brr {
                    // F1 family: Use separate BRR register
                    fmt.sbprintfln(&b, "    case .%s: hal.reg_write(&device.%s.BRR, 1 << %d)", gpio.name, gpio.port, gpio.pin)
                } else {
                    // F2/F3/F4/F7/H7: Use BSRR[31:16] for reset
                    fmt.sbprintfln(&b, "    case .%s: hal.reg_write(&device.%s.BSRR, 1 << %d)", gpio.name, gpio.port, gpio.pin + 16)
                }
            }
        }
        fmt.sbprintln(&b, "    }")
        fmt.sbprintln(&b, "}")
        fmt.sbprintln(&b, "")

        // gpio_read function
        fmt.sbprintln(&b, "// Read GPIO pin state")
        fmt.sbprintln(&b, "gpio_read :: proc \"c\" (gpio: GPIO_Pin) -> bool {")
        fmt.sbprintln(&b, "    #partial switch gpio {")
        for gpio in all_gpios {
            fmt.sbprintfln(&b, "    case .%s: return (hal.reg_read(&device.%s.IDR) & (1 << %d)) != 0", gpio.name, gpio.port, gpio.pin)
        }
        fmt.sbprintln(&b, "    }")
        fmt.sbprintln(&b, "    return false")
        fmt.sbprintln(&b, "}")
        fmt.sbprintln(&b, "")

        // gpio_toggle function
        fmt.sbprintln(&b, "// Toggle GPIO pin")
        fmt.sbprintln(&b, "gpio_toggle :: proc \"c\" (gpio: GPIO_Pin) {")
        fmt.sbprintln(&b, "    if gpio_read(gpio) {")
        fmt.sbprintln(&b, "        gpio_clear(gpio)")
        fmt.sbprintln(&b, "    } else {")
        fmt.sbprintln(&b, "        gpio_set(gpio)")
        fmt.sbprintln(&b, "    }")
        fmt.sbprintln(&b, "}")
        fmt.sbprintln(&b, "")
    }

    // Board init function
    fmt.sbprintln(&b, "// ============================================================================")
    fmt.sbprintln(&b, "// Board Initialization")
    fmt.sbprintln(&b, "// ============================================================================")
    fmt.sbprintln(&b, "")
    fmt.sbprintln(&b, "init :: proc() {")

    // Enable GPIO clocks
    gpio_clocks := make(map[string]bool)
    defer delete(gpio_clocks)

    // GPIO clocks for standalone GPIOs
    for gpio in board.gpio {
        gpio_clocks[gpio.port] = true
    }

    // GPIO clocks for peripherals
    for periph in board.peripherals {
        switch periph.interface {
        case "uart":
            if len(periph.tx.port) > 0 do gpio_clocks[periph.tx.port] = true
            if len(periph.rx.port) > 0 do gpio_clocks[periph.rx.port] = true
        case "spi":
            if len(periph.sck.port) > 0 do gpio_clocks[periph.sck.port] = true
            if len(periph.miso.port) > 0 do gpio_clocks[periph.miso.port] = true
            if len(periph.mosi.port) > 0 do gpio_clocks[periph.mosi.port] = true
        case "i2c":
            if len(periph.scl.port) > 0 do gpio_clocks[periph.scl.port] = true
            if len(periph.sda.port) > 0 do gpio_clocks[periph.sda.port] = true
        case "i2s":
            if len(periph.ws.port) > 0 do gpio_clocks[periph.ws.port] = true
            if len(periph.ck.port) > 0 do gpio_clocks[periph.ck.port] = true
            if len(periph.sd.port) > 0 do gpio_clocks[periph.sd.port] = true
        case "timer":
            for ch in periph.channels {
                if len(ch.pin.port) > 0 do gpio_clocks[ch.pin.port] = true
            }
        }
        // Enable clocks for peripheral-associated GPIOs
        for gpio in periph.gpio {
            if len(gpio.port) > 0 do gpio_clocks[gpio.port] = true
        }
    }

    if len(gpio_clocks) > 0 {
        fmt.sbprintln(&b, "    // Enable GPIO clocks")
        fmt.sbprintf(&b, "    hal.reg_modify(&device.RCC.%s, .Set,\n        ", rcc_info.gpio_ahb_register)
        clock_idx := 0
        for gpio in gpio_clocks {
            if clock_idx > 0 {
                fmt.sbprint(&b, " |\n        ")
            }
            // Auto-detected from RCC: IOP for STM32F3, GPIO for STM32F4/F7
            gpio_letter := strings.to_upper(gpio)[len("GPIO"):]  // Extract just the letter (A, B, C, etc)
            fmt.sbprintf(&b, "device.RCC_%s_%s%sEN_Mask_Shifted", rcc_info.gpio_ahb_register, rcc_info.gpio_clock_prefix, gpio_letter)
            clock_idx += 1
        }
        fmt.sbprintln(&b, ")")
        fmt.sbprintln(&b, "")
    }

    // Enable peripheral clocks (DMA)
    for periph in board.peripherals {
        if periph.interface == "dma" && periph.enable {
            dma_name := strings.to_upper(periph.peripheral)
            fmt.sbprintfln(&b, "    // Enable %s clock", dma_name)
            fmt.sbprintfln(&b, "    hal.reg_modify(&device.RCC.%s, .Set,", rcc_info.gpio_ahb_register)
            fmt.sbprintfln(&b, "        device.RCC_%s_%sEN_Mask_Shifted)", rcc_info.gpio_ahb_register, dma_name)
            fmt.sbprintln(&b, "")
        }
    }

    fmt.sbprintln(&b, "    // Initialize debug UART")
    fmt.sbprintln(&b, "    debug.init()")
    fmt.sbprintln(&b, "")

    if len(all_gpios) > 0 {
        fmt.sbprintln(&b, "    // Configure GPIO pins")
        fmt.sbprintln(&b, "    init_gpios()")
    }

    // Initialize SPI peripherals
    if has_spi {
        fmt.sbprintln(&b, "")
        fmt.sbprintln(&b, "    // Initialize SPI peripherals")
        for periph in board.peripherals {
            if periph.interface == "spi" {
                fmt.sbprintfln(&b, "    init_%s()", periph.name)
            }
        }
    }

    // Initialize I2S peripherals
    if has_i2s {
        fmt.sbprintln(&b, "")
        fmt.sbprintln(&b, "    // Initialize I2S peripherals")
        for periph in board.peripherals {
            if periph.interface == "i2s" {
                fmt.sbprintfln(&b, "    init_%s()", periph.name)
            }
        }
    }

    // Initialize timer peripherals
    if has_timer {
        fmt.sbprintln(&b, "")
        fmt.sbprintln(&b, "    // Initialize timer peripherals")
        for periph in board.peripherals {
            if periph.interface == "timer" {
                fmt.sbprintfln(&b, "    init_%s()", periph.name)
            }
        }
    }

    // Initialize RTC
    if has_rtc {
        fmt.sbprintln(&b, "")
        fmt.sbprintln(&b, "    // Initialize onboard RTC")
        for periph in board.peripherals {
            if periph.interface == "rtc" {
                fmt.sbprintfln(&b, "    init_%s()", periph.name)
            }
        }
    }

    // Initialize IWDG (configure only, call iwdg_start to enable)
    if has_iwdg {
        fmt.sbprintln(&b, "")
        fmt.sbprintln(&b, "    // Initialize IWDG (call iwdg.iwdg_start to enable)")
        for periph in board.peripherals {
            if periph.interface == "iwdg" {
                fmt.sbprintfln(&b, "    init_%s()", periph.name)
            }
        }
    }

    // Initialize WWDG (configure only, call wwdg_start to enable)
    if has_wwdg {
        fmt.sbprintln(&b, "")
        fmt.sbprintln(&b, "    // Initialize WWDG (call wwdg.wwdg_start to enable)")
        for periph in board.peripherals {
            if periph.interface == "wwdg" {
                fmt.sbprintfln(&b, "    init_%s()", periph.name)
            }
        }
    }

    fmt.sbprintln(&b, "}")
    fmt.sbprintln(&b, "")

    // GPIO initialization function
    if len(all_gpios) > 0 {
        fmt.sbprintln(&b, "init_gpios :: proc \"c\" () {")
        for gpio in all_gpios {
            fmt.sbprintfln(&b, "    // %s - %s on %s%d", gpio.name, gpio.description, gpio.port, gpio.pin)

            if gpio.mode == "output" {
                // Set pin to output mode
                fmt.sbprintfln(&b, "    hal.reg_modify(&device.%s.MODER, .Clear, %s << (%d * 2))", gpio.port, GPIO_MODE_MASK, gpio.pin)
                fmt.sbprintfln(&b, "    hal.reg_modify(&device.%s.MODER, .Set, %s << (%d * 2))", gpio.port, GPIO_MODE_OUTPUT, gpio.pin)
            } else if gpio.mode == "input" {
                // Set pin to input mode
                fmt.sbprintfln(&b, "    hal.reg_modify(&device.%s.MODER, .Clear, %s << (%d * 2))", gpio.port, GPIO_MODE_MASK, gpio.pin)

                // Configure pull-up/pull-down if specified
                if len(gpio.pull) > 0 {
                    pull_value := GPIO_PUPD_NONE
                    switch gpio.pull {
                    case "pulldown": pull_value = GPIO_PUPD_DOWN
                    case "pullup":   pull_value = GPIO_PUPD_UP
                    }
                    fmt.sbprintfln(&b, "    hal.reg_modify(&device.%s.PUPDR, .Clear, %s << (%d * 2))", gpio.port, GPIO_PUPD_MASK, gpio.pin)
                    fmt.sbprintfln(&b, "    hal.reg_modify(&device.%s.PUPDR, .Set, %s << (%d * 2))", gpio.port, pull_value, gpio.pin)
                }
            }
        }
        fmt.sbprintln(&b, "}")
        fmt.sbprintln(&b, "")
    }

    // SPI initialization functions
    if has_spi {
        for periph in board.peripherals {
            if periph.interface != "spi" do continue

            // Determine APB bus for SPI peripheral
            // SPI1, SPI4, SPI5, SPI6 are typically on APB2; SPI2, SPI3 on APB1
            apb_bus := "APB1"
            apb_register := "APB1ENR"
            if periph.peripheral == "SPI1" || periph.peripheral == "SPI4" ||
               periph.peripheral == "SPI5" || periph.peripheral == "SPI6" {
                apb_bus = "APB2"
                apb_register = "APB2ENR"
            }

            // Calculate SPI speed divider from requested speed
            // Divider options: 2, 4, 8, 16, 32, 64, 128, 256
            pclk := board.clocks.pclk1_hz
            if apb_bus == "APB2" do pclk = board.clocks.pclk2_hz

            divider_enum := "Div8"  // Default
            if periph.speed > 0 {
                ratio := int(pclk) / periph.speed
                if ratio <= 2 { divider_enum = "Div2" }
                else if ratio <= 4 { divider_enum = "Div4" }
                else if ratio <= 8 { divider_enum = "Div8" }
                else if ratio <= 16 { divider_enum = "Div16" }
                else if ratio <= 32 { divider_enum = "Div32" }
                else if ratio <= 64 { divider_enum = "Div64" }
                else if ratio <= 128 { divider_enum = "Div128" }
                else { divider_enum = "Div256" }
            }

            // SPI mode (0-3)
            mode_enum := fmt.tprintf("Mode%d", periph.mode)

            // Data size (default to 8-bit)
            data_size_enum := "EightBit"
            if periph.data_size == 16 {
                data_size_enum = "SixteenBit"
            }

            // Bit order (default to MSB first)
            bit_order_enum := "MSBFirst"
            if periph.bit_order == "lsb" {
                bit_order_enum = "LSBFirst"
            }

            fmt.sbprintfln(&b, "init_%s :: proc \"c\" () {{", periph.name)
            fmt.sbprintfln(&b, "    // Enable %s clock (%s)", periph.peripheral, apb_bus)
            fmt.sbprintfln(&b, "    hal.reg_modify(&device.RCC.%s, .Set, device.RCC_%s_%sEN_Mask_Shifted)",
                apb_register, apb_register, periph.peripheral)
            fmt.sbprintln(&b, "")

            // Configure SPI pins
            write_gpio_af_config(&b, periph.sck.port, periph.sck.pin, periph.sck.af, "SCK")
            write_gpio_af_config(&b, periph.miso.port, periph.miso.pin, periph.miso.af, "MISO")
            write_gpio_af_config(&b, periph.mosi.port, periph.mosi.pin, periph.mosi.af, "MOSI")

            // Initialize SPI peripheral
            fmt.sbprintfln(&b, "    // Initialize %s peripheral", periph.peripheral)
            fmt.sbprintfln(&b, "    %s.regs = device.%s", periph.name, periph.peripheral)
            fmt.sbprintln(&b, "")
            fmt.sbprintln(&b, "    spi_config := spi.SPI_Config{")
            fmt.sbprintfln(&b, "        mode = .%s,", mode_enum)
            fmt.sbprintfln(&b, "        speed = .%s,", divider_enum)
            fmt.sbprintfln(&b, "        data_size = .%s,", data_size_enum)
            fmt.sbprintfln(&b, "        bit_order = .%s,", bit_order_enum)
            fmt.sbprintln(&b, "    }")
            fmt.sbprintfln(&b, "    spi.spi_init(&%s, spi_config)", periph.name)
            fmt.sbprintln(&b, "}")
            fmt.sbprintln(&b, "")
        }
    }

    // I2S initialization functions
    if has_i2s {
        for periph in board.peripherals {
            if periph.interface != "i2s" do continue

            // I2S uses SPI2 or SPI3 peripheral in I2S mode
            // Determine APB bus
            apb_bus := "APB1"
            apb_register := "APB1ENR"
            pclk := board.clocks.pclk1_hz

            fmt.sbprintfln(&b, "init_%s :: proc \"c\" () {{", periph.name)
            fmt.sbprintfln(&b, "    // Enable %s clock (%s)", periph.peripheral, apb_bus)
            fmt.sbprintfln(&b, "    hal.reg_modify(&device.RCC.%s, .Set, device.RCC_%s_%sEN_Mask_Shifted)",
                apb_register, apb_register, periph.peripheral)
            fmt.sbprintln(&b, "")

            // Configure I2S pins
            write_gpio_af_config(&b, periph.ws.port, periph.ws.pin, periph.ws.af, "WS")
            write_gpio_af_config(&b, periph.ck.port, periph.ck.pin, periph.ck.af, "CK")
            write_gpio_af_config(&b, periph.sd.port, periph.sd.pin, periph.sd.af, "SD")

            // Determine I2S mode enum
            mode_enum := "MasterRx"
            switch periph.i2s_mode {
            case "master_tx": mode_enum = "MasterTx"
            case "master_rx": mode_enum = "MasterRx"
            case "slave_tx":  mode_enum = "SlaveTx"
            case "slave_rx":  mode_enum = "SlaveRx"
            }

            // Determine I2S standard enum
            standard_enum := "Philips"
            switch periph.standard {
            case "philips": standard_enum = "Philips"
            case "msb":     standard_enum = "MSB"
            case "lsb":     standard_enum = "LSB"
            case "pcm":     standard_enum = "PCM"
            }

            // Determine data length enum
            data_length_enum := "Bits16"
            if periph.data_size == 24 {
                data_length_enum = "Bits24"
            } else if periph.data_size == 32 {
                data_length_enum = "Bits32"
            }

            // Channel length (32-bit for 24/32-bit data, 16-bit for 16-bit data)
            channel_length_enum := "Bits16"
            if periph.data_size > 16 {
                channel_length_enum = "Bits32"
            }

            // Initialize I2S peripheral
            fmt.sbprintfln(&b, "    // Initialize %s peripheral in I2S mode", periph.peripheral)
            fmt.sbprintfln(&b, "    %s.regs = device.%s", periph.name, periph.peripheral)
            fmt.sbprintfln(&b, "    %s.pclk = %d", periph.name, pclk)
            fmt.sbprintln(&b, "")
            fmt.sbprintln(&b, "    i2s_config := i2s.I2S_Config{")
            fmt.sbprintfln(&b, "        standard = .%s,", standard_enum)
            fmt.sbprintfln(&b, "        data_length = .%s,", data_length_enum)
            fmt.sbprintfln(&b, "        channel_length = .%s,", channel_length_enum)
            fmt.sbprintfln(&b, "        mode = .%s,", mode_enum)
            fmt.sbprintln(&b, "        clock_polarity = false,")
            fmt.sbprintln(&b, "        mck_output = false,")
            fmt.sbprintln(&b, "    }")
            fmt.sbprintfln(&b, "    i2s.i2s_init(&%s, i2s_config)", periph.name)
            fmt.sbprintln(&b, "")

            // Calculate prescaler for sample rate
            // For now, use a simple prescaler based on sample rate
            // Fs = I2Sclk / (32 * 2 * ((2*I2SDIV) + ODD)) for 32-bit channel
            // Fs = I2Sclk / (16 * 2 * ((2*I2SDIV) + ODD)) for 16-bit channel
            divider := 8  // Default
            odd := false
            if periph.sample_rate > 0 {
                // Approximate calculation for 8MHz clock
                if periph.sample_rate <= 8000 {
                    divider = 31
                    odd = true
                } else if periph.sample_rate <= 16000 {
                    divider = 15
                    odd = true
                } else if periph.sample_rate <= 32000 {
                    divider = 7
                    odd = true
                } else {
                    divider = 5
                    odd = false
                }
            }
            fmt.sbprintfln(&b, "    // Configure prescaler for ~%dHz sample rate", periph.sample_rate)
            fmt.sbprintfln(&b, "    i2s.i2s_set_prescaler(&%s, %d, %s, false)", periph.name, divider, odd ? "true" : "false")
            fmt.sbprintln(&b, "")
            fmt.sbprintfln(&b, "    i2s.i2s_enable(&%s)", periph.name)
            fmt.sbprintln(&b, "}")
            fmt.sbprintln(&b, "")
        }
    }

    // Timer initialization functions
    if has_timer {
        for periph in board.peripherals {
            if periph.interface != "timer" do continue

            // Determine APB bus for timer peripheral
            // TIM1, TIM8, TIM9, TIM10, TIM11, TIM15, TIM16, TIM17, TIM20 are on APB2
            // TIM2, TIM3, TIM4, TIM5, TIM6, TIM7, TIM12, TIM13, TIM14 are on APB1
            apb_bus := "APB1"
            apb_register := "APB1ENR"
            pclk := board.clocks.pclk1_hz
            tim_name := periph.peripheral

            // Check if it's an APB2 timer
            apb2_timers := []string{"TIM1", "TIM8", "TIM9", "TIM10", "TIM11", "TIM15", "TIM16", "TIM17", "TIM20"}
            for t in apb2_timers {
                if tim_name == t {
                    apb_bus = "APB2"
                    apb_register = "APB2ENR"
                    pclk = board.clocks.pclk2_hz
                    break
                }
            }

            // Check if it's an advanced timer (TIM1, TIM8, TIM20)
            is_advanced := tim_name == "TIM1" || tim_name == "TIM8" || tim_name == "TIM20"

            fmt.sbprintfln(&b, "init_%s :: proc \"c\" () {{", periph.name)
            fmt.sbprintfln(&b, "    // Enable %s clock (%s)", tim_name, apb_bus)
            fmt.sbprintfln(&b, "    hal.reg_modify(&device.RCC.%s, .Set, device.RCC_%s_%sEN_Mask_Shifted)",
                apb_register, apb_register, tim_name)
            fmt.sbprintln(&b, "")

            // Configure PWM channel pins if any
            for ch in periph.channels {
                signal_name := fmt.tprintf("CH%d", ch.channel)
                write_gpio_af_config(&b, ch.pin.port, ch.pin.pin, ch.pin.af, signal_name)
            }

            // Initialize timer peripheral
            fmt.sbprintfln(&b, "    // Initialize %s peripheral", tim_name)
            fmt.sbprintfln(&b, "    %s.regs = cast(^device.TIM2_Registers)device.%s", periph.name, tim_name)
            fmt.sbprintfln(&b, "    %s.is_advanced = %s", periph.name, is_advanced ? "true" : "false")
            fmt.sbprintln(&b, "")

            // Determine timer mode
            mode_enum := "Basic"
            if periph.timer_mode == "pwm" {
                mode_enum = "PWM"
            }

            fmt.sbprintln(&b, "    timer_config := timer.Timer_Config{")
            fmt.sbprintfln(&b, "        mode = .%s,", mode_enum)
            fmt.sbprintfln(&b, "        frequency = %d,", periph.frequency)
            fmt.sbprintfln(&b, "        pclk = %d,", pclk)
            fmt.sbprintln(&b, "    }")
            fmt.sbprintfln(&b, "    timer.timer_init(&%s, timer_config)", periph.name)
            fmt.sbprintln(&b, "")

            // Configure PWM channels
            for ch in periph.channels {
                polarity_enum := "ActiveHigh"
                if ch.polarity == "active_low" {
                    polarity_enum = "ActiveLow"
                }

                fmt.sbprintfln(&b, "    // Configure PWM channel %d", ch.channel)
                fmt.sbprintln(&b, "    pwm_config := timer.PWM_Config{")
                fmt.sbprintfln(&b, "        channel = .CH%d,", ch.channel)
                fmt.sbprintfln(&b, "        polarity = .%s,", polarity_enum)
                fmt.sbprintfln(&b, "        duty = %d,", ch.duty)
                fmt.sbprintln(&b, "    }")
                fmt.sbprintfln(&b, "    timer.timer_pwm_config(&%s, pwm_config)", periph.name)
                fmt.sbprintln(&b, "")
            }

            // Enable update interrupt if requested
            if periph.interrupt {
                fmt.sbprintfln(&b, "    timer.timer_enable_interrupt(&%s)", periph.name)
            }

            fmt.sbprintfln(&b, "    timer.timer_enable(&%s)", periph.name)
            fmt.sbprintln(&b, "}")
            fmt.sbprintln(&b, "")
        }
    }

    // RTC initialization functions
    if has_rtc {
        for periph in board.peripherals {
            if periph.interface != "rtc" do continue

            // Determine clock source
            use_lse := periph.clock_source != "lsi"  // Default to LSE
            clock_source_enum := use_lse ? "LSE" : "LSI"

            fmt.sbprintfln(&b, "init_%s :: proc \"c\" () {{", periph.name)
            fmt.sbprintln(&b, "    // Enable PWR clock for backup domain access")
            fmt.sbprintln(&b, "    hal.reg_modify(&device.RCC.APB1ENR, .Set, device.RCC_APB1ENR_PWREN_Mask_Shifted)")
            fmt.sbprintln(&b, "")
            fmt.sbprintln(&b, "    // Unlock backup domain (DBP bit in PWR_CR)")
            fmt.sbprintln(&b, "    hal.reg_modify(&device.PWR.CR, .Set, device.PWR_CR_DBP_Mask_Shifted)")
            fmt.sbprintln(&b, "")

            if use_lse {
                fmt.sbprintln(&b, "    // Enable LSE (32.768 kHz external crystal)")
                fmt.sbprintln(&b, "    hal.reg_modify(&device.RCC.BDCR, .Set, device.RCC_BDCR_LSEON_Mask_Shifted)")
                fmt.sbprintln(&b, "")
                fmt.sbprintln(&b, "    // Wait for LSE ready (with timeout)")
                fmt.sbprintln(&b, "    timeout: u32 = 1000000")
                fmt.sbprintln(&b, "    for timeout > 0 {")
                fmt.sbprintln(&b, "        if (hal.reg_read(&device.RCC.BDCR) & device.RCC_BDCR_LSERDY_Mask_Shifted) != 0 {")
                fmt.sbprintln(&b, "            break")
                fmt.sbprintln(&b, "        }")
                fmt.sbprintln(&b, "        timeout -= 1")
                fmt.sbprintln(&b, "    }")
                fmt.sbprintln(&b, "")
                fmt.sbprintln(&b, "    // Select LSE as RTC clock source (RTCSEL = 01)")
                fmt.sbprintln(&b, "    hal.reg_modify(&device.RCC.BDCR, .Clear, device.RCC_BDCR_RTCSEL_Mask_Shifted)")
                fmt.sbprintln(&b, "    hal.reg_modify(&device.RCC.BDCR, .Set, 1 << device.RCC_BDCR_RTCSEL_Pos)")
            } else {
                fmt.sbprintln(&b, "    // Enable LSI (~40 kHz internal RC)")
                fmt.sbprintln(&b, "    hal.reg_modify(&device.RCC.CSR, .Set, device.RCC_CSR_LSION_Mask_Shifted)")
                fmt.sbprintln(&b, "")
                fmt.sbprintln(&b, "    // Wait for LSI ready (with timeout)")
                fmt.sbprintln(&b, "    timeout: u32 = 100000")
                fmt.sbprintln(&b, "    for timeout > 0 {")
                fmt.sbprintln(&b, "        if (hal.reg_read(&device.RCC.CSR) & device.RCC_CSR_LSIRDY_Mask_Shifted) != 0 {")
                fmt.sbprintln(&b, "            break")
                fmt.sbprintln(&b, "        }")
                fmt.sbprintln(&b, "        timeout -= 1")
                fmt.sbprintln(&b, "    }")
                fmt.sbprintln(&b, "")
                fmt.sbprintln(&b, "    // Select LSI as RTC clock source (RTCSEL = 10)")
                fmt.sbprintln(&b, "    hal.reg_modify(&device.RCC.BDCR, .Clear, device.RCC_BDCR_RTCSEL_Mask_Shifted)")
                fmt.sbprintln(&b, "    hal.reg_modify(&device.RCC.BDCR, .Set, 2 << device.RCC_BDCR_RTCSEL_Pos)")
            }
            fmt.sbprintln(&b, "")
            fmt.sbprintln(&b, "    // Enable RTC clock")
            fmt.sbprintln(&b, "    hal.reg_modify(&device.RCC.BDCR, .Set, device.RCC_BDCR_RTCEN_Mask_Shifted)")
            fmt.sbprintln(&b, "")
            fmt.sbprintfln(&b, "    // Initialize RTC driver")
            fmt.sbprintfln(&b, "    %s.regs = device.RTC", periph.name)
            fmt.sbprintfln(&b, "    %s.clock_source = .%s", periph.name, clock_source_enum)
            fmt.sbprintfln(&b, "    rtc_driver.rtc_init(&%s)", periph.name)
            fmt.sbprintln(&b, "}")
            fmt.sbprintln(&b, "")
        }
    }

    // IWDG initialization functions
    if has_iwdg {
        for periph in board.peripherals {
            if periph.interface != "iwdg" do continue

            timeout_ms := periph.timeout_ms
            if timeout_ms <= 0 {
                timeout_ms = 1000  // Default 1 second
            }

            fmt.sbprintfln(&b, "init_%s :: proc \"c\" () {{", periph.name)
            fmt.sbprintfln(&b, "    iwdg.iwdg_init(&%s, %d)", periph.name, timeout_ms)
            fmt.sbprintfln(&b, "    iwdg.iwdg_configure(&%s)", periph.name)
            fmt.sbprintln(&b, "    // Call iwdg.iwdg_start() when ready to enable watchdog")
            fmt.sbprintln(&b, "}")
            fmt.sbprintln(&b, "")
        }
    }

    // WWDG initialization functions
    if has_wwdg {
        for periph in board.peripherals {
            if periph.interface != "wwdg" do continue

            timeout_ms := periph.timeout_ms
            if timeout_ms <= 0 {
                timeout_ms = 50  // Default 50ms
            }
            window_ms := periph.window_ms
            if window_ms <= 0 {
                window_ms = timeout_ms  // Default to full window
            }

            fmt.sbprintfln(&b, "init_%s :: proc \"c\" () {{", periph.name)
            fmt.sbprintfln(&b, "    wwdg.wwdg_init(&%s, APB1_CLOCK_HZ, %d, %d)", periph.name, window_ms, timeout_ms)
            fmt.sbprintln(&b, "    // Call wwdg.wwdg_start() when ready to enable watchdog")
            fmt.sbprintln(&b, "}")
            fmt.sbprintln(&b, "")
        }
    }

    // Write file
    return os.write_entire_file(filename, transmute([]byte)strings.to_string(b))
}

// Generate debug/init.odin with board-specific UART initialization
// The common debug utilities are in driver.odin (copied from template)
generate_debug_init_file :: proc(board: Board_Config, filename: string) -> bool {
    // Find debug UART peripheral
    debug_uart, found := find_peripheral(board.peripherals, "debug_uart")
    if !found || debug_uart.interface != "uart" {
        fmt.eprintln("Error: No debug_uart peripheral found in board config")
        return false
    }

    b := strings.builder_make()
    defer strings.builder_destroy(&b)

    fmt.sbprintln(&b, "package debug")
    fmt.sbprintln(&b, "")
    fmt.sbprintln(&b, "// GENERATED FILE - DO NOT EDIT")
    fmt.sbprintln(&b, "// Board-specific debug UART initialization")
    fmt.sbprintln(&b, "// Generated from board.yaml by svd2odin")
    fmt.sbprintln(&b, "")
    fmt.sbprintln(&b, "import device \"../../cmsis/device\"")
    fmt.sbprintln(&b, "import hal \"../../hal\"")
    fmt.sbprintln(&b, "import uart \"../../drivers/uart\"")
    fmt.sbprintln(&b, "")

    // Determine APB bus for UART peripheral
    apb_bus := "APB1"  // Default: USART2/3/4/5 are on APB1
    pclk_hz := board.clocks.pclk1_hz
    if debug_uart.peripheral == "USART1" || debug_uart.peripheral == "USART6" {
        apb_bus = "APB2"  // USART1 and USART6 are on APB2
        pclk_hz = board.clocks.pclk2_hz
    }

    // Init function
    fmt.sbprintfln(&b, "// Initialize debug UART on %s (TX: %s%d, RX: %s%d)",
        debug_uart.peripheral, debug_uart.tx.port, debug_uart.tx.pin,
        debug_uart.rx.port, debug_uart.rx.pin)
    fmt.sbprintln(&b, "init :: proc \"c\" () {")
    fmt.sbprintfln(&b, "    // Enable %s clock (%s)", debug_uart.peripheral, apb_bus)
    fmt.sbprintfln(&b, "    hal.reg_modify(&device.RCC.%sENR, .Set, device.RCC_%sENR_%sEN_Mask_Shifted)",
        apb_bus, apb_bus, strings.to_upper(debug_uart.peripheral))
    fmt.sbprintln(&b, "")

    // Configure TX and RX pins
    write_gpio_af_config(&b, debug_uart.tx.port, debug_uart.tx.pin, debug_uart.tx.af, "TX")
    write_gpio_af_config(&b, debug_uart.rx.port, debug_uart.rx.pin, debug_uart.rx.af, "RX")

    fmt.sbprintln(&b, "    // Initialize UART peripheral")
    fmt.sbprintfln(&b, "    debug_uart.regs = device.%s", strings.to_upper(debug_uart.peripheral))
    fmt.sbprintfln(&b, "    debug_uart.pclk = %d  // %s @ %d Hz", pclk_hz, apb_bus, pclk_hz)
    fmt.sbprintln(&b, "")

    fmt.sbprintln(&b, "    uart_config := uart.UART_Config{")
    fmt.sbprintfln(&b, "        baud_rate = .Baud%d,", debug_uart.baud)
    fmt.sbprintln(&b, "        data_bits = .Bits8,")
    fmt.sbprintln(&b, "        stop_bits = .Stop1,")
    fmt.sbprintln(&b, "        parity    = .None,")
    fmt.sbprintln(&b, "    }")
    fmt.sbprintln(&b, "    uart.uart_init(&debug_uart, uart_config)")
    fmt.sbprintln(&b, "")
    fmt.sbprintln(&b, "    debug_initialized = true")
    fmt.sbprintln(&b, "}")

    // Write file
    return os.write_entire_file(filename, transmute([]byte)strings.to_string(b))
}

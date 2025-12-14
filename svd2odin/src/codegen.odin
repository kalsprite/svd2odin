package svd2odin

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

// Generate Odin code from parsed Device
generate_code :: proc(device: Device, board: Board_Config, memory: Memory_Config, output_dir: string) -> bool {
    // Create output directory structure
    dirs := []string{
        output_dir,
        fmt.tprintf("%s/cmsis", output_dir),
        fmt.tprintf("%s/cmsis/device", output_dir),
        fmt.tprintf("%s/hal", output_dir),
        fmt.tprintf("%s/drivers", output_dir),
        fmt.tprintf("%s/drivers/uart", output_dir),
        fmt.tprintf("%s/drivers/dma", output_dir),
        fmt.tprintf("%s/drivers/spi", output_dir),
        fmt.tprintf("%s/drivers/i2c", output_dir),
        fmt.tprintf("%s/drivers/i2s", output_dir),
        fmt.tprintf("%s/drivers/timer", output_dir),
        fmt.tprintf("%s/drivers/rtc", output_dir),
        fmt.tprintf("%s/drivers/iwdg", output_dir),
        fmt.tprintf("%s/drivers/wwdg", output_dir),
        fmt.tprintf("%s/drivers/pwr", output_dir),
        fmt.tprintf("%s/drivers/exti", output_dir),
        fmt.tprintf("%s/drivers/crc", output_dir),
        fmt.tprintf("%s/sys", output_dir),
        fmt.tprintf("%s/sys/systick", output_dir),
        fmt.tprintf("%s/sys/nvic", output_dir),
        fmt.tprintf("%s/sys/interrupts", output_dir),
        fmt.tprintf("%s/sync", output_dir),
        fmt.tprintf("%s/freestanding", output_dir),
        fmt.tprintf("%s/board", output_dir),
        fmt.tprintf("%s/board/debug", output_dir),
    }

    for dir in dirs {
        if !os.exists(dir) {
            err := os.make_directory(dir)
            if err != nil {
                fmt.eprintfln("Failed to create directory: %s", dir)
                return false
            }
        }
    }

    // Create RNG driver directory if hardware RNG is available
    if device.has_rng {
        rng_dir := fmt.tprintf("%s/drivers/rng", output_dir)
        if !os.exists(rng_dir) {
            err := os.make_directory(rng_dir)
            if err != nil {
                fmt.eprintfln("Failed to create directory: %s", rng_dir)
                return false
            }
        }
    }

    // Generate hal/register.odin
    hal_dir := fmt.tprintf("%s/hal", output_dir)
    if !generate_hal_register_file(hal_dir) {
        return false
    }

    // Generate driver files (uart, dma, spi, i2c, systick, nvic, interrupts, sync, freestanding)
    if !generate_driver_files(device, memory, output_dir) {
        return false
    }

    // Generate peripheral files in cmsis/device/
    device_dir := fmt.tprintf("%s/cmsis/device", output_dir)
    for peripheral in device.peripherals {
        filename := fmt.tprintf("%s/%s.odin", device_dir, strings.to_lower(peripheral.name))
        if !generate_peripheral_file(peripheral, filename) {
            return false
        }
    }

    // Generate interrupts file in cmsis/device/
    if len(device.interrupts) > 0 {
        interrupts_file := fmt.tprintf("%s/interrupts.odin", device_dir)
        if !generate_interrupts_file(device, interrupts_file) {
            return false
        }
    }

    // Generate board code
    board_dir := fmt.tprintf("%s/board", output_dir)
    if !generate_board_code(board, device, board_dir) {
        return false
    }

    fmt.printfln("Generated %d peripheral files in %s/cmsis/device/", len(device.peripherals), output_dir)
    fmt.printfln("Generated hal/register.odin with generic register operations")
    fmt.printfln("Generated drivers in %s/drivers/", output_dir)
    fmt.printfln("Generated board code in %s/board/", output_dir)
    if len(device.interrupts) > 0 {
        fmt.printfln("Generated interrupts.odin with %d interrupts", len(device.interrupts))
    }
    return true
}

generate_peripheral_file :: proc(peripheral: Peripheral, filename: string) -> bool {
    builder := strings.builder_make()
    defer strings.builder_destroy(&builder)

    // Package and imports
    fmt.sbprintln(&builder, "package device")
    fmt.sbprintln(&builder)
    // Only import hal for non-derived peripherals (derived ones don't define registers)
    if len(peripheral.derived_from) == 0 {
        fmt.sbprintln(&builder, "import hal \"../../hal\"")
        fmt.sbprintln(&builder)
    }

    // Peripheral comment
    periph_desc := clean_description(peripheral.description)
    fmt.sbprintfln(&builder, "// %s - %s", peripheral.name, periph_desc)
    fmt.sbprintfln(&builder, "// Base address: 0x%08X", peripheral.base_address)

    // Check if this peripheral is derived from another
    if len(peripheral.derived_from) > 0 {
        fmt.sbprintfln(&builder, "// Derived from: %s", peripheral.derived_from)
    }
    fmt.sbprintln(&builder)

    // If derived, use parent's register structure; otherwise define our own
    if len(peripheral.derived_from) > 0 {
        // For derived peripherals, just define the base address and pointer
        fmt.sbprintfln(&builder, "%s_BASE :: 0x%08X", peripheral.name, peripheral.base_address)
        fmt.sbprintfln(&builder, "%s := cast(^%s_Registers)cast(uintptr)%s_BASE",
            peripheral.name, peripheral.derived_from, peripheral.name)
        fmt.sbprintln(&builder)
    } else {
        // Register structure - track expected offset to add padding for gaps
        fmt.sbprintfln(&builder, "%s_Registers :: struct {{", peripheral.name)
        expected_offset: u32 = 0
        reserved_count := 0
        for reg in peripheral.registers {
            comment := clean_description(reg.description)

            // Check if this is an array register
            if reg.dim > 0 {
                // Expand array into individual registers
                indices := parse_dim_index(reg.dim_index, reg.dim)
                for i in 0..<reg.dim {
                    idx_str := indices[i]
                    reg_name := expand_name(reg.name, idx_str)
                    offset := reg.offset + (u32(i) * reg.dim_increment)

                    // Add padding if there's a gap
                    for expected_offset < offset {
                        fmt.sbprintfln(&builder, "    _reserved%d: hal.Register,  // 0x%02X: reserved",
                            reserved_count, expected_offset)
                        reserved_count += 1
                        expected_offset += 4
                    }

                    fmt.sbprintfln(&builder, "    %s: hal.Register,  // 0x%02X: %s [%s]",
                        reg_name, offset, comment, idx_str)
                    expected_offset = offset + 4
                }
            } else {
                // Skip registers that share the same offset as a previous register
                // (these are typically alternate interpretations like CCMR1_Input/CCMR1_Output)
                if reg.offset < expected_offset {
                    continue
                }

                // Add padding if there's a gap
                for expected_offset < reg.offset {
                    fmt.sbprintfln(&builder, "    _reserved%d: hal.Register,  // 0x%02X: reserved",
                        reserved_count, expected_offset)
                    reserved_count += 1
                    expected_offset += 4
                }

                fmt.sbprintfln(&builder, "    %s: hal.Register,  // 0x%02X: %s", reg.name, reg.offset, comment)
                expected_offset = reg.offset + 4
            }
        }
        fmt.sbprintln(&builder, "}")
        fmt.sbprintln(&builder)

        // Peripheral pointer
        fmt.sbprintfln(&builder, "%s_BASE :: 0x%08X", peripheral.name, peripheral.base_address)
        fmt.sbprintfln(&builder, "%s := cast(^%s_Registers)cast(uintptr)%s_BASE",
            peripheral.name, peripheral.name, peripheral.name)
        fmt.sbprintln(&builder)

        // Generate enums and constants for each register
        for reg in peripheral.registers {
            if reg.dim > 0 {
                // For array registers, generate definitions for each element
                indices := parse_dim_index(reg.dim_index, reg.dim)
                for i in 0..<reg.dim {
                    idx_str := indices[i]
                    reg_copy := reg
                    reg_copy.name = expand_name(reg.name, idx_str)
                    reg_copy.offset = reg.offset + (u32(i) * reg.dim_increment)
                    reg_copy.dim = 0  // Mark as expanded
                    generate_register_definitions(&builder, peripheral.name, reg_copy)
                }
            } else {
                generate_register_definitions(&builder, peripheral.name, reg)
            }
        }
    }

    // Write to file
    data := strings.to_string(builder)
    ok := os.write_entire_file(filename, transmute([]byte)data)
    if !ok {
        fmt.eprintln("Failed to write file:", filename)
        return false
    }

    fmt.printfln("Generated: %s", filename)
    return true
}

generate_register_definitions :: proc(b: ^strings.Builder, periph_name: string, reg: Register) {
    // Generate field enums if they have enumerated values
    for field in reg.fields {
        if len(field.values) > 0 {
            // Create enum for this field
            enum_name := fmt.tprintf("%s_%s_%s", periph_name, reg.name, field.name)
            fmt.sbprintfln(b, "// %s values", field.name)
            fmt.sbprintfln(b, "%s :: enum u32 {{", enum_name)
            for enum_val in field.values {
                comment := clean_description(enum_val.description)
                fmt.sbprintfln(b, "    %s = %d,  // %s", enum_val.name, enum_val.value, comment)
            }
            fmt.sbprintln(b, "}")
            fmt.sbprintln(b)
        }
    }

    // Generate field position/mask constants
    for field in reg.fields {
        prefix := fmt.tprintf("%s_%s_%s", periph_name, reg.name, field.name)
        fmt.sbprintfln(b, "%s_Pos  :: %d", prefix, field.bit_offset)
        mask := (u32(1) << field.bit_width) - 1
        fmt.sbprintfln(b, "%s_Mask :: 0x%X", prefix, mask)
        fmt.sbprintfln(b, "%s_Mask_Shifted :: 0x%X << %s_Pos", prefix, mask, prefix)
        fmt.sbprintln(b)
    }
}

// Clean up description text (remove newlines, extra spaces, handle UTF-8)
clean_description :: proc(desc: string) -> string {
    if len(desc) == 0 {
        return ""
    }

    builder := strings.builder_make(0, len(desc))
    defer strings.builder_destroy(&builder)

    prev_was_space := false
    for r in desc {
        // Replace newlines, carriage returns, and tabs with space
        if r == '\n' || r == '\r' || r == '\t' {
            if !prev_was_space && strings.builder_len(builder) > 0 {
                strings.write_byte(&builder, ' ')
                prev_was_space = true
            }
            continue
        }

        // Skip control characters
        if r < ' ' || r == 0x7F {
            continue
        }

        // Only keep printable ASCII + common extended ASCII
        // This avoids any UTF-8 complications
        if r > 126 && r < 160 {
            continue  // Skip non-printable extended ASCII
        }

        // Handle spaces - collapse multiple into one
        if r == ' ' {
            if !prev_was_space && strings.builder_len(builder) > 0 {
                strings.write_byte(&builder, ' ')
                prev_was_space = true
            }
        } else {
            strings.write_byte(&builder, byte(r))
            prev_was_space = false
        }
    }

    result := strings.to_string(builder)
    result = strings.trim_space(result)

    // Truncate if too long
    if len(result) > 80 {
        // Make sure we don't cut in the middle of a word
        truncated := result[:77]
        return strings.clone(fmt.tprintf("%s...", truncated))
    }

    return strings.clone(result)
}

// Parse dimIndex string into individual indices
// Examples: "0,1,2,3" or "1-4" or "A,B,C,D"
parse_dim_index :: proc(dim_index: string, dim: u32) -> []string {
    indices := make([]string, dim)

    if dim_index == "" {
        // No dimIndex specified, generate 0, 1, 2, ...
        for i in 0..<dim {
            indices[i] = fmt.tprintf("%d", i)
        }
        return indices
    }

    // Check if it's a range (e.g., "0-3")
    if strings.contains(dim_index, "-") && !strings.contains(dim_index, ",") {
        // Pure range format (e.g., "0-3" means 0,1,2,3)
        range_parts := strings.split(dim_index, "-")
        defer delete(range_parts)
        if len(range_parts) == 2 {
            start, start_ok := strconv.parse_int(strings.trim_space(range_parts[0]))
            end, end_ok := strconv.parse_int(strings.trim_space(range_parts[1]))
            if start_ok && end_ok {
                for i in 0..<dim {
                    indices[i] = fmt.tprintf("%d", int(start) + int(i))
                }
                return indices
            }
        }
        // Fall through to comma-split if range parsing fails
    }

    // Split on comma
    parts := strings.split(dim_index, ",")
    defer delete(parts)
    for part, i in parts {
        if i < int(dim) {
            indices[i] = strings.trim_space(part)
        }
    }

    return indices
}

// Expand register name by replacing %s with index
// Examples: "CCR%s" -> "CCR1", "BKP%sR" -> "BKP0R"
// Sanitizes identifiers by replacing invalid characters with underscores
expand_name :: proc(name: string, index: string) -> string {
    result := strings.clone(name)
    result, _ = strings.replace_all(result, "%s", index)
    // Sanitize: replace hyphens with underscores for valid identifiers
    result, _ = strings.replace_all(result, "-", "_")
    return result
}

// Copy HAL register.odin from template
generate_hal_register_file :: proc(hal_dir: string) -> bool {
    // Get template directory (relative to svd2odin executable)
    exe_path := os.args[0]
    exe_dir := filepath.dir(exe_path)
    template_path := filepath.join({exe_dir, "hal_template", "register.odin"})

    // Read template
    template_data, ok := os.read_entire_file(template_path)
    if !ok {
        fmt.eprintfln("Failed to read HAL template: %s", template_path)
        return false
    }
    defer delete(template_data)

    // Write to destination
    dest_file := fmt.tprintf("%s/register.odin", hal_dir)
    write_ok := os.write_entire_file(dest_file, template_data)
    if !write_ok {
        fmt.eprintfln("Failed to write HAL register file: %s", dest_file)
        return false
    }

    return true
}

// Generate interrupts file with vector table
generate_interrupts_file :: proc(device: Device, filename: string) -> bool {
    builder := strings.builder_make()
    defer strings.builder_destroy(&builder)

    // Package declaration
    fmt.sbprintln(&builder, "package device")
    fmt.sbprintln(&builder)
    fmt.sbprintln(&builder, "// Interrupt definitions generated from SVD")
    fmt.sbprintln(&builder)

    // Sort interrupts by IRQ number for cleaner output
    sorted_interrupts := make([dynamic]Interrupt, len(device.interrupts))
    defer delete(sorted_interrupts)
    copy(sorted_interrupts[:], device.interrupts[:])
    slice.sort_by(sorted_interrupts[:], proc(a, b: Interrupt) -> bool {
        return a.value < b.value
    })

    // Generate interrupt enum
    fmt.sbprintln(&builder, "// Interrupt numbers")
    fmt.sbprintln(&builder, "Interrupt :: enum i32 {")
    for interrupt in sorted_interrupts {
        comment := clean_description(interrupt.description)
        if comment == "" {
            fmt.sbprintfln(&builder, "    %s = %d,", interrupt.name, interrupt.value)
        } else {
            fmt.sbprintfln(&builder, "    %s = %d,  // %s", interrupt.name, interrupt.value, comment)
        }
    }
    fmt.sbprintln(&builder, "}")
    fmt.sbprintln(&builder)

    // Generate interrupt handler type
    fmt.sbprintln(&builder, "// Interrupt handler function type")
    fmt.sbprintln(&builder, "Interrupt_Handler :: #type proc \"c\" ()")
    fmt.sbprintln(&builder)

    // Generate usage instructions
    fmt.sbprintln(&builder, "// Usage Example:")
    fmt.sbprintln(&builder, "//")
    fmt.sbprintln(&builder, "// 1. Define your interrupt handler:")
    fmt.sbprintln(&builder, "//    @(export)")
    fmt.sbprintln(&builder, "//    TIM1_UP_TIM16_IRQHandler :: proc \"c\" () {")
    fmt.sbprintln(&builder, "//        // Handle interrupt")
    fmt.sbprintln(&builder, "//    }")
    fmt.sbprintln(&builder, "//")
    fmt.sbprintln(&builder, "// 2. Add to vector table in startup code:")
    fmt.sbprintln(&builder, "//    See startup assembly file for vector table setup")
    fmt.sbprintln(&builder)

    // Generate interrupt constant names for reference
    fmt.sbprintln(&builder, "// Interrupt handler names (for reference)")
    fmt.sbprintln(&builder, "// Define these in your code and export them:")
    for interrupt in sorted_interrupts {
        fmt.sbprintfln(&builder, "// %s_IRQHandler :: proc \"c\" () {{ ... }}", interrupt.name)
    }
    fmt.sbprintln(&builder)

    // Write to file
    data := strings.to_string(builder)
    ok := os.write_entire_file(filename, transmute([]byte)data)
    if !ok {
        fmt.eprintln("Failed to write file:", filename)
        return false
    }

    fmt.printfln("Generated: %s", filename)
    return true
}

// Generate driver files (SPI, UART, DMA, I2C, Debug, Freestanding, and optionally RNG)
// These are portable drivers that work across all STM32 chips
generate_driver_files :: proc(device: Device, memory: Memory_Config, output_dir: string) -> bool {
    // Driver template mappings with destination paths
    Driver_Info :: struct {
        template: string,
        dest_dir: string,
    }

    drivers := make([dynamic]Driver_Info, 0, 10)
    defer delete(drivers)

    append(&drivers, Driver_Info{"uart", fmt.tprintf("%s/drivers/uart", output_dir)})
    append(&drivers, Driver_Info{"dma", fmt.tprintf("%s/drivers/dma", output_dir)})
    append(&drivers, Driver_Info{"spi", fmt.tprintf("%s/drivers/spi", output_dir)})
    append(&drivers, Driver_Info{"i2c", fmt.tprintf("%s/drivers/i2c", output_dir)})
    append(&drivers, Driver_Info{"i2s", fmt.tprintf("%s/drivers/i2s", output_dir)})
    append(&drivers, Driver_Info{"timer", fmt.tprintf("%s/drivers/timer", output_dir)})
    append(&drivers, Driver_Info{"rtc", fmt.tprintf("%s/drivers/rtc", output_dir)})
    append(&drivers, Driver_Info{"iwdg", fmt.tprintf("%s/drivers/iwdg", output_dir)})
    append(&drivers, Driver_Info{"wwdg", fmt.tprintf("%s/drivers/wwdg", output_dir)})
    append(&drivers, Driver_Info{"pwr", fmt.tprintf("%s/drivers/pwr", output_dir)})
    append(&drivers, Driver_Info{"exti", fmt.tprintf("%s/drivers/exti", output_dir)})
    append(&drivers, Driver_Info{"crc", fmt.tprintf("%s/drivers/crc", output_dir)})
    append(&drivers, Driver_Info{"systick", fmt.tprintf("%s/sys/systick", output_dir)})
    append(&drivers, Driver_Info{"nvic", fmt.tprintf("%s/sys/nvic", output_dir)})
    append(&drivers, Driver_Info{"interrupts", fmt.tprintf("%s/sys/interrupts", output_dir)})
    append(&drivers, Driver_Info{"freestanding", fmt.tprintf("%s/freestanding", output_dir)})

    // Add RNG driver if hardware RNG is available
    if device.has_rng {
        append(&drivers, Driver_Info{"rng", fmt.tprintf("%s/drivers/rng", output_dir)})
    }

    // Get template directory (relative to svd2odin executable)
    exe_path := os.args[0]
    exe_dir := filepath.dir(exe_path)
    template_base := filepath.join({exe_dir, "driver_templates"})

    for driver_info in drivers {
        // Destination
        dest_file := fmt.tprintf("%s/driver.odin", driver_info.dest_dir)

        // Source template file (relative to executable)
        // Special handling for UART: choose ISR or SR style based on device
        template_file := "driver.odin"
        if driver_info.template == "uart" {
            uses_isr := uart_uses_isr(device)
            template_file = uses_isr ? "driver_isr.odin" : "driver_sr.odin"
        }
        template_path := filepath.join({template_base, driver_info.template, template_file})

        // Read template file
        template_data, ok := os.read_entire_file(template_path)
        if !ok {
            fmt.eprintfln("Warning: Could not read driver template: %s", template_path)
            fmt.eprintfln("Skipping %s driver (template not found)", driver_info.template)
            continue
        }
        defer delete(template_data)

        // Special handling for freestanding driver: template arena size based on RAM
        output_data := template_data
        if driver_info.template == "freestanding" {
            // Arena uses RAM minus stack and guard region
            // Layout: [.data/.bss][arena][guard][stack]
            arena_size := memory.ram_size - memory.stack_size - memory.guard_size

            // Replace placeholders with calculated values
            template_str := string(template_data)

            // Replace heap size
            templated, _ := strings.replace_all(template_str,
                "heap_buffer: [64 * 1024]byte",
                fmt.tprintf("heap_buffer: [%d]byte", arena_size))

            // Replace guard size
            templated, _ = strings.replace_all(templated,
                "GUARD_SIZE :: 256",
                fmt.tprintf("GUARD_SIZE :: %d", memory.guard_size))

            // Replace HAS_MPU flag
            templated, _ = strings.replace_all(templated,
                "HAS_MPU :: false",
                fmt.tprintf("HAS_MPU :: %v", memory.has_mpu))

            output_data = transmute([]byte)templated
        }

        // Write to destination
        write_ok := os.write_entire_file(dest_file, output_data)
        if !write_ok {
            fmt.eprintfln("Failed to write driver file: %s", dest_file)
            return false
        }

        fmt.printfln("Generated: %s/driver.odin", driver_info.dest_dir)

        // Copy additional assembly files if they exist (e.g., pwr_asm.s)
        asm_file := fmt.tprintf("%s_asm.s", driver_info.template)
        asm_src := filepath.join({template_base, driver_info.template, asm_file})
        if asm_data, asm_ok := os.read_entire_file(asm_src); asm_ok {
            defer delete(asm_data)
            asm_dest := fmt.tprintf("%s/%s", driver_info.dest_dir, asm_file)
            if os.write_entire_file(asm_dest, asm_data) {
                fmt.printfln("Generated: %s", asm_dest)
            }
        }
    }

    return true
}

package svd2odin

import "core:fmt"
import "core:os"
import "core:strings"
import "core:strconv"

// Parse memory configuration from command-line args or config file
// Priority: 1. Command-line args, 2. Config file, 3. Error
parse_memory_config :: proc(svd_file: string, args: []string, device: Device) -> (config: Memory_Config, ok: bool) {
    // Try command-line args first
    if try_parse_args(&config, args) {
        fmt.println("Using memory config from command-line args")
    } else {
        // Try config file as fallback
        config_file := strings.concatenate({strings.trim_suffix(svd_file, ".svd"), ".config"})
        defer delete(config_file)

        if try_parse_config_file(&config, config_file) {
            fmt.printfln("Using memory config from: %s", config_file)
        } else {
            fmt.eprintln("Error: No memory configuration provided")
            fmt.eprintln("  Provide either:")
            fmt.eprintln("    --flash-origin=0x08000000 --flash-size=256K --ram-origin=0x20000000 --ram-size=40K")
            fmt.eprintln("  Or create a config file: <device>.config")
            return {}, false
        }
    }

    // Configure guard region based on MPU availability
    config.has_mpu = device.cpu.mpu
    if config.has_mpu {
        config.guard_size = 256  // MPU minimum practical size
        fmt.println("Stack overflow protection: MPU guard region (256 bytes)")
    } else {
        config.guard_size = 4    // Stack canary
        fmt.println("Stack overflow protection: Stack canary (4 bytes)")
    }

    return config, true
}

// Try to parse memory config from command-line arguments
try_parse_args :: proc(config: ^Memory_Config, args: []string) -> bool {
    flash_origin_set := false
    flash_size_set := false
    ram_origin_set := false
    ram_size_set := false

    for arg in args {
        if strings.has_prefix(arg, "--flash-origin=") {
            value_str := strings.trim_prefix(arg, "--flash-origin=")
            if value, ok := parse_hex_or_dec(value_str); ok {
                config.flash_origin = value
                flash_origin_set = true
            }
        } else if strings.has_prefix(arg, "--flash-size=") {
            value_str := strings.trim_prefix(arg, "--flash-size=")
            if value, ok := parse_size(value_str); ok {
                config.flash_size = value
                flash_size_set = true
            }
        } else if strings.has_prefix(arg, "--ram-origin=") {
            value_str := strings.trim_prefix(arg, "--ram-origin=")
            if value, ok := parse_hex_or_dec(value_str); ok {
                config.ram_origin = value
                ram_origin_set = true
            }
        } else if strings.has_prefix(arg, "--ram-size=") {
            value_str := strings.trim_prefix(arg, "--ram-size=")
            if value, ok := parse_size(value_str); ok {
                config.ram_size = value
                ram_size_set = true
            }
        } else if strings.has_prefix(arg, "--stack-size=") {
            value_str := strings.trim_prefix(arg, "--stack-size=")
            if value, ok := parse_size(value_str); ok {
                config.stack_size = value
            }
        }
    }

    // Default stack size if not specified: 8KB
    if config.stack_size == 0 {
        config.stack_size = 8 * 1024
    }

    return flash_origin_set && flash_size_set && ram_origin_set && ram_size_set
}

// Try to parse memory config from config file
try_parse_config_file :: proc(config: ^Memory_Config, filename: string) -> bool {
    data, ok := os.read_entire_file(filename)
    if !ok {
        return false
    }
    defer delete(data)

    content := string(data)
    lines := strings.split(content, "\n")
    defer delete(lines)

    flash_origin_set := false
    flash_size_set := false
    ram_origin_set := false
    ram_size_set := false

    for line in lines {
        trimmed := strings.trim_space(line)

        // Skip empty lines and comments
        if len(trimmed) == 0 || strings.has_prefix(trimmed, "#") {
            continue
        }

        parts := strings.split(trimmed, "=")
        if len(parts) != 2 {
            continue
        }
        defer delete(parts)

        key := strings.trim_space(parts[0])
        value := strings.trim_space(parts[1])

        switch key {
        case "flash_origin":
            if v, ok := parse_hex_or_dec(value); ok {
                config.flash_origin = v
                flash_origin_set = true
            }
        case "flash_size":
            if v, ok := parse_size(value); ok {
                config.flash_size = v
                flash_size_set = true
            }
        case "ram_origin":
            if v, ok := parse_hex_or_dec(value); ok {
                config.ram_origin = v
                ram_origin_set = true
            }
        case "ram_size":
            if v, ok := parse_size(value); ok {
                config.ram_size = v
                ram_size_set = true
            }
        case "stack_size":
            if v, ok := parse_size(value); ok {
                config.stack_size = v
            }
        }
    }

    // Default stack size if not specified: 8KB
    if config.stack_size == 0 {
        config.stack_size = 8 * 1024
    }

    return flash_origin_set && flash_size_set && ram_origin_set && ram_size_set
}

// Parse hex (0x...) or decimal number
parse_hex_or_dec :: proc(s: string) -> (value: u32, ok: bool) {
    if strings.has_prefix(s, "0x") || strings.has_prefix(s, "0X") {
        hex_str := strings.trim_prefix(s, "0x")
        hex_str = strings.trim_prefix(hex_str, "0X")
        val, success := strconv.parse_u64_of_base(hex_str, 16)
        return u32(val), success
    }
    val, success := strconv.parse_u64(s)
    return u32(val), success
}

// Parse size with K/M suffix (e.g., "256K", "1M")
parse_size :: proc(s: string) -> (value: u32, ok: bool) {
    if strings.has_suffix(s, "K") || strings.has_suffix(s, "k") {
        num_str := strings.trim_suffix(s, "K")
        num_str = strings.trim_suffix(num_str, "k")
        num, success := strconv.parse_u64(num_str)
        return u32(num * 1024), success
    } else if strings.has_suffix(s, "M") || strings.has_suffix(s, "m") {
        num_str := strings.trim_suffix(s, "M")
        num_str = strings.trim_suffix(num_str, "m")
        num, success := strconv.parse_u64(num_str)
        return u32(num * 1024 * 1024), success
    }
    // No suffix, parse as bytes
    num, success := strconv.parse_u64(s)
    return u32(num), success
}

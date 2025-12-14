package debug

import uart "../../drivers/uart"

// Debug output via UART
// Simple printf-style debugging for embedded systems
// The init() function is generated separately in init.odin based on board config

// Shared state (initialized by generated init.odin)
debug_uart: uart.UART_Handle
debug_initialized := false

// Print string (no newline)
print :: proc "c" (str: string) {
    if !debug_initialized { return }
    uart.uart_transmit_string(&debug_uart, str)
}

// Print string with newline
println :: proc "c" (str: string) {
    if !debug_initialized { return }
    uart.uart_transmit_string(&debug_uart, str)
    uart.uart_transmit_string(&debug_uart, "\r\n")
}

// Print single character
putc :: proc "c" (ch: u8) {
    if !debug_initialized { return }
    uart.uart_transmit_byte(&debug_uart, ch)
}

// Helper: Convert u32 to decimal string
u32_to_decimal :: proc "c" (value: u32, buffer: []u8) -> int {
    if value == 0 {
        buffer[0] = '0'
        return 1
    }

    // Count digits
    temp := value
    digit_count := 0
    for temp > 0 {
        temp /= 10
        digit_count += 1
    }

    // Fill buffer backwards
    temp = value
    for i := digit_count - 1; i >= 0; i -= 1 {
        buffer[i] = u8('0' + (temp % 10))
        temp /= 10
    }

    return digit_count
}

// Helper: Convert i32 to decimal string
i32_to_decimal :: proc "c" (value: i32, buffer: []u8) -> int {
    if value < 0 {
        buffer[0] = '-'
        len := u32_to_decimal(u32(-value), buffer[1:])
        return len + 1
    }
    return u32_to_decimal(u32(value), buffer)
}

// Helper: Convert u32 to hex string
u32_to_hex :: proc "c" (value: u32, buffer: []u8, uppercase: bool) -> int {
    hex_chars_lower := "0123456789abcdef"
    hex_chars_upper := "0123456789ABCDEF"
    hex_chars := uppercase ? hex_chars_upper : hex_chars_lower

    if value == 0 {
        buffer[0] = '0'
        return 1
    }

    // Count hex digits
    temp := value
    digit_count := 0
    for temp > 0 {
        temp >>= 4
        digit_count += 1
    }

    // Fill buffer backwards
    temp = value
    for i := digit_count - 1; i >= 0; i -= 1 {
        buffer[i] = hex_chars[temp & 0xF]
        temp >>= 4
    }

    return digit_count
}

// Helper: Convert u64 to decimal string
u64_to_decimal :: proc "c" (value: u64, buffer: []u8) -> int {
    if value == 0 {
        buffer[0] = '0'
        return 1
    }

    temp := value
    digit_count := 0
    for temp > 0 {
        temp /= 10
        digit_count += 1
    }

    temp = value
    for i := digit_count - 1; i >= 0; i -= 1 {
        buffer[i] = u8('0' + (temp % 10))
        temp /= 10
    }

    return digit_count
}

// Helper: Convert i64 to decimal string
i64_to_decimal :: proc "c" (value: i64, buffer: []u8) -> int {
    if value < 0 {
        buffer[0] = '-'
        len := u64_to_decimal(u64(-value), buffer[1:])
        return len + 1
    }
    return u64_to_decimal(u64(value), buffer)
}

// Print helpers (no RTTI required)
print_u32 :: proc "c" (value: u32) {
    if !debug_initialized { return }
    buffer: [16]u8
    len := u32_to_decimal(value, buffer[:])
    for i in 0..<len {
        putc(buffer[i])
    }
}

print_i32 :: proc "c" (value: i32) {
    if !debug_initialized { return }
    buffer: [16]u8
    len := i32_to_decimal(value, buffer[:])
    for i in 0..<len {
        putc(buffer[i])
    }
}

print_hex :: proc "c" (value: u32) {
    if !debug_initialized { return }
    buffer: [16]u8
    len := u32_to_hex(value, buffer[:], true)
    for i in 0..<len {
        putc(buffer[i])
    }
}

// Print u32 as exactly 8 hex digits (e.g., 0000FFFF)
print_hex32 :: proc "c" (value: u32) {
    if !debug_initialized { return }
    hex_chars := "0123456789ABCDEF"
    for i := 7; i >= 0; i -= 1 {
        nibble := (value >> (u32(i) * 4)) & 0xF
        putc(hex_chars[nibble])
    }
}

// Print byte as exactly 2 hex digits (e.g., 0A, FF)
print_hex_byte :: proc "c" (value: u8) {
    if !debug_initialized { return }
    hex_chars := "0123456789ABCDEF"
    putc(hex_chars[value >> 4])
    putc(hex_chars[value & 0x0F])
}

print_u8 :: proc "c" (value: u8) {
    print_u32(u32(value))
}

print_i8 :: proc "c" (value: i8) {
    print_i32(i32(value))
}

print_u16 :: proc "c" (value: u16) {
    print_u32(u32(value))
}

print_i16 :: proc "c" (value: i16) {
    print_i32(i32(value))
}

print_u64 :: proc "c" (value: u64) {
    if !debug_initialized { return }
    buffer: [32]u8
    len := u64_to_decimal(value, buffer[:])
    for i in 0..<len {
        putc(buffer[i])
    }
}

print_i64 :: proc "c" (value: i64) {
    if !debug_initialized { return }
    buffer: [32]u8
    len := i64_to_decimal(value, buffer[:])
    for i in 0..<len {
        putc(buffer[i])
    }
}

print_int :: proc "c" (value: int) {
    print_i32(i32(value))
}

print_uint :: proc "c" (value: uint) {
    print_u32(u32(value))
}

// Write raw bytes (bulk write - more efficient than putc loop)
write_bytes :: proc "c" (data: []u8) {
    if !debug_initialized { return }
    uart.uart_transmit(&debug_uart, data)
}

// Simple string builder for bare metal (no allocations, no RTTI)
String_Builder :: struct {
    buffer: []u8,
    len: int,
}

builder_init :: proc "c" (b: ^String_Builder, buffer: []u8) {
    b.buffer = buffer
    b.len = 0
}

builder_reset :: proc "c" (b: ^String_Builder) {
    b.len = 0
}

builder_append_string :: proc "c" (b: ^String_Builder, str: string) {
    for i in 0..<len(str) {
        if b.len < len(b.buffer) {
            b.buffer[b.len] = str[i]
            b.len += 1
        }
    }
}

builder_append_u32 :: proc "c" (b: ^String_Builder, value: u32) {
    temp: [16]u8
    digit_count := u32_to_decimal(value, temp[:])
    for i in 0..<digit_count {
        if b.len < len(b.buffer) {
            b.buffer[b.len] = temp[i]
            b.len += 1
        }
    }
}

builder_append_i32 :: proc "c" (b: ^String_Builder, value: i32) {
    temp: [16]u8
    digit_count := i32_to_decimal(value, temp[:])
    for i in 0..<digit_count {
        if b.len < len(b.buffer) {
            b.buffer[b.len] = temp[i]
            b.len += 1
        }
    }
}

builder_append_hex :: proc "c" (b: ^String_Builder, value: u32, uppercase := true) {
    temp: [16]u8
    digit_count := u32_to_hex(value, temp[:], uppercase)
    for i in 0..<digit_count {
        if b.len < len(b.buffer) {
            b.buffer[b.len] = temp[i]
            b.len += 1
        }
    }
}

builder_append_u8 :: proc "c" (b: ^String_Builder, value: u8) {
    builder_append_u32(b, u32(value))
}

builder_append_i8 :: proc "c" (b: ^String_Builder, value: i8) {
    builder_append_i32(b, i32(value))
}

builder_append_u16 :: proc "c" (b: ^String_Builder, value: u16) {
    builder_append_u32(b, u32(value))
}

builder_append_i16 :: proc "c" (b: ^String_Builder, value: i16) {
    builder_append_i32(b, i32(value))
}

builder_append_int :: proc "c" (b: ^String_Builder, value: int) {
    builder_append_i32(b, i32(value))
}

builder_append_uint :: proc "c" (b: ^String_Builder, value: uint) {
    builder_append_u32(b, u32(value))
}

builder_append_u64 :: proc "c" (b: ^String_Builder, value: u64) {
    temp: [32]u8
    digit_count := u64_to_decimal(value, temp[:])
    for i in 0..<digit_count {
        if b.len < len(b.buffer) {
            b.buffer[b.len] = temp[i]
            b.len += 1
        }
    }
}

builder_append_i64 :: proc "c" (b: ^String_Builder, value: i64) {
    temp: [32]u8
    digit_count := i64_to_decimal(value, temp[:])
    for i in 0..<digit_count {
        if b.len < len(b.buffer) {
            b.buffer[b.len] = temp[i]
            b.len += 1
        }
    }
}

builder_flush :: proc "c" (b: ^String_Builder) {
    if !debug_initialized { return }
    if b.len > 0 {
        write_bytes(b.buffer[:b.len])
    }
}

builder_append :: proc{
    builder_append_string,
    builder_append_u8,
    builder_append_i8,
    builder_append_u16,
    builder_append_i16,
    builder_append_u32,
    builder_append_i32,
    builder_append_u64,
    builder_append_i64,
    builder_append_int,
    builder_append_uint,
}

// Hex dump helper
hex_dump :: proc "c" (data: []u8, bytes_per_line: int) {
    if !debug_initialized { return }

    buffer: [16]u8

    for i := 0; i < len(data); i += bytes_per_line {
        offset_len := u32_to_hex(u32(i), buffer[:], true)
        for j in 0..<offset_len {
            putc(buffer[j])
        }
        print(": ")

        end := i + bytes_per_line
        if end > len(data) { end = len(data) }

        for j in i..<end {
            hex_len := u32_to_hex(u32(data[j]), buffer[:], true)
            if hex_len == 1 { putc('0') }
            for k in 0..<hex_len {
                putc(buffer[k])
            }
            putc(' ')
        }

        print(" | ")
        for j in i..<end {
            ch := data[j]
            if ch >= 32 && ch <= 126 {
                putc(ch)
            } else {
                putc('.')
            }
        }

        print("\r\n")
    }
}

// Get UART handle (for direct access if needed)
get_uart_handle :: proc "c" () -> ^uart.UART_Handle {
    return &debug_uart
}

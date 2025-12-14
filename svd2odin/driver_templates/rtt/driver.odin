package rtt

import "base:intrinsics"

// SEGGER RTT (Real-Time Transfer) Driver
// High-speed debug I/O via debug probe (J-Link, ST-Link+OpenOCD, etc.)
// No pins required - uses SWD/JTAG interface
//
// Usage:
//   rtt.init()
//   rtt.print("Hello RTT!\n")
//   rtt.println("Value: ", 42)
//
// To view output:
//   JLinkRTTViewer, OpenOCD with RTT, probe-rs, or pyOCD

// RTT Configuration
MAX_UP_BUFFERS   :: 1  // Target -> Host buffers (usually just Terminal)
MAX_DOWN_BUFFERS :: 1  // Host -> Target buffers (for input)
BUFFER_SIZE_UP   :: 1024  // Output buffer size (adjust based on RAM)
BUFFER_SIZE_DOWN :: 64    // Input buffer size

// RTT Buffer Descriptor
// Describes a ring buffer for communication
RTT_Buffer :: struct {
    name:        cstring,  // Name of buffer (shown in viewer)
    buffer:      [^]u8,    // Pointer to ring buffer data
    size:        u32,      // Size of buffer in bytes
    wr_off:      u32,      // Write offset (target writes, host reads for UP)
    rd_off:      u32,      // Read offset (host writes for UP, target reads for DOWN)
    flags:       u32,      // Mode flags
}

// RTT Control Block
// Debug probe searches RAM for this structure via the ID string
// MUST be aligned and placed in a known memory region
RTT_Control_Block :: struct {
    id:            [16]u8,                        // ID: "SEGGER RTT\0\0\0\0\0\0"
    max_up:        u32,                           // Number of up buffers
    max_down:      u32,                           // Number of down buffers
    up_buffers:    [MAX_UP_BUFFERS]RTT_Buffer,    // Up (target->host) buffers
    down_buffers:  [MAX_DOWN_BUFFERS]RTT_Buffer,  // Down (host->target) buffers
}

// Buffer mode flags
RTT_MODE_NO_BLOCK_SKIP  :: 0  // Skip if buffer full (default, non-blocking)
RTT_MODE_NO_BLOCK_TRIM  :: 1  // Trim data if buffer full
RTT_MODE_BLOCK_IF_FULL  :: 2  // Block until space available (use with caution!)

// RTT Control Block instance
// The ID string "SEGGER RTT" allows debug probes to find this in RAM
// Must NOT be in .bss (zeroed) - use explicit initialization
// @(export) prevents dead-code elimination so probe can find it
@(export)
_SEGGER_RTT: RTT_Control_Block = {
    id = {'S', 'E', 'G', 'G', 'E', 'R', ' ', 'R', 'T', 'T', 0, 0, 0, 0, 0, 0},
    max_up = MAX_UP_BUFFERS,
    max_down = MAX_DOWN_BUFFERS,
    up_buffers = {},
    down_buffers = {},
}

// Ring buffer storage (separate from control block)
up_buffer_0:   [BUFFER_SIZE_UP]u8
down_buffer_0: [BUFFER_SIZE_DOWN]u8

// Buffer name strings
up_name_0:   cstring = "Terminal"
down_name_0: cstring = "Terminal"

// Initialization state
rtt_initialized := false

// Initialize RTT
// Must be called before using any RTT functions
init :: proc "c" () {
    if rtt_initialized { return }

    // Configure up buffer 0 (Terminal output)
    _SEGGER_RTT.up_buffers[0] = RTT_Buffer{
        name   = up_name_0,
        buffer = &up_buffer_0[0],
        size   = BUFFER_SIZE_UP,
        wr_off = 0,
        rd_off = 0,
        flags  = RTT_MODE_NO_BLOCK_SKIP,
    }

    // Configure down buffer 0 (Terminal input)
    _SEGGER_RTT.down_buffers[0] = RTT_Buffer{
        name   = down_name_0,
        buffer = &down_buffer_0[0],
        size   = BUFFER_SIZE_DOWN,
        wr_off = 0,
        rd_off = 0,
        flags  = RTT_MODE_NO_BLOCK_SKIP,
    }

    // Memory barrier to ensure control block is visible
    intrinsics.atomic_thread_fence(.Seq_Cst)

    rtt_initialized = true
}

// Get available space in up buffer
get_avail_write_space :: proc "c" (buffer_index: u32) -> u32 {
    if buffer_index >= MAX_UP_BUFFERS { return 0 }

    buf := &_SEGGER_RTT.up_buffers[buffer_index]
    rd := intrinsics.volatile_load(&buf.rd_off)
    wr := intrinsics.volatile_load(&buf.wr_off)

    if rd <= wr {
        // rd...wr...end, available = (size - wr) + (rd - 1)
        return (buf.size - wr) + rd - 1
    } else {
        // wr...rd, available = rd - wr - 1
        return rd - wr - 1
    }
}

// Write data to up buffer (target -> host)
// Returns number of bytes written
write :: proc "c" (buffer_index: u32, data: []u8) -> u32 {
    if !rtt_initialized { return 0 }
    if buffer_index >= MAX_UP_BUFFERS { return 0 }
    if len(data) == 0 { return 0 }

    buf := &_SEGGER_RTT.up_buffers[buffer_index]
    avail := get_avail_write_space(buffer_index)

    // In skip mode, drop data if not enough space
    if avail < u32(len(data)) {
        if buf.flags == RTT_MODE_NO_BLOCK_SKIP {
            return 0  // Skip entire message
        } else if buf.flags == RTT_MODE_BLOCK_IF_FULL {
            // Block until space available (busy wait - use carefully!)
            for avail < u32(len(data)) {
                avail = get_avail_write_space(buffer_index)
            }
        }
        // MODE_NO_BLOCK_TRIM: fall through and write what we can
    }

    num_bytes := u32(len(data))
    if num_bytes > avail {
        num_bytes = avail
    }

    wr := intrinsics.volatile_load(&buf.wr_off)

    // Write data to ring buffer
    for i: u32 = 0; i < num_bytes; i += 1 {
        buf.buffer[wr] = data[i]
        wr += 1
        if wr >= buf.size {
            wr = 0  // Wrap around
        }
    }

    // Update write offset (memory barrier for visibility)
    intrinsics.atomic_thread_fence(.Release)
    intrinsics.volatile_store(&buf.wr_off, wr)

    return num_bytes
}

// Write single byte to up buffer
write_byte :: proc "c" (buffer_index: u32, byte: u8) -> bool {
    buf: [1]u8 = {byte}
    return write(buffer_index, buf[:]) == 1
}

// Check if data available in down buffer
has_data :: proc "c" (buffer_index: u32) -> bool {
    if buffer_index >= MAX_DOWN_BUFFERS { return false }

    buf := &_SEGGER_RTT.down_buffers[buffer_index]
    rd := intrinsics.volatile_load(&buf.rd_off)
    wr := intrinsics.volatile_load(&buf.wr_off)

    return rd != wr
}

// Read data from down buffer (host -> target)
// Returns number of bytes read
read :: proc "c" (buffer_index: u32, data: []u8) -> u32 {
    if !rtt_initialized { return 0 }
    if buffer_index >= MAX_DOWN_BUFFERS { return 0 }
    if len(data) == 0 { return 0 }

    buf := &_SEGGER_RTT.down_buffers[buffer_index]
    rd := intrinsics.volatile_load(&buf.rd_off)
    wr := intrinsics.volatile_load(&buf.wr_off)

    // Calculate available data
    avail: u32
    if wr >= rd {
        avail = wr - rd
    } else {
        avail = buf.size - rd + wr
    }

    if avail == 0 { return 0 }

    num_bytes := u32(len(data))
    if num_bytes > avail {
        num_bytes = avail
    }

    // Read data from ring buffer
    for i: u32 = 0; i < num_bytes; i += 1 {
        data[i] = buf.buffer[rd]
        rd += 1
        if rd >= buf.size {
            rd = 0  // Wrap around
        }
    }

    // Update read offset
    intrinsics.atomic_thread_fence(.Acquire)
    intrinsics.volatile_store(&buf.rd_off, rd)

    return num_bytes
}

// Read single byte from down buffer
// Returns byte and true if available, 0 and false otherwise
read_byte :: proc "c" (buffer_index: u32) -> (u8, bool) {
    buf: [1]u8
    if read(buffer_index, buf[:]) == 1 {
        return buf[0], true
    }
    return 0, false
}

// ============================================================================
// Convenience functions for Terminal (buffer 0)
// ============================================================================

// Print string to Terminal
print :: proc "c" (str: string) {
    write(0, transmute([]u8)str)
}

// Print string with newline
println :: proc "c" (str: string) {
    print(str)
    print("\r\n")
}

// Print single character
putc :: proc "c" (ch: u8) {
    write_byte(0, ch)
}

// Write raw bytes
write_bytes :: proc "c" (data: []u8) {
    write(0, data)
}

// ============================================================================
// Number printing helpers
// ============================================================================

// Helper: Convert u32 to decimal string
u32_to_decimal :: proc "c" (value: u32, buffer: []u8) -> int {
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

    temp := value
    digit_count := 0
    for temp > 0 {
        temp >>= 4
        digit_count += 1
    }

    temp = value
    for i := digit_count - 1; i >= 0; i -= 1 {
        buffer[i] = hex_chars[temp & 0xF]
        temp >>= 4
    }

    return digit_count
}

// Print u32
print_u32 :: proc "c" (value: u32) {
    buffer: [16]u8
    len := u32_to_decimal(value, buffer[:])
    write(0, buffer[:len])
}

// Print i32
print_i32 :: proc "c" (value: i32) {
    buffer: [16]u8
    len := i32_to_decimal(value, buffer[:])
    write(0, buffer[:len])
}

// Print hex
print_hex :: proc "c" (value: u32) {
    buffer: [16]u8
    len := u32_to_hex(value, buffer[:], true)
    write(0, buffer[:len])
}

// Print u32 as exactly 8 hex digits
print_hex32 :: proc "c" (value: u32) {
    hex_chars := "0123456789ABCDEF"
    for i := 7; i >= 0; i -= 1 {
        nibble := (value >> (u32(i) * 4)) & 0xF
        putc(hex_chars[nibble])
    }
}

// Print byte as exactly 2 hex digits
print_hex_byte :: proc "c" (value: u8) {
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

print_int :: proc "c" (value: int) {
    print_i32(i32(value))
}

print_uint :: proc "c" (value: uint) {
    print_u32(u32(value))
}

// ============================================================================
// Input functions
// ============================================================================

// Check if input available
input_available :: proc "c" () -> bool {
    return has_data(0)
}

// Read single character (non-blocking)
// Returns character and true if available, 0 and false otherwise
getc :: proc "c" () -> (u8, bool) {
    return read_byte(0)
}

// Read line into buffer (blocking until newline or buffer full)
// Returns number of characters read (not including newline)
read_line :: proc "c" (buffer: []u8) -> int {
    idx := 0
    for idx < len(buffer) - 1 {
        ch, ok := getc()
        if !ok {
            continue  // Spin waiting for input
        }

        if ch == '\r' || ch == '\n' {
            break
        }

        buffer[idx] = ch
        idx += 1
    }
    buffer[idx] = 0  // Null terminate
    return idx
}

// ============================================================================
// Buffer configuration
// ============================================================================

// Set buffer mode
set_mode :: proc "c" (buffer_index: u32, mode: u32) {
    if buffer_index < MAX_UP_BUFFERS {
        _SEGGER_RTT.up_buffers[buffer_index].flags = mode
    }
}

// Get RTT control block address (for debugging)
get_control_block :: proc "c" () -> ^RTT_Control_Block {
    return &_SEGGER_RTT
}

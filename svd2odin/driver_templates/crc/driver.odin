package crc

import hal "../../hal"
import device "../../cmsis/device"

// Hardware CRC driver
// STM32 has built-in CRC-32 calculator (same polynomial as Ethernet/ZIP)

// Initialize CRC peripheral
crc_init :: proc "c" () {
    // Enable CRC clock
    hal.reg_modify(&device.RCC.AHBENR, .Set, device.RCC_AHBENR_CRCEN_Mask_Shifted)
}

// Reset CRC to initial value (0xFFFFFFFF)
crc_reset :: proc "c" () {
    hal.reg_modify(&device.CRC.CR, .Set, 1)  // RESET bit
}

// Feed a 32-bit word into CRC
crc_write :: proc "c" (data: u32) {
    hal.reg_write(&device.CRC.DR, data)
}

// Feed a byte into CRC (F3 supports byte access)
crc_write_byte :: proc "c" (data: u8) {
    // Write to DR as byte (uses DR8 alias at same address)
    ptr := cast(^u8)&device.CRC.DR
    ptr^ = data
}

// Get current CRC value
crc_read :: proc "c" () -> u32 {
    return hal.reg_read(&device.CRC.DR)
}

// Calculate CRC of a buffer (32-bit aligned)
crc_calculate :: proc "c" (data: [^]u32, len: u32) -> u32 {
    crc_reset()
    for i in 0..<len {
        crc_write(data[i])
    }
    return crc_read()
}

// Calculate CRC of a byte buffer
crc_calculate_bytes :: proc "c" (data: [^]u8, len: u32) -> u32 {
    crc_reset()

    // Process 32-bit words first
    words := len / 4
    word_ptr := cast([^]u32)data
    for i in 0..<words {
        crc_write(word_ptr[i])
    }

    // Process remaining bytes
    remaining := len % 4
    if remaining > 0 {
        base := words * 4
        for i in 0..<remaining {
            crc_write_byte(data[base + i])
        }
    }

    return crc_read()
}

// Set custom initial value (F3 feature)
crc_set_init :: proc "c" (init_val: u32) {
    hal.reg_write(&device.CRC.INIT, init_val)
}

// Set custom polynomial (F3 feature)
crc_set_polynomial :: proc "c" (poly: u32) {
    hal.reg_write(&device.CRC.POL, poly)
}

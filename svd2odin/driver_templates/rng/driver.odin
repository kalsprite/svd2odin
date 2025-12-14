package rng

import hal "../hal"
import stm32 ".."

// Hardware Random Number Generator driver
// Uses STM32 TRNG peripheral (analog circuit-based)
// ONLY generated when RNG peripheral detected in SVD

// Initialize RNG peripheral
// Must be called before using get_u32()
init :: proc "c" () {
    // Enable RNG peripheral clock
    // Note: RNG is typically on AHB2 for F2/F4/F7/H7
    hal.reg_modify(&stm32.RCC.AHB2ENR, .Set,
        stm32.RCC_AHB2ENR_RNGEN_Mask_Shifted)

    // Enable RNG
    hal.reg_modify(&stm32.RNG.CR, .Set,
        stm32.RNG_CR_RNGEN_Mask_Shifted)
}

// Get 32-bit hardware random number
// Blocks until data is ready
// Returns cryptographically secure random value from analog noise
get_u32 :: proc "c" () -> u32 {
    // Wait for data ready flag
    for {
        sr := hal.reg_read(&stm32.RNG.SR)
        if (sr & stm32.RNG_SR_DRDY_Mask_Shifted) != 0 {
            break
        }
    }

    // Read random data
    return hal.reg_read(&stm32.RNG.DR)
}

// Check if data is ready (non-blocking)
data_ready :: proc "c" () -> bool {
    sr := hal.reg_read(&stm32.RNG.SR)
    return (sr & stm32.RNG_SR_DRDY_Mask_Shifted) != 0
}

// Get random number without blocking
// Returns (value, ok) where ok indicates if data was ready
try_get_u32 :: proc "c" () -> (value: u32, ok: bool) {
    if !data_ready() {
        return 0, false
    }
    return hal.reg_read(&stm32.RNG.DR), true
}

// Fill buffer with random bytes
fill :: proc "c" (buffer: []u8) {
    // Fill word-aligned portion
    word_count := len(buffer) / 4
    for i in 0..<word_count {
        rnd := get_u32()
        buffer[i*4 + 0] = u8(rnd >> 0)
        buffer[i*4 + 1] = u8(rnd >> 8)
        buffer[i*4 + 2] = u8(rnd >> 16)
        buffer[i*4 + 3] = u8(rnd >> 24)
    }

    // Fill remaining bytes
    remainder := len(buffer) % 4
    if remainder > 0 {
        rnd := get_u32()
        offset := word_count * 4
        for i in 0..<remainder {
            buffer[offset + i] = u8(rnd >> (i * 8))
        }
    }
}

// Get 8-bit random number
get_u8 :: proc "c" () -> u8 {
    return u8(get_u32())
}

// Get 16-bit random number
get_u16 :: proc "c" () -> u16 {
    return u16(get_u32())
}

// Get 64-bit random number
get_u64 :: proc "c" () -> u64 {
    low := u64(get_u32())
    high := u64(get_u32())
    return (high << 32) | low
}

// Check for errors
// Returns true if seed error or clock error detected
has_error :: proc "c" () -> bool {
    sr := hal.reg_read(&stm32.RNG.SR)
    // Check SEIS (seed error) and CEIS (clock error)
    return (sr & (1 << 6)) != 0 || (sr & (1 << 5)) != 0
}

// Clear error flags
clear_errors :: proc "c" () {
    // Writing SR clears error flags
    hal.reg_write(&stm32.RNG.SR, 0)
}

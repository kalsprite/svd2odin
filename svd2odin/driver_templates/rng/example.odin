// Example: Using the Hardware RNG driver
// This demonstrates the RNG API for STM32 chips with hardware TRNG
// Works on: F2, F4 (except F401/F411), F7, H7, G4, L4, L5, U5

package main

import rng "stm32f4/rng"  // Adjust import for your chip
import debug "stm32f4/debug"

@(export)
app_main :: proc "c" () {
    // Initialize debug output
    debug.init(.Baud115200)
    debug.println("STM32 Hardware RNG Example")
    debug.println("==========================")

    // Initialize RNG peripheral
    rng.init()

    // Example 1: Get single 32-bit random number
    random_value := rng.get_u32()
    debug.printf("Random u32: 0x%X\r\n", random_value)

    // Example 2: Get different sized random numbers
    random_u8 := rng.get_u8()
    random_u16 := rng.get_u16()
    random_u64 := rng.get_u64()
    debug.printf("Random u8:  0x%X\r\n", u32(random_u8))
    debug.printf("Random u16: 0x%X\r\n", u32(random_u16))
    debug.printf("Random u64: 0x%X\r\n", random_u64)

    // Example 3: Fill buffer with random bytes
    buffer: [16]u8
    rng.fill(buffer[:])
    debug.print("Random buffer: ")
    for b in buffer {
        debug.printf("%X ", u32(b))
    }
    debug.println("")

    // Example 4: Non-blocking read
    if value, ok := rng.try_get_u32(); ok {
        debug.printf("Got value: 0x%X\r\n", value)
    } else {
        debug.println("Data not ready yet")
    }

    // Example 5: Generate random number in range [0, max)
    max :: 100
    random_in_range := rng.get_u32() % max
    debug.printf("Random 0-%d: %d\r\n", max-1, random_in_range)

    // Example 6: Check for errors (rare)
    if rng.has_error() {
        debug.println("RNG error detected!")
        rng.clear_errors()
    }

    debug.println("\r\nDone!")

    for {} // Infinite loop
}

// Use cases:
// - Cryptographic keys
// - UUIDs / unique IDs
// - Session tokens
// - IV generation
// - Challenge-response protocols
// - Random delays (timing attack mitigation)

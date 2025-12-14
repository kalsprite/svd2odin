// Gyroscope (L3GD20) Example
// Reads gyroscope data via SPI on F303 Discovery
// Note: This example requires l3gd20.odin in the same package
package main

import freestanding "stm32/freestanding"
import board "stm32/board"
import debug "stm32/board/debug"
import systick "stm32/sys/systick"

@(export)
app_main :: proc() {
    freestanding.init()
    systick.systick_init(1000, 8_000_000)
    board.init()

    systick.systick_delay_ms(100)

    debug.println("STM32F303 Discovery - Gyroscope Example")
    debug.println("========================================")
    debug.println("L3GD20 3-axis Gyroscope (SPI)")
    debug.println("")

    // Initialize SPI for gyroscope
    debug.print("Initializing SPI1... ")
    if !gyro_init() {
        debug.println("FAIL")
        for {}
    }
    debug.println("OK")

    // Verify gyroscope ID
    debug.print("Verifying gyroscope... ")
    if gyro_verify() {
        debug.println("OK (L3GD20)")
    } else {
        debug.println("FAIL - check WHO_AM_I")
        for {}
    }

    // Enable gyroscope
    debug.print("Enabling gyroscope... ")
    if gyro_enable() {
        debug.println("OK (95Hz, 250dps)")
    } else {
        debug.println("FAIL")
    }

    debug.println("")
    debug.println("Reading gyroscope data:")
    debug.println("(values in raw counts, ~8.75 mdps/count at 250dps)")
    debug.println("")

    led_idx := 0
    leds := [8]board.GPIO_Pin{
        .LD3, .LD5, .LD7, .LD9, .LD10, .LD8, .LD6, .LD4,
    }

    for {
        // Read and print gyroscope data
        gyro_print_state()

        // Rotate LED to show activity
        board.gpio_clear(leds[led_idx])
        led_idx = (led_idx + 1) % 8
        board.gpio_set(leds[led_idx])

        systick.systick_delay_ms(100)
    }
}

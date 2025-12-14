// IMU (Accelerometer + Magnetometer) Example
// Reads LSM303DLHC sensor data on F303 Discovery
// Note: This example requires lsm303.odin in the same package
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

    debug.println("STM32F303 Discovery - IMU Example")
    debug.println("==================================")
    debug.println("LSM303DLHC Accelerometer + Magnetometer")
    debug.println("")

    // Initialize I2C for sensors
    debug.print("Initializing I2C... ")
    if !accel_init() {
        debug.println("FAIL")
        for {}
    }
    debug.println("OK")

    // Verify magnetometer ID
    debug.print("Verifying magnetometer... ")
    if mag_verify() {
        debug.println("OK (ID: H43)")
    } else {
        debug.println("FAIL")
    }

    // Enable sensors
    debug.print("Enabling accelerometer... ")
    if accel_enable() {
        debug.println("OK (100Hz, +/-2g)")
    } else {
        debug.println("FAIL")
    }

    debug.print("Enabling magnetometer... ")
    if mag_enable() {
        debug.println("OK (75Hz, +/-1.3 gauss)")
    } else {
        debug.println("FAIL")
    }

    debug.println("")
    debug.println("Reading sensor data:")
    debug.println("")

    led_idx := 0
    leds := [8]board.GPIO_Pin{
        .LD3, .LD5, .LD7, .LD9, .LD10, .LD8, .LD6, .LD4,
    }

    for {
        // Read and print sensor data
        accel_print_state()
        mag_print_state()
        debug.println("")

        // Rotate LED to show activity
        board.gpio_clear(leds[led_idx])
        led_idx = (led_idx + 1) % 8
        board.gpio_set(leds[led_idx])

        systick.systick_delay_ms(200)
    }
}

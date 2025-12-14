// IWDG (Independent Watchdog) Example
// Demonstrates watchdog timeout and reset behavior
package main

import freestanding "stm32/freestanding"
import board "stm32/board"
import debug "stm32/board/debug"
import systick "stm32/sys/systick"
import iwdg "stm32/drivers/iwdg"
import device "stm32/cmsis/device"

@(export)
app_main :: proc() {
    freestanding.init()
    systick.systick_init(1000, 8_000_000)
    board.init()

    systick.systick_delay_ms(100)

    debug.println("STM32F303 Discovery - IWDG Example")
    debug.println("===================================")
    debug.println("")

    // Configure IWDG with ~1 second timeout
    // LSI = 40kHz, Prescaler /64 = 625Hz, Reload 625 = 1 second
    watchdog := iwdg.IWDG_Handle{
        regs = device.IWDG,
        prescaler = .DIV_64,
        reload = 625,
    }

    debug.println("Watchdog config: ~1 second timeout")
    debug.println("Will stop refreshing after 5 iterations")
    debug.println("")

    debug.print("Starting IWDG... ")
    iwdg.iwdg_start(&watchdog)
    debug.println("OK")
    debug.println("")

    led_idx := 0
    leds := [8]board.GPIO_Pin{
        .LD3, .LD5, .LD7, .LD9, .LD10, .LD8, .LD6, .LD4,
    }
    count: u32 = 0

    for {
        count += 1

        debug.print("Iteration ")
        debug.print_u16(u16(count))

        if count <= 5 {
            // Refresh watchdog for first 5 iterations
            iwdg.iwdg_refresh(&watchdog)
            debug.println(" - refreshed")
        } else {
            // Stop refreshing - system should reset after ~1 second
            debug.println(" - NOT refreshing, reset imminent...")
        }

        // Rotate LED
        board.gpio_clear(leds[led_idx])
        led_idx = (led_idx + 1) % 8
        board.gpio_set(leds[led_idx])

        // Wait 500ms (well under 1s timeout)
        systick.systick_delay_ms(500)
    }
}

// LED Spiral + UART Example
// Rotates LEDs in a spiral pattern while printing to UART
package main

import freestanding "stm32/freestanding"
import board "stm32/board"
import debug "stm32/board/debug"
import systick "stm32/sys/systick"

// LEDs in clockwise spiral order (LD3-LD10 around the compass)
LED_SPIRAL :: [8]board.GPIO_Pin{
    .LD3, .LD5, .LD7, .LD9, .LD10, .LD8, .LD6, .LD4,
}

@(export)
app_main :: proc() {
    freestanding.init()
    systick.systick_init(1000, 8_000_000)
    board.init()

    systick.systick_delay_ms(100)

    debug.println("STM32F303 Discovery - LED Spiral")
    debug.println("================================")
    debug.println("Watch the LEDs rotate around the compass!")
    debug.println("")

    led_idx := 0
    leds := LED_SPIRAL
    count: u32 = 0

    for {
        count += 1

        // Print iteration every 10 cycles
        if count % 10 == 0 {
            debug.print("Rotation: ")
            debug.print_u16(u16(count / 8))
            debug.println("")
        }

        // Rotate LED
        board.gpio_clear(leds[led_idx])
        led_idx = (led_idx + 1) % 8
        board.gpio_set(leds[led_idx])

        systick.systick_delay_ms(100)
    }
}

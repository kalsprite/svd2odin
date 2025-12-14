// Button Interrupt Example
// Demonstrates EXTI interrupt - press user button to toggle between modes
// Mode 0: LED spiral pattern
// Mode 1: All LEDs flash together
package main

import freestanding "stm32/freestanding"
import board "stm32/board"
import debug "stm32/board/debug"
import systick "stm32/sys/systick"
import nvic "stm32/sys/nvic"
import exti "stm32/drivers/exti"

// LEDs in clockwise spiral order
led_spiral := [8]board.GPIO_Pin{
    .LD3, .LD5, .LD7, .LD9, .LD10, .LD8, .LD6, .LD4,
}

// All LEDs for flash mode
all_leds := [8]board.GPIO_Pin{
    .LD3, .LD4, .LD5, .LD6, .LD7, .LD8, .LD9, .LD10,
}

// Current mode (toggled by interrupt)
// 0 = spiral, 1 = flash
// Using volatile to ensure visibility between ISR and main
mode: u32 = 0

@(export)
app_main :: proc() {
    freestanding.init()
    systick.systick_init(1000, 8_000_000)
    board.init()

    systick.systick_delay_ms(100)

    debug.println("STM32F303 Discovery - Button Interrupt Demo")
    debug.println("============================================")
    debug.println("Press USER button to toggle LED mode")
    debug.println("Mode 0: Spiral  |  Mode 1: Flash")
    debug.println("")

    // Configure EXTI for user button (PA0)
    // Rising edge = button press (active high)
    exti.exti_configure(0, .PA, .Rising)
    exti.exti_enable(0)

    // Enable EXTI0 interrupt in NVIC
    nvic.nvic_enable_irq(.EXTI0)

    debug.println("Button interrupt enabled")
    debug.println("")

    led_idx := 0
    flash_state := false

    for {
        if mode == 0 {
            // Spiral mode - rotate single LED
            for led in led_spiral {
                board.gpio_clear(led)
            }
            board.gpio_set(led_spiral[led_idx])
            led_idx = (led_idx + 1) % 8
            systick.systick_delay_ms(80)
        } else {
            // Flash mode - all LEDs blink together
            if flash_state {
                for led in all_leds {
                    board.gpio_set(led)
                }
            } else {
                for led in all_leds {
                    board.gpio_clear(led)
                }
            }
            flash_state = !flash_state
            systick.systick_delay_ms(200)
        }
    }
}

// EXTI0 interrupt handler - called on button press
@(export)
EXTI0_IRQHandler :: proc "c" () {
    // Clear pending interrupt first (MUST do this or interrupt keeps firing)
    exti.exti_clear_pending(0)
    // Could Debounce here, dont need on F303 tests
    mode = 1 - mode
}

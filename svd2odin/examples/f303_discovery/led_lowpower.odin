// Low Power LED Example
// Demonstrates Stop mode with RTC wakeup timer
// LEDs on for 500ms, then deep sleep for 500ms (LEDs off), repeat
package main

import freestanding "stm32/freestanding"
import board "stm32/board"
import debug "stm32/board/debug"
import systick "stm32/sys/systick"
import device "stm32/cmsis/device"
import rtc "stm32/drivers/rtc"
import pwr "stm32/drivers/pwr"

// All 8 LEDs on the Discovery board
ALL_LEDS :: [8]board.GPIO_Pin{
    .LD3, .LD4, .LD5, .LD6, .LD7, .LD8, .LD9, .LD10,
}

// Timing configuration (milliseconds)
LED_ON_TIME  :: 500   // LEDs on duration
SLEEP_TIME   :: 500   // Stop mode sleep duration

// RTC handle
rtc_handle: rtc.RTC_Handle

@(export)
app_main :: proc() {
    freestanding.init()
    systick.systick_init(1000, 8_000_000)
    board.init()

    systick.systick_delay_ms(100)

    debug.println("STM32F303 Discovery - Low Power Demo")
    debug.println("=====================================")
    debug.println("LEDs ON 500ms, Stop mode 500ms, repeat")
    debug.println("")

    // Initialize RTC with LSI (internal RC, no crystal needed)
    rtc_handle.regs = device.RTC
    rtc_handle.clock_source = .LSI
    rtc_handle.clock_hz = board.LSI_HZ
    if !rtc.rtc_init(&rtc_handle) {
        debug.println("RTC init failed!")
        for {}
    }

    // Configure wakeup timer for 500ms period
    if !rtc.rtc_configure_wakeup_ms(&rtc_handle, SLEEP_TIME) {
        debug.println("RTC wakeup config failed!")
        for {}
    }

    // Enable wakeup timer (configures EXTI line 20 for Stop mode wakeup)
    rtc.rtc_enable_wakeup(&rtc_handle)

    debug.println("RTC wakeup timer configured")
    debug.println("")

    cycle: u32 = 0

    for {
        cycle += 1

        // Turn on all LEDs
        if cycle % 10 == 1 {
            debug.print("Cycle ")
            debug.print_u16(u16(cycle))
            debug.println("")
        }
        for led in ALL_LEDS {
            board.gpio_set(led)
        }

        // Wait with LEDs on
        systick.systick_delay_ms(LED_ON_TIME)

        // Turn off all LEDs before sleeping
        for led in ALL_LEDS {
            board.gpio_clear(led)
        }

        // Clear any pending wakeup flag
        rtc.rtc_clear_wakeup_flag(&rtc_handle)

        // Enter Stop mode with low-power regulator
        // CPU and most clocks stop, RTC continues running
        pwr.enter_stop(.LowPower)

        // Woke up! HSI is now system clock (8 MHz default)
        // Reinitialize SysTick since clocks changed
        systick.systick_init(1000, 8_000_000)

        // Clear wakeup flag for next cycle
        rtc.rtc_clear_wakeup_flag(&rtc_handle)
    }
}

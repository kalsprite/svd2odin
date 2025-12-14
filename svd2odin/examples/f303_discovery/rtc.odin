// RTC (Real-Time Clock) Example
// Sets the time and reads it back periodically
package main

import freestanding "stm32/freestanding"
import board "stm32/board"
import debug "stm32/board/debug"
import systick "stm32/sys/systick"
import rtc "stm32/drivers/rtc"
import device "stm32/cmsis/device"

@(export)
app_main :: proc() {
    freestanding.init()
    systick.systick_init(1000, 8_000_000)
    board.init()

    systick.systick_delay_ms(100)

    debug.println("STM32F303 Discovery - RTC Example")
    debug.println("==================================")

    // Initialize RTC with LSI clock (internal ~40kHz oscillator)
    rtc_handle := rtc.RTC_Handle{
        regs = device.RTC,
        clock_source = .LSI,
    }

    debug.print("Initializing RTC... ")
    if rtc.rtc_init(&rtc_handle) {
        debug.println("OK")
    } else {
        debug.println("FAIL")
        for {}
    }

    // Set time to 12:00:00
    debug.print("Setting time to 12:00:00... ")
    initial_time := rtc.RTC_Time{hours = 12, minutes = 0, seconds = 0}
    if rtc.rtc_set_time(&rtc_handle, initial_time) {
        debug.println("OK")
    } else {
        debug.println("FAIL")
    }

    debug.println("")
    debug.println("Reading time every second:")

    led_on := false

    for {
        // Read current time
        time := rtc.rtc_get_time(&rtc_handle)

        // Print time in HH:MM:SS format
        if time.hours < 10 { debug.print("0") }
        debug.print_u16(u16(time.hours))
        debug.print(":")
        if time.minutes < 10 { debug.print("0") }
        debug.print_u16(u16(time.minutes))
        debug.print(":")
        if time.seconds < 10 { debug.print("0") }
        debug.print_u16(u16(time.seconds))
        debug.println("")

        // Toggle LED to show activity
        if led_on {
            board.gpio_clear(.LD3)
        } else {
            board.gpio_set(.LD3)
        }
        led_on = !led_on

        systick.systick_delay_ms(1000)
    }
}

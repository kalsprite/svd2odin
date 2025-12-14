// UART Interrupt TX Demo (no RX needed)
// Press button to send message via interrupt-driven TX
// Proves ring buffer and TX interrupt work without needing RX wiring
package main

import freestanding "stm32/freestanding"
import board "stm32/board"
import debug "stm32/board/debug"
import systick "stm32/sys/systick"
import nvic "stm32/sys/nvic"
import uart "stm32/drivers/uart"
import exti "stm32/drivers/exti"
import device "stm32/cmsis/device"

// All LEDs for visual feedback
all_leds := [8]board.GPIO_Pin{
    .LD3, .LD4, .LD5, .LD6, .LD7, .LD8, .LD9, .LD10,
}

// UART handle for interrupt mode
uart_handle: uart.UART_Handle_IRQ

// Message counter
msg_count: u32 = 0

// Button pressed flag (set by ISR, cleared by main)
button_pressed: bool = false

@(export)
app_main :: proc() {
    freestanding.init()
    systick.systick_init(1000, 8_000_000)
    board.init()

    systick.systick_delay_ms(100)

    debug.println("STM32F303 Discovery - UART Interrupt TX Demo")
    debug.println("=============================================")
    debug.println("Press USER button to send message via interrupt TX")
    debug.println("")

    // Initialize USART1 for interrupt mode
    uart_handle.regs = device.USART1
    uart_handle.pclk = 8_000_000

    uart_config := uart.UART_Config{
        baud_rate = .Baud115200,
        data_bits = .Bits8,
        stop_bits = .Stop1,
        parity    = .None,
    }
    uart.uart_init_irq(&uart_handle, uart_config)

    // Enable USART1 interrupt in NVIC (for TX)
    nvic.nvic_enable_irq(.USART1_EXTI25)

    // Configure button interrupt (PA0, rising edge)
    exti.exti_configure(0, .PA, .Rising)
    exti.exti_enable(0)
    nvic.nvic_enable_irq(.EXTI0)

    debug.println("Ready! Press button to send...")
    debug.println("")

    led_idx := 0

    for {
        // Check if button was pressed
        if button_pressed {
            button_pressed = false
            msg_count += 1

            // Visual feedback - light up next LED
            board.gpio_toggle(all_leds[led_idx])
            led_idx = (led_idx + 1) % 8

            // Print to debug (polling) to confirm button works
            debug.print("Button #")
            debug.print_u32(msg_count)
            debug.println(" pressed!")

            // Now try interrupt TX
            uart.uart_write_string(&uart_handle, "IRQ TX test\r\n")
        }

        // Small delay to prevent busy-waiting
        systick.systick_delay_ms(10)
    }
}

// USART1 interrupt handler (TX)
@(export)
USART1_EXTI25_IRQHandler :: proc "c" () {
    uart.uart_irq_handler(&uart_handle)
}

// Button interrupt handler
@(export)
EXTI0_IRQHandler :: proc "c" () {
    exti.exti_clear_pending(0)
    button_pressed = true
}

// Black Pill F411 - LED + Button + Timer Interrupt Example
//
// Demonstrates:
//   - GPIO output: LED on PC13 with software PWM breathing effect
//   - GPIO input: Button on PA0 with pull-up, cycles through LED modes
//   - Hardware timer: TIM2 interrupt fires every 2 seconds
//   - RTT debug output: Messages via SWD debug probe (no UART needed)
//
// Hardware:
//   - WeAct Black Pill STM32F411CEU6
//   - Onboard LED on PC13 (active low)
//   - Onboard button on PA0 (directly to ground without external pullup)
//
// Debug output via RTT:
//   1. Connect ST-Link/J-Link via SWD (SWCLK, SWDIO, GND)
//   2. Run: openocd -f interface/stlink.cfg -f target/stm32f4x.cfg \
//           -c init -c "rtt setup 0x20000000 0x10000 \"SEGGER RTT\"" \
//           -c "rtt start" -c "rtt polling_interval 10" \
//           -c "rtt server start 9090 0"
//   3. Connect: ncat localhost 9090
//
package main

import freestanding "stm32/freestanding"
import board "stm32/board"
import systick "stm32/sys/systick"
import hal "stm32/hal"
import device "stm32/cmsis/device"
import rtt "stm32/drivers/rtt"
import nvic "stm32/sys/nvic"

// =============================================================================
// Global State
// =============================================================================

// Button debounce state
button_last := false
button_count: u32 = 0

// LED breathing phase (0-63, quarter sine wave lookup)
led_phase: u32 = 0

// Heartbeat state (read by TIM2 interrupt handler)
heartbeat_count: u32 = 0
heartbeat_led_mode: u32 = 0
heartbeat_button_count: u32 = 0

// =============================================================================
// LED Breathing - Software PWM using sine wave lookup table
// =============================================================================

// Quarter sine wave (0-254), mirrored to create full wave
sine_quarter := [16]u8{
    0, 25, 50, 74, 98, 120, 142, 162,
    180, 197, 212, 225, 236, 244, 250, 254,
}

// Get sine value for phase (0-63) -> brightness (0-254)
get_sine :: proc "c" (phase: u32) -> u8 {
    p := phase & 63
    if p < 16 {
        return sine_quarter[p]
    } else if p < 32 {
        return sine_quarter[31 - p]
    } else if p < 48 {
        return sine_quarter[p - 32]
    } else {
        return sine_quarter[63 - p]
    }
}

// =============================================================================
// TIM2 Hardware Timer - Periodic interrupt every 2 seconds
// =============================================================================

// Configure TIM2 for periodic update interrupts
// - Prescaler divides clock to 1kHz (1ms ticks)
// - Auto-reload sets the period in milliseconds
tim2_init :: proc "c" (interval_ms: u32, clock_hz: u32) {
    // Enable TIM2 peripheral clock
    hal.reg_modify(&device.RCC.APB1ENR, .Set, device.RCC_APB1ENR_TIM2EN_Mask_Shifted)

    tim2 := device.TIM2
    hal.reg_write(&tim2.CR1, 0)                          // Disable during config
    hal.reg_write(&tim2.PSC, (clock_hz / 1000) - 1)      // Prescaler: 1ms ticks
    hal.reg_write(&tim2.ARR, interval_ms - 1)            // Period
    hal.reg_write(&tim2.CNT, 0)                          // Reset counter
    hal.reg_write(&tim2.EGR, device.TIM2_EGR_UG_Mask_Shifted)  // Load prescaler
    hal.reg_write(&tim2.SR, 0)                           // Clear all flags
    hal.reg_write(&tim2.DIER, device.TIM2_DIER_UIE_Mask_Shifted)  // Enable update IRQ

    nvic.nvic_enable_irq(.TIM2)                          // Enable in NVIC
    hal.reg_write(&tim2.CR1, device.TIM2_CR1_CEN_Mask_Shifted)   // Start timer
}

// TIM2 interrupt handler - called every 2 seconds
// Prints heartbeat message to RTT with current status
@(export, link_name="TIM2_IRQHandler")
TIM2_IRQHandler :: proc "c" () {
    tim2 := device.TIM2
    sr := hal.reg_read(&tim2.SR)

    if (sr & device.TIM2_SR_UIF_Mask_Shifted) != 0 {
        hal.reg_write(&tim2.SR, 0)  // Clear interrupt flag
        heartbeat_count += 1

        rtt.print("HB#")
        rtt.print_u32(heartbeat_count)
        rtt.print(" mode=")
        rtt.print_u32(heartbeat_led_mode)
        rtt.print(" btn=")
        rtt.print_u32(heartbeat_button_count)
        rtt.println("")
    }
}

// =============================================================================
// Main Application
// =============================================================================

@(export)
app_main :: proc() {
    // Initialize runtime and peripherals
    freestanding.init()
    systick.systick_init(1000, 16_000_000)  // 1ms tick @ 16MHz HSI
    board.init()
    rtt.init()

    rtt.println("Black Pill F411 - Starting...")

    // Configure PA0 as input with pull-up (button directly to ground)
    pa := device.GPIOA
    hal.reg_modify(&pa.MODER, .Clear, 0x3 << 0)   // Input mode
    hal.reg_modify(&pa.PUPDR, .Clear, 0x3 << 0)
    hal.reg_modify(&pa.PUPDR, .Set, 0x1 << 0)     // Pull-up enabled

    // Configure PC13 as output (onboard LED, active low)
    pc := device.GPIOC
    hal.reg_modify(&pc.MODER, .Clear, 0x3 << 26)
    hal.reg_modify(&pc.MODER, .Set, 0x1 << 26)    // Output mode

    // Start with LED on
    hal.reg_modify(&pc.ODR, .Clear, 1 << 13)

    // Start TIM2 heartbeat (2 second interval)
    tim2_init(2000, 16_000_000)
    rtt.println("Ready - press button to change LED mode")

    // LED modes: 0=breathing, 1=solid, 2=blink
    led_mode: u32 = 0

    for {
        // Update status for heartbeat interrupt
        heartbeat_led_mode = led_mode
        heartbeat_button_count = button_count

        // Check button (active low - pressed when PA0 reads 0)
        button_now := (hal.reg_read(&pa.IDR) & (1 << 0)) == 0
        if button_now && !button_last {
            led_mode = (led_mode + 1) % 3
            button_count += 1
            rtt.print("Mode: ")
            rtt.print_u32(led_mode)
            rtt.println("")
        }
        button_last = button_now

        // LED control based on mode
        switch led_mode {
        case 0:  // Breathing - software PWM with sine wave
            brightness := get_sine(led_phase)
            on_time := (u32(brightness) * 20) / 256
            off_time := 20 - on_time
            if on_time > 0 {
                hal.reg_modify(&pc.ODR, .Clear, 1 << 13)  // LED on
                systick.systick_delay_ms(on_time)
            }
            if off_time > 0 {
                hal.reg_modify(&pc.ODR, .Set, 1 << 13)    // LED off
                systick.systick_delay_ms(off_time)
            }
            led_phase = (led_phase + 1) % 64

        case 1:  // Solid on
            hal.reg_modify(&pc.ODR, .Clear, 1 << 13)
            systick.systick_delay_ms(20)

        case 2:  // Fast blink
            hal.reg_modify(&pc.ODR, .Clear, 1 << 13)
            systick.systick_delay_ms(100)
            hal.reg_modify(&pc.ODR, .Set, 1 << 13)
            systick.systick_delay_ms(100)

        case:
            systick.systick_delay_ms(20)
        }
    }
}

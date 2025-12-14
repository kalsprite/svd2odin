// PWM LED Breathing Demo
// Uses TIM1 to control 4 LEDs with PWM for smooth brightness fading
// LEDs breathe in a wave pattern
//
// Active LEDs (limited by TIM1 channel availability):
//   LD3  (PE9)  - North      - Red    - TIM1_CH1
//   LD7  (PE11) - East       - Green  - TIM1_CH2
//   LD10 (PE13) - South      - Red    - TIM1_CH3
//   LD8  (PE14) - South-West - Orange - TIM1_CH4
//
// Note: LD6 (PE15/West) has no TIM1 channel, so pattern is not fully symmetric
package main

import freestanding "stm32/freestanding"
import board "stm32/board"
import debug "stm32/board/debug"
import systick "stm32/sys/systick"
import hal "stm32/hal"
import device "stm32/cmsis/device"

// Timer ARR value for duty cycle calculations
tim1_arr: u32 = 0

// Sine table for smooth breathing (0-1000 range, 64 entries for one period)
// Values: sin(x) * 500 + 500, where x = 0 to 2*pi
sine_table := [64]u16{
    500, 549, 597, 644, 690, 734, 776, 815,
    852, 886, 917, 944, 968, 988, 1000, 1000,
    1000, 988, 968, 944, 917, 886, 852, 815,
    776, 734, 690, 644, 597, 549, 500, 451,
    403, 356, 310, 266, 224, 185, 148, 114,
    83, 56, 32, 12, 0, 0, 0, 12,
    32, 56, 83, 114, 148, 185, 224, 266,
    310, 356, 403, 451, 500, 500, 500, 500,
}

@(export)
app_main :: proc() {
    freestanding.init()
    systick.systick_init(1000, 8_000_000)
    board.init()

    systick.systick_delay_ms(100)

    debug.println("STM32F303 Discovery - PWM LED Breathing Demo")
    debug.println("=============================================")
    debug.println("4 LEDs breathing in a wave pattern using TIM1 PWM")
    debug.println("")

    // Enable TIM1 clock (APB2)
    hal.reg_modify(&device.RCC.APB2ENR, .Set, device.RCC_APB2ENR_TIM1EN_Mask_Shifted)

    // Configure GPIO pins for TIM1 alternate function (AF2)
    configure_af(device.GPIOE, 9, 2)   // LD3 - TIM1_CH1
    configure_af(device.GPIOE, 11, 2)  // LD7 - TIM1_CH2
    configure_af(device.GPIOE, 13, 2)  // LD10 - TIM1_CH3
    configure_af(device.GPIOE, 14, 2)  // LD8 - TIM1_CH4

    // Now using device.TIM1 struct (generator fix: duplicate offset regs skipped)
    tim1 := device.TIM1

    // Disable timer during config
    hal.reg_modify(&tim1.CR1, .Clear, device.TIM1_CR1_CEN_Mask_Shifted)

    // Set prescaler = 0, ARR = 7999 for 1kHz @ 8MHz
    hal.reg_write(&tim1.PSC, 0)
    hal.reg_write(&tim1.ARR, 7999)

    // Enable auto-reload preload
    hal.reg_modify(&tim1.CR1, .Set, device.TIM1_CR1_ARPE_Mask_Shifted)

    // Configure CCMR1: CH1 and CH2 as PWM mode 1 (0b110) with preload
    // OC1M = 110 (bits 6:4), OC1PE = 1 (bit 3)
    // OC2M = 110 (bits 14:12), OC2PE = 1 (bit 11)
    hal.reg_write(&tim1.CCMR1_Output,
        (u32(device.TIM1_CCMR1_Output_OC1M.PwmMode1) << device.TIM1_CCMR1_Output_OC1M_Pos) |
        device.TIM1_CCMR1_Output_OC1PE_Mask_Shifted |
        (u32(device.TIM1_CCMR1_Output_OC1M.PwmMode1) << device.TIM1_CCMR1_Output_OC2M_Pos) |
        (device.TIM1_CCMR1_Output_OC2PE_Mask_Shifted))

    // Configure CCMR2: CH3 and CH4 as PWM mode 1 with preload
    hal.reg_write(&tim1.CCMR2_Output,
        (u32(device.TIM1_CCMR2_Output_OC3M.PwmMode1) << device.TIM1_CCMR2_Output_OC3M_Pos) |
        device.TIM1_CCMR2_Output_OC3PE_Mask_Shifted |
        (u32(device.TIM1_CCMR2_Output_OC3M.PwmMode1) << device.TIM1_CCMR2_Output_OC4M_Pos) |
        (device.TIM1_CCMR2_Output_OC4PE_Mask_Shifted))

    // Enable all 4 channels in CCER (CC1E, CC2E, CC3E, CC4E)
    hal.reg_write(&tim1.CCER,
        device.TIM1_CCER_CC1E_Mask_Shifted |
        device.TIM1_CCER_CC2E_Mask_Shifted |
        device.TIM1_CCER_CC3E_Mask_Shifted |
        device.TIM1_CCER_CC4E_Mask_Shifted)

    // Set initial duty cycle to 0
    hal.reg_write(&tim1.CCR1, 0)
    hal.reg_write(&tim1.CCR2, 0)
    hal.reg_write(&tim1.CCR3, 0)
    hal.reg_write(&tim1.CCR4, 0)

    // Generate update event to load registers
    hal.reg_write(&tim1.EGR, device.TIM1_EGR_UG_Mask_Shifted)

    // Enable main output (MOE) for advanced timer
    hal.reg_modify(&tim1.BDTR, .Set, device.TIM1_BDTR_MOE_Mask_Shifted)

    // Enable counter
    hal.reg_modify(&tim1.CR1, .Set, device.TIM1_CR1_CEN_Mask_Shifted)

    // Store ARR for duty cycle calculations
    tim1_arr = 7999

    debug.println("PWM initialized, starting breathing animation...")
    debug.println("Active: LD3 (N), LD7 (E), LD10 (S), LD8 (SW)")
    debug.println("")

    phase: u32 = 0

    for {
        duty1 := sine_table[(phase + 0) % 64]
        duty2 := sine_table[(phase + 16) % 64]
        duty3 := sine_table[(phase + 32) % 64]
        duty4 := sine_table[(phase + 48) % 64]

        // Convert duty (0-1000) to CCR value
        hal.reg_write(&tim1.CCR1, (tim1_arr * u32(duty1)) / 1000)
        hal.reg_write(&tim1.CCR2, (tim1_arr * u32(duty2)) / 1000)
        hal.reg_write(&tim1.CCR3, (tim1_arr * u32(duty3)) / 1000)
        hal.reg_write(&tim1.CCR4, (tim1_arr * u32(duty4)) / 1000)

        phase = (phase + 1) % 64

        systick.systick_delay_ms(30)
    }
}

// Configure a GPIO pin as alternate function output
// Note: Using GPIOC_Registers type since GPIOE uses this type in the SVD
configure_af :: proc "c" (gpio: ^device.GPIOC_Registers, pin: u32, af: u32) {
    // Set mode to alternate function (0b10)
    hal.reg_modify(&gpio.MODER, .Clear, u32(0x3) << (pin * 2))
    hal.reg_modify(&gpio.MODER, .Set, u32(0x2) << (pin * 2))

    // Set output type to push-pull (0)
    hal.reg_modify(&gpio.OTYPER, .Clear, u32(1) << pin)

    // Set speed to high (0b11)
    hal.reg_modify(&gpio.OSPEEDR, .Clear, u32(0x3) << (pin * 2))
    hal.reg_modify(&gpio.OSPEEDR, .Set, u32(0x3) << (pin * 2))

    // Set alternate function
    if pin < 8 {
        // Use AFRL for pins 0-7
        hal.reg_modify(&gpio.AFRL, .Clear, u32(0xF) << (pin * 4))
        hal.reg_modify(&gpio.AFRL, .Set, af << (pin * 4))
    } else {
        // Use AFRH for pins 8-15
        pos := (pin - 8) * 4
        hal.reg_modify(&gpio.AFRH, .Clear, u32(0xF) << pos)
        hal.reg_modify(&gpio.AFRH, .Set, af << pos)
    }
}

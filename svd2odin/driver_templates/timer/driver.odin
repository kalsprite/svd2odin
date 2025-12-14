package timer

import "base:intrinsics"
import hal "../../hal"
import device "../../cmsis/device"

// Timer driver for STM32
// Supports basic timing and PWM output modes
// Works with TIM1-TIM20 (general purpose and advanced timers)

// Timer mode
Timer_Mode :: enum {
    Basic,  // Basic timing with update interrupt
    PWM,    // PWM output mode
}

// PWM channel (1-4 for most timers, 1-6 for TIM1/TIM8)
PWM_Channel :: enum {
    CH1 = 0,
    CH2 = 1,
    CH3 = 2,
    CH4 = 3,
    CH5 = 4,
    CH6 = 5,
}

// PWM polarity
PWM_Polarity :: enum {
    ActiveHigh = 0,  // Output high when active
    ActiveLow  = 1,  // Output low when active
}

// Timer configuration
Timer_Config :: struct {
    mode:      Timer_Mode,
    frequency: u32,  // Timer frequency in Hz (for basic mode: interrupt rate, for PWM: PWM frequency)
    pclk:      u32,  // Peripheral clock frequency
}

// PWM channel configuration
PWM_Config :: struct {
    channel:  PWM_Channel,
    polarity: PWM_Polarity,
    duty:     u16,  // Duty cycle 0-1000 (0.0% - 100.0%)
}

// Timer handle - uses TIM2 register layout (compatible with most timers)
Timer_Handle :: struct {
    regs:        ^device.TIM2_Registers,
    arr:         u32,  // Auto-reload value (period)
    is_advanced: bool, // TIM1/TIM8/TIM20 need BDTR.MOE enabled
}

// Register bit positions (common across all timers)
CR1_CEN_Pos  :: 0   // Counter enable
CR1_ARPE_Pos :: 7   // Auto-reload preload enable

DIER_UIE_Pos :: 0   // Update interrupt enable

SR_UIF_Pos :: 0     // Update interrupt flag

CCER_CC1E_Pos :: 0  // Channel 1 enable
CCER_CC1P_Pos :: 1  // Channel 1 polarity
CCER_CC2E_Pos :: 4  // Channel 2 enable
CCER_CC2P_Pos :: 5  // Channel 2 polarity
CCER_CC3E_Pos :: 8  // Channel 3 enable
CCER_CC3P_Pos :: 9  // Channel 3 polarity
CCER_CC4E_Pos :: 12 // Channel 4 enable
CCER_CC4P_Pos :: 13 // Channel 4 polarity

// CCMR output compare mode bits (same position in CCMR1 and CCMR2)
CCMR_OC1M_Pos :: 4   // Output compare 1 mode (channels 1, 3)
CCMR_OC2M_Pos :: 12  // Output compare 2 mode (channels 2, 4)
CCMR_OC1PE_Pos :: 3  // Output compare 1 preload enable
CCMR_OC2PE_Pos :: 11 // Output compare 2 preload enable

// PWM mode 1: active when CNT < CCR
OC_MODE_PWM1 :: 0b110

// BDTR register (advanced timers only)
BDTR_MOE_Pos :: 15  // Main output enable

// Initialize timer for basic or PWM mode
timer_init :: proc "c" (handle: ^Timer_Handle, config: Timer_Config) {
    // Disable timer during configuration
    hal.reg_modify(&handle.regs.CR1, .Clear, 1 << CR1_CEN_Pos)

    // Calculate prescaler and auto-reload for desired frequency
    // Timer clock = PCLK / (PSC + 1)
    // Timer frequency = Timer clock / (ARR + 1)
    // So: frequency = PCLK / ((PSC + 1) * (ARR + 1))

    // For flexibility, we try to maximize ARR for better PWM resolution
    // Start with PSC = 0 and increase if ARR would overflow
    psc: u32 = 0
    arr: u32 = 0

    if config.frequency > 0 {
        // Calculate required divider
        divider := config.pclk / config.frequency

        if divider <= 65536 {
            // Can use PSC = 0
            psc = 0
            arr = divider - 1
        } else {
            // Need prescaler - aim for ARR around 10000 for good PWM resolution
            psc = (divider / 10000)
            if psc > 0 {
                psc -= 1
            }
            arr = (config.pclk / ((psc + 1) * config.frequency)) - 1

            // Clamp to 16-bit
            if arr > 65535 {
                arr = 65535
            }
        }
    }

    handle.arr = arr

    // Set prescaler
    hal.reg_write(&handle.regs.PSC, psc)

    // Set auto-reload value
    hal.reg_write(&handle.regs.ARR, arr)

    // Enable auto-reload preload
    hal.reg_modify(&handle.regs.CR1, .Set, 1 << CR1_ARPE_Pos)

    // Generate update event to load prescaler
    hal.reg_write(&handle.regs.EGR, 1)

    // Clear update flag
    hal.reg_modify(&handle.regs.SR, .Clear, 1 << SR_UIF_Pos)
}

// Configure PWM channel
timer_pwm_config :: proc "c" (handle: ^Timer_Handle, config: PWM_Config) {
    ch := u32(config.channel)

    // Configure output compare mode in CCMRx
    // Channels 1,2 use CCMR1; channels 3,4 use CCMR2
    if ch < 2 {
        // CCMR1
        ccmr := hal.reg_read(&handle.regs.CCMR1_Output)

        if ch == 0 {
            // Channel 1: OC1M bits [6:4], OC1PE bit 3
            ccmr &= ~(u32(0x7) << CCMR_OC1M_Pos)  // Clear mode bits
            ccmr |= OC_MODE_PWM1 << CCMR_OC1M_Pos // Set PWM mode 1
            ccmr |= 1 << CCMR_OC1PE_Pos           // Enable preload
        } else {
            // Channel 2: OC2M bits [14:12], OC2PE bit 11
            ccmr &= ~(u32(0x7) << CCMR_OC2M_Pos)
            ccmr |= OC_MODE_PWM1 << CCMR_OC2M_Pos
            ccmr |= 1 << CCMR_OC2PE_Pos
        }

        hal.reg_write(&handle.regs.CCMR1_Output, ccmr)
    } else {
        // CCMR2
        ccmr := hal.reg_read(&handle.regs.CCMR2_Output)

        if ch == 2 {
            // Channel 3
            ccmr &= ~(u32(0x7) << CCMR_OC1M_Pos)
            ccmr |= OC_MODE_PWM1 << CCMR_OC1M_Pos
            ccmr |= 1 << CCMR_OC1PE_Pos
        } else {
            // Channel 4
            ccmr &= ~(u32(0x7) << CCMR_OC2M_Pos)
            ccmr |= OC_MODE_PWM1 << CCMR_OC2M_Pos
            ccmr |= 1 << CCMR_OC2PE_Pos
        }

        hal.reg_write(&handle.regs.CCMR2_Output, ccmr)
    }

    // Configure polarity and enable channel in CCER
    ccer := hal.reg_read(&handle.regs.CCER)

    enable_pos := ch * 4      // CC1E=0, CC2E=4, CC3E=8, CC4E=12
    polarity_pos := ch * 4 + 1 // CC1P=1, CC2P=5, CC3P=9, CC4P=13

    // Set polarity
    if config.polarity == .ActiveLow {
        ccer |= 1 << polarity_pos
    } else {
        ccer &= ~(u32(1) << polarity_pos)
    }

    // Enable channel
    ccer |= 1 << enable_pos

    hal.reg_write(&handle.regs.CCER, ccer)

    // Set initial duty cycle
    timer_pwm_set_duty(handle, config.channel, config.duty)
}

// Set PWM duty cycle (0-1000 = 0.0% - 100.0%)
timer_pwm_set_duty :: proc "c" (handle: ^Timer_Handle, channel: PWM_Channel, duty: u16) {
    // Calculate CCR value: CCR = ARR * duty / 1000
    ccr := (handle.arr * u32(duty)) / 1000

    #partial switch channel {
    case .CH1:
        hal.reg_write(&handle.regs.CCR1, ccr)
    case .CH2:
        hal.reg_write(&handle.regs.CCR2, ccr)
    case .CH3:
        hal.reg_write(&handle.regs.CCR3, ccr)
    case .CH4:
        hal.reg_write(&handle.regs.CCR4, ccr)
    // CH5/CH6 only available on TIM1/TIM8 - handled via advanced timer registers
    }
}

// Set PWM duty cycle as raw CCR value
timer_pwm_set_ccr :: proc "c" (handle: ^Timer_Handle, channel: PWM_Channel, ccr: u32) {
    #partial switch channel {
    case .CH1:
        hal.reg_write(&handle.regs.CCR1, ccr)
    case .CH2:
        hal.reg_write(&handle.regs.CCR2, ccr)
    case .CH3:
        hal.reg_write(&handle.regs.CCR3, ccr)
    case .CH4:
        hal.reg_write(&handle.regs.CCR4, ccr)
    // CH5/CH6 only available on TIM1/TIM8 - handled via advanced timer registers
    }
}

// Enable timer
timer_enable :: proc "c" (handle: ^Timer_Handle) {
    // For advanced timers, enable main output
    if handle.is_advanced {
        // BDTR register is at offset 0x44 - cast to access it
        bdtr := cast(^hal.Register)(uintptr(&handle.regs.CCR4) + 4)
        hal.reg_modify(bdtr, .Set, 1 << BDTR_MOE_Pos)
    }

    hal.reg_modify(&handle.regs.CR1, .Set, 1 << CR1_CEN_Pos)
}

// Disable timer
timer_disable :: proc "c" (handle: ^Timer_Handle) {
    hal.reg_modify(&handle.regs.CR1, .Clear, 1 << CR1_CEN_Pos)
}

// Enable update interrupt
timer_enable_interrupt :: proc "c" (handle: ^Timer_Handle) {
    hal.reg_modify(&handle.regs.DIER, .Set, 1 << DIER_UIE_Pos)
}

// Disable update interrupt
timer_disable_interrupt :: proc "c" (handle: ^Timer_Handle) {
    hal.reg_modify(&handle.regs.DIER, .Clear, 1 << DIER_UIE_Pos)
}

// Check if update interrupt pending
timer_check_update :: proc "c" (handle: ^Timer_Handle) -> bool {
    sr := hal.reg_read(&handle.regs.SR)
    return (sr & (1 << SR_UIF_Pos)) != 0
}

// Clear update interrupt flag
timer_clear_update :: proc "c" (handle: ^Timer_Handle) {
    hal.reg_modify(&handle.regs.SR, .Clear, 1 << SR_UIF_Pos)
}

// Get current counter value
timer_get_counter :: proc "c" (handle: ^Timer_Handle) -> u32 {
    return hal.reg_read(&handle.regs.CNT)
}

// Set counter value
timer_set_counter :: proc "c" (handle: ^Timer_Handle, value: u32) {
    hal.reg_write(&handle.regs.CNT, value)
}

// Get ARR value (period)
timer_get_period :: proc "c" (handle: ^Timer_Handle) -> u32 {
    return handle.arr
}

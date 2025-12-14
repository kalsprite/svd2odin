package wwdg

import hal "../../hal"
import device "../../cmsis/device"

// Window Watchdog (WWDG) driver
// Clocked by APB1 / 4096
// Must be refreshed within a window (not too early, not too late)
// Counter counts down from programmed value to 0x40
// Reset occurs if counter reaches 0x3F or refresh outside window

// Prescaler values (divides APB1/4096 further)
WWDG_Prescaler :: enum u32 {
    DIV_1 = 0,  // /1
    DIV_2 = 1,  // /2
    DIV_4 = 2,  // /4
    DIV_8 = 3,  // /8
}

WWDG_Handle :: struct {
    regs:      ^device.WWDG_Registers,
    prescaler: WWDG_Prescaler,
    window:    u8,   // 0x40-0x7F, must refresh when counter < window
    counter:   u8,   // 0x40-0x7F, starting counter value
}

// CR register bits
CR_WDGA :: 7  // Activation bit
CR_T_MASK :: 0x7F

// CFR register bits
CFR_EWI :: 9  // Early wakeup interrupt
CFR_WDGTB_POS :: 7
CFR_WDGTB_MASK :: 0x3
CFR_W_MASK :: 0x7F

// Initialize WWDG
// window_ms: time window in which refresh is allowed
// timeout_ms: total timeout from counter start to reset
// Note: window_ms must be less than timeout_ms
wwdg_init :: proc "c" (handle: ^WWDG_Handle, apb1_hz: u32, window_ms: u32, timeout_ms: u32) {
    handle.regs = device.WWDG

    // WWDG clock = APB1 / 4096
    // Time per tick = 4096 * prescaler / APB1
    // Counter range: 0x40 (64) to 0x7F (127), so 63 ticks max

    wwdg_clock := apb1_hz / 4096

    // Try each prescaler
    prescalers := [4]u32{1, 2, 4, 8}

    for i in 0..<4 {
        tick_us := (prescalers[i] * 1000000) / wwdg_clock
        max_ticks := (timeout_ms * 1000) / tick_us

        if max_ticks <= 63 {
            handle.prescaler = WWDG_Prescaler(i)

            // Counter value (0x40 + ticks)
            handle.counter = u8(0x40 + max_ticks)
            if handle.counter > 0x7F {
                handle.counter = 0x7F
            }

            // Window value
            window_ticks := (window_ms * 1000) / tick_us
            handle.window = u8(0x40 + window_ticks)
            if handle.window > handle.counter {
                handle.window = handle.counter
            }
            if handle.window < 0x40 {
                handle.window = 0x40
            }

            return
        }
    }

    // Use maximum prescaler and values
    handle.prescaler = .DIV_8
    handle.counter = 0x7F
    handle.window = 0x7F
}

// Configure and start WWDG (cannot be stopped once started!)
wwdg_start :: proc "c" (handle: ^WWDG_Handle) {
    // Enable WWDG clock
    hal.reg_modify(&device.RCC.APB1ENR, .Set, device.RCC_APB1ENR_WWDGEN_Mask_Shifted)

    // Configure prescaler and window
    cfr: u32 = u32(handle.prescaler) << CFR_WDGTB_POS
    cfr |= u32(handle.window) & CFR_W_MASK
    hal.reg_write(&handle.regs.CFR, cfr)

    // Set counter and enable (WDGA bit)
    cr: u32 = (1 << CR_WDGA) | (u32(handle.counter) & CR_T_MASK)
    hal.reg_write(&handle.regs.CR, cr)
}

// Refresh (kick) the watchdog
// Must be called when counter is below window value but above 0x40
wwdg_refresh :: proc "c" (handle: ^WWDG_Handle) {
    cr: u32 = (1 << CR_WDGA) | (u32(handle.counter) & CR_T_MASK)
    hal.reg_write(&handle.regs.CR, cr)
}

// Get current counter value (useful for debugging timing)
wwdg_get_counter :: proc "c" (handle: ^WWDG_Handle) -> u8 {
    cr := hal.reg_read(&handle.regs.CR)
    return u8(cr & CR_T_MASK)
}

// Check if early wakeup flag is set (counter reached 0x40)
wwdg_check_ewi :: proc "c" (handle: ^WWDG_Handle) -> bool {
    sr := hal.reg_read(&handle.regs.SR)
    return (sr & 1) != 0
}

// Clear early wakeup flag
wwdg_clear_ewi :: proc "c" (handle: ^WWDG_Handle) {
    hal.reg_write(&handle.regs.SR, 0)
}

package iwdg

import hal "../../hal"
import device "../../cmsis/device"

// Independent Watchdog (IWDG) driver
// Clocked by LSI (~40kHz, varies 30-60kHz)
// Once started, cannot be stopped (except by reset)

// Key values for KR register
KEY_ENABLE :: 0x5555  // Enable write access to PR, RLR, WINR
KEY_REFRESH :: 0xAAAA // Refresh (kick) the watchdog
KEY_START :: 0xCCCC   // Start the watchdog

// Prescaler values (actual divider = 4 * 2^PR)
IWDG_Prescaler :: enum u32 {
    DIV_4   = 0,  // /4   (max ~409ms at 40kHz)
    DIV_8   = 1,  // /8   (max ~819ms)
    DIV_16  = 2,  // /16  (max ~1.6s)
    DIV_32  = 3,  // /32  (max ~3.2s)
    DIV_64  = 4,  // /64  (max ~6.5s)
    DIV_128 = 5,  // /128 (max ~13s)
    DIV_256 = 6,  // /256 (max ~26s)
}

IWDG_Handle :: struct {
    regs:      ^device.IWDG_Registers,
    prescaler: IWDG_Prescaler,
    reload:    u16,  // 0-4095
}

// Initialize IWDG with timeout in milliseconds (approximate, LSI varies)
// Does NOT start the watchdog - call iwdg_start() when ready
iwdg_init :: proc "c" (handle: ^IWDG_Handle, timeout_ms: u32) {
    handle.regs = device.IWDG

    // Calculate prescaler and reload for desired timeout
    // Timeout = (prescaler * reload) / LSI_freq
    // LSI ~= 40000 Hz, so timeout_ms = (prescaler * reload) / 40

    // Try each prescaler starting from smallest
    lsi_khz: u32 = 40  // Approximate LSI in kHz

    // prescaler values: 4, 8, 16, 32, 64, 128, 256
    prescalers := [7]u32{4, 8, 16, 32, 64, 128, 256}

    for i in 0..<7 {
        // reload = (timeout_ms * lsi_khz) / prescaler
        reload := (timeout_ms * lsi_khz) / prescalers[i]
        if reload <= 4095 {
            handle.prescaler = IWDG_Prescaler(i)
            handle.reload = u16(reload)
            return
        }
    }

    // Timeout too long, use maximum
    handle.prescaler = .DIV_256
    handle.reload = 4095
}

// Configure IWDG registers (call before start)
iwdg_configure :: proc "c" (handle: ^IWDG_Handle) {
    // Enable write access
    hal.reg_write(&handle.regs.KR, KEY_ENABLE)

    // Set prescaler
    hal.reg_write(&handle.regs.PR, u32(handle.prescaler))

    // Set reload value
    hal.reg_write(&handle.regs.RLR, u32(handle.reload))

    // Wait for registers to be updated (with timeout)
    // Note: PVU/RVU flags only valid after IWDG started
    timeout: u32 = 100000
    for timeout > 0 {
        sr := hal.reg_read(&handle.regs.SR)
        if sr == 0 {
            break
        }
        timeout -= 1
    }
}

// Start the watchdog (cannot be stopped once started!)
iwdg_start :: proc "c" (handle: ^IWDG_Handle) {
    hal.reg_write(&handle.regs.KR, KEY_START)
}

// Refresh (kick) the watchdog - must be called periodically
iwdg_refresh :: proc "c" (handle: ^IWDG_Handle) {
    hal.reg_write(&handle.regs.KR, KEY_REFRESH)
}

// Convenience: init, configure, and start in one call
iwdg_start_ms :: proc "c" (handle: ^IWDG_Handle, timeout_ms: u32) {
    iwdg_init(handle, timeout_ms)
    iwdg_configure(handle)
    iwdg_start(handle)
}

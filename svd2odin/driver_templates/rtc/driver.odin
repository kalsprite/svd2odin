package rtc

import hal "../../hal"
import device "../../cmsis/device"

// RTC driver for STM32 onboard Real-Time Clock
// For external I2C RTCs (DS3231, PCF8563, etc.), use the I2C driver
// and write application-specific code

// RTC clock source
RTC_ClockSource :: enum {
    LSE,  // Low-speed external (32.768 kHz crystal) - more accurate
    LSI,  // Low-speed internal (~40 kHz RC) - less accurate, no crystal needed
}

// Time structure (24-hour format)
RTC_Time :: struct {
    hours:   u8,  // 0-23
    minutes: u8,  // 0-59
    seconds: u8,  // 0-59
}

// Date structure
RTC_Date :: struct {
    year:    u8,  // 0-99 (represents 2000-2099)
    month:   u8,  // 1-12
    day:     u8,  // 1-31
    weekday: u8,  // 1-7 (1 = Monday)
}

// RTC handle
RTC_Handle :: struct {
    regs:         ^device.RTC_Registers,
    clock_source: RTC_ClockSource,
    clock_hz:     u32,  // Clock frequency (LSE=32768, LSI from board config)
}

// Write protection keys
WPR_KEY1 :: 0xCA
WPR_KEY2 :: 0x53

// ISR bit positions
ISR_INITF_Pos :: 6   // Initialization flag
ISR_INIT_Pos  :: 7   // Initialization mode
ISR_RSF_Pos   :: 5   // Registers synchronization flag

// Unlock RTC write protection
rtc_unlock :: proc "c" (handle: ^RTC_Handle) {
    hal.reg_write(&handle.regs.WPR, WPR_KEY1)
    hal.reg_write(&handle.regs.WPR, WPR_KEY2)
}

// Lock RTC write protection
rtc_lock :: proc "c" (handle: ^RTC_Handle) {
    hal.reg_write(&handle.regs.WPR, 0xFF)  // Any wrong key locks
}

// Enter initialization mode
rtc_enter_init :: proc "c" (handle: ^RTC_Handle) -> bool {
    // Ensure PWR clock is enabled for backup domain access
    hal.reg_modify(&device.RCC.APB1ENR, .Set, device.RCC_APB1ENR_PWREN_Mask_Shifted)

    // Ensure backup domain access is enabled (PWR_CR.DBP)
    hal.reg_modify(&device.PWR.CR, .Set, device.PWR_CR_DBP_Mask_Shifted)

    // Read back to synchronize
    _ = hal.reg_read(&device.PWR.CR)

    rtc_unlock(handle)

    // Set INIT bit (write 0xFFFFFFFF to preserve rc_w0 bits)
    hal.reg_write(&handle.regs.ISR, 0xFFFFFFFF)

    // Wait for INITF flag (with timeout)
    timeout: u32 = 100
    for timeout > 0 {
        isr := hal.reg_read(&handle.regs.ISR)
        if (isr & (1 << ISR_INITF_Pos)) != 0 {
            return true
        }
        timeout -= 1
    }

    return false
}

// Exit initialization mode and wait for shadow register sync
rtc_exit_init :: proc "c" (handle: ^RTC_Handle) {
    // Clear INIT bit
    hal.reg_modify(&handle.regs.ISR, .Clear, 1 << ISR_INIT_Pos)
    rtc_lock(handle)

    // Clear RSF and wait for shadow register sync
    hal.reg_modify(&handle.regs.ISR, .Clear, 1 << ISR_RSF_Pos)
    timeout: u32 = 1000
    for timeout > 0 {
        isr := hal.reg_read(&handle.regs.ISR)
        if (isr & (1 << ISR_RSF_Pos)) != 0 {
            return
        }
        timeout -= 1
    }
}

// Initialize RTC with prescaler for 1Hz from clock source
// LSE (32768 Hz): PREDIV_A = 127, PREDIV_S = 255
// LSI (~40000 Hz): PREDIV_A = 127, PREDIV_S = 311
rtc_init :: proc "c" (handle: ^RTC_Handle) -> bool {
    // Enable PWR clock and backup domain access
    hal.reg_modify(&device.RCC.APB1ENR, .Set, device.RCC_APB1ENR_PWREN_Mask_Shifted)
    hal.reg_modify(&device.PWR.CR, .Set, device.PWR_CR_DBP_Mask_Shifted)
    _ = hal.reg_read(&device.PWR.CR)  // Sync

    // Check if RTC is already configured with correct clock source
    // RTCSEL can only be changed after backup domain reset
    bdcr := hal.reg_read(&device.RCC.BDCR)
    current_rtcsel := (bdcr >> 8) & 0x3
    desired_rtcsel: u32 = 2 if handle.clock_source == .LSI else 1

    if current_rtcsel != 0 && current_rtcsel != desired_rtcsel {
        // Different clock source - need backup domain reset
        hal.reg_modify(&device.RCC.BDCR, .Set, device.RCC_BDCR_BDRST_Mask_Shifted)
        hal.reg_modify(&device.RCC.BDCR, .Clear, device.RCC_BDCR_BDRST_Mask_Shifted)
    }

    // Enable and select clock source
    prediv_a: u32 = 127  // Async prescaler (7 bits, max 127)
    prediv_s: u32

    if handle.clock_source == .LSE {
        // Enable LSE
        hal.reg_modify(&device.RCC.BDCR, .Set, device.RCC_BDCR_LSEON_Mask_Shifted)
        // Wait for LSE ready
        timeout: u32 = 100000
        for timeout > 0 {
            if (hal.reg_read(&device.RCC.BDCR) & device.RCC_BDCR_LSERDY_Mask_Shifted) != 0 {
                break
            }
            timeout -= 1
        }
        prediv_s = 255  // 32768 / 128 / 256 = 1 Hz
    } else {
        // Enable LSI
        hal.reg_modify(&device.RCC.CSR, .Set, device.RCC_CSR_LSION_Mask_Shifted)
        // Wait for LSI ready
        timeout: u32 = 10000
        for timeout > 0 {
            if (hal.reg_read(&device.RCC.CSR) & device.RCC_CSR_LSIRDY_Mask_Shifted) != 0 {
                break
            }
            timeout -= 1
        }
        prediv_s = 311  // ~40000 / 128 / 313 ≈ 1 Hz
    }

    // Select RTC clock source and enable RTC
    bdcr = hal.reg_read(&device.RCC.BDCR)
    bdcr &= ~(u32(0x3) << 8)         // Clear RTCSEL
    bdcr |= desired_rtcsel << 8      // Set new source
    bdcr |= device.RCC_BDCR_RTCEN_Mask_Shifted  // Enable RTC
    hal.reg_write(&device.RCC.BDCR, bdcr)

    if !rtc_enter_init(handle) {
        return false
    }

    // PRER register: PREDIV_A[22:16], PREDIV_S[14:0]
    prer := (prediv_a << 16) | prediv_s
    hal.reg_write(&handle.regs.PRER, prer)

    // Set 24-hour format (FMT = 0 in CR)
    hal.reg_modify(&handle.regs.CR, .Clear, 1 << 6)  // FMT bit

    rtc_exit_init(handle)
    return true
}

// Wait for registers synchronization
rtc_wait_sync :: proc "c" (handle: ^RTC_Handle) -> bool {
    // Clear RSF flag
    hal.reg_modify(&handle.regs.ISR, .Clear, 1 << ISR_RSF_Pos)

    // Wait for RSF flag
    timeout: u32 = 100
    for timeout > 0 {
        isr := hal.reg_read(&handle.regs.ISR)
        if (isr & (1 << ISR_RSF_Pos)) != 0 {
            return true
        }
        timeout -= 1
    }

    return false
}

// Convert binary to BCD
bin_to_bcd :: proc "c" (bin: u8) -> u8 {
    return ((bin / 10) << 4) | (bin % 10)
}

// Convert BCD to binary
bcd_to_bin :: proc "c" (bcd: u8) -> u8 {
    return ((bcd >> 4) * 10) + (bcd & 0x0F)
}

// Set time
rtc_set_time :: proc "c" (handle: ^RTC_Handle, time: RTC_Time) -> bool {
    if !rtc_enter_init(handle) {
        return false
    }

    // Build TR register value (BCD format)
    tr: u32 = 0
    tr |= u32(bin_to_bcd(time.hours)) << 16    // HT[1:0], HU[3:0]
    tr |= u32(bin_to_bcd(time.minutes)) << 8   // MNT[2:0], MNU[3:0]
    tr |= u32(bin_to_bcd(time.seconds))        // ST[2:0], SU[3:0]

    hal.reg_write(&handle.regs.TR, tr)

    rtc_exit_init(handle)
    return true
}

// Get time
// Note: Returns tuple due to Odin ARM ABI bug with single small struct returns
rtc_get_time :: proc "c" (handle: ^RTC_Handle) -> (time: RTC_Time, ok: bool) #optional_ok {
    tr := hal.reg_read(&handle.regs.TR)
    time.hours   = bcd_to_bin(u8((tr >> 16) & 0x3F))
    time.minutes = bcd_to_bin(u8((tr >> 8) & 0x7F))
    time.seconds = bcd_to_bin(u8(tr & 0x7F))
    return
}

// Set date
rtc_set_date :: proc "c" (handle: ^RTC_Handle, date: RTC_Date) -> bool {
    if !rtc_enter_init(handle) {
        return false
    }

    // Build DR register value (BCD format)
    dr: u32 = 0
    dr |= u32(bin_to_bcd(date.year)) << 16     // YT[3:0], YU[3:0]
    dr |= u32(date.weekday) << 13              // WDU[2:0]
    dr |= u32(bin_to_bcd(date.month)) << 8     // MT, MU[3:0]
    dr |= u32(bin_to_bcd(date.day))            // DT[1:0], DU[3:0]

    hal.reg_write(&handle.regs.DR, dr)

    rtc_exit_init(handle)
    return true
}

// Get date
// Note: Returns tuple due to Odin ARM ABI bug with single small struct returns
rtc_get_date :: proc "c" (handle: ^RTC_Handle) -> (date: RTC_Date, ok: bool) #optional_ok {
    dr := hal.reg_read(&handle.regs.DR)
    date.year    = bcd_to_bin(u8((dr >> 16) & 0xFF))
    date.month   = bcd_to_bin(u8((dr >> 8) & 0x1F))
    date.day     = bcd_to_bin(u8(dr & 0x3F))
    date.weekday = u8((dr >> 13) & 0x07)
    return
}

// Set both time and date atomically
rtc_set_datetime :: proc "c" (handle: ^RTC_Handle, date: RTC_Date, time: RTC_Time) -> bool {
    if !rtc_enter_init(handle) {
        return false
    }

    // Build TR register value
    tr: u32 = 0
    tr |= u32(bin_to_bcd(time.hours)) << 16
    tr |= u32(bin_to_bcd(time.minutes)) << 8
    tr |= u32(bin_to_bcd(time.seconds))

    // Build DR register value
    dr: u32 = 0
    dr |= u32(bin_to_bcd(date.year)) << 16
    dr |= u32(date.weekday) << 13
    dr |= u32(bin_to_bcd(date.month)) << 8
    dr |= u32(bin_to_bcd(date.day))

    hal.reg_write(&handle.regs.TR, tr)
    hal.reg_write(&handle.regs.DR, dr)

    rtc_exit_init(handle)
    return true
}

// Get both time and date atomically
// Note: Two structs in tuple works around Odin ARM ABI bug with single struct returns
rtc_get_datetime :: proc "c" (handle: ^RTC_Handle) -> (date: RTC_Date, time: RTC_Time) {
    // Read TR first, then DR (locked until DR is read)
    tr := hal.reg_read(&handle.regs.TR)
    dr := hal.reg_read(&handle.regs.DR)

    time.hours   = bcd_to_bin(u8((tr >> 16) & 0x3F))
    time.minutes = bcd_to_bin(u8((tr >> 8) & 0x7F))
    time.seconds = bcd_to_bin(u8(tr & 0x7F))

    date.year    = bcd_to_bin(u8((dr >> 16) & 0xFF))
    date.month   = bcd_to_bin(u8((dr >> 8) & 0x1F))
    date.day     = bcd_to_bin(u8(dr & 0x3F))
    date.weekday = u8((dr >> 13) & 0x07)
    return
}

// Read backup register (0-31 on most STM32)
rtc_read_backup :: proc "c" (handle: ^RTC_Handle, index: u8) -> u32 {
    if index > 31 {
        return 0
    }
    // Backup registers start at offset 0x50 from RTC base
    bkp_ptr := cast(^hal.Register)(uintptr(handle.regs) + 0x50 + uintptr(index) * 4)
    return hal.reg_read(bkp_ptr)
}

// Write backup register (0-31 on most STM32)
rtc_write_backup :: proc "c" (handle: ^RTC_Handle, index: u8, value: u32) {
    if index > 31 {
        return
    }
    rtc_unlock(handle)
    bkp_ptr := cast(^hal.Register)(uintptr(handle.regs) + 0x50 + uintptr(index) * 4)
    hal.reg_write(bkp_ptr, value)
    rtc_lock(handle)
}

// Check if RTC is already initialized (survives reset if VBAT powered)
rtc_is_initialized :: proc "c" (handle: ^RTC_Handle) -> bool {
    isr := hal.reg_read(&handle.regs.ISR)
    // INITS bit indicates calendar has been initialized
    return (isr & (1 << 4)) != 0  // INITS is bit 4
}

// ============================================================================
// Wakeup Timer Functions
// ============================================================================

// Wakeup timer clock selection
Wakeup_Clock :: enum {
    RTC_Div16,          // RTC/16 (fast, short periods)
    RTC_Div8,           // RTC/8
    RTC_Div4,           // RTC/4
    RTC_Div2,           // RTC/2
    CK_SPRE,            // 1 Hz clock (for seconds-based wakeup)
    CK_SPRE_Extended,   // 1 Hz + 2^16 added to counter (for longer periods)
}

// Configure wakeup timer period
// For CK_SPRE clock: wakeup_value = seconds - 1 (max 65535 = ~18 hours)
// For CK_SPRE_Extended: adds 65536 to the counter for even longer periods
// Must call rtc_enable_wakeup() after configuration to start the timer
rtc_configure_wakeup :: proc "c" (handle: ^RTC_Handle, clock: Wakeup_Clock, wakeup_value: u16) -> bool {
    // Ensure PWR and backup domain access
    hal.reg_modify(&device.RCC.APB1ENR, .Set, device.RCC_APB1ENR_PWREN_Mask_Shifted)
    hal.reg_modify(&device.PWR.CR, .Set, device.PWR_CR_DBP_Mask_Shifted)
    _ = hal.reg_read(&device.PWR.CR)

    rtc_unlock(handle)

    // Disable wakeup timer to modify it
    hal.reg_modify(&handle.regs.CR, .Clear, device.RTC_CR_WUTE_Mask_Shifted)

    // Wait for WUTWF flag (wakeup timer write allowed)
    timeout: u32 = 10000
    for timeout > 0 {
        isr := hal.reg_read(&handle.regs.ISR)
        if (isr & device.RTC_ISR_WUTWF_Mask_Shifted) != 0 {
            break
        }
        timeout -= 1
    }
    if timeout == 0 {
        rtc_lock(handle)
        return false
    }

    // Set clock selection (WUCKSEL bits 0-2)
    cr := hal.reg_read(&handle.regs.CR)
    cr &= ~u32(device.RTC_CR_WUCKSEL_Mask_Shifted)
    switch clock {
    case .RTC_Div16:        cr |= 0
    case .RTC_Div8:         cr |= 1
    case .RTC_Div4:         cr |= 2
    case .RTC_Div2:         cr |= 3
    case .CK_SPRE:          cr |= 4
    case .CK_SPRE_Extended: cr |= 6
    }
    hal.reg_write(&handle.regs.CR, cr)

    // Set wakeup auto-reload value
    hal.reg_write(&handle.regs.WUTR, u32(wakeup_value))

    rtc_lock(handle)
    return true
}

// Configure wakeup timer for microseconds
// Uses fastest RTC clock (RTC/2) for best resolution
// LSE: ~61 µs resolution, max ~4 seconds (4,000,000 µs)
// LSI: ~50 µs resolution, max ~3.3 seconds (3,276,800 µs)
// Returns false if period too long (use ms or seconds instead)
rtc_configure_wakeup_us :: proc "c" (handle: ^RTC_Handle, microseconds: u32) -> bool {
    if microseconds == 0 {
        return false
    }

    // RTC/2 clock frequency depends on source
    // LSE: 32768/2 = 16384 Hz → 61.035 µs/tick
    // LSI: varies by device, set in handle.clock_hz
    freq := handle.clock_hz / 2
    // ticks = µs * freq / 1000000
    ticks := (microseconds * freq + 500000) / 1000000  // Round

    if ticks == 0 {
        ticks = 1
    }
    if ticks > 65536 {
        return false  // Too long, use ms or seconds
    }

    return rtc_configure_wakeup(handle, .RTC_Div2, u16(ticks - 1))
}

// Configure wakeup timer for milliseconds
// Automatically selects best clock divider for the period
// LSE: max ~32 seconds (32,000 ms) with RTC/16
// LSI: max ~26 seconds (26,214 ms) with RTC/16
// For longer periods, use rtc_configure_wakeup_seconds
rtc_configure_wakeup_ms :: proc "c" (handle: ^RTC_Handle, milliseconds: u32) -> bool {
    if milliseconds == 0 {
        return false
    }

    // Try different clock dividers to find best fit
    // RTC/16 gives longest range, RTC/2 gives best resolution

    // Clock frequencies (Hz) for each divider
    // LSE (32768 Hz): /16=2048, /8=4096, /4=8192, /2=16384
    // LSI: varies by device, set in handle.clock_hz

    base_freq := handle.clock_hz

    // Try dividers from slowest (longest range) to fastest (best resolution)
    Divider :: struct { clock: Wakeup_Clock, div: u32 }
    dividers := [4]Divider{
        {.RTC_Div16, 16},
        {.RTC_Div8, 8},
        {.RTC_Div4, 4},
        {.RTC_Div2, 2},
    }

    for d in dividers {
        freq := base_freq / d.div
        // ticks = ms * freq / 1000
        ticks := (milliseconds * freq + 500) / 1000  // Round

        if ticks == 0 {
            ticks = 1
        }

        if ticks <= 65536 {
            return rtc_configure_wakeup(handle, d.clock, u16(ticks - 1))
        }
    }

    return false  // Period too long, use seconds
}

// Configure wakeup timer for seconds
// Uses 1 Hz ck_spre clock for precise second timing
// Range: 1-131072 seconds (~36 hours)
rtc_configure_wakeup_seconds :: proc "c" (handle: ^RTC_Handle, seconds: u32) -> bool {
    if seconds == 0 || seconds > 131072 {
        return false
    }

    if seconds <= 65536 {
        return rtc_configure_wakeup(handle, .CK_SPRE, u16(seconds - 1))
    } else {
        // Use extended mode: adds 65536 to counter
        return rtc_configure_wakeup(handle, .CK_SPRE_Extended, u16(seconds - 65537))
    }
}

// Enable wakeup timer and interrupt
// Also configures EXTI line 20 for Stop mode wakeup
rtc_enable_wakeup :: proc "c" (handle: ^RTC_Handle) {
    // Ensure PWR and backup domain access
    hal.reg_modify(&device.RCC.APB1ENR, .Set, device.RCC_APB1ENR_PWREN_Mask_Shifted)
    hal.reg_modify(&device.PWR.CR, .Set, device.PWR_CR_DBP_Mask_Shifted)

    rtc_unlock(handle)

    // Enable wakeup timer interrupt (WUTIE)
    hal.reg_modify(&handle.regs.CR, .Set, device.RTC_CR_WUTIE_Mask_Shifted)

    // Enable wakeup timer (WUTE)
    hal.reg_modify(&handle.regs.CR, .Set, device.RTC_CR_WUTE_Mask_Shifted)

    rtc_lock(handle)

    // Configure EXTI line 20 for RTC wakeup (needed for Stop mode)
    // Enable rising edge trigger
    hal.reg_modify(&device.EXTI.RTSR1, .Set, device.EXTI_RTSR1_TR20_Mask_Shifted)
    // Enable interrupt mask
    hal.reg_modify(&device.EXTI.IMR1, .Set, device.EXTI_IMR1_MR20_Mask_Shifted)
}

// Disable wakeup timer
rtc_disable_wakeup :: proc "c" (handle: ^RTC_Handle) {
    hal.reg_modify(&device.RCC.APB1ENR, .Set, device.RCC_APB1ENR_PWREN_Mask_Shifted)
    hal.reg_modify(&device.PWR.CR, .Set, device.PWR_CR_DBP_Mask_Shifted)

    rtc_unlock(handle)

    // Disable wakeup timer and interrupt
    hal.reg_modify(&handle.regs.CR, .Clear, device.RTC_CR_WUTE_Mask_Shifted)
    hal.reg_modify(&handle.regs.CR, .Clear, device.RTC_CR_WUTIE_Mask_Shifted)

    rtc_lock(handle)

    // Disable EXTI line 20
    hal.reg_modify(&device.EXTI.IMR1, .Clear, device.EXTI_IMR1_MR20_Mask_Shifted)
}

// Check if wakeup flag is set
rtc_get_wakeup_flag :: proc "c" (handle: ^RTC_Handle) -> bool {
    isr := hal.reg_read(&handle.regs.ISR)
    return (isr & device.RTC_ISR_WUTF_Mask_Shifted) != 0
}

// Clear wakeup flag (must be called after wakeup to allow next wakeup)
rtc_clear_wakeup_flag :: proc "c" (handle: ^RTC_Handle) {
    hal.reg_modify(&device.RCC.APB1ENR, .Set, device.RCC_APB1ENR_PWREN_Mask_Shifted)
    hal.reg_modify(&device.PWR.CR, .Set, device.PWR_CR_DBP_Mask_Shifted)

    rtc_unlock(handle)

    // Clear WUTF by writing 0 (rc_w0 bit)
    isr := hal.reg_read(&handle.regs.ISR)
    isr &= ~u32(device.RTC_ISR_WUTF_Mask_Shifted)
    hal.reg_write(&handle.regs.ISR, isr)

    rtc_lock(handle)

    // Clear EXTI line 20 pending bit (write 1 to clear)
    hal.reg_write(&device.EXTI.PR1, device.EXTI_PR1_PR20_Mask_Shifted)
}

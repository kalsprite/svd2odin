package pwr

// Low Power Modes Driver for STM32
// Supports Sleep, Stop, and Standby modes

import hal "../../hal"
import device "../../cmsis/device"

// Low power mode selection
Power_Mode :: enum {
    Sleep,      // CPU stops, peripherals run, any interrupt wakes
    Stop,       // Most clocks stopped, SRAM retained, EXTI/RTC wakes
    Standby,    // Lowest power, only backup domain retained, wakeup pin/RTC/IWDG wakes
}

// Stop mode regulator configuration
Stop_Regulator :: enum {
    MainOn,     // Main regulator on (faster wakeup, higher power)
    LowPower,   // Low-power regulator (slower wakeup, lower power)
}

// Wakeup pin selection (device-specific, F3 has 3 wakeup pins)
Wakeup_Pin :: enum {
    WKUP1,
    WKUP2,
    WKUP3,
}

// Enter Sleep mode
// CPU clock stops, peripherals continue running
// Any interrupt will wake the device
enter_sleep :: proc "c" () {
    // Clear SLEEPDEEP bit (not deep sleep)
    hal.reg_modify(&device.SCB.SCR, .Clear, device.SCB_SCR_SLEEPDEEP_Mask_Shifted)

    // Wait for interrupt
    wfi()
}

// Enter Sleep mode, automatically sleep on ISR exit
// Useful for interrupt-driven applications
enter_sleep_on_exit :: proc "c" () {
    // Clear SLEEPDEEP, set SLEEPONEXIT
    hal.reg_modify(&device.SCB.SCR, .Clear, device.SCB_SCR_SLEEPDEEP_Mask_Shifted)
    hal.reg_modify(&device.SCB.SCR, .Set, device.SCB_SCR_SLEEPONEXIT_Mask_Shifted)

    wfi()
}

// Disable sleep-on-exit mode
disable_sleep_on_exit :: proc "c" () {
    hal.reg_modify(&device.SCB.SCR, .Clear, device.SCB_SCR_SLEEPONEXIT_Mask_Shifted)
}

// Enter Stop mode
// Most clocks stopped, SRAM and register contents retained
// Wakes on EXTI line, RTC alarm, or other configured wakeup sources
// NOTE: After wakeup, HSI is selected as system clock - reconfigure clocks if needed
enter_stop :: proc "c" (regulator: Stop_Regulator) {
    // Set SLEEPDEEP bit
    hal.reg_modify(&device.SCB.SCR, .Set, device.SCB_SCR_SLEEPDEEP_Mask_Shifted)

    // Clear PDDS (select Stop mode, not Standby)
    hal.reg_modify(&device.PWR.CR, .Clear, device.PWR_CR_PDDS_Mask_Shifted)

    // Configure regulator
    if regulator == .LowPower {
        hal.reg_modify(&device.PWR.CR, .Set, device.PWR_CR_LPDS_Mask_Shifted)
    } else {
        hal.reg_modify(&device.PWR.CR, .Clear, device.PWR_CR_LPDS_Mask_Shifted)
    }

    // Clear wakeup flag
    hal.reg_modify(&device.PWR.CR, .Set, device.PWR_CR_CWUF_Mask_Shifted)

    // Wait for interrupt
    wfi()

    // Clear SLEEPDEEP after wakeup
    hal.reg_modify(&device.SCB.SCR, .Clear, device.SCB_SCR_SLEEPDEEP_Mask_Shifted)
}

// Enter Standby mode
// Lowest power consumption
// Only backup domain (RTC, backup registers) retained
// Wakes on wakeup pin, RTC alarm, IWDG reset, or external reset
// NOTE: After wakeup, device resets and restarts from beginning
enter_standby :: proc "c" () {
    // Set SLEEPDEEP bit
    hal.reg_modify(&device.SCB.SCR, .Set, device.SCB_SCR_SLEEPDEEP_Mask_Shifted)

    // Set PDDS (select Standby mode)
    hal.reg_modify(&device.PWR.CR, .Set, device.PWR_CR_PDDS_Mask_Shifted)

    // Clear wakeup flag
    hal.reg_modify(&device.PWR.CR, .Set, device.PWR_CR_CWUF_Mask_Shifted)

    // Wait for interrupt (device will reset on wakeup)
    wfi()

    // Should never reach here
    for {}
}

// Enable wakeup pin for Standby mode wakeup
enable_wakeup_pin :: proc "c" (pin: Wakeup_Pin) {
    mask: u32
    switch pin {
    case .WKUP1: mask = device.PWR_CSR_EWUP1_Mask_Shifted
    case .WKUP2: mask = device.PWR_CSR_EWUP2_Mask_Shifted
    case .WKUP3: mask = device.PWR_CSR_EWUP3_Mask_Shifted
    }
    hal.reg_modify(&device.PWR.CSR, .Set, mask)
}

// Disable wakeup pin
disable_wakeup_pin :: proc "c" (pin: Wakeup_Pin) {
    mask: u32
    switch pin {
    case .WKUP1: mask = device.PWR_CSR_EWUP1_Mask_Shifted
    case .WKUP2: mask = device.PWR_CSR_EWUP2_Mask_Shifted
    case .WKUP3: mask = device.PWR_CSR_EWUP3_Mask_Shifted
    }
    hal.reg_modify(&device.PWR.CSR, .Clear, mask)
}

// Check if wakeup flag is set (woken from Stop/Standby)
get_wakeup_flag :: proc "c" () -> bool {
    return (hal.reg_read(&device.PWR.CSR) & device.PWR_CSR_WUF_Mask_Shifted) != 0
}

// Clear wakeup flag
clear_wakeup_flag :: proc "c" () {
    hal.reg_modify(&device.PWR.CR, .Set, device.PWR_CR_CWUF_Mask_Shifted)
}

// Check if woken from Standby mode
get_standby_flag :: proc "c" () -> bool {
    return (hal.reg_read(&device.PWR.CSR) & device.PWR_CSR_SBF_Mask_Shifted) != 0
}

// Clear standby flag
clear_standby_flag :: proc "c" () {
    hal.reg_modify(&device.PWR.CR, .Set, device.PWR_CR_CSBF_Mask_Shifted)
}

// Enable access to backup domain (RTC, backup registers)
// Must be called before writing to RTC or backup registers
enable_backup_access :: proc "c" () {
    hal.reg_modify(&device.PWR.CR, .Set, device.PWR_CR_DBP_Mask_Shifted)
}

// Disable access to backup domain
disable_backup_access :: proc "c" () {
    hal.reg_modify(&device.PWR.CR, .Clear, device.PWR_CR_DBP_Mask_Shifted)
}

// ARM low-power and barrier instructions (implemented in pwr_asm.s)
foreign {
    wfi :: proc "c" () ---  // Wait For Interrupt
    wfe :: proc "c" () ---  // Wait For Event
    sev :: proc "c" () ---  // Send Event
    dsb :: proc "c" () ---  // Data Synchronization Barrier
    isb :: proc "c" () ---  // Instruction Synchronization Barrier
}

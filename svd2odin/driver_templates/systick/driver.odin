package systick

import "base:intrinsics"

// SysTick Timer Driver
// 24-bit system timer built into ARM Cortex-M4
// Used for millisecond timekeeping and delays

// SysTick memory-mapped registers
SYSTICK_BASE :: 0xE000E010

SysTick_Registers :: struct {
    CTRL:  u32,  // 0x00: Control and Status
    LOAD:  u32,  // 0x04: Reload Value
    VAL:   u32,  // 0x08: Current Value
    CALIB: u32,  // 0x0C: Calibration Value
}

SysTick := (^SysTick_Registers)(uintptr(SYSTICK_BASE))

// CTRL register bits
SYSTICK_CTRL_ENABLE    :: 0x00000001  // Counter enable
SYSTICK_CTRL_TICKINT   :: 0x00000002  // Counting down to 0 causes SysTick exception
SYSTICK_CTRL_CLKSOURCE :: 0x00000004  // 0=external, 1=processor clock
SYSTICK_CTRL_COUNTFLAG :: 0x00010000  // Returns 1 if timer counted to 0 since last read

// Global tick counter (incremented by SysTick_Handler)
systick_ticks: u32 = 0

// Initialize SysTick for 1ms ticks
// tick_hz: How many ticks per second (e.g., 1000 for 1ms ticks)
// core_clock_hz: CPU clock frequency in Hz (e.g., 8_000_000 for 8MHz HSI)
systick_init :: proc "c" (tick_hz: u32, core_clock_hz: u32) {
    // Calculate reload value for desired tick rate
    // reload = (core_clock_hz / tick_hz) - 1
    reload := (core_clock_hz / tick_hz) - 1

    // SysTick is 24-bit, max reload value is 0xFFFFFF
    if reload > 0xFFFFFF {
        reload = 0xFFFFFF
    }

    // Use volatile writes for hardware registers
    // Disable SysTick during configuration
    intrinsics.volatile_store(&SysTick.CTRL, u32(0))

    // Set reload value
    intrinsics.volatile_store(&SysTick.LOAD, reload)

    // Reset current value (write clears counter)
    intrinsics.volatile_store(&SysTick.VAL, u32(0))

    // Enable SysTick with processor clock and interrupt
    intrinsics.volatile_store(&SysTick.CTRL, SYSTICK_CTRL_ENABLE | SYSTICK_CTRL_TICKINT | SYSTICK_CTRL_CLKSOURCE)
}

// Get current tick count
systick_get_ticks :: proc "c" () -> u32 {
    return intrinsics.atomic_load(&systick_ticks)
}

// Delay for specified number of milliseconds
// Note: Assumes SysTick was initialized with 1000Hz (1ms ticks)
systick_delay_ms :: proc "c" (ms: u32) {
    start := systick_get_ticks()
    for (systick_get_ticks() - start) < ms {
        // Wait
    }
}

// Disable SysTick
systick_disable :: proc "c" () {
    intrinsics.volatile_store(&SysTick.CTRL, u32(0))
}

// SysTick interrupt handler - increments tick counter
// This will be called by the interrupt vector
@(export, link_name="SysTick_Handler")
systick_handler :: proc "c" () {
    intrinsics.atomic_add(&systick_ticks, 1)
}

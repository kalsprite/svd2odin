package interrupts

// Interrupt control utilities
// Provides critical section support for bare metal

// External functions implemented in stubs.c
// These use ARM CMSIS intrinsics __disable_irq() and __enable_irq()
foreign _ {
    @(link_name="disable_interrupts")
    disable_interrupts :: proc "c" () ---

    @(link_name="enable_interrupts")
    enable_interrupts :: proc "c" () ---
}

// Critical section helpers
// Example usage:
//   critical_section_enter()
//   defer critical_section_exit()
//   // ... critical code ...
critical_section_enter :: proc "c" () {
    disable_interrupts()
}

critical_section_exit :: proc "c" () {
    enable_interrupts()
}

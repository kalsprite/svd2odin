package exti

import hal "../../hal"
import device "../../cmsis/device"

// External Interrupt (EXTI) driver
// Configures GPIO pins to trigger interrupts on edges

EXTI_Edge :: enum {
    Rising,
    Falling,
    Both,
}

EXTI_Port :: enum u32 {
    PA = 0,
    PB = 1,
    PC = 2,
    PD = 3,
    PE = 4,
    PF = 5,
    PG = 6,
    PH = 7,
}

// Configure EXTI for a GPIO pin
// pin: 0-15
// port: which GPIO port (PA, PB, etc.)
// edge: Rising, Falling, or Both
exti_configure :: proc "c" (pin: u32, port: EXTI_Port, edge: EXTI_Edge) {
    if pin > 15 {return}

    // Enable SYSCFG clock for EXTI port selection
    hal.reg_modify(&device.RCC.APB2ENR, .Set, device.RCC_APB2ENR_SYSCFGEN_Mask_Shifted)

    // Configure SYSCFG to select port for this EXTI line
    // EXTICR1: lines 0-3, EXTICR2: lines 4-7, etc.
    exticr_idx := pin / 4
    exticr_pos := (pin % 4) * 4

    // Get pointer to correct EXTICR register
    exticr_ptr: ^hal.Register
    switch exticr_idx {
    case 0: exticr_ptr = &device.SYSCFG.EXTICR1
    case 1: exticr_ptr = &device.SYSCFG.EXTICR2
    case 2: exticr_ptr = &device.SYSCFG.EXTICR3
    case 3: exticr_ptr = &device.SYSCFG.EXTICR4
    case: return
    }

    // Clear and set port selection
    hal.reg_modify(exticr_ptr, .Clear, 0xF << exticr_pos)
    hal.reg_modify(exticr_ptr, .Set, u32(port) << exticr_pos)

    line_mask := u32(1) << pin

    // Configure edge trigger
    switch edge {
    case .Rising:
        hal.reg_modify(&device.EXTI.RTSR1, .Set, line_mask)
        hal.reg_modify(&device.EXTI.FTSR1, .Clear, line_mask)
    case .Falling:
        hal.reg_modify(&device.EXTI.RTSR1, .Clear, line_mask)
        hal.reg_modify(&device.EXTI.FTSR1, .Set, line_mask)
    case .Both:
        hal.reg_modify(&device.EXTI.RTSR1, .Set, line_mask)
        hal.reg_modify(&device.EXTI.FTSR1, .Set, line_mask)
    }
}

// Enable EXTI interrupt for a line (must also enable in NVIC)
exti_enable :: proc "c" (pin: u32) {
    if pin > 15 {return}
    hal.reg_modify(&device.EXTI.IMR1, .Set, u32(1) << pin)
}

// Disable EXTI interrupt for a line
exti_disable :: proc "c" (pin: u32) {
    if pin > 15 {return}
    hal.reg_modify(&device.EXTI.IMR1, .Clear, u32(1) << pin)
}

// Check if interrupt is pending for a line
exti_is_pending :: proc "c" (pin: u32) -> bool {
    if pin > 15 { return false }
    pr := hal.reg_read(&device.EXTI.PR1)
    return (pr & (u32(1) << pin)) != 0
}

// Clear pending interrupt (call in ISR)
exti_clear_pending :: proc "c" (pin: u32) {
    if pin > 15 {return}
    // Write 1 to clear
    hal.reg_write(&device.EXTI.PR1, u32(1) << pin)
}

// Software trigger an EXTI line
exti_trigger :: proc "c" (pin: u32) {
    if pin > 15 {return}
    hal.reg_write(&device.EXTI.SWIER1, u32(1) << pin)
}

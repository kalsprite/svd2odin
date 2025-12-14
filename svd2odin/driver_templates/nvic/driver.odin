package nvic

import "base:intrinsics"
import device "../../cmsis/device"

// NVIC (Nested Vectored Interrupt Controller) Driver
// Controls interrupt enable/disable and priority
// Part of ARM Cortex-M core (not STM32-specific)

// NVIC memory-mapped register addresses
NVIC_ISER_BASE :: 0xE000E100  // Interrupt Set Enable Registers
NVIC_ICER_BASE :: 0xE000E180  // Interrupt Clear Enable Registers
NVIC_ISPR_BASE :: 0xE000E200  // Interrupt Set Pending Registers
NVIC_ICPR_BASE :: 0xE000E280  // Interrupt Clear Pending Registers
NVIC_IPR_BASE  :: 0xE000E400  // Interrupt Priority Registers

// IRQn is an alias to the generated Interrupt enum from SVD
// Use device.Interrupt values like: .USART1_EXTI25, .EXTI0, .TIM2, etc.
// Handler names must match: USART1_EXTI25_IRQHandler, EXTI0_IRQHandler, etc.
IRQn :: device.Interrupt

// Enable an interrupt
nvic_enable_irq :: proc "c" (irq: IRQn) {
    irq_num := u32(irq)
    reg := cast(^u32)uintptr(NVIC_ISER_BASE + (irq_num >> 5) * 4)
    intrinsics.volatile_store(reg, u32(1) << (irq_num & 0x1F))
}

// Disable an interrupt
nvic_disable_irq :: proc "c" (irq: IRQn) {
    irq_num := u32(irq)
    reg := cast(^u32)uintptr(NVIC_ICER_BASE + (irq_num >> 5) * 4)
    intrinsics.volatile_store(reg, u32(1) << (irq_num & 0x1F))
}

// Set pending flag for an interrupt
nvic_set_pending :: proc "c" (irq: IRQn) {
    irq_num := u32(irq)
    reg := cast(^u32)uintptr(NVIC_ISPR_BASE + (irq_num >> 5) * 4)
    intrinsics.volatile_store(reg, u32(1) << (irq_num & 0x1F))
}

// Clear pending flag for an interrupt
nvic_clear_pending :: proc "c" (irq: IRQn) {
    irq_num := u32(irq)
    reg := cast(^u32)uintptr(NVIC_ICPR_BASE + (irq_num >> 5) * 4)
    intrinsics.volatile_store(reg, u32(1) << (irq_num & 0x1F))
}

// Get pending status of an interrupt
nvic_get_pending :: proc "c" (irq: IRQn) -> bool {
    irq_num := u32(irq)
    reg := cast(^u32)uintptr(NVIC_ISPR_BASE + (irq_num >> 5) * 4)
    return (intrinsics.volatile_load(reg) & (u32(1) << (irq_num & 0x1F))) != 0
}

// Set interrupt priority (0-255, lower is higher priority)
// Note: STM32F3 only implements 4 bits (16 priority levels)
nvic_set_priority :: proc "c" (irq: IRQn, priority: u8) {
    reg := cast(^u8)uintptr(NVIC_IPR_BASE + u32(irq))
    intrinsics.volatile_store(reg, priority)
}

// Get interrupt priority
nvic_get_priority :: proc "c" (irq: IRQn) -> u8 {
    reg := cast(^u8)uintptr(NVIC_IPR_BASE + u32(irq))
    return intrinsics.volatile_load(reg)
}

// Check if an interrupt is enabled
nvic_is_enabled :: proc "c" (irq: IRQn) -> bool {
    irq_num := u32(irq)
    reg := cast(^u32)uintptr(NVIC_ISER_BASE + (irq_num >> 5) * 4)
    return (intrinsics.volatile_load(reg) & (u32(1) << (irq_num & 0x1F))) != 0
}

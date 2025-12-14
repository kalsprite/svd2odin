package dma

import "base:intrinsics"

// DMA (Direct Memory Access) Driver for STM32F3
// Provides high-speed data transfers without CPU intervention
//
// STM32F303 has:
// - DMA1: 7 channels
// - DMA2: 5 channels
//
// Each channel can transfer data between:
// - Memory to Peripheral
// - Peripheral to Memory
// - Memory to Memory

// DMA controller selection
DMA_Controller :: enum {
    DMA1,
    DMA2,
}

// DMA transfer direction
DMA_Direction :: enum u8 {
    PeripheralToMemory = 0,  // Read from peripheral
    MemoryToPeripheral = 1,  // Write to peripheral
    MemoryToMemory     = 2,  // Memory copy
}

// DMA data size
DMA_Size :: enum u8 {
    Byte     = 0,  // 8-bit
    HalfWord = 1,  // 16-bit
    Word     = 2,  // 32-bit
}

// DMA priority level
DMA_Priority :: enum u8 {
    Low       = 0,
    Medium    = 1,
    High      = 2,
    VeryHigh  = 3,
}

// DMA configuration
DMA_Config :: struct {
    source:           rawptr,       // Source address
    dest:             rawptr,       // Destination address
    count:            u16,          // Number of data items to transfer
    direction:        DMA_Direction,
    mem_size:         DMA_Size,     // Memory data size
    periph_size:      DMA_Size,     // Peripheral data size
    mem_increment:    bool,         // Auto-increment memory address
    periph_increment: bool,         // Auto-increment peripheral address
    circular:         bool,         // Circular mode (restart after complete)
    priority:         DMA_Priority,
}

// DMA interrupt types
DMA_Interrupt :: enum {
    TransferComplete,  // Full transfer done
    HalfTransfer,      // Half transfer done
    TransferError,     // Transfer error occurred
}

// DMA channel registers (one per channel)
DMA_Channel_Registers :: struct {
    CCR:   u32,  // 0x00: Channel configuration
    CNDTR: u32,  // 0x04: Number of data register
    CPAR:  u32,  // 0x08: Peripheral address
    CMAR:  u32,  // 0x0C: Memory address
}

// DMA controller registers
DMA_Registers :: struct {
    ISR:      u32,                        // 0x00: Interrupt status
    IFCR:     u32,                        // 0x04: Interrupt flag clear
    _reserved: [2]u32,
    channels: [7]DMA_Channel_Registers,   // 0x08+: Channel registers
}

// DMA base addresses
DMA1_BASE :: 0x40020000
DMA2_BASE :: 0x40020400

// Helper to get DMA registers
@(private)
dma_regs :: proc "c" (controller: DMA_Controller) -> ^DMA_Registers {
    switch controller {
    case .DMA1: return (^DMA_Registers)(uintptr(DMA1_BASE))
    case .DMA2: return (^DMA_Registers)(uintptr(DMA2_BASE))
    }
    return nil
}

// CCR register bits
DMA_CCR_EN        :: 0x00000001  // Channel enable
DMA_CCR_TCIE      :: 0x00000002  // Transfer complete interrupt enable
DMA_CCR_HTIE      :: 0x00000004  // Half transfer interrupt enable
DMA_CCR_TEIE      :: 0x00000008  // Transfer error interrupt enable
DMA_CCR_DIR       :: 0x00000010  // Data transfer direction
DMA_CCR_CIRC      :: 0x00000020  // Circular mode
DMA_CCR_PINC      :: 0x00000040  // Peripheral increment mode
DMA_CCR_MINC      :: 0x00000080  // Memory increment mode
DMA_CCR_PSIZE_POS :: 8           // Peripheral size position
DMA_CCR_MSIZE_POS :: 10          // Memory size position
DMA_CCR_PL_POS    :: 12          // Priority level position
DMA_CCR_MEM2MEM   :: 0x00004000  // Memory to memory mode

// ISR/IFCR bit positions (per channel)
DMA_GIF_POS  :: 0   // Global interrupt flag
DMA_TCIF_POS :: 1   // Transfer complete flag
DMA_HTIF_POS :: 2   // Half transfer flag
DMA_TEIF_POS :: 4   // Transfer error flag

// Configure a DMA channel
dma_configure_channel :: proc "c" (
    controller: DMA_Controller,
    channel: u8,  // 1-7 for DMA1, 1-5 for DMA2
    config: DMA_Config,
) {
    if channel < 1 || channel > 7 {
        return
    }

    regs := dma_regs(controller)
    ch := &regs.channels[channel - 1]

    // Disable channel during configuration
    enable_mask := DMA_CCR_EN
    ch.CCR &= ~enable_mask

    // Clear any pending flags
    shift := (channel - 1) * 4
    regs.IFCR = 0xF << shift

    // Set addresses based on direction
    switch config.direction {
    case .PeripheralToMemory:
        ch.CPAR = u32(uintptr(config.source))  // Peripheral = source
        ch.CMAR = u32(uintptr(config.dest))    // Memory = destination

    case .MemoryToPeripheral:
        ch.CPAR = u32(uintptr(config.dest))    // Peripheral = destination
        ch.CMAR = u32(uintptr(config.source))  // Memory = source

    case .MemoryToMemory:
        ch.CPAR = u32(uintptr(config.source))  // Use peripheral as source
        ch.CMAR = u32(uintptr(config.dest))    // Memory = destination
    }

    // Set transfer count
    ch.CNDTR = u32(config.count)

    // Build CCR value
    ccr: u32 = 0

    // Direction
    if config.direction == .MemoryToPeripheral {
        ccr |= DMA_CCR_DIR
    }

    // Memory to memory mode
    if config.direction == .MemoryToMemory {
        ccr |= DMA_CCR_MEM2MEM
    }

    // Circular mode
    if config.circular {
        ccr |= DMA_CCR_CIRC
    }

    // Increment modes
    if config.periph_increment {
        ccr |= DMA_CCR_PINC
    }
    if config.mem_increment {
        ccr |= DMA_CCR_MINC
    }

    // Data sizes
    ccr |= u32(config.periph_size) << DMA_CCR_PSIZE_POS
    ccr |= u32(config.mem_size) << DMA_CCR_MSIZE_POS

    // Priority
    ccr |= u32(config.priority) << DMA_CCR_PL_POS

    ch.CCR = ccr
}

// Start DMA transfer on a channel
dma_start :: proc "c" (controller: DMA_Controller, channel: u8) {
    if channel < 1 || channel > 7 {
        return
    }

    regs := dma_regs(controller)
    ch := &regs.channels[channel - 1]

    // Enable channel
    ch.CCR |= DMA_CCR_EN
}

// Stop DMA transfer on a channel
dma_stop :: proc "c" (controller: DMA_Controller, channel: u8) {
    if channel < 1 || channel > 7 {
        return
    }

    regs := dma_regs(controller)
    ch := &regs.channels[channel - 1]

    // Disable channel
    enable_mask := DMA_CCR_EN
    ch.CCR &= ~enable_mask

    // Wait for channel to disable (recommended by reference manual)
    for (ch.CCR & DMA_CCR_EN) != 0 {
        // Busy wait
    }
}

// Check if transfer is complete
dma_is_complete :: proc "c" (controller: DMA_Controller, channel: u8) -> bool {
    if channel < 1 || channel > 7 {
        return false
    }

    regs := dma_regs(controller)
    shift := (channel - 1) * 4
    return (regs.ISR & (1 << (shift + DMA_TCIF_POS))) != 0
}

// Check if transfer error occurred
dma_has_error :: proc "c" (controller: DMA_Controller, channel: u8) -> bool {
    if channel < 1 || channel > 7 {
        return false
    }

    regs := dma_regs(controller)
    shift := (channel - 1) * 4
    return (regs.ISR & (1 << (shift + DMA_TEIF_POS))) != 0
}

// Clear transfer complete flag
dma_clear_complete :: proc "c" (controller: DMA_Controller, channel: u8) {
    if channel < 1 || channel > 7 {
        return
    }

    regs := dma_regs(controller)
    shift := (channel - 1) * 4
    regs.IFCR = 1 << (shift + DMA_TCIF_POS)
}

// Clear all flags for a channel
dma_clear_flags :: proc "c" (controller: DMA_Controller, channel: u8) {
    if channel < 1 || channel > 7 {
        return
    }

    regs := dma_regs(controller)
    shift := (channel - 1) * 4
    regs.IFCR = 0xF << shift
}

// Enable interrupt for a channel
dma_enable_interrupt :: proc "c" (
    controller: DMA_Controller,
    channel: u8,
    interrupt: DMA_Interrupt,
) {
    if channel < 1 || channel > 7 {
        return
    }

    regs := dma_regs(controller)
    ch := &regs.channels[channel - 1]

    switch interrupt {
    case .TransferComplete:
        ch.CCR |= DMA_CCR_TCIE
    case .HalfTransfer:
        ch.CCR |= DMA_CCR_HTIE
    case .TransferError:
        ch.CCR |= DMA_CCR_TEIE
    }
}

// Disable interrupt for a channel
dma_disable_interrupt :: proc "c" (
    controller: DMA_Controller,
    channel: u8,
    interrupt: DMA_Interrupt,
) {
    if channel < 1 || channel > 7 {
        return
    }

    regs := dma_regs(controller)
    ch := &regs.channels[channel - 1]

    switch interrupt {
    case .TransferComplete:
        mask := DMA_CCR_TCIE
        ch.CCR &= ~mask
    case .HalfTransfer:
        mask := DMA_CCR_HTIE
        ch.CCR &= ~mask
    case .TransferError:
        mask := DMA_CCR_TEIE
        ch.CCR &= ~mask
    }
}

// Get remaining transfer count
dma_get_count :: proc "c" (controller: DMA_Controller, channel: u8) -> u16 {
    if channel < 1 || channel > 7 {
        return 0
    }

    regs := dma_regs(controller)
    ch := &regs.channels[channel - 1]
    return u16(ch.CNDTR)
}

// Wait for transfer to complete (blocking)
dma_wait_complete :: proc "c" (controller: DMA_Controller, channel: u8) {
    for !dma_is_complete(controller, channel) {
        // Could use WFI here for power saving
    }
}

// Perform a blocking memory-to-memory copy using DMA
dma_memcpy :: proc "c" (dest: rawptr, src: rawptr, size: int, controller := DMA_Controller.DMA1, channel: u8 = 1) {
    config := DMA_Config{
        source = src,
        dest = dest,
        count = u16(size),
        direction = .MemoryToMemory,
        mem_size = .Byte,
        periph_size = .Byte,
        mem_increment = true,
        periph_increment = true,
        circular = false,
        priority = .High,
    }

    dma_configure_channel(controller, channel, config)
    dma_start(controller, channel)
    dma_wait_complete(controller, channel)
    dma_clear_flags(controller, channel)
}

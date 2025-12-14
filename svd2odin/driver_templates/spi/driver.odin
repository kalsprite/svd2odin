package spi

import "base:intrinsics"
import hal "../../hal"
import device "../../cmsis/device"

// Portable SPI driver for STM32
// Works with any SPI peripheral (SPI1, SPI2, SPI3, etc.)

// SPI Mode (CPOL + CPHA combinations)
SPI_Mode :: enum u32 {
    Mode0 = 0,  // CPOL=0, CPHA=0: Clock idle low, sample on first edge
    Mode1 = 1,  // CPOL=0, CPHA=1: Clock idle low, sample on second edge
    Mode2 = 2,  // CPOL=1, CPHA=0: Clock idle high, sample on first edge
    Mode3 = 3,  // CPOL=1, CPHA=1: Clock idle high, sample on second edge
}

// SPI Clock divider (baud rate)
SPI_Speed :: enum u32 {
    Div2   = 0,  // PCLK / 2
    Div4   = 1,  // PCLK / 4
    Div8   = 2,  // PCLK / 8
    Div16  = 3,  // PCLK / 16
    Div32  = 4,  // PCLK / 32
    Div64  = 5,  // PCLK / 64
    Div128 = 6,  // PCLK / 128
    Div256 = 7,  // PCLK / 256
}

// Bit order
SPI_BitOrder :: enum u32 {
    MSBFirst = 0,  // MSB transmitted first (most common)
    LSBFirst = 1,  // LSB transmitted first
}

// Data size
SPI_DataSize :: enum u32 {
    EightBit  = 7,   // 8-bit data
    SixteenBit = 15, // 16-bit data
}

// SPI Configuration
SPI_Config :: struct {
    mode:      SPI_Mode,
    speed:     SPI_Speed,
    data_size: SPI_DataSize,
    bit_order: SPI_BitOrder,
}

// SPI Handle (generic pointer to any SPI peripheral)
SPI_Handle :: struct {
    regs: ^device.SPI1_Registers,  // Works for SPI1, SPI2, etc. (same layout)
    data_size: SPI_DataSize,       // Configured data size (for proper DR access)
}

// Initialize SPI peripheral in master mode
spi_init :: proc "c" (handle: ^SPI_Handle, config: SPI_Config) {
    // Store data size for proper DR access later
    handle.data_size = config.data_size

    // Disable SPI during configuration
    hal.reg_modify(&handle.regs.CR1, .Clear, device.SPI1_CR1_SPE_Mask_Shifted)

    // Configure CR1:
    // - Master mode
    // - Software slave management (user controls CS pin)
    // - Baud rate
    // - CPOL/CPHA (mode)
    // - Bit order
    cr1: u32 = 0
    cr1 |= u32(device.SPI1_CR1_MSTR.Master) << device.SPI1_CR1_MSTR_Pos           // Master
    cr1 |= u32(device.SPI1_CR1_SSM.Enabled) << device.SPI1_CR1_SSM_Pos            // Software slave mgmt
    cr1 |= u32(device.SPI1_CR1_SSI.SlaveNotSelected) << device.SPI1_CR1_SSI_Pos  // Internal slave select high
    cr1 |= u32(config.speed) << device.SPI1_CR1_BR_Pos                           // Baud rate
    cr1 |= u32(config.bit_order) << device.SPI1_CR1_LSBFIRST_Pos                // Bit order

    // Set CPOL and CPHA based on mode
    cpol := (u32(config.mode) >> 1) & 1  // Bit 1 of mode
    cpha := u32(config.mode) & 1          // Bit 0 of mode
    cr1 |= cpol << device.SPI1_CR1_CPOL_Pos
    cr1 |= cpha << device.SPI1_CR1_CPHA_Pos

    hal.reg_write(&handle.regs.CR1, cr1)

    // Configure CR2:
    // - Data size
    // - FRXTH (FIFO threshold) for 8-bit mode
    cr2: u32 = 0
    cr2 |= u32(config.data_size) << device.SPI1_CR2_DS_Pos

    // For 8-bit mode, set FRXTH to generate RXNE on quarter-full (8 bits)
    if config.data_size == .EightBit {
        cr2 |= 1 << device.SPI1_CR2_FRXTH_Pos
    }

    hal.reg_write(&handle.regs.CR2, cr2)

    // Enable SPI
    hal.reg_modify(&handle.regs.CR1, .Set, device.SPI1_CR1_SPE_Mask_Shifted)
}

// Wait for TX buffer to be empty
spi_wait_txe :: proc "c" (handle: ^SPI_Handle) {
    for {
        sr := hal.reg_read(&handle.regs.SR)
        if (sr & device.SPI1_SR_TXE_Mask_Shifted) != 0 {
            break
        }
    }
}

// Wait for RX buffer to have data
spi_wait_rxne :: proc "c" (handle: ^SPI_Handle) {
    for {
        sr := hal.reg_read(&handle.regs.SR)
        if (sr & device.SPI1_SR_RXNE_Mask_Shifted) != 0 {
            break
        }
    }
}

// Wait for SPI to not be busy
spi_wait_not_busy :: proc "c" (handle: ^SPI_Handle) {
    for {
        sr := hal.reg_read(&handle.regs.SR)
        if (sr & device.SPI1_SR_BSY_Mask_Shifted) == 0 {
            break
        }
    }
}

// Transfer one byte (blocking, full duplex)
// IMPORTANT: For STM32F3, we must use 8-bit access to the DR register when in 8-bit mode.
// A 32-bit write to DR is interpreted as 4 bytes by the FIFO, causing corruption.
spi_transfer_byte :: proc "c" (handle: ^SPI_Handle, tx_byte: u8) -> (rx_byte: u8) {
    spi_wait_txe(handle)

    // Get byte pointer to DR register for proper 8-bit access
    dr_byte := cast(^u8)&handle.regs.DR
    intrinsics.volatile_store(dr_byte, tx_byte)

    spi_wait_rxne(handle)
    rx_byte = intrinsics.volatile_load(dr_byte)
    return
}

// Transfer one halfword (16-bit, blocking, full duplex)
// For 16-bit data size mode
spi_transfer_halfword :: proc "c" (handle: ^SPI_Handle, tx_data: u16) -> (rx_data: u16) {
    spi_wait_txe(handle)

    // Get halfword pointer to DR register for 16-bit access
    dr_halfword := cast(^u16)&handle.regs.DR
    intrinsics.volatile_store(dr_halfword, tx_data)

    spi_wait_rxne(handle)
    rx_data = intrinsics.volatile_load(dr_halfword)
    return
}

// Flush RX FIFO - clear any leftover data
// Call this before starting a new SPI transaction to avoid stale data
spi_flush_rx :: proc "c" (handle: ^SPI_Handle) {
    spi_wait_not_busy(handle)
    dr_byte := cast(^u8)&handle.regs.DR
    // Read DR until RXNE is clear (empty the FIFO)
    for {
        sr := hal.reg_read(&handle.regs.SR)
        if (sr & device.SPI1_SR_RXNE_Mask_Shifted) == 0 {
            break
        }
        _ = intrinsics.volatile_load(dr_byte)
    }
}

// Transmit multiple bytes (blocking)
spi_transmit :: proc "c" (handle: ^SPI_Handle, data: []u8) {
    for byte in data {
        _ = spi_transfer_byte(handle, byte)
    }
    spi_wait_not_busy(handle)
}

// Receive multiple bytes (blocking)
spi_receive :: proc "c" (handle: ^SPI_Handle, data: []u8) {
    for i in 0..<len(data) {
        data[i] = spi_transfer_byte(handle, 0xFF)  // Send dummy byte
    }
    spi_wait_not_busy(handle)
}

// Full-duplex transfer (blocking)
spi_transfer :: proc "c" (handle: ^SPI_Handle, tx_data: []u8, rx_data: []u8) {
    len := min(len(tx_data), len(rx_data))
    for i in 0..<len {
        rx_data[i] = spi_transfer_byte(handle, tx_data[i])
    }
    spi_wait_not_busy(handle)
}

// ========== DMA Support ==========

// Enable SPI TX DMA
spi_enable_tx_dma :: proc "c" (handle: ^SPI_Handle) {
    // Set TXDMAEN bit in CR2 (bit 1)
    hal.reg_modify(&handle.regs.CR2, .Set, 1 << 1)
}

// Enable SPI RX DMA
spi_enable_rx_dma :: proc "c" (handle: ^SPI_Handle) {
    // Set RXDMAEN bit in CR2 (bit 0)
    hal.reg_modify(&handle.regs.CR2, .Set, 1 << 0)
}

// Disable SPI TX DMA
spi_disable_tx_dma :: proc "c" (handle: ^SPI_Handle) {
    hal.reg_modify(&handle.regs.CR2, .Clear, 1 << 1)
}

// Disable SPI RX DMA
spi_disable_rx_dma :: proc "c" (handle: ^SPI_Handle) {
    hal.reg_modify(&handle.regs.CR2, .Clear, 1 << 0)
}

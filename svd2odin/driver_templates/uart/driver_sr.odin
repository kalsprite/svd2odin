package uart

import hal "../../hal"
import device "../../cmsis/device"

// Portable UART/USART driver for STM32 (SR/DR register style)
// For F1/F2/F4/F7 families
// Works with any USART peripheral (USART1, USART2, USART3, UART4, UART5)

// Baud rate presets
UART_BaudRate :: enum u32 {
    Baud9600   = 9600,
    Baud19200  = 19200,
    Baud38400  = 38400,
    Baud57600  = 57600,
    Baud115200 = 115200,
    Baud230400 = 230400,
    Baud460800 = 460800,
    Baud921600 = 921600,
}

// Data bits
UART_DataBits :: enum u32 {
    Bits8 = 0,  // 8 data bits
    Bits9 = 1,  // 9 data bits
}

// Stop bits
UART_StopBits :: enum u32 {
    Stop1   = 0,  // 1 stop bit
    Stop0p5 = 1,  // 0.5 stop bits
    Stop2   = 2,  // 2 stop bits
    Stop1p5 = 3,  // 1.5 stop bits
}

// Parity
UART_Parity :: enum u32 {
    None = 0,  // No parity
    Even = 1,  // Even parity
    Odd  = 2,  // Odd parity
}

// UART Configuration
UART_Config :: struct {
    baud_rate:  UART_BaudRate,
    data_bits:  UART_DataBits,
    stop_bits:  UART_StopBits,
    parity:     UART_Parity,
}

// UART Handle (generic pointer to any USART peripheral)
UART_Handle :: struct {
    regs: ^device.USART1_Registers,  // Works for USART1-3, UART4-5 (same layout)
    pclk: u32,  // Peripheral clock frequency (needed for baud rate calculation)
}

// Initialize UART peripheral
uart_init :: proc "c" (handle: ^UART_Handle, config: UART_Config) {
    // Disable UART during configuration
    hal.reg_modify(&handle.regs.CR1, .Clear, device.USART1_CR1_UE_Mask_Shifted)

    // Configure baud rate
    // BRR = PCLK / baudrate (for 16x oversampling)
    brr := handle.pclk / u32(config.baud_rate)
    hal.reg_write(&handle.regs.BRR, brr)

    // Configure CR2: Stop bits
    cr2: u32 = 0
    cr2 |= u32(config.stop_bits) << device.USART1_CR2_STOP_Pos
    hal.reg_write(&handle.regs.CR2, cr2)

    // Configure CR1:
    // - Word length (data bits)
    // - Parity control
    // - TX enable
    // - RX enable
    cr1: u32 = 0
    cr1 |= u32(config.data_bits) << device.USART1_CR1_M_Pos  // Data bits

    // Parity
    if config.parity == .Even {
        cr1 |= (1 << device.USART1_CR1_PCE_Pos)  // Enable parity
        // PS = 0 for even parity (bit already 0)
    } else if config.parity == .Odd {
        cr1 |= (1 << device.USART1_CR1_PCE_Pos)  // Enable parity
        cr1 |= (1 << device.USART1_CR1_PS_Pos)   // PS = 1 for odd parity
    }

    // Enable transmitter and receiver
    cr1 |= (1 << device.USART1_CR1_TE_Pos)
    cr1 |= (1 << device.USART1_CR1_RE_Pos)

    hal.reg_write(&handle.regs.CR1, cr1)

    // Enable UART
    hal.reg_modify(&handle.regs.CR1, .Set, device.USART1_CR1_UE_Mask_Shifted)
}

// Wait for TX buffer to be empty
uart_wait_txe :: proc "c" (handle: ^UART_Handle) {
    for {
        status := hal.reg_read(&handle.regs.SR)
        if (status & device.USART1_SR_TXE_Mask_Shifted) != 0 {
            break
        }
    }
}

// Wait for transmission complete
uart_wait_tc :: proc "c" (handle: ^UART_Handle) {
    for {
        status := hal.reg_read(&handle.regs.SR)
        if (status & device.USART1_SR_TC_Mask_Shifted) != 0 {
            break
        }
    }
}

// Wait for RX buffer to have data
uart_wait_rxne :: proc "c" (handle: ^UART_Handle) {
    for {
        status := hal.reg_read(&handle.regs.SR)
        if (status & device.USART1_SR_RXNE_Mask_Shifted) != 0 {
            break
        }
    }
}

// Check if data is available
uart_data_available :: proc "c" (handle: ^UART_Handle) -> bool {
    status := hal.reg_read(&handle.regs.SR)
    return (status & device.USART1_SR_RXNE_Mask_Shifted) != 0
}

// Transmit one byte (blocking)
uart_transmit_byte :: proc "c" (handle: ^UART_Handle, data: u8) {
    uart_wait_txe(handle)
    hal.reg_write(&handle.regs.DR, u32(data))
}

// Receive one byte (blocking)
uart_receive_byte :: proc "c" (handle: ^UART_Handle) -> (data: u8) {
    uart_wait_rxne(handle)
    data = u8(hal.reg_read(&handle.regs.DR))
    return
}

// Transmit multiple bytes (blocking)
uart_transmit :: proc "c" (handle: ^UART_Handle, data: []u8) {
    for byte in data {
        uart_transmit_byte(handle, byte)
    }
    uart_wait_tc(handle)  // Wait for last byte to complete
}

// Receive multiple bytes (blocking)
uart_receive :: proc "c" (handle: ^UART_Handle, data: []u8) {
    for i in 0..<len(data) {
        data[i] = uart_receive_byte(handle)
    }
}

// Transmit string (blocking)
uart_transmit_string :: proc "c" (handle: ^UART_Handle, str: string) {
    for i in 0..<len(str) {
        uart_transmit_byte(handle, str[i])
    }
    uart_wait_tc(handle)
}

// ========== DMA Support ==========

// Enable UART TX DMA
uart_enable_tx_dma :: proc "c" (handle: ^UART_Handle) {
    // Set DMAT bit in CR3 (bit 7)
    hal.reg_modify(&handle.regs.CR3, .Set, 1 << 7)
}

// Enable UART RX DMA
uart_enable_rx_dma :: proc "c" (handle: ^UART_Handle) {
    // Set DMAR bit in CR3 (bit 6)
    hal.reg_modify(&handle.regs.CR3, .Set, 1 << 6)
}

// Disable UART TX DMA
uart_disable_tx_dma :: proc "c" (handle: ^UART_Handle) {
    hal.reg_modify(&handle.regs.CR3, .Clear, 1 << 7)
}

// Disable UART RX DMA
uart_disable_rx_dma :: proc "c" (handle: ^UART_Handle) {
    hal.reg_modify(&handle.regs.CR3, .Clear, 1 << 6)
}

// ========== Error Checking ==========

// UART Error codes
UART_Error :: enum {
    None = 0,
    Overrun,     // RX overrun (data lost)
    FrameError,  // Framing error
    ParityError, // Parity error
    NoiseError,  // Noise detected
}

// Check for errors
uart_check_errors :: proc "c" (handle: ^UART_Handle) -> UART_Error {
    status := hal.reg_read(&handle.regs.SR)

    // Overrun error (bit 3)
    if (status & (1 << 3)) != 0 {
        return .Overrun
    }

    // Framing error (bit 1)
    if (status & (1 << 1)) != 0 {
        return .FrameError
    }

    // Parity error (bit 0)
    if (status & (1 << 0)) != 0 {
        return .ParityError
    }

    // Noise error (bit 2)
    if (status & (1 << 2)) != 0 {
        return .NoiseError
    }

    return .None
}

// Clear error flags (SR/DR style: read SR then read DR)
uart_clear_errors :: proc "c" (handle: ^UART_Handle) {
    _ = hal.reg_read(&handle.regs.SR)
    _ = hal.reg_read(&handle.regs.DR)
}

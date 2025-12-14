package uart

import "base:intrinsics"
import hal "../../hal"
import device "../../cmsis/device"

// Portable UART/USART driver for STM32
// Works with any USART peripheral (USART1, USART2, USART3, UART4, UART5)
// Supports both polling and interrupt-driven modes with ring buffers

// Baud rate presets (assuming 72MHz PCLK2 for USART1, 36MHz PCLK1 for others)
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
        cr1 |= u32(device.USART1_CR1_PCE.Enabled) << device.USART1_CR1_PCE_Pos  // Enable parity
        cr1 |= u32(device.USART1_CR1_PS.Even) << device.USART1_CR1_PS_Pos       // Even parity
    } else if config.parity == .Odd {
        cr1 |= u32(device.USART1_CR1_PCE.Enabled) << device.USART1_CR1_PCE_Pos  // Enable parity
        cr1 |= u32(device.USART1_CR1_PS.Odd) << device.USART1_CR1_PS_Pos        // Odd parity
    }

    // Enable transmitter and receiver
    cr1 |= u32(device.USART1_CR1_TE.Enabled) << device.USART1_CR1_TE_Pos
    cr1 |= u32(device.USART1_CR1_RE.Enabled) << device.USART1_CR1_RE_Pos

    hal.reg_write(&handle.regs.CR1, cr1)

    // Enable UART
    hal.reg_modify(&handle.regs.CR1, .Set, device.USART1_CR1_UE_Mask_Shifted)
}

// Wait for TX buffer to be empty
uart_wait_txe :: proc "c" (handle: ^UART_Handle) {
    for {
        isr := hal.reg_read(&handle.regs.ISR)
        if (isr & device.USART1_ISR_TXE_Mask_Shifted) != 0 {
            break
        }
    }
}

// Wait for transmission complete
uart_wait_tc :: proc "c" (handle: ^UART_Handle) {
    for {
        isr := hal.reg_read(&handle.regs.ISR)
        if (isr & device.USART1_ISR_TC_Mask_Shifted) != 0 {
            break
        }
    }
}

// Wait for RX buffer to have data
uart_wait_rxne :: proc "c" (handle: ^UART_Handle) {
    for {
        isr := hal.reg_read(&handle.regs.ISR)
        if (isr & device.USART1_ISR_RXNE_Mask_Shifted) != 0 {
            break
        }
    }
}

// Check if data is available
uart_data_available :: proc "c" (handle: ^UART_Handle) -> bool {
    isr := hal.reg_read(&handle.regs.ISR)
    return (isr & device.USART1_ISR_RXNE_Mask_Shifted) != 0
}

// Transmit one byte (blocking)
uart_transmit_byte :: proc "c" (handle: ^UART_Handle, data: u8) {
    uart_wait_txe(handle)
    hal.reg_write(&handle.regs.TDR, u32(data))
}

// Receive one byte (blocking)
uart_receive_byte :: proc "c" (handle: ^UART_Handle) -> (data: u8) {
    uart_wait_rxne(handle)
    data = u8(hal.reg_read(&handle.regs.RDR))
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
    isr := hal.reg_read(&handle.regs.ISR)

    // Overrun error (bit 3)
    if (isr & (1 << 3)) != 0 {
        return .Overrun
    }

    // Framing error (bit 1)
    if (isr & (1 << 1)) != 0 {
        return .FrameError
    }

    // Parity error (bit 0)
    if (isr & (1 << 0)) != 0 {
        return .ParityError
    }

    // Noise error (bit 2)
    if (isr & (1 << 2)) != 0 {
        return .NoiseError
    }

    return .None
}

// Clear error flags
uart_clear_errors :: proc "c" (handle: ^UART_Handle) {
    // Clear ORE, FE, NF, PE flags by writing to ICR
    icr: u32 = 0
    icr |= (1 << 3)  // ORECF - Clear overrun
    icr |= (1 << 1)  // FECF  - Clear framing error
    icr |= (1 << 2)  // NCF   - Clear noise
    icr |= (1 << 0)  // PECF  - Clear parity error
    hal.reg_write(&handle.regs.ICR, icr)
}

// ========== Interrupt-Driven Mode with Ring Buffers ==========

// Ring buffer size (must be power of 2)
UART_RX_BUFFER_SIZE :: 128
UART_TX_BUFFER_SIZE :: 128

// Ring buffer structure
// Uses head/tail indices with masking for efficient circular access
UART_RingBuffer :: struct {
    buffer: [128]u8,  // Fixed size buffer
    head:   u32,      // Write index (producer)
    tail:   u32,      // Read index (consumer)
}

// Extended UART Handle for interrupt mode
// Contains ring buffers for RX and TX
UART_Handle_IRQ :: struct {
    regs:      ^device.USART1_Registers,
    pclk:      u32,
    rx_buffer: UART_RingBuffer,
    tx_buffer: UART_RingBuffer,
    tx_busy:   bool,  // TX interrupt active
}

// Initialize ring buffer
ringbuf_init :: proc "c" (rb: ^UART_RingBuffer) {
    rb.head = 0
    rb.tail = 0
}

// Check if ring buffer is empty
ringbuf_is_empty :: proc "c" (rb: ^UART_RingBuffer) -> bool {
    return intrinsics.volatile_load(&rb.head) == intrinsics.volatile_load(&rb.tail)
}

// Check if ring buffer is full
ringbuf_is_full :: proc "c" (rb: ^UART_RingBuffer) -> bool {
    head := intrinsics.volatile_load(&rb.head)
    tail := intrinsics.volatile_load(&rb.tail)
    return ((head + 1) & (UART_RX_BUFFER_SIZE - 1)) == tail
}

// Get number of bytes available to read
ringbuf_available :: proc "c" (rb: ^UART_RingBuffer) -> u32 {
    head := intrinsics.volatile_load(&rb.head)
    tail := intrinsics.volatile_load(&rb.tail)
    return (head - tail) & (UART_RX_BUFFER_SIZE - 1)
}

// Get free space in buffer
ringbuf_free :: proc "c" (rb: ^UART_RingBuffer) -> u32 {
    return UART_RX_BUFFER_SIZE - 1 - ringbuf_available(rb)
}

// Write one byte to ring buffer (returns false if full)
ringbuf_write :: proc "c" (rb: ^UART_RingBuffer, data: u8) -> bool {
    head := intrinsics.volatile_load(&rb.head)
    next_head := (head + 1) & (UART_RX_BUFFER_SIZE - 1)

    if next_head == intrinsics.volatile_load(&rb.tail) {
        return false  // Buffer full
    }

    rb.buffer[head] = data
    intrinsics.volatile_store(&rb.head, next_head)
    return true
}

// Read one byte from ring buffer (returns false if empty)
ringbuf_read :: proc "c" (rb: ^UART_RingBuffer, data: ^u8) -> bool {
    tail := intrinsics.volatile_load(&rb.tail)

    if tail == intrinsics.volatile_load(&rb.head) {
        return false  // Buffer empty
    }

    data^ = rb.buffer[tail]
    intrinsics.volatile_store(&rb.tail, (tail + 1) & (UART_RX_BUFFER_SIZE - 1))
    return true
}

// Initialize UART for interrupt mode
uart_init_irq :: proc "c" (handle: ^UART_Handle_IRQ, config: UART_Config) {
    // Initialize ring buffers
    ringbuf_init(&handle.rx_buffer)
    ringbuf_init(&handle.tx_buffer)
    handle.tx_busy = false

    // Disable UART during configuration
    hal.reg_modify(&handle.regs.CR1, .Clear, device.USART1_CR1_UE_Mask_Shifted)

    // Configure baud rate
    brr := handle.pclk / u32(config.baud_rate)
    hal.reg_write(&handle.regs.BRR, brr)

    // Configure CR2: Stop bits
    cr2: u32 = 0
    cr2 |= u32(config.stop_bits) << device.USART1_CR2_STOP_Pos
    hal.reg_write(&handle.regs.CR2, cr2)

    // Configure CR1
    cr1: u32 = 0
    cr1 |= u32(config.data_bits) << device.USART1_CR1_M_Pos

    if config.parity == .Even {
        cr1 |= u32(device.USART1_CR1_PCE.Enabled) << device.USART1_CR1_PCE_Pos
        cr1 |= u32(device.USART1_CR1_PS.Even) << device.USART1_CR1_PS_Pos
    } else if config.parity == .Odd {
        cr1 |= u32(device.USART1_CR1_PCE.Enabled) << device.USART1_CR1_PCE_Pos
        cr1 |= u32(device.USART1_CR1_PS.Odd) << device.USART1_CR1_PS_Pos
    }

    // Enable TX and RX
    cr1 |= u32(device.USART1_CR1_TE.Enabled) << device.USART1_CR1_TE_Pos
    cr1 |= u32(device.USART1_CR1_RE.Enabled) << device.USART1_CR1_RE_Pos

    hal.reg_write(&handle.regs.CR1, cr1)

    // Enable UART
    hal.reg_modify(&handle.regs.CR1, .Set, device.USART1_CR1_UE_Mask_Shifted)
}

// Enable RXNE (RX Not Empty) interrupt
uart_enable_rx_interrupt :: proc "c" (handle: ^UART_Handle_IRQ) {
    hal.reg_modify(&handle.regs.CR1, .Set, device.USART1_CR1_RXNEIE_Mask_Shifted)
}

// Disable RXNE interrupt
uart_disable_rx_interrupt :: proc "c" (handle: ^UART_Handle_IRQ) {
    hal.reg_modify(&handle.regs.CR1, .Clear, device.USART1_CR1_RXNEIE_Mask_Shifted)
}

// Enable TXE (TX Empty) interrupt
uart_enable_tx_interrupt :: proc "c" (handle: ^UART_Handle_IRQ) {
    hal.reg_modify(&handle.regs.CR1, .Set, device.USART1_CR1_TXEIE_Mask_Shifted)
}

// Disable TXE interrupt
uart_disable_tx_interrupt :: proc "c" (handle: ^UART_Handle_IRQ) {
    hal.reg_modify(&handle.regs.CR1, .Clear, device.USART1_CR1_TXEIE_Mask_Shifted)
}

// IRQ Handler - call this from your USARTx_IRQHandler
// Handles both RX and TX interrupts
uart_irq_handler :: proc "c" (handle: ^UART_Handle_IRQ) {
    isr := hal.reg_read(&handle.regs.ISR)

    // Handle RX (RXNE - Receive buffer not empty)
    if (isr & device.USART1_ISR_RXNE_Mask_Shifted) != 0 {
        // Read data (this also clears RXNE flag)
        data := u8(hal.reg_read(&handle.regs.RDR))
        // Store in ring buffer (drop if full)
        ringbuf_write(&handle.rx_buffer, data)
    }

    // Handle TX (TXE - Transmit buffer empty)
    if (isr & device.USART1_ISR_TXE_Mask_Shifted) != 0 {
        data: u8
        if ringbuf_read(&handle.tx_buffer, &data) {
            // More data to send
            hal.reg_write(&handle.regs.TDR, u32(data))
        } else {
            // Buffer empty, disable TXE interrupt
            uart_disable_tx_interrupt(handle)
            handle.tx_busy = false
        }
    }

    // Handle errors - clear them to prevent repeated interrupts
    if (isr & ((1 << 3) | (1 << 2) | (1 << 1) | (1 << 0))) != 0 {
        // Clear all error flags
        icr: u32 = (1 << 3) | (1 << 2) | (1 << 1) | (1 << 0)
        hal.reg_write(&handle.regs.ICR, icr)
    }
}

// Check if RX data is available (non-blocking)
uart_rx_available :: proc "c" (handle: ^UART_Handle_IRQ) -> u32 {
    return ringbuf_available(&handle.rx_buffer)
}

// Read one byte from RX buffer (non-blocking)
// Returns true if byte was read, false if buffer empty
uart_read_byte :: proc "c" (handle: ^UART_Handle_IRQ, data: ^u8) -> bool {
    return ringbuf_read(&handle.rx_buffer, data)
}

// Read multiple bytes from RX buffer (non-blocking)
// Returns number of bytes actually read
uart_read :: proc "c" (handle: ^UART_Handle_IRQ, data: []u8) -> u32 {
    count: u32 = 0
    for i in 0..<len(data) {
        if !ringbuf_read(&handle.rx_buffer, &data[i]) {
            break
        }
        count += 1
    }
    return count
}

// Write one byte to TX buffer (non-blocking)
// Returns true if byte was queued, false if buffer full
uart_write_byte :: proc "c" (handle: ^UART_Handle_IRQ, data: u8) -> bool {
    if !ringbuf_write(&handle.tx_buffer, data) {
        return false  // Buffer full
    }

    // Start transmission if not already active
    if !handle.tx_busy {
        handle.tx_busy = true
        uart_enable_tx_interrupt(handle)
    }

    return true
}

// Write multiple bytes to TX buffer (non-blocking)
// Returns number of bytes actually written
uart_write :: proc "c" (handle: ^UART_Handle_IRQ, data: []u8) -> u32 {
    count: u32 = 0
    for i in 0..<len(data) {
        if !ringbuf_write(&handle.tx_buffer, data[i]) {
            break
        }
        count += 1
    }

    // Start transmission if not already active
    if count > 0 && !handle.tx_busy {
        handle.tx_busy = true
        uart_enable_tx_interrupt(handle)
    }

    return count
}

// Write string to TX buffer (non-blocking)
// Returns number of bytes actually written
uart_write_string :: proc "c" (handle: ^UART_Handle_IRQ, str: string) -> u32 {
    count: u32 = 0
    for i in 0..<len(str) {
        if !ringbuf_write(&handle.tx_buffer, str[i]) {
            break
        }
        count += 1
    }

    if count > 0 && !handle.tx_busy {
        handle.tx_busy = true
        uart_enable_tx_interrupt(handle)
    }

    return count
}

// Check if TX is complete (buffer empty and last byte sent)
uart_tx_complete :: proc "c" (handle: ^UART_Handle_IRQ) -> bool {
    if !ringbuf_is_empty(&handle.tx_buffer) {
        return false
    }
    // Check TC (Transmission Complete) flag
    isr := hal.reg_read(&handle.regs.ISR)
    return (isr & device.USART1_ISR_TC_Mask_Shifted) != 0
}

// Flush TX buffer - wait for all data to be sent (blocking)
uart_flush_tx :: proc "c" (handle: ^UART_Handle_IRQ) {
    for !uart_tx_complete(handle) {
        // Wait
    }
}

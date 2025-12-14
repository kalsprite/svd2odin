package i2c

import hal "../../hal"
import device "../../cmsis/device"

// Portable I2C driver for STM32
// Works with any I2C peripheral (I2C1, I2C2, I2C3)
// Supports 7-bit addressing in master mode

// I2C Speed modes
I2C_Speed :: enum u32 {
    Standard = 100_000,  // 100 kHz
    Fast     = 400_000,  // 400 kHz
}

// I2C Configuration
I2C_Config :: struct {
    speed: I2C_Speed,
    timing: u32,  // TIMINGR register value (depends on I2C clock)
}

// I2C Handle
I2C_Handle :: struct {
    regs: ^device.I2C1_Registers,  // Works for I2C1, I2C2, I2C3 (same layout)
}

// I2C Error codes
I2C_Error :: enum {
    None = 0,
    NACK,          // No acknowledge received
    BusError,      // Bus error (misplaced start/stop)
    ArbitrationLost, // Arbitration lost
    Timeout,       // Operation timeout
    Busy,          // Bus is busy
}

// Pre-calculated TIMINGR values for common configurations
// Format: PRESC[31:28] | SCLDEL[23:20] | SDADEL[19:16] | SCLH[15:8] | SCLL[7:0]
//
// For 8 MHz I2C clock (PCLK1):
I2C_TIMING_8MHZ_100KHZ  :: 0x00201D2B  // 100 kHz Standard mode
I2C_TIMING_8MHZ_400KHZ  :: 0x00200510  // 400 kHz Fast mode

// For 48 MHz I2C clock (PCLK1):
I2C_TIMING_48MHZ_100KHZ :: 0x10808DD3  // 100 kHz Standard mode
I2C_TIMING_48MHZ_400KHZ :: 0x00901850  // 400 kHz Fast mode

// Initialize I2C peripheral in master mode
i2c_init :: proc "c" (handle: ^I2C_Handle, config: I2C_Config) {
    // Disable I2C during configuration
    hal.reg_modify(&handle.regs.CR1, .Clear, device.I2C1_CR1_PE_Mask_Shifted)

    // Configure timing (critical for I2C operation)
    hal.reg_write(&handle.regs.TIMINGR, config.timing)

    // Configure CR1:
    // - Analog filter enabled (ANFOFF=0)
    // - Digital filter disabled (DNF=0)
    // - Clock stretching enabled (NOSTRETCH=0)
    cr1: u32 = 0
    // Default values are OK for basic operation

    hal.reg_write(&handle.regs.CR1, cr1)

    // Enable I2C
    hal.reg_modify(&handle.regs.CR1, .Set, device.I2C1_CR1_PE_Mask_Shifted)
}

// Wait for flag in ISR
i2c_wait_flag :: proc "c" (handle: ^I2C_Handle, flag: u32, timeout: u32) -> I2C_Error {
    for i: u32 = 0; i < timeout; i += 1 {
        isr := hal.reg_read(&handle.regs.ISR)
        if (isr & flag) != 0 {
            return .None
        }
    }
    return .Timeout
}

// Check if bus is busy
i2c_is_busy :: proc "c" (handle: ^I2C_Handle) -> bool {
    isr := hal.reg_read(&handle.regs.ISR)
    return (isr & device.I2C1_ISR_BUSY_Mask_Shifted) != 0
}

// Wait for bus to be free
i2c_wait_not_busy :: proc "c" (handle: ^I2C_Handle, timeout: u32) -> I2C_Error {
    for i: u32 = 0; i < timeout; i += 1 {
        if !i2c_is_busy(handle) {
            return .None
        }
    }
    return .Busy
}

// Check for NACK
i2c_check_nack :: proc "c" (handle: ^I2C_Handle) -> bool {
    isr := hal.reg_read(&handle.regs.ISR)
    return (isr & device.I2C1_ISR_NACKF_Mask_Shifted) != 0
}

// Clear NACK flag
i2c_clear_nack :: proc "c" (handle: ^I2C_Handle) {
    // Write 1 to clear NACKF in ICR
    hal.reg_write(&handle.regs.ICR, 1 << device.I2C1_ISR_NACKF_Pos)
}

// Generate START condition and send address
i2c_start :: proc "c" (handle: ^I2C_Handle, addr: u8, is_read: bool, nbytes: u8) -> I2C_Error {
    // Wait for bus to be free
    if err := i2c_wait_not_busy(handle, 10000); err != .None {
        return err
    }

    // Configure CR2:
    // - Slave address (7-bit)
    // - Transfer direction (read/write)
    // - Number of bytes
    // - AUTOEND disabled (manual STOP)
    // - START condition
    cr2: u32 = 0
    cr2 |= u32(addr << 1) << device.I2C1_CR2_SADD_Pos  // 7-bit address (shifted left)

    if is_read {
        cr2 |= 1 << device.I2C1_CR2_RD_WRN_Pos  // Read operation
    }

    cr2 |= u32(nbytes) << device.I2C1_CR2_NBYTES_Pos  // Number of bytes
    cr2 |= 1 << device.I2C1_CR2_START_Pos  // Generate START

    hal.reg_write(&handle.regs.CR2, cr2)

    // Wait for address to be sent (or NACK)
    for i: u32 = 0; i < 10000; i += 1 {
        isr := hal.reg_read(&handle.regs.ISR)

        // Check for NACK
        if (isr & device.I2C1_ISR_NACKF_Mask_Shifted) != 0 {
            i2c_clear_nack(handle)
            return .NACK
        }

        // Check if we can proceed (TXIS for write, RXNE for read)
        if is_read {
            if (isr & device.I2C1_ISR_RXNE_Mask_Shifted) != 0 {
                return .None
            }
        } else {
            if (isr & device.I2C1_ISR_TXIS_Mask_Shifted) != 0 {
                return .None
            }
        }
    }

    return .Timeout
}

// Generate STOP condition
i2c_stop :: proc "c" (handle: ^I2C_Handle) {
    hal.reg_modify(&handle.regs.CR2, .Set, 1 << device.I2C1_CR2_STOP_Pos)

    // Wait for STOP to be sent
    for i: u32 = 0; i < 10000; i += 1 {
        isr := hal.reg_read(&handle.regs.ISR)
        if (isr & device.I2C1_ISR_STOPF_Mask_Shifted) != 0 {
            // Clear STOPF flag
            hal.reg_write(&handle.regs.ICR, 1 << device.I2C1_ISR_STOPF_Pos)
            break
        }
    }
}

// Master transmit (write) to slave device
i2c_master_transmit :: proc "c" (handle: ^I2C_Handle, addr: u8, data: []u8) -> I2C_Error {
    if len(data) == 0 || len(data) > 255 {
        return .Busy  // Invalid length
    }

    // Start transfer
    if err := i2c_start(handle, addr, false, u8(len(data))); err != .None {
        i2c_stop(handle)
        return err
    }

    // Send all bytes
    for byte in data {
        // Wait for TXIS (Transmit buffer empty)
        if err := i2c_wait_flag(handle, device.I2C1_ISR_TXIS_Mask_Shifted, 10000); err != .None {
            i2c_stop(handle)
            return err
        }

        // Check for NACK
        if i2c_check_nack(handle) {
            i2c_clear_nack(handle)
            i2c_stop(handle)
            return .NACK
        }

        // Write data to TXDR
        hal.reg_write(&handle.regs.TXDR, u32(byte))
    }

    // Wait for transfer complete (TC)
    if err := i2c_wait_flag(handle, device.I2C1_ISR_TC_Mask_Shifted, 10000); err != .None {
        i2c_stop(handle)
        return err
    }

    // Generate STOP
    i2c_stop(handle)

    return .None
}

// Master receive (read) from slave device
i2c_master_receive :: proc "c" (handle: ^I2C_Handle, addr: u8, data: []u8) -> I2C_Error {
    if len(data) == 0 || len(data) > 255 {
        return .Busy  // Invalid length
    }

    // Start transfer
    if err := i2c_start(handle, addr, true, u8(len(data))); err != .None {
        i2c_stop(handle)
        return err
    }

    // Receive all bytes
    for i in 0..<len(data) {
        // Wait for RXNE (Receive buffer not empty)
        if err := i2c_wait_flag(handle, device.I2C1_ISR_RXNE_Mask_Shifted, 10000); err != .None {
            i2c_stop(handle)
            return err
        }

        // Read data from RXDR
        data[i] = u8(hal.reg_read(&handle.regs.RXDR))
    }

    // Wait for transfer complete (TC)
    if err := i2c_wait_flag(handle, device.I2C1_ISR_TC_Mask_Shifted, 10000); err != .None {
        i2c_stop(handle)
        return err
    }

    // Generate STOP
    i2c_stop(handle)

    return .None
}

// Write to register of I2C device (common pattern)
i2c_write_register :: proc "c" (handle: ^I2C_Handle, addr: u8, reg: u8, value: u8) -> I2C_Error {
    data := [2]u8{reg, value}
    return i2c_master_transmit(handle, addr, data[:])
}

// Read from register of I2C device (common pattern)
i2c_read_register :: proc "c" (handle: ^I2C_Handle, addr: u8, reg: u8) -> (value: u8, err: I2C_Error) {
    // Write register address
    reg_data := [1]u8{reg}
    if err = i2c_master_transmit(handle, addr, reg_data[:]); err != .None {
        return
    }

    // Read register value
    read_data := [1]u8{0}
    if err = i2c_master_receive(handle, addr, read_data[:]); err != .None {
        return
    }

    value = read_data[0]
    return
}

// Read multiple bytes from register (burst read)
i2c_read_registers :: proc "c" (handle: ^I2C_Handle, addr: u8, reg: u8, data: []u8) -> I2C_Error {
    // Write register address
    reg_data := [1]u8{reg}
    if err := i2c_master_transmit(handle, addr, reg_data[:]); err != .None {
        return err
    }

    // Read multiple bytes
    return i2c_master_receive(handle, addr, data)
}

// ========== DMA Support ==========

// Enable I2C TX DMA
i2c_enable_tx_dma :: proc "c" (handle: ^I2C_Handle) {
    hal.reg_modify(&handle.regs.CR1, .Set, device.I2C1_CR1_TXDMAEN_Mask_Shifted)
}

// Enable I2C RX DMA
i2c_enable_rx_dma :: proc "c" (handle: ^I2C_Handle) {
    hal.reg_modify(&handle.regs.CR1, .Set, device.I2C1_CR1_RXDMAEN_Mask_Shifted)
}

// Disable I2C TX DMA
i2c_disable_tx_dma :: proc "c" (handle: ^I2C_Handle) {
    hal.reg_modify(&handle.regs.CR1, .Clear, device.I2C1_CR1_TXDMAEN_Mask_Shifted)
}

// Disable I2C RX DMA
i2c_disable_rx_dma :: proc "c" (handle: ^I2C_Handle) {
    hal.reg_modify(&handle.regs.CR1, .Clear, device.I2C1_CR1_RXDMAEN_Mask_Shifted)
}

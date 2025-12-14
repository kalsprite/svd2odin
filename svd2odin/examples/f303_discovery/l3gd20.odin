package main

// L3GD20 Gyroscope driver for STM32F303 Discovery
// Uses SPI1 on PA5 (SCK) / PA6 (MISO) / PA7 (MOSI) with PE3 (CS)

import device "stm32/cmsis/device"
import hal "stm32/hal"
import spi "stm32/drivers/spi"
import debug "stm32/board/debug"

// L3GD20 Registers
L3GD20_WHO_AM_I    :: 0x0F  // Device ID (should read 0xD4 for L3GD20 or 0xD7 for L3GD20H)
L3GD20_CTRL_REG1   :: 0x20  // Data rate, bandwidth, power mode, axes enable
L3GD20_CTRL_REG2   :: 0x21  // High-pass filter config
L3GD20_CTRL_REG3   :: 0x22  // Interrupt config
L3GD20_CTRL_REG4   :: 0x23  // Full scale, SPI mode, self-test
L3GD20_CTRL_REG5   :: 0x24  // FIFO, high-pass filter
L3GD20_STATUS_REG  :: 0x27  // Data status
L3GD20_OUT_X_L     :: 0x28  // X-axis low byte
L3GD20_OUT_X_H     :: 0x29
L3GD20_OUT_Y_L     :: 0x2A
L3GD20_OUT_Y_H     :: 0x2B
L3GD20_OUT_Z_L     :: 0x2C
L3GD20_OUT_Z_H     :: 0x2D

// SPI flags
L3GD20_READ_FLAG   :: 0x80  // Set bit 7 for read
L3GD20_MS_FLAG     :: 0x40  // Set bit 6 for multi-byte (auto-increment)

// SPI handle for gyroscope
gyro_spi: spi.SPI_Handle

// CS pin control (PE3)
gyro_cs_low :: proc "c" () {
    hal.reg_modify(&device.GPIOE.ODR, .Clear, 1 << 3)
}

gyro_cs_high :: proc "c" () {
    hal.reg_modify(&device.GPIOE.ODR, .Set, 1 << 3)
}

// Initialize SPI1 for gyroscope
gyro_init :: proc "c" () -> bool {
    // Enable clocks: SPI1 (APB2), GPIOA, GPIOE
    hal.reg_modify(&device.RCC.APB2ENR, .Set, device.RCC_APB2ENR_SPI1EN_Mask_Shifted)
    hal.reg_modify(&device.RCC.AHBENR, .Set, device.RCC_AHBENR_IOPAEN_Mask_Shifted)
    hal.reg_modify(&device.RCC.AHBENR, .Set, device.RCC_AHBENR_IOPEEN_Mask_Shifted)

    // Configure PE3 as output for CS (push-pull, high speed)
    hal.reg_modify(&device.GPIOE.MODER, .Clear, 0x3 << (3 * 2))
    hal.reg_modify(&device.GPIOE.MODER, .Set, 0x1 << (3 * 2))   // Output
    hal.reg_modify(&device.GPIOE.OTYPER, .Clear, 1 << 3)         // Push-pull
    hal.reg_modify(&device.GPIOE.OSPEEDR, .Set, 0x3 << (3 * 2)) // High speed
    gyro_cs_high()  // Deselect

    // Configure PA5 (SCK), PA6 (MISO), PA7 (MOSI) as SPI alternate function
    // AF5 = SPI1

    // PA5 - SCK
    hal.reg_modify(&device.GPIOA.MODER, .Clear, 0x3 << (5 * 2))
    hal.reg_modify(&device.GPIOA.MODER, .Set, 0x2 << (5 * 2))   // Alternate function
    hal.reg_modify(&device.GPIOA.OSPEEDR, .Set, 0x3 << (5 * 2)) // High speed
    hal.reg_modify(&device.GPIOA.AFRL, .Clear, 0xF << (5 * 4))
    hal.reg_modify(&device.GPIOA.AFRL, .Set, 5 << (5 * 4))      // AF5

    // PA6 - MISO
    hal.reg_modify(&device.GPIOA.MODER, .Clear, 0x3 << (6 * 2))
    hal.reg_modify(&device.GPIOA.MODER, .Set, 0x2 << (6 * 2))   // Alternate function
    hal.reg_modify(&device.GPIOA.AFRL, .Clear, 0xF << (6 * 4))
    hal.reg_modify(&device.GPIOA.AFRL, .Set, 5 << (6 * 4))      // AF5

    // PA7 - MOSI
    hal.reg_modify(&device.GPIOA.MODER, .Clear, 0x3 << (7 * 2))
    hal.reg_modify(&device.GPIOA.MODER, .Set, 0x2 << (7 * 2))   // Alternate function
    hal.reg_modify(&device.GPIOA.OSPEEDR, .Set, 0x3 << (7 * 2)) // High speed
    hal.reg_modify(&device.GPIOA.AFRL, .Clear, 0xF << (7 * 4))
    hal.reg_modify(&device.GPIOA.AFRL, .Set, 5 << (7 * 4))      // AF5

    // Initialize SPI handle
    gyro_spi.regs = device.SPI1

    // Configure SPI: Mode 3 (CPOL=1, CPHA=1), 8-bit, ~1MHz (div64 from 8MHz)
    spi_config := spi.SPI_Config{
        mode = .Mode3,
        speed = .Div64,
        data_size = .EightBit,
        bit_order = .MSBFirst,
    }
    spi.spi_init(&gyro_spi, spi_config)

    return true
}

// Read gyroscope register
gyro_read_reg :: proc "c" (reg: u8) -> u8 {
    gyro_cs_low()
    _ = spi.spi_transfer_byte(&gyro_spi, reg | L3GD20_READ_FLAG)
    value := spi.spi_transfer_byte(&gyro_spi, 0xFF)
    gyro_cs_high()
    return value
}

// Write gyroscope register
gyro_write_reg :: proc "c" (reg: u8, value: u8) {
    gyro_cs_low()
    _ = spi.spi_transfer_byte(&gyro_spi, reg)
    _ = spi.spi_transfer_byte(&gyro_spi, value)
    gyro_cs_high()
}

// Verify gyroscope is present by reading WHO_AM_I
gyro_verify :: proc "c" () -> bool {
    who := gyro_read_reg(L3GD20_WHO_AM_I)
    // L3GD20 = 0xD4, L3GD20H = 0xD7 (F303 Discovery uses L3GD20)
    return who == 0xD4 || who == 0xD7
}

// Enable gyroscope
// - 95Hz ODR, 12.5Hz cutoff
// - All axes enabled
// - 250 dps full scale
gyro_enable :: proc "c" () -> bool {
    // CTRL_REG1: DR=00 (95Hz), BW=00 (12.5Hz cutoff), PD=1 (normal), Zen=Yen=Xen=1
    gyro_write_reg(L3GD20_CTRL_REG1, 0x0F)

    // CTRL_REG4: BDU=1 (block update), FS=00 (250 dps)
    gyro_write_reg(L3GD20_CTRL_REG4, 0x80)

    return true
}

// Read gyroscope data (raw 16-bit values in mdps at 250dps scale)
gyro_read_xyz :: proc "c" () -> (x: i16, y: i16, z: i16, ok: bool) {
    // Check status - ZYXDA bit (bit 3) indicates new data
    status := gyro_read_reg(L3GD20_STATUS_REG)
    if (status & 0x08) == 0 {
        return 0, 0, 0, false
    }

    // Read all 6 bytes with auto-increment
    gyro_cs_low()
    _ = spi.spi_transfer_byte(&gyro_spi, L3GD20_OUT_X_L | L3GD20_READ_FLAG | L3GD20_MS_FLAG)
    xl := spi.spi_transfer_byte(&gyro_spi, 0xFF)
    xh := spi.spi_transfer_byte(&gyro_spi, 0xFF)
    yl := spi.spi_transfer_byte(&gyro_spi, 0xFF)
    yh := spi.spi_transfer_byte(&gyro_spi, 0xFF)
    zl := spi.spi_transfer_byte(&gyro_spi, 0xFF)
    zh := spi.spi_transfer_byte(&gyro_spi, 0xFF)
    gyro_cs_high()

    x = i16(u16(xh) << 8 | u16(xl))
    y = i16(u16(yh) << 8 | u16(yl))
    z = i16(u16(zh) << 8 | u16(zl))

    return x, y, z, true
}

// Print gyroscope state
gyro_print_state :: proc "c" () {
    gx, gy, gz, ok := gyro_read_xyz()
    if ok {
        debug.print("Gyro: X=")
        debug.print_i16(gx)
        debug.print(" Y=")
        debug.print_i16(gy)
        debug.print(" Z=")
        debug.print_i16(gz)
        debug.println("")
    } else {
        debug.println("Gyro: no data")
    }
}

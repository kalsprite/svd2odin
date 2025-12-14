package main

// LSM303DLHC Accelerometer driver for STM32F303 Discovery
// Uses I2C1 on PB6 (SCL) / PB7 (SDA)

import device "stm32/cmsis/device"
import hal "stm32/hal"
import i2c "stm32/drivers/i2c"
import debug "stm32/board/debug"

// LSM303DLHC I2C addresses (7-bit)
LSM303_ACCEL_ADDR :: 0x19  // Accelerometer
LSM303_MAG_ADDR   :: 0x1E  // Magnetometer

// Accelerometer registers
LSM303_CTRL_REG1_A  :: 0x20  // Data rate, power mode, axes enable
LSM303_CTRL_REG4_A  :: 0x23  // Full scale, high resolution
LSM303_STATUS_REG_A :: 0x27  // Data status
LSM303_OUT_X_L_A    :: 0x28  // X-axis low byte
LSM303_OUT_X_H_A    :: 0x29
LSM303_OUT_Y_L_A    :: 0x2A
LSM303_OUT_Y_H_A    :: 0x2B
LSM303_OUT_Z_L_A    :: 0x2C
LSM303_OUT_Z_H_A    :: 0x2D

// Magnetometer registers
LSM303_CRA_REG_M  :: 0x00  // Data rate
LSM303_CRB_REG_M  :: 0x01  // Gain
LSM303_MR_REG_M   :: 0x02  // Mode
LSM303_OUT_X_H_M  :: 0x03  // X-axis high byte
LSM303_OUT_X_L_M  :: 0x04  // X-axis low byte
LSM303_OUT_Z_H_M  :: 0x05  // Z-axis high byte (note: Z before Y!)
LSM303_OUT_Z_L_M  :: 0x06
LSM303_OUT_Y_H_M  :: 0x07  // Y-axis high byte
LSM303_OUT_Y_L_M  :: 0x08
LSM303_SR_REG_M   :: 0x09  // Status register
LSM303_IRA_REG_M  :: 0x0A  // ID register A (should read 'H' = 0x48)
LSM303_IRB_REG_M  :: 0x0B  // ID register B (should read '4' = 0x34)
LSM303_IRC_REG_M  :: 0x0C  // ID register C (should read '3' = 0x33)

// I2C handle for accelerometer
accel_i2c: i2c.I2C_Handle

// Initialize I2C1 for accelerometer/magnetometer
accel_init :: proc "c" () -> bool {
    // Enable I2C1 and GPIOB clocks
    hal.reg_modify(&device.RCC.APB1ENR, .Set, device.RCC_APB1ENR_I2C1EN_Mask_Shifted)
    hal.reg_modify(&device.RCC.AHBENR, .Set, device.RCC_AHBENR_IOPBEN_Mask_Shifted)

    // Configure PB6 (SCL) as I2C alternate function, open-drain
    hal.reg_modify(&device.GPIOB.MODER, .Clear, 0x3 << (6 * 2))
    hal.reg_modify(&device.GPIOB.MODER, .Set, 0x2 << (6 * 2))  // Alternate function
    hal.reg_modify(&device.GPIOB.OTYPER, .Set, 1 << 6)  // Open-drain
    hal.reg_modify(&device.GPIOB.OSPEEDR, .Set, 0x3 << (6 * 2))  // High speed
    hal.reg_modify(&device.GPIOB.PUPDR, .Clear, 0x3 << (6 * 2))
    hal.reg_modify(&device.GPIOB.PUPDR, .Set, 0x1 << (6 * 2))  // Pull-up
    hal.reg_modify(&device.GPIOB.AFRL, .Clear, 0xF << (6 * 4))
    hal.reg_modify(&device.GPIOB.AFRL, .Set, 4 << (6 * 4))  // AF4 = I2C1

    // Configure PB7 (SDA) as I2C alternate function, open-drain
    hal.reg_modify(&device.GPIOB.MODER, .Clear, 0x3 << (7 * 2))
    hal.reg_modify(&device.GPIOB.MODER, .Set, 0x2 << (7 * 2))  // Alternate function
    hal.reg_modify(&device.GPIOB.OTYPER, .Set, 1 << 7)  // Open-drain
    hal.reg_modify(&device.GPIOB.OSPEEDR, .Set, 0x3 << (7 * 2))  // High speed
    hal.reg_modify(&device.GPIOB.PUPDR, .Clear, 0x3 << (7 * 2))
    hal.reg_modify(&device.GPIOB.PUPDR, .Set, 0x1 << (7 * 2))  // Pull-up
    hal.reg_modify(&device.GPIOB.AFRL, .Clear, 0xF << (7 * 4))
    hal.reg_modify(&device.GPIOB.AFRL, .Set, 4 << (7 * 4))  // AF4 = I2C1

    // Initialize I2C handle
    accel_i2c.regs = device.I2C1

    i2c_config := i2c.I2C_Config{
        speed = .Standard,
        timing = i2c.I2C_TIMING_8MHZ_100KHZ,
    }
    i2c.i2c_init(&accel_i2c, i2c_config)

    return true
}

// Read accelerometer register
accel_read_reg :: proc "c" (reg: u8) -> (value: u8, ok: bool) {
    val, err := i2c.i2c_read_register(&accel_i2c, LSM303_ACCEL_ADDR, reg)
    return val, err == .None
}

// Write accelerometer register
accel_write_reg :: proc "c" (reg: u8, value: u8) -> bool {
    err := i2c.i2c_write_register(&accel_i2c, LSM303_ACCEL_ADDR, reg, value)
    return err == .None
}

// Read magnetometer register
mag_read_reg :: proc "c" (reg: u8) -> (value: u8, ok: bool) {
    val, err := i2c.i2c_read_register(&accel_i2c, LSM303_MAG_ADDR, reg)
    return val, err == .None
}

// Enable accelerometer
// - ODR = 100Hz, all axes enabled
// - FS = +/-2g, high resolution
accel_enable :: proc "c" () -> bool {
    // CTRL_REG1_A: ODR=0101 (100Hz), LPen=0, Zen=Yen=Xen=1
    if !accel_write_reg(LSM303_CTRL_REG1_A, 0x57) {
        return false
    }
    // CTRL_REG4_A: BDU=1, BLE=0, FS=00 (+/-2g), HR=1
    if !accel_write_reg(LSM303_CTRL_REG4_A, 0x88) {
        return false
    }
    return true
}

// Read acceleration data (raw 16-bit values)
accel_read_xyz :: proc "c" () -> (x: i16, y: i16, z: i16, ok: bool) {
    // Check status
    status, status_ok := accel_read_reg(LSM303_STATUS_REG_A)
    if !status_ok {
        return 0, 0, 0, false
    }

    // ZYXDA bit (bit 3) indicates new data available
    if (status & 0x08) == 0 {
        return 0, 0, 0, false
    }

    // Read each axis
    xl, xl_ok := accel_read_reg(LSM303_OUT_X_L_A)
    xh, xh_ok := accel_read_reg(LSM303_OUT_X_H_A)
    yl, yl_ok := accel_read_reg(LSM303_OUT_Y_L_A)
    yh, yh_ok := accel_read_reg(LSM303_OUT_Y_H_A)
    zl, zl_ok := accel_read_reg(LSM303_OUT_Z_L_A)
    zh, zh_ok := accel_read_reg(LSM303_OUT_Z_H_A)

    if !xl_ok || !xh_ok || !yl_ok || !yh_ok || !zl_ok || !zh_ok {
        return 0, 0, 0, false
    }

    x = i16(u16(xh) << 8 | u16(xl))
    y = i16(u16(yh) << 8 | u16(yl))
    z = i16(u16(zh) << 8 | u16(zl))

    return x, y, z, true
}

// Print accelerometer state
accel_print_state :: proc "c" () {
    ax, ay, az, ok := accel_read_xyz()
    if ok {
        debug.print("Accel: X=")
        debug.print_i16(ax)
        debug.print(" Y=")
        debug.print_i16(ay)
        debug.print(" Z=")
        debug.print_i16(az)
        debug.println("")
    } else {
        debug.println("Accel: no data")
    }
}

// Verify magnetometer is present by reading ID registers
// Returns true if LSM303DLHC magnetometer responds correctly
mag_verify :: proc "c" () -> bool {
    // ID register A should read 'H' (0x48)
    ira, ira_ok := mag_read_reg(LSM303_IRA_REG_M)
    if !ira_ok || ira != 0x48 {
        return false
    }

    // ID register B should read '4' (0x34)
    irb, irb_ok := mag_read_reg(LSM303_IRB_REG_M)
    if !irb_ok || irb != 0x34 {
        return false
    }

    // ID register C should read '3' (0x33)
    irc, irc_ok := mag_read_reg(LSM303_IRC_REG_M)
    if !irc_ok || irc != 0x33 {
        return false
    }

    return true
}

// Write magnetometer register
mag_write_reg :: proc "c" (reg: u8, value: u8) -> bool {
    err := i2c.i2c_write_register(&accel_i2c, LSM303_MAG_ADDR, reg, value)
    return err == .None
}

// Enable magnetometer
// - 75Hz data rate, continuous conversion
// - Gain = +/-1.3 gauss (default)
mag_enable :: proc "c" () -> bool {
    // CRA_REG_M: DO2:DO0 = 110 (75Hz), no temp sensor
    if !mag_write_reg(LSM303_CRA_REG_M, 0x18) {
        return false
    }
    // CRB_REG_M: GN2:GN0 = 001 (+/-1.3 gauss, default)
    if !mag_write_reg(LSM303_CRB_REG_M, 0x20) {
        return false
    }
    // MR_REG_M: MD1:MD0 = 00 (continuous conversion)
    if !mag_write_reg(LSM303_MR_REG_M, 0x00) {
        return false
    }
    return true
}

// Read magnetometer data (raw 16-bit values)
mag_read_xyz :: proc "c" () -> (x: i16, y: i16, z: i16, ok: bool) {
    // Check status - DRDY bit (bit 0)
    status, status_ok := mag_read_reg(LSM303_SR_REG_M)
    if !status_ok {
        return 0, 0, 0, false
    }
    if (status & 0x01) == 0 {
        return 0, 0, 0, false
    }

    // Read each axis (note: high byte first, and Z comes before Y!)
    xh, xh_ok := mag_read_reg(LSM303_OUT_X_H_M)
    xl, xl_ok := mag_read_reg(LSM303_OUT_X_L_M)
    zh, zh_ok := mag_read_reg(LSM303_OUT_Z_H_M)
    zl, zl_ok := mag_read_reg(LSM303_OUT_Z_L_M)
    yh, yh_ok := mag_read_reg(LSM303_OUT_Y_H_M)
    yl, yl_ok := mag_read_reg(LSM303_OUT_Y_L_M)

    if !xh_ok || !xl_ok || !yh_ok || !yl_ok || !zh_ok || !zl_ok {
        return 0, 0, 0, false
    }

    x = i16(u16(xh) << 8 | u16(xl))
    y = i16(u16(yh) << 8 | u16(yl))
    z = i16(u16(zh) << 8 | u16(zl))

    return x, y, z, true
}

// Print magnetometer state
mag_print_state :: proc "c" () {
    mx, my, mz, ok := mag_read_xyz()
    if ok {
        debug.print("Mag: X=")
        debug.print_i16(mx)
        debug.print(" Y=")
        debug.print_i16(my)
        debug.print(" Z=")
        debug.print_i16(mz)
        debug.println("")
    } else {
        debug.println("Mag: no data")
    }
}

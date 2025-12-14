package i2s

import "base:intrinsics"
import hal "../../hal"
import device "../../cmsis/device"

// I2S driver for STM32
// Uses SPI2/SPI3 peripherals in I2S mode
// Supports master receive (microphone input) and master transmit (DAC output)

// I2S Standard
I2S_Standard :: enum u32 {
    Philips = 0,  // I2S Philips standard (most common for MEMS mics)
    MSB     = 1,  // MSB justified
    LSB     = 2,  // LSB justified
    PCM     = 3,  // PCM standard
}

// I2S Data Length
I2S_DataLength :: enum u32 {
    Bits16 = 0,  // 16-bit data
    Bits24 = 1,  // 24-bit data
    Bits32 = 2,  // 32-bit data
}

// I2S Channel Length (frame width)
I2S_ChannelLength :: enum u32 {
    Bits16 = 0,  // 16-bit channel
    Bits32 = 1,  // 32-bit channel
}

// I2S Mode
I2S_Mode :: enum u32 {
    SlaveTx  = 0,  // Slave transmit
    SlaveRx  = 1,  // Slave receive
    MasterTx = 2,  // Master transmit (DAC output)
    MasterRx = 3,  // Master receive (mic input)
}

// I2S Configuration
I2S_Config :: struct {
    standard:       I2S_Standard,
    data_length:    I2S_DataLength,
    channel_length: I2S_ChannelLength,
    mode:           I2S_Mode,
    clock_polarity: bool,  // false = idle low, true = idle high
    mck_output:     bool,  // Master clock output enable
}

// I2S Handle
I2S_Handle :: struct {
    regs: ^device.SPI1_Registers,  // SPI2/SPI3 have same register layout
    pclk: u32,                      // Peripheral clock frequency
}

// Common sample rates and their divider values
// Formula: Fs = I2SxCLK / [(16*2)*((2*I2SDIV)+ODD)*8)] for 16-bit channel
// Or:      Fs = I2SxCLK / [(32*2)*((2*I2SDIV)+ODD)*4)] for 32-bit channel

// Pre-calculated dividers for common sample rates at 8MHz I2S clock
// These assume PLLI2S or external I2S clock is configured
I2S_DIVIDER_8MHZ_8KHZ   :: 0x1F  // ~8kHz
I2S_DIVIDER_8MHZ_16KHZ  :: 0x0F  // ~16kHz
I2S_DIVIDER_8MHZ_32KHZ  :: 0x07  // ~32kHz
I2S_DIVIDER_8MHZ_48KHZ  :: 0x05  // ~48kHz

// Initialize I2S peripheral
i2s_init :: proc "c" (handle: ^I2S_Handle, config: I2S_Config) {
    // Disable I2S during configuration
    hal.reg_modify(&handle.regs.I2SCFGR, .Clear, device.SPI1_I2SCFGR_I2SE_Mask_Shifted)

    // Build I2SCFGR value
    i2scfgr: u32 = 0

    // I2S mode enable
    i2scfgr |= 1 << device.SPI1_I2SCFGR_I2SMOD_Pos

    // Mode (master/slave, tx/rx)
    i2scfgr |= u32(config.mode) << device.SPI1_I2SCFGR_I2SCFG_Pos

    // Standard (Philips, MSB, LSB, PCM)
    i2scfgr |= u32(config.standard) << device.SPI1_I2SCFGR_I2SSTD_Pos

    // Clock polarity
    if config.clock_polarity {
        i2scfgr |= 1 << device.SPI1_I2SCFGR_CKPOL_Pos
    }

    // Data length
    i2scfgr |= u32(config.data_length) << device.SPI1_I2SCFGR_DATLEN_Pos

    // Channel length
    i2scfgr |= u32(config.channel_length) << device.SPI1_I2SCFGR_CHLEN_Pos

    hal.reg_write(&handle.regs.I2SCFGR, i2scfgr)
}

// Set I2S prescaler for desired sample rate
// divider: I2SDIV value (2-255)
// odd: true for odd divider ((2*div)+1), false for even (2*div)
i2s_set_prescaler :: proc "c" (handle: ^I2S_Handle, divider: u8, odd: bool, mck_output: bool) {
    i2spr: u32 = 0

    i2spr |= u32(divider) << device.SPI1_I2SPR_I2SDIV_Pos

    if odd {
        i2spr |= 1 << device.SPI1_I2SPR_ODD_Pos
    }

    if mck_output {
        i2spr |= 1 << device.SPI1_I2SPR_MCKOE_Pos
    }

    hal.reg_write(&handle.regs.I2SPR, i2spr)
}

// Enable I2S
i2s_enable :: proc "c" (handle: ^I2S_Handle) {
    hal.reg_modify(&handle.regs.I2SCFGR, .Set, device.SPI1_I2SCFGR_I2SE_Mask_Shifted)
}

// Disable I2S
i2s_disable :: proc "c" (handle: ^I2S_Handle) {
    hal.reg_modify(&handle.regs.I2SCFGR, .Clear, device.SPI1_I2SCFGR_I2SE_Mask_Shifted)
}

// Check if RX buffer not empty
i2s_rx_ready :: proc "c" (handle: ^I2S_Handle) -> bool {
    sr := hal.reg_read(&handle.regs.SR)
    return (sr & device.SPI1_SR_RXNE_Mask_Shifted) != 0
}

// Check if TX buffer empty
i2s_tx_ready :: proc "c" (handle: ^I2S_Handle) -> bool {
    sr := hal.reg_read(&handle.regs.SR)
    return (sr & device.SPI1_SR_TXE_Mask_Shifted) != 0
}

// Get current channel (left/right)
i2s_get_channel :: proc "c" (handle: ^I2S_Handle) -> bool {
    sr := hal.reg_read(&handle.regs.SR)
    return (sr & device.SPI1_SR_CHSIDE_Mask_Shifted) != 0  // false=left, true=right
}

// Check if busy
i2s_is_busy :: proc "c" (handle: ^I2S_Handle) -> bool {
    sr := hal.reg_read(&handle.regs.SR)
    return (sr & device.SPI1_SR_BSY_Mask_Shifted) != 0
}

// Read 16-bit sample (blocking)
i2s_read_sample :: proc "c" (handle: ^I2S_Handle) -> u16 {
    // Wait for data
    for !i2s_rx_ready(handle) {}
    return u16(hal.reg_read(&handle.regs.DR))
}

// Write 16-bit sample (blocking)
i2s_write_sample :: proc "c" (handle: ^I2S_Handle, sample: u16) {
    // Wait for TX empty
    for !i2s_tx_ready(handle) {}
    hal.reg_write(&handle.regs.DR, u32(sample))
}

// Read stereo sample pair (blocking)
// Returns left and right channel samples
i2s_read_stereo :: proc "c" (handle: ^I2S_Handle) -> (left: i16, right: i16) {
    // Read two samples - order depends on when we start
    s1 := i2s_read_sample(handle)
    ch1 := i2s_get_channel(handle)
    s2 := i2s_read_sample(handle)

    if ch1 {
        // First was right
        right = i16(s1)
        left = i16(s2)
    } else {
        // First was left
        left = i16(s1)
        right = i16(s2)
    }
    return
}

// Enable RX DMA
i2s_enable_rx_dma :: proc "c" (handle: ^I2S_Handle) {
    hal.reg_modify(&handle.regs.CR2, .Set, device.SPI1_CR2_RXDMAEN_Mask_Shifted)
}

// Disable RX DMA
i2s_disable_rx_dma :: proc "c" (handle: ^I2S_Handle) {
    hal.reg_modify(&handle.regs.CR2, .Clear, device.SPI1_CR2_RXDMAEN_Mask_Shifted)
}

// Enable TX DMA
i2s_enable_tx_dma :: proc "c" (handle: ^I2S_Handle) {
    hal.reg_modify(&handle.regs.CR2, .Set, device.SPI1_CR2_TXDMAEN_Mask_Shifted)
}

// Disable TX DMA
i2s_disable_tx_dma :: proc "c" (handle: ^I2S_Handle) {
    hal.reg_modify(&handle.regs.CR2, .Clear, device.SPI1_CR2_TXDMAEN_Mask_Shifted)
}

// Get DR register address for DMA configuration
i2s_get_dr_address :: proc "c" (handle: ^I2S_Handle) -> uintptr {
    return uintptr(&handle.regs.DR)
}

// Check for overrun error
i2s_check_overrun :: proc "c" (handle: ^I2S_Handle) -> bool {
    sr := hal.reg_read(&handle.regs.SR)
    return (sr & device.SPI1_SR_OVR_Mask_Shifted) != 0
}

// Clear overrun by reading DR then SR
i2s_clear_overrun :: proc "c" (handle: ^I2S_Handle) {
    _ = hal.reg_read(&handle.regs.DR)
    _ = hal.reg_read(&handle.regs.SR)
}

// Check for underrun error (TX mode)
i2s_check_underrun :: proc "c" (handle: ^I2S_Handle) -> bool {
    sr := hal.reg_read(&handle.regs.SR)
    return (sr & device.SPI1_SR_UDR_Mask_Shifted) != 0
}

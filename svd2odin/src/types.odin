package svd2odin

// SVD data structures
// Simplified representation of CMSIS-SVD format

Device :: struct {
    name:        string,
    description: string,
    peripherals: [dynamic]Peripheral,
    interrupts:  [dynamic]Interrupt,
    cpu:         CPU_Info,
    has_rng:     bool,  // Hardware RNG peripheral detected
}

CPU_Info :: struct {
    name:     string,  // e.g., "CM4" (Cortex-M4)
    revision: string,
    fpu:      bool,
    mpu:      bool,
}

Memory_Config :: struct {
    flash_origin: u32,
    flash_size:   u32,
    ram_origin:   u32,
    ram_size:     u32,
    stack_size:   u32,  // Stack size (grows down from top of RAM)
    guard_size:   u32,  // Guard region size (MPU: 256 bytes, Canary: 4 bytes)
    has_mpu:      bool, // Device has MPU for guard region
}

// Board configuration structures (from board.yaml)

// Device section
Device_Config :: struct {
    svd:          string,
    mcu:          string,
    package_name: string,
    gpio_use_odr: bool,  // Force use of ODR instead of BSRR (for broken silicon)
}

// Board info section
Board_Info :: struct {
    name:        string,
    description: string,
}

// Memory sections
Memory_Section :: struct {
    origin: u32,
    size:   u32,
}

Stack_Config :: struct {
    size:       u32,
    protection: string,  // "canary", "mpu", or "none"
}

Memory_Config_YAML :: struct {
    flash: Memory_Section,
    ram:   Memory_Section,
    stack: Stack_Config,
}

// Clock configuration
Clock_Config :: struct {
    hsi_hz:    u32,
    lsi_hz:    u32,  // Internal low-speed oscillator (~32-60 kHz, device-specific)
    system_hz: u32,
    pclk1_hz:  u32,
    pclk2_hz:  u32,
}

// Generic GPIO pin configuration
GPIO_Config :: struct {
    name:        string,
    port:        string,  // e.g., "GPIOE"
    pin:         int,
    mode:        string,  // "input" or "output"
    pull:        string,  // "pullup", "pulldown", or "" (optional)
    active_high: bool,    // For inputs (optional)
    description: string,  // Optional description
}

// Pin configuration for peripherals
Pin_Config :: struct {
    port: string,  // GPIO port
    pin:  int,
    af:   int,     // Alternate function
}

// PWM channel configuration
PWM_Channel_Config :: struct {
    channel:  int,        // Channel number (1-4)
    pin:      Pin_Config, // GPIO pin with AF
    polarity: string,     // "active_high" or "active_low"
    duty:     int,        // Initial duty cycle (0-1000 = 0.0% - 100.0%)
}

// Generic peripheral configuration
// Different fields are used depending on the interface type
Peripheral_Config :: struct {
    name:       string,  // Optional name for this peripheral instance
    peripheral: string,  // Hardware peripheral (USART1, SPI1, I2C1, DMA1, etc)
    interface:  string,  // Interface type (uart, spi, i2c, dma, etc)

    // UART fields
    baud: int,
    tx:   Pin_Config,
    rx:   Pin_Config,

    // SPI fields
    mode:      int,     // SPI mode (0-3)
    speed:     int,     // Clock speed in Hz
    data_size: int,     // Data size in bits (8 or 16)
    bit_order: string,  // "msb" or "lsb"
    sck:       Pin_Config,
    miso:      Pin_Config,
    mosi:      Pin_Config,

    // I2C fields (shares 'speed' with SPI)
    scl: Pin_Config,
    sda: Pin_Config,

    // I2S fields
    standard:    string,  // "philips", "msb", "lsb", "pcm"
    sample_rate: int,     // Sample rate in Hz (8000, 16000, 32000, 48000)
    i2s_mode:    string,  // "master_rx", "master_tx", "slave_rx", "slave_tx"
    ws:          Pin_Config,  // Word select (L/R clock)
    ck:          Pin_Config,  // Bit clock
    sd:          Pin_Config,  // Serial data
    mck:         Pin_Config,  // Master clock (optional)

    // Timer/PWM fields
    timer_mode: string,  // "pwm" or "basic"
    frequency:  int,     // Timer frequency in Hz
    interrupt:  bool,    // Enable update interrupt (for basic mode)
    channels:   []PWM_Channel_Config,  // PWM channels

    // RTC fields (onboard STM32 RTC only; for external I2C RTCs use I2C driver)
    clock_source: string,  // "lse" (32.768kHz crystal) or "lsi" (~40kHz internal)

    // IWDG fields (Independent Watchdog - cannot be stopped once started)
    timeout_ms: int,  // Watchdog timeout in milliseconds

    // WWDG fields (Window Watchdog - must refresh within window)
    window_ms: int,   // Window time in milliseconds (refresh allowed when counter < window)

    // DMA fields
    enable: bool,

    // Associated GPIOs (CS pins, interrupts, etc)
    gpio: []GPIO_Config,
}

// Top-level board configuration
Board_Config :: struct {
    device:      Device_Config,
    board:       Board_Info,
    memory:      Memory_Config_YAML,
    clocks:      Clock_Config,
    gpio:        []GPIO_Config,
    peripherals: []Peripheral_Config,  // Changed to list
}

Interrupt :: struct {
    name:        string,
    description: string,
    value:       u32,  // IRQ number
}

Peripheral :: struct {
    name:         string,
    description:  string,
    base_address: u64,
    registers:    [dynamic]Register,
    derived_from: string,  // Name of parent peripheral if this is derived
}

Register :: struct {
    name:          string,
    description:   string,
    offset:        u32,
    size:          u32,
    reset_value:   u32,
    access:        Access_Type,
    fields:        [dynamic]Field,
    // Array/dimension info
    dim:           u32,  // Number of array elements (0 = not an array)
    dim_increment: u32,  // Offset between array elements
    dim_index:     string,  // Comma-separated indices (e.g., "0,1,2,3")
}

Field :: struct {
    name:        string,
    description: string,
    bit_offset:  u32,
    bit_width:   u32,
    values:      [dynamic]Enumerated_Value,
}

Enumerated_Value :: struct {
    name:        string,
    description: string,
    value:       u32,
}

Access_Type :: enum {
    Read_Only,
    Write_Only,
    Read_Write,
}

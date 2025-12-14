# stm32-odin

Bare metal STM32 development in Odin. Includes `svd2odin`, a code generator that converts SVD files into type-safe Odin register definitions.

**Status:** Work in progress. Core functionality works, some drivers incomplete, not everything is tested. Not much is documented. probably bugs in some places. i have not yet written 'real' projects yet, mostly just building infrastructure, so I am not yet certain the design of the modules is ideal or not. 

## Planned Target Example Boards

I have each of the following boards and intend to build at least some examples for each. ESP32 support is *not* planned. You need to use the Xtensa Fork of LLVM, and I dont feel like chasing that down. If someone else wants to add it, ill take the PR so long as its well documented how it works.

STM32F303 Discovery - Done
WeAct F411 Black Pill - Partial / In Work (uses v3 minie as debug interface)
STM32F103 Nucleo - Not Started
STM32F103 Blue Pill - Not Started
Pico2 RP2350 - Not Started
Pico2W RP2350 - Not Started
WRL-25134 SparkFun Thing Plus RP2350 - Not Started
STM32 L432KC Nucleo - Not Started
Adafruit Feather nRF52840 Express - Not Started


## Dependencies

### Debug Interface

Either use of a Nucleo board which has its own internal debug interface / TX-ONLY virtual serial port, or a ST-Link V3-Minie (Strongly recomend this one). The cheap chinese clone V2 ST-Links were highly unreliable for me. The V3SET seemed like a mess, i never got it talking to the F411. I have not tried the V3SET on official STM Boards yet.

V3-Minie Solder Pads:
 CLK: SWSCK
 TMS: SWDIO
 GND: Ground
 VCC: 3v3 (This is a voltage sense-line)

I used Male-Female jumpers, soldering the male side directly to the v3 pads. I found someone who did a male 2x5 header pad and got it soldered to the v3-minie and it looks much nicer. this would allow female-female jumpers to the target board.


### ARM Toolchain

**Arch Linux:**
```sh
sudo pacman -S arm-none-eabi-gcc arm-none-eabi-newlib arm-none-eabi-gdb openocd stlink
```

**Ubuntu/Debian:**
```sh
sudo apt install gcc-arm-none-eabi libnewlib-arm-none-eabi gdb-multiarch openocd stlink-tools
```

**macOS (Homebrew):**

(I think? untested)

```sh
brew install arm-none-eabi-gcc openocd stlink
```

### Summary

| Tool | Purpose |
|------|---------|
| `odin` | Odin compiler |
| `arm-none-eabi-gcc` | ARM cross-compiler (includes `as`, `ld`, `objcopy`) |
| `arm-none-eabi-newlib` | C library for embedded (provides libgcc) |
| `st-flash` / `stlink` | Flash firmware via ST-Link |
| `openocd` | Debug probe interface (optional) |
| `arm-none-eabi-gdb` | Debugger (optional) |

## Supported Boards

| Board | MCU | Status |
|-------|-----|--------|
| WeAct Black Pill | STM32F411CEU6 | Active development |
| STM32F303 Discovery | STM32F303VCT6 | Examples included |
| STM32F401 Nucleo | STM32F401RE | Partial |

## Quick Start

### 1. Clone and enter directory
```sh
git clone <repo-url>
cd stm32
```

### 2. Get an SVD file

SVD files contain register definitions for your chip. Download from:
- TinyGo mirror: `https://github.com/tinygo-org/stm32-svd`
- ST product page → "CAD Resources" → "System View Description"

Place SVD files in the `svd/` directory.

### 3. Create a board config

Copy an existing board config as a starting point:
```sh
cp boards/blackpill_f411/board.yaml my_board.yaml
```

Edit to match your board's MCU, memory layout, clocks, and GPIO. See the F303/F411 Blackpill examples, or read the yaml config parser (ill work on documenting better as this matures).

### 4. Generate code

```sh
# Build the code generator
cd svd2odin && ./build.sh && cd ..

# Generate peripheral code and drivers
./svd2odin/svd2odin my_board.yaml src/stm32
```

This generates:
- `src/stm32/cmsis/device/*.odin` - Register definitions for all peripherals
- `src/stm32/board/` - Startup code, linker script, GPIO config
- `src/stm32/drivers/` - UART, SPI, I2C, DMA drivers
- `src/stm32/hal/` - Portable register operations

### 5. Write Main Application

(See Examples)

### 6. Build

```sh
./build.sh
```

Output: `build/firmware.bin`

### 7. Flash

```sh
st-flash write build/firmware.bin 0x08000000
```

Or use `./flash.sh` which builds and flashes in one step.

## Project Structure

```
stm32/
├── src/
│   ├── main.odin              # Your application
│   └── stm32/                 # Generated code
│       ├── board/             # Board-specific (startup, linker script)
│       ├── cmsis/device/      # Peripheral registers
│       ├── drivers/           # High-level drivers (uart, spi, i2c, ...)
│       ├── hal/               # Portable register operations
│       └── freestanding/      # Runtime (allocator, panic handlers)
├── svd/                       # SVD files
├── boards/                    # Board configuration files
├── svd2odin/                  # Code generator
│   ├── src/                   # Generator source
│   ├── driver_templates/      # Driver templates
│   └── examples/              # Example projects
├── build.sh                   # Build firmware
├── flash.sh                   # Build and flash
├── regenerate.sh              # Regenerate all code from SVD
└── board.yaml                 # Active board config (symlink)
```

## Regenerating Code

If you modify `board.yaml` or want to regenerate everything:

```sh
./regenerate.sh
```

## Serial Output

For UART debug output:
```sh
# Check for USB serial device
ls /dev/ttyUSB* /dev/ttyACM*

# Connect with minicom
minicom -D /dev/ttyACM0 -b 115200

# Or raw terminal
stty -F /dev/ttyACM0 115200 raw -echo
cat /dev/ttyACM0
```

## Examples

See `svd2odin/examples/f303_discovery/` for working examples:
- LED animation
- RTC (Real-Time Clock)
- Watchdog timer
- I2C accelerometer/magnetometer
- SPI gyroscope
- UART with interrupts

## Known Issues

- Some F4 series drivers need register type fixes for SPI/I2C
- F411 Blackpill: examples incomplete, havent figured out flashing DFU yet.
- RTTI is enabled due to runtime.Allocator issues (~20-40KB overhead)

## License

BSD-3

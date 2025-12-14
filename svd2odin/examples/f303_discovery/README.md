# STM32F303 Discovery Examples

Example applications for the STM32F303 Discovery board.

## Files

- `board.yaml` - Board configuration for svd2odin generator
- `STM32F303.svd` - SVD file describing STM32F303 peripherals
- `build.sh` - Build script (copy to project root)

## Examples

### led_spiral.odin
Simple LED spiral animation with UART output. Good starting point.

**Usage:** Copy to `src/main.odin`

### rtc.odin
Real-Time Clock example. Sets time and reads it back every second.

**Usage:** Copy to `src/main.odin`

### iwdg.odin
Independent Watchdog example. Demonstrates timeout and reset behavior.

**Usage:** Copy to `src/main.odin`

### imu.odin + lsm303.odin
Accelerometer and magnetometer reading from on-board LSM303DLHC sensor (I2C).

**Usage:** Copy both files to `src/`

### gyro.odin + l3gd20.odin
Gyroscope reading from on-board L3GD20 sensor (SPI).

**Usage:** Copy both files to `src/`

## Quick Start

```bash
# Generate code from SVD
cd svd2odin
./svd2odin examples/f303_discovery/board.yaml ../src/stm32/cmsis

# Copy example
cp examples/f303_discovery/led_spiral.odin ../src/main.odin

# Build
cd ..
./build.sh

# Flash
st-flash write build/firmware.bin 0x08000000
```

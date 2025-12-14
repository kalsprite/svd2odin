# Dev Notes

## Toolchain Installation

```sh
sudo pacman -S arm-none-eabi-gcc arm-none-eabi-newlib arm-none-eabi-gdb openocd stlink
sudo pacman -S stlink
sudo pacman -S openocd arm-none-eabi-gdb
```

## SVD Files (System View Description)

SVD files contain complete register/peripheral definitions for STM32 chips in XML format.

### Official ST Sources

**STM32F303VC (F3Discovery):**
1. https://www.st.com/en/microcontrollers-microprocessors/stm32f303vc.html
2. Navigate to "CAD Resources" or "HW Model, CAD Libraries & SVD" section
3. Download "System View Description (SVD)" ZIP file

**General STM32:**
- Product page → "CAD Resources & Symbols" → "System View Description"
- Or included in STM32CubeMX installation under: `STM32CubeMX/db/mcu/`

### Community Mirrors 

```sh
# TinyGo repository (used in this project)
curl -O https://raw.githubusercontent.com/tinygo-org/stm32-svd/main/svd/stm32f303.svd

# Other options:
# https://github.com/modm-io/cmsis-svd-stm32
# https://github.com/svcguy/stm32-svd
```


# Set up the port
  stty -F /dev/ttyACM0 115200 raw -echo

  # Read output
  cat /dev/ttyACM0

  Black Pill needs PA10 grounded for DFU Mode.. I can confirm DFU enter works with this.. however i cannot get past 87% on flashing the firmware. 
  https://arduino.stackexchange.com/questions/93017/stm32-black-pill-wont-enter-dfu-mode-reliably


  minicom -D /dev/ttyACM0 -b 115200

  To check which device:
  ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null
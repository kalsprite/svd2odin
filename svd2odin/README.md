# svd2odin

**SVD to Odin code generator for STM32 microcontrollers**

Converts CMSIS-SVD files into complete, type-safe Odin register definitions with helper functions.

## Quick Start

```bash
# Build the tool
./build.sh

# Generate code for STM32F303
./svd2odin STM32F303.svd output/

# Outputs 67 peripheral files + 1 interrupts file
```

## Generated API

### 1. Portable HAL Layer (`hal/register.odin`)
```odin
package hal

Register :: distinct u32  // Type-safe register

Reg_Op :: enum {
    Set,    // Set bits: value | mask
    Clear,  // Clear bits: value & ~mask
    Toggle, // Toggle bits: value ^ mask
}

// Generic operations (work on ANY chip!)
reg_read      :: proc "c" (reg: ^Register) -> u32
reg_write     :: proc "c" (reg: ^Register, value: u32)
reg_modify    :: proc { reg_modify_op, reg_modify_fn }  // Overloaded!
reg_set_field :: proc "c" (reg: ^Register, mask: u32, value: u32)
reg_set_enum  :: proc "c" (reg: ^Register, pos: u32, mask: u32, value: u32)
```

### 2. Peripheral Registers (chip-specific)
```odin
package stm32f3
import hal "../hal"

GPIOA_Registers :: struct {
    MODER:   hal.Register,  // 0x00: GPIO port mode register
    OTYPER:  hal.Register,  // 0x04: GPIO port output type register
    // ...
}

GPIOA_BASE :: 0x48000000
GPIOA := cast(^GPIOA_Registers)cast(uintptr)GPIOA_BASE
```

### 3. Field Enumerations
```odin
GPIOA_MODER_MODER0 :: enum u32 {
    Input     = 0,  // Input mode (reset state)
    Output    = 1,  // General purpose output mode
    Alternate = 2,  // Alternate function mode
    Analog    = 3,  // Analog mode
}
```

### 4. Position/Mask Constants
```odin
GPIOA_MODER_MODER8_Pos  :: 16
GPIOA_MODER_MODER8_Mask :: 0x3
GPIOA_MODER_MODER8_Mask_Shifted :: 0x3 << GPIOA_MODER_MODER8_Pos
```

## Getting SVD Files

**Official ST sources:**
1. Visit https://www.st.com/en/microcontrollers-microprocessors/stm32f303vc.html
2. Navigate to "CAD Resources & Symbols" section
3. Download "System View Description (SVD)" ZIP


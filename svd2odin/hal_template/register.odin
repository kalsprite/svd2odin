// Generic HAL register operations
// Portable across all microcontrollers
package hal

import "base:intrinsics"

Register :: distinct u32

Reg_Op :: enum {
    Set,    // Set bits: value | mask
    Clear,  // Clear bits: value & ~mask
    Toggle, // Toggle bits: value ^ mask
}

// Read register with volatile semantics
reg_read :: proc "c" (reg: ^Register) -> u32 {
    return intrinsics.volatile_load(cast(^u32)reg)
}

// Write register with volatile semantics
reg_write :: proc "c" (reg: ^Register, value: u32) {
    intrinsics.volatile_store(cast(^u32)reg, value)
}

// Modify register with operation (read-modify-write)
reg_modify :: proc {
    reg_modify_op,
    reg_modify_fn,
}

reg_modify_op :: proc "c" (reg: ^Register, op: Reg_Op, mask: u32) {
    val := intrinsics.volatile_load(cast(^u32)reg)
    switch op {
    case .Set:    val |= mask
    case .Clear:  val &= ~mask
    case .Toggle: val ~= mask
    }
    intrinsics.volatile_store(cast(^u32)reg, val)
}

reg_modify_fn :: proc "c" (reg: ^Register, modify_fn: proc "c" (u32) -> u32) {
    val := intrinsics.volatile_load(cast(^u32)reg)
    val = modify_fn(val)
    intrinsics.volatile_store(cast(^u32)reg, val)
}

// Set bitfield in register (read-modify-write)
// mask: bits to modify, value: new value (both pre-shifted)
reg_set_field :: proc "c" (reg: ^Register, mask: u32, value: u32) {
    val := reg_read(reg)
    val = (val & ~mask) | (value & mask)
    reg_write(reg, val)
}

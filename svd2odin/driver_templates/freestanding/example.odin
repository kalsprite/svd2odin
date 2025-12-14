// Example: Using the Freestanding Runtime Hooks
// This shows how to integrate the runtime hooks into your bare metal application

package main

import freestanding "stm32f3/freestanding"  // Adjust for your chip
import debug "stm32f3/debug"
import "core:mem"

// Entry point from startup assembly
@(export)
app_main :: proc "c" () {
    // 1. Initialize debug UART first (needed by _stderr_write)
    debug.init(.Baud115200)

    // 2. Initialize runtime (sets up allocator, calls _startup_runtime)
    freestanding.init()

    // 3. Your application code
    main()

    // 4. Cleanup and exit
    freestanding.cleanup()
    freestanding._exit(0)
}

main :: proc() {
    debug.println("STM32 Bare Metal with Runtime Hooks")
    debug.println("===================================")

    // Now can use dynamic memory allocation!
    dynamic_array := make([dynamic]int)
    defer delete(dynamic_array)

    append(&dynamic_array, 1, 2, 3, 4, 5)
    debug.printf("Array length: %d\r\n", len(dynamic_array))

    // Test panic handler (will output via _stderr_write)
    // Uncomment to test:
    // panic("This is a test panic!")

    // Test assert (will output via _stderr_write)
    value := 42
    assert(value == 42, "Value should be 42")
    debug.println("Assert passed!")

    // Check allocator usage
    used, total := freestanding.get_allocator_usage()
    debug.printf("Allocator: %d / %d bytes used\r\n", used, total)

    // Example: Reset allocator to reclaim all memory
    // freestanding.reset_allocator()

    debug.println("Example complete!")
}

// Alternative: Manual integration without runtime package
// If you want more control, you can implement these directly:

/*
import "base:runtime"

arena_buffer: [32 * 1024]byte
arena: mem.Arena

_stderr_write :: proc "contextless" (data: []byte) -> (int, runtime._OS_Errno) {
    debug.print(string(data))
    return len(data), 0
}

_exit :: proc "contextless" (code: int) -> ! {
    for {}
}

@(export)
app_main :: proc "c" () {
    runtime._startup_runtime()

    mem.arena_init(&arena, arena_buffer[:])
    context.allocator = mem.arena_allocator(&arena)

    main()

    runtime._cleanup_runtime()
    _exit(0)
}
*/

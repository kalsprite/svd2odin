package freestanding

import "base:runtime"
import debug "../board/debug"

// Freestanding Runtime Hooks
// Required for bare metal Odin applications
// These hooks provide panic/assert output and exit behavior

// Stack overflow protection configuration (templated by svd2odin)
HAS_MPU :: false        // Templated: true if device has MPU
GUARD_SIZE :: 256       // Templated: 256 for MPU, 4 for canary
STACK_CANARY :: 0xDEADBEEF

// Global heap for bare metal (general-purpose free-list allocator)
// Size auto-calculated as (RAM - stack_size - guard_size) from memory config
// Memory layout: [.data/.bss][heap][guard][stack]
//
// Strategy: Provide flexible baseline, users specialize as needed
//   - Default: Free-list allocator (malloc/free semantics)
//   - Users carve out sub-allocators: arenas, pools, scratch
//   - Compose using Odin's mem.Arena, mem.Pool, etc.
//
// Example usage:
//   freestanding.init()  // Sets context.allocator to free-list
//
//   // Use directly (malloc/free):
//   buffer := make([]byte, 1024)
//   defer delete(buffer)
//
//   // Create arena for subsystem:
//   arena_mem := make([]byte, 8192)  // From free-list
//   arena: mem.Arena
//   mem.arena_init(&arena, arena_mem)
//   context.allocator = mem.arena_allocator(&arena)  // Fast bump allocations
//
heap_buffer: [64 * 1024]byte  // Templated: ram_size - stack_size - guard_size
heap: Free_List_Allocator

// Free-list allocator for bare metal
// Simple first-fit allocator with coalescing
// Provides malloc/free semantics with static memory pool
Free_List_Allocator :: struct {
    buffer: []byte,
    head: ^Free_Block,  // Head of free block list
}

Free_Block :: struct {
    size: uintptr,      // Size of entire block including header
    next: ^Free_Block,  // Next free block (null if last)
}

BLOCK_HEADER_SIZE :: size_of(Free_Block)
MIN_BLOCK_SIZE :: 32  // Minimum allocation size (including header)
ALIGNMENT :: 8        // 8-byte alignment for ARM

// Stack guard (MPU region or canary depending on HAS_MPU)
when !HAS_MPU {
    // Stack canary for non-MPU devices
    // Placed at boundary between heap and stack
    stack_guard: u32 = STACK_CANARY
}

// ============================================================================
// Free-List Allocator Implementation
// ============================================================================

// Align size up to ALIGNMENT boundary
align_up :: proc "c" (size: uintptr) -> uintptr {
    mask := uintptr(ALIGNMENT - 1)
    return (size + mask) & ~mask
}

// Initialize free-list allocator with memory buffer
free_list_init :: proc "c" (allocator: ^Free_List_Allocator, buffer: []byte) {
    allocator.buffer = buffer

    // Create initial free block spanning entire buffer
    initial_block := cast(^Free_Block)raw_data(buffer)
    initial_block.size = uintptr(len(buffer))
    initial_block.next = nil

    allocator.head = initial_block
}

// Allocate memory from free-list
free_list_alloc :: proc "c" (allocator: ^Free_List_Allocator, size: uintptr) -> rawptr {
    if size == 0 {
        return nil
    }

    // Align requested size and add header
    total_size := align_up(size + BLOCK_HEADER_SIZE)
    if total_size < MIN_BLOCK_SIZE {
        total_size = MIN_BLOCK_SIZE
    }

    // First-fit search
    prev: ^Free_Block = nil
    current := allocator.head

    for current != nil {
        if current.size >= total_size {
            // Found a suitable block
            remaining := current.size - total_size

            if remaining >= MIN_BLOCK_SIZE {
                // Split the block
                new_block := cast(^Free_Block)(uintptr(current) + total_size)
                new_block.size = remaining
                new_block.next = current.next

                current.size = total_size

                if prev != nil {
                    prev.next = new_block
                } else {
                    allocator.head = new_block
                }
            } else {
                // Use entire block (too small to split)
                if prev != nil {
                    prev.next = current.next
                } else {
                    allocator.head = current.next
                }
            }

            // Return pointer past header
            return rawptr(uintptr(current) + BLOCK_HEADER_SIZE)
        }

        prev = current
        current = current.next
    }

    // Out of memory
    return nil
}

// Free memory back to free-list with coalescing
free_list_free :: proc "c" (allocator: ^Free_List_Allocator, ptr: rawptr) {
    if ptr == nil {
        return
    }

    // Get block header
    block := cast(^Free_Block)(uintptr(ptr) - BLOCK_HEADER_SIZE)

    // Validate block is within buffer bounds
    block_addr := uintptr(block)
    buffer_start := uintptr(raw_data(allocator.buffer))
    buffer_end := buffer_start + uintptr(len(allocator.buffer))

    if block_addr < buffer_start || block_addr >= buffer_end {
        // Invalid free - ignore (could panic in debug mode)
        return
    }

    // Insert block into free list (sorted by address for coalescing)
    prev: ^Free_Block = nil
    current := allocator.head

    // Find insertion point (keep list sorted by address)
    for current != nil && uintptr(current) < uintptr(block) {
        prev = current
        current = current.next
    }

    // Insert block
    block.next = current
    if prev != nil {
        prev.next = block
    } else {
        allocator.head = block
    }

    // Coalesce with next block if adjacent
    if current != nil {
        block_end := uintptr(block) + block.size
        if block_end == uintptr(current) {
            block.size += current.size
            block.next = current.next
        }
    }

    // Coalesce with previous block if adjacent
    if prev != nil {
        prev_end := uintptr(prev) + prev.size
        if prev_end == uintptr(block) {
            prev.size += block.size
            prev.next = block.next
        }
    }
}

// Resize allocation (realloc)
free_list_resize :: proc "c" (allocator: ^Free_List_Allocator, ptr: rawptr, old_size: uintptr, new_size: uintptr) -> rawptr {
    if ptr == nil {
        return free_list_alloc(allocator, new_size)
    }

    if new_size == 0 {
        free_list_free(allocator, ptr)
        return nil
    }

    // Allocate new block
    new_ptr := free_list_alloc(allocator, new_size)
    if new_ptr == nil {
        return nil
    }

    // Copy old data
    copy_size := old_size if old_size < new_size else new_size
    runtime.mem_copy(new_ptr, ptr, int(copy_size))

    // Free old block
    free_list_free(allocator, ptr)

    return new_ptr
}

// Get allocator stats
free_list_stats :: proc "c" (allocator: ^Free_List_Allocator) -> (free: uintptr, largest_block: uintptr, num_blocks: int) {
    current := allocator.head
    for current != nil {
        free += current.size
        if current.size > largest_block {
            largest_block = current.size
        }
        num_blocks += 1
        current = current.next
    }
    return
}

// Create Odin allocator interface
free_list_allocator :: proc "c" (allocator: ^Free_List_Allocator) -> runtime.Allocator {
    return runtime.Allocator{
        procedure = free_list_allocator_proc,
        data = allocator,
    }
}

free_list_allocator_proc :: proc(
        allocator_data: rawptr,
        mode: runtime.Allocator_Mode,
        size: int,
        alignment: int,
        old_memory: rawptr,
        old_size: int,
        location := #caller_location,
    ) -> ([]byte, runtime.Allocator_Error) {

        allocator := cast(^Free_List_Allocator)allocator_data

        switch mode {
        case .Alloc, .Alloc_Non_Zeroed:
            ptr := free_list_alloc(allocator, uintptr(size))
            if ptr == nil {
                return nil, .Out_Of_Memory
            }

            if mode == .Alloc {
                runtime.mem_zero(ptr, size)
            }

            return ([^]byte)(ptr)[:size], .None

        case .Free:
            free_list_free(allocator, old_memory)
            return nil, .None

        case .Resize, .Resize_Non_Zeroed:
            ptr := free_list_resize(allocator, old_memory, uintptr(old_size), uintptr(size))
            if ptr == nil {
                return nil, .Out_Of_Memory
            }

            if mode == .Resize && size > old_size {
                // Zero new memory
                new_bytes := uintptr(ptr) + uintptr(old_size)
                runtime.mem_zero(rawptr(new_bytes), size - old_size)
            }

            return ([^]byte)(ptr)[:size], .None

        case .Free_All:
            // Reset to single free block
            free_list_init(allocator, allocator.buffer)
            return nil, .None

        case .Query_Features:
            set := (^runtime.Allocator_Mode_Set)(old_memory)
            if set != nil {
                set^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Resize, .Resize_Non_Zeroed, .Free_All, .Query_Features}
            }
            return nil, .None

        case .Query_Info:
            return nil, .Mode_Not_Implemented
        }

        return nil, .Mode_Not_Implemented
}

// Initialize runtime for bare metal
// Call this before your main application code
//
// Runtime initialization:
//   - Sets up free-list allocator
//   - Configures context.allocator
//   - Sets up stack overflow protection
//
// RTTI (Runtime Type Information):
//   Build with -no-rtti to save 20-40KB of flash (RECOMMENDED for embedded)
//
//   WITH RTTI (default):
//     ✓ Dynamic arrays, maps, slices (same as without)
//     ✓ 'any' type (type erasure)
//     ✓ Reflection: type_info_of(), typeid
//     ✓ fmt.printf with %v (generic formatting)
//     Cost: 20-40KB of flash for type metadata
//
//   WITHOUT RTTI (-no-rtti flag):
//     ✓ Dynamic arrays, maps, slices (STILL WORK!)
//     ✓ All allocations (make, new, delete)
//     ✓ All normal Odin code
//     ✗ 'any' type
//     ✗ Reflection/introspection
//     ✗ fmt.printf with %v
//     Benefit: 20-40KB flash savings
//
// Allocator strategy:
//   Default: Free-list allocator (malloc/free semantics)
//   Users can create sub-allocators (arenas, pools) on top:
//     arena_mem := make([]byte, 8192)  // From free-list
//     arena: mem.Arena
//     mem.arena_init(&arena, arena_mem)
//     context.allocator = mem.arena_allocator(&arena)
//
init :: proc() {  // Not "c" because it uses context
    // Setup free-list allocator
    free_list_init(&heap, heap_buffer[:])
    context.allocator = free_list_allocator(&heap)
    context.temp_allocator = free_list_allocator(&heap)

    // Setup panic handler
    context.assertion_failure_proc = panic_handler

    // Setup stack overflow protection
    when HAS_MPU {
        setup_mpu_guard()
    } else {
        // Canary is initialized at declaration
        // Verify it's intact
        if stack_guard != STACK_CANARY {
            debug.print("FATAL: Stack canary corrupted during init\n")
            _exit(1)
        }
    }
}

// Setup MPU guard region to protect against stack overflow
when HAS_MPU {
    setup_mpu_guard :: proc "c" () {
        // Calculate guard region address (between arena and stack)
        // Guard starts at: ram_origin + sizeof(.data/.bss) + arena_size
        // For simplicity, we protect the region right after arena_buffer
        guard_addr := uintptr(&arena_buffer[len(arena_buffer)])

        // MPU Region configuration for guard
        // Region must be:
        // - Size: power of 2 (256 bytes minimum)
        // - Aligned to size
        // - No access permissions (XN=1, AP=000)

        // Enable MPU with default memory map
        device.MPU.CTRL = device.MPU_CTRL_ENABLE_Mask_Shifted |
                         device.MPU_CTRL_PRIVDEFENA_Mask_Shifted

        // Configure region 0 as guard (no access)
        // Base address (must be 256-byte aligned)
        device.MPU.RBAR = u32(guard_addr) | (0 << 0)  // Region 0

        // Region attributes:
        // Size: 256 bytes (2^8, encoded as (8-1) << 1 = 7 << 1)
        // XN: 1 (execute never)
        // AP: 000 (no access)
        // Enable: 1
        size_bits := u32(7)  // log2(256) - 1
        device.MPU.RASR = (1 << 0) |      // ENABLE
                         (size_bits << 1) | // SIZE
                         (0 << 24) |      // AP=000 (no access)
                         (1 << 28)        // XN=1 (execute never)

        // Data Synchronization Barrier
        intrinsics.cpu_relax()  // DSB
    }
}

// Cleanup runtime (call before exit)
cleanup :: proc() {
    // Nothing to cleanup on freestanding
}

// Freestanding hook: Write to stderr
// Used by panic(), assert(), and runtime errors
// Outputs to debug UART
_stderr_write :: proc "contextless" (data: []byte) -> (int, runtime._OS_Errno) {
    // Write to debug UART
    // Note: This is contextless so we can't use normal Odin procedures
    // We directly access the debug UART if initialized
    debug.print(string(data))
    return len(data), 0
}

// Foreign assembly and C functions for interrupt control
foreign _ {
    @(link_name="disable_interrupts")
    disable_interrupts :: proc "c" () ---

    @(link_name="wait_for_interrupt")
    wait_for_interrupt :: proc "c" () ---
}

// Freestanding hook: Exit program
// Called on fatal errors or explicit exit
// For bare metal: just trap in infinite loop
_exit :: proc "contextless" (code: int) -> ! {
    // Disable interrupts before halting
    disable_interrupts()

    // Infinite loop (trap)
    for {
        // Halt - could enter low power mode here
        wait_for_interrupt()
    }
}

// Custom panic handler for bare metal
// Prints panic info to debug UART then halts
panic_handler :: proc (
    prefix: string,
    message: string,
    loc: runtime.Source_Code_Location,
) -> ! {
    // Disable interrupts immediately
    disable_interrupts()

    // Print panic header
    debug.print("\r\n\r\n")
    debug.print("==== PANIC ====\r\n")

    // Print message
    if len(message) > 0 {
        debug.print(message)
        debug.print("\r\n")
    }

    // Print location
    debug.print("Location: ")
    debug.print(loc.file_path)
    debug.print(":")

    // Print line number (convert to string manually since we can't use fmt)
    // For now, just print a placeholder - debug driver may not have u32_to_decimal
    debug.print("<line>:<col>")

    debug.print("\r\n")
    debug.print("===============\r\n\r\n")

    // Halt system
    _exit(1)
}

// Direct allocation functions (work with -no-rtti)
// Use these instead of make/delete when building with -no-rtti
make_bytes :: proc(size: int) -> []byte {
    ptr := free_list_alloc(&heap, uintptr(size))
    if ptr == nil {
        return nil
    }
    return ([^]byte)(ptr)[:size]
}

free_bytes :: proc(data: []byte) {
    if len(data) > 0 {
        free_list_free(&heap, raw_data(data))
    }
}

resize_bytes :: proc(data: []byte, new_size: int) -> []byte {
    if new_size == 0 {
        free_bytes(data)
        return nil
    }
    ptr := free_list_resize(&heap, raw_data(data), uintptr(len(data)), uintptr(new_size))
    if ptr == nil {
        return nil
    }
    return ([^]byte)(ptr)[:new_size]
}

// Reset allocator (useful for periodic cleanup)
// Frees all allocations at once
reset_allocator :: proc "c" () {
    free_list_init(&heap, heap_buffer[:])
}

// Get allocator stats
get_allocator_usage :: proc "c" () -> (free_bytes: int, largest_free: int, num_free_blocks: int, total: int) {
    free, largest, blocks := free_list_stats(&heap)
    free_bytes = int(free)
    largest_free = int(largest)
    num_free_blocks = blocks
    total = len(heap_buffer)
    return
}

// Get used memory
get_allocator_used :: proc "c" () -> int {
    free, _, _ := free_list_stats(&heap)
    return len(heap_buffer) - int(free)
}

// Check for stack overflow
// Returns true if stack is OK, false if overflow detected
// For MPU: Check if MemManage fault occurred (would have trapped already)
// For canary: Check if canary value is intact
check_stack_overflow :: proc "c" () -> bool {
    when HAS_MPU {
        // With MPU, any stack overflow triggers MemManage fault immediately
        // If we reach here, stack is OK
        // Could check MMFSR register for historical faults
        return true
    } else {
        // Check canary integrity
        return stack_guard == STACK_CANARY
    }
}

// Panic if stack overflow detected (for periodic checks)
assert_stack_ok :: proc "c" () {
    if !check_stack_overflow() {
        debug.print("FATAL: Stack overflow detected (canary corrupted)\n")
        _exit(1)
    }
}

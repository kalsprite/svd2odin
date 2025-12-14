package svd2odin

import "core:fmt"
import "core:os"
import "core:path/filepath"

main :: proc() {
    if len(os.args) < 3 {
        fmt.println("Usage: svd2odin <board.yaml> <output_dir>")
        fmt.println("")
        fmt.println("Example:")
        fmt.println("  svd2odin board.yaml src/stm32")
        fmt.println("")
        fmt.println("The board.yaml file should contain:")
        fmt.println("  - device.svd: Path to SVD file (relative to YAML)")
        fmt.println("  - memory layout (flash, ram, stack)")
        fmt.println("  - clocks configuration")
        fmt.println("  - gpio pins")
        fmt.println("  - peripherals (uart, dma, etc)")
        os.exit(1)
    }

    board_yaml := os.args[1]
    output_dir := os.args[2]

    // Parse board configuration (includes SVD path)
    fmt.printfln("Parsing board config: %s", board_yaml)
    board, board_ok := parse_board_config(board_yaml)
    if !board_ok {
        os.exit(1)
    }
    fmt.printfln("Board: %s (Package: %s)", board.board.name, board.device.package_name)

    // Resolve SVD path relative to YAML file
    yaml_dir := filepath.dir(board_yaml)
    svd_path := filepath.join({yaml_dir, board.device.svd})

    fmt.printfln("Parsing SVD file: %s", svd_path)
    device, ok := parse_svd(svd_path)
    if !ok {
        fmt.eprintln("Failed to parse SVD file")
        os.exit(1)
    }
    defer destroy_device(&device)

    fmt.printfln("Device: %s", device.name)
    fmt.printfln("CPU: %s (FPU: %v, MPU: %v)", device.cpu.name, device.cpu.fpu, device.cpu.mpu)
    fmt.printfln("Peripherals: %d", len(device.peripherals))
    fmt.printfln("Hardware RNG: %v", device.has_rng)

    // Build memory configuration from YAML
    memory := Memory_Config{
        flash_origin = board.memory.flash.origin,
        flash_size   = board.memory.flash.size,
        ram_origin   = board.memory.ram.origin,
        ram_size     = board.memory.ram.size,
        stack_size   = board.memory.stack.size,
        guard_size   = board.memory.stack.protection == "canary" ? 4 : (board.memory.stack.protection == "mpu" ? 256 : 0),
        has_mpu      = device.cpu.mpu,
    }

    fmt.printfln("Using memory config from: board.yaml")
    fmt.printfln("Stack overflow protection: %s (%d bytes)",
        board.memory.stack.protection == "canary" ? "Stack canary" :
        (board.memory.stack.protection == "mpu" ? "MPU guard" : "None"),
        memory.guard_size)
    fmt.printfln("Memory: FLASH=0x%08X (%dK), RAM=0x%08X (%dK)",
        memory.flash_origin, memory.flash_size / 1024,
        memory.ram_origin, memory.ram_size / 1024)

    fmt.printfln("\nGenerating code to: %s", output_dir)
    fmt.printfln("Board code will be in: %s/board/", output_dir)

    // Generate Odin peripheral code and board code
    if !generate_code(device, board, memory, output_dir) {
        fmt.eprintln("Failed to generate Odin code")
        os.exit(1)
    }

    // Generate startup files (linker script + assembly) in board/
    board_dir := fmt.tprintf("%s/board", output_dir)
    if !generate_startup_files(device, memory, board_dir) {
        fmt.eprintln("Failed to generate startup files")
        os.exit(1)
    }

    // Copy runtime files (interrupt_helpers.s, stubs.c) to board/
    if !copy_runtime_files(board_dir) {
        fmt.eprintln("Failed to copy runtime files")
        os.exit(1)
    }

    fmt.println("\nDone!")
}

// Cleanup allocated memory
destroy_device :: proc(device: ^Device) {
    for &peripheral in device.peripherals {
        for &register in peripheral.registers {
            for &field in register.fields {
                delete(field.values)
            }
            delete(register.fields)
        }
        delete(peripheral.registers)
    }
    delete(device.peripherals)
}

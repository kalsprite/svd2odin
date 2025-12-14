package svd2odin

import "core:fmt"
import "core:os"
import "core:path/filepath"

// Runtime files to copy (relative to svd2odin executable)
RUNTIME_FILES :: []string{
    "runtime/interrupt_helpers.s",
    "runtime/stubs.c",
}

// Copy runtime files to output directory
copy_runtime_files :: proc(output_dir: string) -> bool {
    // Find the directory containing the svd2odin executable
    exe_path, exe_ok := os.args[0], true
    if !exe_ok {
        fmt.eprintln("Error: Could not get executable path")
        return false
    }

    exe_dir := filepath.dir(exe_path)

    // Copy each runtime file
    for runtime_file in RUNTIME_FILES {
        src_path := fmt.tprintf("%s/%s", exe_dir, runtime_file)
        filename := filepath.base(runtime_file)
        dst_path := fmt.tprintf("%s/%s", output_dir, filename)

        // Read source file
        data, ok := os.read_entire_file(src_path)
        if !ok {
            fmt.eprintfln("Error: Could not read runtime file: %s", src_path)
            return false
        }
        defer delete(data)

        // Write to destination
        if !os.write_entire_file(dst_path, data) {
            fmt.eprintfln("Error: Could not write runtime file: %s", dst_path)
            return false
        }

        fmt.printfln("Copied: %s", dst_path)
    }

    return true
}

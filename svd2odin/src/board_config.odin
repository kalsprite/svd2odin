package svd2odin

import "core:fmt"
import "core:os"
import yaml "../yaml"

// Parse board.yaml configuration file
parse_board_config :: proc(board_yaml_path: string) -> (Board_Config, bool) {
    config: Board_Config

    // Read board.yaml file
    data, read_ok := os.read_entire_file(board_yaml_path)
    if !read_ok {
        fmt.eprintfln("Error: Could not read board config: %s", board_yaml_path)
        return config, false
    }
    defer delete(data)

    // Parse YAML
    yaml_str := string(data)
    err := yaml.unmarshal(yaml_str, &config)
    if err != .None {
        fmt.eprintfln("Error parsing board.yaml: %v", err)
        return config, false
    }

    return config, true
}

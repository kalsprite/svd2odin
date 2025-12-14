package svd2odin

import "core:encoding/xml"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:strconv"

// Parse SVD file and return Device structure
parse_svd :: proc(filename: string, allocator := context.allocator) -> (Device, bool) {
    context.allocator = allocator

    doc, err := xml.load_from_file(filename)
    if err != .None {
        fmt.eprintln("Failed to parse SVD file:", err)
        return {}, false
    }
    defer xml.destroy(doc)

    device: Device
    device.peripherals = make([dynamic]Peripheral, allocator)
    device.interrupts = make([dynamic]Interrupt, allocator)

    // Root element is always at index 0
    root_id := xml.Element_ID(0)
    root := doc.elements[root_id]

    if root.ident != "device" {
        fmt.eprintln("Root element is not <device>")
        return {}, false
    }

    // Find device name
    if name_id, ok := xml.find_child_by_ident(doc, root_id, "name"); ok {
        name_elem := doc.elements[name_id]
        if len(name_elem.value) > 0 {
            if text, is_string := name_elem.value[0].(string); is_string {
                device.name = strings.clone(text)
            }
        }
    }

    // Find CPU info
    if cpu_id, ok := xml.find_child_by_ident(doc, root_id, "cpu"); ok {
        device.cpu = parse_cpu_info(doc, cpu_id)
    }

    // Find peripherals
    if peripherals_id, ok := xml.find_child_by_ident(doc, root_id, "peripherals"); ok {
        peripherals_elem := doc.elements[peripherals_id]

        for v in peripherals_elem.value {
            if child_id, is_id := v.(xml.Element_ID); is_id {
                child := doc.elements[child_id]
                if child.ident == "peripheral" {
                    if peripheral, ok := parse_peripheral(doc, child_id); ok {
                        append(&device.peripherals, peripheral)

                        // Collect interrupts from this peripheral
                        collect_interrupts(doc, child_id, &device.interrupts)

                        // Detect hardware RNG peripheral
                        if peripheral.name == "RNG" {
                            device.has_rng = true
                        }
                    }
                }
            }
        }
    }

    return device, true
}

parse_peripheral :: proc(doc: ^xml.Document, periph_id: xml.Element_ID) -> (Peripheral, bool) {
    peripheral: Peripheral
    peripheral.registers = make([dynamic]Register)

    periph := doc.elements[periph_id]

    // Check for derivedFrom attribute
    for attrib in periph.attribs {
        if attrib.key == "derivedFrom" {
            peripheral.derived_from = strings.clone(attrib.val)
            break
        }
    }

    // Name
    if name_id, ok := xml.find_child_by_ident(doc, periph_id, "name"); ok {
        peripheral.name = get_element_text(doc, name_id)
    }

    // Description
    if desc_id, ok := xml.find_child_by_ident(doc, periph_id, "description"); ok {
        peripheral.description = get_element_text(doc, desc_id)
    }

    // Base address
    if base_id, ok := xml.find_child_by_ident(doc, periph_id, "baseAddress"); ok {
        addr_str := get_element_text(doc, base_id)
        peripheral.base_address = parse_addr_value(addr_str)
    }

    // Registers
    if registers_id, ok := xml.find_child_by_ident(doc, periph_id, "registers"); ok {
        registers_elem := doc.elements[registers_id]

        for v in registers_elem.value {
            if child_id, is_id := v.(xml.Element_ID); is_id {
                child := doc.elements[child_id]
                if child.ident == "register" {
                    if register, ok := parse_register(doc, child_id); ok {
                        append(&peripheral.registers, register)
                    }
                }
            }
        }
    }

    return peripheral, true
}

parse_register :: proc(doc: ^xml.Document, reg_id: xml.Element_ID) -> (Register, bool) {
    register: Register
    register.fields = make([dynamic]Field)

    // Name
    if name_id, ok := xml.find_child_by_ident(doc, reg_id, "name"); ok {
        register.name = get_element_text(doc, name_id)
    }

    // Description
    if desc_id, ok := xml.find_child_by_ident(doc, reg_id, "description"); ok {
        register.description = get_element_text(doc, desc_id)
    }

    // Address offset
    if offset_id, ok := xml.find_child_by_ident(doc, reg_id, "addressOffset"); ok {
        offset_str := get_element_text(doc, offset_id)
        register.offset = u32(parse_addr_value(offset_str))
    }

    // Size (default to 32 if not specified)
    register.size = 32
    if size_id, ok := xml.find_child_by_ident(doc, reg_id, "size"); ok {
        size_str := get_element_text(doc, size_id)
        register.size = u32(parse_addr_value(size_str))
    }

    // Reset value
    if reset_id, ok := xml.find_child_by_ident(doc, reg_id, "resetValue"); ok {
        reset_str := get_element_text(doc, reset_id)
        register.reset_value = u32(parse_addr_value(reset_str))
    }

    // Access type
    register.access = .Read_Write  // Default
    if access_id, ok := xml.find_child_by_ident(doc, reg_id, "access"); ok {
        access_str := get_element_text(doc, access_id)
        switch access_str {
        case "read-only":  register.access = .Read_Only
        case "write-only": register.access = .Write_Only
        case "read-write": register.access = .Read_Write
        }
    }

    // Array dimension info
    if dim_id, ok := xml.find_child_by_ident(doc, reg_id, "dim"); ok {
        dim_str := get_element_text(doc, dim_id)
        register.dim = u32(parse_addr_value(dim_str))
    }

    if dim_inc_id, ok := xml.find_child_by_ident(doc, reg_id, "dimIncrement"); ok {
        dim_inc_str := get_element_text(doc, dim_inc_id)
        register.dim_increment = u32(parse_addr_value(dim_inc_str))
    }

    if dim_idx_id, ok := xml.find_child_by_ident(doc, reg_id, "dimIndex"); ok {
        register.dim_index = get_element_text(doc, dim_idx_id)
    }

    // Fields
    if fields_id, ok := xml.find_child_by_ident(doc, reg_id, "fields"); ok {
        fields_elem := doc.elements[fields_id]

        for v in fields_elem.value {
            if child_id, is_id := v.(xml.Element_ID); is_id {
                child := doc.elements[child_id]
                if child.ident == "field" {
                    if field, ok := parse_field(doc, child_id); ok {
                        append(&register.fields, field)
                    }
                }
            }
        }
    }

    return register, true
}

parse_field :: proc(doc: ^xml.Document, field_id: xml.Element_ID) -> (Field, bool) {
    field: Field
    field.values = make([dynamic]Enumerated_Value)

    // Name
    if name_id, ok := xml.find_child_by_ident(doc, field_id, "name"); ok {
        field.name = get_element_text(doc, name_id)
    }

    // Description
    if desc_id, ok := xml.find_child_by_ident(doc, field_id, "description"); ok {
        field.description = get_element_text(doc, desc_id)
    }

    // Bit offset
    if offset_id, ok := xml.find_child_by_ident(doc, field_id, "bitOffset"); ok {
        offset_str := get_element_text(doc, offset_id)
        field.bit_offset = u32(parse_addr_value(offset_str))
    }

    // Bit width
    if width_id, ok := xml.find_child_by_ident(doc, field_id, "bitWidth"); ok {
        width_str := get_element_text(doc, width_id)
        field.bit_width = u32(parse_addr_value(width_str))
    }

    // Enumerated values
    if enum_id, ok := xml.find_child_by_ident(doc, field_id, "enumeratedValues"); ok {
        enum_elem := doc.elements[enum_id]

        // Skip if derivedFrom
        has_derived := false
        for attr in enum_elem.attribs {
            if attr.key == "derivedFrom" {
                has_derived = true
                break
            }
        }

        if !has_derived {
            for v in enum_elem.value {
                if child_id, is_id := v.(xml.Element_ID); is_id {
                    child := doc.elements[child_id]
                    if child.ident == "enumeratedValue" {
                        if enum_val, ok := parse_enumerated_value(doc, child_id); ok {
                            append(&field.values, enum_val)
                        }
                    }
                }
            }
        }
    }

    return field, true
}

parse_enumerated_value :: proc(doc: ^xml.Document, enum_id: xml.Element_ID) -> (Enumerated_Value, bool) {
    enum_val: Enumerated_Value

    // Name
    if name_id, ok := xml.find_child_by_ident(doc, enum_id, "name"); ok {
        enum_val.name = get_element_text(doc, name_id)
    }

    // Description
    if desc_id, ok := xml.find_child_by_ident(doc, enum_id, "description"); ok {
        enum_val.description = get_element_text(doc, desc_id)
    }

    // Value
    if value_id, ok := xml.find_child_by_ident(doc, enum_id, "value"); ok {
        value_str := get_element_text(doc, value_id)
        enum_val.value = u32(parse_addr_value(value_str))
    }

    return enum_val, true
}

// Helper: get text content from an element
get_element_text :: proc(doc: ^xml.Document, elem_id: xml.Element_ID) -> string {
    elem := doc.elements[elem_id]
    if len(elem.value) > 0 {
        if text, is_string := elem.value[0].(string); is_string {
            return strings.clone(text)
        }
    }
    return ""
}

// Parse hex (0x...) or decimal number
parse_addr_value :: proc(s: string) -> u64 {
    s := strings.trim_space(s)

    if strings.has_prefix(s, "0x") || strings.has_prefix(s, "0X") {
        val, ok := strconv.parse_u64_of_base(s[2:], 16)
        if ok {
            return val
        }
    }

    val, ok := strconv.parse_u64(s)
    if ok {
        return val
    }

    return 0
}

// Collect interrupts from a peripheral
collect_interrupts :: proc(doc: ^xml.Document, periph_id: xml.Element_ID, interrupts: ^[dynamic]Interrupt) {
    periph := doc.elements[periph_id]

    // Iterate through all children looking for <interrupt> elements
    for v in periph.value {
        if child_id, is_id := v.(xml.Element_ID); is_id {
            child := doc.elements[child_id]
            if child.ident == "interrupt" {
                interrupt: Interrupt

                // Parse interrupt fields
                if name_id, ok := xml.find_child_by_ident(doc, child_id, "name"); ok {
                    interrupt.name = get_element_text(doc, name_id)
                }

                if desc_id, ok := xml.find_child_by_ident(doc, child_id, "description"); ok {
                    interrupt.description = get_element_text(doc, desc_id)
                }

                if value_id, ok := xml.find_child_by_ident(doc, child_id, "value"); ok {
                    value_str := get_element_text(doc, value_id)
                    interrupt.value = u32(parse_addr_value(value_str))
                }

                // Check for duplicates (same interrupt name)
                found := false
                for existing in interrupts {
                    if existing.name == interrupt.name {
                        found = true
                        break
                    }
                }

                if !found && interrupt.name != "" {
                    append(interrupts, interrupt)
                }
            }
        }
    }
}

// Parse CPU information from <cpu> element
parse_cpu_info :: proc(doc: ^xml.Document, cpu_id: xml.Element_ID) -> CPU_Info {
    cpu: CPU_Info
    cpu_elem := doc.elements[cpu_id]

    for v in cpu_elem.value {
        if child_id, is_id := v.(xml.Element_ID); is_id {
            child := doc.elements[child_id]

            switch child.ident {
            case "name":
                cpu.name = strings.clone(get_element_text(doc, child_id))
            case "revision":
                cpu.revision = strings.clone(get_element_text(doc, child_id))
            case "fpuPresent":
                text := get_element_text(doc, child_id)
                cpu.fpu = (text == "true" || text == "1")
            case "mpuPresent":
                text := get_element_text(doc, child_id)
                cpu.mpu = (text == "true" || text == "1")
            }
        }
    }

    return cpu
}

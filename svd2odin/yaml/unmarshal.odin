// YAML Unmarshalling - Convert YAML AST to Odin data structures
package yaml

import "core:mem"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "base:runtime"

Unmarshal_Error :: enum {
	None,
	Invalid_Data,
	Invalid_Parameter,
	Non_Pointer_Parameter,
	Type_Mismatch,
	Unsupported_Type,
	Parse_Error,
}

// Unmarshal YAML into an Odin data structure
unmarshal :: proc(data: string, ptr: ^$T, allocator := context.allocator) -> Unmarshal_Error {
	return unmarshal_any(data, ptr, allocator)
}

// Unmarshal YAML into any pointer
unmarshal_any :: proc(data: string, v: any, allocator := context.allocator) -> Unmarshal_Error {
	v := v
	if v == nil || v.id == nil {
		return .Invalid_Parameter
	}

	v = reflect.any_base(v)
	ti := type_info_of(v.id)
	if !reflect.is_pointer(ti) || ti.id == rawptr {
		return .Non_Pointer_Parameter
	}

	// Parse YAML to AST
	doc, ok := parse_string(data, "", allocator)
	if !ok {
		return .Parse_Error
	}
	defer destroy_node(doc)

	// Unmarshal from AST to target
	target := any{(^rawptr)(v.data)^, ti.variant.(reflect.Type_Info_Pointer).elem.id}
	if v.data == nil {
		return .Invalid_Parameter
	}

	context.allocator = allocator
	return unmarshal_node(doc.root, target, allocator)
}

// Unmarshal a YAML node into an any value
@(private)
unmarshal_node :: proc(node: ^Node, val: any, allocator: mem.Allocator) -> Unmarshal_Error {
	if node == nil {
		return .Invalid_Data
	}

	val := reflect.any_core(val)
	ti := type_info_of(val.id)

	switch n in node.derived {
	case ^Scalar:
		return unmarshal_scalar(n, val, ti, allocator)

	case ^Mapping:
		return unmarshal_mapping(n, val, ti, allocator)

	case ^Sequence:
		return unmarshal_sequence(n, val, ti, allocator)

	case ^Document:
		return .Invalid_Data
	}

	return .Invalid_Data
}

// Unmarshal a scalar value
@(private)
unmarshal_scalar :: proc(scalar: ^Scalar, val: any, ti: ^reflect.Type_Info, allocator: mem.Allocator) -> Unmarshal_Error {
	val := reflect.any_core(val)

	#partial switch info in ti.variant {
	case reflect.Type_Info_String:
		s := strings.clone(scalar.value, allocator)
		(^string)(val.data)^ = s
		return .None

	case reflect.Type_Info_Integer:
		i, ok := strconv.parse_i64(scalar.value)
		if !ok {
			return .Type_Mismatch
		}
		if !assign_int(val, i) {
			return .Type_Mismatch
		}
		return .None

	case reflect.Type_Info_Float:
		f, ok := strconv.parse_f64(scalar.value)
		if !ok {
			return .Type_Mismatch
		}
		if !assign_float(val, f) {
			return .Type_Mismatch
		}
		return .None

	case reflect.Type_Info_Boolean:
		b: bool
		switch scalar.value {
		case "true", "True", "TRUE", "yes", "Yes", "YES":
			b = true
		case "false", "False", "FALSE", "no", "No", "NO":
			b = false
		case:
			return .Type_Mismatch
		}
		if !assign_bool(val, b) {
			return .Type_Mismatch
		}
		return .None
	}

	return .Unsupported_Type
}

// Unmarshal a mapping (key-value pairs)
@(private)
unmarshal_mapping :: proc(mapping: ^Mapping, val: any, ti: ^reflect.Type_Info, allocator: mem.Allocator) -> Unmarshal_Error {
	val := reflect.any_core(val)

	#partial switch &info in ti.variant {
	case reflect.Type_Info_Struct:
		return unmarshal_mapping_to_struct(mapping, val, &info, allocator)

	case reflect.Type_Info_Map:
		return unmarshal_mapping_to_map(mapping, val, &info, allocator)
	}

	return .Unsupported_Type
}

// Unmarshal mapping to struct
@(private)
unmarshal_mapping_to_struct :: proc(mapping: ^Mapping, val: any, info: ^reflect.Type_Info_Struct, allocator: mem.Allocator) -> Unmarshal_Error {
	for pair in mapping.pairs {
		key := pair.key.value

		// Find matching struct field
		for field_idx in 0..<info.field_count {
			field_name := info.names[field_idx]
			if field_name == key {
				field_type := info.types[field_idx]
				field_offset := info.offsets[field_idx]
				field_any := any{rawptr(uintptr(val.data) + field_offset), field_type.id}

				if err := unmarshal_node(pair.value, field_any, allocator); err != .None {
					return err
				}
				break
			}
		}

		// Optionally: warn about unknown fields
		// For now, we silently ignore them (like strictyaml)
	}

	return .None
}

// Unmarshal mapping to map
@(private)
unmarshal_mapping_to_map :: proc(mapping: ^Mapping, val: any, info: ^reflect.Type_Info_Map, allocator: mem.Allocator) -> Unmarshal_Error {
	// For now, only support map[string]string
	// Full map support would require more runtime reflection
	key_type := info.key
	value_type := info.value

	if key_type.id != string || value_type.id != string {
		return .Unsupported_Type
	}

	// Create map[string]string
	m := make(map[string]string, len(mapping.pairs), allocator)

	for pair in mapping.pairs {
		key_str := strings.clone(pair.key.value, allocator)

		// Get value as scalar
		if scalar, ok := pair.value.derived.(^Scalar); ok {
			value_str := strings.clone(scalar.value, allocator)
			m[key_str] = value_str
		} else {
			return .Type_Mismatch
		}
	}

	// Assign map to destination
	(^map[string]string)(val.data)^ = m

	return .None
}

// Unmarshal a sequence (array/list)
@(private)
unmarshal_sequence :: proc(seq: ^Sequence, val: any, ti: ^reflect.Type_Info, allocator: mem.Allocator) -> Unmarshal_Error {
	val := reflect.any_core(val)

	#partial switch &info in ti.variant {
	case reflect.Type_Info_Dynamic_Array:
		return unmarshal_sequence_to_dynamic_array(seq, val, &info, allocator)

	case reflect.Type_Info_Slice:
		return unmarshal_sequence_to_slice(seq, val, &info, allocator)

	case reflect.Type_Info_Array:
		return unmarshal_sequence_to_array(seq, val, &info, allocator)
	}

	return .Unsupported_Type
}

// Unmarshal sequence to dynamic array
@(private)
unmarshal_sequence_to_dynamic_array :: proc(seq: ^Sequence, val: any, info: ^reflect.Type_Info_Dynamic_Array, allocator: mem.Allocator) -> Unmarshal_Error {
	elem_type := info.elem

	// Allocate backing array
	data, err := mem.alloc(elem_type.size * len(seq.items), elem_type.align, allocator)
	if err != nil {
		return .Invalid_Data
	}

	// Unmarshal each element
	for item, i in seq.items {
		elem_offset := uintptr(data) + uintptr(i * elem_type.size)
		elem_any := any{rawptr(elem_offset), elem_type.id}

		if err := unmarshal_node(item.value, elem_any, allocator); err != .None {
			return err
		}
	}

	// Set dynamic array
	raw := (^runtime.Raw_Dynamic_Array)(val.data)
	raw.data = data
	raw.len = len(seq.items)
	raw.cap = len(seq.items)
	raw.allocator = allocator

	return .None
}

// Unmarshal sequence to slice
@(private)
unmarshal_sequence_to_slice :: proc(seq: ^Sequence, val: any, info: ^reflect.Type_Info_Slice, allocator: mem.Allocator) -> Unmarshal_Error {
	elem_type := info.elem

	// Allocate slice
	slice_data, err := mem.alloc(elem_type.size * len(seq.items), elem_type.align, allocator)
	if err != nil {
		return .Invalid_Data
	}

	for item, i in seq.items {
		elem_offset := uintptr(slice_data) + uintptr(i * elem_type.size)
		elem_any := any{rawptr(elem_offset), elem_type.id}

		if unmarshal_err := unmarshal_node(item.value, elem_any, allocator); unmarshal_err != .None {
			return unmarshal_err
		}
	}

	// Set slice
	slice_ptr := (^runtime.Raw_Slice)(val.data)
	slice_ptr.data = slice_data
	slice_ptr.len = len(seq.items)

	return .None
}

// Unmarshal sequence to fixed array
@(private)
unmarshal_sequence_to_array :: proc(seq: ^Sequence, val: any, info: ^reflect.Type_Info_Array, allocator: mem.Allocator) -> Unmarshal_Error {
	elem_type := info.elem

	if len(seq.items) != info.count {
		return .Type_Mismatch
	}

	for item, i in seq.items {
		elem_offset := uintptr(val.data) + uintptr(i * elem_type.size)
		elem_any := any{rawptr(elem_offset), elem_type.id}

		if err := unmarshal_node(item.value, elem_any, allocator); err != .None {
			return err
		}
	}

	return .None
}

// Helper functions (similar to JSON)

@(private)
assign_bool :: proc(val: any, b: bool) -> bool {
	v := reflect.any_core(val)
	switch &dst in v {
	case bool: dst = bool(b)
	case b8:   dst = b8  (b)
	case b16:  dst = b16 (b)
	case b32:  dst = b32 (b)
	case b64:  dst = b64 (b)
	case: return false
	}
	return true
}

@(private)
assign_int :: proc(val: any, i: $T) -> bool {
	v := reflect.any_core(val)
	switch &dst in v {
	case i8:      dst = i8     (i)
	case i16:     dst = i16    (i)
	case i32:     dst = i32    (i)
	case i64:     dst = i64    (i)
	case i128:    dst = i128   (i)
	case u8:      dst = u8     (i)
	case u16:     dst = u16    (i)
	case u32:     dst = u32    (i)
	case u64:     dst = u64    (i)
	case u128:    dst = u128   (i)
	case int:     dst = int    (i)
	case uint:    dst = uint   (i)
	case uintptr: dst = uintptr(i)
	case: return false
	}
	return true
}

@(private)
assign_float :: proc(val: any, f: $T) -> bool {
	v := reflect.any_core(val)
	switch &dst in v {
	case f16:     dst = f16  (f)
	case f32:     dst = f32  (f)
	case f64:     dst = f64  (f)
	case: return false
	}
	return true
}

// YAML Marshalling - Convert Odin data structures to YAML
package yaml

import "core:fmt"
import "core:io"
import "core:mem"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "base:runtime"

Marshal_Options :: struct {
	indent:        int,  // Number of spaces per indent level (default: 2)
	current_depth: int,  // Internal: current indentation depth
}

Marshal_Data_Error :: enum {
	None,
	Unsupported_Type,
}

Marshal_Error :: union #shared_nil {
	Marshal_Data_Error,
	io.Error,
}

// Marshal Odin value to YAML string
marshal :: proc(v: any, opt := Marshal_Options{indent = 2}, allocator := context.allocator) -> (data: string, err: Marshal_Error) {
	b := strings.builder_make(allocator)
	defer if err != nil {
		strings.builder_destroy(&b)
	}

	opt := opt
	if opt.indent == 0 {
		opt.indent = 2
	}

	marshal_to_builder(&b, v, &opt) or_return

	return strings.to_string(b), nil
}

// Marshal to a string builder
marshal_to_builder :: proc(b: ^strings.Builder, v: any, opt: ^Marshal_Options) -> Marshal_Error {
	return marshal_to_writer(strings.to_writer(b), v, opt)
}

// Get YAML field name from struct tag or use field name
yaml_name_from_tag_value :: proc(value: string) -> (yaml_name, extra: string) {
	yaml_name = value
	if comma_index := strings.index_byte(yaml_name, ','); comma_index >= 0 {
		yaml_name = yaml_name[:comma_index]
		extra = value[1 + comma_index:]
	}
	return
}

// Main marshalling function
marshal_to_writer :: proc(w: io.Writer, v: any, opt: ^Marshal_Options) -> (err: Marshal_Error) {
	if v == nil {
		io.write_string(w, "null") or_return
		return nil
	}

	ti := runtime.type_info_base(type_info_of(v.id))
	a := any{v.data, ti.id}

	#partial switch &info in ti.variant {
	case runtime.Type_Info_Integer:
		return marshal_int(w, a, &info)

	case runtime.Type_Info_Float:
		return marshal_float(w, a, &info)

	case runtime.Type_Info_Boolean:
		return marshal_bool(w, a)

	case runtime.Type_Info_String:
		return marshal_string(w, a, &info)

	case runtime.Type_Info_Struct:
		return marshal_struct(w, a, &info, opt)

	case runtime.Type_Info_Dynamic_Array, runtime.Type_Info_Slice, runtime.Type_Info_Array:
		return marshal_array(w, a, ti, opt)

	case runtime.Type_Info_Map:
		return marshal_map(w, a, &info, opt)
	}

	return .Unsupported_Type
}

// Marshal boolean
@(private)
marshal_bool :: proc(w: io.Writer, v: any) -> Marshal_Error {
	b: bool
	switch val in v {
	case bool: b = val
	case b8:   b = bool(val)
	case b16:  b = bool(val)
	case b32:  b = bool(val)
	case b64:  b = bool(val)
	case: return .Unsupported_Type
	}

	io.write_string(w, "true" if b else "false") or_return
	return nil
}

// Marshal integer
@(private)
marshal_int :: proc(w: io.Writer, v: any, info: ^runtime.Type_Info_Integer) -> Marshal_Error {
	buf: [128]byte
	s: string

	switch i in v {
	case i8:      s = strconv.write_int(buf[:], i64(i), 10)
	case i16:     s = strconv.write_int(buf[:], i64(i), 10)
	case i32:     s = strconv.write_int(buf[:], i64(i), 10)
	case i64:     s = strconv.write_int(buf[:], i, 10)
	case int:     s = strconv.write_int(buf[:], i64(i), 10)
	case u8:      s = strconv.write_int(buf[:], i64(i), 10)
	case u16:     s = strconv.write_int(buf[:], i64(i), 10)
	case u32:     s = strconv.write_int(buf[:], i64(i), 10)
	case u64:     s = strconv.write_int(buf[:], i64(i), 10)
	case uint:    s = strconv.write_int(buf[:], i64(i), 10)
	case uintptr: s = strconv.write_int(buf[:], i64(i), 10)
	case: return .Unsupported_Type
	}

	io.write_string(w, s) or_return
	return nil
}

// Marshal float
@(private)
marshal_float :: proc(w: io.Writer, v: any, info: ^runtime.Type_Info_Float) -> Marshal_Error {
	buf: [128]byte
	s: string

	switch f in v {
	case f32: s = strconv.write_float(buf[:], f64(f), 'f', 6, 32)
	case f64: s = strconv.write_float(buf[:], f, 'f', 6, 64)
	case: return .Unsupported_Type
	}

	io.write_string(w, s) or_return
	return nil
}

// Marshal string
@(private)
marshal_string :: proc(w: io.Writer, v: any, info: ^runtime.Type_Info_String) -> Marshal_Error {
	s: string
	switch str in v {
	case string:  s = str
	case cstring: s = string(str)
	case: return .Unsupported_Type
	}

	// Check if string needs quoting (contains special chars)
	needs_quotes := false
	for ch in s {
		if ch == ':' || ch == '#' || ch == '\n' || ch == '\r' {
			needs_quotes = true
			break
		}
	}

	if needs_quotes || len(s) == 0 {
		io.write_quoted_string(w, s) or_return
	} else {
		io.write_string(w, s) or_return
	}

	return nil
}

// Write indentation
@(private)
write_indent :: proc(w: io.Writer, opt: ^Marshal_Options) -> Marshal_Error {
	for i in 0..<(opt.current_depth * opt.indent) {
		io.write_byte(w, ' ') or_return
	}
	return nil
}

// Marshal struct
@(private)
marshal_struct :: proc(w: io.Writer, v: any, info: ^runtime.Type_Info_Struct, opt: ^Marshal_Options) -> Marshal_Error {
	for field_idx in 0..<info.field_count {
		field_name := info.names[field_idx]
		field_type := info.types[field_idx]
		field_offset := info.offsets[field_idx]
		field_any := any{rawptr(uintptr(v.data) + field_offset), field_type.id}

		// Get YAML name from tag or use field name
		yaml_name := field_name
		if tag_value := reflect.struct_tag_get(reflect.Struct_Tag(info.tags[field_idx]), "yaml"); tag_value != "" {
			yaml_name, _ = yaml_name_from_tag_value(tag_value)
		}

		// Skip if tag is "-"
		if yaml_name == "-" {
			continue
		}

		// Write field
		if field_idx > 0 {
			io.write_byte(w, '\n') or_return
		}
		write_indent(w, opt) or_return
		io.write_string(w, yaml_name) or_return
		io.write_string(w, ": ") or_return

		// Check if field value is complex (struct, array, map)
		field_ti := runtime.type_info_base(field_type)
		is_complex := false

		#partial switch _ in field_ti.variant {
		case runtime.Type_Info_Struct, runtime.Type_Info_Dynamic_Array,
		     runtime.Type_Info_Slice, runtime.Type_Info_Array, runtime.Type_Info_Map:
			is_complex = true
		}

		if is_complex {
			io.write_byte(w, '\n') or_return
			opt.current_depth += 1
			marshal_to_writer(w, field_any, opt) or_return
			opt.current_depth -= 1
		} else {
			marshal_to_writer(w, field_any, opt) or_return
		}
	}

	return nil
}

// Marshal array/slice
@(private)
marshal_array :: proc(w: io.Writer, v: any, ti: ^runtime.Type_Info, opt: ^Marshal_Options) -> Marshal_Error {
	len_val: int
	elem_size: int
	elem_type: ^runtime.Type_Info
	data_ptr: rawptr

	#partial switch info in ti.variant {
	case runtime.Type_Info_Dynamic_Array:
		raw := (^runtime.Raw_Dynamic_Array)(v.data)
		len_val = raw.len
		elem_size = info.elem.size
		elem_type = info.elem
		data_ptr = raw.data

	case runtime.Type_Info_Slice:
		raw := (^runtime.Raw_Slice)(v.data)
		len_val = raw.len
		elem_size = info.elem.size
		elem_type = info.elem
		data_ptr = raw.data

	case runtime.Type_Info_Array:
		len_val = info.count
		elem_size = info.elem.size
		elem_type = info.elem
		data_ptr = v.data

	case:
		return .Unsupported_Type
	}

	for i in 0..<len_val {
		if i > 0 {
			io.write_byte(w, '\n') or_return
		}

		write_indent(w, opt) or_return
		io.write_string(w, "- ") or_return

		elem_offset := uintptr(data_ptr) + uintptr(i * elem_size)
		elem_any := any{rawptr(elem_offset), elem_type.id}

		// Check if element is complex
		elem_ti := runtime.type_info_base(elem_type)
		is_complex := false

		#partial switch _ in elem_ti.variant {
		case runtime.Type_Info_Struct:
			is_complex = true
		}

		if is_complex {
			io.write_byte(w, '\n') or_return
			opt.current_depth += 1
			marshal_to_writer(w, elem_any, opt) or_return
			opt.current_depth -= 1
		} else {
			marshal_to_writer(w, elem_any, opt) or_return
		}
	}

	return nil
}

// Marshal map (only map[string]string for now)
@(private)
marshal_map :: proc(w: io.Writer, v: any, info: ^runtime.Type_Info_Map, opt: ^Marshal_Options) -> Marshal_Error {
	// For now, only support map[string]string
	if info.key.id != string || info.value.id != string {
		return .Unsupported_Type
	}

	m := (^map[string]string)(v.data)^

	idx := 0
	for key, value in m {
		if idx > 0 {
			io.write_byte(w, '\n') or_return
		}
		write_indent(w, opt) or_return
		io.write_string(w, key) or_return
		io.write_string(w, ": ") or_return
		io.write_string(w, value) or_return
		idx += 1
	}

	return nil
}

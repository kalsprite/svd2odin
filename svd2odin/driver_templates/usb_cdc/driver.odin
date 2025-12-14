package usb_cdc

import "base:intrinsics"
import device "../../cmsis/device"
import hal "../../hal"

// USB CDC (Communications Device Class) Driver
// Implements ACM (Abstract Control Model) for virtual COM port
//
// Usage:
//   usb_cdc.init()
//   usb_cdc.print("Hello USB!\r\n")

// USB Descriptor Types
DESC_DEVICE         :: 0x01
DESC_CONFIGURATION  :: 0x02
DESC_STRING         :: 0x03
DESC_INTERFACE      :: 0x04
DESC_ENDPOINT       :: 0x05
DESC_CS_INTERFACE   :: 0x24

// USB Request Types
REQ_GET_STATUS      :: 0x00
REQ_CLEAR_FEATURE   :: 0x01
REQ_SET_FEATURE     :: 0x03
REQ_SET_ADDRESS     :: 0x05
REQ_GET_DESCRIPTOR  :: 0x06
REQ_SET_DESCRIPTOR  :: 0x07
REQ_GET_CONFIG      :: 0x08
REQ_SET_CONFIG      :: 0x09
REQ_GET_INTERFACE   :: 0x0A
REQ_SET_INTERFACE   :: 0x0B

// CDC Class Requests
CDC_SET_LINE_CODING         :: 0x20
CDC_GET_LINE_CODING         :: 0x21
CDC_SET_CONTROL_LINE_STATE  :: 0x22

// Endpoint configuration
EP0_MAX_SIZE :: 64
CDC_CMD_EP   :: 0x82
CDC_OUT_EP   :: 0x01
CDC_IN_EP    :: 0x81
CDC_DATA_SIZE :: 64

// USB Device Descriptor
device_descriptor := [18]u8{
    18, DESC_DEVICE, 0x00, 0x02, 0x02, 0x02, 0x00, EP0_MAX_SIZE,
    0x83, 0x04, 0x40, 0x57, 0x00, 0x02, 1, 2, 3, 1,
}

// Configuration Descriptor
config_descriptor := [67]u8{
    9, DESC_CONFIGURATION, 67, 0, 2, 1, 0, 0xC0, 50,
    9, DESC_INTERFACE, 0, 0, 1, 0x02, 0x02, 0x01, 0,
    5, DESC_CS_INTERFACE, 0x00, 0x10, 0x01,
    5, DESC_CS_INTERFACE, 0x01, 0x00, 1,
    4, DESC_CS_INTERFACE, 0x02, 0x02,
    5, DESC_CS_INTERFACE, 0x06, 0, 1,
    7, DESC_ENDPOINT, CDC_CMD_EP, 0x03, 8, 0, 0x10,
    9, DESC_INTERFACE, 1, 0, 2, 0x0A, 0x00, 0x00, 0,
    7, DESC_ENDPOINT, CDC_OUT_EP, 0x02, CDC_DATA_SIZE, 0, 0,
    7, DESC_ENDPOINT, CDC_IN_EP, 0x02, CDC_DATA_SIZE, 0, 0,
}

string_langid := [4]u8{4, DESC_STRING, 0x09, 0x04}
string_manufacturer := [14]u8{14, DESC_STRING, 'O', 0, 'd', 0, 'i', 0, 'n', 0, 'U', 0, 'S', 0}
string_product := [22]u8{22, DESC_STRING, 'B', 0, 'l', 0, 'a', 0, 'c', 0, 'k', 0, 'P', 0, 'i', 0, 'l', 0, 'l', 0, ' ', 0}
string_serial := [26]u8{26, DESC_STRING, '0', 0, '0', 0, '0', 0, '0', 0, '0', 0, '0', 0, '0', 0, '0', 0, '0', 0, '0', 0, '0', 0, '1', 0}

line_coding := [7]u8{0x00, 0xC2, 0x01, 0x00, 0x00, 0x00, 0x08}

// State
usb_configured := false
usb_address: u8 = 0
set_address_pending := false
tx_busy := false

// Buffers
TX_BUFFER_SIZE :: 512
tx_buffer: [TX_BUFFER_SIZE]u8
tx_head: u32 = 0
tx_tail: u32 = 0

RX_BUFFER_SIZE :: 256
rx_buffer: [RX_BUFFER_SIZE]u8
rx_head: u32 = 0
rx_tail: u32 = 0

ep0_buffer: [EP0_MAX_SIZE]u8
ep0_tx_ptr: [^]u8 = nil
ep0_tx_remaining: u32 = 0

// Register addresses
OTG_FS_BASE      :: 0x50000000
OTG_FS_GLOBAL    :: OTG_FS_BASE + 0x000
OTG_FS_DEVICE    :: OTG_FS_BASE + 0x800
OTG_FS_IN_EP     :: OTG_FS_BASE + 0x900
OTG_FS_OUT_EP    :: OTG_FS_BASE + 0xB00
OTG_FS_FIFO_BASE :: OTG_FS_BASE + 0x1000
OTG_FS_FIFO_SIZE :: 0x1000

reg_read :: proc "c" (addr: u32) -> u32 {
    return intrinsics.volatile_load(cast(^u32)uintptr(addr))
}

reg_write :: proc "c" (addr: u32, val: u32) {
    intrinsics.volatile_store(cast(^u32)uintptr(addr), val)
}

reg_set :: proc "c" (addr: u32, bits: u32) {
    reg_write(addr, reg_read(addr) | bits)
}

reg_clear :: proc "c" (addr: u32, bits: u32) {
    reg_write(addr, reg_read(addr) & ~bits)
}

fifo_write :: proc "c" (ep: u32, data: []u8) {
    fifo_addr := OTG_FS_FIFO_BASE + ep * OTG_FS_FIFO_SIZE
    words := (u32(len(data)) + 3) / 4
    for i: u32 = 0; i < words; i += 1 {
        word: u32 = 0
        for j: u32 = 0; j < 4; j += 1 {
            idx := i * 4 + j
            if idx < u32(len(data)) {
                word |= u32(data[idx]) << (j * 8)
            }
        }
        reg_write(fifo_addr, word)
    }
}

fifo_read :: proc "c" (data: []u8, count: u32) {
    fifo_addr: u32 = OTG_FS_FIFO_BASE
    words := (count + 3) / 4
    for i: u32 = 0; i < words; i += 1 {
        word := reg_read(fifo_addr)
        for j: u32 = 0; j < 4; j += 1 {
            idx := i * 4 + j
            if idx < count && idx < u32(len(data)) {
                data[idx] = u8((word >> (j * 8)) & 0xFF)
            }
        }
    }
}

init :: proc "c" () {
    hal.reg_modify(&device.RCC.AHB2ENR, .Set, 1 << 7)
    hal.reg_modify(&device.RCC.AHB1ENR, .Set, 1 << 0)

    pa := device.GPIOA
    hal.reg_modify(&pa.MODER, .Clear, (0x3 << 22) | (0x3 << 24))
    hal.reg_modify(&pa.MODER, .Set, (0x2 << 22) | (0x2 << 24))
    hal.reg_modify(&pa.OSPEEDR, .Set, (0x3 << 22) | (0x3 << 24))
    hal.reg_modify(&pa.AFRH, .Clear, (0xF << 12) | (0xF << 16))
    hal.reg_modify(&pa.AFRH, .Set, (10 << 12) | (10 << 16))

    for i := 0; i < 10000; i += 1 {}

    for (reg_read(OTG_FS_GLOBAL + 0x10) & (1 << 31)) == 0 {}
    reg_set(OTG_FS_GLOBAL + 0x10, 1 << 0)
    for (reg_read(OTG_FS_GLOBAL + 0x10) & (1 << 0)) != 0 {}
    for (reg_read(OTG_FS_GLOBAL + 0x10) & (1 << 31)) == 0 {}

    reg_clear(OTG_FS_GLOBAL + 0x0C, 1 << 29)
    reg_set(OTG_FS_GLOBAL + 0x0C, 1 << 30)
    for i := 0; i < 100000; i += 1 {}

    reg_write(OTG_FS_GLOBAL + 0x38, (1 << 16) | (1 << 21))
    reg_write(OTG_FS_DEVICE + 0x00, 0x03)

    reg_write(OTG_FS_GLOBAL + 0x18, (1 << 4) | (1 << 12) | (1 << 13) | (1 << 18) | (1 << 19))

    reg_write(OTG_FS_GLOBAL + 0x24, 128)
    reg_write(OTG_FS_GLOBAL + 0x28, (64 << 16) | 128)
    reg_write(OTG_FS_GLOBAL + 0x104, (128 << 16) | 192)

    reg_write(OTG_FS_GLOBAL + 0x10, (0x10 << 6) | (1 << 5))
    for (reg_read(OTG_FS_GLOBAL + 0x10) & (1 << 5)) != 0 {}
    reg_write(OTG_FS_GLOBAL + 0x10, 1 << 4)
    for (reg_read(OTG_FS_GLOBAL + 0x10) & (1 << 4)) != 0 {}

    reg_write(OTG_FS_OUT_EP + 0x00, (1 << 31) | (1 << 26) | (3 << 18) | EP0_MAX_SIZE)
    reg_set(OTG_FS_GLOBAL + 0x08, 1 << 0)
    reg_clear(OTG_FS_DEVICE + 0x04, 1 << 1)

    nvic_enable(67)
}

nvic_enable :: proc "c" (irq: u32) {
    reg := cast(^u32)uintptr(0xE000E100 + (irq >> 5) * 4)
    intrinsics.volatile_store(reg, u32(1) << (irq & 0x1F))
}

@(export)
OTG_FS_IRQHandler :: proc "c" () {
    gintsts := reg_read(OTG_FS_GLOBAL + 0x14)

    if (gintsts & (1 << 12)) != 0 {
        handle_reset()
        reg_write(OTG_FS_GLOBAL + 0x14, 1 << 12)
    }
    if (gintsts & (1 << 13)) != 0 {
        reg_write(OTG_FS_IN_EP + 0x00, EP0_MAX_SIZE)
        reg_write(OTG_FS_GLOBAL + 0x14, 1 << 13)
    }
    if (gintsts & (1 << 4)) != 0 {
        handle_rxflvl()
    }
    if (gintsts & (1 << 18)) != 0 {
        handle_iepint()
    }
    if (gintsts & (1 << 19)) != 0 {
        handle_oepint()
    }
}

handle_reset :: proc "c" () {
    usb_configured = false
    usb_address = 0
    tx_head = 0
    tx_tail = 0
    rx_head = 0
    rx_tail = 0
    reg_clear(OTG_FS_DEVICE + 0x00, 0x7F << 4)
    reg_write(OTG_FS_DEVICE + 0x08, 0xFFFFFFFF)
    reg_write(OTG_FS_DEVICE + 0x0C, 0xFFFFFFFF)
    ep0_out_prepare()
}

ep0_out_prepare :: proc "c" () {
    reg_write(OTG_FS_OUT_EP + 0x10, (1 << 29) | (1 << 19) | EP0_MAX_SIZE)
    reg_write(OTG_FS_OUT_EP + 0x00, (1 << 31) | (1 << 26))
}

handle_rxflvl :: proc "c" () {
    grxstsp := reg_read(OTG_FS_GLOBAL + 0x20)
    ep := grxstsp & 0xF
    pktsts := (grxstsp >> 17) & 0xF
    bcnt := (grxstsp >> 4) & 0x7FF

    if ep == 0 {
        if pktsts == 0x06 {
            fifo_read(ep0_buffer[:], bcnt)
            handle_setup()
        } else if pktsts == 0x02 {
            fifo_read(ep0_buffer[:], bcnt)
            handle_ep0_out(bcnt)
        } else if pktsts == 0x04 {
            ep0_out_prepare()
        }
    } else if ep == 1 && pktsts == 0x02 {
        for i: u32 = 0; i < bcnt; i += 1 {
            if i % 4 == 0 {
                word := reg_read(OTG_FS_FIFO_BASE)
                for j: u32 = 0; j < 4 && (i + j) < bcnt; j += 1 {
                    next := (rx_head + 1) % RX_BUFFER_SIZE
                    if next != rx_tail {
                        rx_buffer[rx_head] = u8((word >> (j * 8)) & 0xFF)
                        rx_head = next
                    }
                }
            }
        }
        reg_write(OTG_FS_OUT_EP + 0x20 + 0x10, (1 << 19) | CDC_DATA_SIZE)
        reg_write(OTG_FS_OUT_EP + 0x20, (1 << 31) | (1 << 26))
    }
}

handle_iepint :: proc "c" () {
    daint := reg_read(OTG_FS_DEVICE + 0x18)

    if (daint & (1 << 0)) != 0 {
        diepint := reg_read(OTG_FS_IN_EP + 0x08)
        if (diepint & (1 << 0)) != 0 {
            reg_write(OTG_FS_IN_EP + 0x08, 1 << 0)
            if set_address_pending {
                reg_clear(OTG_FS_DEVICE + 0x00, 0x7F << 4)
                reg_set(OTG_FS_DEVICE + 0x00, u32(usb_address) << 4)
                set_address_pending = false
            }
            if ep0_tx_remaining > 0 {
                ep0_tx_continue()
            } else {
                ep0_out_prepare()
            }
        }
    }

    if (daint & (1 << 1)) != 0 {
        diepint := reg_read(OTG_FS_IN_EP + 0x20 + 0x08)
        if (diepint & (1 << 0)) != 0 {
            reg_write(OTG_FS_IN_EP + 0x20 + 0x08, 1 << 0)
            tx_busy = false
            try_tx()
        }
    }
}

handle_oepint :: proc "c" () {
    daint := reg_read(OTG_FS_DEVICE + 0x18)
    if (daint & (1 << 16)) != 0 {
        doepint := reg_read(OTG_FS_OUT_EP + 0x08)
        reg_write(OTG_FS_OUT_EP + 0x08, doepint)
    }
    if (daint & (1 << 17)) != 0 {
        doepint := reg_read(OTG_FS_OUT_EP + 0x20 + 0x08)
        reg_write(OTG_FS_OUT_EP + 0x20 + 0x08, doepint)
    }
}

handle_setup :: proc "c" () {
    bmRequestType := ep0_buffer[0]
    bRequest := ep0_buffer[1]
    wValue := u16(ep0_buffer[2]) | (u16(ep0_buffer[3]) << 8)
    wLength := u16(ep0_buffer[6]) | (u16(ep0_buffer[7]) << 8)

    if (bmRequestType & 0x60) == 0x00 {
        switch bRequest {
        case REQ_GET_DESCRIPTOR:
            handle_get_descriptor(wValue, wLength)
        case REQ_SET_ADDRESS:
            usb_address = u8(wValue & 0x7F)
            set_address_pending = true
            ep0_tx_zlp()
        case REQ_SET_CONFIG:
            if wValue == 1 {
                configure_endpoints()
                usb_configured = true
            }
            ep0_tx_zlp()
        case REQ_GET_CONFIG:
            ep0_buffer[0] = 1 if usb_configured else 0
            ep0_tx_data(ep0_buffer[:1])
        case:
            ep0_stall()
        }
    } else if (bmRequestType & 0x60) == 0x20 {
        switch bRequest {
        case CDC_SET_LINE_CODING:
            ep0_out_prepare()
        case CDC_GET_LINE_CODING:
            ep0_tx_data(line_coding[:])
        case CDC_SET_CONTROL_LINE_STATE:
            ep0_tx_zlp()
        case:
            ep0_tx_zlp()
        }
    } else {
        ep0_stall()
    }
}

handle_ep0_out :: proc "c" (count: u32) {
    if count == 7 {
        for i: u32 = 0; i < 7; i += 1 {
            line_coding[i] = ep0_buffer[i]
        }
    }
    ep0_tx_zlp()
}

handle_get_descriptor :: proc "c" (wValue: u16, wLength: u16) {
    desc_type := u8(wValue >> 8)
    desc_index := u8(wValue & 0xFF)

    switch desc_type {
    case DESC_DEVICE:
        ep0_tx_data(device_descriptor[:])
    case DESC_CONFIGURATION:
        l := min(u32(wLength), u32(len(config_descriptor)))
        ep0_tx_data(config_descriptor[:l])
    case DESC_STRING:
        switch desc_index {
        case 0: ep0_tx_data(string_langid[:])
        case 1: ep0_tx_data(string_manufacturer[:])
        case 2: ep0_tx_data(string_product[:])
        case 3: ep0_tx_data(string_serial[:])
        case: ep0_stall()
        }
    case:
        ep0_stall()
    }
}

ep0_tx_data :: proc "c" (data: []u8) {
    ep0_tx_ptr = raw_data(data)
    ep0_tx_remaining = u32(len(data))
    ep0_tx_continue()
}

ep0_tx_continue :: proc "c" () {
    l := min(ep0_tx_remaining, EP0_MAX_SIZE)
    reg_write(OTG_FS_IN_EP + 0x10, (1 << 19) | l)
    reg_write(OTG_FS_IN_EP + 0x00, (1 << 31) | (1 << 26))
    fifo_write(0, ep0_tx_ptr[:l])
    ep0_tx_ptr = ep0_tx_ptr[l:]
    ep0_tx_remaining -= l
}

ep0_tx_zlp :: proc "c" () {
    reg_write(OTG_FS_IN_EP + 0x10, 1 << 19)
    reg_write(OTG_FS_IN_EP + 0x00, (1 << 31) | (1 << 26))
}

ep0_stall :: proc "c" () {
    reg_set(OTG_FS_IN_EP + 0x00, 1 << 21)
    reg_set(OTG_FS_OUT_EP + 0x00, 1 << 21)
}

configure_endpoints :: proc "c" () {
    reg_write(OTG_FS_IN_EP + 0x20, (1 << 15) | (2 << 18) | (1 << 22) | CDC_DATA_SIZE)
    reg_set(OTG_FS_DEVICE + 0x0C, (1 << 1))
    reg_write(OTG_FS_OUT_EP + 0x20, (1 << 31) | (1 << 26) | (1 << 15) | (2 << 18) | CDC_DATA_SIZE)
    reg_write(OTG_FS_OUT_EP + 0x20 + 0x10, (1 << 19) | CDC_DATA_SIZE)
    reg_set(OTG_FS_DEVICE + 0x08, (1 << 1))
    reg_write(OTG_FS_IN_EP + 0x40, (1 << 15) | (3 << 18) | (2 << 22) | 8)
}

try_tx :: proc "c" () {
    if tx_busy || !usb_configured { return }
    if tx_head == tx_tail { return }

    count: u32 = 0
    temp_buf: [CDC_DATA_SIZE]u8
    t := tx_tail
    for count < CDC_DATA_SIZE && t != tx_head {
        temp_buf[count] = tx_buffer[t]
        count += 1
        t = (t + 1) % TX_BUFFER_SIZE
    }
    if count == 0 { return }

    tx_tail = t
    tx_busy = true

    reg_write(OTG_FS_IN_EP + 0x20 + 0x10, (1 << 19) | count)
    reg_write(OTG_FS_IN_EP + 0x20, (1 << 31) | (1 << 26) | (1 << 15) | (2 << 18) | (1 << 22) | CDC_DATA_SIZE)
    fifo_write(1, temp_buf[:count])
}

// Public API
is_ready :: proc "c" () -> bool { return usb_configured }

write :: proc "c" (data: []u8) -> u32 {
    written: u32 = 0
    for i := 0; i < len(data); i += 1 {
        next := (tx_head + 1) % TX_BUFFER_SIZE
        if next == tx_tail { break }
        tx_buffer[tx_head] = data[i]
        tx_head = next
        written += 1
    }
    try_tx()
    return written
}

read :: proc "c" (data: []u8) -> u32 {
    count: u32 = 0
    for count < u32(len(data)) && rx_tail != rx_head {
        data[count] = rx_buffer[rx_tail]
        rx_tail = (rx_tail + 1) % RX_BUFFER_SIZE
        count += 1
    }
    return count
}

available :: proc "c" () -> u32 {
    if rx_head >= rx_tail { return rx_head - rx_tail }
    return RX_BUFFER_SIZE - rx_tail + rx_head
}

print :: proc "c" (str: string) { write(transmute([]u8)str) }
println :: proc "c" (str: string) { print(str); print("\r\n") }
putc :: proc "c" (ch: u8) { buf := [1]u8{ch}; write(buf[:]) }
flush :: proc "c" () { for tx_head != tx_tail || tx_busy { try_tx() } }

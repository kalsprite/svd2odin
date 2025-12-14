// ARM low-power and barrier instructions for PWR driver
.syntax unified
.cpu cortex-m4
.thumb

// Wait For Interrupt - enters low-power state until interrupt
.global wfi
.type wfi, %function
wfi:
    wfi
    bx lr

// Wait For Event - enters low-power state until event
.global wfe
.type wfe, %function
wfe:
    wfe
    bx lr

// Send Event - wakes cores waiting in WFE
.global sev
.type sev, %function
sev:
    sev
    bx lr

// Data Synchronization Barrier - ensures all memory accesses complete
.global dsb
.type dsb, %function
dsb:
    dsb
    bx lr

// Instruction Synchronization Barrier - flushes pipeline
.global isb
.type isb, %function
isb:
    isb
    bx lr

// Stub implementations for missing libc functions
// These are needed for linking but should never be called in freestanding environment

void abort(void) {
    // In freestanding environment, just infinite loop
    while(1);
}

// TLS (Thread Local Storage) support - not needed for bare metal
void *__aeabi_read_tp(void) {
    return (void*)0;
}

// Note: disable_interrupts, enable_interrupts, and wait_for_interrupt
// are now implemented in interrupt_helpers.s for better code generation

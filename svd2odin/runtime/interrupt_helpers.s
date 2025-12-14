/* ARM Cortex-M interrupt control helpers */
.syntax unified
.cpu cortex-m4
.thumb

.text

/* Disable all interrupts (set PRIMASK) */
.global disable_interrupts
.type disable_interrupts, %function
disable_interrupts:
    cpsid i
    bx lr
.size disable_interrupts, .-disable_interrupts

/* Enable all interrupts (clear PRIMASK) */
.global enable_interrupts
.type enable_interrupts, %function
enable_interrupts:
    cpsie i
    bx lr
.size enable_interrupts, .-enable_interrupts

/* Wait for interrupt (low power mode) */
.global wait_for_interrupt
.type wait_for_interrupt, %function
wait_for_interrupt:
    wfi
    bx lr
.size wait_for_interrupt, .-wait_for_interrupt

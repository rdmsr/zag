.altmacro
.code64

.section .text
.globl gdt_load
gdt_load:
    lgdt (%rdi)

    /* Set ss, ds and es to data segment */
    mov $0x30, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss

    /* Save return address */
    pop %rdi

    /* Push CS so the CPU will pop it off with retfq */
    mov $0x28, %rax
    push %rax
    push %rdi
    lretq


.globl idt_load
idt_load:
    lidt (%rdi)
    ret

.macro pushall
    push %rax
    push %rbx
    push %rcx
    push %rdx
    push %rbp
    push %rdi
    push %rsi
    push %r8
    push %r9
    push %r10
    push %r11
    push %r12
    push %r13
    push %r14
    push %r15
.endm

.macro popall
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %r11
    pop %r10
    pop %r9
    pop %r8
    pop %rsi
    pop %rdi
    pop %rbp
    pop %rdx
    pop %rcx
    pop %rbx
    pop %rax
.endm

.extern isr_handler_main
isr_handler:
    cld
    pushall
    mov %rsp, %rdi
    call isr_handler_main
    popall
    cli
    add $16, %rsp
    iretq

.macro INTERRUPT_NOERR num
    .globl isr\num
    isr\num :
        pushq $0
        pushq $\num
        jmp isr_handler
.endm

.macro INTERRUPT_ERR num
    .globl isr\num
    isr\num :
        pushq $\num
        jmp isr_handler
.endm

INTERRUPT_NOERR 0
INTERRUPT_NOERR 1
INTERRUPT_NOERR 2
INTERRUPT_NOERR 3
INTERRUPT_NOERR 4
INTERRUPT_NOERR 5
INTERRUPT_NOERR 6
INTERRUPT_NOERR 7
INTERRUPT_ERR   8
INTERRUPT_NOERR 9
INTERRUPT_ERR   10
INTERRUPT_ERR   11
INTERRUPT_ERR   12
INTERRUPT_ERR   13
INTERRUPT_ERR   14
INTERRUPT_NOERR 15
INTERRUPT_NOERR 16
INTERRUPT_ERR   17
INTERRUPT_NOERR 18
INTERRUPT_NOERR 19
INTERRUPT_NOERR 20
INTERRUPT_NOERR 21
INTERRUPT_NOERR 22
INTERRUPT_NOERR 23
INTERRUPT_NOERR 24
INTERRUPT_NOERR 25
INTERRUPT_NOERR 26
INTERRUPT_NOERR 27
INTERRUPT_NOERR 28
INTERRUPT_NOERR 29
INTERRUPT_ERR   30
INTERRUPT_NOERR 31

.rept 224
INTERRUPT_NOERR %32+\+
.endr

.global __interrupt_vectors
__interrupt_vectors:
.rept 256
.quad isr\()\+
.endr

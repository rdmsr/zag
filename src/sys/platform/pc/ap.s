.global AP_TRAMPOLINE_START
.global AP_TRAMPOLINE_END
.global AP_TRAMPOLINE_DATA
.section .rodata

AP_TRAMPOLINE_START:
.set BASE, 0x8000
.set DATA, BASE + (AP_TRAMPOLINE_DATA - AP_TRAMPOLINE_START)

.extern cpu_id_to_apic_id
.extern ap_start_stack
.extern cpu_offsets
.extern cpu_self_offset

.code16
.startup:
    cli
    cld
    xor %ax, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %fs
    mov %ax, %gs
    mov %ax, %ss
    lgdt (BASE + (gdt - AP_TRAMPOLINE_START))
    mov %cr0, %eax
    or $0x1, %eax
    mov %eax, %cr0
    ljmp $0x8, $(BASE + (.pmode - AP_TRAMPOLINE_START))

.code32
.pmode:
    mov $0x18, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %fs
    mov %ax, %gs
    mov %ax, %ss
    mov (DATA + 8), %eax   /* page table */
    mov %eax, %cr3
    mov %cr4, %eax
    or $(1 << 5), %eax
    mov %eax, %cr4
    mov $0xC0000080, %ecx
    rdmsr
    /* NXE and LME */
    or $(1 << 8) | (1 << 11), %eax
    wrmsr
    mov %cr0, %eax
    or $(1 << 31) | (1 << 16) | (1 << 5) | 1, %eax
    mov %eax, %cr0
    ljmp $0x10, $(BASE + (.lmode - AP_TRAMPOLINE_START))
.code64
.lmode:
    mov $0x18, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    xor %ax, %ax
    mov %ax, %fs
    mov %ax, %gs
    mov (DATA + 16), %rax   /* idtr */
    lidt (%rax)

    /* Get xAPIC base address from data */
    mov (DATA + 24), %rax
    test %rax, %rax
    jz 1f                   /* apic_base = 0 means x2apic */

    /* xAPIC mode */
    /* Set xAPIC base to the BSP xAPIC address */
    mov %rax, %rdx
    shr $32, %rdx           /* high 32 bits of address */
    /* %eax already has the lower 32 bits */
    or $0x800, %eax        /* Global enable */
    mov $0x1B, %ecx         /* IA32_APIC_BASE MSR */
    wrmsr

    /* Read APIC ID from memory mapped IO */
    mov (DATA + 32), %rax
    mov 0x20(%rax), %edx
    shr $24, %edx
    jmp 2f

1:
    /* x2APIC mode */
    mov $0x802, %ecx        /* x2APIC ID MSR */
    rdmsr
    mov %eax, %edx          /* x2APIC ID is in EAX */
2:
    /* edx = our APIC ID */
    /* Scan cpu_id_to_apic_id[] to find our cpu_id */
    xor %rcx, %rcx
    mov $cpu_id_to_apic_id, %rbx
3:
    mov (%rbx, %rcx, 4), %eax
    cmp %eax, %edx
    je 4f
    inc %rcx
    jmp 3b
4:
    /* rcx = our cpu_id, save it */
    mov %rcx, %r15
    /* Set GS base to offsets[cpu_id] */
    mov $cpu_offsets, %rdx
    mov (%rdx), %rdx /* get the actual array (since it's a [*]) */
    mov (%rdx, %r15, 8), %rax   /* offsets[cpu_id] */
    mov %rax, %rdx
    shr $32, %rdx
    mov $0xC0000101, %ecx       /* MSR_GS_BASE */
    wrmsr

    mov %rax, %gs:cpu_self_offset

    /* Load stack from start_stack */
    mov %gs:ap_start_stack, %rsp

    /* Call entry with cpu_id as argument */
    mov %r15, %rdi
    mov (DATA), %rax        /* entry */
    mfence
    jmp *%rax
.align 4
gdt:
    .word gdt_end - gdt_start - 1
    .long BASE + (gdt_start - AP_TRAMPOLINE_START)
gdt_start:
    .quad 0 /* null segment */
    .quad 0x00cf9b000000ffff /* 0x08: 32-bit code segment */
    .quad 0x00af9b000000ffff /* 0x10: 64-bit code segment */
    .quad 0x00cf93000000ffff /* 0x18: Data segment */
gdt_end:
AP_TRAMPOLINE_DATA:
    .quad 0 /* entry  +0  */
    .quad 0 /* cr3    +8  */
    .quad 0 /* idtr   +16 */
    .quad 0 /* xapic  +24 */
    .quad 0 /* xapic_virt +32 */
AP_TRAMPOLINE_END:

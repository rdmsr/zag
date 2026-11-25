/*
 * PVH entry point.
 * PVH starts us in pmode and passes the start info structure in %ebx.
*/

/*
 * we're gonna load our own page tables anyway. Only map 64 MiB.
 */
.set N_KPAGES, 32
.set KERNEL_PHYS, 0x200000
.set KERNEL_BASE, 0xffffffffe0000000
.set KERNEL_OFF,  KERNEL_BASE - KERNEL_PHYS

#define V2P(A) A - KERNEL_OFF

.section .note.Xen, "a", @note
.balign 4

    /* XEN_ELFNOTE_PHYS32_ENTRY = 18 */
    .long 4
    .long 4
    .long 18

    .asciz "Xen"
    .balign 4

    .long V2P(pvh_entry32)
    .balign 4

.extern pvh_entry
.section .pvh.text, "ax", @progbits
.code32
.global pvh_entry32
pvh_entry32:
    cli
    cld
    mov  %ebx, %ebp /* keep hvm_start_info */
    mov  $V2P(pvh_stack_top), %esp

    mov  $V2P(pdpt), %eax  ; or $3, %eax
    mov  %eax, V2P(pml4)
    mov  %eax, V2P(pml4) + 511*8
    mov  $V2P(pd_lo), %eax ; or $3, %eax
    mov  %eax, V2P(pdpt)                
    mov  $V2P(pd_hi), %eax ; or $3, %eax
    mov  %eax, V2P(pdpt) + 511*8

    /* identity map the first GiB */
    xor  %ecx, %ecx
1:  mov  %ecx, %eax
    shl  $21, %eax
    or   $0x83, %eax
    mov  %eax, V2P(pd_lo)(,%ecx,8)
    inc  %ecx
    cmp  $512, %ecx
    jb   1b

    /* higher half mapping, PD_hi[256+i] = KERNEL_PHYS + i * 2MiB */
    xor  %ecx, %ecx
2:  mov  %ecx, %eax
    shl  $21, %eax
    add  $(KERNEL_PHYS + 0x83), %eax
    mov  %eax, V2P(pd_hi) + 256*8(,%ecx,8)
    inc  %ecx
    cmp  $N_KPAGES, %ecx
    jb   2b

    mov  %cr4, %eax
	or $(1<<5), %eax
	mov %eax, %cr4       /* PAE */

    mov  $V2P(pml4), %eax
	mov %eax, %cr3

    mov  $0xC0000080, %ecx
	rdmsr   
    or   $((1<<8) | (1<<11)), %eax    /* LME | NXE */
    wrmsr
    lgdt V2P(pvh_gdt_ptr)
    mov  %cr0, %eax
	or $(1<<31), %eax
	mov %eax, %cr0       /* PG */
    ljmp $0x08, $V2P(pvh_long)

.code64
pvh_long:
    mov  $0x10, %eax
    mov  %eax, %ds
	mov %eax, %es
	mov %eax, %ss
    mov  %ebp, %edi /* pass start info */
	movabs $pvh_stack_top, %rsp
	xor  %eax, %eax
    push %rax 
    movabs $pvh_entry, %rax
    jmp  *%rax

.section .pvh.data, "aw", @progbits
.balign 8
pvh_gdt:
    .quad 0
    .quad 0x00209A0000000000
    .quad 0x0000920000000000
pvh_gdt_ptr:
    .word . - pvh_gdt - 1
    .long V2P(pvh_gdt)

.section .pvh.bss, "aw", @nobits
.balign 4096
pml4: .skip 4096
pdpt: .skip 4096
pd_lo: .skip 4096
pd_hi: .skip 4096
.skip 16384
pvh_stack_top:

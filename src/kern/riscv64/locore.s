.section .text
.global riscv_context_switch
.type riscv_context_switch, @function
riscv_context_switch:
    sd sp, 0(a0)
    sd ra, 8(a0)
    sd s0, 16(a0)
    sd s1, 24(a0)
    sd s2, 32(a0)
    sd s3, 40(a0)
    sd s4, 48(a0)
    sd s5, 56(a0)
    sd s6, 64(a0)
    sd s7, 72(a0)
    sd s8, 80(a0)
    sd s9, 88(a0)
    sd s10, 96(a0)
    sd s11, 104(a0)
    mv a0, a1
    j riscv_context_resume

.global riscv_context_load
.type riscv_context_load, @function
riscv_context_load:
    mv a2, zero
    mv a3, zero
    j riscv_context_resume

riscv_context_resume:
    ld sp, 0(a0)
    ld ra, 8(a0)
    ld s0, 16(a0)
    ld s1, 24(a0)
    ld s2, 32(a0)
    ld s3, 40(a0)
    ld s4, 48(a0)
    ld s5, 56(a0)
    ld s6, 64(a0)
    ld s7, 72(a0)
    ld s8, 80(a0)
    ld s9, 88(a0)
    ld s10, 96(a0)
    ld s11, 104(a0)
    beqz a3, 1f
    sb zero, 0(a3)
1:
    beqz a2, 2f
    sb zero, 0(a2)
2:
    ret

.global riscv_context_switch_cont
.type riscv_context_switch_cont, @function
riscv_context_switch_cont:
    mv s2, a2
    mv s3, a3
    mv s4, a1
    ld a0, 112(a0)
    ld sp, 0(s4)
    call riscv_free_old_stack
    mv a0, s4
    mv a2, s2
    mv a3, s3
    j riscv_context_resume

.global thread_start
.type thread_start, @function
thread_start:
    mv a0, s1
    mv a1, s2
    tail riscv_thread_entry

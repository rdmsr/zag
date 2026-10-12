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


.section .text
.global riscv_trap
.type riscv_trap, @function
riscv_trap:
    addi sp, sp, -272
    sd ra, 0(sp)
    sd gp, 8(sp)
    sd tp, 16(sp)
    sd t0, 24(sp)
    sd t1, 32(sp)
    sd t2, 40(sp)
    sd s0, 48(sp)
    sd s1, 56(sp)
    sd a0, 64(sp)
    sd a1, 72(sp)
    sd a2, 80(sp)
    sd a3, 88(sp)
    sd a4, 96(sp)
    sd a5, 104(sp)
    sd a6, 112(sp)
    sd a7, 120(sp)
    sd s2, 128(sp)
    sd s3, 136(sp)
    sd s4, 144(sp)
    sd s5, 152(sp)
    sd s6, 160(sp)
    sd s7, 168(sp)
    sd s8, 176(sp)
    sd s9, 184(sp)
    sd s10, 192(sp)
    sd s11, 200(sp)
    sd t3, 208(sp)
    sd t4, 216(sp)
    sd t5, 224(sp)
    sd t6, 232(sp)
    csrr t0, sepc
    sd t0, 240(sp)
    csrr a0, scause
    mv a1, t0
    call riscv_trap_handler
    ld t0, 240(sp)
    csrw sepc, t0
    ld ra, 0(sp)
    ld gp, 8(sp)
    ld tp, 16(sp)
    ld t0, 24(sp)
    ld t1, 32(sp)
    ld t2, 40(sp)
    ld s0, 48(sp)
    ld s1, 56(sp)
    ld a0, 64(sp)
    ld a1, 72(sp)
    ld a2, 80(sp)
    ld a3, 88(sp)
    ld a4, 96(sp)
    ld a5, 104(sp)
    ld a6, 112(sp)
    ld a7, 120(sp)
    ld s2, 128(sp)
    ld s3, 136(sp)
    ld s4, 144(sp)
    ld s5, 152(sp)
    ld s6, 160(sp)
    ld s7, 168(sp)
    ld s8, 176(sp)
    ld s9, 184(sp)
    ld s10, 192(sp)
    ld s11, 200(sp)
    ld t3, 208(sp)
    ld t4, 216(sp)
    ld t5, 224(sp)
    ld t6, 232(sp)
    addi sp, sp, 272
    sret

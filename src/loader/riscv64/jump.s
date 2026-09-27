.section .text
.global jump_to_kernel
.type jump_to_kernel, @function
jump_to_kernel:
    mv t0, a1
    mv sp, a2
    jr t0

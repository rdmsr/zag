.section .rodata
.balign 4096
.global kernel_image_start
.global kernel_image_end
kernel_image_start:
    .incbin "kernel.bin"
kernel_image_end:

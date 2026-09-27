.globl jump_to_kernel
jump_to_kernel:
	mov %rdx, %rsp              /* Load new stack */
	xorq %rbp, %rbp 			/* Call chain ends here */
	jmp *%rsi					/* rdi = loader_info */

.globl jump_to_kernel
jump_to_kernel:
	mov %rsi, %rsp
	push $0
	jmp *%rdx					; rdi = loader_info

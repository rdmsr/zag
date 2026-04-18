SECTIONS {
    .data.percpu : {
        __percpu_start = .;
        *(.data.percpu)
        __percpu_end = .;
    }

.percpu_init_array : {
    __init_array_percpu_start = .;
    KEEP(*(.percpu_init_array))
    __init_array_percpu_end = .;
	}

} INSERT AFTER .data;

PROVIDE(text_start_addr = ADDR(.text));
PROVIDE(text_end_addr   = ADDR(.text) + SIZEOF(.text));

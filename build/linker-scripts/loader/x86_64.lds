OUTPUT_FORMAT(elf64-x86-64)
ENTRY(loader_entry)

PHDRS
{
    pvh PT_LOAD;
    note PT_NOTE;
    limine_requests PT_LOAD;
    text PT_LOAD;
    rodata PT_LOAD;
    data PT_LOAD;
}

SECTIONS
{
    . = 0xffffffffe0000000;
	kernel_start_addr = .;

    .pvh.text : AT(0x200000) {
        *(.pvh.text)
    } :pvh

    .note.Xen : {
        KEEP(*(.note.Xen))
    } :pvh :note

    .pvh.data : {
        . = ALIGN(4096);
        *(.pvh.data)       
        *(.pvh.bss)
    } :pvh

    . = ALIGN(CONSTANT(MAXPAGESIZE));

    .limine_requests : {
        KEEP(*(.limine_requests_start))
        KEEP(*(.limine_requests))
        KEEP(*(.limine_requests_end))
    } :limine_requests

    . = ALIGN(CONSTANT(MAXPAGESIZE));

	text_start_addr = .;

    .text : {
        *(.text .text.*)
    } :text

    . = ALIGN(CONSTANT(MAXPAGESIZE));

	text_end_addr = .;

	rodata_start_addr = .;

    .rodata : {
        *(.rodata .rodata.*)
    } :rodata

    .note.gnu.build-id : {
        *(.note.gnu.build-id)
    } :rodata


    . = ALIGN(CONSTANT(MAXPAGESIZE));

	rodata_end_addr = .;
	data_start_addr = .;

    .data : {
        *(.data .data.*)
    } :data


    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    } :data

    . = ALIGN(CONSTANT(MAXPAGESIZE));

	data_end_addr = .;
	kernel_end_addr = .;

    /DISCARD/ : {
        *(.eh_frame*)
        *(.note .note.*)
    }
}

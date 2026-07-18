const r = @import("root");
const std = @import("std");

const Entry = r.BootInfo.MemMap.Entry;
const stack_size = 1024 * 16; // should be enough

extern fn jump_to_kernel(loader_info: usize, stack: usize, entry: usize) void;

fn load_kernel(kernel: *anyopaque) usize {
    const elf: *std.elf.Elf64.Ehdr = @ptrCast(@alignCast(kernel));
    const ident = elf.ident;

    if (!std.mem.eql(u8, ident[0..4], std.elf.MAGIC)) {
        @panic("loader: Invalid ELF magic");
    }

    if (ident[std.elf.EI_CLASS] != std.elf.ELFCLASS64) {
        @panic("loader: invalid ELF class");
    }

    if (elf.type != std.elf.ET.EXEC) {
        @panic("loader: invalid ELF type (expected ET_EXEC)");
    }

    var phdr: *std.elf.Elf64.Phdr = @ptrFromInt(@intFromPtr(kernel) + elf.phoff);

    for (0..elf.phnum) |_| {
        switch (phdr.type) {
            .LOAD => {
                const as_pages = std.mem.alignForward(usize, phdr.memsz, r.page_size);
                const npages = as_pages / r.page_size;
                var filesz_rem = phdr.filesz;

                for (0..npages) |i| {
                    const pa = r.mem.alloc_page();
                    const addr = phdr.vaddr + i * r.page_size;

                    r.mem.pagemap.map_page(addr, pa, .{
                        // Gotta have RW access for loading it.
                        .read = true,
                        .write = true,
                    });

                    const file_remaining = @min(filesz_rem, r.page_size);

                    const off: [*]u8 = @ptrFromInt(@intFromPtr(kernel) + phdr.offset + i * r.page_size);
                    const source = off[0..file_remaining];
                    const va: [*]u8 = @ptrFromInt(addr);
                    const dest = va[0..file_remaining];

                    filesz_rem -= file_remaining;

                    // Copy the file data.
                    @memcpy(dest, source);

                    if (filesz_rem == 0) {
                        const zeroes = phdr.memsz - phdr.filesz;

                        // Fill the rest of memsz with 0.
                        @memset(va[0..zeroes], 0);
                    }

                    // Now update the page permissions to their true value.
                    r.mem.pagemap.map_page(addr, pa, .{
                        .execute = phdr.flags.X,
                        .read = phdr.flags.R,
                        .write = phdr.flags.W,
                        .global = true,
                    });

                    r.arch.flush(addr);
                }
            },
            else => {},
        }

        phdr = @ptrFromInt(@intFromPtr(phdr) + elf.phentsize);
    }

    return elf.entry;
}

fn cmp_entries(ctx: void, a: Entry, b: Entry) bool {
    _ = ctx;
    return a.base < b.base;
}

pub fn loader_main(kernel: *anyopaque) void {
    r.arch.init();
    r.mem.init();
    const entry = load_kernel(kernel);
    const stack = r.mem.alloc(stack_size);

    const memmap = &r.loader_info.memory_map;

    // Finally, sort the memory map once we're done allocating everything.
    std.mem.sort(Entry, memmap.entries[0..memmap.entry_count], {}, cmp_entries);

    jump_to_kernel(@intFromPtr(&r.loader_info), stack + stack_size, entry);
}

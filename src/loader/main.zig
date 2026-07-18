const r = @import("root");
const std = @import("std");

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
                r.mem.pagemap.map_range_allocating(phdr.vaddr, std.mem.alignForward(usize, phdr.memsz, r.page_size), .{
                    .execute = phdr.flags.X,
                    // Gotta have RW access for loading it.
                    // XXX remap the pages and set protections properly...
                    .read = true,
                    .write = true,
                    .global = true,
                });

                const off: [*]u8 = @ptrFromInt(@intFromPtr(kernel) + phdr.offset);
                const source = off[0..phdr.filesz];
                const va: [*]u8 = @ptrFromInt(phdr.vaddr);
                const dest = va[0..phdr.filesz];

                // Copy the file data.
                @memcpy(dest, source);

                // Fill the rest of memsz with 0.
                const zero_dest = va[phdr.filesz..phdr.memsz];
                @memset(zero_dest, 0);
            },
            else => {},
        }

        phdr = @ptrFromInt(@intFromPtr(phdr) + elf.phentsize);
    }

    return elf.entry;
}

extern fn jump_to_kernel(loader_info: usize, stack: usize, entry: usize) void;

pub fn loader_main(kernel: *anyopaque) void {
    r.mem.init();
    const entry = load_kernel(kernel);
    const stack = r.mem.alloc(1024 * 16);

    std.log.info("jumping to {x} with stack {x}", .{ entry, stack });
    jump_to_kernel(@intFromPtr(&r.loader_info), stack + (1024 * 16), entry);
}

//! PVH boot protocol support.

const amd64 = @import("arch");
const r = @import("root");
const std = @import("std");

const StartInfo = extern struct {
    magic: u32,
    version: u32,
    flags: u32,
    nr_modules: u32,
    modlist_paddr: u64,
    cmdline_paddr: u64,
    rsdp_paddr: u64,
    memmap_paddr: u64,
    memmap_entries: u32,
    reserved: u32,
};

const MemmapEntry = extern struct {
    addr: u64,
    size: u64,
    type: enum(u32) {
        Ram = 1,
        Reserved = 2,
        Acpi = 3,
        Nvs = 4,
        Unusable = 5,
        Disabled = 6,
        Pmem = 7,
    },
    reserved: u32,
};

fn p2v(pa: usize) usize {
    return pa;
}

const phys_base = 0x200000;

fn get_image_layout() r.ImageLayout {
    return .{
        .physical_base = phys_base,
        .virtual_base = 0xffffffffe0000000,
    };
}

extern var stub_start_addr: u8;
extern var stub_end_addr: u8;

fn build_mmap(info: *StartInfo) void {
    const stub_size = @intFromPtr(&stub_end_addr) -
        @intFromPtr(&stub_start_addr);

    const stub_start = phys_base;
    const stub_end = phys_base + stub_size;

    const entries: [*]MemmapEntry = @ptrFromInt(p2v(info.memmap_paddr));
    const cnt = info.memmap_entries;

    for (0..cnt) |i| {
        var entry = entries[i];

        if (entry.addr == 0) {
            // Let's reserve the first MiB.
            entry.addr += 1024 * 1024;
            entry.size -|= 1024 * 1024;
        }

        if (entry.size == 0) continue;

        const ty: r.BootInfo.MemMap.Entry.Type = switch (entry.type) {
            .Nvs => .AcpiNvs,
            .Acpi => .AcpiReclaimable,
            .Ram => .Free,
            else => .Reserved,
        };

        const e_start: u64 = entry.addr;
        const e_end: u64 = entry.addr + entry.size;

        if (e_start < stub_end and stub_start < e_end) {
            // Entry overlaps the stub. Split it.
            if (e_start < stub_start)
                r.mem.add_entry(e_start, stub_start - e_start, ty);
            if (stub_end < e_end)
                r.mem.add_entry(stub_end, e_end - stub_end, ty);
        } else {
            r.mem.add_entry(e_start, entry.size, ty);
        }
    }
}

fn sum_ok(p: [*]const u8, len: usize) bool {
    var s: u8 = 0;
    for (p[0..len]) |b| s +%= b;
    return s == 0;
}

fn scan_rsdp(start: usize, end: usize) ?usize {
    var addr = start;
    while (addr + 36 <= end) : (addr += 16) {
        const p: [*]const u8 = @ptrFromInt(p2v(addr));
        if (!std.mem.eql(u8, p[0..8], "RSD PTR ")) continue;
        if (!sum_ok(p, 20)) continue;

        if (p[15] >= 2) {
            // revision >= 2.
            const len = std.mem.readInt(u32, p[20..24], .little);
            if (len < 36 or len > 4096 or !sum_ok(p, len)) continue;
        }
        return addr;
    }
    return null;
}

fn find_rsdp() ?usize {
    const seg: *align(1) const u16 = @ptrFromInt(p2v(0x40E));
    const ebda = @as(usize, seg.*) << 4;
    if (ebda >= 0x80000 and ebda < 0xA0000) {
        if (scan_rsdp(ebda, ebda + 1024)) |a| return a;
    }
    return scan_rsdp(0xE0000, 0x100000);
}

var cmdline: [256]u8 = undefined;

export fn pvh_entry(info: *StartInfo) callconv(.c) void {
    r.loader_info.rsdp = if (info.rsdp_paddr != 0)
        info.rsdp_paddr
    else
        find_rsdp() orelse 0;

    if (info.cmdline_paddr != 0) {
        const c: [*:0]u8 = @ptrFromInt(p2v(info.cmdline_paddr));
        const span = std.mem.span(c);
        if (span.len > cmdline.len) {
            r.loader_info.cmdline = "TOOLONG";
        } else {
            std.mem.copyForwards(u8, &cmdline, span);
            r.loader_info.cmdline = cmdline[0..span.len];
        }
    } else {
        r.loader_info.cmdline = &.{};
    }

    r.loader_info.framebuffer = null;

    r.impl = .{
        .get_image_layout = get_image_layout,
        .p2v = p2v,
    };

    build_mmap(info);

    r.main();
}

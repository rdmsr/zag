const b = @import("base");
const ksyms = @import("ksyms");
const limine = @import("limine.zig");

const pl = b.pl;
const ke = b.ke;
const ki = ke.private;

pub const std_options = b.std_options;
pub const panic = b.panic;

const std = @import("std");

var boot_info: pl.BootInfo = undefined;

pub export var limine_base_revision: [3]u64 linksection(".limine_requests") = limine.base_revision(6);

pub export var framebuffer_request: limine.FramebufferRequest linksection(".limine_requests") = .{
    .id = limine.framebuffer_request_id,
    .revision = 0,
    .response = null,
};

pub export var limine_requests_start_marker: [4]u64 linksection(".limine_requests_start") = limine.requests_start_marker;
pub export var limine_requests_end_marker: [2]u64 linksection(".limine_requests_end") = limine.requests_end_marker;

pub export var memmap_request: limine.MemmapRequest linksection(".limine_requests") = .{
    .id = limine.memmap_request_id,
    .revision = 0,
    .response = null,
};

pub export var rsdp_request: limine.RsdpRequest linksection(".limine_requests") = .{
    .id = limine.rsdp_request_id,
    .revision = 0,
    .response = null,
};

pub export var cmdline_request: limine.CmdlineRequest linksection(".limine_requests") = .{
    .id = limine.cmdline_request_id,
    .revision = 0,
    .response = null,
};

pub export var kernel_address_request: limine.KernelAddressRequest linksection(".limine_requests") = .{
    .id = limine.kernel_address_request_id,
    .revision = 0,
    .response = null,
};

fn build_memory_map() void {
    const memmap_response = memmap_request.response orelse {
        @panic("Limine memmap request failed");
    };

    boot_info.memory_map.entry_count = memmap_response.entry_count;
    const entries = memmap_response.entries orelse {
        @panic("Limine memmap response has no entries");
    };

    for (0..memmap_response.entry_count) |i| {
        const entry = entries[i];
        boot_info.memory_map.entries[i] = .{
            .base = entry.base,
            .size = entry.length,
            .type = switch (entry.type) {
                .Usable => pl.BootInfo.MemMap.Entry.Type.Free,
                .AcpiReclaimable => pl.BootInfo.MemMap.Entry.Type.AcpiReclaimable,
                .AcpiNvs => pl.BootInfo.MemMap.Entry.Type.AcpiNvs,
                .BootloaderReclaimable => pl.BootInfo.MemMap.Entry.Type.LoaderReclaimable,
                .KernelAndModules => pl.BootInfo.MemMap.Entry.Type.Kernel,
                else => pl.BootInfo.MemMap.Entry.Type.Reserved,
            },
        };
    }
}

export fn kmain() callconv(.c) void {
    boot_info.cmdline = if (cmdline_request.response) |cmdline_response| {
        cmdline_response.cmdline;
    } else {
        null;
    };

    boot_info.rsdp = if (rsdp_request.response) |rsdp_response| {
        rsdp_response.rsdp;
    } else {
        0;
    };

    boot_info.kernel_address = if (kernel_address_request.response) |ka_response| {
        .{
            .physical_base = ka_response.kernel_address.physical_base,
            .virtual_base = ka_response.kernel_address.virtual_base,
        };
    } else {
        .{ .physical_base = 0, .virtual_base = 0 };
    };

    build_memory_map();

    var cpus: [1]*ke.Cpu = .{&ke.private.bootstrap_cpu};

    ke.ncpus = 1;
    ke.cpus = &cpus;

    ki.init(&boot_info);
}

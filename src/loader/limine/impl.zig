const std = @import("std");
const limine = @import("limine.zig");
const r = @import("root");

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

pub export var hhdm_request: limine.HHDMRequest linksection(".limine_requests") = .{
    .id = limine.hhdm_request_id,
    .revision = 0,
    .response = null,
};

pub export var kernel_request: limine.ExecutableAddressRequest linksection(".limine_requests") = .{
    .id = limine.executable_address_request_id,
    .revision = 0,
    .response = null,
};

pub export var module_request: limine.ModuleRequest linksection(".limine_requests") = .{
    .id = limine.module_request_id,
    .revision = 0,
    .response = null,
};

pub fn p2v(pa: usize) usize {
    return hhdm_request.response.?.offset + pa;
}

pub fn get_image_layout() r.ImageLayout {
    const resp = kernel_request.response.?;

    return .{
        .physical_base = resp.physical_base,
        .virtual_base = resp.virtual_base,
    };
}

export fn loader_entry() callconv(.c) void {
    const mmap = memmap_request.response.?;

    for (0..mmap.entry_count) |i| {
        const entry = mmap.entries.?[i];

        r.mem.add_entry(entry.base, entry.length, switch (entry.type) {
            .AcpiNvs => .AcpiNvs,
            .BootloaderReclaimable => .LoaderReclaimable,
            .AcpiReclaimable => .AcpiReclaimable,
            .Usable => .Free,
            else => .Reserved,
        });
    }

    if (framebuffer_request.response) |resp| {
        const fb = resp.framebuffers[0];

        r.loader_info.framebuffer = .{
            .address = @intFromPtr(fb.address),
            .height = @intCast(fb.height),
            .width = @intCast(fb.width),
            .bpp = @intCast(fb.bpp),
            .pitch = @intCast(fb.pitch),
        };
    }

    if (rsdp_request.response) |resp| {
        r.loader_info.rsdp = @intFromPtr(resp.rsdp);
    }

    var kernel: ?*anyopaque = null;

    if (module_request.response) |resp| {
        const modules = resp.modules.?[0..resp.module_count];

        for (modules) |mod| {
            const str = std.mem.span(mod.string);

            if (std.mem.eql(u8, str, "kernel")) {
                kernel = mod.address;
            }
        }
    }

    if (kernel == null) {
        @panic("loader: kernel not found");
    }

    r.main(kernel.?);
}

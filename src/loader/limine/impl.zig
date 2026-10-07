//! Limine-specific code for the loader.

const std = @import("std");
const limine = @import("limine.zig");
const r = @import("root");

pub export var base_revision: [3]u64 linksection(".limine_requests") =
    limine.base_revision(6);

pub export var framebuffer_request linksection(".limine_requests") =
    limine.FramebufferRequest{
        .id = limine.framebuffer_request_id,
        .revision = 0,
        .response = null,
    };

pub export var start_marker: [4]u64 linksection(".limine_requests_start") =
    limine.requests_start_marker;

pub export var end_marker: [2]u64 linksection(".limine_requests_end") =
    limine.requests_end_marker;

pub export var memmap_request linksection(".limine_requests") =
    limine.MemmapRequest{
        .id = limine.memmap_request_id,
        .revision = 0,
        .response = null,
    };

pub export var rsdp_request linksection(".limine_requests") =
    limine.RsdpRequest{
        .id = limine.rsdp_request_id,
        .revision = 0,
        .response = null,
    };

pub export var cmdline_request linksection(".limine_requests") =
    limine.CmdlineRequest{
        .id = limine.cmdline_request_id,
        .revision = 0,
        .response = null,
    };

pub export var hhdm_request linksection(".limine_requests") =
    limine.HHDMRequest{
        .id = limine.hhdm_request_id,
        .revision = 0,
        .response = null,
    };

pub export var kernel_request linksection(".limine_requests") =
    limine.ExecutableAddressRequest{
        .id = limine.executable_address_request_id,
        .revision = 0,
        .response = null,
    };

pub export var module_request linksection(".limine_requests") =
    limine.ModuleRequest{
        .id = limine.module_request_id,
        .revision = 0,
        .response = null,
    };

var hhdm_offset: usize = 0;
pub fn p2v(pa: usize) usize {
    return hhdm_offset + pa;
}

pub fn get_image_layout() r.ImageLayout {
    const resp = kernel_request.response.?;

    return .{
        .physical_base = resp.physical_base,
        .virtual_base = resp.virtual_base,
    };
}

var cmdline: [256]u8 = undefined;

fn build_mmap(module_start: usize, module_end: usize) void {
    const mmap = memmap_request.response orelse unreachable;
    const entries = mmap.entries orelse unreachable;

    for (0..mmap.entry_count) |i| {
        const entry = entries[i];

        if (entry.type == .KernelAndModules) {
            const end = entry.base + entry.length;
            const reclaim_start = std.mem.alignForward(
                usize,
                @max(entry.base, module_start),
                r.page_size,
            );
            const reclaim_end = std.mem.alignBackward(
                usize,
                @min(end, module_end),
                r.page_size,
            );

            // Ensure the kernel is marked as reclaiamble, we load it ourselves
            // anyway.
            if (reclaim_start < reclaim_end) {
                if (entry.base < reclaim_start) {
                    r.mem.add_entry(
                        entry.base,
                        reclaim_start - entry.base,
                        .Reserved,
                    );
                }

                r.mem.add_entry(
                    reclaim_start,
                    reclaim_end - reclaim_start,
                    .LoaderReclaimable,
                );

                if (reclaim_end < end) {
                    r.mem.add_entry(reclaim_end, end - reclaim_end, .Reserved);
                }
                continue;
            }
        }

        r.mem.add_entry(entry.base, entry.length, switch (entry.type) {
            .AcpiNvs => .AcpiNvs,
            .BootloaderReclaimable => .LoaderReclaimable,
            .AcpiReclaimable => .AcpiReclaimable,
            .Usable => .Free,
            else => .Reserved,
        });
    }
}

export fn loader_entry() callconv(.c) void {
    var kernel: ?*anyopaque = null;
    var module_start: usize = 0;
    var module_end: usize = 0;

    const hhdm_resp = hhdm_request.response orelse unreachable;
    hhdm_offset = hhdm_resp.offset;

    if (module_request.response) |resp| {
        const limine_mods = resp.modules orelse unreachable;
        const modules = limine_mods[0..resp.module_count];

        for (modules) |mod| {
            if (std.mem.eql(u8, std.mem.span(mod.string), "kernel")) {
                kernel = mod.address;
                const phys = @intFromPtr(mod.address) - hhdm_offset;
                const size: usize = @intCast(mod.size);

                module_start = std.mem.alignForward(
                    usize,
                    phys,
                    r.page_size,
                );
                module_end = std.mem.alignBackward(
                    usize,
                    phys + size,
                    r.page_size,
                );
                break;
            }
        }
    }

    if (kernel == null) {
        @panic("loader: kernel not found");
    }

    build_mmap(module_start, module_end);

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

    if (cmdline_request.response) |resp| {
        if (resp.cmdline) |c| {
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
    }

    r.main(kernel.?);
}

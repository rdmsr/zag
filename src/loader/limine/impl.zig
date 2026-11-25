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

fn p2v(pa: usize) usize {
    return hhdm_offset + pa;
}

fn get_image_layout() r.ImageLayout {
    const resp = kernel_request.response orelse unreachable;

    return .{
        .physical_base = resp.physical_base,
        .virtual_base = resp.virtual_base,
    };
}

var cmdline: [256]u8 = undefined;

fn build_mmap() void {
    const mmap = memmap_request.response orelse unreachable;
    const entries = mmap.entries orelse unreachable;

    for (0..mmap.entry_count) |i| {
        const entry = entries[i];

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
    const hhdm_resp = hhdm_request.response orelse unreachable;
    hhdm_offset = hhdm_resp.offset;

    r.impl = .{
        .get_image_layout = get_image_layout,
        .p2v = p2v,
    };

    build_mmap();

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
        r.loader_info.rsdp = @intFromPtr(resp.rsdp) - hhdm_offset;
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

    r.main();
}

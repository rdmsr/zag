//! Very bad and slow framebuffer console.
const r = @import("root");
const std = @import("std");

const pl = r.pl;
const ke = r.ke;

const PSF1_MAGIC: u16 = 0x0436;
const PSF2_MAGIC: u32 = 0x864ab572;

const Psf1Header = extern struct {
    magic: u16,
    mode: u8,
    glyph_size: u8,
};

const Psf2Header = extern struct {
    magic: u32,
    version: u32,
    header_size: u32,
    flags: u32,
    glyph_count: u32,
    glyph_size: u32,
    height: u32,
    width: u32,
};

const FontInfo = struct {
    header_size: usize,
    glyph_size: usize,
    width: u16,
    height: u16,
};

const Cursor = struct {
    x: u16 = 0,
    y: u16 = 0,
};

const font_file = @embedFile("sun12x22-ascii.psf");
const text_color: u32 = 0xFFFFFFFF;
const bg_color: u32 = 0xFF000000;
const crash_bg_color: u32 = 0xFF0000FF;
const window_padding: usize = 10;

var font: FontInfo = undefined;
var framebuffer: [*]u32 = undefined;
var framebuffer_width: usize = 0;
var framebuffer_height: usize = 0;

var cursor: Cursor = .{};
var console_width: u16 = 0;
var console_height: u16 = 0;

var content_w: usize = 0;
var content_h: usize = 0;
var enabled = true;

fn load_font() void {
    if (font_file.len >= @sizeOf(Psf2Header)) {
        const h2: *const Psf2Header = @ptrCast(@alignCast(font_file.ptr));
        if (h2.magic == PSF2_MAGIC) {
            font = .{
                .header_size = h2.header_size,
                .glyph_size = h2.glyph_size,
                .width = h2.width,
                .height = h2.height,
            };
            return;
        }
    }

    if (font_file.len >= @sizeOf(Psf1Header)) {
        const h1: *const Psf1Header = @ptrCast(@alignCast(font_file.ptr));
        if (h1.magic == PSF1_MAGIC) {
            font = .{
                .header_size = @sizeOf(Psf1Header),
                .glyph_size = h1.glyph_size,
                .width = 8,
                .height = h1.glyph_size,
            };
            return;
        }
    }

    font = .{
        .header_size = 0,
        .glyph_size = 0,
        .width = 0,
        .height = 0,
    };
}

fn plot_character(x: usize, y: usize, c: u8) void {
    const bytes_per_row = font.glyph_size / font.height;
    const glyph_offset = font.header_size + (@as(usize, c) * font.glyph_size);
    const glyph_data = font_file[glyph_offset..(glyph_offset + font.glyph_size)];
    const start_x = window_padding + x;
    const start_y = window_padding + y;

    for (0..font.height) |row| {
        var row_data: u32 = 0;

        for (0..bytes_per_row) |b| {
            row_data = (row_data << 8) | @as(u32, glyph_data[row * bytes_per_row + b]);
        }

        const shift_base = bytes_per_row * 8;

        for (0..font.width) |col| {
            if ((row_data & (@as(u32, 1) << @intCast(shift_base - 1 - col))) != 0) {
                framebuffer[(start_y + row) * framebuffer_width + (start_x + col)] = text_color;
            }
        }
    }
}

fn scroll() void {
    const rows_to_shift = (console_height - 1) * font.height;

    // Move all lines up.
    for (0..rows_to_shift) |row| {
        const dst_y = window_padding + row;
        const src_y = dst_y + font.height;

        for (0..content_w) |col| {
            framebuffer[dst_y * framebuffer_width + window_padding + col] =
                framebuffer[src_y * framebuffer_width + window_padding + col];
        }
    }

    // Clear the last line.
    for (0..font.height) |row| {
        const dst_y = window_padding + (console_height - 1) * font.height + row;

        for (0..content_w) |col| {
            framebuffer[dst_y * framebuffer_width + window_padding + col] = bg_color;
        }
    }
}

pub fn disable() void {
    enabled = false;
}

pub fn crash() void {
    cursor.x = 0;
    cursor.y = 0;

    for (0..framebuffer_width * framebuffer_height) |i| {
        framebuffer[i] = crash_bg_color;
    }
}

pub fn write_char(c: u8) void {
    if (!enabled) return;

    if (c == '\n') {
        cursor.x = 0;
        cursor.y += 1;

        if (cursor.y >= console_height) {
            cursor.y = console_height - 1;
            scroll();
        }
    } else if (c == '\r') {
        cursor.x = 0;
    } else {
        plot_character(cursor.x * font.width, cursor.y * font.height, c);
        cursor.x += 1;
    }
}

pub fn init(boot_info: *r.BootInfo) void {
    framebuffer = @ptrFromInt(boot_info.framebuffer.?.address);
    framebuffer_width = boot_info.framebuffer.?.width;
    framebuffer_height = boot_info.framebuffer.?.height;

    load_font();

    content_w = framebuffer_width - (window_padding * 2);
    content_h = framebuffer_height - (window_padding * 2);

    console_width = @intCast(content_w / font.width);
    console_height = std.math.divCeil(
        u16,
        @intCast(content_h),
        font.height,
    ) catch unreachable;

    for (0..framebuffer_width * framebuffer_height) |i| {
        framebuffer[i] = bg_color;
    }
}

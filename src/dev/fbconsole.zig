//! Very bad and slow framebuffer console.
const r = @import("root");

const pl = r.pl;
const ke = r.ke;
const ex = r.ex;

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
    width: usize,
    height: usize,
};

const font_file = @embedFile("sun12x22.psfu");
var font: FontInfo = undefined;
var framebuffer: [*]u32 = undefined;
var framebuffer_width: usize = 0;
var framebuffer_height: usize = 0;

const bg_color: u32 = 0xFFFFFFFF;
const text_color: u32 = 0xFF000000;
const window_padding: usize = 10;

var content_x: usize = 0;
var content_y: usize = 0;
var content_w: usize = 0;
var content_h: usize = 0;
var visible_h: usize = 0;

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
    font = .{ .header_size = 0, .glyph_size = 0, .width = 0, .height = 0 };
}

fn plot_character(x: usize, y: usize, c: u8) void {
    const bytes_per_row = font.glyph_size / font.height;
    const glyph_offset = font.header_size + (@as(usize, c) * font.glyph_size);
    const glyph_data = font_file[glyph_offset..(glyph_offset + font.glyph_size)];
    for (0..font.height) |row| {
        var row_data: u32 = 0;
        for (0..bytes_per_row) |b| {
            row_data = (row_data << 8) | @as(u32, glyph_data[row * bytes_per_row + b]);
        }
        const shift_base = bytes_per_row * 8;
        for (0..font.width) |col| {
            if ((row_data & (@as(u32, 1) << @intCast(shift_base - 1 - col))) != 0) {
                framebuffer[(y + row) * framebuffer_width + (x + col)] = text_color;
            }
        }
    }
}

var cursor_x: usize = 0;
var cursor_y: usize = 0;

fn clear_content_rows(y: usize, height: usize) void {
    for (0..height) |row| {
        const dst_y = content_y + y + row;
        if (dst_y >= content_y + visible_h) break;

        for (0..content_w) |col| {
            framebuffer[dst_y * framebuffer_width + content_x + col] = bg_color;
        }
    }
}

fn scroll_up(pixels: usize) void {
    if (pixels >= visible_h) {
        clear_content_rows(0, visible_h);
        return;
    }

    const remaining_h = visible_h - pixels;
    for (0..remaining_h) |row| {
        const dst_y = content_y + row;
        const src_y = dst_y + pixels;

        for (0..content_w) |col| {
            framebuffer[dst_y * framebuffer_width + content_x + col] =
                framebuffer[src_y * framebuffer_width + content_x + col];
        }
    }

    clear_content_rows(remaining_h, pixels);
}

fn ensure_cursor_visible() void {
    while (cursor_y + font.height > visible_h) {
        scroll_up(font.height);
        cursor_y -= font.height;
    }
}

fn newline() void {
    cursor_x = 0;
    cursor_y += font.height;

    while (cursor_y > visible_h) {
        scroll_up(font.height);
        cursor_y -= font.height;
    }
}

pub fn write_char(c: u8) void {
    if (font.width == 0 or font.height == 0 or content_w < font.width or visible_h < font.height) {
        return;
    }

    // Backspace.
    if (c == '\x08') {
        if (cursor_x >= font.width) {
            cursor_x -= font.width;
            ensure_cursor_visible();
            for (0..font.height) |row| {
                const dst_y = content_y + cursor_y + row;
                for (0..font.width) |col| {
                    framebuffer[dst_y * framebuffer_width + content_x + cursor_x + col] = bg_color;
                }
            }
        }
        return;
    }

    if (c == '\n') {
        newline();
    } else if (c == '\r') {
        cursor_x = 0;
    } else {
        if (cursor_x + font.width > content_w) {
            newline();
        }

        ensure_cursor_visible();
        plot_character(content_x + cursor_x, content_y + cursor_y, c);
        cursor_x += font.width;
    }
}

fn write(_: ?*anyopaque, s: []const u8) void {
    for (s) |c| {
        write_char(c);
    }
}

var console: ex.Console = .{ .ctx = null, .link = undefined, .write = write };

pub fn init(boot_info: *pl.BootInfo) void {
    framebuffer = @ptrFromInt(boot_info.framebuffer.?.address);
    framebuffer_width = boot_info.framebuffer.?.width;
    framebuffer_height = boot_info.framebuffer.?.height;

    load_font();

    content_x = window_padding;
    content_y = window_padding;
    content_w = framebuffer_width - (window_padding * 2);
    content_h = framebuffer_height - (window_padding * 2);
    visible_h = if (font.height == 0) 0 else content_h - (content_h % font.height);

    for (0..framebuffer_width * framebuffer_height) |i| {
        framebuffer[i] = bg_color;
    }

    ex.console.register(&console);
}

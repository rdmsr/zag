const std = @import("std");
const ksyms = @import("ksyms");
const pl = @import("base").pl;

const DebugWriter = struct {
    pub const Error = error{};
    pub const Writer = std.io.GenericWriter(*DebugWriter, Error, write);

    fn write(self: *DebugWriter, bytes: []const u8) Error!usize {
        _ = self;
        for (bytes) |c| pl.debug_write(c);
        return bytes.len;
    }

    fn writer(self: *DebugWriter) Writer {
        return .{ .context = self };
    }
};

var debug_writer = DebugWriter{};

export fn kmain() callconv(.c) void {
    print("hello from kernel!\n", .{});

    for (ksyms.ksyms) |sym| {
        print("  0x{x:0>16} {s}\n", .{ sym.addr, sym.name });
    }

    pl.first_init();

    while (true) {
        asm volatile ("hlt");
    }
}

export fn memset(dest: [*]u8, c: u8, n: usize) [*]u8 {
    for (dest[0..n]) |*b| b.* = c;
    return dest;
}

export fn memcpy(dest: [*]u8, src: [*]const u8, n: usize) [*]u8 {
    for (0..n) |i| dest[i] = src[i];
    return dest;
}

export fn memmove(dest: [*]u8, src: [*]const u8, n: usize) [*]u8 {
    if (@intFromPtr(dest) < @intFromPtr(src)) {
        for (0..n) |i| dest[i] = src[i];
    } else {
        var i = n;
        while (i > 0) {
            i -= 1;
            dest[i] = src[i];
        }
    }
    return dest;
}

const std = @import("std");
const config = @import("config");
const r = @import("root");
const ksyms = @import("ksyms");
const ke = r.ke;
const ki = ke.private;

extern var text_start_addr: u8;
extern var text_end_addr: u8;

const StackFrame = struct {
    prev: ?*StackFrame,
    return_addr: usize,
};

const Symbol = struct {
    name: []const u8,
    offset: usize,
};

fn get_symbol_name(addr: usize) ?Symbol {
    const symbols = ksyms.get_symbols();

    // Do a binary search on the ksyms array.
    // The address may not be exact, so we look for the closest
    // symbol that is less than or equal to the address.
    var left: usize = 0;
    var right: usize = symbols.len;
    while (left < right) {
        const mid = left + (right - left) / 2;
        const sym = symbols[mid];
        if (sym.addr == addr) {
            return .{ .name = sym.name_ptr[0..sym.name_len], .offset = 0 };
        } else if (sym.addr < addr) {
            left = mid + 1;
        } else {
            right = mid;
        }
    }

    if (left > 0) {
        const sym = symbols[left - 1];

        if (sym.addr <= addr) {
            return .{ .name = sym.name_ptr[0..sym.name_len], .offset = addr - sym.addr };
        }
    }

    return null;
}

fn is_kernel_text(addr: usize) bool {
    const s = @intFromPtr(&text_start_addr);
    const e = @intFromPtr(&text_end_addr);
    return addr >= s and addr < e;
}

fn walk_stack_frame(base: usize) void {
    var frame: ?*StackFrame = @ptrFromInt(base);
    var depth: usize = 0;
    while (frame) |f| : (depth += 1) {
        if (depth > 64) break;
        const ret_addr = f.return_addr;
        if (!is_kernel_text(ret_addr)) {
            break;
        }
        const sym = get_symbol_name(ret_addr) orelse Symbol{ .name = "???", .offset = 0 };
        std.log.err("  #{d} {s}+0x{x} - 0x{x}", .{ depth, sym.name, sym.offset, ret_addr });
        frame = f.prev;
    }
}

pub fn panic_with_frame(
    msg: []const u8,
    frame: usize,
) noreturn {
    std.log.err("KERNEL PANIC: {s}", .{msg});
    std.log.err("Stack trace:", .{});
    walk_stack_frame(frame);

    while (true) {}
}

pub fn panic(
    msg: []const u8,
    first_trace_addr: ?usize,
) noreturn {
    if (@hasDecl(config, "CONFIG_ARCH_UM")) {
        std.debug.defaultPanic(msg, first_trace_addr);
    }
    panic_with_frame(msg, @frameAddress());
}

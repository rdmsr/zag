//! Abortable functions.
//!
//! Abortable functions are regular memory operations that return an error
//! when a page fault occurs instead of crashing.
//!
//! This works by implementing the operations in assembly routines that are
//! placed by the linker in a given range of addresses; if a page fault occurs,
//! the exception handler notices that the IP is within that range and
//! twiddles the IP to point to instructions that return 1 (true) instead.

const std = @import("std");
const assert = std.debug.assert;

const r = @import("root");
const ke = r.ke;
const kep = ke.private;

/// Try to read `T` from `addr`.
/// Returns an error if a fault occured.
pub fn try_read(comptime T: type, addr: *const T) error{Aborted}!T {
    switch (@sizeOf(T)) {
        1, 2, 4, 8 => {
            const U = @Int(.unsigned, @sizeOf(T) * 8);
            var raw: U = undefined;
            const faulted = switch (@sizeOf(T)) {
                1 => kep.impl.try_read8(addr, &raw),
                2 => kep.impl.try_read16(addr, &raw),
                4 => kep.impl.try_read32(addr, &raw),
                8 => kep.impl.try_read64(addr, &raw),
                else => unreachable,
            };
            if (faulted) return error.Aborted;
            return std.mem.bytesToValue(T, std.mem.asBytes(&raw));
        },
        else => {
            var out: T = undefined;
            if (kep.impl.try_copy(&out, addr, @sizeOf(T))) return error.Aborted;
            return out;
        },
    }
}

/// Try to write `val` to `addr`.
/// Returns an error if a fault occured.
pub fn try_write(comptime T: type, addr: *T, val: T) error{Aborted}!void {
    const faulted = switch (@sizeOf(T)) {
        1, 2, 4, 8 => blk: {
            const U = @Int(.unsigned, @sizeOf(T) * 8);
            const raw = std.mem.bytesToValue(U, std.mem.asBytes(&val));
            break :blk switch (@sizeOf(T)) {
                1 => kep.impl.try_write8(addr, raw),
                2 => kep.impl.try_write16(addr, raw),
                4 => kep.impl.try_write32(addr, raw),
                8 => kep.impl.try_write64(addr, raw),
                else => unreachable,
            };
        },
        else => kep.impl.try_copy(addr, &val, @sizeOf(T)),
    };
    if (faulted) return error.Aborted;
}

/// Try to copy `src` into `dst`.
/// Returns an error if a fault occured.
pub fn try_copy(dst: []u8, src: []const u8) error{Aborted}!void {
    assert(dst.len == src.len);
    if (kep.impl.try_copy(dst.ptr, src.ptr, src.len)) return error.Aborted;
}

//! General-purpose kernel allocator.
//!
//! `kalloc` provides a general-purpose allocator on top of zones.
//! This works by creating a given number of generic zones for various sizes.
//!
//! The sizing scheme used is the one from Jemalloc, i.e "linear-log bucketing",
//! where:
//!
//! * For small allocations, there's a linear range of sizes from 8 to 64,
//! spaced out by 16 bytes, i.e 8, 16, 32, 64.
//!
//! * For larger allocations, sizes are grouped in powers of two with 4 linear
//! sub-classes, i.e from size 128: 160, 192, 224, 256
//!
//! Why do this? Consider simply using power-of-two sizes; this leads to worst-
//! case fragmentation at 50%:
//!
//! lim (1/2 - 1/(2^(k+1))) = 1/2
//! k->inf
//!
//! or more intuitively, pick any number K such that N = 2^K and observe that
//! (2^(K+1) - N+1)/(2^(K+1)) is ~1/2; N+1 lands in the size class 2^(K+1) which
//! gives us worst-case fragmentation, e.g (512 - 257)/512 = ~1/2.
//!
//! This method, on the other hand, caps worst-case fragmentation at ~20%.
//!
//! For more details, see:
//! https://pvk.ca/Blog/2015/06/27/linear-log-bucketing-fast-versatile-simple.

const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;

const mm = @import("root").mm;
const mmp = mm.private;
const Zone = mm.zone.Zone;

/// The number of generic zones to generate.
const N = 33; // Up to 8192 bytes

/// 1/8th of a page.
const small_slab_size = 512;

/// Generic zones for general-purpose allocations.
var generic_zones: [N]Zone = undefined;
const generic_sizes = generate_generic_sizes();
const generic_names = generate_generic_names(generic_sizes);
const generic_max_size = bucket_to_size(N - 1);

/// Initialize kalloc.
pub fn init() void {
    for (0..generic_zones.len, &generic_zones) |i, *zone| {
        zone.init(generic_names[i], generic_sizes[i], .{});
    }
}

pub fn create(comptime T: type, comptime wait: mm.WaitPolicy) RetType(
    *T,
    wait,
) {
    const len = @sizeOf(T);

    const ptr = if (wait == .DontWaitForMemory)
        try alloc_impl(len, .fromByteUnits(@alignOf(T)), wait)
    else
        alloc_impl(len, .fromByteUnits(@alignOf(T)), wait) catch {
            // This will wait for free memory.
            unreachable;
        };

    return @ptrCast(@alignCast(ptr));
}

pub fn alloc(
    comptime T: type,
    count: usize,
    comptime wait: mm.WaitPolicy,
) RetType([]T, wait) {
    const len = @sizeOf(T) * count;

    const ptr = if (wait == .DontWaitForMemory)
        try alloc_impl(len, .fromByteUnits(@alignOf(T)), wait)
    else
        alloc_impl(len, .fromByteUnits(@alignOf(T)), wait) catch {
            // This will wait for free memory.
            unreachable;
        };

    const sl: [*]T = @ptrCast(@alignCast(ptr));
    return sl[0..count];
}

pub fn free(buf: anytype) void {
    comptime {
        const T = @TypeOf(buf);
        const info = @typeInfo(T);
        if (info != .pointer or info.pointer.size != .slice)
            @compileError("free expects a slice, got " ++ @typeName(T));
    }

    const bytes = std.mem.sliceAsBytes(buf);
    assert(bytes.len != 0);

    free_impl(bytes);
}

pub fn destroy(ptr: anytype) void {
    const T = @TypeOf(ptr);
    comptime {
        const info = @typeInfo(T);
        if (info != .pointer or info.pointer.size != .one)
            @compileError(
                "destroy expects a single-item pointer, got " ++ @typeName(ptr),
            );
    }

    const Child = @typeInfo(T).pointer.child;
    const base: [*]u8 = @ptrCast(@constCast(ptr));

    assert(@sizeOf(Child) != 0);

    free_impl(base[0..@sizeOf(Child)]);
}

fn alloc_impl(
    len: usize,
    ptr_align: mem.Alignment,
    wait: mm.WaitPolicy,
) mm.Error![*]u8 {
    const zone = zone_for(len) orelse {
        assert(ptr_align.toByteUnits() <= mm.page_size);
        const pages = std.mem.alignForward(usize, len, mm.page_size);
        const ptr = try mmp.heap.alloc(pages, wait);
        return @ptrCast(ptr);
    };

    const obj = try zone.alloc(.{ .policy = wait });
    return @ptrCast(obj);
}

fn free_impl(buf: []const u8) void {
    const len = buf.len;

    const zone = zone_for(len) orelse {
        const pages = std.mem.alignForward(usize, buf.len, mm.page_size);
        mm.heap.free(@intFromPtr(buf.ptr), pages);
        return;
    };

    zone.free(@ptrCast(@constCast(buf)));
}

/// Convert a bucket to its corresponding size.
fn bucket_to_size(index: usize) usize {
    if (index == 0) return 8;

    const i = index - 1;
    const group = i / 4;
    const offset = i % 4;

    if (group == 0) {
        return (offset + 1) * 16;
    }

    return (offset + 5) << (group + 3);
}

/// Convert a size to its containing size.
fn size_to_bucket(size: usize) usize {
    if (size <= 8) return 0;
    if (size <= 64) return ((size - 1) / 16) + 1;

    const lg: usize = std.math.log2_int(usize, size - 1);
    const group = lg - 5;
    const shift: std.math.Log2Int(usize) = @intCast(lg - 2);
    const offset = ((size - 1) >> shift) - 4;
    return 1 + (group * 4) + offset;
}

fn generate_generic_sizes() [N]usize {
    var arr: [N]usize = undefined;

    for (0..N) |i| {
        arr[i] = comptime bucket_to_size(i);
    }

    return arr;
}

fn generate_generic_names(comptime array: [N]usize) [N][]const u8 {
    var ret: [N][]const u8 = undefined;

    for (0..N) |i| {
        ret[i] = std.fmt.comptimePrint("zone-{}", .{array[i]});
    }

    return ret;
}

fn RetType(comptime T: type, comptime wait: mm.WaitPolicy) type {
    if (wait == .DontWaitForMemory) {
        return mm.Error!T;
    }

    return T;
}

/// zig-compatible general-purpose allocator.
/// This will wait for memory and thus never error.
///
/// Prefer using kalloc functions directly, as they take flags and don't have to
/// go through a vtable.
pub const gpa: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = gpa_alloc,
        .resize = gpa_resize,
        .free = gpa_free,
        .remap = gpa_remap,
    },
};

fn gpa_alloc(
    _: *anyopaque,
    len: usize,
    ptr_align: mem.Alignment,
    _: usize,
) ?[*]u8 {
    return alloc_impl(len, ptr_align, .WaitForMemory) catch null;
}

fn gpa_resize(
    _: *anyopaque,
    buf: []u8,
    _: std.mem.Alignment,
    new_len: usize,
    _: usize,
) bool {
    if (buf.len > generic_max_size) {
        // Allow shrinking within the same page-rounded allocation.
        const old_pages = std.mem.alignForward(usize, buf.len, mm.page_size);
        const new_pages = std.mem.alignForward(usize, new_len, mm.page_size);
        return new_pages <= old_pages;
    }
    // Can't resize in place. Only allow shrinking within the same zone.
    const old_zone = zone_for(buf.len) orelse return false;
    const new_zone = zone_for(new_len) orelse return false;
    return old_zone == new_zone;
}

fn gpa_remap(
    _: *anyopaque,
    buf: []u8,
    alignment: mem.Alignment,
    new_len: usize,
    ret_addr: usize,
) ?[*]u8 {
    if (gpa_resize(undefined, buf, alignment, new_len, ret_addr))
        return buf.ptr;

    const new_ptr = gpa_alloc(undefined, new_len, alignment, ret_addr) orelse
        return null;
    const copy_len = @min(buf.len, new_len);
    @memcpy(new_ptr[0..copy_len], buf[0..copy_len]);
    gpa_free(undefined, buf, alignment, ret_addr);
    return new_ptr;
}

fn gpa_free(_: *anyopaque, buf: []u8, _: mem.Alignment, _: usize) void {
    free_impl(buf);
}

fn zone_for(size: usize) ?*Zone {
    if (size > generic_max_size) return null;
    return &generic_zones[size_to_bucket(size)];
}

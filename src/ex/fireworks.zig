//! Fireworks test ported from the Boron operating system.
const std = @import("std");
const r = @import("root");
const ke = r.ke;
const mm = r.mm;
const sintab = @import("sintab.zig");

var pixel_buffer: [*]u8 = undefined;
var fb_width: usize = 0;
var fb_height: usize = 0;
var fb_pitch: usize = 0;
var fb_bpp: usize = 0;
var inited = std.atomic.Value(bool).init(false);

const background_color = 0x09090F;

fn fill_screen(color: u32) void {
    for (0..fb_height) |y| {
        for (0..fb_width) |x| {
            const pixel_offset = y * fb_pitch + x * fb_bpp;
            @as(*u32, @ptrCast(@alignCast(&pixel_buffer[pixel_offset]))).* = color;
        }
    }
}

fn plot_pixel(x: i64, y: i64, color: u32) void {
    if (x >= fb_width or y >= fb_height or x < 0 or y < 0) return;

    const pixel_offset = @as(u64, @intCast(y)) * fb_pitch + @as(u64, @intCast(x)) * fb_bpp;
    @as(*u32, @ptrCast(@alignCast(&pixel_buffer[pixel_offset]))).* = color;
}

fn read_tsc() u64 {
    var lo: u32 = 0;
    var hi: u32 = 0;

    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );

    return (@as(u64, hi) << 32) | @as(u64, lo);
}

fn rand_tsc_based() u32 {
    const tsc = read_tsc();
    const lo: u32 = @truncate(tsc);
    const hi: u32 = @truncate(tsc >> 32);
    return lo ^ hi;
}

var rand_gen: i64 = 0x9521af17;

fn rand() i64 {
    rand_gen += @as(i32, @bitCast(@as(u32, 0xe120fc15)));
    var tmp: u64 = @bitCast(rand_gen *% 0x4a39b70d);
    const m1 = (tmp >> 32) ^ tmp;
    tmp = m1 *% 0x12fad5c9;
    const m2 = (tmp >> 32) ^ tmp;
    return @intCast(m2 & 0x7FFFFFFF); //make it always positive.
}

const fixed_point_shift = 16;

fn fp_to_int(fp: i64) i64 {
    return fp >> fixed_point_shift;
}

fn int_to_fp(i: i64) i64 {
    return i << fixed_point_shift;
}

fn mul_fp_fp(a: i64, b: i64) i64 {
    return (a * b) >> fixed_point_shift;
}

fn rand_fp() i64 {
    return @rem(rand(), (1 << fixed_point_shift));
}

fn rand_fp_sign() i64 {
    if (@rem(rand(), 2) != 0)
        return -rand_fp();

    return rand_fp();
}

fn sin(angle: i64) i64 {
    return @divFloor(int_to_fp(sintab.SinTable[@intCast(@rem(angle, 65536))]), 32768);
}

fn cos(angle: i64) i64 {
    return sin(angle + 16384);
}

const FireworkData = struct {
    x: i64,
    y: i64,
    color: u32,
    act_x: i64,
    act_y: i64,
    vel_x: i64,
    vel_y: i64,
    explosion_range: i32,
};

fn get_random_color() u32 {
    return @intCast((rand() + 0x808080) & 0xFFFFFF); // Random pastel color
}

fn perform_delay(ms: usize) void {
    var timer: ke.Timer = undefined;
    timer.init();
    ke.timer.set(&timer, std.time.ns_per_ms * ms, null);
    _ = ke.wait.wait_one(&timer.hdr, null) catch unreachable;
}

fn particle(param: ?*anyopaque) void {
    const parent_data: *FireworkData = @ptrCast(@alignCast(param));
    var data: FireworkData = undefined;

    data = std.mem.zeroes(FireworkData);

    data.x = parent_data.x;
    data.y = parent_data.y;
    data.act_x = parent_data.act_x;
    data.act_y = parent_data.act_y;
    const explosion_range = parent_data.explosion_range;

    const angle = @rem(rand(), 65536);
    data.vel_x = mul_fp_fp(cos(angle), rand_fp_sign()) * explosion_range;
    data.vel_y = mul_fp_fp(sin(angle), rand_fp_sign()) * explosion_range;

    const expire_in = 2000 + (@rem(rand(), 1000));

    data.color = get_random_color();

    var i: i32 = 0;
    var t: i32 = 0;

    while (i < expire_in) {
        plot_pixel(@intCast(data.x), @intCast(data.y), data.color);

        const delay = @as(i32, 16) + @intFromBool(t != 0);
        perform_delay(@intCast(delay));
        i += delay;
        t += 1;

        if (t == 3)
            t = 0;

        plot_pixel(@intCast(data.x), @intCast(data.y), background_color);

        data.act_x += @divTrunc(data.vel_x * delay, 1000);
        data.act_y += @divTrunc(data.vel_y * delay, 1000);
        data.x = fp_to_int(data.act_x);
        data.y = fp_to_int(data.act_y);

        data.vel_y += @divTrunc(int_to_fp(10) * delay, 1000);
    }

    // Now block.
    ke.sched.block();
}

fn make_thread(entry: *const fn (?*anyopaque) void, arg: ?*anyopaque) *ke.Thread {
    var ret: *ke.Thread = mm.zone.gpa.create(ke.Thread) catch @panic("oom");
    const stack = mm.heap.alloc(r.kib(16)) catch @panic("wtf");

    ret.init(@intFromPtr(stack), r.kib(16), entry, arg);

    ret.priority = ke.Thread.Priority.default;
    ret.priority_class = .Batch;

    return ret;
}

fn spawn_particle(arg: ?*anyopaque) void {
    const thread = make_thread(&particle, arg);
    ke.sched.enqueue(thread);
}

fn spawn_explodeable() void {
    const thread = make_thread(&explodeable, null);
    ke.sched.enqueue(thread);
}

fn explodeable(_: ?*anyopaque) void {
    var data: FireworkData = undefined;

    const offset_x: i64 = @intCast(fb_width * 400 / 1024);

    data.x = @intCast(fb_width / 2);
    data.y = @intCast(fb_height - 1);
    data.act_x = int_to_fp(data.x);
    data.act_y = int_to_fp(data.y);
    data.vel_y = -int_to_fp(400 + @rem(rand(), 400));
    data.vel_x = offset_x * rand_fp_sign();
    data.color = get_random_color();
    data.explosion_range = @intCast(100 + (@rem(rand(), 100)));

    const expire_in = 500 + (@rem(rand(), 500));
    var t: i32 = 0;
    var i: i32 = 0;

    while (i < expire_in) {
        plot_pixel(data.x, data.y, data.color);

        const delay: i32 = @as(u8, 16) + @intFromBool(t != 0);

        perform_delay(@intCast(delay));

        i += delay;
        t += 1;

        if (t == 3)
            t = 0;

        plot_pixel(data.x, data.y, background_color);

        data.act_x += @divTrunc(data.vel_x * delay, 1000);
        data.act_y += @divTrunc(data.vel_y * delay, 1000);

        data.x = fp_to_int(data.act_x);
        data.y = fp_to_int(data.act_y);

        data.vel_y += @divTrunc(int_to_fp(10) * delay, 1000);
    }

    const part_count: usize = @intCast(@rem(rand(), 100) + 100);

    for (0..part_count) |_| {
        const param: *FireworkData = mm.zone.gpa.create(FireworkData) catch @panic("oom");
        param.* = data;
        spawn_particle(param);
    }

    ke.sched.block();
}

pub fn start(param: ?*anyopaque) void {
    const boot_info: *r.pl.BootInfo = @ptrCast(@alignCast(param));

    rand_gen ^= rand_tsc_based();

    if (boot_info.framebuffer) |fb| {
        fb_bpp = fb.bpp / 8;
        fb_pitch = fb.pitch;
        fb_width = fb.width;
        fb_height = fb.height;
        pixel_buffer = @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(fb.address))));
    }

    fill_screen(0x09090F);

    while (true) {
        const spawn_count: usize = @intCast(@rem(rand(), 20) + 1);

        for (0..spawn_count) |_| {
            spawn_explodeable();
        }

        perform_delay(2000);
    }
}

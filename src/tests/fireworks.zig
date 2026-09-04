//! Fireworks test ported from the Boron operating system.
const std = @import("std");
const r = @import("root");
const ke = r.ke;
const mm = r.mm;
const ps = r.ps;
const bv = r.bv;

var pixel_buffer: [*]u8 = undefined;
var fb_width: usize = 0;
var fb_height: usize = 0;
var fb_pitch: usize = 0;
var fb_bpp: usize = 0;
var inited = std.atomic.Value(bool).init(false);
var particle_count: std.atomic.Value(usize) = .init(0);

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

fn rand_tsc_based() u32 {
    const tsc = ke.time.read_time().value;
    const lo: u32 = @truncate(tsc);
    const hi: u32 = @truncate(tsc >> 32);
    return lo ^ hi;
}

var rand_gen: u32 = 0x9521af17;

fn rand() i64 {
    rand_gen +%= 0xe120fc15;
    var tmp: u64 = @as(u64, rand_gen) *% 0x4a39b70d;
    const m1: u32 = @truncate((tmp >> 32) ^ tmp);
    tmp = @as(u64, m1) *% 0x12fad5c9;
    return @as(u32, @truncate((tmp >> 32) ^ tmp));
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
    return rand() & 0xFFFF;
}

fn rand_fp_sign() i64 {
    const v = rand();
    const m = -((v >> 16) & 1);
    return ((v & 0xFFFF) ^ m) - m;
}

fn sin(angle: i64) i64 {
    const x: i32 = @as(i16, @truncate(angle));
    const mask = x >> 31;
    const ax = (x ^ mask) - mask;
    return (x * (32768 - ax)) >> 12;
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
    expire_in: i64,
    i: u32,
};

fn get_random_color() u32 {
    return @intCast((rand() + 0x808080) & 0xFFFFFF);
}

fn sleep(ms: usize, continuation: ?ke.Continuation) void {
    _ = ke.wait.wait_any(&.{}, "sleep", .{
        .timeout = .from(r.Milliseconds.init(ms)),
        .continuation = continuation,
    }) catch {
        return;
    };
    @panic("Not a timeout?");
}

const particle_delay = 16;

fn particle_continuation(param: ?*anyopaque) void {
    const data: *FireworkData = @ptrCast(@alignCast(param));
    plot_pixel(@intCast(data.x), @intCast(data.y), background_color);

    data.i += particle_delay;

    if (data.i >= data.expire_in) {
        mm.zone.gpa.destroy(data);

        _ = particle_count.fetchSub(1, .monotonic);
        ps.thread.exit();
    }

    data.act_x += @divTrunc(data.vel_x * particle_delay, 1000);
    data.act_y += @divTrunc(data.vel_y * particle_delay, 1000);
    data.x = fp_to_int(data.act_x);
    data.y = fp_to_int(data.act_y);

    data.vel_y += @divTrunc(int_to_fp(10) * particle_delay, 1000);

    plot_pixel(@intCast(data.x), @intCast(data.y), data.color);
    sleep(particle_delay, .{
        .func = particle_continuation,
        .arg = data,
    });
}

fn particle(param: ?*anyopaque) void {
    const parent_data: *FireworkData = @ptrCast(@alignCast(param));

    const data = mm.zone.gpa.create(FireworkData) catch unreachable;

    data.* = std.mem.zeroes(FireworkData);

    _ = particle_count.fetchAdd(1, .monotonic);

    data.x = parent_data.x;
    data.y = parent_data.y;
    data.act_x = parent_data.act_x;
    data.act_y = parent_data.act_y;
    const explosion_range = parent_data.explosion_range;

    mm.zone.gpa.destroy(parent_data);

    const angle = rand();
    const speed = @max(rand_fp(), rand_fp());
    data.vel_x = mul_fp_fp(cos(angle), speed) * explosion_range;
    data.vel_y = mul_fp_fp(sin(angle), speed) * explosion_range;

    const expire_in = 2000 + (@rem(rand(), 1000));

    data.expire_in = expire_in;
    data.i = 0;

    data.color = get_random_color();

    plot_pixel(@intCast(data.x), @intCast(data.y), data.color);

    sleep(particle_delay, .{
        .func = particle_continuation,
        .arg = data,
    });

    @panic("shouldn't happen");
}

fn spawn_particle(arg: ?*anyopaque) void {
    const t = ps.thread.create_kernel(
        .Default,
        .{ .func = &particle, .arg = arg },
        false,
    ) catch @panic("OOM");

    ke.sched.enqueue(&t.kern);
}

fn spawn_explodeable() void {
    const t = ps.thread.create_kernel(
        .Default,
        .{ .func = &explodeable, .arg = null },
        false,
    ) catch @panic("OOM");
    ke.sched.enqueue(&t.kern);
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

        sleep(@intCast(delay), null);

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

    ps.thread.exit();
}

fn spawning_loop(_: ?*anyopaque) void {
    const spawn_count: usize = @intCast(@rem(rand(), 20) + 1);

    for (0..spawn_count) |_| {
        spawn_explodeable();
    }

    std.log.info("async: {}, sync: {}, usable memory: {} KiB, {} stacks for {} particles", .{
        mm.private.tlb.async_shootdowns.load(.monotonic),
        mm.private.tlb.sync_shootdowns.load(.monotonic),
        mm.private.phys.usable_memory.load(.monotonic) / 1024,
        ke.private.thread.stacks_count(),
        particle_count.load(.monotonic),
    });

    sleep(2000, .{ .func = spawning_loop, .arg = null });
}

pub fn start(param: ?*anyopaque) void {
    const boot_info: *r.BootInfo = @ptrCast(@alignCast(param));

    rand_gen ^= rand_tsc_based();

    bv.disable();

    if (boot_info.framebuffer) |fb| {
        fb_bpp = fb.bpp / 8;
        fb_pitch = fb.pitch;
        fb_width = fb.width;
        fb_height = fb.height;
        pixel_buffer = @ptrCast(@alignCast(@as(*anyopaque, @ptrFromInt(fb.address))));
    }

    fill_screen(0x09090F);

    spawning_loop(null);
}

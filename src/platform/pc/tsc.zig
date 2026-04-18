// Not sure if this should be in platform/pc or in kern/
const std = @import("std");
const amd64 = @import("arch");
const r = @import("root");
const ke = r.ke;

const log = std.log.scoped(.@"amd64/tsc");

var tsc_timer: ke.TimeCounter = .{
    .name = "TSC",
    .quality = 100,
    .frequency = 0,
    .read_count = read_tsc,
    .mask = std.math.maxInt(u64),
    .p = 0,
    .n = 0,
};

pub fn init() linksection(r.init) void {
    const features = amd64.cpu_features;

    if (!features.invariant_tsc) {
        log.info("invariant TSC not supported (get a new PC), using fallback", .{});
        if (ke.time.best()) |best| {
            log.info("using {s} as timecounter source", .{best.name});
        }
        return;
    }

    // Try using cpuid leaf 0x15 to get the TSC frequency.
    const cpuid_state = amd64.cpuid(0x15, 0);

    if (cpuid_state.ebx != 0 and cpuid_state.ecx != 0) {
        const tsc_freq = (cpuid_state.ebx / cpuid_state.eax) * cpuid_state.ecx;
        log.info("TSC frequency determined via CPUID: {} Hz", .{tsc_freq});
        tsc_timer.frequency = tsc_freq;

        ke.time.register_source(&tsc_timer);
        return;
    }

    // Fallback to the other best time source to calibrate.
    const best = ke.time.best() orelse return;

    const calib_cost_runs = 5;
    var calib_cost: u64 = 0;

    // Calculate how many ticks it costs to call tc_sleep.
    for (0..calib_cost_runs) |_| {
        const start = amd64.rdtsc();
        ke.time.sleep(0);
        const end = amd64.rdtsc();
        calib_cost += (end - start);
    }

    calib_cost /= calib_cost_runs;

    const runs = 5;
    const calib_time = 10 * std.time.ns_per_ms;

    // Sleep for 10ms `runs` times and measure the TSC frequency, then average the middle values to get a stable estimate.
    var freqs: [runs]u64 = undefined;

    for (0..runs) |i| {
        const start = amd64.rdtsc();
        ke.time.sleep(calib_time);
        const end = amd64.rdtsc();
        freqs[i] = (end - start - calib_cost) * (std.time.ns_per_s / calib_time);
    }

    // Sort and average middle values, discarding min and max.
    std.mem.sort(u64, &freqs, {}, std.sort.asc(u64));
    var sum: u64 = 0;
    for (freqs[1 .. runs - 1]) |f| sum += f;

    tsc_timer.frequency = sum / (runs - 2);

    ke.time.register_source(&tsc_timer);

    log.info("frequency calibrated using {s}: {}.{} MHz", .{ best.name, tsc_timer.frequency / 1_000_000, (tsc_timer.frequency % 1_000_000) / 1000 });
}

fn read_tsc() u64 {
    return amd64.rdtsc();
}

const std = @import("std");
const linux = std.os.linux;
const b = @import("base");
const pl = b.pl;
const ke = b.ke;
const ki = b.ke.private;
const posix = std.posix;

const timer = @import("timer.zig");

pub const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("pthread.h");
    @cInclude("sys/mman.h");
    @cInclude("ucontext.h");
    @cInclude("signal.h");
    @cInclude("unistd.h");
    @cInclude("sys/time.h");
    @cInclude("sched.h");
});

pub const name = "User-Mode";

pub const GlobalState = struct {
    const Params = struct {
        mem_size: usize,
        cmdline: ?[]const u8,
        ncpus: usize,
    };

    params: Params,
    boot_info: pl.BootInfo,
    phys_memory_memfd: i32,
    phys_base: usize,
};

pub var global_state: GlobalState = undefined;
pub threadlocal var my_cpu: *ke.Cpu = undefined;

var cpu_id: u32 = 0;

pub fn devices_init() void {}

pub fn debug_write(char: u8) void {
    std.debug.print("{c}", .{char});
}

pub const arm_timer = timer.arm_timer;

fn check_function(fn_name: []const u8, ret: usize) void {
    const real_ret: i64 = @intCast(ret);

    if (real_ret < 0) {
        const errno_val = linux.errno(ret);

        std.debug.print("error: {s}: {s}\n", .{ fn_name, @tagName(errno_val) });
        std.process.exit(1);
    }
}

pub fn early_init() linksection(b.init) void {
    // Set current CPU to the bootstrap CPU
    my_cpu = &ki.bootstrap_cpu;

    my_cpu.impl.pthread = c.pthread_self();

    // Allocate our ID
    my_cpu.id = 0;
    cpu_id += 1;

    const memfd: i32 = @intCast(linux.memfd_create("phys_memory", 0));

    check_function("ftruncate", linux.ftruncate(memfd, @intCast(global_state.params.mem_size)));

    const phys_base = linux.mmap(null, global_state.params.mem_size, .{ .READ = true, .WRITE = true }, .{ .ANONYMOUS = true, .TYPE = .SHARED }, memfd, 0);

    check_function("mmap", phys_base);

    // Build memory map
    global_state.boot_info.memory_map.entry_count = 1;
    global_state.boot_info.memory_map.entries[0].base = phys_base;
    global_state.boot_info.memory_map.entries[0].size = global_state.params.mem_size;
    global_state.boot_info.memory_map.entries[0].kind = .Free;

    global_state.phys_memory_memfd = memfd;
    global_state.phys_base = phys_base;

    const pfndb_base = linux.mmap(null, b.tib(1), .{}, .{ .ANONYMOUS = true, .TYPE = .PRIVATE }, -1, 0);

    check_function("mmap", pfndb_base);

    const heap_base = linux.mmap(null, b.gib(8), .{}, .{ .ANONYMOUS = true, .TYPE = .PRIVATE }, -1, 0);

    check_function("mmap", heap_base);

    b.kernel_pfndb_base = pfndb_base;
    b.kernel_heap_base = heap_base;

    std.log.info("um: kernel heap lives at {X}", .{heap_base});
}

fn sigusr1_handler(_: posix.SIG, _: *const posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    if (@intFromEnum(ke.curcpu().ipl) < @intFromEnum(ke.Ipl.Dispatch) and ki.ipl.is_softint_pending(ke.curcpu(), .Dispatch)) {
        ki.dpc.dispatch(ke.curcpu());
    }
}

fn make_thread(entry: *const fn (?*anyopaque) void, td: *ke.Thread) void {
    const stack = std.heap.page_allocator.alloc(u8, 16384) catch @panic("wtf");

    td.init(@intFromPtr(stack.ptr), 16384, entry, null);

    td.priority = 0;
    td.priority_class = .Idle;
}

var cpus_up = std.atomic.Value(usize).init(0);

fn other_cpu_entry(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    my_cpu = @ptrCast(@alignCast(arg.?));

    my_cpu.id = @atomicRmw(u32, &cpu_id, .Add, 1, .monotonic);
    my_cpu.impl.pthread = c.pthread_self();

    my_cpu.init(my_cpu.idle_thread.?);

    timer.init_cpu();

    _ = cpus_up.fetchAdd(1, .monotonic);

    while (true) {}

    return null;
}

fn idle(_: ?*anyopaque) void {}

pub fn late_init() linksection(b.init) void {
    timer.init();
    timer.init_cpu();

    var sa: posix.Sigaction = std.mem.zeroes(posix.Sigaction);
    sa.handler = .{
        .sigaction = sigusr1_handler,
    };

    sa.flags = posix.SA.SIGINFO;

    sa.mask = posix.sigemptyset();

    _ = posix.sigaction(posix.SIG.USR1, &sa, null);

    std.log.info("um: starting {} thread{s}", .{
        ke.ncpus - 1,
        if ((ke.ncpus - 1) > 1) "s" else "",
    });

    const other_count = ke.ncpus - 1;

    const allocator = std.heap.page_allocator;

    var other_threads =
        allocator.alloc(c.pthread_t, other_count) catch @panic("oom");

    ke.cpus = allocator.alloc(*ke.Cpu, ke.ncpus) catch @panic("oom");
    ke.cpus[0] = &ki.bootstrap_cpu;

    for (1..ke.ncpus) |i| {
        ke.cpus[i] = allocator.create(ke.Cpu) catch @panic("oom");

        ke.cpus[i].idle_thread = allocator.create(ke.Thread) catch @panic("oom");

        make_thread(idle, ke.cpus[i].idle_thread.?);

        var attr: c.pthread_attr_t = undefined;

        _ = c.pthread_attr_init(&attr);

        var cpuset: c.cpu_set_t = std.mem.zeroes(c.cpu_set_t);
        cpuset.__bits[i / 64] |= @as(c_ulong, 1) << @intCast(i % 64);
        _ = c.pthread_attr_setaffinity_np(&attr, @sizeOf(c.cpu_set_t), &cpuset);

        const r = c.pthread_create(
            &other_threads[i - 1],
            &attr,
            other_cpu_entry,
            ke.cpus[i],
        );

        if (r != 0) {
            @panic("pthread_create() failed");
        }
    }

    if (ke.ncpus > 1) {
        while (cpus_up.load(.monotonic) < @as(u32, @intCast(ke.ncpus - 1))) {
            std.atomic.spinLoopHint();
        }
    }
}

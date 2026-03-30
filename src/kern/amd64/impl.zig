const b = @import("base");
const ke = b.ke;
const pl = b.pl;
const amd64 = pl.impl;

const std = @import("std");

pub const Cpu = struct {
    self_ptr: *Cpu,
    percpu_offset: usize,
};

pub const ThreadContext = struct {
    rdi: u64,
    rsi: u64,
    rbx: u64,
    rsp: u64,
    rbp: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,

    fn thread_trampoline(entry: usize, arg: usize) callconv(.c) void {
        const entry_fn: *const fn (?*anyopaque) void = @ptrFromInt(entry);
        entry_fn(@ptrFromInt(arg));
        // TODO: This shouldn't be reached!!!
    }

    pub fn init(stack: b.VAddr, stack_size: usize, entry: *const fn (?*anyopaque) void, arg: ?*anyopaque) @This() {
        var ctx: @This() = undefined;
        ctx.rdi = @intFromPtr(entry);
        ctx.rsi = @intFromPtr(arg);

        var sp = stack + stack_size;
        {
            sp -= @sizeOf(usize);
            @as(*usize, @ptrFromInt(sp)).* = 0;

            sp -= @sizeOf(usize);
            @as(*usize, @ptrFromInt(sp)).* = @intFromPtr(&thread_trampoline);
        }
        ctx.rsp = sp;

        return ctx;
    }

    export fn do_switch_to() callconv(.naked) void {
        const asm_template = std.fmt.comptimePrint(
            \\movq %%rbx, {d}(%%rdi)
            \\movq %%rsp, {d}(%%rdi)
            \\movq %%rbp, {d}(%%rdi)
            \\movq %%r12, {d}(%%rdi)
            \\movq %%r13, {d}(%%rdi)
            \\movq %%r14, {d}(%%rdi)
            \\movq %%r15, {d}(%%rdi)
            \\
            \\movq {d}(%%rsi), %%rbx
            \\movq {d}(%%rsi), %%rsp
            \\movq {d}(%%rsi), %%rbp
            \\movq {d}(%%rsi), %%r12
            \\movq {d}(%%rsi), %%r13
            \\movq {d}(%%rsi), %%r14
            \\movq {d}(%%rsi), %%r15
            \\movq {d}(%%rsi), %%rdi
            \\movq {d}(%%rsi), %%rsi
            \\
            \\ret
        , .{
            @offsetOf(ThreadContext, "rbx"),
            @offsetOf(ThreadContext, "rsp"),
            @offsetOf(ThreadContext, "rbp"),
            @offsetOf(ThreadContext, "r12"),
            @offsetOf(ThreadContext, "r13"),
            @offsetOf(ThreadContext, "r14"),
            @offsetOf(ThreadContext, "r15"),

            @offsetOf(ThreadContext, "rbx"),
            @offsetOf(ThreadContext, "rsp"),
            @offsetOf(ThreadContext, "rbp"),
            @offsetOf(ThreadContext, "r12"),
            @offsetOf(ThreadContext, "r13"),
            @offsetOf(ThreadContext, "r14"),
            @offsetOf(ThreadContext, "r15"),
            @offsetOf(ThreadContext, "rdi"),
            @offsetOf(ThreadContext, "rsi"),
        });

        asm volatile (asm_template);
    }

    pub fn switch_to(self: *ThreadContext, new: *ThreadContext) callconv(.c) void {
        asm volatile (
            \\call do_switch_to
            :
            : [_] "{rdi}" (self),
              [_] "{rsi}" (new),
        );
    }
};

inline fn percpu_ptr_for(variable: anytype, cpu: u32) @TypeOf(variable) {
    _ = cpu; // TODO
    @panic("TODO percpu_ptr_for");

    // return @ptrFromInt(@intFromPtr(variable) +% cpu.impl.percpu_offset);
}

pub inline fn percpu_ptr_other(variable: anytype, id: u32) @TypeOf(variable) {
    return percpu_ptr_for(variable, id);
}

pub inline fn percpu_ptr(variable: anytype) @TypeOf(variable) {
    @panic("TODO percpu_ptr");
}

pub inline fn set_hardware_ipl(ipl: ke.Ipl) void {
    asm volatile ("mov %[ipl], %%cr8"
        :
        : [ipl] "r" (@as(u64, @intFromEnum(ipl))),
    );
}

pub inline fn enable_interrupts() void {
    amd64.cpu.sti();
}

pub inline fn disable_interrupts() bool {
    const rflags = amd64.cpu.rflags();

    amd64.cpu.cli();

    return rflags & (1 << 9) != 0;
}

pub inline fn restore_interrupts(state: bool) void {
    if (state) {
        enable_interrupts();
    } else {
        _ = disable_interrupts();
    }
}

pub inline fn send_resched_ipi(_: u32) void {
    @panic("TODO send_resched_ipi");
}

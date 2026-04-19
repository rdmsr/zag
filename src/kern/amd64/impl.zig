const r = @import("root");
const ke = r.ke;
const pl = r.pl;
const amd64 = r.arch;

const std = @import("std");

pub const init = @import("init.zig");
pub const early_init = init.early_init;

pub export var cpu_self_offset: usize linksection(r.percpu) = 0;
pub export var cpu_offsets: [*]usize = undefined;

const ThreadFrame = extern struct {
    rbp: u64 align(1),
    rbx: u64 align(1),
    r12: u64 align(1),
    r13: u64 align(1),
    r14: u64 align(1),
    r15: u64 align(1),
    rip: u64 align(1),
};

extern fn asm_thread_entry() void;

extern fn do_context_switch(old: *ThreadContext, new: *ThreadContext, lock: *u8) callconv(.c) void;

pub const ThreadContext = extern struct {
    rsp: u64 align(1),
    frame: ThreadFrame,

    export fn thread_entry(entry: usize, arg: usize) callconv(.c) void {
        const entry_fn: *const fn (?*anyopaque) void = @ptrFromInt(entry);
        ke.ipl.lower(.Passive);
        entry_fn(@ptrFromInt(arg));
        // TODO: This shouldn't be reached!!!
    }

    pub fn init(stack: r.VAddr, stack_size: usize, entry: *const fn (?*anyopaque) void, arg: ?*anyopaque) @This() {
        var ctx: @This() = undefined;
        var sp: usize = stack + stack_size;

        if (sp % 16 != 0) {
            sp -= (sp % 16);
        }

        const frame: *ThreadFrame = @ptrFromInt(sp - @sizeOf(ThreadFrame));

        frame.* = std.mem.zeroes(ThreadFrame);

        ctx.rsp = @intFromPtr(frame);
        frame.rip = @intFromPtr(&asm_thread_entry);
        frame.r12 = @intFromPtr(entry);
        frame.r13 = @intFromPtr(arg);

        return ctx;
    }

    pub fn switch_to(self: *ThreadContext, new: *ThreadContext) callconv(.c) void {
        const thread: *ke.Thread = @alignCast(@fieldParentPtr("context", self));
        do_context_switch(self, new, &thread.lock.locked);
    }
};

inline fn percpu_ptr_for(variable: anytype, cpu: u32) @TypeOf(variable) {
    return @ptrFromInt(@intFromPtr(variable) +% cpu_offsets[cpu]);
}

pub inline fn percpu_ptr_other(variable: anytype, id: u32) @TypeOf(variable) {
    return percpu_ptr_for(variable, id);
}

pub inline fn percpu_ptr(variable: anytype) @TypeOf(variable) {
    const offset = asm volatile ("mov %%gs:(%[self]), %[out]"
        : [out] "=r" (-> u64),
        : [self] "r" (&cpu_self_offset),
    );

    return @ptrFromInt(offset +% @intFromPtr(variable));
}

pub inline fn set_hardware_ipl(ipl: ke.Ipl) void {
    const cr8_value: u64 = switch (ipl) {
        .Passive, .Dispatch => 0,
        .Device => 13,
        .High => 15,
    };
    asm volatile ("mov %[ipl], %%cr8"
        :
        : [ipl] "r" (cr8_value),
    );
}

pub inline fn enable_interrupts() void {
    amd64.sti();
}

pub inline fn disable_interrupts() bool {
    const ie = amd64.rflags().interrupt_enable;

    amd64.cli();

    return ie;
}

pub inline fn restore_interrupts(state: bool) void {
    if (state) {
        enable_interrupts();
    } else {
        _ = disable_interrupts();
    }
}

pub inline fn send_resched_ipi(target: u32) void {
    pl.impl.send_resched_ipi(target);
}

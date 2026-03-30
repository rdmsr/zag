const std = @import("std");
const b = @import("base");
const c = b.pl.impl.c;
const ke = b.ke;
const ki = ke.private;

fn set_signals(enabled: bool) bool {
    var newmask: c.sigset_t = undefined;
    var oldmask: c.sigset_t = undefined;

    _ = c.sigfillset(&newmask);

    const how = if (enabled) c.SIG_UNBLOCK else c.SIG_BLOCK;

    if (c.pthread_sigmask(how, &newmask, &oldmask) != 0) {
        @panic("pthread_sigmask failed");
    }

    return c.sigismember(&oldmask, c.SIGUSR1) == 0;
}

threadlocal var hard_ipl: ke.Ipl = .Passive;

/// Set the hardware IPL.
pub fn set_hardware_ipl(ipl: ke.Ipl) void {
    // This is a no-op since we handle this in enable_interrupts().
    hard_ipl = ipl;
}

/// Disable interrupts and return the previous state.
pub fn disable_interrupts() bool {
    return set_signals(false);
}

/// Enable interrupts and return the previous state.
pub fn enable_interrupts() bool {
    const ipl_allows_ints = @intFromEnum(hard_ipl) <= @intFromEnum(ke.Ipl.get_max_software());
    return set_signals(ipl_allows_ints);
}

/// Restore an interrupt state.
pub fn restore_interrupts(val: bool) void {
    const ipl_allows_ints = @intFromEnum(hard_ipl) <= @intFromEnum(ke.Ipl.get_max_software());
    _ = set_signals(val and ipl_allows_ints);
}

pub fn send_resched_ipi(cpu: u32) void {
    _ = c.pthread_kill(b.pl.impl.percpu.remote(cpu).pthread, c.SIGUSR1);
}

pub const ThreadContext = struct {
    ucontext: c.ucontext_t,

    fn real_entry(entry_int: c_ulong, arg_int: c_ulong) callconv(.c) void {
        const entry: *const fn (?*anyopaque) void = @ptrFromInt(entry_int);
        const arg: ?*anyopaque = @ptrFromInt(arg_int);
        ke.ipl.lower(.Passive);
        entry(arg);
    }

    pub fn init(stack: b.VAddr, stack_size: usize, entry: *const fn (?*anyopaque) void, arg: ?*anyopaque) ThreadContext {
        var new: ThreadContext = .{ .ucontext = undefined };

        if (c.getcontext(&new.ucontext) == -1) {
            @panic("getcontext() failed");
        }

        new.ucontext.uc_stack.ss_sp = @ptrFromInt(stack);
        new.ucontext.uc_stack.ss_size = stack_size;

        // No successor
        new.ucontext.uc_link = null;

        const entry_int: usize = @intFromPtr(entry);
        const arg_int: usize = @intFromPtr(arg);

        c.makecontext(
            &new.ucontext,
            @ptrCast(&real_entry),
            2,
            @as(c_ulong, entry_int),
            @as(c_ulong, arg_int),
        );
        return new;
    }

    pub fn load(self: *ThreadContext) void {
        _ = c.setcontext(&self.ucontext);
    }

    pub fn switch_to(self: *ThreadContext, new: *ThreadContext) void {
        const thread: *ke.Thread = @fieldParentPtr("context", self);

        thread.lock.release_no_ipl();

        if (c.swapcontext(&self.ucontext, &new.ucontext) == -1) {
            @panic("swapcontext() failed");
        }
    }
};

pub inline fn percpu_ptr_other(variable: anytype, cpu_id: usize) @TypeOf(variable) {
    return @ptrFromInt(@intFromPtr(variable) +% b.pl.impl.cpu_offsets[cpu_id]);
}

pub inline fn percpu_ptr(variable: anytype) @TypeOf(variable) {
    return @ptrFromInt(@intFromPtr(variable) +% b.pl.impl.cpu_offsets[b.pl.impl.my_cpu_id]);
}

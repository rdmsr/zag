const std = @import("std");
const b = @import("base");
const c = b.pl.impl.c;
const ke = b.ke;
const ki = ke.private;

pub const Cpu = struct { pthread: c.pthread_t };

/// Return the current CPU.
pub fn curcpu() *ke.Cpu {
    return b.pl.impl.my_cpu;
}

fn set_signals(enabled: bool) bool {
    var newmask: c.sigset_t = undefined;
    var oldmask: c.sigset_t = undefined;

    _ = c.sigfillset(&newmask);

    const how = if (enabled) c.SIG_BLOCK else c.SIG_UNBLOCK;

    if (c.pthread_sigmask(how, &newmask, &oldmask) != 0) {
        ke.panic("pthread_sigmask failed", .{});
    }

    return std.mem.eql(u8, std.mem.asBytes(&newmask), std.mem.asBytes(&oldmask));
}

/// Set the hardware IPL.
pub fn set_hardware_ipl(ipl: ke.Ipl) void {
    _ = set_signals(@intFromEnum(ipl) > @intFromEnum(ke.Ipl.get_max_software()));
}

/// Disable interrupts and return the previous state.
pub fn disable_interrupts() bool {
    return set_signals(false);
}

/// Enable interrupts and return the previous state.
pub fn enable_interrupts() bool {
    return set_signals(true);
}

/// Restore an interrupt state.
pub fn restore_interrupts(val: bool) void {
    if (val) {
        _ = enable_interrupts();
    } else {
        _ = disable_interrupts();
    }
}

pub fn send_resched_ipi(cpu: *ke.Cpu) void {
    _ = c.pthread_kill(cpu.impl.pthread, c.SIGUSR1);
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
            ke.panic("getcontext() failed", .{});
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
            ke.panic("swapcontext() failed", .{});
        }
    }
};

pub inline fn percpu_ptr_other(variable: anytype, cpu_id: usize) @TypeOf(variable) {
    return @ptrFromInt(@intFromPtr(variable) +% b.pl.impl.cpu_offsets[cpu_id]);
}

pub inline fn percpu_ptr(variable: anytype) @TypeOf(variable) {
    return @ptrFromInt(@intFromPtr(variable) +% b.pl.impl.cpu_offsets[b.pl.impl.my_cpu.id]);
}

const r = @import("root");
const ke = r.ke;
const rv64 = @import("arch");
const std = @import("std");

const int = @import("int.zig");

comptime {
    std.testing.refAllDecls(int);
}

pub const tlb_max_pages = 32;

pub const ThreadContext = extern struct {
    sp: usize,
    ra: usize = 0,
    s: [12]usize = @splat(0),

    pub fn init_with_stack(stack: r.VAddr) @This() {
        return .{ .sp = stack };
    }

    pub fn reset(self: *@This(), stack_top: r.VAddr, entry: *const fn (?*anyopaque) void, arg: ?*anyopaque) @This() {
        self.sp = stack_top & ~@as(usize, 15);
        self.ra = @intFromPtr(&thread_start);
        self.s = @splat(0);
        self.s[1] = @intFromPtr(entry);
        self.s[2] = @intFromPtr(arg);
        return self.*;
    }

    pub fn load(self: *@This()) noreturn {
        riscv_context_load(self);
    }
};

extern fn riscv_context_load(ctx: *ThreadContext) callconv(.c) noreturn;
extern fn riscv_context_switch(old: *ThreadContext, new: *ThreadContext, lock: *u8, switching: *bool) callconv(.c) void;
extern fn riscv_context_switch_cont(old: *ke.Thread.Context, new: *ThreadContext, lock: *u8, switching: *bool) callconv(.c) void;
extern fn thread_start() callconv(.c) noreturn;

export fn riscv_thread_entry(entry_addr: usize, arg_addr: usize) callconv(.c) noreturn {
    const entry: *const fn (?*anyopaque) void = @ptrFromInt(entry_addr);
    entry(@ptrFromInt(arg_addr));
    @panic("Thread entry returned");
}

export fn riscv_free_old_stack(stack: usize) callconv(.c) void {
    ke.private.thread.stack_cache_free(stack);
}

export fn riscv_run_continuation(func_addr: usize, arg: ?*anyopaque) callconv(.c) noreturn {
    ke.ipl.lower(.Passive);
    const func: *const fn (?*anyopaque) void = @ptrFromInt(func_addr);
    func(arg);
    @panic("Continuation returned");
}

pub fn switch_normal_to_normal(old: *ke.Thread.Context, new: *ke.Thread.Context) void {
    const thread: *ke.Thread = @alignCast(@fieldParentPtr("context", old));
    riscv_context_switch(&old.impl, &new.impl, &thread.lock.inner.locked.raw, &thread.switching.raw);
}

pub fn switch_cont_to_normal(old: *ke.Thread.Context, new: *ke.Thread.Context) void {
    const thread: *ke.Thread = @alignCast(@fieldParentPtr("context", old));
    riscv_context_switch_cont(old, &new.impl, &thread.lock.inner.locked.raw, &thread.switching.raw);
}

pub fn call_continuation(ctx: *ke.Thread.Context, continuation: ke.Continuation) noreturn {
    const sp = ctx.stack_top & ~@as(usize, 15);
    asm volatile (
        \\mv sp, %[stack]
        \\mv a0, %[func]
        \\mv a1, %[arg]
        \\tail riscv_run_continuation
        :
        : [stack] "r" (sp),
          [func] "r" (continuation.func),
          [arg] "r" (continuation.arg),
        : .{ .memory = true });
    unreachable;
}

pub inline fn percpu_ptr(variable: anytype) @TypeOf(variable) {
    return variable;
}

pub inline fn percpu_ptr_other(variable: anytype, id: u32) @TypeOf(variable) {
    // TODO: start up harts
    if (id != 0) @panic("secondary harts are not supported");
    return variable;
}

pub fn early_init() void {
    _ = disable_interrupts();
}

pub inline fn raise_software_ipl(new: ke.Ipl, old: *ke.Ipl) bool {
    const current = ke.private.ipl.cpu_ipl.local();
    old.* = current.*;
    current.* = new;
    return new.value() < old.value();
}

pub inline fn lower_software_ipl(new: ke.Ipl, old: *ke.Ipl) bool {
    const current = ke.private.ipl.cpu_ipl.local();
    old.* = current.*;
    current.* = new;
    return new.value() > old.value();
}

pub fn set_hardware_ipl(level: ke.Ipl) void {
    if (level.value() > ke.Ipl.Dispatch.value()) {
        asm volatile ("csrc sie, %[mask]"
            :
            : [mask] "r" (@as(usize, 32)),
            : .{ .memory = true });
    } else {
        asm volatile ("csrs sie, %[mask]"
            :
            : [mask] "r" (@as(usize, 32)),
            : .{ .memory = true });
    }
}

pub inline fn disable_interrupts() bool {
    const old = asm volatile ("csrrc %[old], sstatus, %[mask]"
        : [old] "=r" (-> usize),
        : [mask] "r" (@as(usize, 2)),
        : .{ .memory = true });
    return old & 2 != 0;
}

pub inline fn enable_interrupts() void {
    asm volatile ("csrsi sstatus, 2" ::: .{ .memory = true });
}

pub inline fn restore_interrupts(state: bool) void {
    if (state) enable_interrupts() else _ = disable_interrupts();
}

pub inline fn halt() void {
    asm volatile ("wfi");
}

pub inline fn flush_full_tlb() void {
    rv64.sfence_vma();
}

pub inline fn flush_tlb(va: r.VAddr) void {
    rv64.sfence_vma_page(va);
}

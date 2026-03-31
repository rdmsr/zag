const amd64 = @import("arch");
const std = @import("std");
const b = @import("base");

extern const __interrupt_vectors: [256]usize;

var idt: [256]amd64.IdtEntry align(16) = undefined;

const exception_msg = [32][]const u8{
    "Divide Error",
    "Debug",
    "Non-Maskable Interrupt",
    "Breakpoint",
    "Overflow",
    "Bound Range Exceeded",
    "Invalid Opcode",
    "Device Not Available",
    "Double Fault",
    "Coprocessor Segment Overrun",
    "Invalid TSS",
    "Segment Not Present",
    "Stack-Segment Fault",
    "General Protection Fault",
    "Page Fault",
    "???",
    "x87 Floating-Point Exception",
    "Alignment Check",
    "Machine Check",
    "SIMD Floating-Point Exception",
    "Virtualization Exception",
    "Control Protection Exception",
    "???",
    "???",
    "???",
    "???",
    "???",
    "???",
    "???",
    "???",
    "???",
    "Security Exception",
};

export fn isr_handler_main(frame: *const amd64.IrqFrame) callconv(.{ .x86_64_sysv = .{} }) void {
    if (frame.intno < 32) {
        std.log.info("Unhandled exception: 0x{x} ({s}), err=0x{x}, pc=0x{x}", .{ frame.intno, exception_msg[frame.intno], frame.errcode, frame.rip });
        std.log.info("RAX=0x{x:0>16} RBX=0x{x:0>16} RCX=0x{x:0>16} RDX=0x{x:0>16}", .{ frame.rax, frame.rbx, frame.rcx, frame.rdx });
        std.log.info("RSI=0x{x:0>16} RDI=0x{x:0>16} RBP=0x{x:0>16} RSP=0x{x:0>16}", .{ frame.rsi, frame.rdi, frame.rbp, frame.rsp });
        std.log.info("R8= 0x{x:0>16}  R9=0x{x:0>16} R10=0x{x:0>16} R11=0x{x:0>16}", .{ frame.r8, frame.r9, frame.r10, frame.r11 });
        std.log.info("R12=0x{x:0>16} R13=0x{x:0>16} R14=0x{x:0>16} R15=0x{x:0>16}", .{ frame.r12, frame.r13, frame.r14, frame.r15 });
        const cr2 = amd64.read_cr(2);
        const cr3 = amd64.read_cr(3);
        const rflags = amd64.rflags();
        std.log.info("CR2=0x{x:0>16} CR3=0x{x:0>16} RFLAGS={x}", .{ cr2, cr3, @as(u64, @bitCast(rflags)) });

        @panic("Unhandled exception");
    }
}

extern fn idt_load(idt_ptr: *const amd64.Idtr) callconv(.{ .x86_64_sysv = .{} }) void;

pub fn init() linksection(b.init) void {
    const idtr: amd64.Idtr = .{
        .limit = @sizeOf(@TypeOf(idt)) - 1,
        .base = @intFromPtr(&idt),
    };

    for (&idt, 0..256) |*entry, i| {
        entry.* = .init(0x28, 0, .InterruptGate, __interrupt_vectors[i]);
    }

    idt_load(&idtr);
}

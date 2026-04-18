const amd64 = @import("arch");
const std = @import("std");
const b = @import("base");
const ke = b.ke;
const ki = ke.private;

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
        std.log.err("Unhandled exception: 0x{x} ({s}), err=0x{x}, pc=0x{x}", .{ frame.intno, exception_msg[frame.intno], frame.errcode, frame.rip });
        std.log.err("RAX=0x{x:0>16} RBX=0x{x:0>16} RCX=0x{x:0>16} RDX=0x{x:0>16}", .{ frame.rax, frame.rbx, frame.rcx, frame.rdx });
        std.log.err("RSI=0x{x:0>16} RDI=0x{x:0>16} RBP=0x{x:0>16} RSP=0x{x:0>16}", .{ frame.rsi, frame.rdi, frame.rbp, frame.rsp });
        std.log.err("R8= 0x{x:0>16}  R9=0x{x:0>16} R10=0x{x:0>16} R11=0x{x:0>16}", .{ frame.r8, frame.r9, frame.r10, frame.r11 });
        std.log.err("R12=0x{x:0>16} R13=0x{x:0>16} R14=0x{x:0>16} R15=0x{x:0>16}", .{ frame.r12, frame.r13, frame.r14, frame.r15 });
        const cr2 = amd64.read_cr(2);
        const cr3 = amd64.read_cr(3);
        const rflags = amd64.rflags();

        var buf: [128]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);

        writer.print("0x{x:0>8} [", .{@as(u64, @bitCast(rflags))}) catch {};
        if (rflags.carry) writer.writeAll(" CF") catch {};
        if (rflags.parity) writer.writeAll(" PF") catch {};
        if (rflags.auxiliary) writer.writeAll(" AF") catch {};
        if (rflags.zero) writer.writeAll(" ZF") catch {};
        if (rflags.sign) writer.writeAll(" SF") catch {};
        if (rflags.trap) writer.writeAll(" TF") catch {};
        if (rflags.interrupt_enable) writer.writeAll(" IF") catch {};
        if (rflags.direction) writer.writeAll(" DF") catch {};
        if (rflags.overflow) writer.writeAll(" OF") catch {};
        if (rflags.resume_) writer.writeAll(" RF") catch {};
        if (rflags.virtual_8086_mode) writer.writeAll(" VM") catch {};
        writer.print(" IOPL={d}]", .{rflags.iopl}) catch {};

        std.log.err("CR2=0x{x:0>16} CR3=0x{x:0>16} RFLAGS={s}", .{ cr2, cr3, buf[0..writer.end] });

        ki.panic.panic_with_frame("Unhandled exception", frame.rbp);
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

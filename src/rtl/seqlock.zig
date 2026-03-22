const std = @import("std");
const rtl = @import("rtl");

pub fn SeqLock(comptime T: type) type {
    return struct {
        const Self = @This();

        raw: T,
        sequence: std.atomic.Value(usize),

        pub fn init(val: T) Self {
            return .{ .raw = val, .sequence = .init(0) };
        }

        pub fn load(self: *Self) T {
            var ret: T = undefined;

            while (true) {
                const seq = self.sequence.load(.acquire);
                if (seq & 1 != 0) {
                    std.atomic.spinLoopHint();
                    continue;
                }

                ret = self.raw;

                // Ensure the sequence read happens *after* the data is fully loaded.
                rtl.barrier.rmb();

                if (self.sequence.load(.monotonic) == seq)
                    break;

                std.atomic.spinLoopHint();
            }

            return ret;
        }

        pub fn store(self: *Self, data: T) void {
            const seq = self.sequence.load(.monotonic);

            self.sequence.store(seq + 1, .monotonic);

            // Ensure the data write happens *after* the sequence is incremented.
            rtl.fence.wmb();

            self.raw = data;

            self.sequence.store(seq + 2, .release);
        }
    };
}

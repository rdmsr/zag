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

                // Relaxed load memcpy is needed here since data races are UB.
                rtl.barrier.atomic_load_memcpy(&ret, &self.raw, .monotonic);

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
            rtl.barrier.wmb();

            // Relaxed store memcpy is needed here since data races are UB.
            rtl.barrier.atomic_store_memcpy(&self.raw, &data, .monotonic);

            self.sequence.store(seq + 2, .release);
        }
    };
}

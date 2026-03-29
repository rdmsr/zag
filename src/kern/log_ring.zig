//! Lock-free multi-producer multi-consumer ring buffer designed for kernel logging.
//!
//! # Overview
//!
//! `RingBuffer` is a concurrent ring buffer that allows multiple writers and readers
//! to operate simultaneously without locks, making it safe to use from interrupt and
//! NMI context. It is modelled after Linux's `printk_ringbuffer`, but is simpler (no "committed" state).
//! See linux's printk_ringbuffer.c for more details.
//!
//! The ring buffer is composed of three parallel arrays:
//!
//!   - `descs`  - descriptor ring: tracks the state and data location of each record
//!   - `data`   - data ring: byte storage for the actual messages
//!   - `infos`  - array containing metadata: stores sequence number, timestamp, and length per record
//!
//! `infos` is indexed by descriptor IDs, so it doesn't *really* count as a ring.
//! `head_id` is the ID of the newest descriptor, the last slot claimed by a writer.
//! `tail_id` is the ID of the oldest descriptor, the oldest slot which is the next to be evicted.
//! `tail_id` must always point to a free or published descriptor.
//! The number of live descriptors at any moment is `head_id - tail_id`,
//! when this reaches the maximum descriptor count (`desc_count`), the ring is full and `tail_id` must be advanced.
//! `head_lpos` and `tail_lpos` are the logical positions of the next data block to be written and the oldest data block, respectively.
//!
//! # Descriptor states
//!
//! Each descriptor transitions through the following states:
//!
//!   Reserved -> Published  -> Free
//!
//!   `Reserved`   A writer has claimed this slot and is actively writing.
//!   `Published`  The record is complete and visible to readers.
//!   `Free`       The slot has been recycled and is available for reuse.
//!   `Miss`       Pseudo-state: the slot has been recycled to a newer generation.
//!                Returned when the ID embedded in a descriptor state does not match
//!                the expected ID, indicating the record is gone.
//!
//! # IDs and logical positions
//!
//! Both descriptor IDs and data logical positions (`lpos`) are monotonically
//! increasing integers that never reset. The physical array index is derived
//! by masking off the lower bits:
//!
//!   desc index  =  id   & desc_mask
//!   data index  =  lpos & data_mask
//!
//! The upper bits act as a generation/wrap counter. This means two IDs that map
//! to the same physical slot can always be distinguished by comparing the full
//! integer, which prevents ABA bugs.
//! The `State` atomic packs both the descriptor ID and its state into a single
//! `usize`, allowing both to be read and updated atomically via CAS (a CAS is used to prevent ABA where the generation could overflow):
//!
//!   [ id (upper 62 bits) | state (lower 2 bits) ] (on 64-bit platforms)
//!
//! # Wrap handling
//!
//! Data blocks are never split across the physical boundary of the data array.
//! If an allocation would cross the boundary, the block is placed at offset 0 of
//! the next generation and a stub (containing only the descriptor ID) is left at
//! the original position so the data ring can be walked linearly during eviction.
const std = @import("std");
const base = @import("base");
const rtl = @import("rtl");
const ke = base.ke;
const ki = ke.private;

const BlkPos = struct {
    begin: usize,
    end: usize,
};

const DescState = enum(u2) {
    Reserved = 0,
    Published = 1,
    Free = 2,
    Miss = 3,
};

const usize_bits = @bitSizeOf(usize);
// Id is a monotonically increasing counter. `id & desc_mask` maps to the physical array index.
const Id = std.meta.Int(.unsigned, usize_bits - 2);
const IdSigned = std.meta.Int(.signed, usize_bits - 2);

const State = packed struct(usize) {
    id: Id,
    state: DescState,
};

const Desc = struct {
    state: std.atomic.Value(State),
    blk_pos: BlkPos,
};

pub const Info = struct {
    sequence: u64,
    timestamp: u64,
    length: u16,
};

const Entry = struct {
    id: usize,
    data: *[]u8,
    data_size: u16,
};

const DataBlock = struct {
    id: Id,
    data: [0]u8,
};

pub const Reservation = struct {
    irq_state: bool,
    id: Id,
    info: *Info,
    buf: []u8,
};

pub const ReserveError = error{ NoSpace, ReservationFailed, ZeroSize };
pub const ReadError = error{NotYetAvailable};

// Logical positions are always aligned to `@sizeOf(usize)` (even numbers).
// Thus, 1 (an odd number) is guaranteed to never collide with a real data block position.
const lpos_no_data = 1;

pub fn RingBuffer(data_size_bits: usize, avg_msg_bits: usize) type {
    return struct {
        const data_size = 1 << data_size_bits;
        const desc_bits = data_size_bits - avg_msg_bits;
        const desc_count = 1 << desc_bits;
        const desc_mask = desc_count - 1;
        const data_mask = data_size - 1;

        descs: [desc_count]Desc,
        infos: [desc_count]Info,
        data: [data_size]u8,

        /// ID of the newest descriptor.
        head_id: std.atomic.Value(usize),
        /// ID of the oldest descriptor.
        tail_id: std.atomic.Value(usize),

        /// Logical position of the next (not yet existing) data block.
        head_lpos: std.atomic.Value(usize),

        /// Beginning of the oldest data block.
        tail_lpos: std.atomic.Value(usize),

        const Self = @This();

        // Return the exact Id of the descriptor that occupied this physical slot one generation ago.
        fn prev_wrap(id: Id) Id {
            return id -% desc_count;
        }

        fn get_desc_state(id: Id, expected: State) DescState {
            if (id != expected.id) {
                return .Miss;
            }

            return expected.state;
        }

        // Ensure block sizes are always aligned to usize.
        fn to_block_size(size: usize) usize {
            var sz = size;
            sz += @sizeOf(DataBlock);
            sz = std.mem.alignForward(usize, sz, @sizeOf(usize));
            return sz;
        }

        fn to_desc(self: *Self, id: Id) *Desc {
            return &self.descs[id & desc_mask];
        }

        fn to_info(self: *Self, id: Id) *Info {
            return &self.infos[id & desc_mask];
        }

        fn to_block(self: *Self, lpos: usize) *DataBlock {
            return @ptrCast(@alignCast(&self.data[lpos & data_mask]));
        }

        fn check_size(size: usize) bool {
            // If the size is larger than half of the data buffer, it can never fit in the ring buffer.
            return size <= data_size / 2;
        }

        // Return true if `lpos_current` has not yet reached `lpos_next`.
        // Uses wrapping subtraction so that:
        //   - if lpos_current > lpos_next (another CPU already advanced past the target), returns false.
        //   - if lpos_current == lpos_next (already at target), the -% 1 wraps to usize max, returns false.
        //   - if the distance exceeds data_size (should never happen), returns false.
        fn need_more_space(lpos_current: usize, lpos_next: usize) bool {
            return lpos_next -% lpos_current -% 1 < data_size;
        }

        const ReadDescResult = struct {
            state: DescState,
            seq: u64 = 0,
            desc: Desc = undefined,
        };

        fn read_desc(self: *Self, id: Id) ReadDescResult {
            const desc = self.to_desc(id);
            const info = self.to_info(id);
            var state_var = desc.state.load(.acquire);
            const state = get_desc_state(id, state_var);

            var result: ReadDescResult = .{ .state = state };

            if (state == .Miss or state == .Reserved) {
                result.desc.state.store(state_var, .monotonic);
                return result;
            }

            // Copy descriptor position and state block.
            // Ordering is not critical for the payload copy itself.
            result.desc.blk_pos = desc.blk_pos;
            result.desc.state.store(state_var, .monotonic);

            result.seq = info.sequence;

            // Ensure the copy is finished before the state load.
            rtl.barrier.rmb();

            state_var = desc.state.load(.acquire);
            result.state = get_desc_state(id, state_var);
            result.desc.state.store(state_var, .monotonic);

            return result;
        }

        fn read_desc_finalized(self: *Self, id: Id, seq: u64, desc_out: *Desc) !void {
            const res = self.read_desc(id);
            desc_out.* = res.desc;

            if (res.state == .Miss or res.state == .Reserved or (res.seq != seq)) {
                return error.Invalid;
            }

            if (res.state == .Free or (desc_out.blk_pos.begin == lpos_no_data))
                return error.DataLost;
        }

        fn free_desc(self: *Self, id: Id) void {
            var desc = self.to_desc(id);
            const expected_state: State = .{ .state = .Published, .id = id };
            const new_state: State = .{ .state = .Free, .id = id };

            _ = desc.state.cmpxchgStrong(expected_state, new_state, .release, .monotonic);
        }

        fn free_data(self: *Self, begin: usize, end: usize) ?usize {
            var desc: Desc = undefined;
            var cur_begin = begin;

            while (need_more_space(cur_begin, end)) {
                const blk = self.to_block(cur_begin);

                // Loading the ID here is purposely racey because we check if the descriptor is valid anyway.
                const id: Id = @truncate(@atomicLoad(usize, @as(*usize, @ptrCast(&blk.id)), .monotonic));
                const res = self.read_desc(id);
                desc = res.desc;

                switch (res.state) {
                    .Miss, .Reserved => {
                        // The block is still in use, we can't free it yet.
                        return null;
                    },
                    .Published => {
                        if (desc.blk_pos.begin != cur_begin) {
                            // The descriptor does not point back to the data block, we must've lost a race.
                            return null;
                        }
                        self.free_desc(id);
                    },
                    .Free => {
                        if (desc.blk_pos.begin != cur_begin) {
                            // The descriptor does not point back to the data block, we must've lost a race.
                            return null;
                        }
                    },
                }

                // The block can be freed, move to the next one.
                cur_begin = desc.blk_pos.end;
            }

            return cur_begin;
        }

        fn data_advance_tail(self: *Self, new_tail_lpos: usize) !void {
            if (new_tail_lpos & 1 != 0) {
                // No data.
                return;
            }

            var cur_tail = self.tail_lpos.load(.monotonic);

            // Loop until the tail is at or beyond the new tail position.
            while (need_more_space(cur_tail, new_tail_lpos)) {
                // Invalidate all data blocks before the new tail position.
                if (self.free_data(cur_tail, new_tail_lpos)) |new_tail| {
                    // Successfully freed some blocks, try advancing the tail.
                    if (self.tail_lpos.cmpxchgWeak(cur_tail, new_tail, .release, .monotonic)) |real_cur_tail| {
                        cur_tail = real_cur_tail;
                        std.atomic.spinLoopHint();
                    } else {
                        break;
                    }
                } else {
                    // Failed to free the data, which means we either lost a race or the descriptor is still in use.
                    // Reload the tail position to try again.
                    const new_tail = self.tail_lpos.load(.acquire);
                    if (new_tail == cur_tail) {
                        return error.ReservationFailed;
                    }

                    // Another CPU pushed the tail, try again.
                    cur_tail = new_tail;
                    std.atomic.spinLoopHint();
                    continue;
                }
            }
        }

        // Try advancing the tail.
        fn advance_tail(self: *Self, tail_id: Id) !void {
            const res = self.read_desc(tail_id);
            const tail_desc = res.desc;

            switch (res.state) {
                .Published => {
                    // Free the descriptor.
                    self.free_desc(tail_id);
                },
                .Reserved => {
                    // The descriptor is still reserved, we can't do anything but fail the reservation.
                    return error.ReservationFailed;
                },
                .Miss => {
                    if (tail_desc.state.load(.monotonic).id == prev_wrap(tail_id)) {
                        // This must mean that the descriptor is currently getting reserved by another writer.
                        return error.ReservationFailed;
                    }

                    // Someone else has already advanced the tail, we are good.
                    return;
                },
                .Free => {
                    // The descriptor is already free, we can just advance the tail.
                },
            }

            // Invalidate data blocks
            try self.data_advance_tail(tail_desc.blk_pos.end);

            // Read the next descriptor after tail_id, because the tail must always be in a finalized or free state.
            const next_res = self.read_desc(tail_id +% 1);

            if (next_res.state == .Published or next_res.state == .Free) {
                // Advance the tail to the next descriptor.
                // release: push all previous state changes before the tail update, guaranteeing the new tail is visible after all evictions.
                _ = self.tail_id.cmpxchgStrong(@as(usize, tail_id), @as(usize, tail_id +% 1), .release, .monotonic);
            } else {
                // The next descriptor is not in the desired state.
                // One possibility is that the tail was pushed by another CPU, in which case we are good.
                const tail_id_cur = self.tail_id.load(.acquire);
                if (tail_id_cur != tail_id) {
                    // Another CPU pushed the tail, we are good.
                    return;
                }
                return error.ReservationFailed;
            }
        }

        // Reserve a new descriptor and make space for it if needed.
        fn reserve_desc(self: *Self) !Id {
            var head_id: Id = @truncate(self.head_id.load(.acquire));
            var new_id: Id = undefined;
            var prev_id: Id = undefined;

            while (true) {
                new_id = head_id +% 1;
                prev_id = prev_wrap(new_id);

                // Ordering: acquire pairs with release in advance_tail,
                // guaranteeing we see the tail after any previous evictions.
                const tail_id = self.tail_id.load(.acquire);

                if (prev_id == tail_id) {
                    // Wrapped back to the tail, need to make space by advancing it.
                    try self.advance_tail(prev_id);
                }

                // Ordering: acq_rel to claim head and publish, acquire on failure to retry.
                if (self.head_id.cmpxchgWeak(head_id, new_id, .acq_rel, .acquire)) |val| {
                    head_id = @truncate(val);
                    std.atomic.spinLoopHint();
                } else {
                    break;
                }
            }

            const desc = self.to_desc(new_id);

            // Ordering: monotonic is safe here because acq_rel on head_id published our claim.
            const prev_state = desc.state.load(.monotonic);
            const raw: usize = @bitCast(prev_state);

            if (raw != 0 and get_desc_state(prev_id, prev_state) != .Free) {
                return error.ReservationFailed;
            }

            // Ordering: release ensures all setup is published before making the descriptor reserved.
            if (desc.state.cmpxchgStrong(prev_state, .{ .state = .Reserved, .id = new_id }, .release, .monotonic) != null) {
                return error.ReservationFailed;
            }

            return new_id;
        }

        // Return true if the range [begin, end) crosses the buffer boundary.
        // Compares the generation counters (upper bits) of begin and end-1.
        // The -% 1 ensures a block that fits exactly at the end does not count as wrapping.
        fn data_wraps(begin: usize, end: usize) bool {
            return (begin >> data_size_bits) != ((end -% 1) >> data_size_bits);
        }

        fn get_next_lpos(lpos: usize, size: usize) usize {
            const begin_lpos = lpos;
            const next_lpos = lpos +% size;

            // We never physically split a payload across the ring boundary.
            // If it would cross the boundary, we advance the `lpos` to the next generation boundary
            // so the data can sit contiguously at physical offset 0.
            if (data_wraps(begin_lpos, next_lpos)) {
                return ((next_lpos >> data_size_bits) << data_size_bits) + size;
            }

            return next_lpos;
        }

        fn alloc_data(self: *Self, size: usize, id: Id, out_position: *BlkPos) ReserveError![]u8 {
            const blk_size = to_block_size(size);
            var head_lpos = self.head_lpos.load(.monotonic);
            var new_head_lpos = head_lpos;

            if (size == 0) {
                out_position.begin = lpos_no_data;
                out_position.end = lpos_no_data;
                return error.ZeroSize;
            }

            while (true) {
                new_head_lpos = get_next_lpos(head_lpos, blk_size);

                // Make room if needed, try advancing the tail until we have enough space.
                self.data_advance_tail(new_head_lpos -% data_size) catch |e| {
                    out_position.begin = lpos_no_data;
                    out_position.end = lpos_no_data;
                    return e;
                };

                // Try to claim the new head position.
                if (self.head_lpos.cmpxchgWeak(head_lpos, new_head_lpos, .acq_rel, .acquire)) |real_head_lpos| {
                    head_lpos = real_head_lpos;
                    std.atomic.spinLoopHint();
                } else {
                    break;
                }
            }

            var blk = self.to_block(head_lpos);
            blk.id = id;

            if (data_wraps(head_lpos, new_head_lpos)) {
                // Wrapping blocks store their data at the beginning
                blk = self.to_block(0);
                blk.id = id;
            }

            out_position.begin = head_lpos;
            out_position.end = new_head_lpos;

            return @as([*]u8, @ptrCast(&blk.data))[0..size];
        }

        fn read_internal(self: *Self, seq: u64, buf: ?[]u8) !Info {
            const rdesc = self.to_desc(@truncate(seq));
            const info = self.to_info(@truncate(seq));
            var desc: Desc = undefined;

            const id = rdesc.state.load(.monotonic).id;

            try self.read_desc_finalized(id, seq, &desc);

            const result_info = info.*;

            if (buf) |b| {
                if (desc.blk_pos.begin == lpos_no_data) {
                    return error.DataLost;
                }

                var blk = self.to_block(desc.blk_pos.begin);
                if (data_wraps(desc.blk_pos.begin, desc.blk_pos.end)) {
                    blk = self.to_block(0);
                }

                const data_ptr: [*]u8 = @ptrCast(&blk.data);
                const len = @min(b.len, result_info.length);
                @memcpy(b[0..len], data_ptr[0..len]);
            }

            try self.read_desc_finalized(id, seq, &desc);
            return result_info;
        }

        /// Initialize and return a new ring buffer instance.
        pub fn init() Self {
            // Start near usize max so that the first wrap of the ID/lpos space happens
            // almost immediately, testing overflow handling early rather than after
            // billions of records.
            const dummy_id: Id = 0 -% @as(Id, desc_count + 1);
            const blk0: usize = -%@as(usize, data_size);

            var self: Self = std.mem.zeroes(Self);

            // Place a dummy descriptor in the last slot. head_id and tail_id both start
            // here so that the first reservation (head_id + 1) lands in slot 0, giving
            // the first real record sequence number 0.
            self.descs[desc_count - 1].state.store(.{ .state = .Free, .id = dummy_id }, .monotonic);
            self.descs[desc_count - 1].blk_pos = .{ .begin = lpos_no_data, .end = lpos_no_data };

            self.head_id.store(dummy_id, .monotonic);
            self.tail_id.store(dummy_id, .monotonic);

            // Make it -(desc_count) so that when the slot is first reserved and the sequence is advanced by desc_count,
            // the first record gets sequence number 0.
            self.infos[0].sequence = -%(@as(u64, desc_count));

            self.head_lpos.store(blk0, .monotonic);
            self.tail_lpos.store(blk0, .monotonic);

            return self;
        }

        /// Reserve space for a record and return a reservation.
        pub fn reserve(self: *Self, size: usize) ReserveError!Reservation {
            if (!check_size(size)) {
                return error.NoSpace;
            }

            var reservation: Reservation = undefined;

            reservation.irq_state = ki.impl.disable_interrupts();

            const id = try self.reserve_desc();

            const desc = self.to_desc(id);
            var info = self.to_info(id);
            const seq = info.sequence;

            reservation.id = id;

            if (seq == 0 and (id & desc_mask) != 0) {
                // First time this slot has been used.
                // Slot 0 never hits this branch, its seq is set to -(desc_count)
                // in init() so that the else branch below produces seq=0 on its first use.
                info.sequence = @as(u64, id & desc_mask);
            } else {
                // Slot is being recycled (or is slot 0 on first use).
                // Adding desc_count advances the sequence by one full ring wrap,
                // keeping sequence numbers monotonically increasing across generations.
                info.sequence = seq +% desc_count;
            }

            reservation.buf = self.alloc_data(size, id, &desc.blk_pos) catch |e| {
                // On failure, publish the descriptor as-is to clean up the reservation.
                self.publish(reservation);
                return e;
            };

            reservation.info = info;

            return reservation;
        }

        /// Publish a previously reserved record.
        pub fn publish(self: *Self, res: Reservation) void {
            const desc = self.to_desc(res.id);

            _ = desc.state.cmpxchgStrong(.{ .state = .Reserved, .id = res.id }, .{ .state = .Published, .id = res.id }, .release, .monotonic);

            // Restore IRQ state after publishing the new entry.
            ki.impl.restore_interrupts(res.irq_state);
        }

        /// Return the first readable sequence currently retained by the ring.
        pub fn first_seq(self: *Self) u64 {
            var seq: u64 = undefined;

            while (true) {
                const id: Id = @truncate(self.tail_id.load(.acquire));
                const res = self.read_desc(id);
                seq = res.seq;

                if (res.state == .Published or res.state == .Free) break;
                std.atomic.spinLoopHint();
            }

            return seq;
        }

        /// Read a record at `seq` into `buf`.
        pub fn read(self: *Self, seq: u64, buf: ?[]u8) ReadError!Info {
            var cur_seq = seq;

            while (true) {
                return self.read_internal(cur_seq, buf) catch |err| switch (err) {
                    error.Invalid => {
                        const first = self.first_seq();
                        if (cur_seq < first) {
                            // Behind the tail, catch up and try again.
                            cur_seq = first;
                            continue;
                        }
                        return error.NotYetAvailable;
                    },
                    error.DataLost => {
                        // Record at cur_seq was overwritten, skip forward.
                        const first = self.first_seq();
                        if (cur_seq < first)
                            cur_seq = first
                        else
                            cur_seq += 1;
                        continue;
                    },
                };
            }
        }
    };
}

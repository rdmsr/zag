//! Implementation of a scalable, lock-free hash table.
//! The table is lock-free for read operations and has fine-grained locking on
//! the buckets for write operations.

const std = @import("std");
const rtl = @import("rtl");
const r = @import("root");
const mm = r.mm;
const ex = r.ex;
const ke = r.ke;
const rcu = r.rcu;

/// Atomic state for the table
const State = packed struct(u32) {
    /// The current index.
    current_index: u1,
    _pad0: u7 = 0,
    /// The current shift, equals log2(size)
    current_shift: u5,
    _pad1: u3 = 0,
    /// The new index, if resizing.
    /// If not resizing, then cur == new.
    new_index: u1,
    _pad2: u7 = 0,
    new_shift: u5,
    _pad3: u3 = 0,
};

const Bucket = struct {
    word: std.atomic.Value(usize),

    const Self = @This();

    const lock_tag = 0b01;
    const stop_tag = 0b10;
    const mask = lock_tag | stop_tag;

    const moved = 0 | stop_tag;

    fn is_stop(ptr: usize) bool {
        return (ptr & stop_tag) != 0;
    }

    fn stop_for(head: *anyopaque) usize {
        return @intFromPtr(head) | stop_tag;
    }

    fn load(self: *const Self) usize {
        return self.word.load(.acquire) & ~@as(usize, lock_tag);
    }

    /// Lock the bucket and return the address.
    fn lock(self: *Self) usize {
        while (true) {
            const v = self.word.fetchOr(lock_tag, .acquire);
            if (v & lock_tag == 0) return v;
            while (self.word.load(.monotonic) & lock_tag != 0) {
                std.atomic.spinLoopHint();
            }
        }
    }

    /// Unlock the bucket and store `val`.
    fn unlock(self: *Self, val: usize) void {
        std.debug.assert(val & lock_tag == 0);
        self.word.store(val, .release);
    }

    fn store_locked(self: *Self, val: usize) void {
        std.debug.assert(val & lock_tag == 0);
        self.word.store(val | lock_tag, .release);
    }

    fn unlock_no_changes(self: *Self) void {
        _ = self.word.fetchAnd(~@as(usize, lock_tag), .release);
    }
};

const Which = enum {
    Cur,
    New,
};

/// Describes the resizing policy for the hash table.
const ResizePolicy = enum {
    /// The table will favor aggressive shrinking and long collision chains.
    /// This represents a target chain depth of 4.
    Compact,
    /// The table will allow medium-sized collision chains and will
    /// shrink less aggressively than `Compact`. This represents a
    /// target chain depth of 2
    Balanced,
    /// Same as `Balanced` but the table won't shrink.
    BalancedNoShrink,
    /// The table will never shrink and only allow short collision chains.
    /// This represents a target chain depth of 1.
    Fast,

    fn depth_for(policy: ResizePolicy) usize {
        return switch (policy) {
            .Compact => 4,
            .Balanced, .BalancedNoShrink => 2,
            .Fast => 1,
        };
    }

    /// Chain depth beyond which a bucket is treated as evidence of hash
    /// flooding (or simply a bad hash function) rather than bad luck, and
    /// a reseed should be requested via `rehashing_reseed`.
    ///
    /// With a good, seed-randomized hash, n keys spread over m buckets make
    /// each bucket's occupancy converge to Poisson(lambda), lambda = n/m.
    /// Since a grow always fires before the average depth exceeds
    /// `depth_for(policy)`, using that as lambda is a conservative estimate.
    /// The thresholds below were chosen so that P(X >= k) for that Poisson
    /// distribution is ~1e-14..1e-15, a real hash would need on the order of
    /// a trillion operations to produce a chain this deep by chance.
    fn reseed_depth_for(policy: ResizePolicy) usize {
        return switch (policy) {
            .Compact => 28,
            .Balanced, .BalancedNoShrink => 20,
            .Fast => 16,
        };
    }
};

const rehashing_none: u8 = 0;
const rehashing_running: u8 = 1 << 0;
const rehashing_resize: u8 = 1 << 1;
const rehashing_reseed: u8 = 1 << 2;

const Core = struct {
    /// The current state of the hash table.
    state: std.atomic.Value(State),
    /// One pointer for current buckets, another for new buckets (during resizing).
    buckets: [2]std.atomic.Value([*]Bucket),
    /// One seed for current table, another for the new table.
    seeds: [2]std.atomic.Value(u32),
    elems: std.atomic.Value(u32),
    min_shift: u5,
    policy: ResizePolicy,
    rehash_work: ex.WorkItem,
    rehashing_state: std.atomic.Value(u8),
    smr: *ke.smr.Domain,
    hash_link: *const fn (link: *rcu.SList.Entry, seed: u32) u32,

    const Self = @This();

    fn init(self: *Self, policy: ResizePolicy, min_size: u32) !void {
        const min: u32 = if (policy == .Compact) @max(2, min_size) else @max(16, min_size);

        const start_size = min;

        self.policy = policy;

        const shift: u5 = @intCast(std.math.log2_int_ceil(usize, start_size));
        const size = size_for_shift(shift);

        const arr = try mm.zone.gpa.alloc(Bucket, size);

        for (arr) |*elem| {
            elem.word = .init(Bucket.stop_for(elem));
        }

        self.min_shift = @intCast(std.math.log2_int_ceil(usize, min));

        self.state = .init(.{
            .current_shift = shift,
            .new_shift = shift,
            .current_index = 0,
            .new_index = 0,
        });

        self.rehashing_state = .init(rehashing_none);
        self.elems = .init(0);

        self.buckets[0] = .init(@ptrCast(arr));
        self.seeds[0] = .init(0);
        self.rehash_work.init(.Normal, rehash, self);
    }

    fn migrate_bucket(self: *Self, old: *Bucket, new_array: [*]Bucket, new_seed: u32, new_shift: u5) void {
        // This is called in worker thread context, so we have ample stack size
        // to work with.
        const flat_size = 256;
        var flat: [flat_size]*rcu.SList.Entry = undefined;

        const mask = (@as(u32, 1) << new_shift) - 1;

        var word = old.lock();
        while (!Bucket.is_stop(word)) {
            var n: usize = 0;

            // Fill the flat array with flat_size elements from the chain.
            while (n < flat_size and !Bucket.is_stop(word)) {
                const link: *rcu.SList.Entry = @ptrFromInt(word);
                flat[n] = link;
                n += 1;
                word = link.next.load(.monotonic);
            }

            // Append the chain in reverse to the new array.
            // This is so that readers concurrently traversing this chain don't
            // immediately hit the slow path. Having moved Lk+1..Ln, we get:
            // old head -> L1 -> L2 -> ... -> Lk -> Lk+1 -> [dest(Lk+1) chain]
            // -> stop(dest)
            //
            // If we appended them in the other direction, readers would divert
            // on L1->next immediately and end up spinning until the bucket is
            // fully migrated.
            // We could make this O(n^2) in the case where we have more than
            // flat_size elements by processing chunks in reverse order too,
            // but we can keep this O(n) with the trade-off that readers on
            // large chains might spin a bit longer waiting for moved to
            // show up.
            var j = n;
            while (j > 0) {
                j -= 1;
                const link = flat[j];
                const h = self.hash_link(link, new_seed);
                const head = &new_array[h & mask];
                const next = head.lock();
                link.next.store(next, .monotonic);
                head.unlock(@intFromPtr(link));
            }
        }

        old.unlock(Bucket.moved);
    }

    fn enqueue_rehash(self: *Self, reason: u8) void {
        const prev = self.rehashing_state.fetchOr(reason, .monotonic);

        if (prev == rehashing_none) {
            ex.work.enqueue(&self.rehash_work);
        }
    }

    fn rehash(ptr: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr.?));

        while (true) {
            const reason = self.rehashing_state.swap(rehashing_running, .monotonic);

            const elems = self.elems.load(.monotonic);
            const state = self.state.load(.monotonic);
            const size = size_for_shift(state.current_shift);

            if (self.should_grow(elems, size) or self.should_shrink(elems, size)) {
                self.resize(self.target_shift_for(elems));
            } else if (reason & rehashing_reseed != 0) {
                self.resize(state.current_shift);
            }

            _ = self.rehashing_state.cmpxchgStrong(
                rehashing_running,
                rehashing_none,
                .monotonic,
                .monotonic,
            ) orelse break;
        }
    }

    fn resize(self: *Self, new_shift: u5) void {
        var state = self.state.load(.monotonic);
        state.new_shift = new_shift;

        const old_size = size_for_shift(state.current_shift);
        const old_idx = state.current_index;

        // Get the other index.
        state.new_index = ~state.current_index;
        const new_size = size_for_shift(state.new_shift);

        const old_array = self.buckets[state.current_index].load(.monotonic);
        const new_array = mm.zone.gpa.alloc(Bucket, new_size) catch return;

        // FIXME: cryptographically secure seed.
        const new_seed = 0;

        // 1. Prepare the new array and publish it.
        for (new_array) |*elem| {
            elem.word = .init(Bucket.stop_for(elem));
        }

        self.buckets[state.new_index].store(new_array.ptr, .monotonic);
        self.seeds[state.new_index].store(new_seed, .monotonic);
        self.state.store(state, .release);

        // 2. Migrate all buckets.
        for (0..old_size) |i| {
            self.migrate_bucket(
                &old_array[i],
                new_array.ptr,
                new_seed,
                state.new_shift,
            );
        }

        // 3. Publish the new state, wait for readers to finish and then
        // free the old array.
        state.current_index = state.new_index;
        state.current_shift = state.new_shift;
        self.state.store(state, .release);

        ke.smr.synchronize(self.smr);

        self.buckets[old_idx].store(undefined, .monotonic);

        mm.zone.gpa.free(old_array[0..old_size]);
    }

    /// Remove a given element from the table, SMR must be entered.
    fn remove(self: *Self, link: *rcu.SList.Entry) void {
        var state = self.state.load(.acquire);
        var h = self.hash_link(link, self.seeds[state.current_index].load(.monotonic));

        var b = self.bucket(state, .Cur, h);

        var first = b.lock();

        if (first == Bucket.moved) {
            @branchHint(.unlikely);
            b.unlock_no_changes();

            // Get the new state instead.
            state = self.state.load(.acquire);
            h = self.hash_link(link, self.seeds[state.new_index].load(.monotonic));
            b = self.bucket(state, .New, h);
            first = b.lock();
        }

        var word = first;
        var prev: *rcu.SList.Entry = undefined;

        while (!Bucket.is_stop(word)) {
            const l: *rcu.SList.Entry = @ptrFromInt(word);
            if (l == link) {
                break;
            }
            prev = l;
            word = l.next.load(.monotonic);
        }

        const next = link.next.load(.monotonic);
        const elems = self.elems.fetchSub(1, .monotonic);

        if (word == first) {
            // We are removing the head, swap it with its next element.
            b.unlock(next);
        } else {
            prev.next.store(next, .monotonic);
            b.unlock_no_changes();
        }

        const size = size_for_shift(state.current_shift);

        if (self.should_shrink(elems, size)) {
            // We should shrink
            self.enqueue_rehash(rehashing_resize);
        }
    }

    fn bucket(self: *Self, state: State, which: Which, h: u32) *Bucket {
        const idx: usize, const shift: u5 = switch (which) {
            .Cur => .{ state.current_index, @intCast(state.current_shift) },
            .New => .{ state.new_index, @intCast(state.new_shift) },
        };
        const array = self.buckets[idx].load(.monotonic);
        const mask = (@as(u32, 1) << shift) - 1;
        return &array[h & mask];
    }

    fn size_for_shift(shift: u5) u32 {
        return @as(u32, 1) << shift;
    }

    fn should_grow(self: *Self, elems: u32, size: u32) bool {
        const target_depth = ResizePolicy.depth_for(self.policy);
        return elems > target_depth * size;
    }

    fn should_shrink(self: *Self, elems: u32, size: u32) bool {
        const min_size = size_for_shift(self.min_shift);

        return switch (self.policy) {
            // Compact only allows half of the slots to be empty.
            .Compact => size > elems * 2 and size > min_size,
            // Balanced allows 75% of the slots to be empty.
            .Balanced => size > elems * 4 and size > min_size,
            .Fast, .BalancedNoShrink => false,
        };
    }

    fn target_shift_for(self: *Self, elems: u32) u5 {
        const depth = ResizePolicy.depth_for(self.policy);
        const needed = std.math.divCeil(usize, elems, depth) catch unreachable;

        var shift = self.min_shift;
        while (size_for_shift(shift) < needed) : (shift += 1) {}
        return shift;
    }
};

/// Scalable, lock-free hashtable backed by SMR.
pub fn Table(comptime T: type, comptime link_field: []const u8, comptime Context: type) type {
    comptime rtl.assert_interface(Context, struct {
        pub const Key = Context.Key;
        pub fn hash(key: Key, seed: usize) u32 {
            _ = key;
            _ = seed;
            unreachable;
        }
        pub fn eql(a: Key, b: Key) bool {
            _ = a;
            _ = b;
            unreachable;
        }
        pub fn key_of(obj: *T) Key {
            _ = obj;
            unreachable;
        }
    });

    return struct {
        core: Core,
        const Self = @This();

        /// Initialize a new table, `min_size` provides the minimum count of
        /// buckets. If `min_size` is 0, it will get clamped to sane defaults
        /// depending on the chosen policy.
        pub fn init(self: *Self, policy: ResizePolicy, min_size: u32) !void {
            try self.core.init(policy, min_size);
            self.core.hash_link = hash_link;
        }

        /// Get an element given a key, SMR must be entered.
        pub fn get(self: *Self, key: Context.Key) ?*T {
            const state = self.core.state.load(.acquire);
            const h = Context.hash(key, self.core.seeds[state.current_index].load(.monotonic));
            const b = self.core.bucket(state, .Cur, h);

            var word = b.load();

            while (!Bucket.is_stop(word)) {
                const link: *rcu.SList.Entry = @ptrFromInt(word);

                const obj = link_to_obj(link);
                if (Context.eql(Context.key_of(obj), key)) {
                    return obj;
                }
                word = link.next.load(.monotonic);
            }

            if (word != Bucket.stop_for(b)) {
                // We got to the end and didn't find the 'stop' marker,
                // this means the walk was incoherent (may have gotten migrated)
                // and we have to go through the slow path.
                @branchHint(.unlikely);
                return self.get_slow(key, b);
            }

            // We got to the end successfully and found nothing.
            return null;
        }

        /// Find an element or insert it given a key, SMR must be entered.
        pub fn get_or_insert(
            self: *Self,
            key: Context.Key,
            value: *rcu.SList.Entry,
        ) ?*T {
            var state = self.core.state.load(.acquire);
            var h = Context.hash(key, self.core.seeds[state.current_index].load(.monotonic));
            var b = self.core.bucket(state, .Cur, h);

            var first = b.lock();

            if (first == Bucket.moved) {
                @branchHint(.unlikely);
                b.unlock_no_changes();

                // Get the new state instead.
                state = self.core.state.load(.acquire);
                h = Context.hash(key, self.core.seeds[state.new_index].load(.monotonic));
                b = self.core.bucket(state, .New, h);
                first = b.lock();
            }

            var word = first;
            var depth: usize = 0;

            // Try finding the object.
            while (!Bucket.is_stop(word)) {
                const link: *rcu.SList.Entry = @ptrFromInt(word);
                const obj = link_to_obj(link);
                if (Context.eql(Context.key_of(obj), key)) {
                    b.unlock_no_changes();
                    return obj;
                }
                word = link.next.load(.monotonic);
                depth += 1;
            }

            const elms = self.core.elems.fetchAdd(1, .monotonic);

            // Add the value onto the list, we set its next value first
            // then publish it as the head of the bucket using unlock().
            // Relaxed ordering is fine since unlock() here uses release.
            value.next.store(first, .monotonic);
            b.unlock(@intFromPtr(value));

            const size = Core.size_for_shift(state.current_shift);

            const max_depth = ResizePolicy.reseed_depth_for(self.core.policy);

            if (depth >= max_depth) {
                self.core.enqueue_rehash(rehashing_reseed);
            } else if (self.core.should_grow(elms, size)) {
                // We should grow.
                self.core.enqueue_rehash(rehashing_resize);
            }

            return null;
        }

        /// Remove a given element from the table, SMR must be entered.
        pub fn remove(self: *Self, link: *rcu.SList.Entry) void {
            self.core.remove(link);
        }

        fn get_slow(self: *Self, key: Context.Key, bucket: *Bucket) ?*T {
            // Wait until the bucket finishes moving.
            while (bucket.word.load(.monotonic) != Bucket.moved) {
                std.atomic.spinLoopHint();
            }

            // Now do the same as in get(), but with the new state.
            const state = self.core.state.load(.acquire);
            const h = Context.hash(key, self.core.seeds[state.new_index].load(.monotonic));
            const b = self.core.bucket(state, .New, h);

            var word: usize = b.load();
            while (!Bucket.is_stop(word)) {
                const link: *rcu.SList.Entry = @ptrFromInt(word);
                const obj = link_to_obj(link);
                if (Context.eql(Context.key_of(obj), key)) {
                    return obj;
                }
                word = link.next.load(.monotonic);
            }

            // Not found.
            return null;
        }

        fn hash_link(link: *rcu.SList.Entry, seed: u32) u32 {
            return Context.hash(Context.key_of(link_to_obj(link)), seed);
        }

        fn link_to_obj(link: *rcu.SList.Entry) *T {
            return @fieldParentPtr(link_field, link);
        }
    };
}

const std = @import("std");

fn get_closest_type(comptime N: usize) type {
    const bits = std.math.ceilPowerOfTwo(usize, N) catch unreachable;
    return @Int(.unsigned, bits);
}

fn bit_mask(comptime Word: type, bit_index: usize) Word {
    return @as(Word, 1) << @truncate(bit_index);
}

/// Static bitmap that uses the most efficient underlying word size for N < 64
pub fn BitMap(comptime N: usize) type {
    return struct {
        pub const Word = if (N > 32) u64 else get_closest_type(N);
        const Self = @This();
        const bits_per_word = @bitSizeOf(Word);
        const arr_len = (N + bits_per_word - 1) / bits_per_word;

        storage: [arr_len]Word,

        fn valid_word_mask(word_index: usize) Word {
            std.debug.assert(word_index < arr_len);

            if (word_index != arr_len - 1) return std.math.maxInt(Word);

            const rem = N % bits_per_word;
            if (rem == 0) return std.math.maxInt(Word);
            return (@as(Word, 1) << @truncate(rem)) - 1;
        }

        /// Initialize a bitmap, setting all bits to `val`.
        pub fn init(val: bool) Self {
            return .{
                .storage = @splat(if (val) std.math.maxInt(Self.Word) else 0),
            };
        }

        /// Set a given bit.
        pub fn set(self: *Self, bit: usize) void {
            std.debug.assert(bit < N);
            const word_index = bit / Self.bits_per_word;
            const bit_index = bit % Self.bits_per_word;

            self.storage[word_index] |= bit_mask(Word, bit_index);
        }

        /// Clear a given bit.
        pub fn clear(self: *Self, bit: usize) void {
            std.debug.assert(bit < N);
            const word_index = bit / Self.bits_per_word;
            const bit_index = bit % Self.bits_per_word;
            self.storage[word_index] &= ~bit_mask(Word, bit_index);
        }

        /// Get a given bit.
        pub fn get(self: *const Self, bit: usize) bool {
            std.debug.assert(bit < N);
            const word_index = bit / Self.bits_per_word;
            const bit_index = bit % Self.bits_per_word;
            return self.storage[word_index] & bit_mask(Word, bit_index) != 0;
        }

        /// Count the number of set bits in the bitmap.
        pub fn count(self: *const Self) usize {
            var total: usize = 0;
            for (self.storage, 0..) |word, i| {
                total += @intCast(@popCount(word & valid_word_mask(i)));
            }
            return total;
        }

        pub const Iterator = struct {
            bitmap: *const Self,
            word_index: usize = 0,
            word: Word = 0,

            /// Return the index of the next set bit, or null when exhausted.
            pub fn next(self: *Iterator) ?usize {
                while (true) {
                    if (self.word != 0) {
                        const bit_index: usize = @intCast(@ctz(self.word));
                        self.word &= self.word - 1;
                        return ((self.word_index - 1) * bits_per_word) + bit_index;
                    }

                    if (self.word_index >= arr_len) return null;

                    self.word = self.bitmap.storage[self.word_index] & valid_word_mask(self.word_index);
                    self.word_index += 1;
                }
            }
        };

        /// Iterate over the indexes of set bits in ascending order.
        pub fn iter(self: *const Self) Iterator {
            return .{ .bitmap = self };
        }

        /// Check whether all bits in the bitmap are equal to a given value.
        pub fn is_all(self: *const Self, value: bool) bool {
            const v: Self.Word = if (value) std.math.maxInt(Self.Word) else 0;
            for (self.storage) |word| {
                if (word != v) return false;
            }
            return true;
        }
    };
}

/// Atomic static bitmap with the same API as `BitMap`, but each operation accepts a memory ordering.
pub fn AtomicBitMap(comptime N: usize) type {
    return struct {
        pub const Word = if (N > 32) u64 else get_closest_type(N);
        const Self = @This();
        const bits_per_word = @bitSizeOf(Word);
        const arr_len = (N + bits_per_word - 1) / bits_per_word;

        storage: [arr_len]std.atomic.Value(Word),

        fn valid_word_mask(word_index: usize) Word {
            std.debug.assert(word_index < arr_len);

            if (word_index != arr_len - 1) return std.math.maxInt(Word);

            const rem = N % bits_per_word;
            if (rem == 0) return std.math.maxInt(Word);
            return (@as(Word, 1) << @truncate(rem)) - 1;
        }

        /// Initialize a bitmap, setting all bits to `val`.
        pub fn init(val: bool) Self {
            var storage: [arr_len]std.atomic.Value(Word) = undefined;
            const word: Word = if (val) std.math.maxInt(Self.Word) else 0;
            inline for (&storage) |*elem| {
                elem.* = std.atomic.Value(Word).init(word);
            }
            return .{ .storage = storage };
        }

        /// Set a given bit.
        pub fn set(self: *Self, bit: usize, comptime ordering: std.builtin.AtomicOrder) void {
            std.debug.assert(bit < N);
            const word_index = bit / Self.bits_per_word;
            const bit_index = bit % Self.bits_per_word;

            _ = self.storage[word_index].fetchOr(bit_mask(Word, bit_index), ordering);
        }

        /// Clear a given bit.
        pub fn clear(self: *Self, bit: usize, comptime ordering: std.builtin.AtomicOrder) void {
            std.debug.assert(bit < N);
            const word_index = bit / Self.bits_per_word;
            const bit_index = bit % Self.bits_per_word;

            _ = self.storage[word_index].fetchAnd(~bit_mask(Word, bit_index), ordering);
        }

        /// Get a given bit.
        pub fn get(self: *const Self, bit: usize, comptime ordering: std.builtin.AtomicOrder) bool {
            std.debug.assert(bit < N);
            const word_index = bit / Self.bits_per_word;
            const bit_index = bit % Self.bits_per_word;
            return self.storage[word_index].load(ordering) & bit_mask(Word, bit_index) != 0;
        }

        /// Count the number of set bits in the bitmap.
        pub fn count(self: *const Self, comptime ordering: std.builtin.AtomicOrder) usize {
            var total: usize = 0;
            for (self.storage, 0..) |word, i| {
                total += @intCast(@popCount(word.load(ordering) & valid_word_mask(i)));
            }
            return total;
        }

        pub fn Iterator(comptime ordering: std.builtin.AtomicOrder) type {
            return struct {
                bitmap: *const Self,
                word_index: usize = 0,
                word: Word = 0,

                /// Return the index of the next set bit, or null when exhausted.
                pub fn next(self: *@This()) ?usize {
                    while (true) {
                        if (self.word != 0) {
                            const bit_index: usize = @intCast(@ctz(self.word));
                            self.word &= self.word - 1;
                            return ((self.word_index - 1) * bits_per_word) + bit_index;
                        }

                        if (self.word_index >= arr_len) return null;

                        self.word = self.bitmap.storage[self.word_index].load(ordering) & valid_word_mask(self.word_index);
                        self.word_index += 1;
                    }
                }
            };
        }

        /// Iterate over the indexes of set bits in ascending order.
        pub fn iter(self: *const Self, comptime ordering: std.builtin.AtomicOrder) Iterator(ordering) {
            return .{ .bitmap = self };
        }

        /// Check whether all bits in the bitmap are equal to a given value.
        pub fn is_all(self: *const Self, value: bool, comptime ordering: std.builtin.AtomicOrder) bool {
            const v: Self.Word = if (value) std.math.maxInt(Self.Word) else 0;
            for (self.storage) |word| {
                if (word.load(ordering) != v) return false;
            }
            return true;
        }
    };
}

test "BitMap has proper underlying type" {
    std.debug.assert(BitMap(8).Word == u8);
    std.debug.assert(BitMap(10).Word == u16);
    std.debug.assert(BitMap(16).Word == u16);
    std.debug.assert(BitMap(21).Word == u32);
    std.debug.assert(BitMap(32).Word == u32);
    std.debug.assert(BitMap(64).Word == u64);
    std.debug.assert(BitMap(128).Word == u64);
    std.debug.assert(BitMap(1024).Word == u64);
}

test BitMap {
    var bitmap = BitMap(10).init(false);

    std.debug.assert(@TypeOf(bitmap).Word == u16);
    std.debug.assert(bitmap.get(0) == false);
    bitmap.set(0);

    std.debug.assert(bitmap.get(0) == true);

    bitmap.clear(0);

    std.debug.assert(bitmap.get(0) == false);
}

test "BitMap count and iter" {
    var bitmap = BitMap(70).init(false);

    std.debug.assert(bitmap.count() == 0);
    {
        var it = bitmap.iter();
        std.debug.assert(it.next() == null);
    }

    bitmap.set(0);
    bitmap.set(3);
    bitmap.set(63);
    bitmap.set(64);
    bitmap.set(69);

    std.debug.assert(bitmap.count() == 5);

    var it = bitmap.iter();
    std.debug.assert(it.next().? == 0);
    std.debug.assert(it.next().? == 3);
    std.debug.assert(it.next().? == 63);
    std.debug.assert(it.next().? == 64);
    std.debug.assert(it.next().? == 69);
    std.debug.assert(it.next() == null);

    bitmap.clear(63);

    std.debug.assert(bitmap.count() == 4);

    var all = BitMap(70).init(true);
    std.debug.assert(all.count() == 70);

    var all_it = all.iter();
    var expected: usize = 0;
    while (all_it.next()) |bit| : (expected += 1) {
        std.debug.assert(bit == expected);
    }
    std.debug.assert(expected == 70);
}

test AtomicBitMap {
    var bitmap = AtomicBitMap(10).init(false);

    std.debug.assert(@TypeOf(bitmap).Word == u16);
    std.debug.assert(bitmap.get(0, .seq_cst) == false);
    bitmap.set(0, .seq_cst);

    std.debug.assert(bitmap.get(0, .seq_cst) == true);
    std.debug.assert(bitmap.is_all(false, .seq_cst) == false);

    bitmap.clear(0, .seq_cst);

    std.debug.assert(bitmap.get(0, .seq_cst) == false);
    std.debug.assert(bitmap.is_all(false, .seq_cst) == true);
}

test "AtomicBitMap count and iter" {
    var bitmap = AtomicBitMap(70).init(false);

    std.debug.assert(bitmap.count(.seq_cst) == 0);
    {
        var it = bitmap.iter(.seq_cst);
        std.debug.assert(it.next() == null);
    }

    bitmap.set(0, .seq_cst);
    bitmap.set(3, .seq_cst);
    bitmap.set(63, .seq_cst);
    bitmap.set(64, .seq_cst);
    bitmap.set(69, .seq_cst);

    std.debug.assert(bitmap.count(.seq_cst) == 5);

    var it = bitmap.iter(.seq_cst);
    std.debug.assert(it.next().? == 0);
    std.debug.assert(it.next().? == 3);
    std.debug.assert(it.next().? == 63);
    std.debug.assert(it.next().? == 64);
    std.debug.assert(it.next().? == 69);
    std.debug.assert(it.next() == null);

    bitmap.clear(63, .seq_cst);

    std.debug.assert(bitmap.count(.seq_cst) == 4);

    var all = AtomicBitMap(70).init(true);
    std.debug.assert(all.count(.seq_cst) == 70);

    var all_it = all.iter(.seq_cst);
    var expected: usize = 0;
    while (all_it.next()) |bit| : (expected += 1) {
        std.debug.assert(bit == expected);
    }
    std.debug.assert(expected == 70);
}

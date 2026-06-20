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

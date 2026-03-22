//! Intrusive Pairing Heap implementation.
const std = @import("std");

pub const Node = struct {
    child: ?*Node = null,
    next: ?*Node = null,
    prev: ?*Node = null,
};

pub fn PairingHeap(comptime order: enum { min, max }, comptime cmp: fn (*Node, *Node) std.math.Order) type {
    return struct {
        const Self = @This();

        /// Number of elements in the heap
        size: usize = 0,

        /// Topmost element of the heap
        root: ?*Node = null,

        fn meld(a: *Node, b: *Node) *Node {
            const a_wins = switch (order) {
                .min => cmp(a, b) != .gt, // a <= b
                .max => cmp(a, b) == .gt, // a > b
            };

            if (a_wins) {
                if (a.child) |c| {
                    c.prev = b;
                }

                b.next = a.child;
                a.child = b;
                b.prev = a;
                return a;
            }

            if (b.child) |c| {
                c.prev = a;
            }

            a.prev = b;
            a.next = b.child;
            b.child = a;
            return b;
        }

        fn merge_pairs(node: *Node) *Node {
            // First pass: pair up siblings left to right
            var list: ?*Node = node;
            var pairs: ?*Node = null;

            while (list) |a| {
                const b = a.next orelse {
                    a.next = pairs;
                    a.prev = null;
                    pairs = a;
                    break;
                };
                list = b.next;

                a.next = null;
                a.prev = null;
                b.next = null;
                b.prev = null;

                const merged = meld(a, b);
                merged.next = pairs;
                merged.prev = null;
                pairs = merged;
            }

            // Second pass: fold pairs right to left
            var result = pairs.?;
            var rest = result.next;
            result.next = null;
            while (rest) |p| {
                rest = p.next;
                p.next = null;
                result = meld(result, p);
            }
            return result;
        }

        pub fn init() Self {
            return .{
                .size = 0,
                .root = null,
            };
        }

        /// Insert `node` into the heap.
        pub fn insert(self: *Self, node: *Node) void {
            node.* = .{
                .child = null,
                .next = null,
                .prev = null,
            };

            self.size += 1;

            if (self.root == null) {
                self.root = node;
                return;
            }

            self.root = meld(self.root.?, node);
        }

        /// Return and remove the topmost element.
        pub fn pop(self: *Self) ?*Node {
            const root = self.root orelse return null;
            const child = root.child;

            root.child = null;
            self.size -= 1;

            if (child) |c| {
                c.prev = null;
                self.root = merge_pairs(c);
            } else {
                self.root = null;
            }

            return root;
        }

        /// Remove `node` from the heap.
        pub fn remove(self: *Self, node: *Node) void {
            if (self.root == node) {
                _ = self.pop();
                return;
            }

            std.debug.assert(self.root != null);

            self.size -= 1;

            // Unlink the node
            if (node.next) |n| {
                n.prev = node.prev;
            }

            if (node.prev) |p| {
                if (p.child == node) {
                    // node was leftmost child
                    p.child = node.next;
                } else {
                    // node was a sibling
                    p.next = node.next;
                }
            }

            node.prev = null;
            node.next = null;

            // Merge node's children back into the heap
            if (node.child) |c| {
                c.prev = null;
                self.root = meld(self.root.?, merge_pairs(c));
            }

            node.child = null;
        }
    };
}
const TestNode = struct {
    value: u32,
    node: Node = .{},
};

fn my_cmp(a: *Node, b: *Node) std.math.Order {
    const ta: *TestNode = @fieldParentPtr("node", a);
    const tb: *TestNode = @fieldParentPtr("node", b);
    return std.math.order(ta.value, tb.value);
}

const MinHeap = PairingHeap(.min, my_cmp);
const MaxHeap = PairingHeap(.max, my_cmp);

test "empty heap" {
    var heap = MinHeap.init();
    try std.testing.expect(heap.root == null);
    try std.testing.expectEqual(0, heap.size);
    try std.testing.expect(heap.pop() == null);
}

test "single element insert and pop" {
    var heap = MinHeap.init();
    var a = TestNode{ .value = 42 };

    heap.insert(&a.node);
    try std.testing.expectEqual(1, heap.size);

    const top: *TestNode = @fieldParentPtr("node", heap.root.?);
    try std.testing.expectEqual(42, top.value);

    _ = heap.pop();
    try std.testing.expect(heap.root == null);
    try std.testing.expectEqual(0, heap.size);
    try std.testing.expect(heap.pop() == null);
}

test "min heap ordering" {
    var heap = MinHeap.init();
    var a = TestNode{ .value = 3 };
    var b = TestNode{ .value = 1 };
    var c = TestNode{ .value = 2 };

    heap.insert(&a.node);
    heap.insert(&b.node);
    heap.insert(&c.node);
    try std.testing.expectEqual(3, heap.size);

    const first: *TestNode = @fieldParentPtr("node", heap.pop().?);
    try std.testing.expectEqual(1, first.value);

    const second: *TestNode = @fieldParentPtr("node", heap.pop().?);
    try std.testing.expectEqual(2, second.value);

    const third: *TestNode = @fieldParentPtr("node", heap.pop().?);
    try std.testing.expectEqual(3, third.value);

    try std.testing.expect(heap.pop() == null);
}

test "max heap ordering" {
    var heap = MaxHeap.init();
    var a = TestNode{ .value = 3 };
    var b = TestNode{ .value = 1 };
    var c = TestNode{ .value = 2 };

    heap.insert(&a.node);
    heap.insert(&b.node);
    heap.insert(&c.node);

    const first: *TestNode = @fieldParentPtr("node", heap.pop().?);
    try std.testing.expectEqual(3, first.value);

    const second: *TestNode = @fieldParentPtr("node", heap.pop().?);
    try std.testing.expectEqual(2, second.value);

    const third: *TestNode = @fieldParentPtr("node", heap.pop().?);
    try std.testing.expectEqual(1, third.value);
}

test "remove middle node" {
    var heap = MinHeap.init();
    var a = TestNode{ .value = 1 };
    var b = TestNode{ .value = 2 };
    var c = TestNode{ .value = 3 };

    heap.insert(&a.node);
    heap.insert(&b.node);
    heap.insert(&c.node);

    heap.remove(&b.node);
    try std.testing.expectEqual(2, heap.size);

    const first: *TestNode = @fieldParentPtr("node", heap.pop().?);
    try std.testing.expectEqual(1, first.value);

    const second: *TestNode = @fieldParentPtr("node", heap.pop().?);
    try std.testing.expectEqual(3, second.value);

    try std.testing.expect(heap.pop() == null);
}

test "remove root" {
    var heap = MinHeap.init();
    var a = TestNode{ .value = 1 };
    var b = TestNode{ .value = 2 };
    var c = TestNode{ .value = 3 };

    heap.insert(&a.node);
    heap.insert(&b.node);
    heap.insert(&c.node);

    heap.remove(&a.node);
    try std.testing.expectEqual(2, heap.size);

    const top: *TestNode = @fieldParentPtr("node", heap.root.?);
    try std.testing.expectEqual(2, top.value);
}

test "remove last element" {
    var heap = MinHeap.init();
    var a = TestNode{ .value = 1 };

    heap.insert(&a.node);
    heap.remove(&a.node);
    try std.testing.expectEqual(0, heap.size);
    try std.testing.expect(heap.root == null);
}

test "duplicate values" {
    var heap = MinHeap.init();
    var a = TestNode{ .value = 1 };
    var b = TestNode{ .value = 1 };
    var c = TestNode{ .value = 1 };

    heap.insert(&a.node);
    heap.insert(&b.node);
    heap.insert(&c.node);
    try std.testing.expectEqual(3, heap.size);

    _ = heap.pop();
    _ = heap.pop();
    _ = heap.pop();
    try std.testing.expectEqual(0, heap.size);
    try std.testing.expect(heap.pop() == null);
}

test "large sequence" {
    var heap = MinHeap.init();
    var nodes: [16]TestNode = undefined;

    for (&nodes, 0..) |*n, i| {
        n.* = .{ .value = @intCast(16 - i) };
        heap.insert(&n.node);
    }

    try std.testing.expectEqual(16, heap.size);

    var prev: u32 = 0;
    while (heap.pop()) |n| {
        const t: *TestNode = @fieldParentPtr("node", n);
        try std.testing.expect(t.value >= prev);
        prev = t.value;
    }
    try std.testing.expectEqual(0, heap.size);
}

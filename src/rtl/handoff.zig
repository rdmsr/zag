//! Lock-free singly linked list with an activation callback when items are first inserted.
//! This is meant for use where there is a set of objects being worked upon in an
//! asynchronous context.
//! Data structure generalized from the NT kernel reaper lists, and inspired by
//! MINTIA's custody list (https://github.com/xrarch/mintia2/blob/main/OS/Executive/Ke/KeCustodyList.jkl)

const std = @import("std");

pub const HandoffList = struct {
    const ActivationFn = *const fn (*Self) void;

    const Self = @This();

    /// Non-null value indicating processing is in progress.
    const processing_tag: *anyopaque = @ptrFromInt(1);

    activation: ActivationFn,
    head: std.atomic.Value(?*anyopaque),

    pub fn init(activation: ActivationFn) Self {
        return .{
            .activation = activation,
            .head = .init(null),
        };
    }

    /// Insert an element at the head of the list.
    /// If the list was previously empty, the activation routine will be called.
    pub fn insert(self: *Self, link: *?*anyopaque) void {
        var head = self.head.load(.monotonic);

        while (true) {
            link.* = head;
            head = self.head.cmpxchgWeak(head, @ptrCast(link), .release, .monotonic) orelse break;
        }

        if (head == null) {
            // List was empty, call the activation.
            self.activation(self);
        }
    }

    /// Pop the entire list and process it.
    /// The callback takes the object pointer as its first parameter
    /// and ctx as its second.
    pub fn process(self: *Self, callback: *const fn (*anyopaque, ?*anyopaque) void, ctx: ?*anyopaque) void {
        while (true) {
            const head = self.head.swap(processing_tag, .acquire);

            // Someone else is already processing it (or we set it previously and got nothing).
            if (head == processing_tag) return;

            // List is empty; this shouldn't happen, but it'll just return on the next
            // iteration if it is truly empty.
            if (head == null) {
                _ = self.head.cmpxchgStrong(processing_tag, null, .release, .monotonic) orelse return;
                continue;
            }

            // Walk and process the nodes we took ownership of.
            var it: ?*anyopaque = head;
            while (it) |node| {
                const next_ptr: *?*anyopaque = @ptrCast(@alignCast(node));
                const next = next_ptr.*;
                callback(node, ctx);

                it = if (next == processing_tag) null else next;
            }

            // If the cmpxchg fails, a new item was added; also process it.
            _ = self.head.cmpxchgStrong(processing_tag, null, .release, .monotonic) orelse return;
        }
    }
};

const TestNode = struct {
    next: ?*anyopaque = null,
    value: u32,
};

const TestContext = struct {
    list: HandoffList,
    activated: usize = 0,
    processed: [8]u32 = undefined,
    processed_len: usize = 0,
    insert_on_value: ?u32 = null,
    inserted: bool = false,
    extra: ?*TestNode = null,

    fn init() TestContext {
        return .{ .list = HandoffList.init(test_activation) };
    }
};

fn test_activation(list: *HandoffList) void {
    const ctx: *TestContext = @fieldParentPtr("list", list);
    ctx.activated += 1;
}

fn record_node(node_ptr: *anyopaque, ctx_ptr: ?*anyopaque) void {
    const node: *TestNode = @ptrCast(@alignCast(node_ptr));
    const ctx: *TestContext = @ptrCast(@alignCast(ctx_ptr.?));

    ctx.processed[ctx.processed_len] = node.value;
    ctx.processed_len += 1;
}

fn record_node_and_insert(node_ptr: *anyopaque, ctx_ptr: ?*anyopaque) void {
    const node: *TestNode = @ptrCast(@alignCast(node_ptr));
    const ctx: *TestContext = @ptrCast(@alignCast(ctx_ptr.?));

    ctx.processed[ctx.processed_len] = node.value;
    ctx.processed_len += 1;

    if (!ctx.inserted and ctx.insert_on_value == node.value) {
        ctx.inserted = true;
        ctx.list.insert(&ctx.extra.?.next);
    }
}

test "insert activates only when transitioning from empty" {
    var ctx = TestContext.init();

    var first = TestNode{ .value = 1 };
    var second = TestNode{ .value = 2 };

    ctx.list.insert(&first.next);
    try std.testing.expectEqual(@as(usize, 1), ctx.activated);

    ctx.list.insert(&second.next);
    try std.testing.expectEqual(@as(usize, 1), ctx.activated);

    ctx.list.process(record_node, &ctx);
    try std.testing.expectEqual(@as(usize, 1), ctx.activated);

    var third = TestNode{ .value = 3 };
    ctx.list.insert(&third.next);
    try std.testing.expectEqual(@as(usize, 2), ctx.activated);
}

test "process drains nodes in newest first order" {
    var ctx = TestContext.init();

    var first = TestNode{ .value = 1 };
    var second = TestNode{ .value = 2 };
    var third = TestNode{ .value = 3 };

    ctx.list.insert(&first.next);
    ctx.list.insert(&second.next);
    ctx.list.insert(&third.next);

    ctx.list.process(record_node, &ctx);

    try std.testing.expectEqual(@as(usize, 3), ctx.processed_len);
    try std.testing.expectEqual(@as(u32, 3), ctx.processed[0]);
    try std.testing.expectEqual(@as(u32, 2), ctx.processed[1]);
    try std.testing.expectEqual(@as(u32, 1), ctx.processed[2]);

    ctx.list.process(record_node, &ctx);
    try std.testing.expectEqual(@as(usize, 3), ctx.processed_len);
}

test "process handles empty list" {
    var ctx = TestContext.init();

    ctx.list.process(record_node, &ctx);

    try std.testing.expectEqual(@as(usize, 0), ctx.activated);
    try std.testing.expectEqual(@as(usize, 0), ctx.processed_len);
}

test "process also drains nodes inserted while processing" {
    var ctx = TestContext.init();

    var first = TestNode{ .value = 1 };
    var extra = TestNode{ .value = 2 };
    ctx.insert_on_value = 1;
    ctx.extra = &extra;

    ctx.list.insert(&first.next);
    ctx.list.process(record_node_and_insert, &ctx);

    try std.testing.expectEqual(@as(usize, 2), ctx.processed_len);
    try std.testing.expectEqual(@as(u32, 1), ctx.processed[0]);
    try std.testing.expectEqual(@as(u32, 2), ctx.processed[1]);
    try std.testing.expectEqual(@as(usize, 1), ctx.activated);
}

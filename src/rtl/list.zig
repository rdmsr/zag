//! Intrusive circular linked list module.
/// Branchless intrusive circular linked list.
/// Embed `List.Entry` in your struct and use `@fieldParentPtr` to recover it.
pub const List = struct {
    head: Entry,

    /// A list entry
    pub const Entry = struct {
        /// Next element in the list
        next: *Entry = undefined,
        /// Previous element
        prev: *Entry = undefined,

        /// Remove an entry from whatever list it's in.
        pub fn remove(elem: *Entry) void {
            elem.prev.next = elem.next;
            elem.next.prev = elem.prev;
        }

        /// Insert elem before `before`.
        pub fn insert_before(elem: *Entry, before: *Entry) void {
            elem.prev = before.prev;
            elem.next = before;
            before.prev.next = elem;
            before.prev = elem;
        }
    };

    /// Initialize the list.
    pub fn init(self: *List) void {
        self.head.next = &self.head;
        self.head.prev = &self.head;
    }

    /// Return whether the list is empty.
    pub fn is_empty(self: *List) bool {
        return self.head.next == &self.head;
    }

    /// Insert elem at the end of the list.
    pub fn insert_tail(self: *List, elem: *Entry) void {
        self.head.prev.next = elem;
        elem.next = &self.head;
        elem.prev = self.head.prev;
        self.head.prev = elem;
    }

    /// Insert elem at the beginning of the list.
    pub fn insert_head(self: *List, elem: *Entry) void {
        self.head.next.prev = elem;
        elem.next = self.head.next;
        elem.prev = &self.head;
        self.head.next = elem;
    }

    /// Return the first element of the list.
    pub fn first(self: *List) *Entry {
        return self.head.next;
    }

    /// Return the last element of the list.
    pub fn last(self: *List) *Entry {
        return self.head.prev;
    }

    pub fn iterator(self: *List) Iterator {
        return .{ .head = &self.head, .current = self.head.next };
    }

    pub const Iterator = struct {
        head: *Entry,
        current: *Entry,

        pub fn next(self: *Iterator) bool {
            return self.current != self.head;
        }

        pub fn get(self: *Iterator) *Entry {
            return self.current;
        }

        pub fn advance(self: *Iterator) void {
            self.current = self.current.next;
        }
    };
};

const std = @import("std");

test "init creates empty list" {
    var list: List = undefined;
    list.init();
    try std.testing.expect(list.is_empty());
}

test "insert_tail adds elements in order" {
    var list: List = undefined;
    list.init();

    const Node = struct { value: u32, link: List.Entry = undefined };
    var a = Node{ .value = 1 };
    var b = Node{ .value = 2 };
    var c = Node{ .value = 3 };

    list.insert_tail(&a.link);
    list.insert_tail(&b.link);
    list.insert_tail(&c.link);

    var it = list.iterator();
    var i: u32 = 1;
    while (it.next()) : (it.advance()) {
        const node: *Node = @fieldParentPtr("link", it.get());
        try std.testing.expectEqual(i, node.value);
        i += 1;
    }
    try std.testing.expectEqual(@as(u32, 4), i);
}

test "insert_head adds elements in reverse order" {
    var list: List = undefined;
    list.init();

    const Node = struct { value: u32, link: List.Entry = undefined };
    var a = Node{ .value = 1 };
    var b = Node{ .value = 2 };
    var c = Node{ .value = 3 };

    list.insert_head(&a.link);
    list.insert_head(&b.link);
    list.insert_head(&c.link);

    var it = list.iterator();
    var i: u32 = 3;
    while (it.next()) : (it.advance()) {
        const node: *Node = @fieldParentPtr("link", it.get());
        try std.testing.expectEqual(i, node.value);
        i -= 1;
    }
}

test "remove detaches element" {
    var list: List = undefined;
    list.init();

    const Node = struct { value: u32, link: List.Entry = undefined };
    var a = Node{ .value = 1 };
    var b = Node{ .value = 2 };
    var c = Node{ .value = 3 };

    list.insert_tail(&a.link);
    list.insert_tail(&b.link);
    list.insert_tail(&c.link);

    b.link.remove();

    var it = list.iterator();
    const first: *Node = @fieldParentPtr("link", it.get());
    try std.testing.expectEqual(@as(u32, 1), first.value);
    it.advance();
    const second: *Node = @fieldParentPtr("link", it.get());
    try std.testing.expectEqual(@as(u32, 3), second.value);
    it.advance();
    try std.testing.expect(!it.next());
}

test "insert_before inserts in correct position" {
    var list: List = undefined;
    list.init();

    const Node = struct { value: u32, link: List.Entry = undefined };
    var a = Node{ .value = 1 };
    var b = Node{ .value = 3 };
    var mid = Node{ .value = 2 };

    list.insert_tail(&a.link);
    list.insert_tail(&b.link);

    mid.link.insert_before(&b.link);

    var it = list.iterator();
    var i: u32 = 1;
    while (it.next()) : (it.advance()) {
        const node: *Node = @fieldParentPtr("link", it.get());
        try std.testing.expectEqual(i, node.value);
        i += 1;
    }
}

test "first and last return correct elements" {
    var list: List = undefined;
    list.init();

    const Node = struct { value: u32, link: List.Entry = undefined };
    var a = Node{ .value = 1 };
    var b = Node{ .value = 2 };

    list.insert_tail(&a.link);
    list.insert_tail(&b.link);

    const first: *Node = @fieldParentPtr("link", list.first());
    const last: *Node = @fieldParentPtr("link", list.last());
    try std.testing.expectEqual(@as(u32, 1), first.value);
    try std.testing.expectEqual(@as(u32, 2), last.value);
}

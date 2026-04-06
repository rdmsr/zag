//! Red-Black Tree implementation mostly based on pseudocode from CLRS.
//! Refer to the book for details on the algorithms and properties of red-black trees.
const bst = @import("bst.zig");
const std = @import("std");

const black: u2 = 0;
const red: u2 = 1;

fn get_color(node: *bst.Node) u2 {
    return node.parent.get_tag();
}

fn set_color(node: *bst.Node, color: u2) void {
    node.parent.set_tag(color);
}

pub fn RBTree(comptime cmp: fn (*bst.Node, *bst.Node) std.math.Order) type {
    return struct {
        tree: bst.BST(cmp),

        const Self = @This();

        fn rotate_right(self: *Self, node: *bst.Node) void {
            var y = node.left;
            const parent = node.parent.get_ptr();

            node.left = y.right;

            if (!self.tree.is_nil(y.right)) {
                y.right.parent.set_ptr(node);
            }

            y.parent.set_ptr(parent);

            if (self.tree.is_nil(parent)) {
                self.tree.root = y;
            } else if (node == parent.right) {
                parent.right = y;
            } else {
                parent.left = y;
            }

            y.right = node;
            node.parent.set_ptr(y);
        }

        fn rotate_left(self: *Self, node: *bst.Node) void {
            var y = node.right;
            const parent = node.parent.get_ptr();

            node.right = y.left;

            if (!self.tree.is_nil(y.left)) {
                y.left.parent.set_ptr(node);
            }

            y.parent.set_ptr(parent);

            if (self.tree.is_nil(parent)) {
                self.tree.root = y;
            } else if (node == parent.left) {
                parent.left = y;
            } else {
                parent.right = y;
            }

            y.left = node;
            node.parent.set_ptr(y);
        }

        pub fn init() Self {
            return Self{
                .tree = bst.BST(cmp).init(),
            };
        }

        /// Insert the node `elem` into the tree.
        pub fn insert(self: *Self, elem: *bst.Node) !void {
            if (self.tree.is_empty()) {
                self.tree.insert(elem) catch unreachable;
                set_color(elem, black);
                return;
            }

            self.tree.insert(elem) catch |err| {
                if (err != error.AlreadyExists) unreachable;
                set_color(elem, red);
                return error.AlreadyExists;
            };

            set_color(elem, red);

            var node = elem;
            var parent = node.parent.get_ptr();

            // The tree might be unbalanced, rebalance it.
            while (get_color(parent) == red) {
                var grandparent = parent.parent.get_ptr();

                // The parent of the node is a left child
                if (parent == grandparent.left) {
                    const uncle = grandparent.right;

                    // If the node's parent and uncle are both red, make them
                    // both black and make the node's grandparent red,
                    // as a red node cannot have a red parent.
                    if (get_color(uncle) == red) {
                        set_color(parent, black);
                        set_color(uncle, black);
                        set_color(grandparent, red);
                        node = grandparent;
                        parent = node.parent.get_ptr();
                    } else {
                        // Otherwise, if the node is a right child, rotate left
                        // to make it a left child.
                        if (node == parent.right) {
                            node = parent;
                            self.rotate_left(node);
                            parent = node.parent.get_ptr();
                            grandparent = parent.parent.get_ptr();
                        }

                        // Then, recolor the parent and grandparent and rotate right
                        // to maintain the properties of the red-black tree.
                        set_color(parent, black);
                        set_color(grandparent, red);
                        self.rotate_right(grandparent);
                    }
                } else {
                    // This code is symmetrical to above.
                    const uncle = grandparent.left;

                    if (get_color(uncle) == red) {
                        set_color(parent, black);
                        set_color(uncle, black);
                        set_color(grandparent, red);
                        node = grandparent;
                        parent = node.parent.get_ptr();
                    } else {
                        if (node == parent.left) {
                            node = parent;
                            self.rotate_right(node);
                            parent = node.parent.get_ptr();
                            grandparent = parent.parent.get_ptr();
                        }

                        set_color(parent, black);
                        set_color(grandparent, red);
                        self.rotate_left(grandparent);
                    }

                    parent = node.parent.get_ptr();
                }
            }

            set_color(self.tree.root, black);
        }

        /// Delete the node `elem` from the tree.
        pub fn delete(self: *Self, elem: *bst.Node) void {
            var node = elem;
            var child = &bst.nil;
            var orig_color = get_color(node);

            if (self.tree.is_nil(node.left)) {
                child = node.right;
                // Replace the child with its right child.
                self.tree.transplant(node, node.right);
            } else if (self.tree.is_nil(node.right)) {
                child = node.left;
                // Replace the child with its left child.
                self.tree.transplant(node, node.left);
            } else {
                // Replace with its successor.
                node = self.tree.successor(node);
                orig_color = get_color(node);
                child = node.right;

                if (node.parent.get_ptr() == elem) {
                    child.parent.set_ptr(node);
                } else {
                    self.tree.transplant(node, node.right);
                    node.right = elem.right;
                    node.right.parent.set_ptr(node);
                }

                self.tree.transplant(elem, node);
                node.left = elem.left;
                node.left.parent.set_ptr(node);
                set_color(node, get_color(elem));
            }

            if (orig_color != black) {
                // No need to fix anything.
                return;
            }

            node = child;

            // Fix the tree
            while (node != self.tree.root and get_color(node) == black) {
                var parent = node.parent.get_ptr();

                if (node == parent.left) {
                    var sibling = parent.right;

                    if (get_color(sibling) == red) {
                        set_color(sibling, black);
                        set_color(parent, red);
                        self.rotate_left(parent);

                        parent = node.parent.get_ptr();
                        sibling = parent.right;
                    }

                    if (get_color(sibling.left) == black and get_color(sibling.right) == black) {
                        set_color(sibling, red);
                        node = parent;
                    } else {
                        if (get_color(sibling.right) == black) {
                            set_color(sibling.left, black);
                            set_color(sibling, red);
                            self.rotate_right(sibling);
                            parent = node.parent.get_ptr();
                            sibling = parent.right;
                        }

                        set_color(sibling, get_color(parent));
                        set_color(parent, black);
                        set_color(sibling.right, black);
                        self.rotate_left(parent);
                        node = self.tree.root;
                    }
                } else {
                    var sibling = parent.left;

                    if (get_color(sibling) == red) {
                        set_color(sibling, black);
                        set_color(parent, red);
                        self.rotate_right(parent);

                        parent = node.parent.get_ptr();
                        sibling = parent.left;
                    }

                    if (get_color(sibling.left) == black and get_color(sibling.right) == black) {
                        set_color(sibling, red);
                        node = parent;
                    } else {
                        if (get_color(sibling.left) == black) {
                            set_color(sibling.right, black);
                            set_color(sibling, red);
                            self.rotate_left(sibling);
                            parent = node.parent.get_ptr();
                            sibling = parent.left;
                        }

                        set_color(sibling, get_color(parent));
                        set_color(parent, black);
                        set_color(sibling.left, black);
                        self.rotate_right(parent);
                        node = self.tree.root;
                    }
                }
            }
            set_color(node, black);
        }
    };
}

const TestNode = struct {
    node: bst.Node,
    value: i32,
};

fn cmp_test_node(a: *bst.Node, b: *bst.Node) std.math.Order {
    const a_node: *TestNode = @fieldParentPtr("node", a);
    const b_node: *TestNode = @fieldParentPtr("node", b);

    if (a_node.value < b_node.value) return .lt;
    if (a_node.value > b_node.value) return .gt;
    return .eq;
}

fn get_black_height(tree: *RBTree(cmp_test_node), node: *bst.Node) !usize {
    if (tree.tree.is_nil(node)) return 1;

    const left_bh = try get_black_height(tree, node.left);
    const right_bh = try get_black_height(tree, node.right);

    if (left_bh != right_bh) return error.BlackHeightMismatch;

    if (get_color(node) == red) {
        if (!tree.tree.is_nil(node.left) and get_color(node.left) == red)
            return error.RedRedViolation;
        if (!tree.tree.is_nil(node.right) and get_color(node.right) == red)
            return error.RedRedViolation;
    }

    return left_bh + if (get_color(node) == black) @as(usize, 1) else 0;
}

fn check_invariants(tree: *RBTree(cmp_test_node)) !void {
    if (tree.tree.is_empty()) return;
    try std.testing.expect(get_color(tree.tree.root) == black);
    _ = try get_black_height(tree, tree.tree.root);
}

fn make_tree() RBTree(cmp_test_node) {
    bst.init_nil();
    return .init();
}

fn insert_all(tree: *RBTree(cmp_test_node), nodes: []TestNode) !void {
    for (nodes) |*n| try tree.insert(&n.node);
}

test "invariants hold after each insertion" {
    var tree = make_tree();
    var nodes = [_]TestNode{
        .{ .value = 10, .node = undefined },
        .{ .value = 5, .node = undefined },
        .{ .value = 20, .node = undefined },
        .{ .value = 1, .node = undefined },
        .{ .value = 7, .node = undefined },
        .{ .value = 15, .node = undefined },
        .{ .value = 25, .node = undefined },
        .{ .value = 3, .node = undefined },
        .{ .value = 6, .node = undefined },
    };
    for (&nodes) |*n| {
        try tree.insert(&n.node);
        try check_invariants(&tree);
    }
}

test "ascending insertion stays balanced" {
    var tree = make_tree();
    var nodes: [10]TestNode = undefined;
    for (&nodes, 0..) |*n, i| {
        n.* = .{ .value = @intCast(i + 1), .node = undefined };
        try tree.insert(&n.node);
        try check_invariants(&tree);
    }
}

test "descending insertion stays balanced" {
    var tree = make_tree();
    var nodes: [10]TestNode = undefined;
    for (&nodes, 0..) |*n, i| {
        n.* = .{ .value = @intCast(10 - i), .node = undefined };
        try tree.insert(&n.node);
        try check_invariants(&tree);
    }
}

test "single insert and delete" {
    var tree = make_tree();
    var n = TestNode{ .value = 42, .node = undefined };
    try tree.insert(&n.node);
    try check_invariants(&tree);
    tree.delete(&n.node);
    try std.testing.expect(tree.tree.is_empty());
}

test "delete root" {
    var tree = make_tree();
    var nodes = [_]TestNode{
        .{ .value = 5, .node = undefined },
        .{ .value = 3, .node = undefined },
        .{ .value = 7, .node = undefined },
    };
    try insert_all(&tree, &nodes);
    tree.delete(&nodes[0].node);
    try check_invariants(&tree);
    try std.testing.expect(!tree.tree.is_empty());
}

test "delete leaf" {
    var tree = make_tree();
    var nodes = [_]TestNode{
        .{ .value = 5, .node = undefined },
        .{ .value = 3, .node = undefined },
        .{ .value = 7, .node = undefined },
    };
    try insert_all(&tree, &nodes);
    tree.delete(&nodes[1].node);
    try check_invariants(&tree);
}

test "delete node with two children" {
    var tree = make_tree();
    var nodes = [_]TestNode{
        .{ .value = 10, .node = undefined },
        .{ .value = 5, .node = undefined },
        .{ .value = 15, .node = undefined },
        .{ .value = 3, .node = undefined },
        .{ .value = 7, .node = undefined },
    };
    try insert_all(&tree, &nodes);
    tree.delete(&nodes[1].node);
    try check_invariants(&tree);
}

test "invariants hold after each deletion" {
    var tree = make_tree();
    var nodes = [_]TestNode{
        .{ .value = 5, .node = undefined },
        .{ .value = 3, .node = undefined },
        .{ .value = 7, .node = undefined },
        .{ .value = 2, .node = undefined },
        .{ .value = 4, .node = undefined },
        .{ .value = 6, .node = undefined },
        .{ .value = 8, .node = undefined },
        .{ .value = 1, .node = undefined },
        .{ .value = 9, .node = undefined },
    };
    try insert_all(&tree, &nodes);

    const delete_order = [_]usize{ 3, 0, 7, 1, 5, 2, 6, 4, 8 };
    for (delete_order) |i| {
        tree.delete(&nodes[i].node);
        try check_invariants(&tree);
    }
    try std.testing.expect(tree.tree.is_empty());
}

test "duplicate insert returns error" {
    var tree = make_tree();
    var a = TestNode{ .value = 5, .node = undefined };
    var b = TestNode{ .value = 5, .node = undefined };
    try tree.insert(&a.node);
    try std.testing.expectError(error.AlreadyExists, tree.insert(&b.node));
    try check_invariants(&tree);
    tree.delete(&a.node);
    try std.testing.expect(tree.tree.is_empty());
}

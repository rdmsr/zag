//! AVL tree implementation
//! Invariant: For every node, the difference in height between its left
//! and right subtrees is strictly limited to -1, 0 or 1.
const bst = @import("bst.zig");
const std = @import("std");

// Left-heavy
const minus_one: u2 = 1;
// Balanced
const zero: u2 = 0;
// Right-heavy
const one: u2 = 2;

fn get_bf(node: *bst.Node) u2 {
    return node.parent.get_tag();
}

fn set_bf(node: *bst.Node, bf: u2) void {
    node.parent.set_tag(bf);
}

pub fn AVLTree(comptime cmp: fn (*const bst.Node, *const bst.Node) std.math.Order) type {
    return struct {
        tree: bst.BST(cmp),

        const Self = @This();

        pub fn init() Self {
            return Self{
                .tree = bst.BST(cmp).init(),
            };
        }

        fn rotate_left(self: *Self, x: *bst.Node, z: *bst.Node) *bst.Node {
            x.right = z.left;

            if (!self.tree.is_nil(z.left)) {
                z.left.parent.set_ptr(x);
            }

            z.left = x;

            x.parent.set_ptr(z);

            if (get_bf(z) == zero) {
                set_bf(x, one);
                set_bf(z, minus_one);
            } else {
                set_bf(x, zero);
                set_bf(z, zero);
            }

            return z;
        }

        fn rotate_right(self: *Self, x: *bst.Node, z: *bst.Node) *bst.Node {
            x.left = z.right;

            if (!self.tree.is_nil(z.right)) {
                z.right.parent.set_ptr(x);
            }

            z.right = x;

            x.parent.set_ptr(z);

            if (get_bf(z) == zero) {
                set_bf(x, minus_one);
                set_bf(z, one);
            } else {
                set_bf(x, zero);
                set_bf(z, zero);
            }

            return z;
        }

        fn rotate_right_left(self: *Self, x: *bst.Node, z: *bst.Node) *bst.Node {
            var y = z.left;
            var t2 = y.right;

            // First, rotate right at Z
            z.left = t2;
            if (!self.tree.is_nil(t2)) {
                t2.parent.set_ptr(z);
            }

            y.right = z;

            z.parent.set_ptr(y);

            const t1 = y.left;

            // second, rotate left at X
            x.right = t1;

            if (!self.tree.is_nil(t1)) {
                t1.parent.set_ptr(x);
            }

            y.left = x;
            x.parent.set_ptr(y);

            switch (get_bf(y)) {
                zero => {
                    set_bf(x, zero);
                    set_bf(z, zero);
                },

                one => {
                    set_bf(x, minus_one);
                    set_bf(z, zero);
                },

                else => {
                    set_bf(x, zero);
                    set_bf(z, one);
                },
            }

            set_bf(y, zero);

            return y;
        }

        fn rotate_left_right(self: *Self, x: *bst.Node, z: *bst.Node) *bst.Node {
            var y = z.right;
            var t2 = y.left;

            // First, rotate left at Z
            z.right = t2;
            if (!self.tree.is_nil(t2)) {
                t2.parent.set_ptr(z);
            }

            y.left = z;

            z.parent.set_ptr(y);

            const t1 = y.right;

            // second, rotate right at X
            x.left = t1;

            if (!self.tree.is_nil(t1)) {
                t1.parent.set_ptr(x);
            }

            y.right = x;
            x.parent.set_ptr(y);

            switch (get_bf(y)) {
                zero => {
                    set_bf(x, zero);
                    set_bf(z, zero);
                },

                minus_one => {
                    set_bf(x, one);
                    set_bf(z, zero);
                },

                else => {
                    set_bf(x, zero);
                    set_bf(z, minus_one);
                },
            }

            set_bf(y, zero);

            return y;
        }

        /// Insert the node `elem` into the tree.
        pub fn insert(self: *Self, elem: *bst.Node) !void {
            if (self.tree.is_empty()) {
                self.tree.insert(elem) catch unreachable;
                set_bf(elem, zero);
                return;
            }

            self.tree.insert(elem) catch |err| {
                if (err != error.AlreadyExists) unreachable;
                return error.AlreadyExists;
            };

            set_bf(elem, zero);

            // Now the tree may be unbalanced, rebalance it.
            var node = elem;
            var parent = elem.parent.get_ptr();
            var n = &bst.nil;

            while (!self.tree.is_nil(parent)) : (parent = parent.parent.get_ptr()) {
                const orig_parent = parent.parent.get_ptr();

                if (node == parent.right) {
                    if (get_bf(parent) == one) {
                        // This node has been inserted on the right of the parent,
                        // and the parent already has a balance factor of 1 (right-heavy),
                        // the parent's BF would then become +2, which breaks the invariant.
                        // We need to rebalance.

                        if (get_bf(node) == minus_one) {
                            n = self.rotate_right_left(parent, node);
                        } else {
                            // This is a case where the tree looks like this:
                            //  1
                            //   \
                            //    2
                            //    \
                            //     3
                            // We need to rotate the subtree so it looks like:
                            //      2
                            //     / \
                            //    1  3
                            // In the code, `parent` would be 1 and `node` would be 2
                            n = self.rotate_left(parent, node);
                        }
                    } else {
                        // The balance factor is either 0 or -1, increase it.
                        // If it was -1, now it is 0 so the subtree is perfectly balanced, we can stop.
                        // If it was 0, now it is +1, so we may need to check higher up for imbalances.

                        if (get_bf(parent) == minus_one) {
                            set_bf(parent, zero);
                            break;
                        }

                        set_bf(parent, one);
                        node = parent;
                        continue;
                    }
                }
                // This node is the left child.
                // The logic is the same as the other case but inverted.
                else {
                    if (get_bf(parent) == minus_one) {
                        // This node has been inserted on the left of the parent,
                        // and the parent already has a balance factor of -1 (left-heavy),
                        // the parent's balance factor would then become -2, which breaks the invariant.
                        // We need to rebalance.

                        if (get_bf(node) == one) {
                            n = self.rotate_left_right(parent, node);
                        } else {
                            n = self.rotate_right(parent, node);
                        }
                    } else {
                        if (get_bf(parent) == one) {
                            set_bf(parent, zero);
                            break;
                        }

                        set_bf(parent, minus_one);
                        node = parent;
                        continue;
                    }
                }

                // Adopt the new subtree root
                n.parent.set_ptr(orig_parent);

                if (!self.tree.is_nil(orig_parent)) {
                    if (parent == orig_parent.left) {
                        orig_parent.left = n;
                    } else {
                        orig_parent.right = n;
                    }
                } else {
                    self.tree.root = n;
                }

                break;
            }
        }

        /// Delete the node `elem` from the tree.
        pub fn delete(self: *Self, elem: *bst.Node) void {
            var node = elem;
            var original_parent = &bst.nil;
            var parent = node.parent.get_ptr();
            var was_on_left = !self.tree.is_nil(parent) and parent.left == node;
            var b = zero;

            if (self.tree.is_nil(elem.left)) {
                self.tree.transplant(elem, elem.right);
            } else if (self.tree.is_nil(elem.right)) {
                self.tree.transplant(elem, elem.left);
            } else {
                var succ = self.tree.successor(node);
                parent = succ.parent.get_ptr();
                was_on_left = !self.tree.is_nil(parent) and succ == parent.left;

                if (parent != elem) {
                    self.tree.transplant(succ, succ.right);
                    succ.right = elem.right;
                    succ.right.parent.set_ptr(succ);
                } else {
                    // The successor is the direct child, so start rebalancing from it.
                    parent = succ;
                }

                self.tree.transplant(elem, succ);
                succ.left = elem.left;
                succ.left.parent.set_ptr(succ);
                set_bf(succ, get_bf(elem));

                node = succ;
            }

            // Rebalance the tree.
            while (!self.tree.is_nil(parent)) {
                original_parent = parent.parent.get_ptr();

                if (node == parent.left or was_on_left) {
                    was_on_left = false;

                    if (get_bf(parent) == one) {
                        const sibling = parent.right;
                        b = get_bf(sibling);

                        if (b == minus_one) {
                            node = self.rotate_right_left(parent, sibling);
                        } else {
                            node = self.rotate_left(parent, sibling);
                        }
                    } else {
                        if (get_bf(parent) == zero) {
                            set_bf(parent, one);
                            break;
                        }

                        node = parent;
                        set_bf(parent, zero);
                        parent = original_parent;
                        continue;
                    }
                } else {
                    if (get_bf(parent) == minus_one) {
                        const sibling = parent.left;
                        b = get_bf(sibling);

                        if (b == one) {
                            node = self.rotate_left_right(parent, sibling);
                        } else {
                            node = self.rotate_right(parent, sibling);
                        }
                    } else {
                        if (get_bf(parent) == zero) {
                            set_bf(parent, minus_one);
                            break;
                        }

                        node = parent;
                        set_bf(node, zero);
                        parent = original_parent;
                        continue;
                    }
                }

                // Adopt the new subtree root
                node.parent.set_ptr(original_parent);

                if (!self.tree.is_nil(original_parent)) {
                    if (parent == original_parent.left) {
                        original_parent.left = node;
                    } else {
                        original_parent.right = node;
                    }
                } else {
                    self.tree.root = node;
                }

                if (b == zero) {
                    break;
                }

                parent = original_parent;
            }
        }
    };
}

const rtl = @import("rtl");
const std = @import("std");

pub const Node = struct {
    left: *Node,
    right: *Node,
    parent: rtl.TaggedPtr(Node),
};

/// Base struct for binary search trees.
/// This should be used as a field in other types that are based on binary search trees, such as red-black trees or AVL trees.
pub fn BST(comptime cmp: fn (*Node, *Node) std.math.Order) type {
    return struct {
        const Self = @This();

        root: *Node = undefined,
        nil: Node = undefined,

        /// Initialize the BST. This must be called before using the tree.
        pub fn init(self: *Self) void {
            self.nil.left = &self.nil;
            self.nil.right = &self.nil;
            self.nil.parent = &self.nil;
            self.root = &self.nil;
        }

        /// Return whether or not the given node is the sentinel nil node.
        pub fn is_nil(self: *Self, node: *Node) bool {
            return node == &self.nil;
        }

        /// Search for a node in the BST that matches `elem`, and return a pointer to it if found.
        pub fn search(self: *Self, elem: *Node) ?*Node {
            var node = self.root;
            while (!self.is_nil(node)) {
                const order = cmp(elem, node);
                if (order == .eq) {
                    return node;
                } else if (order == .lt) {
                    node = node.left;
                } else {
                    node = node.right;
                }
            }
            return null;
        }

        /// Return a pointer to the minimum node in the subtree rooted at `node`.
        pub fn minimum(self: *Self, node: *Node) *Node {
            var current = node;
            while (!self.is_nil(current.left)) {
                current = current.left;
            }
            return current;
        }

        /// Return a pointer to the maximum node in the subtree rooted at `node`.
        pub fn maximum(self: *Self, node: *Node) *Node {
            var current = node;
            while (!self.is_nil(current.right)) {
                current = current.right;
            }
            return current;
        }

        /// Return a pointer to the successor of `node`, or nil if `node` is the maximum element in the tree.
        pub fn successor(self: *Self, node: *Node) *Node {
            if (!self.is_nil(node.right)) {
                // Minimum of right subtree
                return self.minimum(node.right);
            }

            // Go up and find it.
            var current = node;
            var parent = current.parent.get_ptr();
            while (!self.is_nil(parent) and current == parent.right) {
                current = parent;
                parent = parent.parent.get_ptr();
            }

            if (parent == self.root) {
                return &self.nil;
            }

            return parent;
        }

        /// Transplant the subtree rooted at `u` with the subtree rooted at `v`. This is used as a helper function.
        pub fn transplant(self: *Self, u: *Node, v: *Node) void {
            const u_parent = u.parent.get_ptr();
            if (self.is_nil(u_parent)) {
                self.root = v;
            } else if (u == u_parent.left) {
                u_parent.left = v;
            } else {
                u_parent.right = v;
            }
            v.parent.set_ptr(u_parent);
        }
    };
}

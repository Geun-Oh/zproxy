const std = @import("std");

pub const Treap = struct {
    pub const Node = struct {
        key: u64,
        priority: u64,

        left: ?*Node = null,
        right: ?*Node = null,
        parent: ?*Node = null,
    };

    root: ?*Node = null,

    pub fn insert(self: *Treap, node: *Node) void {
        // 1. Standard BST Insert
        if (self.root == null) {
            self.root = node;
            node.parent = null;
        } else {
            var current = self.root;
            while (current) |c| {
                if (node.key < c.key) {
                    if (c.left) |left| {
                        current = left;
                    } else {
                        c.left = node;
                        node.parent = c;
                        break;
                    }
                } else {
                    if (c.right) |right| {
                        current = right;
                    } else {
                        c.right = node;
                        node.parent = c;
                        break;
                    }
                }
            }
        }

        // 2. Heap Property Rebalancing (Bubble Up)
        while (node.parent) |p| {
            if (node.priority > p.priority) {
                if (node == p.left) {
                    self.rotateRight(p);
                } else {
                    self.rotateLeft(p);
                }
            } else {
                break;
            }
        }
    }

    pub fn delete(self: *Treap, node: *Node) void {
        // 1. Rotate down to leaf
        while (node.left != null or node.right != null) {
            var use_left = false;

            if (node.left != null and node.right != null) {
                if (node.left.?.priority > node.right.?.priority) {
                    use_left = true;
                }
            } else if (node.left != null) {
                use_left = true;
            }

            if (use_left) {
                self.rotateRight(node);
            } else {
                self.rotateLeft(node);
            }
        }

        // 2. Remove leaf
        if (node.parent) |p| {
            if (p.left == node) {
                p.left = null;
            } else {
                p.right = null;
            }
        } else {
            self.root = null;
        }

        // Clear links for safety
        node.left = null;
        node.right = null;
        node.parent = null;
    }

    pub fn first(self: *Treap) ?*Node {
        var current = self.root orelse return null;
        while (current.left) |left| {
            current = left;
        }
        return current;
    }

    fn rotateLeft(self: *Treap, x: *Node) void {
        const y = x.right orelse return;
        x.right = y.left;

        if (y.left) |yl| {
            yl.parent = x;
        }

        y.parent = x.parent;

        if (x.parent) |xp| {
            if (x == xp.left) {
                xp.left = y;
            } else {
                xp.right = y;
            }
        } else {
            self.root = y;
        }

        y.left = x;
        x.parent = y;
    }

    fn rotateRight(self: *Treap, y: *Node) void {
        const x = y.left orelse return;
        y.left = x.right;

        if (x.right) |xr| {
            xr.parent = y;
        }

        x.parent = y.parent;

        if (y.parent) |yp| {
            if (y == yp.left) {
                yp.left = x;
            } else {
                yp.right = x;
            }
        } else {
            self.root = x;
        }

        x.right = y;
        y.parent = x;
    }
};

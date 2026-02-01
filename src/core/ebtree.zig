const std = @import("std");

pub const EB64Tree = struct {
    pub const Node = struct {
        key: u64,

        // Tree links
        left: ?*Node = null,
        right: ?*Node = null,
        parent: ?*Node = null,

        // Duplicate handling (for identical keys)
        // This is a specialized optimization for timers/schedulers where
        // many events may happen at the exact same timestamp.
        dup: ?*Node = null,
        dup_prev: ?*Node = null, // doubly linked for O(1) removal from middle
    };

    root: ?*Node = null,

    pub fn insert(self: *EB64Tree, node: *Node) void {
        // Reset links
        node.left = null;
        node.right = null;
        node.parent = null;
        node.dup = null;
        node.dup_prev = null;

        if (self.root == null) {
            self.root = node;
            return;
        }

        var current = self.root;
        while (current) |c| {
            if (node.key == c.key) {
                // Duplicate optimization: Add to dup list of the node in the tree
                // We add to the head for O(1)
                node.dup = c.dup;
                if (c.dup) |d| {
                    d.dup_prev = node;
                }
                c.dup = node;
                node.dup_prev = c; // c acts as the "prev" for the head
                // Note: We don't set node.parent/left/right because it's stored in 'dup'
                // But we mark it somehow?
                // Actually, if node.dup_prev points to 'c' (which is in the tree),
                // we can distinguish it.
                // However, 'c' is the list head holder, not exactly the same list type.
                // Simpler: Just link it.
                return;
            } else if (node.key < c.key) {
                if (c.left) |left| {
                    current = left;
                } else {
                    c.left = node;
                    node.parent = c;
                    return;
                }
            } else {
                if (c.right) |right| {
                    current = right;
                } else {
                    c.right = node;
                    node.parent = c;
                    return;
                }
            }
        }
    }

    pub fn delete(self: *EB64Tree, node: *Node) void {
        // Check if node is in a duplicate list (secondary)
        // If node.dup_prev is set, it might be in a list.
        // Or if node.parent is null and node != root?
        // No, parent is null for root.

        // Case 1: Node is in the duplicate list (not the tree structure main node)
        // We know this if it has a dup_prev, OR if a parent's 'dup' points to it.
        // Actually, let's look at dup_prev.

        if (node.dup_prev) |prev| {
            // It is in a list.
            // Check if 'prev' is the tree node itself or just another dup.
            // If 'prev.dup' == node, then 'prev' is our predecessor.

            if (prev.dup == node) {
                // Unlink
                prev.dup = node.dup;
                if (node.dup) |d| {
                    d.dup_prev = prev;
                }
                node.dup = null;
                node.dup_prev = null;
                return;
            }
        }

        // Case 2: Node is the main node in the tree.
        // Use standard BST delete, BUT check for duplicates first.

        if (node.dup) |head_dup| {
            // We have a duplicate waiting. Promote it to replace 'node'.
            // head_dup becomes the new tree node.

            this_replace_node(self, node, head_dup);

            // Fix dup links
            head_dup.dup = head_dup.dup; // Points to next? No, head_dup.dup is next.
            // Wait, head_dup.dup points to the *next* dup.
            // We need to preserve that.
            // head_dup.dup is correct.
            // head_dup.dup_prev was 'node'. Now it should be null as it's the main node.

            if (head_dup.dup) |d| {
                d.dup_prev = head_dup;
            }
            head_dup.dup_prev = null;

            // Inherit tree structure
            head_dup.left = node.left;
            if (head_dup.left) |l| l.parent = head_dup;

            head_dup.right = node.right;
            if (head_dup.right) |r| r.parent = head_dup;

            // Clean up node
            node.left = null;
            node.right = null;
            node.parent = null;
            node.dup = null;
            return;
        }

        // Standard BST Delete (no duplicates to promote)
        if (node.left == null) {
            self.transplant(node, node.right);
        } else if (node.right == null) {
            self.transplant(node, node.left);
        } else {
            const y = getMinimum(node.right.?);
            if (y.parent != node) {
                self.transplant(y, y.right);
                y.right = node.right;
                y.right.?.parent = y;
            }
            self.transplant(node, y);
            y.left = node.left;
            y.left.?.parent = y;
        }
    }

    fn this_replace_node(self: *EB64Tree, u: *Node, v: *Node) void {
        if (u.parent) |parent| {
            if (u == parent.left) {
                parent.left = v;
            } else {
                parent.right = v;
            }
        } else {
            self.root = v;
        }
        v.parent = u.parent;
    }

    fn transplant(self: *EB64Tree, u: *Node, v: ?*Node) void {
        if (u.parent) |parent| {
            if (u == parent.left) {
                parent.left = v;
            } else {
                parent.right = v;
            }
        } else {
            self.root = v;
        }
        if (v) |val| {
            val.parent = u.parent;
        }
    }

    fn getMinimum(node: *Node) *Node {
        var current = node;
        while (current.left) |left| {
            current = left;
        }
        return current;
    }

    pub fn first(self: *EB64Tree) ?*Node {
        var current = self.root orelse return null;
        while (current.left) |left| {
            current = left;
        }
        // Return the tree node.
        // If it has duplicates, the scheduler deletes them one by one.
        // Logic:
        // 1. Get Node A.
        // 2. Scheduler executes A.
        // 3. Scheduler deletes A.
        // 4. Delete operation promotes A.dup (A') to be the tree node.
        // 5. Next loop: first() returns A'.
        // Correct.
        return current;
    }
};

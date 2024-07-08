const std = @import("std");

const Allocator = std.mem.Allocator;

pub const MAX_LABELS = 10;

threadlocal var sni_free_cb: *const fn (user: *anyopaque) void = undefined;

pub const SniNode = struct {
    allocator: Allocator,
    user: ?*anyopaque = null, // Empty nodes must always hold null
    children: std.StringHashMap(SniNode),

    pub fn init(allocator: Allocator) !*SniNode {
        const self = try allocator.create(SniNode);
        self.* = .{
            .allocator = allocator,
            .children = std.StringHashMap(SniNode).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *SniNode) void {
        var children = self.children.iterator();
        while (children.next()) |entry| {
            // free string key values
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.user) |user| sni_free_cb(user);
            entry.value_ptr.deinit();
        }
        self.allocator.destroy(self);
        self.* = undefined;
    }

    // Deletes a single node, may fill empty nodes with null.
    pub fn removeUser(self: *SniNode, label: u64, labels: []const []const u8) ?*anyopaque {
        if (label == labels.len) {
            const user = self.user;
            // mark to be filled with null
            self.user = null;
            return user;
        }

        if (self.children.getEntry(labels[label])) |entry| {
            const removed_user = removeUser(entry.value_ptr, label + 1, labels);
            if (entry.value_ptr.children.count() == 0 and entry.value_ptr.user == null) {
                var removed = self.children.fetchRemove(entry.key_ptr.*);
                self.allocator.free(removed.?.key);
                removed.?.value.deinit();
            }
            return removed_user;
        } else return null;
    }
};

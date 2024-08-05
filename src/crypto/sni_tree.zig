const std = @import("std");

const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const MAX_LABELS = 10;

threadlocal var sni_free_cb: *const fn (user: *anyopaque) void = undefined;

pub const SniNode = struct {
    allocator: Allocator,
    user: ?*anyopaque = null, // Empty nodes must always hold null
    children: std.StringHashMap(SniNode),

    pub fn init(allocator: Allocator) SniNode {
        return .{
            .allocator = allocator,
            .children = std.StringHashMap(SniNode).init(allocator),
        };
    }

    pub fn deinit(self: *SniNode) void {
        var children = self.children.iterator();
        while (children.next()) |entry| {
            // free string key values
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.user) |user| sni_free_cb(user);
            entry.value_ptr.deinit();
        }
        self.children.deinit();
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

    pub fn getUser(self: *SniNode, label: u64, labels: []const []const u8) ?*anyopaque {
        if (label == labels.len) return self.user;
        if (self.children.getEntry(labels[label])) |entry| {
            if (getUser(entry.value_ptr, label + 1, labels)) |user| return user;
        }
        if (self.children.getEntry("*")) |entry| {
            return getUser(entry.value_ptr, label + 1, labels);
        } else return null;
    }
};

pub fn sniFree(sni: *SniNode, cb: *const fn (user: *anyopaque) void) void {
    sni_free_cb = cb;
    sni.deinit();
}

/// Returns false if name already registered.
pub fn sniAdd(sni: *SniNode, allocator: std.mem.Allocator, hostname: []const u8, user: ?*anyopaque) !bool {
    var root = sni;
    var view = hostname;
    var label: []const u8 = &[_]u8{};
    // iterate over labels in hostname
    while (view.len > 0) : (view = view[@min(view.len, label.len + 1)..]) {
        // label is token between dots
        label = view[0 .. std.mem.indexOfScalar(u8, view, '.') orelse view.len];
        const entry = try root.children.getOrPut(label);
        if (!entry.found_existing) {
            // duplicate label
            entry.key_ptr.* = try allocator.dupe(u8, label);
            entry.value_ptr.* = SniNode.init(allocator);
        }
        root = entry.value_ptr;
    }
    // avoid adding mulitple contexts for same name (memory would leak)
    if (root.user) |_| return true;
    root.user = user;
    return false;
}

pub fn sniRemove(root: *SniNode, hostname: []const u8) ?*anyopaque {
    var labels: [MAX_LABELS][]const u8 = undefined;
    var num_labels: u8 = 0;
    // traverse all labels
    var view = hostname;
    var label: []const u8 = &[_]u8{};
    while (view.len > 0) : (view = view[@min(view.len, label.len + 1)..]) {
        // label is token between dots
        label = view[0 .. std.mem.indexOfScalar(u8, view, '.') orelse view.len];
        if (num_labels == MAX_LABELS) return null;
        labels[num_labels] = label;
        num_labels += 1;
    }
    return root.removeUser(0, labels[0..num_labels]);
}

pub fn sniFind(root: *SniNode, hostname: []const u8) ?*anyopaque {
    var labels: [MAX_LABELS][]const u8 = undefined;
    var num_labels: u8 = 0;
    // traverse all labels
    var view = hostname;
    var label: []const u8 = &[_]u8{};
    while (view.len > 0) : (view = view[@min(view.len, label.len + 1)..]) {
        // label is token between dots
        label = view[0 .. std.mem.indexOfScalar(u8, view, '.') orelse view.len];
        if (num_labels == MAX_LABELS) return null;
        labels[num_labels] = label;
        num_labels += 1;
    }
    return root.getUser(0, labels[0..num_labels]);
}

test "sni tree" {
    const allocator = testing.allocator;
    var sni = SniNode.init(allocator);
    defer sniFree(&sni, struct {
        pub fn call(user: *anyopaque) void {
            std.debug.print("\nfreeing user: {d}", .{@intFromPtr(user)});
        }
    }.call);
    try testing.expectEqual(false, try sniAdd(&sni, allocator, "*.google.com", @ptrFromInt(13)));
    try testing.expectEqual(false, try sniAdd(&sni, allocator, "test.google.com", @ptrFromInt(14)));

    // adding same hostname should not overwrite existing
    try testing.expectEqual(true, try sniAdd(&sni, allocator, "*.google.com", @ptrFromInt(15)));
    try testing.expectEqual(@as(usize, 13), @intFromPtr(sniFind(&sni, "random.google.com")));

    try testing.expectEqual(@as(usize, 13), @intFromPtr(sniFind(&sni, "docs.google.com")));
    try testing.expectEqual(@as(usize, 13), @intFromPtr(sniFind(&sni, "*.google.com")));
    try testing.expectEqual(@as(usize, 14), @intFromPtr(sniFind(&sni, "test.google.com")));
    try testing.expectEqual(@as(usize, 0), @intFromPtr(sniFind(&sni, "yolo.nothing.com")));
    try testing.expectEqual(@as(usize, 13), @intFromPtr(sniFind(&sni, "yolo.google.com")));

    // should work to remove
    try testing.expectEqual(@as(usize, 14), @intFromPtr(sniRemove(&sni, "test.google.com")));
    try testing.expectEqual(@as(usize, 13), @intFromPtr(sniFind(&sni, "test.google.com")));
    try testing.expectEqual(@as(usize, 13), @intFromPtr(sniRemove(&sni, "*.google.com")));
    try testing.expectEqual(@as(usize, 0), @intFromPtr(sniFind(&sni, "test.google.com")));

    // removing parent with data should not remove child with data
    try testing.expectEqual(false, try sniAdd(&sni, allocator, "www.google.com", @ptrFromInt(16)));
    try testing.expectEqual(false, try sniAdd(&sni, allocator, "www.google.com.au.ck.uk", @ptrFromInt(17)));
    try testing.expectEqual(@as(usize, 16), @intFromPtr(sniFind(&sni, "www.google.com")));
    try testing.expectEqual(@as(usize, 17), @intFromPtr(sniFind(&sni, "www.google.com.au.ck.uk")));
    try testing.expectEqual(@as(usize, 0), @intFromPtr(sniRemove(&sni, "www.google.com.yolo")));
    try testing.expectEqual(@as(usize, 17), @intFromPtr(sniRemove(&sni, "www.google.com.au.ck.uk")));
    try testing.expectEqual(@as(usize, 16), @intFromPtr(sniFind(&sni, "www.google.com")));
}

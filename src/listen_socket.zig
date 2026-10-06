const bsd = @import("bsd/root.zig");
const std = @import("std");
const Extension = @import("extension.zig");
const Loop = @import("eventing/impl.zig").Loop;
const Poll = @import("eventing/impl.zig").Poll;
const SocketContext = @import("socket_context.zig");
const Socket = @import("socket.zig");

const Self = @This();

s: Socket,
// ext: []Extension = &.{},

pub fn init(allocator: std.mem.Allocator, context: *SocketContext, comptime ExtensionTypes: []const type) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .s = .{
            .context = context,
            .ls_field_ptr = true,
            .ext = try allocator.alloc(Extension, ExtensionTypes.len),
        },
    };
    errdefer allocator.free(self.s.ext);
    inline for (0..ExtensionTypes.len) |i| self.s.ext[i] = Extension.init(allocator, ExtensionTypes[i]) catch |e| {
        for (0..i) |j| self.s.ext[j].deinit(allocator);
        return e;
    };
    return self;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator, loop: *Loop) void {
    self.s.p.deinit(allocator, loop);
    for (self.s.ext) |*e| e.deinit(allocator);
    allocator.free(self.s.ext);
    // self.ext.deinit(allocator);
    allocator.destroy(self);
}

pub fn close(self: *Self, _: bool) void {
    if (!self.s.isClosed(false)) {
        self.s.context.unlinkListenSocket(self);
        self.s.p.stop(self.s.context.loop);
        bsd.closeSocket(self.s.p.fd());
        self.s.next = self.s.context.loop.data.closed_head;
        self.s.context.loop.data.closed_head = &self.s;
        self.s.prev = @ptrCast(@alignCast(self.s.context));
    }
}

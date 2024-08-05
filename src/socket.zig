const bsd = @import("bsd.zig");
const build_opts = @import("build_opts");
const std = @import("std");
const zs = @import("zsockets.zig");

const Allocator = std.mem.Allocator;

pub const Socket = struct {
    p: zs.Poll,
    timeout: u8,
    long_timeout: u8,
    low_priority_state: zs.LowPriorityState,
    context: *zs.Context,
    prev: ?*Socket,
    next: ?*Socket,
    _ext: zs.Extension = .{},

    pub fn deinit(self: *Socket, allocator: Allocator, loop: *zs.Loop) void {
        self._ext.deinit(allocator);
        self.p.deinit(loop);
        allocator.destroy(self);
    }

    pub fn ext(self: *Socket, comptime T: type) ?*align(@alignOf(u8)) T {
        return @ptrCast(@alignCast(self._ext.ptr));
    }

    pub fn ctx(self: *Socket) *zs.Context {
        return self.context;
    }

    pub fn isClosed(self: *const Socket) bool {
        return @intFromPtr(self.prev) == @intFromPtr(self.context);
    }

    pub fn isEstablished(self: *const Socket) bool {
        return self.p.type() != .semi_socket;
    }

    pub fn shutdown(self: *Socket) !void {
        // TODO: maybe clean up handling here
        if (!self.isClosed() and !self.isShutdown()) {
            self.p.setType(.socket_shutdown);
            try self.p.change(self.context.loop, self.p.events() & zs.SOCKET_READABLE);
            return bsd.shutdownSocket(self.p.fd());
        }
    }

    pub fn isShutdown(self: *const Socket) bool {
        return self.p.type() == .socket_shutdown;
    }

    pub fn setTimeout(self: *Socket, seconds: u32) void {
        self.timeout = switch (seconds) {
            0 => 255,
            else => @intCast((self.context.timestamp + ((seconds + 3) >> 2)) % 240),
        };
    }

    pub fn close(self: *Socket, allocator: Allocator, code: i32, reason: ?*anyopaque) !*Socket {
        if (!self.isClosed()) {
            switch (self.low_priority_state) {
                .queued => {
                    if (self.low_priority_state == .queued) {
                        // unlink socket from low priority queue
                        if (self.prev) |prev| {
                            prev.next = self.next;
                        } else {
                            self.context.loop.data.low_priority_head = self.next;
                        }
                        self.prev = null;
                        self.next = null;
                        self.low_priority_state = .none;
                    }
                },
                else => self.context.unlinkSocket(self),
            }
            try self.p.stop(self.context.loop);
            try bsd.closeSocket(self.p.fd());

            // link socket to closed-list (ready deletion)
            self.next = self.context.loop.data.closed_head;
            self.context.loop.data.closed_head = self;

            // any socket with prev = context is marked as closed
            self.prev = @ptrCast(@alignCast(self.context));
            return self.context.on_close(allocator, self, code, reason);
        }
        return self;
    }

    /// This function is the same as `close`, but does not
    /// emit the on-close callback.
    pub fn closeConnecting(self: *Socket) !*Socket {
        if (!self.isClosed()) {
            self.context.unlinkSocket(self);
            try self.p.stop(self.context.loop);
            try bsd.closeSocket(self.p.fd());
            // link socket to the close-list so it can be deleted
            // after this iteration.
            self.next = self.context.loop.data.closed_head;
            self.context.loop.data.closed_head = self;
            // any socket with `prev == context` is marked as closed
            self.prev = @ptrCast(@alignCast(self.context));
        }
        return self;
    }

    pub fn write(self: *Socket, data: []const u8, msg_more: bool) !isize {
        if (self.isClosed() or self.isShutdown()) return 0;
        const written = bsd.send((&self.p).fd(), data, msg_more);
        if (written != @as(isize, @intCast(data.len))) {
            self.context.loop.data.last_write_failed = true;
            try self.p.change(self.context.loop, zs.SOCKET_READABLE | zs.SOCKET_WRITABLE);
        }
        return written;
    }

    pub fn resize(self: *Socket, allocator: Allocator, loop: *zs.Loop, comptime T: ?type) !void {
        var old_ext = self._ext;
        defer old_ext.deinit(allocator);
        if (T) |Ext| {
            self._ext = try zs.Extension.init(allocator, Ext);
            old_ext.copyTo(&self._ext);
        }
        try self.p.resizeUpdate(loop);
    }
};

pub const ListenSocket = struct {
    s: zs.Socket,

    pub fn close(self: *ListenSocket) !void {
        if (!self.s.isClosed()) {
            self.s.context.unlinkListenSocket(self);
            try self.s.p.stop(self.s.context.loop);
            try bsd.closeSocket(self.s.p.fd());
            self.s.next = self.s.context.loop.data.closed_head;
            self.s.context.loop.data.closed_head = &self.s;
            self.s.prev = @ptrCast(@alignCast(self.s.context));
        }
    }
};

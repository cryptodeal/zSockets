const bsd = @import("bsd.zig");
const build_opts = @import("build_opts");
const c = @import("ssl.zig");
const context_ = @import("context.zig");
const internal = @import("internal.zig");
const std = @import("std");

const Extensions = @import("zsockets.zig").Extensions;

const Allocator = std.mem.Allocator;
const EXT_ALIGNMENT = internal.EXT_ALIGNMENT;
const LowPriorityState = internal.LowPriorityState;
const SOCKET_READABLE = internal.SOCKET_READABLE;
const SOCKET_WRITABLE = internal.SOCKET_WRITABLE;

pub fn Socket(comptime ssl: bool, comptime SocketExt: type, comptime SocketCtxExt: type, comptime Loop: type, comptime Poll: type) type {
    // internal types

    const BaseSocket = struct {
        const Self = @This();
        pub const Context = @import("context.zig").SocketCtx(ssl, SocketCtxExt, Loop, Poll, Self);

        pub const ListenSocket = struct {
            s: Self align(EXT_ALIGNMENT),

            pub fn close(self: *ListenSocket) !void {
                if (!self.s.isClosed()) {
                    self.s.context.unklinkListenSocket(self);
                    try @as(*Poll, @ptrCast(@alignCast(&self.s))).stop(self.s.context.loop);
                    try bsd.closeSocket(@as(*Poll, @ptrCast(@alignCast(&self.s))).fd());
                    self.s.next = self.s.context.loop.data.closed_head;
                    self.s.context.loop.data.closed_head = &self.s;
                    self.s.prev = @ptrCast(@alignCast(self.s.context));
                }
            }
        };

        p: Poll align(EXT_ALIGNMENT),
        timeout: u8,
        long_timeout: u8,
        low_prio_state: LowPriorityState,
        context: *Context,
        prev: ?*Self,
        next: ?*Self,

        pub fn isShutdown(self: *Self) bool {
            return self.p.pollType() == .socket_shutdown;
        }

        pub fn isClosed(self: *Self) bool {
            return self.prev == @as(*Self, @ptrCast(@alignCast(self.context)));
        }

        pub fn close(self: *Self, allocator: Allocator, code: i32, reason: ?*anyopaque) !*Self {
            if (!self.isClosed()) {
                switch (self.low_prio_state) {
                    .queued => {
                        if (self.low_prio_state == .queued) {
                            // unlink socket from low priority queue
                            if (self.prev) |prev| {
                                prev.next = self.next;
                            } else {
                                self.context.loop.data.low_prio_head = self.next;
                            }
                            self.prev = null;
                            self.next = null;
                            self.low_prio_state = .none;
                        }
                    },
                    else => self.context.unlinkSocket(self),
                }
                try @as(*Poll, @ptrCast(@alignCast(self))).stop(self.context.loop);
                try bsd.closeSocket(@as(*Poll, @ptrCast(@alignCast(self))).fd());

                // link socket to closed-list (ready deletion)
                self.next = self.context.loop.data.closed_head;
                self.context.loop.data.closed_head = self;

                // any socket with prev = context is marked as closed
                self.prev = @ptrCast(@alignCast(self.context));
                return self.context.on_close(allocator, self, code, reason);
            }
            return self;
        }

        pub fn getCtx(self: *Self) *Context {
            return self.context;
        }

        pub fn shutdown(self: *Self) !void {
            // TODO: maybe clean up handling here
            if (!self.isClosed() and !self.isShutdown()) {
                self.p.setPollType(.socket_shutdown);
                try self.p.change(self.context.loop, self.p.events() & SOCKET_READABLE);
                return bsd.shutdownSocket(@as(*Poll, @ptrCast(@alignCast(self))).fd());
            }
        }
    };

    if (build_opts.ssl_lib != .nossl and ssl) {
        return struct {
            const Self = @This();
            pub const Context = @import("context.zig").SocketCtx(ssl, SocketCtxExt, Loop, Poll, Self);

            pub const ListenSocket = struct {
                s: Self align(EXT_ALIGNMENT),

                pub fn close(self: *ListenSocket) !void {
                    if (!self.s.s.isClosed()) {
                        self.s.s.context.unklinkListenSocket(self);
                        try @as(*Poll, @ptrCast(@alignCast(&self.s.s))).stop(self.s.s.context.loop);
                        try bsd.closeSocket(@as(*Poll, @ptrCast(@alignCast(&self.s))).fd());
                        self.s.next = self.s.context.loop.data.closed_head;
                        self.s.context.loop.data.closed_head = &self.s;
                        self.s.prev = @ptrCast(@alignCast(self.s.context));
                    }
                }
            };

            s: BaseSocket,
            ssl: ?*c.SSL,
            ssl_write_wants_read: bool,
            ssl_read_wants_write: bool,
            ext: ?SocketExt,

            pub fn isShutdown(self: *Self) bool {
                return self.s.isShutdown() or (c.SSL_get_shutdown(self.ssl) & c.SSL_SENT_SHUTDOWN) == 1;
            }

            pub fn close(self: *Self, allocator: Allocator, code: i32, reason: ?*anyopaque) !*Self {
                _ = try self.s.close(allocator, code, reason);
                return self;
            }

            pub fn shutdown(self: *Self) !void {
                if (self.s.isClosed() or self.isShutdown()) {
                    const ctx = self.s.getCtx();
                    const loop = ctx.sc.getLoop();
                    const loop_ssl_data: *c.LoopSslData(Self) = @ptrCast(@alignCast(loop.data.ssl_data));
                    loop_ssl_data.ssl_read_input_length = 0;
                    loop_ssl_data.ssl_socket = &self.s;
                    loop_ssl_data.msg_more = false;

                    var ret: c_int = c.SSL_shutdown(self.ssl);
                    if (ret == 0) ret = c.SSL_shutdown(self.ssl);
                    if (ret < 0) {
                        switch (c.SSL_get_error(self.ssl, ret)) {
                            c.SSL_ERROR_SSL, c.SSL_ERROR_SYSCALL => c.ERR_clear_error(),
                            else => {},
                        }
                        try self.s.shutdown();
                    }
                }
            }

            pub fn sslOnOpen(self: *Self, allocator: Allocator, is_client: bool, ip: []u8) !*Self {
                const context = self.s.getCtx();
                const loop = context.getLoop();
                const loop_ssl_data: *c.LoopSslData(Self) = @ptrCast(@alignCast(loop.data.ssl_data));
                self.ssl = c.SSL_new(context.ssl_context);
                self.ssl_write_wants_read = 0;
                self.ssl_read_wants_write = 0;
                c.SSL_set_bio(self.ssl, loop_ssl_data.shared_rbio, loop_ssl_data.shared_wbio);
                c.BIO_up_ref(loop_ssl_data.shared_rbio);
                c.BIO_up_ref(loop_ssl_data.shared_wbio);
                switch (is_client) {
                    true => c.SSL_set_connect_state(self.ssl),
                    else => c.SSL_set_accept_state(self.ssl),
                }
                return context.on_open(allocator, self, is_client, ip);
            }

            pub fn sslOnClose(self: *Self, allocator: Allocator, code: i32, reason: ?*anyopaque) !*Self {
                const context = self.s.getCtx();
                c.SSL_free(self.ssl);
                return context.on_close(allocator, self, code, reason);
            }

            pub fn sslOnEnd(self: *Self, allocator: Allocator) !*Self {
                return self.close(allocator, 0, null);
            }

            pub fn sslOnData(self: *Self, allocator: Allocator, data: []u8) !*Self {
                _ = self; // autofix
                _ = allocator; // autofix
                _ = data; // autofix
            }
        };
    } else {
        return struct {
            const Self = @This();
            pub const Context = @import("context.zig").SocketCtx(ssl, SocketCtxExt, Loop, Poll, Self);

            pub const ListenSocket = struct {
                s: Self align(EXT_ALIGNMENT),

                pub fn close(self: *ListenSocket) !void {
                    if (!self.s.isClosed()) {
                        self.s.context.unklinkListenSocket(self);
                        try @as(*Poll, @ptrCast(@alignCast(&self.s))).stop(self.s.context.loop);
                        try bsd.closeSocket(@as(*Poll, @ptrCast(@alignCast(&self.s))).fd());
                        self.s.next = self.s.context.loop.data.closed_head;
                        self.s.context.loop.data.closed_head = &self.s;
                        self.s.prev = @ptrCast(@alignCast(self.s.context));
                    }
                }
            };

            p: Poll align(EXT_ALIGNMENT),
            timeout: u8,
            long_timeout: u8,
            low_prio_state: LowPriorityState,
            context: *Context,
            prev: ?*Self,
            next: ?*Self,
            ext: ?SocketExt,

            pub fn isClosed(self: *Self) bool {
                return self.prev == @as(*Self, @ptrCast(@alignCast(self.context)));
            }

            pub fn isShutdown(self: *Self) bool {
                return self.p.pollType() == .socket_shutdown;
            }

            pub fn close(self: *Self, allocator: Allocator, code: i32, reason: ?*anyopaque) !*Self {
                if (!self.isClosed()) {
                    switch (self.low_prio_state) {
                        .queued => {
                            if (self.low_prio_state == .queued) {
                                // unlink socket from low priority queue
                                if (self.prev) |prev| {
                                    prev.next = self.next;
                                } else {
                                    self.context.loop.data.low_priority_head = self.next;
                                }
                                self.prev = null;
                                self.next = null;
                                self.low_prio_state = .none;
                            }
                        },
                        else => self.context.unlinkSocket(self),
                    }
                    try @as(*Poll, @ptrCast(@alignCast(self))).stop(self.context.loop);
                    try bsd.closeSocket(@as(*Poll, @ptrCast(@alignCast(self))).fd());

                    // link socket to closed-list (ready deletion)
                    self.next = self.context.loop.data.closed_head;
                    self.context.loop.data.closed_head = self;

                    // any socket with prev = context is marked as closed
                    self.prev = @ptrCast(@alignCast(self.context));
                    return self.context.on_close(allocator, self, code, reason);
                }
                return self;
            }

            pub fn closeConnecting(self: *Self) !*Self {
                if (!self.isClosed()) {
                    self.context.unlinkSocket(self);
                    try @as(*Poll, @ptrCast(@alignCast(self))).stop(self.context.loop);
                    try bsd.closeSocket(@as(*Poll, @ptrCast(@alignCast(self))).fd());

                    // link socket to closed-list (ready for deletion after this iteration)
                    self.next = self.context.loop.data.closed_head;
                    self.context.loop.data.closed_head = null;

                    // Any socket where prev = context is marked as closed
                    self.prev = @ptrCast(@alignCast(self.context));
                }
                return self;
            }

            pub fn shutdown(self: *Self) !void {
                // TODO: maybe clean up handling here
                if (!self.isClosed() and !self.isShutdown()) {
                    self.p.setPollType(.socket_shutdown);
                    try self.p.change(self.context.loop, self.p.events() & SOCKET_READABLE);
                    return bsd.shutdownSocket(@as(*Poll, @ptrCast(@alignCast(self))).fd());
                }
            }

            pub fn getCtx(self: *Self) *Context {
                return self.context;
            }

            pub fn flush(self: *Self) !void {
                if (!self.isShutdown()) {
                    try bsd.flushSocket(@as(*Poll, @ptrCast(@alignCast(self))).fd());
                }
            }

            pub fn write(self: *Self, data: []const u8, msg_more: bool) !usize {
                if (self.isClosed() or self.isShutdown()) return 0;
                const written = try bsd.send(self.p.fd(), data, msg_more);
                if (written != data.len) {
                    self.context.loop.data.last_write_failed = true;
                    try self.p.change(self.context.loop, SOCKET_READABLE | SOCKET_WRITABLE);
                }
                return written;
            }

            pub fn getExt(self: *Self) *?SocketExt {
                return &self.ext;
            }

            pub fn setTimeout(self: *Self, seconds: u32) void {
                self.timeout = switch (seconds) {
                    0 => 255,
                    else => @intCast((self.context.timestamp + ((seconds + 3) >> 2)) % 240),
                };
            }
        };
    }
}

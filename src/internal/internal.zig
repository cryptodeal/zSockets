const bsd = @import("../bsd.zig");
const build_opts = @import("build_opts");
const context = @import("../context.zig");
const events = @import("events.zig");
const ssl_ = @import("../crypto/ssl.zig");
const std = @import("std");

const EXT_ALIGNMENT = @import("../constants.zig").EXT_ALIGNMENT;
const InternalSslSocket = ssl_.InternalSslSocket;
const Loop = @import("../loop.zig").Loop;
const SocketCtx = context.SocketCtx;
const SocketCtxOpts = context.SocketCtxOpts;

const Allocator = std.mem.Allocator;
pub const InternalAsync = anyopaque;
const Poll = events.Poll;
pub const SocketDescriptor = std.posix.socket_t;

pub const Timer = switch (build_opts.event_loop_lib) {
    .io_uring => @import("../io_uring/internal.zig").Timer,
    else => anyopaque,
};

pub const LowPriorityState = enum(u16) {
    none = 0,
    queued = 1,
    prev_queued_in_iter = 2,
};

/// Specifies the type of poll (and what is polled for).
pub const PollType = enum(u4) {
    // 2 first bits
    socket = 0,
    socket_shutdown = 1,
    semi_socket = 2,
    callback = 3,

    // Two last bits
    polling_out = 4,
    polling_in = 8,
    _,
};

pub const Socket = struct {
    p: Poll align(EXT_ALIGNMENT),
    timeout: u8,
    long_timeout: u8,
    low_prio_state: u16,
    context: *SocketCtx,
    prev: *Socket,
    next: *Socket,

    pub fn isClosed(self: *Socket, _: bool) bool {
        return self.prev == @as(*Socket, @ptrCast(@alignCast(self.context)));
    }

    pub fn isShutdown(self: *Socket, ssl: bool) bool {
        if (build_opts.ssl_lib != .nossl and ssl) {
            return @as(*InternalSslSocket, @ptrCast(@alignCast(self))).isShutdown();
        } else return self.p.internalPollType() == .socket_shutdown;
    }

    pub fn socketCtx(self: *Socket, _: bool) *SocketCtx {
        return self.context;
    }

    pub fn flush(self: *Socket, _: bool) !void {
        if (!self.isShutdown(false)) {
            try bsd.bsdSocketFlush(@as(*Poll, @ptrCast(@alignCast(self))).fd());
        }
    }

    pub fn write(self: *Socket, ssl: bool, data: []const u8, msg_more: bool) !usize {
        if (build_opts.ssl_lib != .nossl and ssl) return ssl_.internalSslSocketWrite(@ptrCast(@alignCast(self)), data, msg_more);
        if (self.isClosed(ssl) or self.isShutdown(ssl)) return 0;
        const written = try bsd.bsdSend(self.p.fd(), data, msg_more);
        if (written != data.len) {
            self.context.loop.data.last_write_failed = true;
            try self.p.change(self.context.loop, events.SOCKET_READABLE | events.SOCKET_WRITABLE);
        }
        return written;
    }

    pub fn getExt(self: *Socket, ssl: bool) ?*anyopaque {
        if (build_opts.ssl_lib != .nossl and ssl) {
            return ssl_.internalSslSocketExt(self);
        } else return @as([*]Socket, @ptrCast(@alignCast(self))) + 1;
    }

    pub fn setTimeout(self: *Socket, _: bool, seconds: u32) void {
        self.timeout = switch (seconds) {
            0 => 255,
            else => (self.context.timestamp + ((seconds + 3) >> 2)) % 240,
        };
    }
};

pub const InternalCallback = struct {
    p: Poll align(EXT_ALIGNMENT),
    loop: *Loop,
    cb_expects_the_loop: bool,
    leave_poll_ready: bool,
    cb: *const fn (self: *InternalCallback) anyerror!void,
};

pub const ListenSocket = struct {
    s: Socket align(EXT_ALIGNMENT),
    socket_ext_size: u32,
};

pub const UdpSocket = ?*anyopaque;

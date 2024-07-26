const build_opts = @import("build_opts");
const builtin = @import("builtin");
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const InternalAsync = anyopaque;
pub const Socket = @import("internal/socket.zig");
pub const SocketDescriptor = std.posix.socket_t;

pub const Timer = switch (build_opts.event_loop_lib) {
    .io_uring => @compileError("IO_URING event loop is not yet implemented"),
    else => anyopaque,
};

pub const LowPriorityState = enum(u16) {
    none = 0,
    queued = 1,
    prev_queued_in_iter = 2,
    _,
};

/// Specifies the type of poll (and what is polled for).
pub const PollType = enum(u8) {
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

// constants

/// 512kb shared receive buffer.
pub const RECV_BUFFER_LENGTH = 524288;
/// Timeout granularity specifies +/- 4 seconds from set timeout.
pub const TIMEOUT_GRANULARITY = 4;
/// 32 byte padding of receive buffer ends.
pub const RECV_BUFFER_PADDING = 32;
/// Guaranteed alignment of extension memory.
pub const EXT_ALIGNMENT = 16;

pub const SOCKET_READABLE = switch (build_opts.event_loop_lib) {
    .epoll, .kqueue => @import("events/epoll_kqueue.zig").SOCKET_READABLE,
    else => |v| @compileError("Unsupported event loop library " ++ @tagName(v)),
};

pub const SOCKET_WRITABLE = switch (build_opts.event_loop_lib) {
    .epoll, .kqueue => @import("events/epoll_kqueue.zig").SOCKET_WRITABLE,
    else => |v| @compileError("Unsupported event loop library " ++ @tagName(v)),
};

pub const SOCKET_ERROR = switch (builtin.target.os.tag) {
    .windows => std.os.INVALID_SOCKET,
    else => -1,
};

/// Options specifying ownership of port.
pub const PortOptions = enum {
    /// Default port options.
    default,
    /// Port is owned by zSocket and will not be shared.
    exclusive,
};

/// Options for socket contexts.
pub const SocketCtxOpts = struct {
    key_file_path: ?[:0]const u8 = null,
    cert_file_path: ?[:0]const u8 = null,
    passphrase: ?[:0]const u8 = null,
    dh_params_file_path: ?[:0]const u8 = null,
    ca_file_path: ?[:0]const u8 = null,
    ssl_ciphers: ?[:0]const u8 = null,
    ssl_prefer_low_mem_usg: bool = false, // TODO: rename field/apply to TCP as well
};

pub const SslT = enum { boringssl, openssl, wolfssl, nossl };

pub const EventLoopT = enum { io_uring, epoll, kqueue, libuv, gcd, asio };

pub fn InternalCallback(comptime Poll: type, comptime Loop: type) type {
    return struct {
        const Self = @This();
        p: Poll align(EXT_ALIGNMENT),
        loop: *Loop,
        cb_expects_the_loop: bool,
        leave_poll_ready: bool,
        cb: *const fn (allocator: Allocator, self: *Self) anyerror!void,
    };
}

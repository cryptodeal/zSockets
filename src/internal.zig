const build_opts = @import("build_opts");
const builtin = @import("builtin");
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const InternalAsync = anyopaque;
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
    .epoll, .kqueue => @import("events/epoll_kqueue/constants.zig").SOCKET_READABLE,
    else => |v| @compileError("Unsupported event loop library " ++ @tagName(v)),
};

pub const SOCKET_WRITABLE = switch (build_opts.event_loop_lib) {
    .epoll, .kqueue => @import("events/epoll_kqueue/constants.zig").SOCKET_WRITABLE,
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

pub const Extension = struct {
    ptr: ?*anyopaque = null,
    ptr_len: usize = 0,
    free_cb: ?*const fn (allocator: Allocator, v: ?*anyopaque) void = null,
    dupe_empty: ?*const fn (allocator: Allocator) Allocator.Error!?*anyopaque = null,

    pub fn init(allocator: Allocator, comptime T: type) !Extension {
        const TypeInfo = @typeInfo(T);
        std.debug.assert(TypeInfo == .Struct and (TypeInfo.Struct.layout == .@"packed" or TypeInfo.Struct.layout == .@"extern"));
        const buffer = try allocator.alloc(u8, @sizeOf(T));
        return .{
            .ptr = buffer.ptr,
            .ptr_len = buffer.len,
        };
    }

    pub fn deinit(self: *Extension, allocator: Allocator) void {
        if (self.ptr) |p| allocator.free(@as([*]u8, @ptrCast(@alignCast(p)))[0..self.ptr_len]);
        self.ptr = null;
        self.ptr_len = 0;
        self.free_cb = null;
        self.dupe_empty = null;
    }

    pub fn dupeEmpty(self: *Extension, allocator: Allocator) !Extension {
        const buffer = try allocator.alloc(u8, self.ptr_len);
        return .{
            .ptr = buffer.ptr,
            .ptr_len = buffer.len,
            .free_cb = self.free_cb,
            .dupe_empty = self.dupe_empty,
        };
    }

    pub fn copyTo(self: *Extension, other: *Extension) void {
        const other_bytes = @as([*]u8, @ptrCast(@alignCast(other.ptr)));
        const self_bytes = @as([*]u8, @ptrCast(@alignCast(self.ptr)));
        if (self.ptr_len == other.ptr_len) {
            @memcpy(other_bytes[0..other.ptr_len], self_bytes[0..self.ptr_len]);
        } else if (self.ptr_len < other.ptr_len) {
            @memcpy(other_bytes[0..self.ptr_len], self_bytes[0..self.ptr_len]);
        } else {
            @memcpy(other_bytes[0..other.ptr_len], self_bytes[0..other.ptr_len]);
        }
    }
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

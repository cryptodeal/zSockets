const build_opts = @import("build_opts");
const constants = @import("constants.zig");
const internal = @import("internal/internal.zig");
const loop_ = @import("loop.zig");
const ssl = @import("crypto/ssl.zig");
const std = @import("std");

const Allocator = std.mem.Allocator;
const EXT_ALIGNMENT = constants.EXT_ALIGNMENT;
const internalLoopLink = loop_.internalLoopLink;
const ListenSocket = internal.ListenSocket;
const Loop = loop_.Loop;
const LowPriorityState = internal.LowPriorityState;
const Socket = internal.Socket;
const SocketDescriptor = internal.SocketDescriptor;

// default function pointers

pub fn isLowPriorityHandler(_: *Socket) LowPriorityState {
    return .none;
}

pub fn socketCtxTimestamp(_: i32, context: *SocketCtx) u16 {
    return context.timestamp;
}

pub fn listenSocketClose(ssl_: i32, ls: *ListenSocket) void {
    _ = ssl_; // autofix
    _ = ls; // autofix
}

pub const SocketCtx = struct {
    loop: *Loop align(EXT_ALIGNMENT),
    global_tick: u32,
    timestamp: u8,
    long_timestamp: u8,
    head_sockets: ?*Socket,
    head_listen_sockets: ?*ListenSocket,
    iterator: ?*Socket,
    prev: ?*SocketCtx,
    next: ?*SocketCtx,

    on_pre_open: ?*const fn (fd: SocketDescriptor) anyerror!SocketDescriptor,
    on_open: *const fn (s: *Socket, is_client: bool, ip: []u8) anyerror!*Socket,
    on_data: *const fn (s: *Socket, data: []u8) anyerror!*Socket,
    on_writable: *const fn (s: *Socket) anyerror!*Socket,
    on_close: *const fn (s: *Socket, code: i32, reason: ?*anyopaque) anyerror!*Socket,
    // on_timeout: *const fn (s: *SocketCtx) anyerror!void,
    on_socket_timeout: *const fn (s: *Socket) anyerror!*Socket,
    on_socket_long_timeout: *const fn (s: *Socket) anyerror!*Socket,
    on_end: *const fn (s: *Socket) anyerror!*Socket,
    on_connect_error: *const fn (s: *Socket, code: i32) anyerror!*Socket,
    is_low_priority: *const fn (s: *Socket) LowPriorityState,

    pub fn init(allocator: Allocator, ssl_: bool, loop: *Loop, context_ext_size: usize, opts: SocketCtxOpts) anyerror!*SocketCtx {
        if (build_opts.ssl_lib != .nossl and ssl_) {
            return @ptrCast(@alignCast(try ssl.internalCreateSslSocketCtx(allocator, loop, context_ext_size, opts)));
        }
        const buf = try allocator.alloc(u8, @sizeOf(SocketCtx) + context_ext_size);
        const context: *SocketCtx = @ptrCast(@alignCast(buf));
        context.loop = loop;
        context.head_sockets = null;
        context.head_listen_sockets = null;
        context.iterator = null;
        context.next = null;
        context.is_low_priority = isLowPriorityHandler;
        context.timestamp = 0;
        context.long_timestamp = 0;
        context.global_tick = 0;
        context.on_pre_open = null;

        internalLoopLink(loop, context);
        return context;
    }

    pub fn socketCtxLoop(self: *SocketCtx, _: bool) *Loop {
        return self.loop;
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

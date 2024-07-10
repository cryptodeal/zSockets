const events = @import("events.zig");
const socket = @import("../socket.zig");
const std = @import("std");

const EXT_ALIGNMENT = @import("../zsockets.zig").EXT_ALIGNMENT;
const Loop = @import("../loop.zig").Loop;

const Poll = events.Poll;
const SocketDescriptor = socket.SocketDescriptor;

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
};

pub const Socket = struct {
    p: Poll align(EXT_ALIGNMENT),
    timeout: u8,
    long_timeout: u8,
    low_prio_state: u16,
    context: *SocketCtx,
    prev: *Socket,
    next: *Socket,
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

pub const SocketCtx = struct {
    loop: *Loop align(EXT_ALIGNMENT),
    global_tick: u32,
    timestamp: u8,
    long_timestamp: u8,
    head_sockets: *Socket,
    head_listen_sockets: *ListenSocket,
    iterator: *Socket,
    prev: *SocketCtx,
    next: *SocketCtx,

    on_pre_open: *const fn (fd: SocketDescriptor) anyerror!SocketDescriptor,
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
};

pub const UdpSocket = ?*anyopaque;

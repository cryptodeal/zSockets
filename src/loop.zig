const build_opts = @import("build_opts");
const constants = @import("internal/constants.zig");
const bsd = @import("bsd/root.zig");
const std = @import("std");
const Extension = @import("extension.zig");
const timerSet = @import("eventing/impl.zig").timerSet;
const SocketContext = @import("socket_context.zig");
const Loop = @import("eventing/impl.zig").Loop;
const Poll = @import("eventing/impl.zig").Poll;
const asyncWakeup = @import("eventing/impl.zig").asyncWakeup;
const InternalCallback = @import("internal_callback.zig");
const internal = @import("internal/internal.zig");
const socket_readable = @import("eventing/impl.zig").socket_readable;
const socket_writable = @import("eventing/impl.zig").socket_writable;
const timeout_granularity = @import("internal/constants.zig").timeout_granularity;
const Socket = @import("socket.zig");
const ListenSocket = @import("listen_socket.zig");
const openssl = @import("crypto/openssl.zig");

pub fn wakeupLoop(loop: *Loop) void {
    return asyncWakeup(loop.data.wakeup_async.?);
}

pub fn link(loop: *Loop, context: *SocketContext) void {
    context.next = loop.data.head;
    context.prev = null;
    if (loop.data.head) |head| head.prev = context;
    loop.data.head = context;
}

pub fn loopUnlink(loop: *Loop, context: *SocketContext) void {
    if (loop.data.head == context) {
        loop.data.head = context.next;
        if (loop.data.head) |head| head.prev = null;
    } else {
        context.prev.?.next = context.next;
        if (context.next) |next| next.prev = context.prev;
    }
}

pub fn internalTimerSweep(allocator: std.mem.Allocator, io: std.Io, loop: *Loop) !void {
    const loop_data = &loop.data;
    loop_data.iterator = loop_data.head;
    while (loop_data.iterator) |context| : (loop_data.iterator = context.next) {
        context.global_tick += 1;
        const short_ticks = context.global_tick % 240;
        context.timestamp = @intCast(short_ticks);
        const long_ticks = (context.global_tick / 15) % 240;
        context.long_timestamp = @intCast(long_ticks);
        var s = context.head_sockets;
        next_context: while (s) |_| {
            // std.debug.print("internalTimerSweep socket ptr: {d}\n", .{@intFromPtr(s)});
            while (true) {
                if (short_ticks == s.?.timeout or long_ticks == s.?.long_timeout) {
                    break;
                }
                s = s.?.next;
                if (s == null) {
                    break :next_context;
                }
            }
            context.iterator = s;
            if (@as(u8, @intCast(short_ticks)) == s.?.timeout) {
                s.?.timeout = 255;
                _ = try context.on_socket_timeout(allocator, io, s.?);
            }
            if (context.iterator == s and @as(u8, @intCast(long_ticks)) == s.?.long_timeout) {
                s.?.long_timeout = 255;
                _ = try context.on_socket_long_timeout.?(allocator, io, s.?);
            }
            if (s == context.iterator) {
                s = s.?.next;
            } else {
                s = context.iterator;
            }
        }
        context.iterator = null;
    }
}

const max_low_prio_sockets_per_loop_iteration = 5;

fn handleLowPrioritySockets(loop: *Loop) void {
    const loop_data = &loop.data;
    loop_data.low_priority_budget = max_low_prio_sockets_per_loop_iteration;
    var s: ?*Socket = loop_data.low_priority_head;
    while (s != null and loop_data.low_priority_budget > 0) : ({
        s = loop_data.low_priority_head;
        loop_data.low_priority_budget -= 1;
    }) {
        loop_data.low_priority_head = s.?.next;
        if (s.?.next) |next| next.prev = null;
        s.?.next = null;
        s.?.context.linkSocket(s.?);
        s.?.p.change(s.?.context.loop, s.?.p.events() | socket_readable);
        s.?.low_priority_state = .prev_queued;
    }
}

fn freeClosedSockets(allocator: std.mem.Allocator, loop: *Loop) void {
    if (loop.data.closed_head) |_| {
        var maybe_s = loop.data.closed_head;
        while (maybe_s) |s| {
            const next = s.next;
            if (!s.ls_field_ptr) {
                s.deinit(allocator, loop);
            } else {
                var ls: *ListenSocket = @fieldParentPtr("s", s);
                ls.deinit(allocator, loop);
            }
            maybe_s = next;
        }
        loop.data.closed_head = null;
    }
}

fn sweepTimerCb(allocator: std.mem.Allocator, io: std.Io, cb: *InternalCallback) !void {
    try internalTimerSweep(allocator, io, cb.loop);
}

fn loopIterationNumber(loop: *const Loop) i64 {
    return loop.data.iteration_count;
}

pub fn pre(allocator: std.mem.Allocator, io: std.Io, loop: *Loop) !void {
    loop.data.iteration_count += 1;
    handleLowPrioritySockets(loop);
    try loop.data.pre_cb(allocator, io, loop);
}

pub fn post(allocator: std.mem.Allocator, io: std.Io, loop: *Loop) !void {
    freeClosedSockets(allocator, loop);
    try loop.data.post_cb(allocator, io, loop);
}

// TODO: unused parameter is `ssl: bool` for future SSL support
pub fn adoptAcceptedSocket(allocator: std.mem.Allocator, io: std.Io, ssl: bool, context: *SocketContext, accepted_fd: std.posix.socket_t, addr_ip: []u8, extension: Extension) !*Socket {
    if (build_opts.ssl_impl != .no_ssl) {
        if (ssl) {
            return &(try openssl.adoptAcceptedSocket(allocator, io, @fieldParentPtr("sc", context), accepted_fd, addr_ip, extension)).s;
        }
    }
    const res = try allocator.create(Socket);
    try internal.adoptAcceptedSocket(allocator, io, res, context, accepted_fd, addr_ip, extension);
    return res;
}

pub fn internalDispatchReadyPoll(allocator: std.mem.Allocator, io: std.Io, p: *Poll, err: u32, events: u32) !void {
    outer: switch (p.pollType()) {
        .callback => {
            const cb: *InternalCallback = @fieldParentPtr("p", p);
            if (!cb.leave_poll_ready) {
                if (build_opts.event_backend != .libuv) {
                    _ = p.acceptEvent();
                }
            }
            try cb.cb.?(allocator, io, if (cb.expects_loop) @ptrCast(@alignCast(cb.loop)) else cb);
        },
        .semi_socket => {
            if (p.events() == socket_writable) {
                const s: *Socket = @fieldParentPtr("p", p);
                if (err != 0) {
                    _ = try s.context.on_connect_error.?(allocator, io, s, 0);
                    _ = s.closeConnecting(false);
                } else {
                    p.change(s.context.loop, socket_readable);
                    bsd.socketNoDelay(p.fd(), true);
                    p.setType(.socket);
                    s.setTimeout(false, 0);
                    _ = try s.context.on_open(allocator, io, s, true, &.{});
                }
            } else {
                const listen_socket: *ListenSocket = @fieldParentPtr("s", @as(*Socket, @fieldParentPtr("p", p)));
                var addr: bsd.Addr = undefined;
                var client_fd: std.posix.socket_t = undefined;
                inner: while (bsd.acceptSocket(p.fd(), &addr)) |fd| {
                    client_fd = fd;
                    const context = listen_socket.s.context;
                    if (context.on_pre_open == null or (try context.on_pre_open.?(allocator, io, client_fd, @as([*]u8, @ptrCast(@alignCast(addr.ip)))[0..@as(usize, @intCast(addr.ip_length))])) == client_fd) {
                        // TODO: update lamda `ext` creation/deletion across varying types to conform to this pattern (when needed)
                        _ = try adoptAcceptedSocket(allocator, io, false, context, client_fd, @as([*]u8, @ptrCast(@alignCast(addr.ip)))[0..@as(usize, @intCast(addr.ip_length))], listen_socket.s.ext);
                        if (listen_socket.s.isClosed(false)) {
                            break :inner;
                        }
                    }
                } else |_| {}
            }
        },
        .socket_shutdown, .socket => {
            var s: *Socket = @fieldParentPtr("p", p);
            if (err != 0) {
                s = try s.close(allocator, io, false, 0, null);
                return;
            }
            if (events & socket_writable != 0) {
                s.context.loop.data.last_write_failed = false;
                s = try s.context.on_writable(allocator, io, s);
                if (s.isClosed(false)) {
                    return;
                }
                if (!s.context.loop.data.last_write_failed or s.isShutdown(false)) {
                    s.p.change(s.context.loop, s.p.events() & socket_readable);
                }
            }
            if (events & socket_readable != 0) {
                if (s.context.is_low_priority(s) != .not_queued) {
                    if (s.low_priority_state == .prev_queued) {
                        s.low_priority_state = .not_queued;
                    } else if (s.context.loop.data.low_priority_budget > 0) {
                        s.context.loop.data.low_priority_budget -= 1;
                    } else {
                        s.p.change(s.context.loop, s.p.events() & socket_writable);
                        s.context.unlinkSocket(s);
                        s.prev = null;
                        s.next = s.context.loop.data.low_priority_head;
                        if (s.next) |next| next.prev = s;
                        s.context.loop.data.low_priority_head = s;
                        s.low_priority_state = .in_queue;

                        break :outer;
                    }
                }
                var length: isize = bsd.recv(s.p.fd(), s.context.loop.data.recv_buf[constants.recv_buffer_padding .. constants.recv_buffer_padding + constants.recv_buffer_length], 0);
                while (true) : (length = bsd.recv(s.p.fd(), s.context.loop.data.recv_buf[constants.recv_buffer_padding .. constants.recv_buffer_padding + constants.recv_buffer_length], 0)) {
                    if (length > 0) {
                        s = try s.context.on_data(allocator, io, s, s.context.loop.data.recv_buf[constants.recv_buffer_padding .. constants.recv_buffer_padding + @as(usize, @intCast(length))]);
                        if (length == constants.recv_buffer_length and !s.isClosed(false)) continue;
                    } else if (length == 0) {
                        if (s.isShutdown(false)) {
                            s = try s.close(allocator, io, false, 0, null);
                        } else {
                            s.p.change(s.context.loop, s.p.events() & socket_writable);
                            s = try s.context.on_end(allocator, io, s);
                        }
                    } else if (length == -1 and !bsd.wouldBlock()) {
                        s = try s.close(allocator, io, false, 0, null);
                    }
                    break;
                }
            }
        },
        else => {},
    }
}

pub fn integrate(loop: *Loop) void {
    timerSet(loop.data.sweep_timer.?, @ptrCast(@alignCast(&sweepTimerCb)), timeout_granularity * 1000, timeout_granularity * 1000);
}

pub fn getExt(loop: *Loop, comptime T: type) ?*T {
    return @ptrCast(@alignCast(loop.ext));
}

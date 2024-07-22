const bsd = @import("bsd.zig");
const build_opts = @import("build_opts");
const internal = @import("internal.zig");
const std = @import("std");

const Extensions = @import("zsockets.zig").Extensions;

const Allocator = std.mem.Allocator;
const RECV_BUFFER_LENGTH = internal.RECV_BUFFER_LENGTH;
const RECV_BUFFER_PADDING = internal.RECV_BUFFER_PADDING;
const SocketDescriptor = internal.SocketDescriptor;
const SOCKET_ERROR = internal.SOCKET_ERROR;
const SOCKET_READABLE = internal.SOCKET_READABLE;
const SOCKET_WRITABLE = internal.SOCKET_WRITABLE;
const Timer = internal.Timer;

pub fn LoopData(comptime Loop: type, comptime Socket: type, comptime SocketCtx: type) type {
    return struct {
        sweep_timer: ?*Timer,
        wakeup_async: ?*anyopaque,
        last_write_failed: bool,
        head: ?*SocketCtx,
        iterator: ?*SocketCtx,
        recv_buf: []u8 = &[_]u8{},
        ssl_data: ?*anyopaque,
        pre_cb: *const fn (allocator: Allocator, loop: *Loop) anyerror!void,
        post_cb: *const fn (allocator: Allocator, loop: *Loop) anyerror!void,
        closed_head: ?*Socket,
        low_priority_head: ?*Socket,
        low_priority_budget: i32,
        iteration_nr: i64,
    };
}

pub fn internalLoopPre(allocator: Allocator, loop: anytype) !void {
    loop.data.iteration_nr += 1;
    try internalHandleLowPrioritySockets(loop);
    try loop.data.pre_cb(allocator, loop);
}

const MAX_LOW_PRIO_SOCKETS_PER_LOOP_ITERATION = 5;

fn internalHandleLowPrioritySockets(loop: anytype) !void {
    const loop_data = &loop.data;
    var s: ?*@TypeOf(loop.*).Socket = undefined;

    loop_data.low_priority_budget = MAX_LOW_PRIO_SOCKETS_PER_LOOP_ITERATION;
    s = loop_data.low_priority_head;
    while (s != null and loop_data.low_priority_budget > 0) : ({
        s = loop_data.low_priority_head;
        loop_data.low_priority_budget -= 1;
    }) {
        // unlink this socket from low priority queue
        loop_data.low_priority_head = s.?.next;
        if (s.?.next) |next| next.prev = null;
        s.?.next = null;
        s.?.context.linkSocket(s.?);
        try s.?.p.change(s.?.getCtx().loop, s.?.p.events() | SOCKET_READABLE);
        s.?.low_prio_state = .prev_queued_in_iter;
    }
}

pub fn internalTimerSweep(allocator: Allocator, loop: anytype) !void {
    const loop_data = &loop.data;
    loop_data.iterator = loop_data.head;
    // iterate through all socket contexts in the loop
    while (loop_data.iterator) |iter| : (loop_data.iterator = iter.next) {
        const context = iter;
        // Update this context's timestamps
        // (TODO(cryptodeal): this could be moved to loop and done once)
        context.global_tick += 1;
        context.timestamp = @intCast(context.global_tick % 240);
        const short_ticks = context.timestamp;
        context.long_timestamp = @intCast((context.global_tick / 15) % 240);
        const long_ticks = context.long_timestamp;

        // start from head
        var maybe_s = context.head_sockets;
        next_context: while (maybe_s) |s| {
            // Seek until end or timeout found (tightest loop)
            while (true) {
                // read one random cache line here
                if (short_ticks == s.timeout or long_ticks == s.long_timeout) {
                    break;
                }

                // Did we reach the end without finding a timeout?
                if (s.next != null and s == s.next.?) break :next_context;
            }

            // Need to emit timeout (slow path)
            context.iterator = s;
            if (short_ticks == s.timeout) {
                s.timeout = 255;
                _ = try context.on_socket_timeout(allocator, s);
            }
            if (context.iterator != null and context.iterator.? == s and long_ticks == s.long_timeout) {
                s.long_timeout = 255;
                _ = try context.on_socket_long_timeout.?(allocator, s);
            }

            // Check for unlink/link (if the event handler did not
            // modify the chain, we step 1)
            if (context.iterator != null and context.iterator.? == s) {
                maybe_s = s.next;
            } else {
                // iterator changed by event handler cb
                maybe_s = context.iterator;
            }
        }
        // set context.iterator to null since we're done iterating.
        context.iterator = null;
    }
}

pub fn internalDispatchReadyPoll(allocator: Allocator, comptime CallbackType: type, comptime SocketType: type, p: anytype, err: u32, events_: u32) !void {
    switch (p.pollType()) {
        .callback => {
            const cb: *CallbackType = @ptrCast(@alignCast(p));
            if (!cb.leave_poll_ready) {
                if (build_opts.event_loop_lib == .libuv) {
                    // TODO: internalAcceptPollEvent(p)
                }
                try cb.cb(allocator, if (cb.cb_expects_the_loop) @ptrCast(@alignCast(cb.loop)) else @ptrCast(@alignCast(&cb.p)));
            }
        },
        .semi_socket => {
            // connect and listen sockets are both semi-sockets,
            // but each polls for different events.
            if (p.events() == SOCKET_WRITABLE) {
                var s: *SocketType = @ptrCast(@alignCast(p));
                // it's possible we arrive  here with an error
                if (err != 0) {
                    // Emit error, close but don't emit `on_close`
                    _ = try s.context.on_connect_error.?(s, 0);
                    _ = try s.closeConnecting();
                } else {
                    // all sockets poll for readable
                    try p.change(s.context.loop, SOCKET_READABLE);
                    // always use tcp nodelay
                    try bsd.setNodelay(p.fd(), true);
                    // now have a proper socket
                    p.setPollType(.socket);
                    // if using connection timeout, need to reset
                    s.setTimeout(0);
                    _ = try s.context.on_open(allocator, s, true, &.{});
                }
            } else {
                const listen_socket: *SocketType.ListenSocket = @ptrCast(@alignCast(p));
                var addr: bsd.BsdAddr = undefined;
                var client_fd = try bsd.acceptSocket(p.fd(), &addr);
                if (client_fd == SOCKET_ERROR) {
                    // TODO: start timer here
                } else {
                    // TODO: stop timer here if any
                    client_fd = try bsd.acceptSocket(p.fd(), &addr);
                    blk: while (client_fd != SOCKET_ERROR) : (client_fd = bsd.acceptSocket(p.fd(), &addr) catch break :blk) {
                        const context: *SocketType.Context = listen_socket.s.getCtx();
                        // determine whether to export fd or keep here (event can be unset)
                        if (context.on_pre_open == null or context.on_pre_open.?(client_fd) == client_fd) {
                            // adopt the newly accepted socket
                            _ = try adoptAcceptedSocket(allocator, SocketType, @TypeOf(p.*), context, client_fd, addr.getIp());

                            // Exit accept loop if listen socket was closed in on_open handler
                            if (listen_socket.s.isClosed()) break;
                        }
                    }
                }
            }
        },
        .socket_shutdown, .socket => blk: {
            // only use s, not p after this point
            var s: *SocketType = @ptrCast(@alignCast(p));
            if (err != 0) {
                // TODO: decide on exit code to use here
                s = try s.close(allocator, 0, null);
                return;
            }
            if ((events_ & SOCKET_WRITABLE) == 1) {
                // N.B. if failed write of a socket of one loop,
                // then adopted to another loop, this is WRONG.
                // This is an extreme edge case.
                s.context.loop.data.last_write_failed = false;
                s = try s.context.on_writable(allocator, s);
                if (s.isClosed()) return;

                // If no failed write or if shut down, stop
                // polling for more writable
                if (!s.context.loop.data.last_write_failed or s.isShutdown()) {
                    try s.p.change(s.getCtx().loop, s.p.events() & SOCKET_READABLE);
                }
            }
            if ((events_ & SOCKET_READABLE) == 1) {
                // Contexts may prioritize down sockets that are currently readable (e.g.
                // SSL handshake). SSL handshakes are CPU intensive, so prefer to limit the
                // number of handshakes per loop iteration, and move the rest to the
                // low-priority queue.
                if (@intFromEnum(s.context.is_low_prio(s)) != 0) {
                    if (s.low_prio_state == .prev_queued_in_iter) {
                        // socket delayed; must process incoming data for one iteration
                        s.low_prio_state = .none;
                    } else if (s.context.loop.data.low_priority_budget > 0) {
                        // still have budget for this iteration, continue per usual
                        s.context.loop.data.low_priority_budget -= 1;
                    } else {
                        try s.p.change(s.getCtx().loop, s.p.events() & SOCKET_WRITABLE);
                        s.context.unlinkSocket(s);

                        // Link this socket to the low-priority queue - we use a LIFO
                        // queue, to prioritize newer clients that are maybe not already
                        // timeouted. This works better irl with smaller client-timeouts
                        // under high load
                        s.prev = null;
                        s.next = s.context.loop.data.low_priority_head;
                        if (s.next) |next| next.prev = s;
                        s.context.loop.data.low_priority_head = s;
                        s.low_prio_state = .queued;

                        break :blk;
                    }
                }

                var length: usize = undefined;
                length = bsd.recv(s.p.fd(), s.context.loop.data.recv_buf[RECV_BUFFER_PADDING..][0..RECV_BUFFER_LENGTH], 0) catch {
                    s = try s.close(allocator, 0, null);
                    return;
                };
                while (true) : ({
                    length = bsd.recv(s.p.fd(), s.context.loop.data.recv_buf[RECV_BUFFER_PADDING..][0..RECV_BUFFER_LENGTH], 0) catch {
                        s = try s.close(allocator, 0, null);
                        return;
                    };
                }) {
                    if (length > 0) {
                        s = try s.context.on_data(allocator, s, s.context.loop.data.recv_buf[RECV_BUFFER_PADDING..][0..length]);
                        // If filled the entire recv buffer, need to immediately read again since otherwise a
                        // pending hangup event in the same even loop iteration can close the socket before we get
                        // the chance to read again next iteration.
                        if (length == RECV_BUFFER_LENGTH) continue;
                    } else {
                        if (s.isShutdown()) {
                            // received FIN back after sending it
                            // TODO: should give "CLEAN SHUTDOWN" as reason here
                            s = try s.close(allocator, 0, null);
                        } else {
                            // received FIN, so stop polling for readable
                            try s.p.change(s.getCtx().loop, s.p.events() & SOCKET_WRITABLE);
                            s = try s.context.on_end(allocator, s);
                        }
                    }
                    break;
                }
            }
        },
        else => {},
    }
}

pub fn adoptAcceptedSocket(
    allocator: Allocator,
    comptime SocketType: type,
    comptime PollType: type,
    context: *SocketType.Context,
    accepted_fd: SocketDescriptor,
    addr_ip: []u8,
) !*SocketType {
    const accepted_p: *PollType = try PollType.init(allocator, context.loop, false, accepted_fd, .socket);
    try accepted_p.start(context.loop, SOCKET_READABLE);
    const s: *SocketType = @ptrCast(@alignCast(accepted_p));
    s.context = context;
    s.timeout = 255;
    s.long_timeout = 255;
    s.low_prio_state = .none;

    // always use nodelay
    try bsd.setNodelay(accepted_fd, true);
    context.linkSocket(s);
    _ = try context.on_open(allocator, s, false, addr_ip);
    return s;
}

// N.B. takes the linked list and timeout sweep into account
fn internalFreeClosedSockets(allocator: Allocator, loop: anytype) void {
    const Socket = @TypeOf(loop.*).Socket;
    const Poll = @TypeOf(loop.*).Poll;
    // Free all closed sockets (maybe better to reverse order?)
    if (loop.data.closed_head) |closed_head| {
        var maybe_s: ?*Socket = closed_head;
        while (maybe_s) |s| : (maybe_s = loop.data.closed_head) {
            const next = s.next;
            @as(*Poll, @ptrCast(@alignCast(s))).deinit(allocator, loop);
            maybe_s = next;
        }
        loop.data.closed_head = null;
    }
}

pub fn internalLoopPost(allocator: Allocator, loop: anytype) !void {
    internalFreeClosedSockets(allocator, loop);
    try loop.data.post_cb(allocator, loop);
}

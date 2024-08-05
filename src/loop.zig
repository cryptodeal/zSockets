const bsd = @import("bsd.zig");
const build_opts = @import("build_opts");
const std = @import("std");
const zs = @import("zsockets.zig");

const Callback = @import("internal/callback.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub fn internalLoopDataFree(allocator: Allocator, loop: *zs.Loop) void {
    // TODO(cryptodeal): if using ssl, free ssl data
    allocator.free(loop.data.recv_buf);
    zs.Loop.closeTimer(allocator, loop.data.sweep_timer);
    zs.Loop.closeAsync(allocator, loop.data.wakeup_async);
}

pub fn initLoopData(
    allocator: Allocator,
    loop: *zs.Loop,
    wakeup_cb: *const fn (allocator: Allocator, loop: *zs.Loop) anyerror!void,
    pre_cb: *const fn (allocator: Allocator, loop: *zs.Loop) anyerror!void,
    post_cb: *const fn (allocator: Allocator, loop: *zs.Loop) anyerror!void,
) !void {
    const sweep_timer = try loop.createTimer(allocator, true, null);
    const recv_buf = try allocator.alloc(u8, zs.RECV_BUFFER_LENGTH + zs.RECV_BUFFER_PADDING * 2);
    errdefer allocator.free(recv_buf);
    loop.data = .{
        .sweep_timer = sweep_timer,
        .recv_buf = recv_buf,
        .ssl_data = null,
        .head = null,
        .iterator = null,
        .closed_head = null,
        .low_priority_head = null,
        .low_priority_budget = 0,
        .pre_cb = pre_cb,
        .post_cb = post_cb,
        .last_write_failed = false,
        .iteration_nr = 0,
        .wakeup_async = try loop.createAsync(allocator, true, null),
    };
    zs.Loop.asyncSet(loop.data.wakeup_async, @ptrCast(@alignCast(wakeup_cb)));
}

const MAX_LOW_PRIO_SOCKETS_PER_LOOP_ITERATION = 5;

fn internalHandleLowPrioritySockets(loop: *zs.Loop) !void {
    const loop_data = &loop.data;
    var s: ?*zs.Socket = undefined;

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
        try s.?.p.change(s.?.ctx().loop, s.?.p.events() | zs.SOCKET_READABLE);
        s.?.low_priority_state = .prev_queued_in_iter;
    }
}

pub fn internalLoopPre(allocator: Allocator, loop: *zs.Loop) !void {
    loop.data.iteration_nr += 1;
    try internalHandleLowPrioritySockets(loop);
    try loop.data.pre_cb(allocator, loop);
}

// N.B. takes the linked list and timeout sweep into account
fn internalFreeClosedSockets(allocator: Allocator, loop: *zs.Loop) void {
    // Free all closed sockets (maybe better to reverse order?)
    if (loop.data.closed_head) |_| {
        var maybe_s = loop.data.closed_head;
        while (maybe_s) |s| {
            const next = s.next;
            s.deinit(allocator, loop);
            maybe_s = next;
        }
        loop.data.closed_head = null;
    }
}

pub fn internalLoopPost(allocator: Allocator, loop: *zs.Loop) !void {
    internalFreeClosedSockets(allocator, loop);
    try loop.data.post_cb(allocator, loop);
}

fn internalTimerSweep(allocator: Allocator, loop: *zs.Loop) !void {
    const loop_data = &loop.data;
    loop_data.iterator = loop_data.head;
    // iterate through all socket contexts in the loop
    while (loop_data.iterator) |iter| : (loop_data.iterator = iter.next) {
        const context = iter;
        // std.debug.print("context: {any}\n", .{context});
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
                maybe_s = s.next;
                if (maybe_s == null) break :next_context;
            }

            // Need to emit timeout (slow path)
            context.iterator = s;
            if (short_ticks == s.timeout) {
                s.timeout = 255;
                _ = try context.on_socket_timeout(allocator, s);
            }
            if (@intFromPtr(context.iterator) == @intFromPtr(s) and long_ticks == s.long_timeout) {
                s.long_timeout = 255;
                _ = try context.on_socket_long_timeout.?(allocator, s);
            }

            // Check for unlink/link (if the event handler did not
            // modify the chain, we step 1)
            if (@intFromPtr(s) == @intFromPtr(context.iterator)) {
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

fn sweepTimerCb(allocator: Allocator, cb: *Callback) !void {
    return internalTimerSweep(allocator, cb.loop);
}

pub fn loopIntegrate(loop: *zs.Loop) !void {
    return zs.Loop.timerSet(
        loop.data.sweep_timer,
        @ptrCast(&sweepTimerCb),
        zs.TIMEOUT_GRANULARITY * 1000,
        zs.TIMEOUT_GRANULARITY * 1000,
    );
}

pub fn internalDispatchReadyPoll(allocator: Allocator, p: *zs.Poll, err: u32, evnts: u32) !void {
    // std.debug.print("PollType: {d}\n", .{@intFromEnum(p.type())});
    switch (p.type()) {
        .callback => {
            const cb: *Callback = @fieldParentPtr("p", p);
            if (!cb.leave_poll_ready) {
                if (build_opts.event_loop_lib != .libuv) {
                    _ = p.acceptPollEvent();
                }
                try cb.cb(allocator, if (cb.expects_loop) @fieldParentPtr("loop", &cb.loop) else @fieldParentPtr("p", &cb.p));
            }
        },
        .semi_socket => {
            // connect and listen sockets are both semi-sockets,
            // but each polls for different events.
            if (p.events() == zs.SOCKET_WRITABLE) {
                var s: *zs.Socket = @fieldParentPtr("p", p);
                // it's possible we arrive  here with an error
                if (err != 0) {
                    // Emit error, close but don't emit `on_close`
                    _ = try s.context.on_connect_error.?(allocator, s, 0);
                    _ = try s.closeConnecting();
                } else {
                    // all sockets poll for readable
                    try p.change(s.context.loop, zs.SOCKET_READABLE);
                    // always use tcp nodelay
                    bsd.setNoDelay(p.fd(), true);
                    // now have a proper socket
                    p.setType(.socket);
                    // if using connection timeout, need to reset
                    s.setTimeout(0);
                    _ = try s.context.on_open(allocator, s, true, &.{});
                }
            } else {
                const s: *zs.Socket = @fieldParentPtr("p", p);
                const listen_socket: *zs.ListenSocket = @fieldParentPtr("s", s);
                var addr: bsd.c.bsd_addr_t = .{};
                var client_fd = bsd.acceptSocket(p.fd(), &addr);
                if (client_fd == zs.SOCKET_ERROR) {
                    // TODO: start timer here
                } else {
                    // TODO: stop timer here if any
                    outer: while (client_fd != zs.SOCKET_ERROR) : (client_fd = bsd.acceptSocket(p.fd(), &addr)) {
                        const context = listen_socket.s.ctx();
                        // determine whether to export fd or keep here (event can be unset)
                        if (context.on_pre_open == null or (try context.on_pre_open.?(allocator, client_fd)) == client_fd) {
                            // adopt the newly accepted socket
                            _ = try adoptAcceptedSocket(allocator, context, client_fd, &listen_socket.s._ext, bsd.internalGetIp(&addr));
                            // Exit accept loop if listen socket was closed in on_open handler
                            if (listen_socket.s.isClosed()) break :outer;
                        }
                    }
                }
            }
        },
        .socket_shutdown, .socket => blk: {
            // only use s, not p after this point
            var s: ?*zs.Socket = @fieldParentPtr("p", p);
            if (err != 0) {
                // TODO: decide on exit code to use here
                // std.debug.print("s: {any}\n", .{s});
                s = try s.?.close(allocator, 0, null);
                return;
            }
            if ((evnts & zs.SOCKET_WRITABLE) != 0) {
                // N.B. if failed write of a socket of one loop,
                // then adopted to another loop, this is WRONG.
                // This is an extreme edge case.
                s.?.context.loop.data.last_write_failed = false;
                s = try s.?.context.on_writable(allocator, s.?);
                if (s.?.isClosed()) return;

                // If no failed write or if shut down, stop
                // polling for more writable
                if (!s.?.context.loop.data.last_write_failed or s.?.isShutdown()) {
                    try s.?.p.change(s.?.ctx().loop, s.?.p.events() & zs.SOCKET_READABLE);
                }
            }
            // std.debug.print("events_ & SOCKET_READABLE <--> {d} & {d}\n", .{ events_, SOCKET_READABLE });
            if ((evnts & zs.SOCKET_READABLE) != 0) {
                // Contexts may prioritize down sockets that are currently readable (e.g.
                // SSL handshake). SSL handshakes are CPU intensive, so prefer to limit the
                // number of handshakes per loop iteration, and move the rest to the
                // low-priority queue.
                if (@intFromEnum(s.?.context.is_low_priority(s.?)) != 0) {
                    if (s.?.low_priority_state == .prev_queued_in_iter) {
                        // socket delayed; must process incoming data for one iteration
                        s.?.low_priority_state = .none;
                    } else if (s.?.context.loop.data.low_priority_budget > 0) {
                        // still have budget for this iteration, continue per usual
                        s.?.context.loop.data.low_priority_budget -= 1;
                    } else {
                        try s.?.p.change(s.?.ctx().loop, s.?.p.events() & zs.SOCKET_WRITABLE);
                        s.?.context.unlinkSocket(s.?);

                        // Link this socket to the low-priority queue - we use a LIFO
                        // queue, to prioritize newer clients that are maybe not already
                        // timeouted. This works better irl with smaller client-timeouts
                        // under high load
                        s.?.prev = null;
                        s.?.next = s.?.context.loop.data.low_priority_head;
                        if (s.?.next) |next| next.prev = s;
                        s.?.context.loop.data.low_priority_head = s;
                        s.?.low_priority_state = .queued;
                        break :blk;
                    }
                }

                var length: isize = undefined;
                length = bsd.recv(s.?.p.fd(), s.?.context.loop.data.recv_buf[zs.RECV_BUFFER_PADDING .. zs.RECV_BUFFER_PADDING + zs.RECV_BUFFER_LENGTH], 0);
                while (true) : (length = bsd.recv(s.?.p.fd(), s.?.context.loop.data.recv_buf[zs.RECV_BUFFER_PADDING .. zs.RECV_BUFFER_PADDING + zs.RECV_BUFFER_LENGTH], 0)) {
                    if (length > 0) {
                        s = try s.?.context.on_data(allocator, s.?, s.?.context.loop.data.recv_buf[zs.RECV_BUFFER_PADDING .. zs.RECV_BUFFER_PADDING + @as(usize, @intCast(length))]);
                        // If filled the entire recv buffer, need to immediately read again since otherwise a
                        // pending hangup event in the same even loop iteration can close the socket before we get
                        // the chance to read again next iteration.
                        if (length == zs.RECV_BUFFER_LENGTH and s != null and !s.?.isClosed()) continue;
                    } else if (length == 0) {
                        switch (s.?.isShutdown()) {
                            true => s = try s.?.close(allocator, 0, null), // received FIN back after sending it
                            else => {
                                // received FIN, so stop polling for readable
                                try s.?.p.change(s.?.ctx().loop, s.?.p.events() & zs.SOCKET_WRITABLE);
                                s = try s.?.context.on_end(allocator, s.?);
                            },
                        }
                    } else if (length == zs.SOCKET_ERROR and !bsd.wouldBlock()) {
                        // TODO(cryptodeal): determine error code to be sent here
                        s = try s.?.close(allocator, 0, null);
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
    context: *zs.Context,
    accepted_fd: zs.SocketDescriptor,
    ext: *zs.Extension,
    addr_ip: []u8,
) !*zs.Socket {
    const s = try allocator.create(zs.Socket);
    errdefer allocator.destroy(s);
    s._ext = if (ext.ptr) |_| try ext.dupeEmpty(allocator) else .{};
    s.p = zs.Poll.init(context.loop, false, accepted_fd, .socket);
    try s.p.start(context.loop, zs.SOCKET_READABLE);
    s.context = context;
    s.timeout = 255;
    s.long_timeout = 255;
    s.low_priority_state = .none;

    // always use nodelay
    bsd.setNoDelay(accepted_fd, true);
    context.linkSocket(s);
    _ = try context.on_open(allocator, s, false, addr_ip);
    return s;
}

pub fn internalLoopLink(loop: *zs.Loop, context: *zs.Context) void {
    // insert context as head of loop
    context.next = loop.data.head;
    context.prev = null;
    if (loop.data.head) |head| {
        head.prev = context;
    }
    loop.data.head = context;
}

pub fn internalLoopUnlink(loop: *zs.Loop, context: *zs.Context) void {
    if (@intFromPtr(loop.data.head) == @intFromPtr(context)) {
        loop.data.head = context.next;
        if (loop.data.head) |head| head.prev = null;
    } else {
        context.prev.?.next = context.next;
        if (context.next) |next| next.prev = context.prev;
    }
}

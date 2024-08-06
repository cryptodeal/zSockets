const bsd = @import("bsd.zig");
const std = @import("std");
const utils = @import("loop.zig");
const zs = @import("zsockets.zig");

const Allocator = std.mem.Allocator;

fn isLowPriority(_: *zs.Socket) zs.LowPriorityState {
    return .none;
}

pub const Context = struct {
    loop: *zs.Loop,
    global_tick: u32,
    timestamp: u8,
    long_timestamp: u8,
    head_sockets: ?*zs.Socket = null,
    head_listen_sockets: ?*zs.ListenSocket = null,
    iterator: ?*zs.Socket = null,
    prev: ?*Context = null,
    next: ?*Context = null,
    on_pre_open: ?*const fn (allocator: Allocator, fd: zs.SocketDescriptor) anyerror!zs.SocketDescriptor = null,
    on_open: *const fn (allocator: Allocator, s: *zs.Socket, is_client: bool, ip: []u8) anyerror!*zs.Socket = undefined,
    on_data: *const fn (allocator: Allocator, s: *zs.Socket, data: []u8) anyerror!*zs.Socket = undefined,
    on_writable: *const fn (allocator: Allocator, s: *zs.Socket) anyerror!*zs.Socket = undefined,
    on_close: *const fn (allocator: Allocator, s: *zs.Socket, code: i32, reason: ?*anyopaque) anyerror!*zs.Socket = undefined,
    on_socket_timeout: *const fn (allocator: Allocator, s: *zs.Socket) anyerror!*zs.Socket = undefined,
    on_socket_long_timeout: ?*const fn (allocator: Allocator, s: *zs.Socket) anyerror!*zs.Socket = null,
    on_connect_error: ?*const fn (allocator: Allocator, s: *zs.Socket, code: i32) anyerror!*zs.Socket = null,
    on_end: *const fn (allocator: Allocator, s: *zs.Socket) anyerror!*zs.Socket = undefined,
    is_low_priority: *const fn (s: *zs.Socket) zs.LowPriorityState = &isLowPriority,
    _ext: zs.Extension = .{},

    pub fn init(allocator: Allocator, comptime Extension: ?type, loop: *zs.Loop) !*Context {
        const self = try allocator.create(Context);
        errdefer allocator.destroy(loop);
        self.* = .{
            .loop = loop,
            .timestamp = 0,
            .long_timestamp = 0,
            .global_tick = 0,
        };
        if (Extension) |T| self._ext = try zs.Extension.init(allocator, T);
        utils.internalLoopLink(loop, self);
        return self;
    }

    pub fn deinit(self: *Context, allocator: Allocator) void {
        utils.internalLoopUnlink(self.loop, self);
        self._ext.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn ext(self: *Context, comptime T: type) ?*align(@alignOf(u8)) T {
        return @ptrCast(@alignCast(self._ext.ptr));
    }

    pub fn initChildContext(self: *Context, allocator: Allocator, comptime T: ?type) !*Context {
        return Context.init(allocator, T, self.loop);
    }

    pub fn setOnOpen(
        self: *Context,
        on_open: *const fn (allocator: Allocator, s: *zs.Socket, is_client: bool, ip: []u8) anyerror!*zs.Socket,
    ) void {
        self.on_open = on_open;
    }

    pub fn setOnData(
        self: *Context,
        on_data: *const fn (allocator: Allocator, s: *zs.Socket, data: []u8) anyerror!*zs.Socket,
    ) void {
        self.on_data = on_data;
    }

    pub fn setOnWritable(
        self: *Context,
        on_writable: *const fn (allocator: Allocator, s: *zs.Socket) anyerror!*zs.Socket,
    ) void {
        self.on_writable = on_writable;
    }

    pub fn setOnClose(
        self: *Context,
        on_close: *const fn (allocator: Allocator, s: *zs.Socket, code: i32, reason: ?*anyopaque) anyerror!*zs.Socket,
    ) void {
        self.on_close = on_close;
    }

    pub fn setOnTimeout(
        self: *Context,
        on_timeout: *const fn (allocator: Allocator, s: *zs.Socket) anyerror!*zs.Socket,
    ) void {
        self.on_socket_timeout = on_timeout;
    }

    pub fn setOnLongTimeout(
        self: *Context,
        on_long_timeout: *const fn (allocator: Allocator, s: *zs.Socket) anyerror!*zs.Socket,
    ) void {
        self.on_socket_long_timeout = on_long_timeout;
    }

    pub fn setOnEnd(
        self: *Context,
        on_end: *const fn (allocator: Allocator, s: *zs.Socket) anyerror!*zs.Socket,
    ) void {
        self.on_end = on_end;
    }

    pub fn setOnConnectError(
        self: *Context,
        on_connect_error: *const fn (allocator: Allocator, s: *zs.Socket, code: i32) anyerror!*zs.Socket,
    ) void {
        self.on_connect_error = on_connect_error;
    }

    pub fn adoptSocket(self: *Context, allocator: Allocator, s: *zs.Socket, comptime T: ?type) !*zs.Socket {
        // cannot adopt a closed socket
        if (s.isClosed()) return s;
        if (s.low_priority_state != .queued) {
            // update the iterator if in `on_timeout`
            s.context.unlinkSocket(s);
        }
        try s.resize(allocator, s.context.loop, T);
        s.timeout = 255;
        s.long_timeout = 255;
        if (s.low_priority_state == .queued) {
            // update pointers in low priority queue
            if (s.prev) |prev| {
                prev.next = s;
            } else {
                s.context.loop.data.low_priority_head = s;
            }
            if (s.next) |next| next.prev = s;
        } else {
            self.linkSocket(s);
        }
        return s;
    }

    pub fn connect(
        self: *Context,
        allocator: Allocator,
        comptime T: ?type,
        host: ?[:0]const u8,
        port: u64,
        src_host: ?[:0]const u8,
        options: u64,
    ) !*zs.Socket {
        const connect_socket_fd = try bsd.createConnectSocket(host, port, src_host, options);
        if (connect_socket_fd == zs.SOCKET_ERROR) return error.ConnectFailed;
        const connect_socket = try allocator.create(zs.Socket);
        errdefer allocator.destroy(connect_socket);
        connect_socket._ext = if (T) |Ext| try zs.Extension.init(allocator, Ext) else .{};
        connect_socket.p = zs.Poll.init(self.loop, false, connect_socket_fd, .semi_socket);
        try connect_socket.p.start(self.loop, zs.SOCKET_WRITABLE);
        connect_socket.context = self;
        connect_socket.timeout = 255;
        connect_socket.long_timeout = 255;
        connect_socket.low_priority_state = .none;
        self.linkSocket(connect_socket);
        return connect_socket;
    }

    pub fn listen(self: *Context, allocator: Allocator, comptime T: ?type, host: ?[:0]const u8, port: u64, options: u64) !*zs.ListenSocket {
        const listen_socket_fd = try bsd.createListenSocket(host, port, options);
        const ls = try allocator.create(zs.ListenSocket);
        ls.s._ext = if (T) |Ext| try zs.Extension.init(allocator, Ext) else .{};
        ls.s.p = zs.Poll.init(self.loop, false, listen_socket_fd, .semi_socket);
        try ls.s.p.start(self.loop, zs.SOCKET_READABLE);
        ls.s.context = self;
        ls.s.timeout = 255;
        ls.s.long_timeout = 255;
        ls.s.low_priority_state = .none;
        ls.s.next = null;
        self.linkListenSocket(ls);
        return ls;
    }

    pub fn unlinkSocket(self: *Context, s: *zs.Socket) void {
        if (@intFromPtr(s) == @intFromPtr(self.iterator)) {
            self.iterator = s.next;
        }
        if (s.prev == s.next) {
            self.head_sockets = null;
        } else {
            if (s.prev) |prev| {
                prev.next = s.next;
            } else {
                self.head_sockets = s.next;
            }
            if (s.next) |next| next.prev = s.prev;
        }
    }

    pub fn linkSocket(self: *Context, s: *zs.Socket) void {
        s.context = self;
        s.next = self.head_sockets;
        s.prev = null;
        if (self.head_sockets) |head| head.prev = s;
        self.head_sockets = s;
    }

    pub fn unlinkListenSocket(self: *Context, ls: *zs.ListenSocket) void {
        if (@intFromPtr(ls) == @intFromPtr(self.iterator)) {
            self.iterator = ls.s.next;
        }
        if (ls.s.prev == ls.s.next) {
            self.head_listen_sockets = null;
        } else {
            if (ls.s.prev) |prev| {
                prev.next = ls.s.next;
            } else {
                self.head_listen_sockets = @ptrCast(@alignCast(ls.s.next));
            }
            if (ls.s.next) |next| next.prev = ls.s.prev;
        }
    }

    pub fn linkListenSocket(self: *Context, ls: *zs.ListenSocket) void {
        ls.s.context = self;
        ls.s.next = @ptrCast(@alignCast(self.head_listen_sockets));
        ls.s.prev = null;
        if (self.head_listen_sockets) |head| head.s.prev = &ls.s;
        self.head_listen_sockets = ls;
    }
};

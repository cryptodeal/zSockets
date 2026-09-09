const build_opts = @import("build_opts");
const bsd = @import("bsd/root.zig");
const std = @import("std");
const Extension = @import("extension.zig");
const Poll = @import("eventing/impl.zig").Poll;
const Loop = @import("eventing/impl.zig").Loop;
const socket_readable = @import("eventing/impl.zig").socket_readable;
const socket_writable = @import("eventing/impl.zig").socket_writable;
const loop_ = @import("loop.zig");
const openssl = @import("crypto/openssl.zig");
const ListenSocket = @import("listen_socket.zig");
const internal = @import("internal/internal.zig");
const Socket = @import("socket.zig");
const SocketContextOptions = @import("socket_context_options.zig");

const Self = @This();

loop: *Loop,
global_tick: u32 = 0,
timestamp: u8 = 0,
long_timestamp: u8 = 0,
head_sockets: ?*Socket = null,
head_listen_sockets: ?*ListenSocket = null,
iterator: ?*Socket = null,
prev: ?*Self = null,
next: ?*Self = null,
on_pre_open: ?*const fn (std.mem.Allocator, std.posix.socket_t, []u8) anyerror!std.posix.socket_t = null,
on_open: *const fn (std.mem.Allocator, *Socket, bool, []u8) anyerror!*Socket = undefined,
on_data: *const fn (std.mem.Allocator, *Socket, []u8) anyerror!*Socket = undefined,
on_writable: *const fn (std.mem.Allocator, *Socket) anyerror!*Socket = undefined,
on_close: *const fn (std.mem.Allocator, *Socket, i32, ?*anyopaque) anyerror!*Socket = undefined,
on_socket_timeout: *const fn (std.mem.Allocator, *Socket) anyerror!*Socket = undefined,
on_socket_long_timeout: ?*const fn (std.mem.Allocator, *Socket) anyerror!*Socket = null,
on_connect_error: ?*const fn (std.mem.Allocator, *Socket, i32) anyerror!*Socket = null,
on_end: *const fn (std.mem.Allocator, *Socket) anyerror!*Socket = undefined,
is_low_priority: *const fn (*Socket) internal.LowPriorityQueueState = &internal.isLowPriority,
is_ssl: bool = false,
ext: Extension = .{},

pub fn init(allocator: std.mem.Allocator, ssl: bool, loop: *Loop, options: SocketContextOptions, comptime MaybeT: ?type) !*Self {
    if (build_opts.ssl_impl != .no_ssl) {
        if (ssl) {
            return &(try openssl.SslSocketContext.init(allocator, loop, options, MaybeT)).sc;
        }
    }
    const self = try allocator.create(Self);
    try self.internalInit(allocator, loop, options, MaybeT);
    return self;
}

pub fn internalInit(self: *Self, allocator: std.mem.Allocator, loop: *Loop, _: SocketContextOptions, comptime ExtensionT: ?type) !void {
    self.* = .{
        .loop = loop,
        .ext = try Extension.init(allocator, ExtensionT),
    };
    loop_.link(self.loop, self);
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    if (build_opts.ssl_impl != .no_ssl) {
        if (self.is_ssl) {
            @as(*openssl.SslSocketContext, @fieldParentPtr("sc", self)).deinit(allocator);
            return;
        }
    }
    loop_.loopUnlink(self.loop, self);
    self.ext.deinit(allocator);
    allocator.destroy(self);
}

pub fn close(self: *Self, allocator: std.mem.Allocator, ssl: bool) !void {
    var maybe_ls = self.head_listen_sockets;
    while (maybe_ls) |ls| {
        const next_ls: ?*ListenSocket = @ptrCast(@alignCast(ls.s.next));
        ls.close(ssl);
        maybe_ls = next_ls;
    }
    var maybe_s = self.head_sockets;
    while (maybe_s) |s| {
        const next_s = s.next;
        _ = try s.close(allocator, ssl, 0, null);
        maybe_s = next_s;
    }
}

pub fn unlinkListenSocket(self: *Self, ls: *ListenSocket) void {
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

pub fn unlinkSocket(self: *Self, s: *Socket) void {
    if (@intFromPtr(s) == @intFromPtr(self.iterator)) self.iterator = s.next;
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

pub fn linkListenSocket(self: *Self, ls: *ListenSocket) void {
    ls.s.context = self;
    ls.s.next = @ptrCast(@alignCast(self.head_listen_sockets));
    ls.s.prev = null;
    if (self.head_listen_sockets) |head_listen_sockets| {
        head_listen_sockets.s.prev = &ls.s;
    }
    self.head_listen_sockets = ls;
}

pub fn linkSocket(self: *Self, s: *Socket) void {
    s.context = self;
    s.next = self.head_sockets;
    s.prev = null;
    if (self.head_sockets) |head_sockets| head_sockets.prev = s;
    self.head_sockets = s;
}

pub fn findServerNameUserdata(self: *Self, ssl: bool, hostname_pattern: [:0]const u8) ?*anyopaque {
    if (build_opts.ssl_impl != .no_ssl) {
        if (ssl) {
            return @as(*openssl.SslSocketContext, @fieldParentPtr("sc", self)).findServerNameUserdata(hostname_pattern);
        }
    }
    return null;
}

pub fn addServerName(self: *Self, ssl: bool, hostname_pattern: [:0]const u8, options: SocketContextOptions, user: ?*anyopaque) void {
    if (build_opts.ssl_impl != .no_ssl) {
        if (ssl) {
            @as(*openssl.SslSocketContext, @fieldParentPtr("sc", self)).addServerName(hostname_pattern, options, user);
        }
    }
}

pub fn removeServerName(self: *Self, allocator: std.mem.Allocator, ssl: bool, hostname_pattern: [:0]const u8) void {
    if (build_opts.ssl_impl != .no_ssl) {
        if (ssl) {
            @as(*openssl.SslSocketContext, @fieldParentPtr("sc", self)).removeServerName(allocator, hostname_pattern);
        }
    }
}

pub fn setOnServerName(self: *Self, ssl: bool, func: *const fn (*Self, [:0]const u8) void) void {
    if (build_opts.ssl_impl != .no_ssl) {
        if (ssl) {
            @as(*openssl.SslSocketContext, @fieldParentPtr("sc", self)).setOnServerName(func);
        }
    }
}

pub fn getNativeHandle(self: *Self, ssl: bool) ?*anyopaque {
    if (build_opts.ssl_impl != .no_ssl) {
        if (ssl) {
            return @as(*openssl.SslSocketContext, @fieldParentPtr("sc", self)).getNativeHandle();
        }
    }
    return null;
}

const ListenError = std.mem.Allocator.Error || std.fmt.BufPrintError || error{ CreateListenSocket, GetAddrInfo };

pub fn listen(self: *Self, allocator: std.mem.Allocator, ssl: bool, host: ?[:0]const u8, port: u32, options: u32, comptime MaybeT: ?type) ListenError!*ListenSocket {
    if (build_opts.ssl_impl != .no_ssl) {
        if (ssl) {
            return @as(*openssl.SslSocketContext, @fieldParentPtr("sc", self)).listen(allocator, host, port, options, MaybeT);
        }
    }
    const listen_socket_fd = try bsd.createListenSocket(host, port, options);
    // TODO: probably need `errdefer` handling here
    const ls = try ListenSocket.init(allocator, self, MaybeT);
    try ls.s.p.create(allocator, self.loop, false, null);
    // std.debug.print("Created listen socket; socket field ptr: {d}\n", .{@intFromPtr(&ls.s)});
    ls.s.p.init(listen_socket_fd, .semi_socket);
    ls.s.p.start(self.loop, socket_readable);
    self.linkListenSocket(ls);
    return ls;
}

const ListenUnixError = std.mem.Allocator.Error || bsd.SocketError || error{CreateListenSocketUnix};
pub fn listenUnix(self: *Self, allocator: std.mem.Allocator, ssl: bool, path: [:0]const u8, options: u32, comptime MaybeT: ?type) ListenUnixError!*ListenSocket {
    if (build_opts.ssl_impl != .no_ssl) {
        if (ssl) {
            return @as(*openssl.SslSocketContext, @fieldParentPtr("sc", self)).listenUnix(allocator, path, options, MaybeT);
        }
    }
    const listen_socket_fd = try bsd.createListenSocketUnix(path, options);
    const ls = try ListenSocket.init(allocator, self, MaybeT);
    try ls.s.p.create(allocator, self.loop, false, null);
    // std.debug.print("Created listen socket unix; socket field ptr: {d}\n", .{@intFromPtr(&ls.s)});
    ls.s.p.init(listen_socket_fd, .semi_socket);
    ls.s.p.start(self.loop, socket_readable);
    self.linkListenSocket(ls);
    return ls;
}

pub fn connect(self: *Self, allocator: std.mem.Allocator, ssl: bool, host: [:0]const u8, port: u32, source_host: ?[:0]const u8, options: u32, comptime MaybeT: ?type) !*Socket {
    if (build_opts.ssl_impl != .no_ssl) {
        if (ssl) {
            return &(try @as(*openssl.SslSocketContext, @fieldParentPtr("sc", self)).connect(allocator, host, port, source_host, options, MaybeT)).s;
        }
    }
    const connect_socket = try allocator.create(Socket);
    try internal.connect(allocator, self, connect_socket, host, port, source_host, options, MaybeT);
    return connect_socket;
}

pub fn connectUnix(self: *Self, allocator: std.mem.Allocator, ssl: bool, server_path: [:0]const u8, options: u32, comptime MaybeT: ?type) !*Socket {
    if (build_opts.ssl_impl != .no_ssl) {
        if (ssl) {
            return &(try @as(*openssl.SslSocketContext, @fieldParentPtr("sc", self)).connectUnix(allocator, server_path, options, MaybeT)).s;
        }
    }
    const connect_socket = try allocator.create(Socket);
    try internal.connectUnix(allocator, self, connect_socket, server_path, options, MaybeT);
    return connect_socket;
}

pub fn createChildContext(self: *Self, allocator: std.mem.Allocator, ssl: bool, comptime MaybeT: ?type) !*Self {
    if (build_opts.ssl_impl != .no_ssl) {
        if (ssl) {
            return &(try @as(*openssl.SslSocketContext, @fieldParentPtr("sc", self)).createChildContext(allocator, MaybeT)).sc;
        }
    }
    return Self.init(allocator, ssl, self.loop, .{}, MaybeT);
}

// TODO: implement (requires `Poll.resize`; verify consistent handling of `extension` handling between socket/poll)
pub fn adoptSocket(self: *Self, allocator: std.mem.Allocator, ssl: bool, s: *Socket, comptime MaybeT: ?type) std.mem.Allocator.Error!*Socket {
    if (build_opts.ssl_impl != .no_ssl) {
        if (ssl) {
            return &(try @as(*openssl.SslSocketContext, @fieldParentPtr("sc", self)).adoptSocket(allocator, @as(*openssl.SslSocket, @fieldParentPtr("s", s)), MaybeT)).s;
        }
    }
    if (s.isClosed(ssl)) return s;
    if (s.low_priority_state != .in_queue) s.context.unlinkSocket(s);
    var old_ext = s.ext;
    s.ext = try Extension.init(allocator, MaybeT);
    if (old_ext.copy_to_cb) |copy_to_cb| {
        if (s.ext.as_bytes_cb) |as_bytes_cb| copy_to_cb(old_ext.ptr.?, as_bytes_cb(s.ext.ptr.?));
    }
    old_ext.deinit(allocator);
    // TODO: might not need to call here
    // s.p.resize(s.context.loop);
    s.timeout = 255;
    s.long_timeout = 255;
    if (s.low_priority_state == .in_queue) {
        if (s.prev) |prev| prev.next = s else s.context.loop.data.low_priority_head = s;
        if (s.next) |next| next.prev = s;
    } else {
        self.linkSocket(s);
    }
    return s;
}

pub fn setOnPreOpen(self: *Self, _: bool, func: *const fn (std.mem.Allocator, std.posix.fd_t, []u8) anyerror!std.posix.fd_t) void {
    self.on_pre_open = func;
}

pub fn setOnOpen(self: *Self, ssl: bool, func: *const fn (std.mem.Allocator, *Socket, bool, []u8) anyerror!*Socket) void {
    if (build_opts.ssl_impl != .no_ssl) {
        if (ssl) {
            @as(*openssl.SslSocketContext, @fieldParentPtr("sc", self)).setOnOpen(@ptrCast(@alignCast(func)));
            return;
        }
    }
    self.on_open = func;
}

pub fn setOnClose(self: *Self, ssl: bool, func: *const fn (std.mem.Allocator, *Socket, i32, ?*anyopaque) anyerror!*Socket) void {
    if (build_opts.ssl_impl != .no_ssl) {
        if (ssl) {
            @as(*openssl.SslSocketContext, @fieldParentPtr("sc", self)).setOnClose(@ptrCast(@alignCast(func)));
            return;
        }
    }
    self.on_close = func;
}

pub fn setOnData(self: *Self, ssl: bool, func: *const fn (std.mem.Allocator, *Socket, []u8) anyerror!*Socket) void {
    if (build_opts.ssl_impl != .no_ssl) {
        if (ssl) {
            @as(*openssl.SslSocketContext, @fieldParentPtr("sc", self)).setOnData(@ptrCast(@alignCast(func)));
            return;
        }
    }
    self.on_data = func;
}

pub fn setOnWritable(self: *Self, ssl: bool, func: *const fn (std.mem.Allocator, *Socket) anyerror!*Socket) void {
    if (build_opts.ssl_impl != .no_ssl) {
        if (ssl) {
            @as(*openssl.SslSocketContext, @fieldParentPtr("sc", self)).setOnWritable(@ptrCast(@alignCast(func)));
            return;
        }
    }
    self.on_writable = func;
}

pub fn setOnLongTimeout(self: *Self, ssl: bool, func: *const fn (std.mem.Allocator, *Socket) anyerror!*Socket) void {
    if (build_opts.ssl_impl != .no_ssl) {
        if (ssl) {
            @as(*openssl.SslSocketContext, @fieldParentPtr("sc", self)).setOnLongTimeout(@ptrCast(@alignCast(func)));
            return;
        }
    }
    self.on_socket_long_timeout = func;
}

pub fn setOnTimeout(self: *Self, ssl: bool, func: *const fn (std.mem.Allocator, *Socket) anyerror!*Socket) void {
    if (build_opts.ssl_impl != .no_ssl) {
        if (ssl) {
            @as(*openssl.SslSocketContext, @fieldParentPtr("sc", self)).setOnTimeout(@ptrCast(@alignCast(func)));
            return;
        }
    }
    self.on_socket_timeout = func;
}

pub fn setOnEnd(self: *Self, ssl: bool, func: *const fn (std.mem.Allocator, *Socket) anyerror!*Socket) void {
    if (build_opts.ssl_impl != .no_ssl) {
        if (ssl) {
            @as(*openssl.SslSocketContext, @fieldParentPtr("sc", self)).setOnEnd(@ptrCast(@alignCast(func)));
            return;
        }
    }
    self.on_end = func;
}

pub fn setOnConnectError(self: *Self, ssl: bool, func: *const fn (std.mem.Allocator, *Socket, i32) anyerror!*Socket) void {
    if (build_opts.ssl_impl != .no_ssl) {
        if (ssl) {
            @as(*openssl.SslSocketContext, @fieldParentPtr("sc", self)).setOnConnectError(@ptrCast(@alignCast(func)));
            return;
        }
    }
    self.on_connect_error = func;
}

pub fn getExt(self: *Self, comptime T: type) ?*T {
    return @ptrCast(@alignCast(self.ext.ptr));
}

const std = @import("std");
const builtin = @import("builtin");
const build_opts = @import("build_opts");
const bsd = @import("bsd/root.zig");
const quic = @import("lsquic");
const Extension = @import("extension.zig");
const Timer = @import("internal/internal.zig").Timer;
const Loop = @import("eventing/impl.zig").Loop;
const udp = @import("udp.zig");
const createTimer = @import("eventing/impl.zig").createTimer;
const timerSet = @import("eventing/impl.zig").timerSet;
const ssl = switch (build_opts.ssl_impl) {
    .boringssl => @import("openssl"),
    else => @compileError("Currently support only BoringSSL"),
};

pub const Socket = extern struct {
    udp_socket: ?*anyopaque = null,

    pub fn createStream(self: *Socket, comptime _: ?type) void {
        quic.lsquic_conn_make_stream(@ptrCast(@alignCast(self)));
    }
};

var global_engine: ?*quic.lsquic_engine_t = null;
var global_client_engine: ?*quic.lsquic_engine_t = null;

pub const SocketContext = struct {
    pub const Options = struct {
        cert_file_name: [:0]const u8 = &.{},
        key_file_name: [:0]const u8 = &.{},
        passphrase: [:0]const u8 = &.{},
    };

    // stash user provided allocator here for use in callbacks
    allocator: std.mem.Allocator,
    io: std.Io,
    recv_buf: ?*anyopaque = null,
    outgoing_packets: u32 = undefined,
    loop: *Loop,
    engine: ?*quic.lsquic_engine_t = null,
    client_engine: ?*quic.lsquic_engine_t = null,
    options: Options,
    on_stream_data: ?*const fn (std.mem.Allocator, std.Io, ?*anyopaque, []u8) anyerror!void = null,
    on_stream_end: ?*const fn (std.mem.Allocator, std.Io, ?*anyopaque) anyerror!void = null,
    on_stream_headers: ?*const fn (std.mem.Allocator, std.Io, ?*anyopaque) anyerror!void = null,
    on_stream_open: ?*const fn (std.mem.Allocator, std.Io, ?*anyopaque, bool) anyerror!void = null,
    on_stream_close: ?*const fn (std.mem.Allocator, std.Io, ?*anyopaque) anyerror!void = null,
    on_stream_writable: ?*const fn (std.mem.Allocator, std.Io, ?*anyopaque) anyerror!void = null,
    on_open: ?*const fn (std.mem.Allocator, std.Io, *Socket, bool) anyerror!void = null,
    on_close: ?*const fn (std.mem.Allocator, std.Io, *Socket) anyerror!void = null,
    ext: Extension = .{},

    // static values
    const stream_callbacks: quic.lsquic_stream_if = .{
        .on_close = &onStreamClose,
        .on_conn_closed = &onConnClosed,
        .on_write = &onWrite,
        .on_read = &onRead,
        .on_new_stream = &onNewStream,
        .on_new_conn = &onNewConn,
    };

    const hset_if: quic.lsquic_hset_if = .{
        .hsi_discard_header_set = &hsiDiscardHeaderSet,
        .hsi_create_header_set = &hsiCreateHeaderSet,
        .hsi_prepare_decode = &hsiPrepareDecode,
        .hsi_process_header = &hsiProcessHeader,
    };

    const logger: quic.lsquic_logger_if = .{
        .log_buf = &logBufCb,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, loop: *Loop, options: Options, comptime Ext: ?type) !*SocketContext {
        std.debug.print("Creating socket context with ssl: {s}\n", .{options.key_file_name});
        const self = try allocator.create(SocketContext);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .recv_buf = try udp.PacketBuffer.init(allocator),
            .loop = loop,
            .options = options,
            .ext = try Extension.init(allocator, Ext),
        };
        errdefer {
            allocator.destroy(self);
        }
        if (0 != quic.lsquic_global_init(quic.LSQUIC_GLOBAL_CLIENT | quic.LSQUIC_GLOBAL_SERVER)) {
            std.process.exit(std.process.exit(1));
        }
        _ = addAlpn("h3");
        var engine_api: quic.lsquic_engine_api = .{
            .ea_packets_out = &sendPacketsOut,
            .ea_packets_out_ctx = self,
            .ea_stream_if = &stream_callbacks,
            .ea_stream_if_ctx = self,
            .ea_get_ssl_ctx = &getSslCtx,
            .ea_lookup_cert = &sniLookup,
            .ea_cert_lu_ctx = null,
            .ea_hsi_ctx = null,
            .ea_hsi_if = &hset_if,
        };
        self.engine = quic.lsquic_engine_new(quic.LSENG_SERVER | quic.LSENG_HTTP, &engine_api);
        var engine_api_client: quic.lsquic_engine_api = .{
            .ea_packets_out = &sendPacketsOut,
            .ea_packets_out_ctx = self,
            .ea_stream_if = &stream_callbacks,
            .ea_stream_if_ctx = self,
            .ea_hsi_ctx = null,
            .ea_hsi_if = &hset_if,
        };
        self.client_engine = quic.lsquic_engine_new(quic.LSENG_HTTP, &engine_api_client);
        std.debug.print("Engine: 0x{x}\n", .{@intFromPtr(self.engine)});
        std.debug.print("Client Engine: 0x{x}\n", .{@intFromPtr(self.client_engine)});
        const delay_timer = try createTimer(allocator, io, loop, false, null);
        timerSet(delay_timer, &timerCb, 50, 50);
        global_engine = self.engine;
        global_client_engine = self.client_engine;
        return self;
    }

    pub fn setOnStreamData(self: *SocketContext, cb: *const fn (std.mem.Allocator, std.Io, ?*anyopaque, []u8) anyerror!void) void {
        self.on_stream_data = cb;
    }

    pub fn setOnStreamEnd(self: *SocketContext, cb: *const fn (std.mem.Allocator, std.Io, ?*anyopaque) anyerror!void) void {
        self.on_stream_end = cb;
    }

    pub fn setOnStreamHeaders(self: *SocketContext, cb: *const fn (std.mem.Allocator, std.Io, ?*anyopaque) anyerror!void) void {
        self.on_stream_headers = cb;
    }

    pub fn setOnStreamOpen(self: *SocketContext, cb: *const fn (std.mem.Allocator, std.Io, ?*anyopaque, bool) anyerror!void) void {
        self.on_stream_open = cb;
    }

    pub fn setOnStreamClose(self: *SocketContext, cb: *const fn (std.mem.Allocator, std.Io, ?*anyopaque) anyerror!void) void {
        self.on_stream_close = cb;
    }

    pub fn setOnStreamWritable(self: *SocketContext, cb: *const fn (std.mem.Allocator, std.Io, ?*anyopaque) anyerror!void) void {
        self.on_stream_writable = cb;
    }

    pub fn setOnOpen(self: *SocketContext, cb: *const fn (std.mem.Allocator, std.Io, *Socket, bool) anyerror!void) void {
        self.on_open = cb;
    }

    pub fn setOnClose(self: *SocketContext, cb: *const fn (std.mem.Allocator, std.Io, *Socket) anyerror!void) void {
        self.on_close = cb;
    }

    pub fn setHeader(_: *SocketContext, index: u8, key: [:0]const u8, value: [:0]const u8) !void {
        try headerSetPtr(@ptrCast(headers_arr[index * 40 .. (index + 1) * 40].ptr), &hbuf, key, value);
    }

    pub fn sendHeaders(_: *SocketContext, s: ?*anyopaque, num: u32, has_body: bool) !void {
        const headers: quic.lsquic_http_headers_t = .{
            .count = @intCast(num),
            .headers = @ptrCast(&headers_arr),
        };
        if (quic.lsquic_stream_send_headers(@ptrCast(@alignCast(s)), &headers, if (has_body) 0 else 1) != 0) {
            return error.CannotSendHeaders;
        }
        hbuf.off = 0;
    }

    pub fn getHeader(_: *SocketContext, index: usize, name: *[]u8, value: *[]u8) bool {
        if (index < last_hset.offset) {
            const pd: [*]ProcessedHeader = @ptrCast(@alignCast(last_hset + 1));
            pd = pd + index;
            name.* = @as(?[*]u8, @ptrCast(@alignCast(pd.*.name)))[0..pd.*.name_len];
            value.* = @as(?[*]u8, @ptrCast(@alignCast(pd.*.value)))[0..pd.*.value_len];
            return true;
        }
        return false;
    }

    pub fn listen(self: *SocketContext, allocator: std.mem.Allocator, io: std.Io, host: [:0]const u8, port: u32, comptime _: ?type) !*udp.Socket {
        return udp.Socket.init(allocator, io, self.loop, null, &onUdpSocketData, &onUdpSocketWritable, host, port, self);
    }

    pub fn connect(self: *SocketContext, allocator: std.mem.Allocator, io: std.Io, _: [:0]const u8, _: u32, comptime _: ?type) !?*anyopaque {
        std.debug.print("Connecting..\n", .{});
        var storage = std.mem.zeroes(std.c.sockaddr.storage);
        var addr: *std.c.sockaddr.in6 = @ptrCast(@alignCast(&storage));
        addr.addr[15] = 1;
        addr.port = std.mem.nativeToBig(u16, 9004);
        addr.family = std.c.AF.INET6;
        const udp_socket = try udp.Socket.init(allocator, io, self.loop, null, &onUdpSocketDataClient, &onUdpSocketWritable, &.{}, 0, self);
        const ephemeral = udp_socket.port;
        std.debug.print("Connecting with udp socket bound to port: {d}\n", .{ephemeral});
        std.debug.print("Client udp socket is: 0x{x}\n", .{@intFromPtr(udp_socket)});
        var local_storage = std.mem.zeroes(std.c.sockaddr.storage);
        var local_addr: *std.c.sockaddr.in6 = @ptrCast(@alignCast(&local_storage));
        local_addr.addr[15] = 1;
        local_addr.port = std.mem.nativeToBig(u16, @intCast(ephemeral));
        local_addr.family = std.c.AF.INET6;
        const client = quic.lsquic_engine_connect(self.client_engine, quic.LSQVER_I001, @ptrCast(@alignCast(local_addr)), @ptrCast(@alignCast(addr)), udp_socket, @ptrCast(@alignCast(udp_socket)), "sni", 0, null, 0, null, 0);
        std.debug.print("Client: 0x{x}\n", .{@intFromPtr(client)});
        quic.lsquic_engine_process_conns(self.client_engine);
        return client;
    }
};

fn onUdpSocketWritable(_: std.mem.Allocator, _: std.Io, s: *udp.Socket) !void {
    const context: *SocketContext = @ptrCast(@alignCast(s.user));
    quic.lsquic_engine_send_unsent_packets(context.engine);
}

pub fn onUdpSocketDataClient(_: std.mem.Allocator, _: std.Io, s: *udp.Socket, buf: *udp.PacketBuffer, packets: usize) !void {
    const context: *SocketContext = @ptrCast(@alignCast(s.user));
    for (0..packets) |i| {
        const payload = buf.payload(i);
        // _ = buf.ecn(i);
        const peer_addr = buf.peer(i);
        var ip_buf: [16]u8 = undefined;
        const ip = try buf.localIp(i, &ip_buf);
        if (ip.len == 0) {
            std.debug.print("We got no ip on received packet!\n", .{});
            return error.FailedToGetLocalIp;
        }
        const port = s.port;
        var local_addr = std.mem.zeroes(std.c.sockaddr.storage);
        if (ip.len == 16) {
            const ipv6: *std.c.sockaddr.in6 = @ptrCast(@alignCast(&local_addr));
            ipv6.family = std.c.AF.INET6;
            ipv6.port = std.mem.bigToNative(u16, @intCast(port));
            @memcpy(&ipv6.addr, ip);
        } else {
            const ipv4: *std.c.sockaddr.in = @ptrCast(@alignCast(&local_addr));
            ipv4.family = std.c.AF.INET;
            ipv4.port = std.mem.bigToNative(u16, @intCast(port));
            @memcpy(std.mem.asBytes(&ipv4.addr), ip[0..4]);
        }
        _ = quic.lsquic_engine_packet_in(context.client_engine, payload.ptr, payload.len, @ptrCast(@alignCast(&local_addr)), @ptrCast(@alignCast(peer_addr)), @ptrCast(@alignCast(s)), 0);
    }
    quic.lsquic_engine_process_conns(context.client_engine);
}

fn onUdpSocketData(_: std.mem.Allocator, _: std.Io, s: *udp.Socket, buf: *udp.PacketBuffer, packets: usize) !void {
    const context: *SocketContext = @ptrCast(@alignCast(s.user));
    quic.lsquic_engine_process_conns(context.engine);
    for (0..packets) |i| {
        const payload = buf.payload(i);
        _ = buf.ecn(i);
        const peer_addr = buf.peer(i);

        var ip_buf: [16]u8 = undefined;
        const ip = try buf.localIp(i, &ip_buf);
        if (ip.len == 0) {
            std.debug.print("We got no ip on received packet!\n", .{});
            return error.FailedToGetLocalIp;
        }
        const port = s.port;
        var local_addr = std.mem.zeroes(std.c.sockaddr.storage);
        if (ip.len == 16) {
            const ipv6: *std.c.sockaddr.in6 = @ptrCast(@alignCast(&local_addr));
            ipv6.family = std.c.AF.INET6;
            ipv6.port = std.mem.bigToNative(u16, @intCast(port));
            @memcpy(&ipv6.addr, ip);
        } else {
            const ipv4: *std.c.sockaddr.in = @ptrCast(@alignCast(&local_addr));
            ipv4.family = std.c.AF.INET;
            ipv4.port = std.mem.bigToNative(u16, @intCast(port));
            @memcpy(std.mem.asBytes(&ipv4.addr), ip[0..4]);
        }
        _ = quic.lsquic_engine_packet_in(context.engine, payload.ptr, payload.len, @ptrCast(@alignCast(&local_addr)), @ptrCast(peer_addr), @ptrCast(@alignCast(s)), 0);
    }
    quic.lsquic_engine_process_conns(context.engine);
}

const UIO_MAXIOV = 1024;

pub fn sendPacketsOut(_: ?*anyopaque, specs: [*c]const quic.lsquic_out_spec, n_specs: c_uint) callconv(.c) c_int {
    if (builtin.os.tag != .windows) {
        var hdrs: [UIO_MAXIOV]std.c.mmsghdr = undefined;
        var run_length: usize = 0;
        var last_socket: *udp.Socket = @ptrCast(@alignCast(specs[0].peer_ctx));
        var sent: usize = 0;
        for (0..n_specs) |i| {
            if (run_length == UIO_MAXIOV or @as(*udp.Socket, @ptrCast(@alignCast(specs[i].peer_ctx))) != last_socket) {
                const ret = bsd.sendmmsg(last_socket.cb.p.fd(), @ptrCast(@alignCast(&hdrs)), @intCast(run_length), 0) catch |err| {
                    std.debug.print("unhandled udp backpressure! Error: {s}\n", .{@errorName(err)});
                    return @intCast(sent);
                };
                if (ret != run_length) {
                    std.debug.print("unhandled udp backpressure!\n", .{});
                    return @intCast(sent + ret);
                }
                sent += ret;
                run_length = 0;
                last_socket = @ptrCast(@alignCast(specs[i].peer_ctx));
            }
            // @memcpy(&hdrs[run_length], @as([@sizeOf(std.c.mmsghdr)]u8, @splat(0)));
            hdrs[run_length] = std.mem.zeroes(std.c.mmsghdr);
            hdrs[run_length].hdr.name = @ptrCast(@alignCast(@constCast(specs[i].dest_sa)));
            hdrs[run_length].hdr.namelen = if (@as(*const std.c.sockaddr, @ptrCast(@alignCast(specs[i].dest_sa.?))).family == std.c.AF.INET) @sizeOf(std.c.sockaddr.in) else @sizeOf(std.c.sockaddr.in6);
            hdrs[run_length].hdr.iov = @ptrCast(@alignCast(specs[i].iov));
            hdrs[run_length].hdr.iovlen = @intCast(specs[i].iovlen);
            run_length += 1;
        }
        if (run_length != 0) {
            const ret = bsd.sendmmsg(last_socket.cb.p.fd(), @ptrCast(@alignCast(&hdrs)), @intCast(run_length), 0) catch |err| {
                std.debug.print("backpressure! A: {s}\n", .{@errorName(err)});
                return @intCast(sent);
            };
            if (sent + ret != n_specs) {
                std.debug.print("backpressure! B: {s}\n", .{@tagName(@as(std.c.E, @enumFromInt(std.c._errno().*)))});
                std.c._errno().* = @intCast(@intFromEnum(std.c.E.AGAIN));
            }
            return @intCast(sent + ret);
        }
    }
    return @intCast(n_specs);
}

fn onNewConn(stream_if_ctx: ?*anyopaque, c: ?*quic.lsquic_conn_t) callconv(.c) ?*quic.lsquic_conn_ctx_t {
    const context: *SocketContext = @ptrCast(@alignCast(stream_if_ctx));
    std.debug.print("Context is: 0x{x}\n", .{@intFromPtr(context)});
    var is_client = false;
    if (quic.lsquic_conn_get_engine(c) == context.client_engine) {
        is_client = true;
    }
    context.on_open.?(context.allocator, context.io, @ptrCast(@alignCast(c)), is_client) catch |err| {
        std.debug.print("onNewConn Error: {s}\n", .{@errorName(err)});
        std.debug.dumpCurrentStackTrace(.{});
    };
    return @ptrCast(@alignCast(context));
}

fn onConnClosed(c: ?*quic.lsquic_conn_t) callconv(.c) void {
    const context: *SocketContext = @ptrCast(@alignCast(quic.lsquic_conn_get_ctx(c)));
    std.debug.print("onConnClose\n", .{});
    context.on_close.?(context.allocator, context.io, @ptrCast(@alignCast(c))) catch |err| {
        std.debug.print("onConnClose Error: {s}\n", .{@errorName(err)});
        std.debug.dumpCurrentStackTrace(.{});
    };
    // TODO: set conn_ctx to null?
    // quic.lsquic_conn_set_ctx(c, null);
}

fn onNewStream(stream_if_ctx: ?*anyopaque, s: ?*quic.lsquic_stream_t) callconv(.c) ?*quic.lsquic_stream_ctx_t {
    _ = quic.lsquic_stream_wantread(s, 1);
    const context: *SocketContext = @ptrCast(@alignCast(stream_if_ctx));
    const ext_size = 256;
    const ext = context.allocator.alloc(u8, ext_size) catch |err| {
        std.debug.print("onNewStream Error: {s}\n", .{@errorName(err)});
        std.debug.dumpCurrentStackTrace(.{});
        std.process.fatal("Error: OutOfMemory\n", .{});
    };
    @memcpy(ext.ptr, "Hello I am ext!");
    var is_client = false;
    if (quic.lsquic_conn_get_engine(quic.lsquic_stream_conn(s)) == context.client_engine) {
        is_client = true;
    }
    quic.lsquic_stream_set_ctx(s, @ptrCast(ext.ptr));
    context.on_stream_open.?(context.allocator, context.io, s, is_client) catch |err| {
        std.debug.print("onNewStream Error: {s}\n", .{@errorName(err)});
        std.debug.dumpCurrentStackTrace(.{});
    };
    return @ptrCast(ext.ptr);
}

const HeaderBuf = struct {
    off: u32,
    buf: [std.math.maxInt(u16)]u8,
};

fn headerSetPtr(hdr: *quic.lsxpack_header, header_buf: *HeaderBuf, name: [:0]const u8, val: [:0]const u8) !void {
    if (header_buf.off + name.len + val.len <= std.math.maxInt(u16)) {
        @memcpy(@as([*]u8, &header_buf.buf) + header_buf.off, name);
        @memcpy(@as([*]u8, &header_buf.buf) + header_buf.off + name.len, val);
        quic.lsxpack_header_set_offset2_(hdr, @as([*]u8, &header_buf.buf) + header_buf.off, 0, name.len, name.len, val.len);
        header_buf.off += @intCast(name.len + val.len);
    } else return error.CannotFormatHeader;
}

var hbuf: HeaderBuf = undefined;

// size of `lsxpack_header` * 10
var headers_arr: [40 * 10]u8 = undefined;

pub fn streamIsClient(s: *quic.us_quic_stream_t) bool {
    const context: *SocketContext = @ptrCast(@alignCast(quic.lsquic_conn_get_ctx(quic.lsquic_stream_conn(@ptrCast(@alignCast(s))))));
    var is_client = false;
    if (quic.lsquic_conn_get_engine(quic.lsquic_stream_conn(@ptrCast(@alignCast(s)))) == context.client_engine) {
        is_client = true;
    }
    return is_client;
}

pub fn streamSocket(s: ?*anyopaque) *Socket {
    return @ptrCast(@alignCast(quic.lsquic_stream_conn(@ptrCast(@alignCast(s)))));
}

fn onRead(s: ?*quic.lsquic_stream_t, _: ?*quic.lsquic_stream_ctx_t) callconv(.c) void {
    const context: *SocketContext = @ptrCast(@alignCast(quic.lsquic_conn_get_ctx(quic.lsquic_stream_conn(s))));
    const header_set = quic.lsquic_stream_get_hset(s);
    if (header_set) |_| {
        context.on_stream_headers.?(context.allocator, context.io, s) catch |err| {
            std.debug.print("onRead Error: {s}\n", .{@errorName(err)});
            std.debug.dumpCurrentStackTrace(.{});
        };
        leaveAll();
    }
    var temp: [4096]u8 = undefined;
    const nr = quic.lsquic_stream_read(s, &temp, 4096);
    if (nr == 0) {
        _ = quic.lsquic_stream_wantread(s, 0);
        context.on_stream_end.?(context.allocator, context.io, s) catch |err| {
            std.debug.print("onRead Error: {s}\n", .{@errorName(err)});
            std.debug.dumpCurrentStackTrace(.{});
        };
    } else if (nr == -1) {
        const would_block = if (@hasDecl(std.c.E, "WOULDBLOCK")) std.c.E.WOULDBLOCK else std.c.E.AGAIN;
        if (std.c.errno(nr) != would_block) {
            std.debug.print("UNHANDLED ON_READ ERROR\n", .{});
            std.process.exit(0);
        }
    } else {
        context.on_stream_data.?(context.allocator, context.io, s, temp[0..@intCast(nr)]) catch |err| {
            std.debug.print("onRead Error: {s}\n", .{@errorName(err)});
            std.debug.dumpCurrentStackTrace(.{});
        };
    }
}

pub fn streamWrite(s: ?*anyopaque, data: []u8) usize {
    const stream: *quic.lsquic_stream_t = @ptrCast(@alignCast(s));
    const ret: usize = @intCast(quic.lsquic_stream_write(stream, data.ptr, data.len));
    if (ret != data.len) {
        _ = quic.lsquic_stream_wantwrite(stream, 1);
    } else {
        _ = quic.lsquic_stream_wantwrite(stream, 0);
    }
    return ret;
}

fn onWrite(s: ?*quic.lsquic_stream_t, _: ?*quic.lsquic_stream_ctx_t) callconv(.c) void {
    const context: *SocketContext = @ptrCast(@alignCast(quic.lsquic_conn_get_ctx(quic.lsquic_stream_conn(s))));
    context.on_stream_writable.?(context.allocator, context.io, s) catch |err| {
        std.debug.print("onWrite Error: {s}\n", .{@errorName(err)});
        std.debug.dumpCurrentStackTrace(.{});
    };
}

fn onStreamClose(_: ?*quic.lsquic_stream_t, _: ?*quic.lsquic_stream_ctx_t) callconv(.c) void {}

var s_alpn_buf: [0x100]u8 = @splat(0);
var s_alpn: [:0]u8 = s_alpn_buf[0..0 :0];

fn addAlpn(alpn: [:0]const u8) c_int {
    const all_len: usize = s_alpn.len;
    if (alpn.len > 255) {
        return -1;
    }
    if (all_len + 1 + alpn.len + 1 > 0x100) {
        return -1;
    }
    s_alpn_buf[all_len] = @intCast(alpn.len);
    @memcpy((&s_alpn_buf).ptr + all_len + 1, alpn);
    s_alpn_buf[all_len + 1 + alpn.len] = 0;
    s_alpn = s_alpn_buf[0 .. all_len + 1 + alpn.len :0];
    return 0;
}

fn selectAlpn(_: ?*ssl.SSL, out: [*c][*c]const u8, outlen: [*c]u8, in: [*c]const u8, inlen: c_uint, _: ?*anyopaque) callconv(.c) c_int {
    var r: c_int = undefined;
    std.debug.print("select_alpn\n", .{});
    r = ssl.SSL_select_next_proto(@ptrCast(@constCast(out)), outlen, in, inlen, s_alpn.ptr, @intCast(s_alpn.len));
    if (r == ssl.OPENSSL_NPN_NEGOTIATED) {
        std.debug.print("OPENSSL_NPN_NEGOTIATED\n", .{});
        return ssl.SSL_TLSEXT_ERR_OK;
    } else {
        std.debug.print("no supported protocol can be selected!\n", .{});
        return ssl.SSL_TLSEXT_ERR_ALERT_FATAL;
    }
}

var old_ctx: ?*ssl.SSL_CTX = null;

fn serverNameCb(s: ?*ssl.SSL, _: [*c]c_int, _: ?*anyopaque) callconv(.c) c_int {
    std.debug.print("yolo SNI server_name_cb\n", .{});
    _ = ssl.SSL_set_SSL_CTX(s, old_ctx);
    const ssl_server_name = ssl.SSL_get_servername(s, ssl.TLSEXT_NAMETYPE_host_name);
    if (ssl_server_name == null) {
        _ = ssl.SSL_set_tlsext_host_name(s, "YOLO NAME!");
        std.debug.print("set name is: {s}\n", .{std.mem.span(ssl.SSL_get_servername(s, ssl.TLSEXT_NAMETYPE_host_name))});
    } else {
        std.debug.print("existing name is: {s}\n", .{std.mem.span(ssl_server_name)});
    }
    return ssl.SSL_TLSEXT_ERR_OK;
}

fn getSslCtx(peer_ctx: ?*anyopaque, _: ?*const quic.sockaddr) callconv(.c) ?*quic.ssl_ctx_st {
    std.debug.print("getting ssl ctx now, peer_ctx: 0x{x}\n", .{@intFromPtr(peer_ctx)});
    const udp_socket: *udp.Socket = @ptrCast(@alignCast(peer_ctx));
    const context: *SocketContext = @ptrCast(@alignCast(udp_socket.user));
    if (old_ctx != null) {
        return @ptrCast(old_ctx);
    }
    const options = &context.options;
    const ctx = ssl.SSL_CTX_new(ssl.TLS_method());
    old_ctx = ctx;
    _ = ssl.SSL_CTX_set_min_proto_version(ctx, ssl.TLS1_3_VERSION);
    _ = ssl.SSL_CTX_set_max_proto_version(ctx, ssl.TLS1_3_VERSION);
    ssl.SSL_CTX_set_alpn_select_cb(ctx, &selectAlpn, null);
    // TODO: fix for openssl (failed to translate macro)
    _ = ssl.SSL_CTX_set_tlsext_servername_callback(ctx, &serverNameCb);
    std.debug.print("Key: {s}\n", .{options.key_file_name});
    std.debug.print("Cert: {s}\n", .{options.cert_file_name});
    const a = ssl.SSL_CTX_use_certificate_chain_file(ctx, options.cert_file_name.ptr);
    const b = ssl.SSL_CTX_use_PrivateKey_file(ctx, options.key_file_name.ptr, ssl.SSL_FILETYPE_PEM);
    std.debug.print("loaded cert and key? {d}, {d}\n", .{ a, b });
    return @ptrCast(ctx);
}

fn sniLookup(_: ?*anyopaque, _: ?*const quic.sockaddr, _: [*c]const u8) callconv(.c) ?*quic.ssl_ctx_st {
    std.debug.print("simply returning old ctx in sni\n", .{});
    return @ptrCast(old_ctx);
}

fn logBufCb(_: ?*anyopaque, buf: [*c]const u8, len: usize) callconv(.c) c_int {
    std.log.info("{s}\n", .{@as([*:0]const u8, buf)[0..len]});
    return 0;
}

pub fn streamShutdownRead(s: ?*anyopaque) void {
    const stream: *quic.lsquic_stream_t = @ptrCast(s);
    const ret = quic.lsquic_stream_shutdown(stream, 0);
    if (ret != 0) {
        std.debug.print("cannot shutdown stream!\n", .{});
        std.process.exit(0);
    }
}

pub fn streamExt(s: ?*anyopaque) ?*anyopaque {
    return quic.lsquic_stream_get_ctx(@ptrCast(s));
}

pub fn streamClose(s: ?*anyopaque) void {
    const stream: *quic.lsquic_stream_t = @ptrCast(s);
    const ret = quic.lsquic_stream_close(stream);
    if (ret != 0) {
        std.debug.print("cannot close stream!\n", .{});
        std.process.exit(0);
    }
}

pub fn streamShutdown(s: ?*anyopaque) void {
    const stream: *quic.lsquic_stream_t = @ptrCast(s);
    const ret = quic.lsquic_stream_shutdown(stream, 1);
    if (ret != 0) {
        std.debug.print("cannot shutdown stream!\n", .{});
        std.process.exit(0);
    }
}

const HeaderSetHd = extern struct {
    offset: c_int,
};

var last_hset: [*]HeaderSetHd = undefined;

const ProcessedHeader = extern struct {
    name: ?*anyopaque,
    value: ?*anyopaque,
    name_len: c_int,
    value_len: c_int,
};

var pool: [1000][4096]u8 = undefined;
var pool_top: usize = 0;

fn take() ?*anyopaque {
    if (pool_top == 1000) {
        std.debug.print("out of memory\n", .{});
        std.process.exit(0);
    }
    const index = pool_top;
    pool_top += 1;
    return &pool[index];
}

fn leaveAll() void {
    pool_top = 0;
}

fn hsiCreateHeaderSet(_: ?*anyopaque, _: ?*quic.lsquic_stream_t, _: c_int) callconv(.c) ?*anyopaque {
    const hset = take();
    @memset(@as([*]u8, @ptrCast(@alignCast(hset)))[0..@sizeOf(HeaderSetHd)], 0);
    return hset;
}

fn hsiDiscardHeaderSet(_: ?*anyopaque) callconv(.c) void {
    std.debug.print("hsi_discard_header!\n", .{});
}

var header_decode_heap: [1024 * 8]u8 = undefined;
var header_decode_heap_offset: u32 = 0;

fn hsiPrepareDecode(_: ?*anyopaque, hdr: ?*quic.lsxpack_header, space: usize) callconv(.c) ?*quic.lsxpack_header {
    var hdr_: *quic.lsxpack_header = undefined;
    if (hdr) |h| {
        hdr_ = h;
        if (space > 4096) {
            std.debug.print("not handled!\n", .{});
            std.process.exit(0);
        }
        quic.lsxpack_header_set_val_len(hdr_, @intCast(space));
    } else {
        const mem = take();
        hdr_ = @ptrCast(mem);
        quic.lsxpack_header_zero_init(hdr_);
        // @memset(std.mem.asBytes(hdr_), 0);
        quic.lsxpack_header_set_buf(hdr_, @as([*]u8, @ptrCast(@alignCast(mem))) + quic.lsxpack_header_sizeof());
        // hdr_.buf = @as([*]u8, @ptrCast(@alignCast(mem))) + @sizeOf(quic.lsxpack_header);
        quic.lsxpack_header_prepare_decode_(hdr_, quic.lsxpack_header_get_buf(hdr_), 0, space);
    }
    return hdr_;
}

fn hsiProcessHeader(hdr_set: ?*anyopaque, hdr: ?*quic.lsxpack_header) callconv(.c) c_int {
    const hd: [*]HeaderSetHd = @ptrCast(@alignCast(hdr_set));
    const proc_hdr: [*]ProcessedHeader = @ptrCast(@alignCast(hd + 1));
    if (hdr) |h| {
        // TODO: maybe remove `constCast`
        proc_hdr[@intCast(hd[0].offset)].value = quic.lsxpack_header_get_val_ptr(h);
        proc_hdr[@intCast(hd[0].offset)].name = quic.lsxpack_header_get_name_ptr(h);
        proc_hdr[@intCast(hd[0].offset)].value_len = @intCast(quic.lsxpack_header_get_val_len(h));
        proc_hdr[@intCast(hd[0].offset)].name_len = @intCast(quic.lsxpack_header_get_name_len(h));
        hd[0].offset += 1;
        return 0;
    }
    last_hset = hd;
    return 0;
}

fn timerCb(_: std.mem.Allocator, _: std.Io, _: *Timer) !void {
    quic.lsquic_engine_process_conns(global_engine);
    quic.lsquic_engine_process_conns(global_client_engine);

    quic.lsquic_engine_send_unsent_packets(global_engine);
    quic.lsquic_engine_send_unsent_packets(global_client_engine);
}

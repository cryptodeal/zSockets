const c = @cImport({
    @cInclude("lsquic.h");
    @cInclude("lsquic_types.h");
    @cInclude("lsxpack_header.h");
});
const internal = @import("internal/internal.zig");
const udp = @import("udp.zig");

const Loop = @import("loop.zig").Loop;
const SocketDescriptor = internal.SocketDescriptor;
const UdpSocket = udp.UdpSocket;

pub const QuicListenSocket = opaque {};
pub const QuicStream = anyopaque;

pub const QuicSocket = struct {
    udp_socket: ?*anyopaque,
};

pub const QuicSocketCtxOpts = struct {
    cert_file_name: []const u8,
    key_file_name: []const u8,
    passphrase: []const u8,
};

pub fn QuicSocketCtx(comptime T: type) type {
    return struct {
        const Self = @This();

        recv_buf: *anyopaque,
        // send_buf: *anyopaque,
        // udp_socket: *anyopaque,
        loop: *Loop,
        engine: ?*c.lsquic_engine_t = null,
        client_engine: ?*c.lsquic_engine_t = null,

        // store context from the socket's initialization.
        options: T,
        // TODO: might want to
        on_stream_data: *const fn (s: *QuicStream, data: []u8) anyerror!void,
        on_stream_end: *const fn (s: *QuicStream) anyerror!void,
        on_stream_headers: *const fn (s: *QuicStream) anyerror!void,
        on_stream_open: *const fn (s: *QuicStream, is_client: bool) anyerror!void,
        on_stream_close: *const fn (s: *QuicStream) anyerror!void,
        on_open: *const fn (s: *QuicStream, is_client: bool) anyerror!void,
        on_close: *const fn (s: *QuicStream) anyerror!void,

        // TODO(cryptodeal): implement

        pub fn onUdpSocketWritable(s: *UdpSocket) void {
            _ = s; // autofix
            // var ctx: *Self = @ptrCast(@alignCast(udpSocketUser(s)));
            // c.lsquic_engine_send_unsent_packets(ctx.engine);
        }

        // pub fn
    };
}

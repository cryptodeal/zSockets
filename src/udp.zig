const std = @import("std");
const bsd = @import("bsd/root.zig");
const Loop = @import("eventing/impl.zig").Loop;
const Poll = @import("eventing/impl.zig").Poll;
const socket_readable = @import("eventing/impl.zig").socket_readable;
const InternalCallback = @import("internal_callback.zig");

pub const PacketBuffer = bsd.PacketBuffer;

pub const Socket = struct {
    cb: InternalCallback,
    receive_buf: *PacketBuffer,
    data_cb: ?*const fn (std.mem.Allocator, *Socket, *PacketBuffer, usize) anyerror!void = null,
    drain_cb: ?*const fn (std.mem.Allocator, *Socket) anyerror!void = null,
    user: ?*anyopaque = null,
    port: u32,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        loop: *Loop,
        buf: ?*PacketBuffer,
        data_cb: *const fn (std.mem.Allocator, *Socket, *PacketBuffer, usize) anyerror!void,
        drain_cb: *const fn (std.mem.Allocator, *Socket) anyerror!void,
        host: [:0]const u8,
        port: u32,
        user: ?*anyopaque,
    ) !*Socket {
        const fd = try bsd.createUdpSocket(host, port);
        const receive_buf = buf orelse try PacketBuffer.init(allocator);
        errdefer {
            if (buf == null) receive_buf.deinit(allocator);
        }
        var tmp: bsd.Addr = undefined;
        try bsd.localAddr(fd, &tmp);

        const self = try allocator.create(Socket);
        errdefer allocator.destroy(self);
        self.* = .{
            .cb = .{
                .allocator = allocator,
                .io = io,
                .p = undefined,
                .loop = loop,
                .leave_poll_ready = true,
                .cb = @ptrCast(@alignCast(&onUdpRead)),
            },
            .receive_buf = receive_buf,
            .data_cb = data_cb,
            .drain_cb = drain_cb,
            .user = user,
            .port = @intCast(tmp.port),
        };
        std.debug.print("The port of UDP is: {d}\n", .{self.port});
        // `errdefer` is not necessary as we don't allocate anything for the poll here (extension is `null`)
        try self.cb.p.create(allocator, loop, false, null);
        self.cb.p.init(fd, .callback);
        self.cb.p.start(self.cb.loop, socket_readable);
        return self;
    }

    // TODO: verify this handles freeing all resources, closing `fd`, etc.
    pub fn deinit(self: *Socket, allocator: std.mem.Allocator) void {
        self.receive_buf.deinit(allocator);
        self.cb.p.deinit(allocator, self.cb.loop);
        allocator.destroy(self);
    }

    pub fn send(self: *Socket, buf: *PacketBuffer, num: u32) !usize {
        const fd = self.cb.p.fd();
        return buf.sendmmsg(fd, num, 0);
    }

    pub fn receive(self: *Socket, buf: *PacketBuffer) !usize {
        const fd = self.cb.p.fd();
        return buf.recvmmsg(fd, bsd.udp_max_num, 0, null);
    }
};

pub fn onUdpRead(allocator: std.mem.Allocator, _: std.Io, s: *Socket) !void {
    const packets = try s.receive(s.receive_buf);
    try s.data_cb.?(allocator, s, s.receive_buf, packets);
}

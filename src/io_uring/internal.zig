const std = @import("std");

const IoUring = std.os.linux.IoUring;

pub const max_connections = 4096;
pub const backlog = 512;
pub const max_message_len = 2048;
pub const buffers_count = max_connections;

/// 8 byte aligned pointer offset
pub const PointerTags = enum(u4) {
    socket_read,
    socket_write,
    listen_socket_accept,
    socket_connect,
    loop_timer = 7,
};

pub const Timer = struct {
    loop: *Loop,
    fd: c_int,
    buf: u64,
};

pub const Loop = struct {
    // ring: io_uring,
    // buf_ring: *io_uring_buf_ring,
    timer: *Timer,
    head: *SocketCtx,
    iterator: *SocketCtx,
    next_timeout: u64,

    pub fn deinit(self: *Loop) void {
        _ = self; // autofix
    }
};

pub const SocketCtx = struct {
    loop: *Loop,
    global_tick: u32,
    timestamp: u8,
    long_timestamp: u8,
    head_sockets: *Socket,
    head_listen_sockets: *ListenSocket,
    iterator: *Socket,
    // struct us_socket_t *(*on_open)(struct us_socket_t *, int is_client, char *ip, int ip_length);
    // struct us_socket_t *(*on_data)(struct us_socket_t *, char *data, int length);
    // struct us_socket_t *(*on_writable)(struct us_socket_t *);
    // struct us_socket_t *(*on_close)(struct us_socket_t *, int code, void *reason);
    // // void (*on_timeout)(struct us_socket_context *);
    // struct us_socket_t *(*on_socket_timeout)(struct us_socket_t *);
    // struct us_socket_t *(*on_socket_long_timeout)(struct us_socket_t *);
    // struct us_socket_t *(*on_end)(struct us_socket_t *);
    // struct us_socket_t *(*on_connect_error)(struct us_socket_t *, int code);
};

pub const ListenSocket = struct {
    ctx: *SocketCtx,
    socket_ext_size: c_int,
};

pub const Socket = struct {
    ctx: *SocketCtx,
    prev: *Socket,
    next: *Socket,
    timeout: u8, // 1 byte
    long_timeout: u8, // 1 byte
    dd: c_int,

    send_buf: [16 * 1024]u8,
};

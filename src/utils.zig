pub const SslT = enum { boringssl, openssl, wolfssl, nossl };

pub const EventLoopT = enum { io_uring, epoll, kqueue, libuv, gcd, asio };

# zSockets (WIP)

zSockets is a from-scratch zig implementation of the [µSockets](https://github.com/uNetworking/uSockets) library. The name is a play on [µSockets](https://github.com/uNetworking/uSockets), where the "µ" represents the metric prefix for `micro` (1e−6); here, the `z` represents the metric prefix for `zepto` (1e-21) and the Zig programming language.

## Status

### Setup Dependencies

#### SSL/Crypto
[x] [OpenSSL](https://github.com/kassane/openssl-zig) (build flag: `-DUSE_OPENSSL`)
[x] [wolfSSL](https://github.com/cryptodeal/wolfssl-zig) (build flag: `-DUSE_WOLFSSL`)
[ ] [BoringSSL]()

#### Event Loop
[ ] io_uring (build flag: `-DUSE_IO_URING`)
[ ] epoll (build flag: `-DUSE_EPOLL`)
[x] [asio](https://github.com/kassane/asio) (build flag: `-DUSE_ASIO`)


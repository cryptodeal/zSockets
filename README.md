# zSockets (WIP)

zSockets is a from-scratch zig implementation of the [µSockets](https://github.com/uNetworking/uSockets) library. The name is a play on [µSockets](https://github.com/uNetworking/uSockets), where the "µ" represents the metric prefix for `micro` (1e−6); here, the `z` represents the metric prefix for `zepto` (1e-21) and the Zig programming language.

# Setup

Clone the repository and its submodules:
```sh
git clone --recurse-submodules git@github.com:cryptodeal/zSockets.git
```

Once cloned, recursively init submodules:
```sh
git submodule update --init --recursive
```

To build with `boringssl` and `quic`:
```sh
zig build -DUSE_BORINGSSL -DUSE_QUIC
```

To test with `boringssl` and `quic`:
```sh
zig build test -DUSE_BORINGSSL -DUSE_QUIC
```


## Status

### Setup Dependencies

#### SSL/Crypto
- [ ] [BoringSSL](https://github.com/google/boringssl) (default, optionally specified via build flag: `-DUSE_BORINGSSL`)
  - [x] add/link dependency
  - [ ] fleshed out API
- [ ] [OpenSSL](https://github.com/kassane/openssl-zig) (build flag: `-DUSE_OPENSSL`)
  - [x] add/link dependency
  - [ ] fleshed out API
- [ ] [wolfSSL](https://github.com/cryptodeal/wolfssl-zig) (build flag: `-DUSE_WOLFSSL`)
  - [x] add/link dependency
  - [ ] fleshed out API

#### Event Loop
- [ ] io_uring (build flag: `-DUSE_IO_URING`)
  - [ ] fleshed out API
- [ ] epoll (build flag: `-DUSE_EPOLL`)
  - [ ] fleshed out API
- [ ] kqueue (build flag: `-DUSE_KQUEUE`)
  - [ ] fleshed out API
- [ ] [asio](https://github.com/kassane/asio) (build flag: `-DUSE_ASIO`)
  - [x] add/link dependency
  - [ ] fleshed out API
- [ ] [gcd](https://github.com/apple/swift-corelibs-libdispatch) (build flag: `-DUSE_GCD`)
  - [ ] add/link dependency
  - [ ] fleshed out API
- [ ] [libuv](https://github.com/libuv/libuv)
  - [ ] add/link dependency
  - [ ] fleshed out API

#### Other
- [ ] [lsquic](https://github.com/cryptodeal/lsquic-zig) (build flag: `-DUSE_QUIC`)
  - [x] add/link dependency
  - [ ] fleshed out API

#### Other
- [ ] purge zig's C ABI compatability types where possible

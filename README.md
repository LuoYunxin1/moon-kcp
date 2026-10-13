# MoonKCP

MoonKCP is a caller-driven MoonBit implementation of the KCP v1 reliable-datagram state machine. It takes complete datagrams and caller-supplied millisecond ticks, then returns datagrams to send and complete ordered messages to deliver. It does not own sockets, timers, encryption, peer authentication, or application protocols.

The intended users are MoonBit game and real-time runtimes, RPC/remote-management transports, and edge telemetry or configuration agents that need interoperable KCP peers over a datagram layer they already own. The library keeps those integrations on one protocol implementation instead of embedding transport state machines in each application.

## Status and installation

The source is in active development and has not been published to MoonCakes. To build and try the checked-out source, install the MoonBit toolchain, clone this repository, and run:

```sh
moon check --deny-warn
moon test --target wasm-gc --deny-warn
moon run examples/codec
moon run examples/loopback
moon run examples/retransmission
```

A consuming project can add the module from MoonCakes after its separate publication. Until then, do not assume a registry install is available.

## Quick start

`KcpControl` is sans-I/O: the host provides datagrams and time. Construct two peers with the same conversation id, queue a message, and shuttle returned datagrams through the network layer:

```mbt
match new_kcp_control(7L, kcp_default_config()) {
  Err(_) => println("Invalid KCP configuration")
  Ok(peer) =>
    match peer.send([1, 2, 3]) {
      Err(_) => println("Message exceeds configured limits")
      Ok(fragments) => {
        println("Queued fragments: " + fragments.to_string())
        match peer.update(0L) {
          Err(_) => println("Update failed")
          Ok(datagrams) => println("Datagrams to send: " + datagrams.length().to_string())
        }
      }
    }
}
```

The host sends each returned datagram through its chosen network API and passes peer datagrams to `input`. For a complete runnable exchange, including ACK delivery and ordered receive, see [`examples/loopback`](examples/loopback). The codec example demonstrates the 24-byte little-endian KCP header, and the retransmission example simulates a dropped datagram without opening a socket.

## Public lifecycle

- `new_kcp_control(conv, config)` validates and copies configuration.
- `send(message)` copies and fragments a bounded application message.
- `update(now_ms)` advances the u32 KCP clock and returns due output datagrams.
- `input(datagram)` validates the complete datagram before consuming its segments.
- `recv()` removes the oldest complete ordered message, when available.
- `check(now_ms)` reports the next caller update time; no timer is started internally.
- `flush()` emits pending ACKs, probes, new sends, and due retransmissions.

See the generated package interface and API doc comments for the exact error and statistics types. Sequence and clock arithmetic use the KCP 32-bit serial space. Configuration bounds MTU, message fragments, queued bytes, receive/send windows, and the number of segments accepted per datagram. Optional stream mode can coalesce bytes into unsent segment space; it does not preserve `send` call boundaries, so applications should concatenate chunks returned by `recv` when using it.

## Protocol and scope

The compatibility reference is [`skywind3000/kcp`](https://github.com/skywind3000/kcp), revision `8004f7eba5d1bf33f0691eef5f887f2cd3140cb5` (MIT). MoonKCP is an independent MoonBit rewrite of the KCP v1 wire format and caller-driven control-block behavior; it does not claim source-code compatibility or performance parity. The implementation boundary and intentionally unsupported behavior are recorded in [`docs/protocol-boundary.md`](docs/protocol-boundary.md), and attribution is in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

KCP is not QUIC or SCTP. This package does not supply UDP sockets, NAT traversal, encryption/authentication, peer identity, multiplexing, RPC serialization, or a new congestion-control algorithm. Applications remain responsible for those layers and for deciding which data needs reliable ordered delivery.

## Development

```sh
moon info
moon fmt
moon check --deny-warn
moon test --target wasm-gc --deny-warn
```

Continuous integration checks formatting and generated interfaces, builds the library and examples, and runs tests for wasm-gc, wasm, JavaScript, and native targets. The native target is exercised in CI because this development machine does not have a native C toolchain.

## License and AI disclosure

MoonKCP is licensed under Apache-2.0. The upstream KCP project is separately attributed under its MIT license; no upstream implementation source is copied. AI-assisted work and maintainer review responsibilities are disclosed in [`AI-USE.md`](AI-USE.md).

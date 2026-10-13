# Protocol and API boundaries

## Compatibility objective

MoonKCP implements the KCP v1 datagram protocol as a caller-driven state machine. A host owns sockets, scheduling, clocks, encryption/authentication, peer identity, and packet loss policy. The library accepts complete datagrams and timestamps, then returns outbound datagrams and complete messages.

A KCP segment has a 24-byte little-endian header: conversation id (u32), command (u8), fragment count (u8), advertised window (u16), timestamp (u32), sequence number (u32), UNA (u32), and payload length (u32). Commands are PUSH=81, ACK=82, WASK=83, and WINS=84. A datagram can contain multiple consecutive segments. Parsers must reject truncated headers, impossible lengths, and unsupported commands without reading outside the supplied buffer.

## State-machine responsibilities

- Assign sequence numbers and fragment messages within the configured message-size/window limits.
- Process ACK and UNA information, update RTT/RTO estimates, and release acknowledged send segments.
- Track receive-window occupancy, queue out-of-order fragments, and release complete messages in sequence order.
- Schedule timeout and fast retransmission according to KCP v1 behavior.
- Generate window probes and acknowledgements; report the next update/check deadline without owning a timer.

## Explicitly outside scope

No socket APIs, DNS, congestion-control redesign, encryption, authentication, multiplexing protocol, generic ARQ abstraction, or complete RPC/game service. The implementation must not claim that “sans-I/O” alone is novel. Unsupported upstream options or behavior must be documented and tested as such.

## Numeric and resource invariants

Protocol u32 values are compared using serial-number arithmetic, including wrap-around. Datagrams, queued bytes, fragment counts, and session windows need explicit limits. Arithmetic that would overflow a host integer or exceed configured bounds returns a structured error instead of panicking or allocating without limit.
# Protocol and API boundaries

## Compatibility objective

MoonKCP implements the KCP v1 datagram protocol as a caller-driven state machine. A host owns sockets, scheduling, clocks, encryption/authentication, peer identity, and packet loss policy. The library accepts complete datagrams and timestamps, then returns outbound datagrams and complete messages.

A KCP segment has a 24-byte little-endian header: conversation id (u32), command (u8), fragment count (u8), advertised window (u16), timestamp (u32), sequence number (u32), UNA (u32), and payload length (u32). Commands are PUSH=81, ACK=82, WASK=83, and WINS=84. A datagram can contain multiple consecutive segments. Parsers must reject truncated headers, impossible lengths, and unsupported commands without reading outside the supplied buffer.

## State-machine responsibilities

- Assign sequence numbers and fragment messages within the configured message-size/window limits. A single call queues at most 127 new segments, matching the KCP v1 `WND_RCV` send-count ceiling; stream mode applies this after unsent-tail coalescing.
- Process ACK and UNA information, update RTT/RTO estimates, and release acknowledged send segments.
- Track receive-window occupancy, queue out-of-order fragments, and release complete messages in sequence order.
- Schedule timeout and fast retransmission according to KCP v1 behavior.
- Generate window probes and acknowledgements; report the next update/check deadline without owning a timer.

## Input error semantics

Wire framing, conversation IDs, and command values are checked across the decoded datagram before sequence-dependent state processing begins. After that preflight, segments are processed in wire order. A PUSH outside the receive window is ignored, while an already-received PUSH is acknowledged; both decisions precede fragment-chain validation. An eligible PUSH that violates the fragment or queue limit returns a structured error.

This is not a transactional API: if an eligible segment fails after earlier segments in the same datagram have been processed, those earlier ACK, receive, window, and diagnostic effects are not rolled back. PUSHes already accepted before a complete fragment chain is checked also retain their pending ACKs and receive-sequence advancement if that chain is inconsistent; no message is delivered for that invalid chain. `ReceiveWindowOverflow` is reserved for an individual PUSH whose `frg + 1` exceeds the configured receive window. Once enough eligible fragments are present to confirm that their `frg` values do not descend to zero, `input` instead returns `InvalidFragmentChain` and counts the datagram as malformed. Callers should record the error and avoid blindly replaying the whole datagram.

## Explicitly outside scope

No socket APIs, DNS, congestion-control redesign, encryption, authentication, multiplexing protocol, generic ARQ abstraction, or complete RPC/game service. The implementation must not claim that “sans-I/O” alone is novel. Unsupported upstream options or behavior must be documented and tested as such.

## Numeric and resource invariants

Protocol u32 values are compared using serial-number arithmetic, including wrap-around. Datagrams, queued bytes, fragment counts, and session windows need explicit limits. Pending ACKs are coalesced by sequence number and retained within a separate bounded budget; a repeated sequence keeps the newest serial timestamp. Arithmetic that would overflow a host integer or exceed configured bounds returns a structured error instead of panicking or allocating without limit.
# Changelog

All notable changes to MoonKCP are recorded here.

## 0.1.0 (unreleased)

- Implement the KCP v1 little-endian segment codec and caller-driven control block.
- Add bounded send/receive queues, message fragmentation and ordered reassembly, ACK/UNA processing, RTT/RTO estimation, timeout and fast retransmission, congestion gating, and window probes.
- Add stream mode, wrap-safe sequence and clock arithmetic, structured input errors, and transport statistics.
- Add codec, loopback, and packet-loss retransmission examples, plus CI for wasm-gc, wasm, JavaScript, and native targets.
- Record the protocol compatibility boundary, upstream MIT attribution, independent-rewrite statement, and AI-use disclosure.

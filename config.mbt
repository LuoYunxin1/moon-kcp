///|
/// Hard safety ceilings for caller-configurable buffering. The default profile
/// stays much smaller; these limits prevent accidentally configuring queues
/// that cannot be represented safely by MoonBit's indexed arrays.
let kcp_hard_max_message_size : Int = 16 * 1024 * 1024

///|
let kcp_hard_max_queued_bytes : Int = 64 * 1024 * 1024

///|
/// Bound queue entries independently of payload bytes, since each segment
/// also owns a header and runtime object.
let kcp_hard_max_queued_segments : Int = 65535

///|
/// KCP v1 rejects a single send whose segment count reaches WND_RCV (128).
let kcp_protocol_max_send_segments : Int = 127

///|
/// Limits and scheduling values for one KCP control block.
///
/// The defaults match the common KCP v1 control block, with explicit resource
/// caps added so an untrusted peer cannot grow queues without bound.
pub struct KcpConfig {
  mut mtu : Int
  mut send_window : Int
  mut receive_window : Int
  mut interval_ms : Int
  mut fast_resend : Int
  mut no_congestion_control : Bool
  mut stream_mode : Bool
  mut initial_rto_ms : Int
  mut minimum_rto_ms : Int
  mut maximum_rto_ms : Int
  mut max_message_size : Int
  mut max_queued_bytes : Int
  mut max_segments_per_datagram : Int
}

///|
/// Return the interoperable KCP v1 defaults with finite defensive queue caps.
pub fn kcp_default_config() -> KcpConfig {
  {
    mtu: 1400,
    send_window: 32,
    receive_window: 128,
    interval_ms: 100,
    fast_resend: 0,
    no_congestion_control: false,
    stream_mode: false,
    initial_rto_ms: 200,
    minimum_rto_ms: 100,
    maximum_rto_ms: 60000,
    max_message_size: 127 * (1400 - 24),
    max_queued_bytes: 4 * 1024 * 1024,
    max_segments_per_datagram: 32,
  }
}

///|
/// Set the datagram MTU. The control block rejects invalid configuration later.
pub fn KcpConfig::set_mtu(self : Self, mtu : Int) -> Unit {
  self.mtu = mtu
}

///|
/// Set the sender and receiver window sizes.
pub fn KcpConfig::set_windows(
  self : Self,
  send_window : Int,
  receive_window : Int,
) -> Unit {
  self.send_window = send_window
  self.receive_window = receive_window
}

///|
/// Set the periodic flush interval in milliseconds.
pub fn KcpConfig::set_interval(self : Self, interval_ms : Int) -> Unit {
  self.interval_ms = interval_ms
}

///|
/// Set the duplicate-ACK threshold for fast retransmission (zero disables it).
pub fn KcpConfig::set_fast_resend(self : Self, fast_resend : Int) -> Unit {
  self.fast_resend = fast_resend
}

///|
/// Toggle the KCP congestion-window gate.
pub fn KcpConfig::set_no_congestion_control(
  self : Self,
  disabled : Bool,
) -> Unit {
  self.no_congestion_control = disabled
}

///|
/// Toggle stream-compatible send semantics.
pub fn KcpConfig::set_stream_mode(self : Self, enabled : Bool) -> Unit {
  self.stream_mode = enabled
}

///|
/// Set the initial, minimum, and maximum retransmission timeouts.
pub fn KcpConfig::set_rto_limits(
  self : Self,
  minimum_ms : Int,
  initial_ms : Int,
  maximum_ms : Int,
) -> Unit {
  self.minimum_rto_ms = minimum_ms
  self.initial_rto_ms = initial_ms
  self.maximum_rto_ms = maximum_ms
}

///|
/// Set bounded message, queued-byte, and datagram-segment limits.
pub fn KcpConfig::set_resource_limits(
  self : Self,
  max_message_size : Int,
  max_queued_bytes : Int,
  max_segments_per_datagram : Int,
) -> Unit {
  self.max_message_size = max_message_size
  self.max_queued_bytes = max_queued_bytes
  self.max_segments_per_datagram = max_segments_per_datagram
}

///|
/// Validate values before constructing a state machine.
///
/// This check is deliberately side-effect free. KCP v1 carries several narrow
/// integer fields, so values outside their on-wire ranges are not silently
/// truncated.
pub fn kcp_config_is_valid(config : KcpConfig) -> Bool {
  let header_size = 24
  config.mtu >= header_size + 1 &&
  config.mtu <= 65507 &&
  config.send_window >= 1 &&
  config.send_window <= 65535 &&
  config.receive_window >= 1 &&
  config.receive_window <= 65535 &&
  config.interval_ms >= 10 &&
  config.interval_ms <= 5000 &&
  config.fast_resend >= 0 &&
  config.fast_resend <= 255 &&
  config.minimum_rto_ms >= 10 &&
  config.initial_rto_ms >= config.minimum_rto_ms &&
  config.maximum_rto_ms >= config.initial_rto_ms &&
  config.maximum_rto_ms <= 60000 &&
  config.max_message_size >= 0 &&
  config.max_message_size <= kcp_hard_max_message_size &&
  config.max_message_size <= config.max_queued_bytes &&
  (
    config.stream_mode ||
    (
      kcp_config_max_fragments(config) <= kcp_protocol_max_send_segments &&
      kcp_config_max_fragments(config) <= config.receive_window
    )
  ) &&
  config.max_queued_bytes >= config.mtu &&
  config.max_queued_bytes <= kcp_hard_max_queued_bytes &&
  config.max_segments_per_datagram >= 1 &&
  config.max_segments_per_datagram <= 255
}

///|
/// Return the payload capacity of each PUSH segment for a validated MTU.
pub fn kcp_config_mss(config : KcpConfig) -> Int {
  config.mtu - 24
}

///|
/// Return the maximum number of segments needed for a configured message.
pub fn kcp_config_max_fragments(config : KcpConfig) -> Int {
  let mss = kcp_config_mss(config)
  if mss <= 0 {
    0
  } else if config.max_message_size == 0 {
    1
  } else {
    // This ceiling-division form avoids overflowing `value + mss - 1`.
    (config.max_message_size - 1) / mss + 1
  }
}

///|
/// Check whether one send call fits its configured byte and segment limits.
pub fn kcp_config_accepts_message(
  config : KcpConfig,
  byte_length : Int,
) -> Bool {
  if !kcp_config_is_valid(config) ||
    byte_length < 0 ||
    byte_length > config.max_message_size {
    false
  } else {
    let mss = kcp_config_mss(config)
    let fragments = if byte_length == 0 {
      1
    } else {
      (byte_length - 1) / mss + 1
    }
    fragments <= kcp_protocol_max_send_segments
  }
}

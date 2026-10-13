///|
/// Failures from a caller-driven KCP control block.
pub enum KcpStateError {
  InvalidConfiguration
  InvalidConversation(Int64)
  ConversationMismatch(Int64, Int64)
  MalformedDatagram(KcpError)
  UnsupportedCommand(KcpCommand)
  MessageTooLarge(Int)
  TooManySegments(Int, Int)
  InvalidPayloadByte(Int, Int)
  QueueLimitExceeded(Int, Int)
  QueueSegmentLimitExceeded(Int, Int)
  InvalidClock(Int64)
  InvalidFragmentChain
  ReceiveWindowOverflow
} derive(Eq, Debug)

///|
pub extend KcpStateError with Eq::{not_equal, equal}

///|
pub extend KcpStateError with @debug.Debug::{to_repr}

///|
/// A cumulative snapshot of observable control-block activity.
pub struct KcpStats {
  sent_datagrams : Int
  sent_segments : Int
  sent_payload_bytes : Int
  received_datagrams : Int
  received_segments : Int
  received_payload_bytes : Int
  delivered_messages : Int
  retransmissions : Int
  fast_retransmissions : Int
  timeout_retransmissions : Int
  duplicate_acks : Int
  out_of_window_segments : Int
  malformed_datagrams : Int
}

///|
/// Summary of one successfully parsed datagram.
pub struct KcpInputReport {
  segment_count : Int
  acknowledgements : Int
  pushed_segments : Int
  accepted_payload_bytes : Int
  ignored_out_of_window : Int
}

///|
/// Internal send state attached to one sequence-numbered PUSH segment.
priv struct KcpTxEntry {
  segment : KcpSegment
  resend_at : Int64
  resend_timeout : Int
  mut fast_ack : Int
  transmissions : Int
}

///|
/// One acknowledgement retained until the next output flush.
priv struct KcpReceiveMessage {
  data : Array[Int]
  segments : Int
}

///|
priv struct KcpPendingAck {
  sn : Int64
  mut ts : Int64
}

///|
/// KCP v1 control block. All I/O remains with the caller.
///
/// Construct with `new_kcp_control`, enqueue messages using `send`, pass peer
/// datagrams to `input`, advance time with `update`, and read complete ordered
/// messages with `recv`. `update` returns datagrams for the host to transmit.
pub struct KcpControl {
  priv conv : Int64
  priv config : KcpConfig
  priv mut current : Int64
  priv mut clock_started : Bool
  priv mut updated : Bool
  priv mut snd_una : Int64
  priv mut snd_nxt : Int64
  priv mut rcv_nxt : Int64
  priv mut send_queue : Array[KcpSegment]
  priv mut send_buffer : Array[KcpTxEntry]
  priv mut receive_buffer : Array[KcpSegment]
  priv mut receive_queue : Array[KcpSegment]
  priv mut receive_messages : Array[KcpReceiveMessage]
  priv mut pending_acks : Array[KcpPendingAck]
  priv mut remote_window : Int
  priv mut congestion_window : Int
  priv mut congestion_increment : Int64
  priv mut slow_start_threshold : Int
  priv mut smoothed_rtt : Int
  priv mut rtt_variance : Int
  priv mut retransmission_timeout : Int
  priv mut next_flush : Int64
  priv mut probe_flags : Int
  priv mut probe_deadline : Int64
  priv mut probe_interval : Int
  priv mut send_queue_bytes : Int
  priv mut send_buffer_bytes : Int
  priv mut receive_buffer_bytes : Int
  priv mut receive_queue_bytes : Int
  priv mut receive_queue_segments : Int
  priv mut sent_datagrams : Int
  priv mut sent_segments : Int
  priv mut sent_payload_bytes : Int
  priv mut received_datagrams : Int
  priv mut received_segments : Int
  priv mut received_payload_bytes : Int
  priv mut delivered_messages : Int
  priv mut retransmissions : Int
  priv mut fast_retransmissions : Int
  priv mut timeout_retransmissions : Int
  priv mut duplicate_acks : Int
  priv mut out_of_window_segments : Int
  priv mut malformed_datagrams : Int
}

///|
/// Copy a half-open byte range after the caller has checked its bounds.
fn kcp_copy_byte_range(data : Array[Int], start : Int, end : Int) -> Array[Int] {
  let copied : Array[Int] = []
  let mut index = start
  while index < end {
    copied.push(data[index])
    index += 1
  }
  copied
}

///|
/// Copy configuration so later caller mutations cannot invalidate this session.
fn kcp_copy_config(config : KcpConfig) -> KcpConfig {
  {
    mtu: config.mtu,
    send_window: config.send_window,
    receive_window: config.receive_window,
    interval_ms: config.interval_ms,
    fast_resend: config.fast_resend,
    no_congestion_control: config.no_congestion_control,
    stream_mode: config.stream_mode,
    initial_rto_ms: config.initial_rto_ms,
    minimum_rto_ms: config.minimum_rto_ms,
    maximum_rto_ms: config.maximum_rto_ms,
    max_message_size: config.max_message_size,
    max_queued_bytes: config.max_queued_bytes,
    max_segments_per_datagram: config.max_segments_per_datagram,
  }
}

///|
/// Create a fresh KCP v1 session with validated settings and a fixed conversation id.
pub fn new_kcp_control(
  conv : Int64,
  config : KcpConfig,
) -> Result[KcpControl, KcpStateError] {
  if conv < 0L || conv > kcp_u32_max {
    Err(InvalidConversation(conv))
  } else if !kcp_config_is_valid(config) {
    Err(InvalidConfiguration)
  } else {
    let actual_config = kcp_copy_config(config)
    let send_queue : Array[KcpSegment] = []
    let send_buffer : Array[KcpTxEntry] = []
    let receive_buffer : Array[KcpSegment] = []
    let receive_queue : Array[KcpSegment] = []
    let receive_messages : Array[KcpReceiveMessage] = []
    let pending_acks : Array[KcpPendingAck] = []
    Ok({
      conv,
      config: actual_config,
      current: 0L,
      clock_started: false,
      updated: false,
      snd_una: 0L,
      snd_nxt: 0L,
      rcv_nxt: 0L,
      send_queue,
      send_buffer,
      receive_buffer,
      receive_queue,
      receive_messages,
      pending_acks,
      remote_window: actual_config.receive_window,
      congestion_window: 1,
      congestion_increment: kcp_config_mss(actual_config).to_int64(),
      slow_start_threshold: 2,
      smoothed_rtt: 0,
      rtt_variance: 0,
      retransmission_timeout: actual_config.initial_rto_ms,
      next_flush: 0L,
      probe_flags: 0,
      probe_deadline: 0L,
      probe_interval: 0,
      send_queue_bytes: 0,
      send_buffer_bytes: 0,
      receive_buffer_bytes: 0,
      receive_queue_bytes: 0,
      receive_queue_segments: 0,
      sent_datagrams: 0,
      sent_segments: 0,
      sent_payload_bytes: 0,
      received_datagrams: 0,
      received_segments: 0,
      received_payload_bytes: 0,
      delivered_messages: 0,
      retransmissions: 0,
      fast_retransmissions: 0,
      timeout_retransmissions: 0,
      duplicate_acks: 0,
      out_of_window_segments: 0,
      malformed_datagrams: 0,
    })
  }
}

///|
/// Return this control block's immutable conversation identifier.
pub fn KcpControl::conversation(self : Self) -> Int64 {
  self.conv
}

///|
/// Return the negotiated payload size per KCP segment.
pub fn KcpControl::maximum_segment_payload(self : Self) -> Int {
  kcp_config_mss(self.config)
}

///|
/// Return queued send bytes, including both waiting and transmitted segments.
pub fn KcpControl::waitsnd_bytes(self : Self) -> Int {
  self.send_queue_bytes + self.send_buffer_bytes
}

///|
/// Return the number of unacknowledged or not-yet-emitted PUSH segments.
pub fn KcpControl::waitsnd_segments(self : Self) -> Int {
  self.send_queue.length() + self.send_buffer.length()
}

///|
/// Return complete receive messages waiting for the application.
pub fn KcpControl::pending_messages(self : Self) -> Int {
  self.receive_messages.length()
}

///|
/// Return the next receive sequence expected from the peer.
pub fn KcpControl::next_receive_sequence(self : Self) -> Int64 {
  self.rcv_nxt
}

///|
/// Return the next local sequence number to assign to a PUSH segment.
pub fn KcpControl::next_send_sequence(self : Self) -> Int64 {
  self.snd_nxt
}

///|
/// Return an immutable statistics snapshot for monitoring and tests.
pub fn KcpControl::stats(self : Self) -> KcpStats {
  {
    sent_datagrams: self.sent_datagrams,
    sent_segments: self.sent_segments,
    sent_payload_bytes: self.sent_payload_bytes,
    received_datagrams: self.received_datagrams,
    received_segments: self.received_segments,
    received_payload_bytes: self.received_payload_bytes,
    delivered_messages: self.delivered_messages,
    retransmissions: self.retransmissions,
    fast_retransmissions: self.fast_retransmissions,
    timeout_retransmissions: self.timeout_retransmissions,
    duplicate_acks: self.duplicate_acks,
    out_of_window_segments: self.out_of_window_segments,
    malformed_datagrams: self.malformed_datagrams,
  }
}

///|
/// Queue one application message for reliable ordered delivery.
///
/// The peer is not contacted until the host calls `update` and sends the
/// returned datagrams. A message must fit the configured byte and fragment
/// limits. Its input byte array is copied before the function returns. The result
/// counts newly allocated KCP segments, not accepted bytes; in stream mode it can
/// be zero when all bytes coalesce into an unsent segment. Unsent chunks may
/// coalesce, so application write boundaries are not preserved as message
/// boundaries.
pub fn KcpControl::send(
  self : Self,
  message : Array[Int],
) -> Result[Int, KcpStateError] {
  if message.length() > self.config.max_message_size {
    return Err(MessageTooLarge(message.length()))
  }
  let mut valid = true
  let mut index = 0
  while index < message.length() && valid {
    if message[index] < 0 || message[index] > 255 {
      valid = false
    }
    index += 1
  }
  if !valid {
    return Err(InvalidPayloadByte(index - 1, message[index - 1]))
  }

  let mss = kcp_config_mss(self.config)
  let queued = self.send_queue_bytes + self.send_buffer_bytes
  if message.length() > self.config.max_queued_bytes - queued {
    return Err(QueueLimitExceeded(queued, self.config.max_queued_bytes))
  }
  let tail_space = if self.config.stream_mode && self.send_queue.length() > 0 {
    mss - self.send_queue[self.send_queue.length() - 1].data.length()
  } else {
    0
  }
  let merge_bytes = kcp_int_min(message.length(), tail_space)
  let remainder = message.length() - merge_bytes
  let new_segments = if self.config.stream_mode {
    if remainder == 0 {
      0
    } else {
      (remainder - 1) / mss + 1
    }
  } else if message.length() == 0 {
    1
  } else {
    (message.length() - 1) / mss + 1
  }
  if new_segments > kcp_protocol_max_send_segments {
    return Err(TooManySegments(new_segments, kcp_protocol_max_send_segments))
  }
  let max_queued_segments = kcp_int_min(
    self.config.max_queued_bytes / mss,
    kcp_hard_max_queued_segments,
  )
  let queued_segments = self.send_queue.length() + self.send_buffer.length()
  if new_segments > max_queued_segments - queued_segments {
    return Err(QueueSegmentLimitExceeded(queued_segments, max_queued_segments))
  }

  let mut offset = 0
  if merge_bytes > 0 {
    let tail_index = self.send_queue.length() - 1
    while offset < merge_bytes {
      self.send_queue[tail_index].data.push(message[offset])
      offset += 1
    }
  }
  let mut fragment_index = 0
  while offset < message.length() ||
        (
          !self.config.stream_mode &&
          message.length() == 0 &&
          fragment_index == 0
        ) {
    let end = kcp_int_min(offset + mss, message.length())
    let payload = kcp_copy_byte_range(message, offset, end)
    let frg = if self.config.stream_mode {
      0
    } else {
      new_segments - fragment_index - 1
    }
    self.send_queue.push({
      conv: self.conv,
      cmd: Push,
      frg,
      wnd: self.kcp_control_receive_window(),
      ts: 0L,
      sn: 0L,
      una: 0L,
      data: payload,
    })
    offset = end
    fragment_index += 1
  }
  self.send_queue_bytes += message.length()
  Ok(new_segments)
}

///|
/// Remove the oldest complete message, or return `None` while receive is pending.
pub fn KcpControl::recv(self : Self) -> Array[Int]? {
  if self.receive_messages.length() == 0 {
    None
  } else {
    let queued = self.receive_messages[0]
    let remaining : Array[KcpReceiveMessage] = []
    let mut index = 1
    while index < self.receive_messages.length() {
      remaining.push(self.receive_messages[index])
      index += 1
    }
    self.receive_messages = remaining
    let was_full = self.kcp_control_receive_window() == 0
    self.receive_queue_bytes -= queued.data.length()
    self.receive_queue_segments -= queued.segments
    if was_full && self.kcp_control_receive_window() > 0 {
      self.probe_flags = self.probe_flags | 2
    }
    self.delivered_messages += 1
    Some(queued.data)
  }
}

///|
/// Compute the receiver's current advertised segment window.
fn KcpControl::kcp_control_receive_window(self : KcpControl) -> Int {
  let occupied = self.receive_queue_segments + self.receive_buffer.length()
  let remaining = self.config.receive_window - occupied
  if remaining <= 0 {
    0
  } else {
    remaining
  }
}

///|
/// Return the serial distance from `start` to `end` modulo 2^32.
fn kcp_sequence_distance(start : Int64, end : Int64) -> Int64 {
  kcp_seq_add(end, -start)
}

///|
/// Add milliseconds modulo the 32-bit KCP clock space.
fn kcp_time_add(time : Int64, milliseconds : Int) -> Int64 {
  kcp_seq_add(time, milliseconds.to_int64())
}

///|
/// Return true if an unsigned serial value is within a half-open interval.
fn kcp_sequence_in_range(value : Int64, start : Int64, end : Int64) -> Bool {
  !kcp_seq_less(value, start) && kcp_seq_less(value, end)
}

///|
/// A bounded serializer batches independently encoded segments into UDP packets.
priv struct KcpDatagramBuilder {
  packets : Array[Array[Int]]
  mut current : Array[Int]
  mut segments : Int
  mtu : Int
  max_segments : Int
}

///|
fn new_kcp_datagram_builder(
  mtu : Int,
  max_segments : Int,
) -> KcpDatagramBuilder {
  { packets: [], current: [], segments: 0, mtu, max_segments, }
}

///|
fn KcpDatagramBuilder::finish_current(self : Self) -> Unit {
  if self.current.length() > 0 {
    self.packets.push(self.current)
    self.current = []
    self.segments = 0
  }
}

///|
fn KcpDatagramBuilder::append(
  self : Self,
  segment : KcpSegment,
) -> Result[Unit, KcpStateError] {
  let encoded = match kcp_encode_segment(segment) {
    Ok(bytes) => bytes
    Err(error) => return Err(MalformedDatagram(error))
  }
  if encoded.length() > self.mtu {
    return Err(MalformedDatagram(PayloadTooLarge(encoded.length())))
  }
  if self.segments >= self.max_segments ||
    self.current.length() + encoded.length() > self.mtu {
    self.finish_current()
  }
  for byte in encoded {
    self.current.push(byte)
  }
  self.segments += 1
  Ok(())
}

///|
fn KcpDatagramBuilder::finish(self : Self) -> Array[Array[Int]] {
  self.finish_current()
  self.packets
}

///|
fn kcp_time_diff(later : Int64, earlier : Int64) -> Int64 {
  let distance = kcp_sequence_distance(earlier, later)
  if distance >= kcp_u32_half {
    distance - 4294967296L
  } else {
    distance
  }
}

///|
fn kcp_int_min(left : Int, right : Int) -> Int {
  if left < right {
    left
  } else {
    right
  }
}

///|
fn kcp_int_max(left : Int, right : Int) -> Int {
  if left > right {
    left
  } else {
    right
  }
}

///|
fn KcpControl::kcp_control_update_snd_una(self : Self) -> Unit {
  if self.send_buffer.length() == 0 {
    self.snd_una = self.snd_nxt
  } else {
    self.snd_una = self.send_buffer[0].segment.sn
  }
}

///|
fn KcpControl::kcp_control_una_is_plausible(self : Self, una : Int64) -> Bool {
  let outstanding = kcp_sequence_distance(self.snd_una, self.snd_nxt)
  let offset = kcp_sequence_distance(self.snd_una, una)
  if offset <= outstanding {
    true
  } else {
    let stale_distance = kcp_sequence_distance(una, self.snd_una)
    stale_distance > 0L && stale_distance < kcp_u32_half
  }
}

///|
fn KcpControl::kcp_control_parse_una(self : Self, una : Int64) -> Unit {
  if !self.kcp_control_una_is_plausible(una) {
    return
  }
  let remaining : Array[KcpTxEntry] = []
  for entry in self.send_buffer {
    if kcp_seq_less(entry.segment.sn, una) {
      self.send_buffer_bytes -= entry.segment.data.length()
    } else {
      remaining.push(entry)
    }
  }
  self.send_buffer = remaining
  self.kcp_control_update_snd_una()
}

///|
fn KcpControl::kcp_control_update_rtt(self : Self, sample : Int) -> Unit {
  if sample <= 0 {
    return
  }
  if self.smoothed_rtt == 0 {
    self.smoothed_rtt = sample
    self.rtt_variance = sample / 2
  } else {
    let delta = if sample > self.smoothed_rtt {
      sample - self.smoothed_rtt
    } else {
      self.smoothed_rtt - sample
    }
    self.rtt_variance = (3 * self.rtt_variance + delta) / 4
    self.smoothed_rtt = (7 * self.smoothed_rtt + sample) / 8
    if self.smoothed_rtt < 1 {
      self.smoothed_rtt = 1
    }
  }
  let variation = kcp_int_max(self.config.interval_ms, 4 * self.rtt_variance)
  let estimate = self.smoothed_rtt + variation
  self.retransmission_timeout = kcp_int_min(
    self.config.maximum_rto_ms,
    kcp_int_max(self.config.minimum_rto_ms, estimate),
  )
}

///|
fn KcpControl::kcp_control_remove_ack(self : Self, sn : Int64) -> Bool {
  let mut found = false
  let remaining : Array[KcpTxEntry] = []
  for entry in self.send_buffer {
    if entry.segment.sn == sn && !found {
      found = true
      self.send_buffer_bytes -= entry.segment.data.length()
    } else {
      remaining.push(entry)
    }
  }
  if found {
    self.send_buffer = remaining
    self.kcp_control_update_snd_una()
  }
  found
}

///|
fn KcpControl::kcp_control_adjust_congestion(
  self : Self,
  previous_una : Int64,
) -> Unit {
  if self.config.no_congestion_control ||
    self.snd_una == previous_una ||
    kcp_seq_less(self.snd_una, previous_una) {
    return
  }
  let mss = kcp_config_mss(self.config)
  if self.congestion_window < self.slow_start_threshold {
    self.congestion_window += 1
    self.congestion_increment += mss.to_int64()
  } else if self.congestion_window < self.remote_window {
    let increase = mss.to_int64() *
      mss.to_int64() /
      (if self.congestion_increment < 1L {
        1L
      } else {
        self.congestion_increment
      }) +
      (mss / 16).to_int64()
    self.congestion_increment += increase
    if (self.congestion_window + 1).to_int64() * mss.to_int64() <=
      self.congestion_increment {
      self.congestion_window = kcp_int_min(
        self.remote_window,
        (self.congestion_increment / mss.to_int64()).to_int(),
      )
    }
  }
  if self.congestion_window > self.remote_window {
    self.congestion_window = self.remote_window
    self.congestion_increment = self.remote_window.to_int64() * mss.to_int64()
  }
  if self.congestion_window < 1 && self.remote_window > 0 {
    self.congestion_window = 1
  }
}

///|
fn KcpControl::kcp_control_push_pending_ack(
  self : Self,
  sn : Int64,
  ts : Int64,
) -> Unit {
  for pending in self.pending_acks {
    if pending.sn == sn {
      if kcp_time_diff(ts, pending.ts) >= 0L {
        pending.ts = ts
      }
      return
    }
  }
  let cap = kcp_int_min(
    self.config.max_queued_bytes / kcp_header_size,
    self.config.receive_window * 4,
  )
  if self.pending_acks.length() < cap {
    self.pending_acks.push({ sn, ts, })
  }
}

///|
fn KcpControl::kcp_control_receive_has_sequence(
  self : Self,
  sn : Int64,
) -> Bool {
  let mut index = 0
  while index < self.receive_buffer.length() {
    if self.receive_buffer[index].sn == sn {
      return true
    }
    index += 1
  }
  false
}

///|
fn KcpControl::kcp_control_insert_receive_segment(
  self : Self,
  segment : KcpSegment,
) -> Bool {
  let mut index = 0
  while index < self.receive_buffer.length() &&
        kcp_seq_less(self.receive_buffer[index].sn, segment.sn) {
    index += 1
  }
  if index < self.receive_buffer.length() &&
    self.receive_buffer[index].sn == segment.sn {
    false
  } else {
    let inserted : Array[KcpSegment] = []
    let mut cursor = 0
    while cursor < index {
      inserted.push(self.receive_buffer[cursor])
      cursor += 1
    }
    inserted.push(segment)
    while cursor < self.receive_buffer.length() {
      inserted.push(self.receive_buffer[cursor])
      cursor += 1
    }
    self.receive_buffer = inserted
    self.receive_buffer_bytes += segment.data.length()
    true
  }
}

///|
fn KcpControl::kcp_control_move_contiguous_receive(self : Self) -> Unit {
  let mut consumed = 0
  while consumed < self.receive_buffer.length() &&
        self.receive_buffer[consumed].sn == self.rcv_nxt &&
        self.receive_queue_segments < self.config.receive_window {
    let segment = self.receive_buffer[consumed]
    self.receive_buffer_bytes -= segment.data.length()
    self.receive_queue_bytes += segment.data.length()
    self.receive_queue_segments += 1
    self.receive_queue.push(segment)
    self.rcv_nxt = kcp_seq_add(self.rcv_nxt, 1L)
    consumed += 1
  }
  if consumed > 0 {
    let remaining : Array[KcpSegment] = []
    while consumed < self.receive_buffer.length() {
      remaining.push(self.receive_buffer[consumed])
      consumed += 1
    }
    self.receive_buffer = remaining
  }
}

///|
fn KcpControl::kcp_control_reassemble(
  self : Self,
) -> Result[Unit, KcpStateError] {
  let mut consumed = 0
  let mut done = false
  let mut result : Result[Unit, KcpStateError] = Ok(())
  while consumed < self.receive_queue.length() && !done {
    let first = self.receive_queue[consumed]
    let required = first.frg + 1
    if self.receive_queue.length() - consumed < required {
      done = true
    } else {
      let mut valid_chain = true
      let mut index = 0
      while index < required {
        if self.receive_queue[consumed + index].frg != first.frg - index {
          valid_chain = false
        }
        index += 1
      }
      if !valid_chain {
        result = Err(InvalidFragmentChain)
        done = true
      } else {
        let mut size = 0
        index = 0
        while index < required {
          size += self.receive_queue[consumed + index].data.length()
          index += 1
        }
        if size > self.config.max_message_size {
          result = Err(MessageTooLarge(size))
          done = true
        } else if size > self.config.max_queued_bytes {
          result = Err(
            QueueLimitExceeded(
              self.receive_queue_bytes,
              self.config.max_queued_bytes,
            ),
          )
          done = true
        } else {
          let message : Array[Int] = []
          index = 0
          while index < required {
            for byte in self.receive_queue[consumed + index].data {
              message.push(byte)
            }
            index += 1
          }
          self.receive_messages.push({ data: message, segments: required, })
          consumed += required
        }
      }
    }
  }
  if consumed > 0 {
    let remaining : Array[KcpSegment] = []
    while consumed < self.receive_queue.length() {
      remaining.push(self.receive_queue[consumed])
      consumed += 1
    }
    self.receive_queue = remaining
  }
  result
}

///|
/// Validate and consume one peer datagram. Framing, conversation, and command
/// validation complete before state changes; sequence-dependent PUSH handling
/// then follows wire order, including errors raised for eligible segments.
pub fn KcpControl::input(
  self : Self,
  bytes : Array[Int],
) -> Result[KcpInputReport, KcpStateError] {
  if bytes.length() == 0 || bytes.length() > self.config.mtu {
    self.malformed_datagrams += 1
    return Err(MalformedDatagram(PayloadTooLarge(bytes.length())))
  }
  let segments = match kcp_decode_datagram(bytes) {
    Ok(decoded) => decoded
    Err(error) => {
      self.malformed_datagrams += 1
      return Err(MalformedDatagram(error))
    }
  }
  if segments.length() == 0 ||
    segments.length() > self.config.max_segments_per_datagram {
    self.malformed_datagrams += 1
    return Err(MalformedDatagram(PayloadTooLarge(bytes.length())))
  }
  for segment in segments {
    if segment.conv != self.conv {
      self.malformed_datagrams += 1
      return Err(ConversationMismatch(self.conv, segment.conv))
    }
    if !kcp_command_is_supported(segment.cmd) {
      self.malformed_datagrams += 1
      return Err(UnsupportedCommand(segment.cmd))
    }
  }

  let mut has_max_ack = false
  let mut max_ack = 0L
  let mut max_ack_ts = 0L
  for segment in segments {
    if segment.cmd == Ack {
      if !has_max_ack {
        has_max_ack = true
        max_ack = segment.sn
        max_ack_ts = segment.ts
      } else if kcp_seq_less(max_ack, segment.sn) &&
        kcp_time_diff(segment.ts, max_ack_ts) > 0L {
        max_ack = segment.sn
        max_ack_ts = segment.ts
      }
    }
  }

  self.received_datagrams += 1
  self.received_segments += segments.length()
  let mut ack_count = 0
  let mut pushed_count = 0
  let mut accepted_bytes = 0
  let mut ignored_out_of_window = 0
  let previous_una = self.snd_una
  for segment in segments {
    self.remote_window = segment.wnd
    if segment.cmd == Ack &&
      kcp_sequence_in_range(segment.sn, self.snd_una, self.snd_nxt) {
      let sample = kcp_time_diff(self.current, segment.ts)
      if sample > 0L && sample <= self.config.maximum_rto_ms.to_int64() {
        self.kcp_control_update_rtt(sample.to_int())
      }
    }
    self.kcp_control_parse_una(segment.una)
    match segment.cmd {
      Ack => {
        ack_count += 1
        let covered_by_una = kcp_seq_less(segment.sn, self.snd_una)
        let in_flight = kcp_sequence_in_range(
          segment.sn,
          self.snd_una,
          self.snd_nxt,
        )
        if in_flight {
          if !self.kcp_control_remove_ack(segment.sn) {
            self.duplicate_acks += 1
          }
        } else if covered_by_una {
          ()
        } else if kcp_seq_less(segment.sn, self.snd_nxt) {
          self.duplicate_acks += 1
        }
      }
      Push => {
        pushed_count += 1
        let upper = kcp_seq_add(
          self.rcv_nxt,
          self.config.receive_window.to_int64(),
        )
        if !kcp_seq_less(segment.sn, upper) {
          ignored_out_of_window += 1
          self.out_of_window_segments += 1
        } else if segment.sn < 0L || segment.sn > kcp_u32_max {
          ignored_out_of_window += 1
          self.out_of_window_segments += 1
        } else if kcp_seq_less(segment.sn, self.rcv_nxt) {
          self.kcp_control_push_pending_ack(segment.sn, segment.ts)
        } else if self.kcp_control_receive_has_sequence(segment.sn) {
          self.kcp_control_push_pending_ack(segment.sn, segment.ts)
        } else if self.receive_queue_segments + self.receive_buffer.length() >=
          self.config.receive_window {
          ignored_out_of_window += 1
          self.out_of_window_segments += 1
        } else if segment.frg + 1 > self.config.receive_window {
          self.malformed_datagrams += 1
          return Err(ReceiveWindowOverflow)
        } else if segment.data.length() >
          self.config.max_queued_bytes -
          self.receive_queue_bytes -
          self.receive_buffer_bytes {
          return Err(
            QueueLimitExceeded(
              self.receive_queue_bytes + self.receive_buffer_bytes,
              self.config.max_queued_bytes,
            ),
          )
        } else {
          self.kcp_control_push_pending_ack(segment.sn, segment.ts)
          if self.kcp_control_insert_receive_segment(segment) {
            accepted_bytes += segment.data.length()
            self.received_payload_bytes += segment.data.length()
            self.kcp_control_move_contiguous_receive()
            match self.kcp_control_reassemble() {
              Ok(_) => ()
              Err(InvalidFragmentChain) => {
                self.malformed_datagrams += 1
                return Err(InvalidFragmentChain)
              }
              Err(error) => return Err(error)
            }
          }
        }
      }
      WindowAsk => self.probe_flags = self.probe_flags | 2
      WindowTell => ()
    }
  }
  if has_max_ack && kcp_sequence_in_range(max_ack, self.snd_una, self.snd_nxt) {
    for entry in self.send_buffer {
      if kcp_seq_less(entry.segment.sn, max_ack) &&
        kcp_time_diff(max_ack_ts, entry.segment.ts) >= 0L &&
        entry.fast_ack < self.config.fast_resend {
        entry.fast_ack += 1
      }
    }
  }
  self.kcp_control_update_snd_una()
  self.kcp_control_adjust_congestion(previous_una)
  Ok({
    segment_count: segments.length(),
    acknowledgements: ack_count,
    pushed_segments: pushed_count,
    accepted_payload_bytes: accepted_bytes,
    ignored_out_of_window,
  })
}

///|
fn kcp_command_is_supported(command : KcpCommand) -> Bool {
  match command {
    Push => true
    Ack => true
    WindowAsk => true
    WindowTell => true
  }
}

///|
fn KcpControl::kcp_control_has_due_retransmission(self : Self) -> Bool {
  for entry in self.send_buffer {
    if entry.transmissions == 0 ||
      kcp_time_diff(self.current, entry.resend_at) >= 0L ||
      (
        self.config.fast_resend > 0 &&
        entry.fast_ack >= self.config.fast_resend &&
        entry.transmissions <= 5
      ) {
      return true
    }
  }
  false
}

///|
/// Flush queued acknowledgements, probes, first sends, and due retransmissions.
/// The returned arrays are complete UDP datagrams; no network I/O is performed.
pub fn KcpControl::flush(
  self : Self,
) -> Result[Array[Array[Int]], KcpStateError] {
  if !self.clock_started {
    return Ok([])
  }
  let builder = new_kcp_datagram_builder(
    self.config.mtu,
    self.config.max_segments_per_datagram,
  )
  let mut output_segments = 0
  let mut output_payload_bytes = 0

  if self.remote_window == 0 {
    if self.probe_interval == 0 {
      self.probe_interval = 7000
      self.probe_deadline = kcp_time_add(self.current, self.probe_interval)
    } else if kcp_time_diff(self.current, self.probe_deadline) >= 0L {
      self.probe_interval = kcp_int_min(
        120000,
        self.probe_interval + self.probe_interval / 2,
      )
      self.probe_deadline = kcp_time_add(self.current, self.probe_interval)
      self.probe_flags = self.probe_flags | 1
    }
  } else if self.remote_window > 0 {
    self.probe_interval = 0
    self.probe_deadline = 0L
    if (self.probe_flags & 1) != 0 {
      self.probe_flags -= 1
    }
  }

  for pending in self.pending_acks {
    let ack : KcpSegment = {
      conv: self.conv,
      cmd: Ack,
      frg: 0,
      wnd: self.kcp_control_receive_window(),
      ts: pending.ts,
      sn: pending.sn,
      una: self.rcv_nxt,
      data: [],
    }
    match builder.append(ack) {
      Ok(_) => output_segments += 1
      Err(error) => return Err(error)
    }
  }
  self.pending_acks = []

  if (self.probe_flags & 1) != 0 {
    let ask : KcpSegment = {
      conv: self.conv,
      cmd: WindowAsk,
      frg: 0,
      wnd: self.kcp_control_receive_window(),
      ts: 0L,
      sn: 0L,
      una: self.rcv_nxt,
      data: [],
    }
    match builder.append(ask) {
      Ok(_) => output_segments += 1
      Err(error) => return Err(error)
    }
    self.probe_flags -= 1
  }
  if (self.probe_flags & 2) != 0 {
    let tell : KcpSegment = {
      conv: self.conv,
      cmd: WindowTell,
      frg: 0,
      wnd: self.kcp_control_receive_window(),
      ts: 0L,
      sn: 0L,
      una: self.rcv_nxt,
      data: [],
    }
    match builder.append(tell) {
      Ok(_) => output_segments += 1
      Err(error) => return Err(error)
    }
    self.probe_flags -= 2
  }

  let mut send_limit = kcp_int_min(self.config.send_window, self.remote_window)
  if !self.config.no_congestion_control {
    send_limit = kcp_int_min(send_limit, self.congestion_window)
  }
  let mut queued_cursor = 0
  while queued_cursor < self.send_queue.length() &&
        kcp_sequence_distance(self.snd_una, self.snd_nxt) <
        send_limit.to_int64() {
    let queued = self.send_queue[queued_cursor]
    let segment : KcpSegment = {
      conv: queued.conv,
      cmd: queued.cmd,
      frg: queued.frg,
      wnd: self.kcp_control_receive_window(),
      ts: self.current,
      sn: self.snd_nxt,
      una: self.rcv_nxt,
      data: queued.data,
    }
    self.snd_nxt = kcp_seq_add(self.snd_nxt, 1L)
    let length = segment.data.length()
    self.send_queue_bytes -= length
    self.send_buffer_bytes += length
    self.send_buffer.push({
      segment,
      resend_at: self.current,
      resend_timeout: self.retransmission_timeout,
      fast_ack: 0,
      transmissions: 0,
    })
    queued_cursor += 1
  }
  if queued_cursor > 0 {
    let remaining : Array[KcpSegment] = []
    while queued_cursor < self.send_queue.length() {
      remaining.push(self.send_queue[queued_cursor])
      queued_cursor += 1
    }
    self.send_queue = remaining
  }
  self.kcp_control_update_snd_una()

  let mut index = 0
  let mut saw_timeout = false
  let mut saw_fast_retransmit = false
  while index < self.send_buffer.length() {
    let entry = self.send_buffer[index]
    let new_send = entry.transmissions == 0
    let timeout_due = !new_send &&
      kcp_time_diff(self.current, entry.resend_at) >= 0L
    let fast_due = !new_send &&
      !timeout_due &&
      self.config.fast_resend > 0 &&
      entry.fast_ack >= self.config.fast_resend &&
      entry.transmissions <= 5
    if new_send || timeout_due || fast_due {
      let mut timeout = entry.resend_timeout
      if timeout_due {
        timeout = kcp_int_min(
          self.config.maximum_rto_ms,
          timeout + kcp_int_max(timeout, self.retransmission_timeout),
        )
        saw_timeout = true
        self.retransmissions += 1
        self.timeout_retransmissions += 1
      } else if fast_due {
        saw_fast_retransmit = true
        self.retransmissions += 1
        self.fast_retransmissions += 1
      }
      let transmissions = entry.transmissions + 1
      let delay = if new_send { timeout + timeout / 8 } else { timeout }
      let segment : KcpSegment = {
        conv: entry.segment.conv,
        cmd: entry.segment.cmd,
        frg: entry.segment.frg,
        wnd: self.kcp_control_receive_window(),
        ts: self.current,
        sn: entry.segment.sn,
        una: self.rcv_nxt,
        data: entry.segment.data,
      }
      match builder.append(segment) {
        Ok(_) => {
          output_segments += 1
          output_payload_bytes += segment.data.length()
        }
        Err(error) => return Err(error)
      }
      self.send_buffer[index] = {
        segment,
        resend_at: kcp_time_add(self.current, delay),
        resend_timeout: timeout,
        fast_ack: if new_send {
          entry.fast_ack
        } else {
          0
        },
        transmissions,
      }
    }
    index += 1
  }

  if saw_timeout && !self.config.no_congestion_control {
    self.slow_start_threshold = kcp_int_max(self.congestion_window / 2, 2)
    self.congestion_window = 1
    self.congestion_increment = kcp_config_mss(self.config).to_int64()
  } else if saw_fast_retransmit && !self.config.no_congestion_control {
    let in_flight = kcp_sequence_distance(self.snd_una, self.snd_nxt).to_int()
    self.slow_start_threshold = kcp_int_max(in_flight / 2, 2)
    self.congestion_window = self.slow_start_threshold + self.config.fast_resend
    self.congestion_increment = self.congestion_window.to_int64() *
      kcp_config_mss(self.config).to_int64()
  }

  let datagrams = builder.finish()
  self.sent_datagrams += datagrams.length()
  self.sent_segments += output_segments
  self.sent_payload_bytes += output_payload_bytes
  Ok(datagrams)
}

///|
/// Advance the 32-bit KCP clock and perform a due flush.
/// `current` is an unsigned millisecond tick; forward wraparound is supported.
pub fn KcpControl::update(
  self : Self,
  current : Int64,
) -> Result[Array[Array[Int]], KcpStateError] {
  if current < 0L || current > kcp_u32_max {
    return Err(InvalidClock(current))
  }
  if self.clock_started && kcp_time_diff(current, self.current) < 0L {
    return Err(InvalidClock(current))
  }
  self.current = current
  self.clock_started = true
  if !self.updated {
    self.updated = true
    self.next_flush = current
  }
  let flush_delta = kcp_time_diff(current, self.next_flush)
  let retransmission_due = self.kcp_control_has_due_retransmission()
  let probe_due = self.probe_interval > 0 &&
    kcp_time_diff(current, self.probe_deadline) >= 0L
  let clock_slip = flush_delta >= 10000L || flush_delta <= -10000L
  if flush_delta >= 0L || clock_slip || retransmission_due || probe_due {
    self.next_flush = kcp_time_add(current, self.config.interval_ms)
    self.flush()
  } else {
    Ok([])
  }
}

///|
/// Return the next 32-bit tick at which `update` should be called.
pub fn KcpControl::check(
  self : Self,
  current : Int64,
) -> Result[Int64, KcpStateError] {
  if current < 0L || current > kcp_u32_max {
    return Err(InvalidClock(current))
  }
  if self.clock_started && kcp_time_diff(current, self.current) < 0L {
    return Err(InvalidClock(current))
  }
  if !self.updated {
    return Ok(current)
  }
  let mut wait = kcp_time_diff(self.next_flush, current)
  if wait <= 0L {
    return Ok(current)
  }
  for entry in self.send_buffer {
    let until_resend = kcp_time_diff(entry.resend_at, current)
    if until_resend <= 0L {
      return Ok(current)
    }
    if until_resend < wait {
      wait = until_resend
    }
  }
  if self.probe_interval > 0 {
    let until_probe = kcp_time_diff(self.probe_deadline, current)
    if until_probe <= 0L {
      return Ok(current)
    }
    if until_probe < wait {
      wait = until_probe
    }
  }
  Ok(kcp_time_add(current, wait.to_int()))
}

///|
/// Return the size of the oldest complete message without consuming it.
///
/// This lets callers check receive capacity or prepare a destination buffer
/// before calling `recv`. The value is `None` while the next ordered message
/// is incomplete or the receive queue is empty.
pub fn KcpControl::peek_message_size(self : Self) -> Int? {
  if self.receive_messages.length() == 0 {
    None
  } else {
    Some(self.receive_messages[0].data.length())
  }
}

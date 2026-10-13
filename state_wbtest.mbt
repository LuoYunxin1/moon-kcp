///|
fn state_test_control(conv : Int64, config : KcpConfig) -> KcpControl {
  new_kcp_control(conv, config).unwrap()
}

///|
fn state_test_encode(segment : KcpSegment) -> Array[Int] {
  kcp_encode_segment(segment).unwrap()
}

///|
fn state_test_datagram(segments : Array[KcpSegment]) -> Array[Int] {
  let bytes : Array[Int] = []
  for segment in segments {
    for byte in state_test_encode(segment) {
      bytes.push(byte)
    }
  }
  bytes
}

///|
fn state_test_segment(
  conv : Int64,
  cmd : KcpCommand,
  sn : Int64,
  una : Int64,
  wnd : Int,
  ts : Int64,
  frg : Int,
  data : Array[Int],
) -> KcpSegment {
  { conv, cmd, sn, una, wnd, ts, frg, data, }
}

///|
fn state_test_take_datagrams(
  result : Result[Array[Array[Int]], KcpStateError],
) -> Array[Array[Int]] {
  result.unwrap()
}

///|
fn state_test_input(control : KcpControl, bytes : Array[Int]) -> KcpInputReport {
  control.input(bytes).unwrap()
}

///|
test "input orders and reassembles fragments while rejecting duplicates" {
  let control = state_test_control(42L, kcp_default_config())
  let later = state_test_datagram([
    state_test_segment(42L, Push, 1L, 0L, 128, 10L, 0, [2]),
  ])
  let first_report = state_test_input(control, later)
  assert_eq(first_report.accepted_payload_bytes, 1)
  assert_eq(control.next_receive_sequence(), 0L)
  assert_true(control.recv() is None)

  let first = state_test_datagram([
    state_test_segment(42L, Push, 0L, 0L, 128, 11L, 1, [1]),
  ])
  let second_report = state_test_input(control, first)
  assert_eq(second_report.accepted_payload_bytes, 1)
  assert_eq(control.next_receive_sequence(), 2L)
  assert_eq(control.recv(), Some([1, 2]))

  let duplicate_report = state_test_input(control, later)
  assert_eq(duplicate_report.accepted_payload_bytes, 0)
  assert_eq(control.stats().received_payload_bytes, 2)
  assert_eq(control.stats().out_of_window_segments, 0)
}

///|
test "ACK and UNA release flight state and sample RTT across a wrap-safe clock" {
  let config = kcp_default_config()
  config.set_no_congestion_control(true)
  config.set_interval(10)
  let sender = state_test_control(7L, config)
  ignore(sender.send([1]))
  ignore(sender.send([2]))
  let outgoing = state_test_take_datagrams(sender.update(100L))
  assert_eq(outgoing.length(), 1)
  assert_eq(sender.waitsnd_segments(), 2)
  ignore(state_test_take_datagrams(sender.update(120L)))

  let ack = state_test_datagram([
    state_test_segment(7L, Ack, 0L, 2L, 128, 100L, 0, []),
  ])
  let report = state_test_input(sender, ack)
  assert_eq(report.acknowledgements, 1)
  assert_eq(sender.next_send_sequence(), 2L)
  assert_eq(sender.snd_una, 2L)
  assert_eq(sender.waitsnd_segments(), 0)
  assert_eq(sender.smoothed_rtt, 20)
  assert_eq(sender.stats().duplicate_acks, 0)
}

///|
test "selective ACK holes hold the send window until UNA advances" {
  let config = kcp_default_config()
  config.set_windows(4, 4)
  config.set_resource_limits(4 * 1376, 4 * 1024 * 1024, 32)
  config.set_interval(10)
  config.set_no_congestion_control(true)
  let sender = state_test_control(70L, config)
  ignore(sender.send([0]))
  ignore(sender.send([1]))
  ignore(sender.send([2]))
  ignore(sender.send([3]))
  ignore(sender.send([4]))

  let initial = state_test_take_datagrams(sender.update(100L))
  assert_eq(initial.length(), 1)
  assert_eq(sender.snd_una, 0L)
  assert_eq(sender.next_send_sequence(), 4L)
  assert_eq(sender.waitsnd_segments(), 5)

  let selective_acks = state_test_datagram([
    state_test_segment(70L, Ack, 1L, 0L, 4, 100L, 0, []),
    state_test_segment(70L, Ack, 2L, 0L, 4, 100L, 0, []),
    state_test_segment(70L, Ack, 3L, 0L, 4, 100L, 0, []),
  ])
  let report = state_test_input(sender, selective_acks)
  assert_eq(report.acknowledgements, 3)
  assert_eq(sender.snd_una, 0L)
  assert_eq(sender.waitsnd_segments(), 2)

  assert_eq(state_test_take_datagrams(sender.update(110L)).length(), 0)
  assert_eq(sender.next_send_sequence(), 4L)
  assert_eq(sender.send_queue.length(), 1)

  let first_ack = state_test_datagram([
    state_test_segment(70L, Ack, 0L, 0L, 4, 100L, 0, []),
  ])
  ignore(state_test_input(sender, first_ack))
  assert_eq(sender.snd_una, 4L)
  let resumed = state_test_take_datagrams(sender.update(120L))
  assert_eq(resumed.length(), 1)
  let resumed_segments = match kcp_decode_datagram(resumed[0]) {
    Ok(segments) => segments
    Err(_) => fail("resumed output must decode")
  }
  assert_eq(resumed_segments[0].sn, 4L)
  assert_eq(sender.next_send_sequence(), 5L)
  assert_eq(sender.send_queue.length(), 0)
}

///|
test "selective ACK send window preserves its hole across u32 wrap" {
  let config = kcp_default_config()
  config.set_windows(4, 4)
  config.set_resource_limits(4 * 1376, 4 * 1024 * 1024, 32)
  config.set_interval(10)
  config.set_no_congestion_control(true)
  let sender = state_test_control(71L, config)
  sender.snd_una = 0xFFFFFFFEL
  sender.snd_nxt = 0xFFFFFFFEL
  ignore(sender.send([0]))
  ignore(sender.send([1]))
  ignore(sender.send([2]))
  ignore(sender.send([3]))
  ignore(sender.send([4]))

  let initial = state_test_take_datagrams(sender.update(100L))
  assert_eq(initial.length(), 1)
  assert_eq(sender.snd_una, 0xFFFFFFFEL)
  assert_eq(sender.next_send_sequence(), 2L)

  let selective_acks = state_test_datagram([
    state_test_segment(71L, Ack, 0xFFFFFFFFL, 0xFFFFFFFEL, 4, 100L, 0, []),
    state_test_segment(71L, Ack, 0L, 0xFFFFFFFEL, 4, 100L, 0, []),
    state_test_segment(71L, Ack, 1L, 0xFFFFFFFEL, 4, 100L, 0, []),
  ])
  let report = state_test_input(sender, selective_acks)
  assert_eq(report.acknowledgements, 3)
  assert_eq(sender.snd_una, 0xFFFFFFFEL)

  assert_eq(state_test_take_datagrams(sender.update(110L)).length(), 0)
  assert_eq(sender.next_send_sequence(), 2L)
  assert_eq(sender.send_queue.length(), 1)

  let first_ack = state_test_datagram([
    state_test_segment(71L, Ack, 0xFFFFFFFEL, 0xFFFFFFFEL, 4, 100L, 0, []),
  ])
  ignore(state_test_input(sender, first_ack))
  assert_eq(sender.snd_una, 2L)
  let resumed = state_test_take_datagrams(sender.update(120L))
  assert_eq(resumed.length(), 1)
  let resumed_segments = match kcp_decode_datagram(resumed[0]) {
    Ok(segments) => segments
    Err(_) => fail("resumed output must decode")
  }
  assert_eq(resumed_segments[0].sn, 2L)
  assert_eq(sender.next_send_sequence(), 3L)
  assert_eq(sender.send_queue.length(), 0)
}

///|
test "timeout retransmission backs off and check points at the deadline" {
  let config = kcp_default_config()
  config.set_interval(100)
  config.set_rto_limits(10, 20, 80)
  config.set_no_congestion_control(true)
  let sender = state_test_control(8L, config)
  ignore(sender.send([9]))
  let initial = state_test_take_datagrams(sender.update(100L))
  assert_eq(initial.length(), 1)
  assert_eq(sender.send_buffer[0].resend_at, 122L)
  assert_eq(sender.check(121L), Ok(122L))
  assert_eq(state_test_take_datagrams(sender.update(121L)).length(), 0)
  let retransmission = state_test_take_datagrams(sender.update(122L))
  assert_eq(retransmission.length(), 1)
  assert_eq(sender.stats().retransmissions, 1)
  assert_eq(sender.stats().timeout_retransmissions, 1)
  assert_eq(sender.send_buffer[0].resend_timeout, 40)
  assert_eq(sender.send_buffer[0].resend_at, 162L)
}

///|
test "later ACKs trigger fast retransmit for missing earlier segments" {
  let config = kcp_default_config()
  config.set_interval(10)
  config.set_windows(8, 128)
  config.set_fast_resend(1)
  config.set_no_congestion_control(true)
  let sender = state_test_control(9L, config)
  ignore(sender.send([1]))
  ignore(sender.send([2]))
  ignore(sender.send([3]))
  let initial = state_test_take_datagrams(sender.update(100L))
  assert_eq(initial.length(), 1)
  assert_eq(sender.waitsnd_segments(), 3)
  let later_ack = state_test_datagram([
    state_test_segment(9L, Ack, 2L, 0L, 128, 100L, 0, []),
  ])
  ignore(state_test_input(sender, later_ack))
  assert_eq(sender.send_buffer[0].fast_ack, 1)
  let retransmissions = state_test_take_datagrams(sender.update(110L))
  assert_eq(retransmissions.length(), 1)
  assert_eq(sender.stats().fast_retransmissions, 2)
  assert_eq(sender.stats().timeout_retransmissions, 0)
}

///|
test "window probe and window-tell commands are caller driven" {
  let config = kcp_default_config()
  config.set_interval(10)
  config.set_no_congestion_control(true)
  let sender = state_test_control(10L, config)
  let closed = state_test_datagram([
    state_test_segment(10L, WindowTell, 0L, 0L, 0, 0L, 0, []),
  ])
  ignore(state_test_input(sender, closed))
  ignore(sender.send([5]))
  assert_eq(state_test_take_datagrams(sender.update(100L)).length(), 0)
  let probe = state_test_take_datagrams(sender.update(7100L))
  assert_eq(probe.length(), 1)
  let decoded_probe = match kcp_decode_datagram(probe[0]) {
    Ok(segments) => segments
    Err(_) => fail("probe output must be a valid KCP datagram")
  }
  assert_eq(decoded_probe[0].cmd, WindowAsk)

  let receiver = state_test_control(10L, kcp_default_config())
  let ask = state_test_datagram([
    state_test_segment(10L, WindowAsk, 0L, 0L, 1, 0L, 0, []),
  ])
  ignore(state_test_input(receiver, ask))
  let tell = state_test_take_datagrams(receiver.update(0L))
  assert_eq(tell.length(), 1)
  let decoded_tell = match kcp_decode_datagram(tell[0]) {
    Ok(segments) => segments
    Err(_) => fail("window tell must be a valid KCP datagram")
  }
  assert_eq(decoded_tell[0].cmd, WindowTell)
  assert_eq(decoded_tell[0].wnd, 128)
}

///|
test "sequence and timer serial arithmetic survives the u32 boundary" {
  let config = kcp_default_config()
  config.set_interval(10)
  config.set_rto_limits(10, 20, 80)
  config.set_no_congestion_control(true)
  let control = state_test_control(11L, config)
  ignore(control.send([1]))
  let first = state_test_take_datagrams(control.update(0xFFFFFFF0L))
  let first_segment = match kcp_decode_datagram(first[0]) {
    Ok(segments) => segments[0]
    Err(_) => fail("initial packet must decode")
  }
  assert_eq(first_segment.ts, 0xFFFFFFF0L)
  assert_eq(control.check(0xFFFFFFF0L), Ok(0xFFFFFFFAL))
  assert_eq(state_test_take_datagrams(control.update(0xFFFFFFFAL)).length(), 0)
  assert_eq(control.check(0xFFFFFFFAL), Ok(4L))
  assert_eq(state_test_take_datagrams(control.update(4L)).length(), 0)
  assert_eq(control.check(4L), Ok(6L))
  let retransmission = state_test_take_datagrams(control.update(6L))
  assert_eq(retransmission.length(), 1)
  assert_eq(control.stats().timeout_retransmissions, 1)
  assert_true(control.update(5L) is Err(InvalidClock(5L)))
}

///|
test "input rejects malformed and foreign datagrams before state mutation" {
  let control = state_test_control(12L, kcp_default_config())
  assert_true(
    control.input([1, 2]) is Err(MalformedDatagram(TruncatedHeader(0, 2))),
  )
  let foreign = state_test_datagram([
    state_test_segment(13L, Push, 0L, 0L, 128, 0L, 0, [8]),
  ])
  assert_true(control.input(foreign) is Err(ConversationMismatch(12L, 13L)))
  assert_eq(control.next_receive_sequence(), 0L)
  assert_eq(control.pending_messages(), 0)
  assert_eq(control.stats().malformed_datagrams, 2)
}

///|
test "receive window and queued zero-byte segments have finite bounds" {
  let receive_config = kcp_default_config()
  receive_config.set_windows(32, 1)
  receive_config.set_resource_limits(1376, 4 * 1024 * 1024, 32)
  let receiver = state_test_control(14L, receive_config)
  let impossible_chain = state_test_datagram([
    state_test_segment(14L, Push, 0L, 0L, 1, 0L, 1, [1]),
  ])
  assert_true(receiver.input(impossible_chain) is Err(ReceiveWindowOverflow))
  assert_eq(receiver.next_receive_sequence(), 0L)
  assert_eq(receiver.pending_messages(), 0)
  assert_eq(receiver.stats().received_datagrams, 1)
  assert_eq(receiver.stats().received_segments, 1)
  assert_eq(receiver.stats().malformed_datagrams, 1)

  let send_config = kcp_default_config()
  send_config.set_resource_limits(0, 1400, 16)
  let sender = state_test_control(15L, send_config)
  assert_eq(sender.send([]), Ok(1))
  assert_true(sender.send([]) is Err(QueueSegmentLimitExceeded(1, 1)))
}

///|
test "eligible oversized PUSH follows wire order and later input recovers" {
  let config = kcp_default_config()
  config.set_windows(4, 4)
  config.set_resource_limits(4 * 1376, 4 * 1024 * 1024, 32)
  let control = state_test_control(31L, config)
  ignore(control.send([9]))
  ignore(state_test_take_datagrams(control.update(100L)))

  let mixed = state_test_datagram([
    state_test_segment(31L, Push, 0L, 0L, 4, 10L, 0, [1]),
    state_test_segment(31L, Ack, 0L, 0L, 4, 100L, 0, []),
    state_test_segment(31L, Push, 1L, 0L, 4, 11L, 4, [2]),
  ])
  assert_true(control.input(mixed) is Err(ReceiveWindowOverflow))

  // This is a per-segment error, not a transaction rollback: earlier PUSH and
  // ACK effects remain. The malformed counter records the rejected datagram.
  assert_eq(control.next_receive_sequence(), 1L)
  assert_eq(control.pending_messages(), 1)
  assert_eq(control.waitsnd_segments(), 0)
  assert_eq(control.pending_acks.length(), 1)
  assert_eq(control.stats().received_datagrams, 1)
  assert_eq(control.stats().received_segments, 3)
  assert_eq(control.stats().received_payload_bytes, 1)
  assert_eq(control.stats().malformed_datagrams, 1)
  assert_eq(control.snd_una, 1L)

  let recovery = state_test_datagram([
    state_test_segment(31L, Push, 1L, 0L, 4, 12L, 0, [2]),
  ])
  let report = state_test_input(control, recovery)
  assert_eq(report.accepted_payload_bytes, 1)
  assert_eq(control.next_receive_sequence(), 2L)
  assert_eq(control.pending_messages(), 2)
  assert_eq(control.snd_una, 1L)
  assert_eq(control.recv(), Some([1]))
  assert_eq(control.recv(), Some([2]))
  assert_eq(control.stats().received_datagrams, 2)
}

///|
test "oversized out-of-window PUSH keeps window handling priority" {
  let config = kcp_default_config()
  config.set_windows(2, 2)
  config.set_resource_limits(2 * 1376, 4 * 1024 * 1024, 32)
  let control = state_test_control(32L, config)
  ignore(control.send([9]))
  ignore(state_test_take_datagrams(control.update(100L)))

  // After PUSH sn=0 advances rcv_nxt, sn=3 is still outside [1, 3).
  let mixed = state_test_datagram([
    state_test_segment(32L, Push, 0L, 0L, 2, 10L, 0, [1]),
    state_test_segment(32L, Ack, 0L, 0L, 2, 100L, 0, []),
    state_test_segment(32L, Push, 3L, 0L, 2, 11L, 255, [2]),
  ])
  let report = state_test_input(control, mixed)
  assert_eq(report.ignored_out_of_window, 1)
  assert_eq(control.next_receive_sequence(), 1L)
  assert_eq(control.pending_messages(), 1)
  assert_eq(control.waitsnd_segments(), 0)
  assert_eq(control.pending_acks.length(), 1)
  assert_eq(control.stats().out_of_window_segments, 1)
  assert_eq(control.stats().malformed_datagrams, 0)
}

///|
test "oversized duplicate PUSH is acknowledged before fragment validation" {
  let config = kcp_default_config()
  config.set_windows(4, 4)
  config.set_resource_limits(4 * 1376, 4 * 1024 * 1024, 32)
  let control = state_test_control(33L, config)
  let duplicate = state_test_datagram([
    state_test_segment(33L, Push, 0L, 0L, 4, 10L, 0, [1]),
    state_test_segment(33L, Push, 0L, 0L, 4, 11L, 255, [9]),
  ])
  let report = state_test_input(control, duplicate)
  assert_eq(report.accepted_payload_bytes, 1)
  assert_eq(control.next_receive_sequence(), 1L)
  assert_eq(control.pending_messages(), 1)
  assert_eq(control.pending_acks.length(), 2)
  assert_eq(control.stats().received_payload_bytes, 1)
  assert_eq(control.stats().out_of_window_segments, 0)
  assert_eq(control.stats().malformed_datagrams, 0)
  assert_eq(control.recv(), Some([1]))
}

///|
test "flush respects MTU and per-datagram segment caps" {
  let config = kcp_default_config()
  config.set_mtu(96)
  config.set_windows(8, 128)
  config.set_resource_limits(1024, 4096, 2)
  config.set_no_congestion_control(true)
  let sender = state_test_control(16L, config)
  ignore(sender.send(Array::make(90, 7)))
  let datagrams = state_test_take_datagrams(sender.update(100L))
  assert_eq(datagrams.length(), 2)
  for datagram in datagrams {
    assert_true(datagram.length() <= 96)
    let segments = match kcp_decode_datagram(datagram) {
      Ok(decoded) => decoded
      Err(_) => fail("output must decode as a KCP datagram")
    }
    assert_true(segments.length() <= 2)
  }
  assert_eq(sender.stats().sent_segments, 2)
  assert_eq(sender.stats().sent_payload_bytes, 90)
}

///|
test "reliable message round trip releases send and receive storage" {
  let sender = state_test_control(17L, kcp_default_config())
  let receiver = state_test_control(17L, kcp_default_config())
  ignore(sender.send([10, 20, 30]))
  let outgoing = state_test_take_datagrams(sender.update(1000L))
  assert_eq(outgoing.length(), 1)
  let report = state_test_input(receiver, outgoing[0])
  assert_eq(report.accepted_payload_bytes, 3)
  let acks = state_test_take_datagrams(receiver.update(1000L))
  assert_eq(acks.length(), 1)
  ignore(sender.update(1020L))
  let ack_report = state_test_input(sender, acks[0])
  assert_eq(ack_report.acknowledgements, 1)
  assert_eq(sender.waitsnd_segments(), 0)
  assert_eq(sender.smoothed_rtt, 20)
  assert_eq(receiver.recv(), Some([10, 20, 30]))
  assert_eq(receiver.stats().delivered_messages, 1)
}

///|
test "stream mode coalesces only the unsent tail and preserves byte order" {
  let config = kcp_default_config()
  config.set_mtu(48)
  config.set_resource_limits(4096, 8192, 32)
  config.set_stream_mode(true)
  config.set_no_congestion_control(true)
  let sender = state_test_control(18L, config)
  let receiver = state_test_control(18L, kcp_default_config())
  assert_eq(
    sender.send([
      1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
    ]),
    Ok(1),
  )
  assert_eq(sender.send([21, 22, 23, 24, 25, 26, 27, 28, 29, 30]), Ok(1))
  assert_eq(sender.send([31, 32]), Ok(0))
  assert_eq(sender.waitsnd_segments(), 2)
  assert_eq(sender.send_queue[0].data, [
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22,
    23, 24,
  ])
  assert_eq(sender.send_queue[1].data, [25, 26, 27, 28, 29, 30, 31, 32])
  assert_eq(sender.send_queue[0].frg, 0)
  assert_eq(sender.send_queue[1].frg, 0)

  let output = state_test_take_datagrams(sender.update(100L))
  assert_eq(output.length(), 2)
  let mut received_segments = 0
  for datagram in output {
    assert_true(datagram.length() <= 48)
    let decoded = match kcp_decode_datagram(datagram) {
      Ok(segments) => segments
      Err(_) => fail("stream output must decode")
    }
    assert_eq(decoded.length(), 1)
    assert_eq(decoded[0].frg, 0)
    ignore(state_test_input(receiver, datagram))
    received_segments += decoded.length()
  }
  assert_eq(received_segments, 2)
  // Reads follow transport segment boundaries, not the two application writes.
  assert_eq(
    receiver.recv(),
    Some([
      1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21,
      22, 23, 24,
    ]),
  )
  assert_eq(receiver.recv(), Some([25, 26, 27, 28, 29, 30, 31, 32]))
  assert_true(receiver.recv() is None)

  // An application write made after flush cannot coalesce into an in-flight tail.
  assert_eq(sender.send([33]), Ok(1))
  assert_eq(sender.send_queue.length(), 1)
  assert_eq(sender.send_queue[0].data, [33])
  assert_eq(sender.waitsnd_segments(), 3)
}

///|
test "fast acknowledgement uses the sequence and timestamp conservative pair" {
  let config = kcp_default_config()
  config.set_windows(8, 128)
  config.set_fast_resend(1)
  config.set_no_congestion_control(true)
  let sender = state_test_control(27L, config)
  ignore(sender.send([0]))
  ignore(sender.send([1]))
  ignore(sender.send([2]))
  ignore(sender.send([3]))
  ignore(state_test_take_datagrams(sender.update(100L)))

  let reordered_timestamps = state_test_datagram([
    state_test_segment(27L, Ack, 2L, 0L, 128, 110L, 0, []),
    state_test_segment(27L, Ack, 3L, 0L, 128, 90L, 0, []),
  ])
  ignore(state_test_input(sender, reordered_timestamps))
  assert_eq(sender.send_buffer[0].fast_ack, 1)
  assert_eq(sender.send_buffer[1].fast_ack, 1)
  assert_eq(sender.send_buffer.length(), 2)
}

///|
test "timeout congestion threshold derives from the congestion window" {
  let config = kcp_default_config()
  config.set_windows(32, 128)
  let sender = state_test_control(28L, config)
  sender.congestion_window = 10
  sender.slow_start_threshold = 8
  ignore(sender.send([1]))
  ignore(sender.send([2]))
  ignore(sender.send([3]))
  ignore(state_test_take_datagrams(sender.update(100L)))
  ignore(state_test_take_datagrams(sender.update(325L)))
  assert_eq(sender.slow_start_threshold, 5)
  assert_eq(sender.congestion_window, 1)
}

///|
test "stream queue caps segment metadata independently from payload bytes" {
  let config = kcp_default_config()
  config.set_mtu(25)
  config.set_windows(1, 1)
  config.set_stream_mode(true)
  config.set_resource_limits(65536, 64 * 1024 * 1024, 255)
  let sender = state_test_control(29L, config)
  assert_true(
    sender.send(Array::make(65536, 7))
    is Err(QueueSegmentLimitExceeded(0, 65535)),
  )
}

///|
test "congestion byte arithmetic remains wide for large MSS and windows" {
  let config = kcp_default_config()
  config.set_mtu(65507)
  config.set_windows(65535, 65535)
  let sender = state_test_control(30L, config)
  sender.remote_window = 65535
  sender.congestion_window = 40000
  sender.slow_start_threshold = 1
  sender.congestion_increment = 40000L * kcp_config_mss(config).to_int64()
  sender.snd_una = 1L
  sender.kcp_control_adjust_congestion(0L)
  assert_true(sender.congestion_increment > 0L)
  assert_eq(sender.congestion_window, 40000)
}

///|
test "constructor and caller-supplied clocks reject values outside serial range" {
  assert_true(
    new_kcp_control(-1L, kcp_default_config()) is Err(InvalidConversation(-1L)),
  )
  assert_true(
    new_kcp_control(0x100000000L, kcp_default_config())
    is Err(InvalidConversation(0x100000000L)),
  )
  let invalid = kcp_default_config()
  invalid.set_interval(9)
  assert_true(new_kcp_control(1L, invalid) is Err(InvalidConfiguration))

  let control = state_test_control(1L, kcp_default_config())
  assert_true(control.update(-1L) is Err(InvalidClock(-1L)))
  assert_true(control.update(0x100000000L) is Err(InvalidClock(0x100000000L)))
  assert_eq(control.update(100L), Ok([]))
  assert_true(control.update(99L) is Err(InvalidClock(99L)))
  assert_true(control.check(99L) is Err(InvalidClock(99L)))
}

///|
test "send rejects oversized or invalid payload without mutating queued state" {
  let config = kcp_default_config()
  config.set_resource_limits(4, 1400, 32)
  let control = state_test_control(2L, config)
  assert_true(control.send([1, 2, 3, 4, 5]) is Err(MessageTooLarge(5)))
  assert_true(control.send([1, 256]) is Err(InvalidPayloadByte(1, 256)))
  assert_eq(control.waitsnd_bytes(), 0)
  assert_eq(control.waitsnd_segments(), 0)

  assert_eq(control.send([1, 2, 3]), Ok(1))
  assert_true(control.send([4, 5]) is Err(QueueSegmentLimitExceeded(1, 1)))
  assert_eq(control.waitsnd_bytes(), 3)
  assert_eq(control.waitsnd_segments(), 1)
}

///|
test "reading a full receive window advertises reopened capacity" {
  let config = kcp_default_config()
  config.set_windows(1, 1)
  config.set_resource_limits(1376, 1400, 32)
  let receiver = state_test_control(3L, config)
  let incoming = state_test_datagram([
    state_test_segment(3L, Push, 0L, 0L, 1, 1L, 0, [41]),
  ])
  ignore(state_test_input(receiver, incoming))
  assert_eq(receiver.stats().out_of_window_segments, 0)
  assert_eq(receiver.kcp_control_receive_window(), 0)
  assert_eq(receiver.recv(), Some([41]))
  assert_eq(receiver.kcp_control_receive_window(), 1)

  let response = state_test_take_datagrams(receiver.update(0L))
  assert_eq(response.length(), 1)
  let decoded = match kcp_decode_datagram(response[0]) {
    Ok(segments) => segments
    Err(_) => fail("window update must be a valid KCP datagram")
  }
  assert_eq(decoded.length(), 2)
  assert_eq(decoded[1].cmd, WindowTell)
  assert_eq(decoded[1].wnd, 1)
}

///|
test "malformed input increments diagnostics without accepting a datagram" {
  let receiver = state_test_control(4L, kcp_default_config())
  assert_true(receiver.input([1, 2, 3]) is Err(_))
  assert_eq(receiver.stats().received_datagrams, 0)
  assert_eq(receiver.stats().malformed_datagrams, 1)
  assert_eq(receiver.stats().received_segments, 0)
  assert_eq(receiver.next_receive_sequence(), 0L)
}

///|
test "queued byte budget stays occupied in flight and releases after acknowledgment" {
  let config = kcp_default_config()
  config.set_resource_limits(1400, 1400, 8)
  let sender = state_test_control(34L, config)
  let large = Array::make(1376, 7)
  assert_eq(sender.send(large), Ok(1))
  assert_true(
    sender.send(Array::make(25, 8)) is Err(QueueLimitExceeded(1376, 1400)),
  )
  assert_eq(sender.waitsnd_bytes(), 1376)
  assert_eq(sender.waitsnd_segments(), 1)

  let initial = state_test_take_datagrams(sender.update(0L))
  assert_eq(initial.length(), 1)
  assert_eq(sender.send_queue_bytes, 0)
  assert_eq(sender.send_buffer_bytes, 1376)
  assert_true(
    sender.send(Array::make(25, 8)) is Err(QueueLimitExceeded(1376, 1400)),
  )

  let acknowledgement = state_test_datagram([
    state_test_segment(34L, Ack, 0L, 1L, 128, 0L, 0, []),
  ])
  ignore(state_test_input(sender, acknowledgement))
  assert_eq(sender.waitsnd_bytes(), 0)
  assert_eq(sender.waitsnd_segments(), 0)
  assert_eq(sender.send_buffer_bytes, 0)
  assert_true(sender.send([8]) is Ok(1))
  assert_eq(sender.waitsnd_bytes(), 1)
  assert_eq(sender.waitsnd_segments(), 1)
}

///|
test "sender pauses at a full receive window and resumes after window tell" {
  let config = kcp_default_config()
  config.set_windows(1, 1)
  config.set_resource_limits(1376, 4 * 1024 * 1024, 32)
  config.set_interval(10)
  config.set_no_congestion_control(true)
  let sender = state_test_control(35L, config)
  let receiver = state_test_control(35L, config)

  assert_true(sender.send([1]) is Ok(1))
  let first_send = state_test_take_datagrams(sender.update(0L))
  assert_eq(first_send.length(), 1)
  ignore(state_test_input(receiver, first_send[0]))
  assert_eq(receiver.pending_messages(), 1)
  assert_eq(receiver.kcp_control_receive_window(), 0)

  let first_ack = state_test_take_datagrams(receiver.update(0L))
  assert_eq(first_ack.length(), 1)
  ignore(state_test_input(sender, first_ack[0]))
  assert_eq(sender.remote_window, 0)
  assert_true(sender.send([2]) is Ok(1))
  assert_eq(state_test_take_datagrams(sender.update(10L)).length(), 0)
  assert_eq(sender.waitsnd_segments(), 1)

  assert_eq(receiver.recv(), Some([1]))
  assert_eq(receiver.kcp_control_receive_window(), 1)
  let window_tell = state_test_take_datagrams(receiver.update(10L))
  assert_eq(window_tell.length(), 1)
  let control_segments = kcp_decode_datagram(window_tell[0]).unwrap()
  assert_eq(control_segments.length(), 1)
  assert_eq(control_segments[0].cmd, WindowTell)
  assert_eq(control_segments[0].wnd, 1)
  ignore(state_test_input(sender, window_tell[0]))
  assert_eq(sender.remote_window, 1)

  let resumed = state_test_take_datagrams(sender.update(20L))
  assert_eq(resumed.length(), 1)
  ignore(state_test_input(receiver, resumed[0]))
  assert_eq(receiver.recv(), Some([2]))
  let final_ack = state_test_take_datagrams(receiver.update(20L))
  assert_eq(final_ack.length(), 1)
  ignore(state_test_input(sender, final_ack[0]))
  assert_eq(sender.waitsnd_segments(), 0)
}

///|
test "receive queue backpressure preserves retryable later segments" {
  let config = kcp_default_config()
  config.set_windows(4, 4)
  config.set_resource_limits(1400, 1400, 32)
  let receiver = state_test_control(36L, config)
  let first_message = state_test_datagram([
    state_test_segment(36L, Push, 0L, 0L, 4, 10L, 0, Array::make(1376, 7)),
  ])
  ignore(state_test_input(receiver, first_message))
  let retried_datagram = state_test_datagram([
    state_test_segment(36L, Push, 0L, 0L, 4, 10L, 0, []),
    state_test_segment(36L, Push, 1L, 0L, 4, 11L, 0, Array::make(25, 8)),
  ])

  assert_true(
    receiver.input(retried_datagram) is Err(QueueLimitExceeded(1376, 1400)),
  )
  assert_eq(receiver.next_receive_sequence(), 1L)
  assert_eq(receiver.pending_messages(), 1)
  assert_eq(receiver.pending_acks.length(), 2)
  assert_eq(receiver.stats().received_datagrams, 2)
  assert_eq(receiver.stats().received_segments, 3)
  assert_eq(receiver.stats().received_payload_bytes, 1376)
  assert_eq(receiver.stats().malformed_datagrams, 0)

  assert_eq(receiver.recv(), Some(Array::make(1376, 7)))
  let retried = state_test_input(receiver, retried_datagram)
  assert_eq(retried.segment_count, 2)
  assert_eq(retried.accepted_payload_bytes, 25)
  assert_eq(receiver.next_receive_sequence(), 2L)
  assert_eq(receiver.pending_messages(), 1)
  assert_eq(receiver.recv(), Some(Array::make(25, 8)))
  assert_eq(receiver.stats().received_payload_bytes, 1401)
  assert_eq(receiver.stats().malformed_datagrams, 0)
}

///|
test "deterministic two-peer link recovers fragmented messages under faults" {
  let config = kcp_default_config()
  config.set_windows(8, 8)
  config.set_interval(10)
  config.set_no_congestion_control(true)
  config.set_rto_limits(10, 40, 160)
  config.set_resource_limits(4096, 12000, 2)
  let sender = state_test_control(90L, config)
  let receiver = state_test_control(90L, config)
  let expected = [
    Array::make(2500, 17),
    Array::make(2900, 29),
    Array::make(1700, 41),
  ]
  assert_eq(sender.send(expected[0]), Ok(2))
  assert_eq(sender.send(expected[1]), Ok(3))
  assert_eq(sender.send(expected[2]), Ok(2))

  let mut dropped_push = false
  let mut reordered_push = false
  let mut duplicated_push = false
  let mut held_pushes : Array[Array[Int]] = []
  let mut dropped_ack = false
  let delivered : Array[Array[Int]] = []
  let mut tick = 0
  while tick < 100 &&
        (
          sender.waitsnd_segments() > 0 ||
          delivered.length() < expected.length()
        ) {
    let now = (tick * 10).to_int64()
    let outbound = state_test_take_datagrams(sender.update(now))
    for datagram in outbound {
      assert_true(datagram.length() <= config.mtu)
      let segments = match kcp_decode_datagram(datagram) {
        Ok(decoded) => decoded
        Err(_) => fail("simulated link received an invalid sender datagram")
      }
      assert_true(segments.length() <= config.max_segments_per_datagram)
      let has_push = segments.any(fn(segment) { segment.cmd == Push })
      if has_push && !dropped_push {
        dropped_push = true
      } else if has_push && !reordered_push {
        held_pushes.push(datagram)
        reordered_push = true
      } else {
        ignore(state_test_input(receiver, datagram))
        if has_push && !duplicated_push {
          ignore(state_test_input(receiver, datagram))
          duplicated_push = true
        }
        if held_pushes.length() > 0 {
          ignore(state_test_input(receiver, held_pushes[0]))
          held_pushes = []
        }
      }
    }

    let acknowledgements = state_test_take_datagrams(receiver.update(now))
    for datagram in acknowledgements {
      assert_true(datagram.length() <= config.mtu)
      let segments = match kcp_decode_datagram(datagram) {
        Ok(decoded) => decoded
        Err(_) => fail("simulated link received an invalid receiver datagram")
      }
      assert_true(segments.length() <= config.max_segments_per_datagram)
      let has_ack = segments.any(fn(segment) { segment.cmd == Ack })
      if has_ack && !dropped_ack {
        dropped_ack = true
      } else {
        ignore(state_test_input(sender, datagram))
      }
    }

    let mut receiving = true
    while receiving {
      match receiver.recv() {
        Some(message) => {
          assert_true(delivered.length() < expected.length())
          assert_eq(message, expected[delivered.length()])
          delivered.push(message)
        }
        None => receiving = false
      }
    }

    assert_true(sender.waitsnd_bytes() <= config.max_queued_bytes)
    let send_segment_limit = kcp_int_min(
      config.max_queued_bytes / kcp_config_mss(config),
      kcp_hard_max_queued_segments,
    )
    assert_true(sender.waitsnd_segments() <= send_segment_limit)
    assert_true(
      receiver.receive_queue_bytes + receiver.receive_buffer_bytes <=
      config.max_queued_bytes,
    )
    assert_true(
      receiver.receive_queue_segments + receiver.receive_buffer.length() <=
      config.receive_window,
    )
    let pending_ack_limit = kcp_int_min(
      config.max_queued_bytes / kcp_header_size,
      config.receive_window * 4,
    )
    assert_true(receiver.pending_acks.length() <= pending_ack_limit)
    tick += 1
  }

  assert_true(dropped_push)
  assert_true(reordered_push)
  assert_true(duplicated_push)
  assert_true(dropped_ack)
  assert_eq(held_pushes.length(), 0)
  assert_eq(delivered.length(), expected.length())
  assert_eq(sender.waitsnd_segments(), 0)
  assert_eq(sender.waitsnd_bytes(), 0)
  assert_eq(sender.send_queue.length(), 0)
  assert_eq(sender.send_buffer.length(), 0)
  assert_true(sender.stats().timeout_retransmissions > 0)
  assert_eq(receiver.pending_messages(), 0)
  assert_eq(receiver.receive_queue.length(), 0)
  assert_eq(receiver.receive_buffer.length(), 0)
  assert_eq(receiver.receive_queue_bytes, 0)
  assert_eq(receiver.receive_buffer_bytes, 0)
  assert_eq(receiver.receive_queue_segments, 0)
  assert_eq(receiver.pending_acks.length(), 0)
}

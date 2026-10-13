// Blackbox tests run against the package's public API. Use `@moon-kcp` to import.
// Prefer high-level behaviors over implementation details.
// Run `moon test` to execute and `moon test --update` to refresh snapshots.

///|
test "public peek reports the next complete message without consuming it" {
  let receiver = @moon-kcp.new_kcp_control(31L, @moon-kcp.kcp_default_config()).unwrap()
  assert_eq(receiver.peek_message_size(), None)
  let segment : @moon-kcp.KcpSegment = {
    conv: 31L,
    cmd: @moon-kcp.Push,
    frg: 0,
    wnd: 128,
    ts: 10L,
    sn: 0L,
    una: 0L,
    data: [9, 8, 7],
  }
  let datagram = @moon-kcp.kcp_encode_segment(segment).unwrap()
  assert_eq(receiver.input(datagram).unwrap().accepted_payload_bytes, 3)
  assert_eq(receiver.peek_message_size(), Some(3))
  assert_eq(receiver.peek_message_size(), Some(3))
  assert_eq(receiver.recv(), Some([9, 8, 7]))
  assert_eq(receiver.peek_message_size(), None)
}

///|
test "control blocks copy configuration, queued payloads, and decoded datagrams" {
  let config = @moon-kcp.kcp_default_config()
  config.set_mtu(100)
  config.set_resource_limits(9728, 4 * 1024 * 1024, 32)
  let configured = @moon-kcp.new_kcp_control(55L, config).unwrap()
  assert_eq(configured.conversation(), 55L)
  assert_eq(configured.maximum_segment_payload(), 76)
  config.set_mtu(200)
  assert_eq(configured.maximum_segment_payload(), 76)
  assert_true(configured.send(Array::make(77, 3)) is Ok(2))

  let sender = @moon-kcp.new_kcp_control(56L, @moon-kcp.kcp_default_config()).unwrap()
  let application_bytes = [1, 2, 3]
  assert_true(sender.send(application_bytes) is Ok(1))
  application_bytes[0] = 99
  let initial = sender.update(0L).unwrap()
  let initial_segments = @moon-kcp.kcp_decode_datagram(initial[0]).unwrap()
  assert_eq(initial_segments[0].data, [1, 2, 3])
  initial[0][24] = 88
  let retransmission = sender.update(225L).unwrap()
  let retried_segments = @moon-kcp.kcp_decode_datagram(retransmission[0]).unwrap()
  assert_eq(retried_segments[0].data, [1, 2, 3])

  let receiver = @moon-kcp.new_kcp_control(57L, @moon-kcp.kcp_default_config()).unwrap()
  let incoming = @moon-kcp.kcp_encode_segment({
    conv: 57L,
    cmd: @moon-kcp.Push,
    frg: 0,
    wnd: 128,
    ts: 0L,
    sn: 0L,
    una: 0L,
    data: [4, 5],
  }).unwrap()
  ignore(receiver.input(incoming))
  incoming[24] = 77
  assert_eq(receiver.recv(), Some([4, 5]))
}

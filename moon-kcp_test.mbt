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

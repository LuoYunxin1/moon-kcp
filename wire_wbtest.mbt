///|
fn wire_test_segment(command : KcpCommand, data : Array[Int]) -> KcpSegment {
  {
    conv: 0x78563412L,
    cmd: command,
    frg: 7,
    wnd: 0x1234,
    ts: 0xFEDCBA98L,
    sn: 0x89ABCDEFL,
    una: 0x10203040L,
    data,
  }
}

///|
test "KCP wire header is little endian and preserves payload" {
  let segment = wire_test_segment(Push, [0, 1, 127, 255])
  let encoded = match kcp_encode_segment(segment) {
    Ok(bytes) => bytes
    Err(_) => fail("expected segment encoding to succeed")
  }
  assert_eq(encoded.length(), 28)
  assert_eq(encoded[0], 0x12)
  assert_eq(encoded[1], 0x34)
  assert_eq(encoded[2], 0x56)
  assert_eq(encoded[3], 0x78)
  assert_eq(encoded[4], 81)
  assert_eq(encoded[5], 7)
  assert_eq(encoded[6], 0x34)
  assert_eq(encoded[7], 0x12)
  assert_eq(encoded[8], 0x98)
  assert_eq(encoded[11], 0xFE)
  assert_eq(encoded[12], 0xEF)
  assert_eq(encoded[15], 0x89)
  assert_eq(encoded[20], 4)
  assert_eq(encoded[21], 0)
  assert_eq(encoded[24], 0)
  assert_eq(encoded[25], 1)
  assert_eq(encoded[26], 127)
  assert_eq(encoded[27], 255)

  let decoded = match kcp_decode_datagram(encoded) {
    Ok(segments) => segments
    Err(_) => fail("expected datagram decoding to succeed")
  }
  assert_eq(decoded.length(), 1)
  assert_eq(decoded[0].conv, segment.conv)
  assert_eq(decoded[0].cmd, Push)
  assert_eq(decoded[0].frg, segment.frg)
  assert_eq(decoded[0].wnd, segment.wnd)
  assert_eq(decoded[0].ts, segment.ts)
  assert_eq(decoded[0].sn, segment.sn)
  assert_eq(decoded[0].una, segment.una)
  assert_eq(decoded[0].data, segment.data)
}

///|
test "all KCP command values encode and decode" {
  let commands : Array[KcpCommand] = [Push, Ack, WindowAsk, WindowTell]
  let expected : Array[Int] = [81, 82, 83, 84]
  for i in 0..<commands.length() {
    let encoded = match kcp_encode_segment(wire_test_segment(commands[i], [])) {
      Ok(bytes) => bytes
      Err(_) => fail("known command should encode")
    }
    assert_eq(encoded[4], expected[i])
    let decoded = match kcp_decode_datagram(encoded) {
      Ok(segments) => segments
      Err(_) => fail("known command should decode")
    }
    assert_eq(decoded[0].cmd, commands[i])
  }
}

///|
test "datagram parser traverses concatenated segments" {
  let first = match kcp_encode_segment(wire_test_segment(Ack, [])) {
    Ok(bytes) => bytes
    Err(_) => fail("first segment should encode")
  }
  let second = match kcp_encode_segment(wire_test_segment(Push, [9, 8, 7])) {
    Ok(bytes) => bytes
    Err(_) => fail("second segment should encode")
  }
  let datagram = first.copy()
  for byte in second {
    datagram.push(byte)
  }
  let decoded = match kcp_decode_datagram(datagram) {
    Ok(segments) => segments
    Err(_) => fail("concatenated segments should decode")
  }
  assert_eq(decoded.length(), 2)
  assert_eq(decoded[0].cmd, Ack)
  assert_eq(decoded[1].cmd, Push)
  assert_eq(decoded[1].data, [9, 8, 7])
}

///|
test "datagram parser rejects truncated headers and payloads" {
  assert_true(kcp_decode_datagram([1, 2, 3]) is Err(TruncatedHeader(0, 3)))
  let valid = match kcp_encode_segment(wire_test_segment(Push, [5])) {
    Ok(bytes) => bytes
    Err(_) => fail("segment should encode")
  }
  ignore(valid.pop())
  assert_true(kcp_decode_datagram(valid) is Err(TruncatedPayload(0, 1L, 0)))
}

///|
test "datagram parser rejects unknown commands and invalid bytes" {
  let bytes = match kcp_encode_segment(wire_test_segment(Ack, [])) {
    Ok(encoded) => encoded
    Err(_) => fail("segment should encode")
  }
  bytes[4] = 99
  assert_true(kcp_decode_datagram(bytes) is Err(UnknownCommand(4, 99)))
  let invalid_byte = match kcp_encode_segment(wire_test_segment(Ack, [])) {
    Ok(encoded) => encoded
    Err(_) => fail("segment should encode")
  }
  invalid_byte[0] = 256
  assert_true(kcp_decode_datagram(invalid_byte) is Err(InvalidByte(0, 256)))
}

///|
test "encoder validates field widths and payload bytes" {
  let base = wire_test_segment(Push, [])
  let bad_conv = {
    conv: 4294967296L,
    cmd: base.cmd,
    frg: base.frg,
    wnd: base.wnd,
    ts: base.ts,
    sn: base.sn,
    una: base.una,
    data: base.data,
  }
  assert_true(
    kcp_encode_segment(bad_conv) is Err(InvalidU32Field("conv", 4294967296L)),
  )
  let bad_fragment = {
    conv: base.conv,
    cmd: base.cmd,
    frg: 256,
    wnd: base.wnd,
    ts: base.ts,
    sn: base.sn,
    una: base.una,
    data: base.data,
  }
  assert_true(
    kcp_encode_segment(bad_fragment) is Err(InvalidU8Field("frg", 256)),
  )
  let bad_window = {
    conv: base.conv,
    cmd: base.cmd,
    frg: base.frg,
    wnd: 65536,
    ts: base.ts,
    sn: base.sn,
    una: base.una,
    data: base.data,
  }
  assert_true(
    kcp_encode_segment(bad_window) is Err(InvalidU16Field("wnd", 65536)),
  )
  let bad_data = wire_test_segment(Push, [256])
  assert_true(kcp_encode_segment(bad_data) is Err(InvalidByte(0, 256)))
}

///|
test "sequence arithmetic wraps at u32 boundary" {
  assert_eq(kcp_seq_add(0xFFFFFFFFL, 1L), 0L)
  assert_eq(kcp_seq_add(0L, -1L), 0xFFFFFFFFL)
  assert_eq(kcp_seq_add(0xFFFFFFFEL, 3L), 1L)
}

///|
test "sequence comparison uses wrapping signed difference" {
  assert_true(kcp_seq_less(0xFFFFFFFFL, 0L))
  assert_true(kcp_seq_less(0L, 1L))
  assert_true(!kcp_seq_less(1L, 0L))
  assert_true(!kcp_seq_less(7L, 7L))
  assert_true(kcp_seq_less(0x7FFFFFFFL, 0x80000000L))
}

///|
test "decoder rejects invalid payload octets and oversized declared lengths" {
  let payload = match kcp_encode_segment(wire_test_segment(Push, [7])) {
    Ok(bytes) => bytes
    Err(_) => fail("test segment should encode")
  }
  payload[24] = -1
  assert_true(kcp_decode_datagram(payload) is Err(InvalidByte(24, -1)))

  let declared_length = match kcp_encode_segment(wire_test_segment(Ack, [])) {
    Ok(bytes) => bytes
    Err(_) => fail("empty ACK should encode")
  }
  declared_length[20] = 255
  declared_length[21] = 255
  declared_length[22] = 255
  declared_length[23] = 255
  assert_true(
    kcp_decode_datagram(declared_length)
    is Err(TruncatedPayload(0, 4294967295L, 0)),
  )
}

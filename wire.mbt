/// KCP v1 wire boundary: each segment is a 24-byte little-endian header
/// followed by exactly `len` payload bytes. This module validates and walks
/// datagrams only; it does not implement transport, timers, congestion control,
/// stream semantics, or KCP control-block policy.
///
/// The fixed header layout is conv:u32, cmd:u8, frg:u8, wnd:u16,
/// ts:u32, sn:u32, una:u32, len:u32. Sequence values are stored as
/// non-negative Int64 bit patterns in the inclusive u32 range.

///|
pub(all) enum KcpCommand {
  Push
  Ack
  WindowAsk
  WindowTell
} derive(Eq, Debug)

///|
pub extend KcpCommand with Eq::{not_equal, equal}

///|
pub extend KcpCommand with @debug.Debug::{to_repr}

///|
pub(all) struct KcpSegment {
  conv : Int64
  cmd : KcpCommand
  frg : Int
  wnd : Int
  ts : Int64
  sn : Int64
  una : Int64
  data : Array[Int]
}

///|
pub enum KcpError {
  InvalidU32Field(String, Int64)
  InvalidU8Field(String, Int)
  InvalidU16Field(String, Int)
  InvalidByte(Int, Int)
  UnknownCommand(Int, Int)
  TruncatedHeader(Int, Int)
  TruncatedPayload(Int, Int64, Int)
  PayloadTooLarge(Int)
} derive(Eq, Debug)

///|
pub extend KcpError with Eq::{not_equal, equal}

///|
pub extend KcpError with @debug.Debug::{to_repr}

///|
let kcp_header_size : Int = 24

///|
let kcp_u32_max : Int64 = 4294967295L

///|
let kcp_u32_mask : Int64 = 4294967295L

///|
let kcp_u32_half : Int64 = 2147483648L

///|
fn kcp_command_byte(command : KcpCommand) -> Int {
  match command {
    Push => 81
    Ack => 82
    WindowAsk => 83
    WindowTell => 84
  }
}

///|
fn kcp_validate_u32(name : String, value : Int64) -> Result[Unit, KcpError] {
  if value < 0L || value > kcp_u32_max {
    Err(InvalidU32Field(name, value))
  } else {
    Ok(())
  }
}

///|
fn kcp_validate_u8(name : String, value : Int) -> Result[Unit, KcpError] {
  if value < 0 || value > 255 {
    Err(InvalidU8Field(name, value))
  } else {
    Ok(())
  }
}

///|
fn kcp_validate_u16(name : String, value : Int) -> Result[Unit, KcpError] {
  if value < 0 || value > 65535 {
    Err(InvalidU16Field(name, value))
  } else {
    Ok(())
  }
}

///|
fn kcp_push_u32_le(out : Array[Int], value : Int64) -> Unit {
  out.push(((value >> 0) & 255L).to_int())
  out.push(((value >> 8) & 255L).to_int())
  out.push(((value >> 16) & 255L).to_int())
  out.push(((value >> 24) & 255L).to_int())
}

///|
fn kcp_read_u32_le(bytes : Array[Int], offset : Int) -> Int64 {
  bytes[offset].to_int64() |
  (bytes[offset + 1].to_int64() << 8) |
  (bytes[offset + 2].to_int64() << 16) |
  (bytes[offset + 3].to_int64() << 24)
}

///|
/// Encode one KCP v1 segment, rejecting out-of-range fields and non-byte data.
pub fn kcp_encode_segment(segment : KcpSegment) -> Result[Array[Int], KcpError] {
  match kcp_validate_u32("conv", segment.conv) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match kcp_validate_u32("ts", segment.ts) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match kcp_validate_u32("sn", segment.sn) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match kcp_validate_u32("una", segment.una) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match kcp_validate_u8("frg", segment.frg) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match kcp_validate_u16("wnd", segment.wnd) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let data_len = segment.data.length().to_int64()
  if data_len > kcp_u32_max {
    return Err(PayloadTooLarge(segment.data.length()))
  }
  let mut i = 0
  while i < segment.data.length() {
    let byte = segment.data[i]
    if byte < 0 || byte > 255 {
      return Err(InvalidByte(i, byte))
    }
    i += 1
  }

  let out : Array[Int] = []
  kcp_push_u32_le(out, segment.conv)
  out.push(kcp_command_byte(segment.cmd))
  out.push(segment.frg)
  out.push(segment.wnd & 255)
  out.push((segment.wnd >> 8) & 255)
  kcp_push_u32_le(out, segment.ts)
  kcp_push_u32_le(out, segment.sn)
  kcp_push_u32_le(out, segment.una)
  kcp_push_u32_le(out, data_len)
  for byte in segment.data {
    out.push(byte)
  }
  Ok(out)
}

///|
/// Decode every concatenated KCP segment in one UDP datagram.
/// Empty datagrams decode to an empty segment array. Payload bytes are copied
/// so returned segments do not alias the caller's mutable input array.
pub fn kcp_decode_datagram(
  bytes : Array[Int],
) -> Result[Array[KcpSegment], KcpError] {
  let segments : Array[KcpSegment] = []
  let mut offset = 0
  while offset < bytes.length() {
    let remaining = bytes.length() - offset
    if remaining < kcp_header_size {
      return Err(TruncatedHeader(offset, remaining))
    }

    let mut header_index = offset
    while header_index < offset + kcp_header_size {
      let value = bytes[header_index]
      if value < 0 || value > 255 {
        return Err(InvalidByte(header_index, value))
      }
      header_index += 1
    }

    let conv = kcp_read_u32_le(bytes, offset)
    let command_value = bytes[offset + 4]
    let command = match command_value {
      81 => Push
      82 => Ack
      83 => WindowAsk
      84 => WindowTell
      _ => return Err(UnknownCommand(offset + 4, command_value))
    }
    let frg = bytes[offset + 5]
    let wnd = bytes[offset + 6] | (bytes[offset + 7] << 8)
    let ts = kcp_read_u32_le(bytes, offset + 8)
    let sn = kcp_read_u32_le(bytes, offset + 12)
    let una = kcp_read_u32_le(bytes, offset + 16)
    let data_len = kcp_read_u32_le(bytes, offset + 20)
    let available = remaining - kcp_header_size
    if data_len > available.to_int64() {
      return Err(TruncatedPayload(offset, data_len, available))
    }
    let payload_len = data_len.to_int()
    let payload_start = offset + kcp_header_size
    let payload_end = payload_start + payload_len
    let data : Array[Int] = []
    let mut payload_index = payload_start
    while payload_index < payload_end {
      let byte = bytes[payload_index]
      if byte < 0 || byte > 255 {
        return Err(InvalidByte(payload_index, byte))
      }
      data.push(byte)
      payload_index += 1
    }
    segments.push({ conv, cmd: command, frg, wnd, ts, sn, una, data, })
    offset = payload_end
  }
  Ok(segments)
}

///|
/// Add a delta modulo 2^32, preserving the result as a non-negative Int64.
pub fn kcp_seq_add(value : Int64, delta : Int64) -> Int64 {
  (value + delta) & kcp_u32_mask
}

///|
/// KCP serial-number ordering: true when the signed 32-bit difference is
/// negative. As with RFC-style serial arithmetic, callers must compare values
/// whose distance is less than 2^31; the half-range boundary is ambiguous.
pub fn kcp_seq_less(left : Int64, right : Int64) -> Bool {
  ((left - right) & kcp_u32_mask) >= kcp_u32_half
}

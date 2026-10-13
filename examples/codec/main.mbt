///|
/// Encode one application payload into a KCP PUSH segment and decode it again.
/// This example shows the wire boundary only; it does not open a socket.
fn main {
  let segment : @kcp.KcpSegment = {
    conv: 7L,
    cmd: @kcp.Push,
    frg: 0,
    wnd: 128,
    ts: 1000L,
    sn: 0L,
    una: 0L,
    data: [72, 101, 108, 108, 111],
  }
  match @kcp.kcp_encode_segment(segment) {
    Err(_) => println("Could not encode the example segment.")
    Ok(encoded) =>
      match @kcp.kcp_decode_datagram(encoded) {
        Err(_) => println("Could not decode the encoded datagram.")
        Ok(segments) => {
          println("KCP datagram bytes: " + encoded.length().to_string())
          println("Segments decoded: " + segments.length().to_string())
          println("Conversation: " + segments[0].conv.to_string())
          println("Sequence: " + segments[0].sn.to_string())
          println("Payload bytes: " + segments[0].data.length().to_string())
        }
      }
  }
}

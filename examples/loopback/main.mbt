///|
/// Deliver one emitted datagram to the opposite in-memory control block.
fn deliver(
  peer : @kcp.KcpControl,
  datagram : Array[Int],
  label : String,
) -> Unit {
  match peer.input(datagram) {
    Ok(report) =>
      println(
        label +
        ": segments=" +
        report.segment_count.to_string() +
        ", accepted-bytes=" +
        report.accepted_payload_bytes.to_string(),
      )
    Err(_) => println(label + ": peer rejected datagram")
  }
}

///|
/// Exchange a fragmented message and its ACKs between two in-memory peers.
/// Hosts using the library do the same handoff with their UDP socket layer.
fn main {
  match @kcp.new_kcp_control(0x4D4F4F4EL, @kcp.kcp_default_config()) {
    Err(_) => println("Could not create sender control block.")
    Ok(sender) =>
      match @kcp.new_kcp_control(0x4D4F4F4EL, @kcp.kcp_default_config()) {
        Err(_) => println("Could not create receiver control block.")
        Ok(receiver) => {
          let message = [77, 111, 111, 110, 66, 105, 116, 45, 75, 67, 80]
          match sender.send(message) {
            Err(_) => println("Sender rejected the message.")
            Ok(fragments) => {
              println("Queued fragments: " + fragments.to_string())
              match sender.update(0L) {
                Err(_) => println("Sender update failed.")
                Ok(outgoing) => {
                  for datagram in outgoing {
                    deliver(receiver, datagram, "data")
                  }
                  match receiver.update(0L) {
                    Err(_) => println("Receiver update failed.")
                    Ok(acknowledgements) =>
                      for acknowledgement in acknowledgements {
                        deliver(sender, acknowledgement, "ack")
                      }
                  }
                  match receiver.recv() {
                    None => println("No complete message is ready.")
                    Some(complete) =>
                      println(
                        "Delivered message bytes: " +
                        complete.length().to_string(),
                      )
                  }
                  println(
                    "Sender outstanding segments: " +
                    sender.waitsnd_segments().to_string(),
                  )
                }
              }
            }
          }
        }
      }
  }
}

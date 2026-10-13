///|
/// Drop the first transmission, advance the caller-owned clock to the first resend deadline,
/// then deliver the timeout retransmission and return its acknowledgement.
fn main {
  let config = @kcp.kcp_default_config()
  config.set_interval(20)
  config.set_rto_limits(10, 50, 1000)
  match @kcp.new_kcp_control(0x52545259L, config) {
    Err(_) => println("Could not create sender control block.")
    Ok(sender) =>
      match @kcp.new_kcp_control(0x52545259L, config) {
        Err(_) => println("Could not create receiver control block.")
        Ok(receiver) =>
          match sender.send([114, 101, 116, 114, 121]) {
            Err(_) => println("Sender rejected the message.")
            Ok(_) => {
              match sender.update(0L) {
                Err(_) => println("Initial update failed.")
                Ok(first_send) =>
                  println(
                    "Initial datagrams intentionally dropped: " +
                    first_send.length().to_string(),
                  )
              }
              match sender.update(56L) {
                Err(_) => println("Retransmission update failed.")
                Ok(retry) => {
                  println(
                    "Timeout retransmission datagrams: " +
                    retry.length().to_string(),
                  )
                  for datagram in retry {
                    match receiver.input(datagram) {
                      Err(_) => println("Receiver rejected retransmission.")
                      Ok(_) => ()
                    }
                  }
                  match receiver.update(56L) {
                    Err(_) => println("Receiver ACK update failed.")
                    Ok(acks) =>
                      for acknowledgement in acks {
                        match sender.input(acknowledgement) {
                          Err(_) => println("Sender rejected ACK.")
                          Ok(_) => ()
                        }
                      }
                  }
                  let stats = sender.stats()
                  println(
                    "Timeout retries recorded: " +
                    stats.timeout_retransmissions.to_string(),
                  )
                  println(
                    "Outstanding segments after ACK: " +
                    sender.waitsnd_segments().to_string(),
                  )
                }
              }
            }
          }
      }
  }
}

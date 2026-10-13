///|
test "kcp default configuration is valid" {
  let config = kcp_default_config()
  assert_true(kcp_config_is_valid(config))
  assert_eq(kcp_config_mss(config), 1376)
  assert_true(kcp_config_accepts_message(config, 4096))
}

///|
test "kcp config refuses wire-inexpressible windows" {
  let config = kcp_default_config()
  config.set_windows(65536, 128)
  assert_false(kcp_config_is_valid(config))
}

///|
test "kcp config refuses inconsistent retransmission timers" {
  let config = kcp_default_config()
  config.set_rto_limits(100, 50, 60000)
  assert_false(kcp_config_is_valid(config))
}

///|
test "kcp config bounds message fragmentation" {
  let config = kcp_default_config()
  config.set_resource_limits(256 * 1024, 4 * 1024 * 1024, 32)
  config.set_mtu(25)
  assert_false(kcp_config_accepts_message(config, 1024))
}

///|
test "kcp config enforces hard memory and message ceilings" {
  let config = kcp_default_config()
  config.set_resource_limits(16 * 1024 * 1024 + 1, 32 * 1024 * 1024, 32)
  assert_false(kcp_config_is_valid(config))
  config.set_resource_limits(1024, 64 * 1024 * 1024 + 1, 32)
  assert_false(kcp_config_is_valid(config))
}

///|
test "kcp message length checks reject huge and negative values safely" {
  let config = kcp_default_config()
  assert_false(kcp_config_accepts_message(config, -1))
  assert_false(kcp_config_accepts_message(config, 2147483647))
  assert_true(kcp_config_accepts_message(config, 0))
}

///|
test "message fragments must fit the receive window while stream chunks may span it" {
  let config = kcp_default_config()
  assert_eq(kcp_config_max_fragments(config), config.receive_window)
  config.set_resource_limits(256 * 1024, 4 * 1024 * 1024, 32)
  assert_false(kcp_config_is_valid(config))
  config.set_stream_mode(true)
  assert_true(kcp_config_is_valid(config))
  assert_true(kcp_config_accepts_message(config, 256 * 1024))
}

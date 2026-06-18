# typed: false
# frozen_string_literal: true

require_relative "test_helper"

class ConnectionTest < ServerTest
  def test_ping_echo
    assert_equal "PONG", r("PING")
    assert_equal "hi", r("PING", "hi")
    assert_equal "hello", r("ECHO", "hello")
  end

  def test_select_and_isolation
    r("SET", "k", "db0")
    assert_equal "OK", r("SELECT", "1")
    assert_nil r("GET", "k")
    assert_equal "OK", r("SET", "k", "db1")
    assert_equal "OK", r("SELECT", "0")
    assert_equal "db0", r("GET", "k")
  end

  def test_hello_negotiates_resp3
    reply = r("HELLO", "3")
    assert_equal 3, reply["proto"]
    assert_equal "redis", reply["server"]
  end

  def test_command_count
    assert r("COMMAND", "COUNT") > 100
  end

  def test_dbsize_flushdb
    r("MSET", "a", "1", "b", "2")
    assert_equal 2, r("DBSIZE")
    assert_equal "OK", r("FLUSHDB")
    assert_equal 0, r("DBSIZE")
  end

  def test_info_has_sections
    info = r("INFO")
    assert_match(/redis_version:/, info)
    assert_match(/# Keyspace/, info)
  end

  def test_config_get_set
    assert_equal %w[maxmemory 0], r("CONFIG", "GET", "maxmemory")
    assert_equal "OK", r("CONFIG", "SET", "maxmemory", "100mb")
    assert_equal %w[maxmemory 100mb], r("CONFIG", "GET", "maxmemory")
  end

  def test_hgetall_is_map_in_resp3
    r("HELLO", "3")
    r("HSET", "h", "a", "1", "b", "2")
    assert_equal({ "a" => "1", "b" => "2" }, r("HGETALL", "h"))
  end
end

# typed: false
# frozen_string_literal: true

require_relative "test_helper"

class PersistenceTest < ServerTest
  def test_save_and_reload_roundtrips_all_types
    r("SET", "str", "hello")
    r("EXPIRE", "str", "1000")
    r("RPUSH", "list", "a", "b", "c")
    r("HSET", "hash", "f1", "v1", "f2", "v2")
    r("SADD", "set", "x", "y", "z")
    r("ZADD", "zset", "1", "a", "2.5", "b")

    assert_equal "OK", r("SAVE")
    assert_equal "OK", r("DEBUG", "RELOAD")

    assert_equal "hello", r("GET", "str")
    assert r("TTL", "str").positive?
    assert_equal %w[a b c], r("LRANGE", "list", "0", "-1")
    assert_equal %w[f1 v1 f2 v2], r("HGETALL", "hash")
    assert_equal %w[x y z], r("SMEMBERS", "set").sort
    assert_equal ["a", "1", "b", "2.5"], r("ZRANGE", "zset", "0", "-1", "WITHSCORES")
  end

  def test_rdb_file_loads_into_fresh_server
    r("SET", "persisted", "value")
    r("ZADD", "scores", "42", "answer")
    assert_equal "OK", r("SAVE")

    # Boot a brand new server pointed at the same directory.
    config = RedisRuby::Config.new
    config.set("dir", @harness.dir)
    config.set("save", "")
    other = RedisRuby::Server.new(config)
    port = other.listen(host: "127.0.0.1", port: 0)
    thread = Thread.new { other.run }
    begin
      client = TestSupport::Client.new("127.0.0.1", port)
      assert_equal "value", client.call("GET", "persisted")
      assert_equal "42", client.call("ZSCORE", "scores", "answer")
      client.close
    ensure
      other.stop
      thread.join(5)
    end
  end
end

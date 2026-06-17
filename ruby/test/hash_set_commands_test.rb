# typed: false
# frozen_string_literal: true

require_relative "test_helper"

class HashCommandsTest < ServerTest
  def test_hset_hget
    assert_equal 2, r("HSET", "h", "a", "1", "b", "2")
    assert_equal "1", r("HGET", "h", "a")
    assert_equal 0, r("HSET", "h", "a", "10")
    assert_equal 2, r("HLEN", "h")
    assert_equal 1, r("HEXISTS", "h", "b")
    assert_equal ["10", "2"], r("HMGET", "h", "a", "b")
  end

  def test_hgetall_flat_in_resp2
    r("HSET", "h", "a", "1", "b", "2")
    # RESP2 returns a map as a flat array; RESP3 clients get a real map.
    assert_equal %w[a 1 b 2], r("HGETALL", "h")
  end

  def test_hdel
    r("HSET", "h", "a", "1", "b", "2")
    assert_equal 1, r("HDEL", "h", "a")
    assert_equal 1, r("HDEL", "h", "b", "missing")
    assert_equal 0, r("EXISTS", "h")
  end

  def test_hincr
    assert_equal 5, r("HINCRBY", "h", "n", "5")
    assert_equal 3, r("HINCRBY", "h", "n", "-2")
    assert_equal "3.5", r("HINCRBYFLOAT", "h", "f", "3.5")
  end

  def test_hscan
    10.times { |i| r("HSET", "h", "f#{i}", i.to_s) }
    cursor, batch = r("HSCAN", "h", "0", "COUNT", "100")
    assert_equal "0", cursor
    assert_equal 20, batch.size
  end
end

class SetCommandsTest < ServerTest
  def test_sadd_members
    assert_equal 3, r("SADD", "s", "a", "b", "c")
    assert_equal 0, r("SADD", "s", "a")
    assert_equal 3, r("SCARD", "s")
    assert_equal %w[a b c], r("SMEMBERS", "s").sort
    assert_equal 1, r("SISMEMBER", "s", "a")
    assert_equal [1, 0], r("SMISMEMBER", "s", "a", "z")
  end

  def test_srem_spop
    r("SADD", "s", "a", "b", "c")
    assert_equal 1, r("SREM", "s", "a")
    popped = r("SPOP", "s")
    assert_includes %w[b c], popped
  end

  def test_set_algebra
    r("SADD", "s1", "a", "b", "c", "d")
    r("SADD", "s2", "c", "d", "e")
    assert_equal %w[c d], r("SINTER", "s1", "s2").sort
    assert_equal %w[a b c d e], r("SUNION", "s1", "s2").sort
    assert_equal %w[a b], r("SDIFF", "s1", "s2").sort
    assert_equal 2, r("SINTERSTORE", "dst", "s1", "s2")
    assert_equal 2, r("SINTERCARD", "2", "s1", "s2")
  end

  def test_smove
    r("SADD", "s1", "a", "b")
    assert_equal 1, r("SMOVE", "s1", "s2", "a")
    assert_equal 0, r("SISMEMBER", "s1", "a")
    assert_equal 1, r("SISMEMBER", "s2", "a")
  end
end

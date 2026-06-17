# typed: false
# frozen_string_literal: true

require_relative "test_helper"

class SortedSetCommandsTest < ServerTest
  def test_zadd_zscore_zrange
    assert_equal 3, r("ZADD", "z", "1", "a", "2", "b", "3", "c")
    assert_equal "2", r("ZSCORE", "z", "b")
    assert_equal %w[a b c], r("ZRANGE", "z", "0", "-1")
    assert_equal %w[c b a], r("ZREVRANGE", "z", "0", "-1")
    assert_equal ["a", "1", "b", "2", "c", "3"], r("ZRANGE", "z", "0", "-1", "WITHSCORES")
  end

  def test_zadd_options
    r("ZADD", "z", "1", "a")
    assert_equal 0, r("ZADD", "z", "NX", "5", "a")
    assert_equal "1", r("ZSCORE", "z", "a")
    assert_equal 0, r("ZADD", "z", "XX", "CH", "1", "a")
    assert_equal 1, r("ZADD", "z", "XX", "CH", "9", "a")
    assert_equal "14", r("ZADD", "z", "INCR", "5", "a")
  end

  def test_zincrby_zrank
    r("ZADD", "z", "1", "a", "2", "b", "3", "c")
    assert_equal "5", r("ZINCRBY", "z", "4", "a")
    assert_equal 2, r("ZRANK", "z", "a")
    assert_equal 0, r("ZREVRANK", "z", "a")
  end

  def test_zrangebyscore
    r("ZADD", "z", "1", "a", "2", "b", "3", "c", "4", "d")
    assert_equal %w[b c], r("ZRANGEBYSCORE", "z", "2", "3")
    assert_equal %w[c], r("ZRANGEBYSCORE", "z", "(2", "3")
    assert_equal %w[a b c d], r("ZRANGEBYSCORE", "z", "-inf", "+inf")
    assert_equal %w[b c], r("ZRANGEBYSCORE", "z", "-inf", "+inf", "LIMIT", "1", "2")
    assert_equal %w[d c b a], r("ZREVRANGEBYSCORE", "z", "+inf", "-inf")
  end

  def test_zrangebylex
    r("ZADD", "z", "0", "a", "0", "b", "0", "c", "0", "d")
    assert_equal %w[a b c d], r("ZRANGEBYLEX", "z", "-", "+")
    assert_equal %w[a b], r("ZRANGEBYLEX", "z", "[a", "[b")
    assert_equal %w[b c], r("ZRANGEBYLEX", "z", "(a", "[c")
  end

  def test_zpop
    r("ZADD", "z", "1", "a", "2", "b", "3", "c")
    assert_equal ["a", "1"], r("ZPOPMIN", "z")
    assert_equal ["c", "3"], r("ZPOPMAX", "z")
  end

  def test_zcount_and_remove
    r("ZADD", "z", "1", "a", "2", "b", "3", "c")
    assert_equal 2, r("ZCOUNT", "z", "2", "3")
    assert_equal 1, r("ZREMRANGEBYSCORE", "z", "1", "1")
    assert_equal 2, r("ZCARD", "z")
  end

  def test_zunionstore_with_weights
    r("ZADD", "z1", "1", "a", "2", "b")
    r("ZADD", "z2", "3", "a", "4", "c")
    assert_equal 3, r("ZUNIONSTORE", "dst", "2", "z1", "z2", "WEIGHTS", "1", "10")
    assert_equal "31", r("ZSCORE", "dst", "a")
    assert_equal 1, r("ZINTERSTORE", "dst2", "2", "z1", "z2")
  end
end

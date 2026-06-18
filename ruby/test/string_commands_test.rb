# typed: false
# frozen_string_literal: true

require_relative "test_helper"

class StringCommandsTest < ServerTest
  def test_set_and_get
    assert_equal "OK", r("SET", "k", "v")
    assert_equal "v", r("GET", "k")
    assert_nil r("GET", "missing")
  end

  def test_set_with_expiry_and_ttl
    assert_equal "OK", r("SET", "k", "v", "EX", "100")
    ttl = r("TTL", "k")
    assert ttl.positive? && ttl <= 100
    assert_equal "OK", r("SET", "k", "v2", "KEEPTTL")
    assert r("TTL", "k").positive?
    assert_equal "OK", r("SET", "k", "v3")
    assert_equal(-1, r("TTL", "k"))
  end

  def test_set_nx_xx
    assert_equal "OK", r("SET", "k", "1", "NX")
    assert_nil r("SET", "k", "2", "NX")
    assert_equal "1", r("GET", "k")
    assert_equal "OK", r("SET", "k", "3", "XX")
    assert_nil r("SET", "missing", "x", "XX")
  end

  def test_set_get_option
    assert_nil r("SET", "k", "first", "GET")
    assert_equal "first", r("SET", "k", "second", "GET")
  end

  def test_append_and_strlen
    assert_equal 5, r("APPEND", "k", "hello")
    assert_equal 11, r("APPEND", "k", " world")
    assert_equal 11, r("STRLEN", "k")
    assert_equal "hello world", r("GET", "k")
  end

  def test_incr_decr
    assert_equal 1, r("INCR", "n")
    assert_equal 11, r("INCRBY", "n", "10")
    assert_equal 9, r("DECRBY", "n", "2")
    assert_equal 8, r("DECR", "n")
    r("SET", "bad", "abc")
    assert_error(/not an integer/, r("INCR", "bad"))
  end

  def test_incrbyfloat
    assert_equal "3.5", r("INCRBYFLOAT", "f", "3.5")
    assert_equal "4", r("INCRBYFLOAT", "f", "0.5")
  end

  def test_getrange_setrange
    r("SET", "k", "Hello World")
    assert_equal "Hello", r("GETRANGE", "k", "0", "4")
    assert_equal "World", r("GETRANGE", "k", "-5", "-1")
    assert_equal 11, r("SETRANGE", "k", "6", "Redis")
    assert_equal "Hello Redis", r("GET", "k")
  end

  def test_mset_mget
    assert_equal "OK", r("MSET", "a", "1", "b", "2", "c", "3")
    assert_equal %w[1 2 3], r("MGET", "a", "b", "c")
    assert_equal ["1", nil], r("MGET", "a", "missing")
    assert_equal 0, r("MSETNX", "a", "x", "d", "4")
    assert_equal 1, r("MSETNX", "e", "5", "f", "6")
  end

  def test_getdel
    r("SET", "k", "v")
    assert_equal "v", r("GETDEL", "k")
    assert_equal 0, r("EXISTS", "k")
  end

  def test_wrong_type
    r("LPUSH", "list", "x")
    assert_error(/WRONGTYPE/, r("GET", "list"))
  end
end

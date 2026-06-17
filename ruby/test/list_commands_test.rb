# typed: false
# frozen_string_literal: true

require_relative "test_helper"

class ListCommandsTest < ServerTest
  def test_push_pop
    assert_equal 3, r("RPUSH", "l", "a", "b", "c")
    assert_equal 4, r("LPUSH", "l", "z")
    assert_equal %w[z a b c], r("LRANGE", "l", "0", "-1")
    assert_equal "z", r("LPOP", "l")
    assert_equal "c", r("RPOP", "l")
    assert_equal 2, r("LLEN", "l")
  end

  def test_pop_count
    r("RPUSH", "l", "a", "b", "c", "d")
    assert_equal %w[a b], r("LPOP", "l", "2")
    assert_equal %w[d c], r("RPOP", "l", "2")
    assert_equal 0, r("EXISTS", "l")
  end

  def test_lpushx_rpushx
    assert_equal 0, r("LPUSHX", "l", "a")
    r("RPUSH", "l", "a")
    assert_equal 2, r("LPUSHX", "l", "z")
  end

  def test_index_set_insert
    r("RPUSH", "l", "a", "b", "c")
    assert_equal "b", r("LINDEX", "l", "1")
    assert_equal "c", r("LINDEX", "l", "-1")
    assert_equal "OK", r("LSET", "l", "1", "B")
    assert_equal 4, r("LINSERT", "l", "BEFORE", "c", "x")
    assert_equal %w[a B x c], r("LRANGE", "l", "0", "-1")
  end

  def test_lrem
    r("RPUSH", "l", "a", "b", "a", "c", "a")
    assert_equal 2, r("LREM", "l", "2", "a")
    assert_equal %w[b c a], r("LRANGE", "l", "0", "-1")
  end

  def test_ltrim
    r("RPUSH", "l", "a", "b", "c", "d", "e")
    assert_equal "OK", r("LTRIM", "l", "1", "3")
    assert_equal %w[b c d], r("LRANGE", "l", "0", "-1")
  end

  def test_lmove
    r("RPUSH", "src", "a", "b", "c")
    assert_equal "c", r("LMOVE", "src", "dst", "RIGHT", "LEFT")
    assert_equal %w[c], r("LRANGE", "dst", "0", "-1")
    # src is now [a, b]; RPOPLPUSH pops the tail ("b") onto dst's head.
    assert_equal "b", r("RPOPLPUSH", "src", "dst")
  end

  def test_lpos
    r("RPUSH", "l", "a", "b", "c", "b", "b")
    assert_equal 1, r("LPOS", "l", "b")
    assert_equal [1, 3, 4], r("LPOS", "l", "b", "COUNT", "0")
    assert_equal 4, r("LPOS", "l", "b", "RANK", "-1")
  end

  def test_lmpop
    r("RPUSH", "l1", "a", "b")
    assert_equal ["l1", ["a"]], r("LMPOP", "2", "l0", "l1", "LEFT")
  end
end

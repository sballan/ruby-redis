# typed: false
# frozen_string_literal: true

require_relative "test_helper"

class KeysCommandsTest < ServerTest
  def test_del_exists_type
    r("SET", "a", "1")
    r("SET", "b", "2")
    assert_equal 1, r("EXISTS", "a")
    assert_equal 2, r("EXISTS", "a", "b")
    assert_equal 2, r("DEL", "a", "b")
    assert_equal 0, r("EXISTS", "a")
    r("RPUSH", "l", "x")
    assert_equal "list", r("TYPE", "l")
    assert_equal "none", r("TYPE", "missing")
  end

  def test_expire_persist
    r("SET", "k", "v")
    assert_equal 1, r("EXPIRE", "k", "100")
    assert r("TTL", "k").positive?
    assert_equal 1, r("PERSIST", "k")
    assert_equal(-1, r("TTL", "k"))
    assert_equal(-2, r("TTL", "missing"))
  end

  def test_expire_options
    r("SET", "k", "v")
    r("EXPIRE", "k", "100")
    assert_equal 0, r("EXPIRE", "k", "200", "NX")
    assert_equal 1, r("EXPIRE", "k", "200", "XX")
    assert_equal 1, r("EXPIRE", "k", "300", "GT")
    assert_equal 0, r("EXPIRE", "k", "100", "GT")
  end

  def test_negative_expire_deletes
    r("SET", "k", "v")
    assert_equal 1, r("EXPIRE", "k", "-1")
    assert_equal 0, r("EXISTS", "k")
  end

  def test_keys_pattern
    r("MSET", "one", "1", "two", "2", "three", "3")
    assert_equal %w[one], r("KEYS", "one")
    assert_equal %w[three two].sort, r("KEYS", "t*").sort
  end

  def test_rename
    r("SET", "a", "1")
    assert_equal "OK", r("RENAME", "a", "b")
    assert_equal "1", r("GET", "b")
    assert_error(/no such key/, r("RENAME", "missing", "x"))
    r("SET", "c", "3")
    assert_equal 0, r("RENAMENX", "b", "c")
  end

  def test_copy_and_move
    r("SET", "src", "v")
    assert_equal 1, r("COPY", "src", "dst")
    assert_equal "v", r("GET", "dst")
    assert_equal 0, r("COPY", "src", "dst")
    assert_equal 1, r("COPY", "src", "dst", "REPLACE")
    assert_equal 1, r("MOVE", "src", "1")
    assert_equal 0, r("EXISTS", "src")
  end

  def test_scan
    20.times { |i| r("SET", "key:#{i}", i.to_s) }
    seen = []
    cursor = "0"
    loop do
      cursor, batch = r("SCAN", cursor, "COUNT", "5")
      seen.concat(batch)
      break if cursor == "0"
    end
    assert_equal 20, seen.uniq.size
  end

  def test_object_encoding_strings
    r("SET", "n", "12345")
    assert_equal "int", r("OBJECT", "ENCODING", "n")
    r("SET", "s", "hello")
    assert_equal "embstr", r("OBJECT", "ENCODING", "s")
    r("SET", "big", "x" * 64)
    assert_equal "raw", r("OBJECT", "ENCODING", "big")
  end

  def test_object_encoding_list_transition
    r("RPUSH", "l", "x")
    assert_equal "listpack", r("OBJECT", "ENCODING", "l")
    r("RPUSH", "l", "y" * 65) # element over 64 bytes forces quicklist
    assert_equal "quicklist", r("OBJECT", "ENCODING", "l")
  end

  def test_object_encoding_set_transition
    r("SADD", "ints", "1", "2", "3")
    assert_equal "intset", r("OBJECT", "ENCODING", "ints")
    r("SADD", "ints", "hello") # a non-integer member drops intset
    assert_equal "listpack", r("OBJECT", "ENCODING", "ints")
    130.times { |i| r("SADD", "big", "m#{i}") }
    assert_equal "hashtable", r("OBJECT", "ENCODING", "big")
  end

  def test_object_encoding_hash_transition
    r("HSET", "h", "f", "v")
    assert_equal "listpack", r("OBJECT", "ENCODING", "h")
    r("HSET", "h", "f2", "z" * 65)
    assert_equal "hashtable", r("OBJECT", "ENCODING", "h")
  end

  def test_object_encoding_zset_transition
    r("ZADD", "z", "1", "a")
    assert_equal "listpack", r("OBJECT", "ENCODING", "z")
    r("ZADD", "z", "2", "b" * 65)
    assert_equal "skiplist", r("OBJECT", "ENCODING", "z")
  end
end

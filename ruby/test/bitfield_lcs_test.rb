# typed: false
# frozen_string_literal: true

require_relative "test_helper"

class BitfieldLcsTest < ServerTest
  # --- BITFIELD ----------------------------------------------------------

  def test_bitfield_set_and_get
    assert_equal [0], r("BITFIELD", "bf", "SET", "u8", "0", "255")
    assert_equal [255], r("BITFIELD", "bf", "GET", "u8", "0")
  end

  def test_bitfield_field_offset
    r("BITFIELD", "bf", "SET", "u8", "0", "255")
    assert_equal [255, 10], r("BITFIELD", "bf", "SET", "u8", "#0", "10", "GET", "u8", "#0")
  end

  def test_bitfield_incrby_wrap
    assert_equal [255, 9], r("BITFIELD", "k", "INCRBY", "u8", "0", "255", "INCRBY", "u8", "0", "10")
  end

  def test_bitfield_overflow_sat
    assert_equal [255], r("BITFIELD", "k2", "OVERFLOW", "SAT", "INCRBY", "u8", "0", "300")
    assert_equal [255], r("BITFIELD", "k2", "OVERFLOW", "SAT", "INCRBY", "u8", "0", "100")
  end

  def test_bitfield_overflow_fail
    assert_equal [0, nil], r("BITFIELD", "k3", "SET", "u8", "0", "255", "OVERFLOW", "FAIL", "INCRBY", "u8", "0", "10")
  end

  def test_bitfield_signed
    assert_equal [0, -128], r("BITFIELD", "s", "SET", "i8", "0", "-128", "GET", "i8", "0")
    assert_equal [-128], r("BITFIELD", "s", "OVERFLOW", "SAT", "INCRBY", "i8", "0", "-1")
  end

  def test_bitfield_invalid_type
    assert_error(/Invalid bitfield type/, r("BITFIELD", "x", "GET", "u64", "0"))
  end

  def test_bitfield_ro_rejects_writes
    assert_error(/BITFIELD_RO only supports the GET/, r("BITFIELD_RO", "x", "SET", "u8", "0", "1"))
  end

  def test_bitfield_ro_get
    r("BITFIELD", "ro", "SET", "u8", "0", "42")
    assert_equal [42], r("BITFIELD_RO", "ro", "GET", "u8", "0")
  end

  def test_bitfield_pure_get_does_not_create_key
    assert_equal [0], r("BITFIELD", "nokey", "GET", "u8", "0")
    assert_equal 0, r("EXISTS", "nokey")
  end

  # --- LCS ---------------------------------------------------------------

  def setup_lcs
    r("MSET", "key1", "ohmytext", "key2", "mynewtext")
  end

  def test_lcs_basic
    setup_lcs
    assert_equal "mytext", r("LCS", "key1", "key2")
  end

  def test_lcs_len
    setup_lcs
    assert_equal 6, r("LCS", "key1", "key2", "LEN")
  end

  def test_lcs_idx
    setup_lcs
    reply = r("LCS", "key1", "key2", "IDX")
    # RESP2 downgrades Reply::Map to a flat array: ["matches", [...], "len", 6]
    assert_equal "matches", reply[0]
    assert_equal "len", reply[2]
    assert_equal 6, reply[3]
    matches = reply[1]
    assert_equal [[[4, 7], [5, 8]], [[2, 3], [0, 1]]], matches
  end

  def test_lcs_idx_minmatchlen
    setup_lcs
    reply = r("LCS", "key1", "key2", "IDX", "MINMATCHLEN", "4")
    assert_equal [[[4, 7], [5, 8]]], reply[1]
  end

  def test_lcs_idx_withmatchlen
    setup_lcs
    reply = r("LCS", "key1", "key2", "IDX", "WITHMATCHLEN")
    assert_equal [[[4, 7], [5, 8], 4], [[2, 3], [0, 1], 2]], reply[1]
  end

  def test_lcs_len_and_idx_conflict
    setup_lcs
    assert_error(/just use IDX/, r("LCS", "key1", "key2", "LEN", "IDX"))
  end

  def test_lcs_wrong_type
    r("RPUSH", "l", "a")
    assert_error(/WRONGTYPE/, r("LCS", "l", "key2"))
  end
end

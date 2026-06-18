# typed: false
# frozen_string_literal: true

require_relative "test_helper"

class HyperLogLogTest < ServerTest
  def test_pfadd_return_values
    assert_equal 1, r("PFADD", "hll", "a", "b", "c")
    # Re-adding the same elements changes nothing.
    assert_equal 0, r("PFADD", "hll", "a", "b", "c")
    # A new element does change a register.
    assert_equal 1, r("PFADD", "hll", "d")
  end

  def test_pfadd_creates_key
    # PFADD with no elements on a missing key still creates the HLL.
    assert_equal 1, r("PFADD", "fresh")
    assert_equal 0, r("PFCOUNT", "fresh")
    assert_equal 1, r("EXISTS", "fresh")
  end

  def test_pfcount_empty_and_absent
    assert_equal 0, r("PFCOUNT", "missing")
    r("PFADD", "empty")
    assert_equal 0, r("PFCOUNT", "empty")
  end

  def test_pfcount_approximation
    1000.times { |i| r("PFADD", "big", "elem#{i}") }
    count = r("PFCOUNT", "big")
    assert (count - 1000).abs < 30, "expected ~1000, got #{count}"
  end

  def test_pfcount_stable_on_duplicates
    1000.times { |i| r("PFADD", "dup", "elem#{i}") }
    first = r("PFCOUNT", "dup")
    1000.times { |i| r("PFADD", "dup", "elem#{i}") }
    second = r("PFCOUNT", "dup")
    assert_equal first, second
  end

  def test_pfcount_uses_cache
    100.times { |i| r("PFADD", "cached", "e#{i}") }
    first = r("PFCOUNT", "cached")
    # Second call should hit the cached value and return the same number.
    assert_equal first, r("PFCOUNT", "cached")
  end

  def test_pfmerge
    500.times { |i| r("PFADD", "hll1", "v#{i}") }       # 0..499
    (250...750).each { |i| r("PFADD", "hll2", "v#{i}") } # 250..749
    assert_equal "OK", r("PFMERGE", "dest", "hll1", "hll2")
    count = r("PFCOUNT", "dest")
    # Union is 0..749 == 750 distinct.
    assert ((count - 750).abs).to_f / 750 < 0.03, "expected ~750, got #{count}"
  end

  def test_pfmerge_into_existing_dest
    250.times { |i| r("PFADD", "dest", "v#{i}") }        # 0..249 already in dest
    (200...600).each { |i| r("PFADD", "src", "v#{i}") }   # 200..599
    assert_equal "OK", r("PFMERGE", "dest", "src")
    count = r("PFCOUNT", "dest")
    # Union is 0..599 == 600 distinct.
    assert ((count - 600).abs).to_f / 600 < 0.03, "expected ~600, got #{count}"
  end

  def test_pfcount_multiple_keys
    500.times { |i| r("PFADD", "hll1", "v#{i}") }
    (250...750).each { |i| r("PFADD", "hll2", "v#{i}") }
    count = r("PFCOUNT", "hll1", "hll2")
    assert ((count - 750).abs).to_f / 750 < 0.03, "expected ~750, got #{count}"
    # Multi-key PFCOUNT must not mutate the inputs.
    assert ((r("PFCOUNT", "hll1") - 500).abs) < 20
  end

  def test_pfcount_multiple_keys_with_absent
    300.times { |i| r("PFADD", "present", "v#{i}") }
    count = r("PFCOUNT", "present", "nope")
    assert ((count - 300).abs).to_f / 300 < 0.03, "expected ~300, got #{count}"
  end

  def test_wrongtype_on_plain_string
    r("SET", "foo", "bar")
    assert_error(/WRONGTYPE/, r("PFADD", "foo", "x"))
    assert_error(/WRONGTYPE/, r("PFCOUNT", "foo"))
    assert_error(/WRONGTYPE/, r("PFMERGE", "dst", "foo"))
  end

  def test_wrongtype_on_list
    r("LPUSH", "list", "x")
    assert_error(/WRONGTYPE/, r("PFADD", "list", "x"))
    assert_error(/WRONGTYPE/, r("PFCOUNT", "list"))
  end

  def test_type_is_string
    r("PFADD", "hll", "a", "b", "c")
    assert_equal "string", r("TYPE", "hll")
  end

  def test_pfcount_after_merge_matches_manual
    100.times { |i| r("PFADD", "a", "x#{i}") }
    (50...150).each { |i| r("PFADD", "b", "x#{i}") } # union 0..149 = 150
    r("PFMERGE", "merged", "a", "b")
    direct = r("PFCOUNT", "a", "b")
    merged = r("PFCOUNT", "merged")
    # Merge result and direct multi-key count should agree exactly: same
    # register max-merge produces an identical sketch.
    assert_equal direct, merged
  end
end

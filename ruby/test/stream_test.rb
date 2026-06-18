# typed: false
# frozen_string_literal: true

require_relative "test_helper"

class StreamTest < ServerTest
  # Spawn a command on its own connection so blocking calls can be awaited.
  def async(*args)
    client = @harness.client
    Thread.new { client.call(*args) }
  end

  def wait_for_blocked(count, timeout: 3)
    deadline = Time.now + timeout
    loop do
      blocked = r("INFO", "clients")[/blocked_clients:(\d+)/, 1].to_i
      return if blocked >= count
      raise "timed out waiting for #{count} blocked clients (saw #{blocked})" if Time.now > deadline

      sleep 0.01
    end
  end

  def finish(thread)
    assert thread.join(5), "blocking call did not complete in time"
    thread.value
  end

  # --- XADD / XLEN / TYPE ------------------------------------------------

  def test_xadd_explicit_ids_and_xlen
    assert_equal "1-1", r("XADD", "s", "1-1", "a", "1")
    assert_equal "1-2", r("XADD", "s", "1-2", "b", "2")
    assert_equal "2-0", r("XADD", "s", "2-0", "c", "3")
    assert_equal 3, r("XLEN", "s")
    assert_equal "stream", r("TYPE", "s")
    assert_equal "stream", r("OBJECT", "ENCODING", "s")
  end

  def test_xadd_autogenerates_increasing_ids
    id1 = r("XADD", "s", "*", "a", "1")
    id2 = r("XADD", "s", "*", "b", "2")
    assert_match(/\A\d+-\d+\z/, id1)
    assert_match(/\A\d+-\d+\z/, id2)
    ms1, seq1 = id1.split("-").map(&:to_i)
    ms2, seq2 = id2.split("-").map(&:to_i)
    assert((([ms2, seq2] <=> [ms1, seq1]) == 1), "second id must be greater")
  end

  def test_xadd_partial_id_autoseq
    assert_equal "5-0", r("XADD", "s", "5-*", "a", "1")
    assert_equal "5-1", r("XADD", "s", "5-*", "b", "2")
    assert_equal "5-2", r("XADD", "s", "5", "c", "3")
  end

  def test_xadd_rejects_non_increasing
    r("XADD", "s", "5-5", "a", "1")
    assert_error(/equal or smaller/, r("XADD", "s", "5-5", "b", "2"))
    assert_error(/equal or smaller/, r("XADD", "s", "1-1", "b", "2"))
    assert_error(/must be greater than 0-0/, r("XADD", "x", "0-0", "b", "2"))
  end

  def test_xadd_nomkstream
    assert_nil r("XADD", "missing", "NOMKSTREAM", "*", "a", "1")
    assert_equal 0, r("EXISTS", "missing")
  end

  def test_xadd_wrong_args
    assert_error(/wrong number/, r("XADD", "s", "*", "field"))
  end

  # --- XRANGE / XREVRANGE ------------------------------------------------

  def setup_three
    r("XADD", "s", "1-1", "a", "1")
    r("XADD", "s", "1-2", "b", "2")
    r("XADD", "s", "2-0", "c", "3")
  end

  def test_xrange_full
    setup_three
    assert_equal([["1-1", %w[a 1]], ["1-2", %w[b 2]], ["2-0", %w[c 3]]], r("XRANGE", "s", "-", "+"))
  end

  def test_xrange_partial_id_bounds
    setup_three
    # bare "1" => start 1-0, end 1-MAX, so both ms==1 entries.
    assert_equal([["1-1", %w[a 1]], ["1-2", %w[b 2]]], r("XRANGE", "s", "1", "1"))
  end

  def test_xrange_count_and_exclusive
    setup_three
    assert_equal([["1-1", %w[a 1]]], r("XRANGE", "s", "-", "+", "COUNT", "1"))
    # exclusive start drops 1-1.
    assert_equal([["1-2", %w[b 2]], ["2-0", %w[c 3]]], r("XRANGE", "s", "(1-1", "+"))
  end

  def test_xrevrange
    setup_three
    assert_equal([["2-0", %w[c 3]], ["1-2", %w[b 2]], ["1-1", %w[a 1]]], r("XREVRANGE", "s", "+", "-"))
    assert_equal([["2-0", %w[c 3]]], r("XREVRANGE", "s", "+", "-", "COUNT", "1"))
  end

  # --- XDEL / XTRIM ------------------------------------------------------

  def test_xdel
    setup_three
    assert_equal 1, r("XDEL", "s", "1-2")
    assert_equal 0, r("XDEL", "s", "9-9")
    assert_equal 2, r("XLEN", "s")
    assert_equal 1, r("EXISTS", "s") # streams persist even when emptied
  end

  def test_xtrim_maxlen
    setup_three
    assert_equal 2, r("XTRIM", "s", "MAXLEN", "1")
    assert_equal 1, r("XLEN", "s")
    assert_equal([["2-0", %w[c 3]]], r("XRANGE", "s", "-", "+"))
  end

  def test_xtrim_minid
    setup_three
    assert_equal 1, r("XTRIM", "s", "MINID", "1-2")
    assert_equal([["1-2", %w[b 2]], ["2-0", %w[c 3]]], r("XRANGE", "s", "-", "+"))
  end

  def test_xadd_with_maxlen
    r("XADD", "s", "MAXLEN", "2", "1-1", "a", "1")
    r("XADD", "s", "MAXLEN", "2", "1-2", "b", "2")
    r("XADD", "s", "MAXLEN", "2", "1-3", "c", "3")
    assert_equal 2, r("XLEN", "s")
    assert_equal([["1-2", %w[b 2]], ["1-3", %w[c 3]]], r("XRANGE", "s", "-", "+"))
  end

  # --- XSETID ------------------------------------------------------------

  def test_xsetid
    r("XADD", "k", "5-5", "a", "1")
    assert_equal "OK", r("XSETID", "k", "10-0")
    assert_equal "10-1", r("XADD", "k", "10-1", "b", "2")
    assert_error(/smaller than the target stream top item/, r("XSETID", "k", "1-0"))
    assert_error(/requires the key to exist/, r("XSETID", "nope", "1-0"))
  end

  # --- XREAD -------------------------------------------------------------

  def test_xread_basic
    r("XADD", "st", "1-1", "a", "1")
    r("XADD", "st", "2-2", "b", "2")
    assert_equal([["st", [["1-1", %w[a 1]], ["2-2", %w[b 2]]]]], r("XREAD", "STREAMS", "st", "0"))
    assert_equal([["st", [["2-2", %w[b 2]]]]], r("XREAD", "STREAMS", "st", "1-1"))
    assert_nil r("XREAD", "STREAMS", "st", "2-2")
    assert_equal([["st", [["1-1", %w[a 1]]]]], r("XREAD", "COUNT", "1", "STREAMS", "st", "0"))
  end

  def test_xread_multiple_streams
    r("XADD", "a", "1-1", "x", "1")
    r("XADD", "b", "1-1", "y", "2")
    assert_equal([["a", [["1-1", %w[x 1]]]], ["b", [["1-1", %w[y 2]]]]],
                 r("XREAD", "STREAMS", "a", "b", "0", "0"))
  end

  def test_xread_block_wakes_on_xadd
    blocker = async("XREAD", "BLOCK", "0", "STREAMS", "bs", "$")
    wait_for_blocked(1)
    r("XADD", "bs", "1-1", "field", "value")
    assert_equal([["bs", [["1-1", %w[field value]]]]], finish(blocker))
  end

  def test_xread_block_times_out
    assert_nil r("XREAD", "BLOCK", "50", "STREAMS", "bs", "$")
  end

  # --- Consumer groups ---------------------------------------------------

  def setup_group
    r("XADD", "ms", "1-1", "field", "v1")
    r("XADD", "ms", "2-2", "field", "v2")
    r("XGROUP", "CREATE", "ms", "g1", "0")
  end

  def test_xgroup_create_errors
    assert_error(/requires the key to exist/, r("XGROUP", "CREATE", "nope", "g", "0"))
    assert_equal "OK", r("XGROUP", "CREATE", "nope", "g", "0", "MKSTREAM")
    assert_equal "stream", r("TYPE", "nope")
    assert_error(/BUSYGROUP/, r("XGROUP", "CREATE", "nope", "g", "0"))
  end

  def test_xreadgroup_new_and_pending
    setup_group
    res = r("XREADGROUP", "GROUP", "g1", "c1", "COUNT", "10", "STREAMS", "ms", ">")
    assert_equal([["ms", [["1-1", %w[field v1]], ["2-2", %w[field v2]]]]], res)
    # Second ">" read sees nothing new.
    assert_nil r("XREADGROUP", "GROUP", "g1", "c1", "STREAMS", "ms", ">")
    # History replay from the consumer's PEL.
    assert_equal([["ms", [["1-1", %w[field v1]], ["2-2", %w[field v2]]]]],
                 r("XREADGROUP", "GROUP", "g1", "c1", "STREAMS", "ms", "0"))
  end

  def test_xack_and_xpending_summary
    setup_group
    r("XREADGROUP", "GROUP", "g1", "c1", "STREAMS", "ms", ">")
    assert_equal([2, "1-1", "2-2", [%w[c1 2]]], r("XPENDING", "ms", "g1"))
    assert_equal 1, r("XACK", "ms", "g1", "1-1")
    assert_equal 0, r("XACK", "ms", "g1", "1-1")
    assert_equal([1, "2-2", "2-2", [%w[c1 1]]], r("XPENDING", "ms", "g1"))
  end

  def test_xpending_extended
    setup_group
    r("XREADGROUP", "GROUP", "g1", "c1", "STREAMS", "ms", ">")
    rows = r("XPENDING", "ms", "g1", "-", "+", "10")
    assert_equal 2, rows.length
    id, consumer, _idle, delivery_count = rows[0]
    assert_equal "1-1", id
    assert_equal "c1", consumer
    assert_equal 1, delivery_count
  end

  def test_xclaim
    setup_group
    r("XREADGROUP", "GROUP", "g1", "c1", "STREAMS", "ms", ">")
    claimed = r("XCLAIM", "ms", "g1", "c2", "0", "2-2")
    assert_equal([["2-2", %w[field v2]]], claimed)
    # Now 2-2 belongs to c2.
    rows = r("XPENDING", "ms", "g1", "-", "+", "10", "c2")
    assert_equal 1, rows.length
    assert_equal "2-2", rows[0][0]
    # JUSTID form returns only ids.
    assert_equal(["1-1"], r("XCLAIM", "ms", "g1", "c2", "0", "1-1", "JUSTID"))
  end

  def test_xautoclaim
    setup_group
    r("XREADGROUP", "GROUP", "g1", "c1", "STREAMS", "ms", ">")
    cursor, claimed, deleted = r("XAUTOCLAIM", "ms", "g1", "c2", "0", "0")
    assert_equal "0-0", cursor
    assert_equal([["1-1", %w[field v1]], ["2-2", %w[field v2]]], claimed)
    assert_equal [], deleted
  end

  def test_xgroup_consumer_management
    setup_group
    assert_equal 1, r("XGROUP", "CREATECONSUMER", "ms", "g1", "c9")
    assert_equal 0, r("XGROUP", "CREATECONSUMER", "ms", "g1", "c9")
    r("XREADGROUP", "GROUP", "g1", "c1", "STREAMS", "ms", ">")
    assert_equal 2, r("XGROUP", "DELCONSUMER", "ms", "g1", "c1") # 2 pending removed
    assert_equal 1, r("XGROUP", "DESTROY", "ms", "g1")
    assert_equal 0, r("XGROUP", "DESTROY", "ms", "g1")
  end

  def test_xreadgroup_nogroup_error
    r("XADD", "ms", "1-1", "f", "v")
    assert_error(/NOGROUP/, r("XREADGROUP", "GROUP", "nope", "c", "STREAMS", "ms", ">"))
  end

  # --- XINFO -------------------------------------------------------------

  def test_xinfo_stream
    setup_three
    info = Hash[*r("XINFO", "STREAM", "s")]
    assert_equal 3, info["length"]
    assert_equal "2-0", info["last-generated-id"]
    assert_equal 3, info["entries-added"]
    assert_equal(["1-1", %w[a 1]], info["first-entry"])
    assert_equal(["2-0", %w[c 3]], info["last-entry"])
  end

  def test_xinfo_groups_and_consumers
    setup_group
    r("XREADGROUP", "GROUP", "g1", "c1", "STREAMS", "ms", ">")
    groups = r("XINFO", "GROUPS", "ms")
    assert_equal 1, groups.length
    g = Hash[*groups[0]]
    assert_equal "g1", g["name"]
    assert_equal 1, g["consumers"]
    assert_equal 2, g["pending"]

    consumers = r("XINFO", "CONSUMERS", "ms", "g1")
    assert_equal 1, consumers.length
    c = Hash[*consumers[0]]
    assert_equal "c1", c["name"]
    assert_equal 2, c["pending"]
  end

  # --- Persistence -------------------------------------------------------

  def test_stream_survives_reload
    setup_group
    r("XREADGROUP", "GROUP", "g1", "c1", "STREAMS", "ms", ">")
    r("XACK", "ms", "g1", "1-1")
    r("DEBUG", "RELOAD")
    assert_equal 2, r("XLEN", "ms")
    assert_equal([["1-1", %w[field v1]], ["2-2", %w[field v2]]], r("XRANGE", "ms", "-", "+"))
    # Group + PEL survived: one message (2-2) still pending for c1.
    assert_equal([1, "2-2", "2-2", [%w[c1 1]]], r("XPENDING", "ms", "g1"))
  end

  # --- WRONGTYPE ---------------------------------------------------------

  def test_wrongtype
    r("SET", "str", "x")
    assert_error(/WRONGTYPE/, r("XADD", "str", "*", "a", "1"))
    assert_error(/WRONGTYPE/, r("XLEN", "str"))
  end
end

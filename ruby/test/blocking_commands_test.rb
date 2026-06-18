# typed: false
# frozen_string_literal: true

require_relative "test_helper"

class BlockingCommandsTest < ServerTest
  # --- Helpers -----------------------------------------------------------

  # Spawn a command on its own connection in a background thread. Thread#value
  # returns the reply once the call completes.
  def async(*args)
    client = @harness.client
    Thread.new { client.call(*args) }
  end

  # Block until the server reports at least +count+ blocked clients, so tests
  # don't race the parking of a connection.
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

  # --- Immediate (non-blocking) paths ------------------------------------

  def test_blpop_brpop_immediate
    r("RPUSH", "l", "a", "b", "c")
    assert_equal ["l", "a"], r("BLPOP", "l", "0")
    assert_equal ["l", "c"], r("BRPOP", "l", "0")
    assert_equal 1, r("LLEN", "l")
  end

  def test_blmove_brpoplpush_immediate
    r("RPUSH", "s", "a", "b")
    # BLMOVE moves "a" onto d's tail; BRPOPLPUSH moves "b" onto d's head.
    assert_equal "a", r("BLMOVE", "s", "d", "LEFT", "RIGHT", "0")
    assert_equal "b", r("BRPOPLPUSH", "s", "d", "0")
    assert_equal %w[b a], r("LRANGE", "d", "0", "-1")
    assert_equal 0, r("EXISTS", "s")
  end

  def test_blmpop_immediate
    r("RPUSH", "l1", "a", "b")
    assert_equal ["l1", ["a"]], r("BLMPOP", "0", "2", "l0", "l1", "LEFT")
  end

  def test_bzpop_immediate
    r("ZADD", "z", "1", "a", "2", "b")
    assert_equal ["z", "a", "1"], r("BZPOPMIN", "z", "0")
    assert_equal ["z", "b", "2"], r("BZPOPMAX", "z", "0")
    assert_equal 0, r("EXISTS", "z")
  end

  def test_bzmpop_immediate
    r("ZADD", "z", "1", "a", "2", "b")
    assert_equal ["z", [["a", "1"]]], r("BZMPOP", "0", "1", "z", "MIN")
  end

  # --- Blocking then woken by another client -----------------------------

  def test_blpop_woken_by_push
    waiter = async("BLPOP", "k", "5")
    wait_for_blocked(1)
    assert_equal 1, r("RPUSH", "k", "v")
    assert_equal ["k", "v"], finish(waiter)
    assert_equal 0, r("EXISTS", "k")
  end

  def test_brpop_woken_by_push
    waiter = async("BRPOP", "k", "5")
    wait_for_blocked(1)
    r("LPUSH", "k", "v")
    assert_equal ["k", "v"], finish(waiter)
  end

  def test_blpop_multiple_keys_served_from_ready_one
    waiter = async("BLPOP", "ka", "kb", "5")
    wait_for_blocked(1)
    r("RPUSH", "kb", "v")
    assert_equal ["kb", "v"], finish(waiter)
  end

  def test_blpop_fifo_order
    first = async("BLPOP", "q", "5")
    wait_for_blocked(1)
    second = async("BLPOP", "q", "5")
    wait_for_blocked(2)

    r("RPUSH", "q", "one")
    assert_equal ["q", "one"], finish(first)

    r("RPUSH", "q", "two")
    assert_equal ["q", "two"], finish(second)
  end

  def test_blmove_woken_by_push
    waiter = async("BLMOVE", "src", "dst", "LEFT", "RIGHT", "5")
    wait_for_blocked(1)
    r("RPUSH", "src", "x")
    assert_equal "x", finish(waiter)
    assert_equal ["x"], r("LRANGE", "dst", "0", "-1")
  end

  def test_blmpop_woken_by_push
    waiter = async("BLMPOP", "5", "2", "l0", "l1", "LEFT")
    wait_for_blocked(1)
    r("RPUSH", "l1", "a", "b")
    assert_equal ["l1", ["a"]], finish(waiter)
  end

  def test_bzpopmin_woken_by_zadd
    waiter = async("BZPOPMIN", "z", "5")
    wait_for_blocked(1)
    r("ZADD", "z", "7", "m")
    assert_equal ["z", "m", "7"], finish(waiter)
  end

  # --- Timeouts ----------------------------------------------------------

  def test_blpop_timeout_returns_null
    started = Time.now
    assert_nil r("BLPOP", "missing", "0.1")
    assert_operator Time.now - started, :>=, 0.05
  end

  def test_blmove_timeout_returns_null
    assert_nil r("BLMOVE", "missing", "dst", "LEFT", "RIGHT", "0.1")
  end

  def test_bzpopmin_timeout_returns_null
    assert_nil r("BZPOPMIN", "missing", "0.1")
  end

  # --- WAIT --------------------------------------------------------------

  def test_wait_no_replicas_returns_zero
    assert_equal 0, r("WAIT", "0", "100")
  end

  def test_wait_times_out_when_replicas_unreachable
    started = Time.now
    assert_equal 0, r("WAIT", "1", "100")
    assert_operator Time.now - started, :>=, 0.05
  end

  # --- Errors and transaction semantics ----------------------------------

  def test_blpop_wrong_type_is_immediate_error
    r("SET", "k", "v")
    assert_error(/WRONGTYPE/, r("BLPOP", "k", "0"))
  end

  def test_timeout_validation
    assert_error(/timeout is not a float/, r("BLPOP", "k", "notanumber"))
    assert_error(/timeout is negative/, r("BLPOP", "k", "-1"))
  end

  def test_blpop_in_multi_does_not_block
    assert_equal "OK", r("MULTI")
    assert_equal "QUEUED", r("BLPOP", "missing", "0")
    assert_equal [nil], r("EXEC")
  end

  def test_blpop_in_multi_returns_available_data
    r("RPUSH", "l", "a")
    assert_equal "OK", r("MULTI")
    assert_equal "QUEUED", r("BLPOP", "l", "0")
    assert_equal [["l", "a"]], r("EXEC")
  end

  def test_info_reports_blocked_clients
    assert_match(/blocked_clients:0/, r("INFO", "clients"))
    waiter = async("BLPOP", "k", "5")
    wait_for_blocked(1)
    assert_match(/blocked_clients:1/, r("INFO", "clients"))
    r("RPUSH", "k", "v")
    finish(waiter)
  end
end

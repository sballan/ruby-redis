# typed: false
# frozen_string_literal: true

require_relative "test_helper"

class TransactionsTest < ServerTest
  def test_multi_exec
    assert_equal "OK", r("MULTI")
    assert_equal "QUEUED", r("SET", "k", "1")
    assert_equal "QUEUED", r("INCR", "k")
    assert_equal ["OK", 2], r("EXEC")
    assert_equal "2", r("GET", "k")
  end

  def test_discard
    r("MULTI")
    r("SET", "k", "1")
    assert_equal "OK", r("DISCARD")
    assert_equal 0, r("EXISTS", "k")
  end

  def test_exec_without_multi
    assert_error(/EXEC without MULTI/, r("EXEC"))
  end

  def test_queued_error_aborts
    r("MULTI")
    assert_error(/unknown command/, r("NOTACOMMAND"))
    assert_error(/EXECABORT/, r("EXEC"))
  end

  def test_watch_abort
    r("SET", "k", "1")
    watcher = @client
    other = @harness.client

    watcher.call("WATCH", "k")
    watcher.call("MULTI")
    watcher.call("INCR", "k")
    other.call("SET", "k", "100")
    assert_nil watcher.call("EXEC")
    assert_equal "100", r("GET", "k")
  end
end

class PubSubTest < ServerTest
  def test_publish_subscribe
    subscriber = @harness.client
    assert_equal ["subscribe", "news", 1], subscriber.call("SUBSCRIBE", "news")

    publisher = @harness.client
    assert_equal 1, publisher.call("PUBLISH", "news", "hello")

    assert_equal ["message", "news", "hello"], subscriber.read
  end

  def test_pattern_subscribe
    subscriber = @harness.client
    subscriber.call("PSUBSCRIBE", "ne*")

    publisher = @harness.client
    assert_equal 1, publisher.call("PUBLISH", "news", "hi")
    assert_equal ["pmessage", "ne*", "news", "hi"], subscriber.read
  end

  def test_pubsub_channels
    subscriber = @harness.client
    subscriber.call("SUBSCRIBE", "a", "b")
    assert_equal %w[a b], r("PUBSUB", "CHANNELS").sort
    assert_equal ["a", 1], r("PUBSUB", "NUMSUB", "a")
  end
end

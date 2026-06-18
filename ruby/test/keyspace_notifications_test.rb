# typed: false
# frozen_string_literal: true

require_relative "test_helper"

class KeyspaceNotificationsTest < ServerTest
  # K = keyspace, E = keyevent, A = all event classes.
  def server_config = { "notify-keyspace-events" => "KEA" }

  # Open a fresh connection subscribed to +channel+ and consume the confirmation.
  def subscribe(channel)
    sub = @harness.client
    assert_equal ["subscribe", channel, 1], sub.call("SUBSCRIBE", channel)
    sub
  end

  def test_keyevent_on_set
    sub = subscribe("__keyevent@0__:set")
    r("SET", "foo", "bar")
    assert_equal ["message", "__keyevent@0__:set", "foo"], sub.read
  end

  def test_keyspace_carries_event_name
    sub = subscribe("__keyspace@0__:foo")
    r("SET", "foo", "bar")
    assert_equal ["message", "__keyspace@0__:foo", "set"], sub.read
  end

  def test_del_emits_generic_event
    r("SET", "foo", "bar")
    sub = subscribe("__keyevent@0__:del")
    r("DEL", "foo")
    assert_equal ["message", "__keyevent@0__:del", "foo"], sub.read
  end

  def test_type_specific_event_names
    sub = subscribe("__keyspace@0__:mylist")
    r("RPUSH", "mylist", "a")
    assert_equal ["message", "__keyspace@0__:mylist", "rpush"], sub.read
  end

  def test_event_alias_for_incr
    sub = subscribe("__keyevent@0__:incrby")
    r("INCR", "counter")
    assert_equal ["message", "__keyevent@0__:incrby", "counter"], sub.read
  end

  def test_expired_event
    sub = subscribe("__keyevent@0__:expired")
    r("SET", "k", "v")
    r("PEXPIRE", "k", "5")
    sleep 0.05
    r("EXISTS", "k") # lazy expiry fires the expired event
    assert_equal ["message", "__keyevent@0__:expired", "k"], sub.read
  end

  def test_disabled_suppresses_events
    sub = subscribe("__keyevent@0__:set")
    r("CONFIG", "SET", "notify-keyspace-events", "")
    r("SET", "suppressed", "1") # must NOT produce an event
    r("CONFIG", "SET", "notify-keyspace-events", "KEA")
    r("SET", "delivered", "1") # the first event the subscriber should see
    assert_equal ["message", "__keyevent@0__:set", "delivered"], sub.read
  end

  def test_class_filtering
    # Only string ($) + keyevent enabled: list events are filtered out, string
    # events still flow.
    r("CONFIG", "SET", "notify-keyspace-events", "E$")
    sub = subscribe("__keyevent@0__:set")
    r("RPUSH", "alist", "x") # list class disabled -> no event
    r("SET", "astr", "y")    # string class enabled -> delivered
    assert_equal ["message", "__keyevent@0__:set", "astr"], sub.read
  end
end

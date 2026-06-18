# typed: false
# frozen_string_literal: true

require_relative "test_helper"

class ProtocolTest < Minitest::Test
  include RedisRuby

  def encode(value, protocol)
    out = +"".b
    Protocol.encode(out, value, protocol)
    out
  end

  def test_encodes_core_resp2_types
    assert_equal "$3\r\nfoo\r\n".b, encode("foo", 2)
    assert_equal ":42\r\n".b, encode(42, 2)
    assert_equal "$-1\r\n".b, encode(nil, 2)
    assert_equal "*2\r\n:1\r\n:2\r\n".b, encode([1, 2], 2)
    assert_equal "+OK\r\n".b, encode(Reply::OK, 2)
    assert_equal "-ERR boom\r\n".b, encode(Reply::Error.new("ERR boom"), 2)
  end

  def test_resp3_downgrades_for_resp2
    assert_equal "_\r\n".b, encode(nil, 3)
    assert_equal "#t\r\n".b, encode(Reply::Boolean.new(true), 3)
    assert_equal ":1\r\n".b, encode(Reply::Boolean.new(true), 2)
    assert_equal ",3.14\r\n".b, encode(Reply::Double.new(3.14), 3)
    assert_equal "$4\r\n3.14\r\n".b, encode(Reply::Double.new(3.14), 2)
  end

  def test_map_encoding_differs_by_protocol
    map = Reply::Map.new([["a", 1], ["b", 2]])
    assert_equal "%2\r\n$1\r\na\r\n:1\r\n$1\r\nb\r\n:2\r\n".b, encode(map, 3)
    assert_equal "*4\r\n$1\r\na\r\n:1\r\n$1\r\nb\r\n:2\r\n".b, encode(map, 2)
  end

  def test_reader_parses_multibulk
    reader = Protocol::Reader.new
    reader << "*2\r\n$3\r\nGET\r\n$3\r\nfoo\r\n".b
    assert_equal %w[GET foo], reader.read_command
    assert_nil reader.read_command
  end

  def test_reader_handles_partial_frames
    reader = Protocol::Reader.new
    reader << "*1\r\n$5\r\nhel".b
    assert_nil reader.read_command
    reader << "lo\r\n".b
    assert_equal ["hello"], reader.read_command
  end

  def test_reader_parses_inline
    reader = Protocol::Reader.new
    reader << "PING hello world\r\n".b
    assert_equal %w[PING hello world], reader.read_command
  end

  def test_reader_parses_inline_quotes
    reader = Protocol::Reader.new
    reader << %(SET key "hello world"\r\n).b
    assert_equal ["SET", "key", "hello world"], reader.read_command
  end

  def test_format_double
    assert_equal "3", Util.format_double(3.0)
    assert_equal "3.14", Util.format_double(3.14)
    assert_equal "inf", Util.format_double(Float::INFINITY)
    assert_equal "-inf", Util.format_double(-Float::INFINITY)
  end

  def test_glob_match
    assert Util.glob_match?("h?llo", "hello")
    assert Util.glob_match?("h*o", "hellooo")
    assert Util.glob_match?("h[ae]llo", "hallo")
    refute Util.glob_match?("h[^ae]llo", "hallo")
    assert Util.glob_match?("*", "anything")
  end

  def test_string_to_int_rejects_leading_zero
    assert_equal 10, Util.string_to_int("10")
    assert_raises(CommandError) { Util.string_to_int("01") }
    assert_raises(CommandError) { Util.string_to_int("1.5") }
  end
end

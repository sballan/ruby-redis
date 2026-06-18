# typed: false
# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "socket"
require "tmpdir"
require "fileutils"
require "redis_ruby"

module TestSupport
  # A wrapper returned for RESP error replies so tests can inspect the message
  # without the client raising.
  class ErrorReply
    attr_reader :message

    def initialize(message)
      @message = message
    end

    def to_s = @message
  end

  # A tiny blocking RESP client used by the integration tests. Understands both
  # RESP2 and RESP3 replies.
  class Client
    def initialize(host, port)
      @socket = TCPSocket.new(host, port)
      @socket.sync = true
      @buffer = +"".b
    end

    def call(*args)
      send_command(args)
      read_reply
    end

    # Read the next reply without sending a command (for pub/sub pushes).
    def read = read_reply

    def close
      @socket.close
    rescue StandardError
      nil
    end

    private

    def send_command(args)
      out = +"*#{args.length}\r\n".b
      args.each do |arg|
        bytes = arg.to_s.b
        out << "$#{bytes.bytesize}\r\n".b << bytes << "\r\n".b
      end
      @socket.write(out)
    end

    def read_reply
      line = read_line
      type = line.byteslice(0, 1)
      body = line.byteslice(1, line.bytesize - 1)
      case type
      when "+" then body
      when "-" then ErrorReply.new(body)
      when ":" then body.to_i
      when "(" then body.to_i
      when "," then parse_double(body)
      when "#" then body == "t"
      when "_" then nil
      when "$", "=" then read_bulk(body.to_i, verbatim: type == "=")
      when "*", ">", "~" then read_array(body.to_i)
      when "%" then read_map(body.to_i)
      else raise "unknown reply type #{type.inspect} (#{line.inspect})"
      end
    end

    def read_bulk(length, verbatim:)
      return nil if length == -1

      data = read_bytes(length)
      read_bytes(2)
      verbatim ? data.byteslice(4, data.bytesize - 4) : data
    end

    def read_array(count)
      return nil if count == -1

      Array.new(count) { read_reply }
    end

    def read_map(count)
      pairs = {}
      count.times { pairs[read_reply] = read_reply }
      pairs
    end

    def parse_double(body)
      case body
      when "inf" then Float::INFINITY
      when "-inf" then -Float::INFINITY
      else body.to_f
      end
    end

    def read_line
      loop do
        index = @buffer.index("\r\n".b)
        if index
          line = @buffer.byteslice(0, index)
          @buffer = @buffer.byteslice(index + 2, @buffer.bytesize - index - 2)
          return line
        end
        @buffer << @socket.readpartial(4096)
      end
    end

    def read_bytes(count)
      @buffer << @socket.readpartial(4096) while @buffer.bytesize < count
      data = @buffer.byteslice(0, count)
      @buffer = @buffer.byteslice(count, @buffer.bytesize - count)
      data
    end
  end

  # Boots a real server on an ephemeral port inside a background thread.
  class Harness
    attr_reader :server, :port, :dir

    def initialize(config_overrides = {})
      @dir = Dir.mktmpdir("redis_ruby_test")
      config = RedisRuby::Config.new
      config.set("dir", @dir)
      config.set("save", "")
      config_overrides.each { |name, value| config.set(name, value) }
      @server = RedisRuby::Server.new(config)
      @port = @server.listen(host: "127.0.0.1", port: 0)
      @thread = Thread.new { @server.run }
      @thread.report_on_exception = true
      @clients = []
    end

    def client
      client = Client.new("127.0.0.1", @port)
      @clients << client
      client
    end

    def stop
      @clients.each(&:close)
      @server.stop
      @thread.join(5)
    ensure
      FileUtils.remove_entry(@dir) if File.directory?(@dir)
    end
  end
end

# Base class: a fresh server + connected client per test.
class ServerTest < Minitest::Test
  def setup
    @harness = TestSupport::Harness.new(server_config)
    @client = @harness.client
  end

  def teardown
    @harness&.stop
  end

  # Override to tweak server config for a test class.
  def server_config = {}

  def r(*args) = @client.call(*args)

  def assert_error(pattern, reply)
    assert_instance_of TestSupport::ErrorReply, reply, "expected an error reply, got #{reply.inspect}"
    assert_match pattern, reply.message
  end
end

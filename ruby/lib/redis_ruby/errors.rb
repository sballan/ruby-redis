# typed: strict
# frozen_string_literal: true

module RedisRuby
  # Base class for every error raised inside the server.
  class Error < StandardError; end

  # Raised by the protocol reader when a client sends a malformed request.
  # The connection is closed after the error reply is written.
  class ProtocolError < Error; end

  # Raised by command handlers to signal an error reply to the client. The
  # message is sent verbatim as a RESP error (e.g. "WRONGTYPE Operation ...").
  # Command execution is otherwise unaffected and the connection stays open.
  class CommandError < Error
    extend T::Sig

    WRONG_TYPE = "WRONGTYPE Operation against a key holding the wrong kind of value"
    NOT_INTEGER = "ERR value is not an integer or out of range"
    NOT_FLOAT = "ERR value is not a valid float"
    SYNTAX = "ERR syntax error"
    OUT_OF_RANGE = "ERR value is out of range"
    NEGATIVE_INDEX = "ERR index out of range"

    sig { returns(CommandError) }
    def self.wrong_type = new(WRONG_TYPE)

    sig { returns(CommandError) }
    def self.not_integer = new(NOT_INTEGER)

    sig { returns(CommandError) }
    def self.not_float = new(NOT_FLOAT)

    sig { returns(CommandError) }
    def self.syntax = new(SYNTAX)

    sig { params(name: String).returns(CommandError) }
    def self.wrong_args(name)
      new("ERR wrong number of arguments for '#{name}' command")
    end

    sig { params(message: String).returns(CommandError) }
    def self.generic(message) = new("ERR #{message}")

    sig { params(message: String).returns(CommandError) }
    def self.raw(message) = new(message)
  end

  # Raised internally to abort the running command and disconnect the client
  # (used by QUIT after the reply has been queued, and by SHUTDOWN).
  class ClientClosed < Error; end
end

# typed: strict
# frozen_string_literal: true

module RedisRuby
  # Reply wrapper objects. Command handlers return plain Ruby values
  # (nil, Integer, String, Array) for the common cases, and one of these
  # wrappers when a specific RESP3 type or a forced simple/error reply is
  # required. {Protocol.encode} knows how to serialize each one, downgrading
  # RESP3-only types for RESP2 clients.
  module Reply
    # +OK style simple status string.
    class SimpleString
      extend T::Sig
      sig { returns(String) }
      attr_reader :string
      sig { params(string: String).void }
      def initialize(string) = (@string = string)
    end

    # -ERR ... style error. The message includes its error-code prefix.
    class Error
      extend T::Sig
      sig { returns(String) }
      attr_reader :message
      sig { params(message: String).void }
      def initialize(message) = (@message = message)
    end

    # A RESP3 double (,3.14). Downgrades to a bulk string for RESP2 clients.
    class Double
      extend T::Sig
      sig { returns(Float) }
      attr_reader :value
      sig { params(value: Float).void }
      def initialize(value) = (@value = value)
    end

    # A RESP3 boolean (#t/#f). Downgrades to :1 / :0 for RESP2 clients.
    class Boolean
      extend T::Sig
      sig { returns(T::Boolean) }
      attr_reader :value
      sig { params(value: T::Boolean).void }
      def initialize(value) = (@value = value)
    end

    # A RESP3 big number. Downgrades to a bulk string for RESP2 clients.
    class BigNumber
      extend T::Sig
      sig { returns(String) }
      attr_reader :digits
      sig { params(digits: String).void }
      def initialize(digits) = (@digits = digits)
    end

    # A RESP3 verbatim string (=15\r\ntxt:...). Downgrades to a bulk string.
    class Verbatim
      extend T::Sig
      sig { returns(String) }
      attr_reader :format
      sig { returns(String) }
      attr_reader :string
      sig { params(format: String, string: String).void }
      def initialize(format, string)
        @format = format
        @string = string
      end
    end

    # A RESP3 map (%). Downgrades to a flat array for RESP2 clients.
    # +pairs+ is an array of [key, value] tuples to preserve ordering.
    class Map
      extend T::Sig
      sig { returns(T::Array[[T.untyped, T.untyped]]) }
      attr_reader :pairs
      sig { params(pairs: T::Array[[T.untyped, T.untyped]]).void }
      def initialize(pairs) = (@pairs = pairs)

      sig { params(hash: T::Hash[T.untyped, T.untyped]).returns(Map) }
      def self.from_hash(hash) = new(hash.to_a)
    end

    # A RESP3 set (~). Downgrades to an array for RESP2 clients.
    class Set
      extend T::Sig
      sig { returns(T::Array[T.untyped]) }
      attr_reader :elements
      sig { params(elements: T::Array[T.untyped]).void }
      def initialize(elements) = (@elements = elements)
    end

    # A RESP3 push (>) message, used for pub/sub delivery. Downgrades to an
    # ordinary array for RESP2 clients.
    class Push
      extend T::Sig
      sig { returns(T::Array[T.untyped]) }
      attr_reader :elements
      sig { params(elements: T::Array[T.untyped]).void }
      def initialize(elements) = (@elements = elements)
    end

    # A null array (*-1 in RESP2, _ in RESP3), distinct from a null bulk string
    # ($-1). The timeout reply of the blocking commands that would otherwise
    # answer with an array (BLPOP/BRPOP, BZPOPMIN/BZPOPMAX, BLMPOP/BZMPOP).
    class NullArray; end

    # Sentinel meaning "produce no reply at all" (used by CLIENT REPLY OFF/SKIP
    # and by commands whose reply is delivered asynchronously, e.g. blocking).
    NO_REPLY = T.let(Object.new.freeze, Object)

    NULL_ARRAY = T.let(NullArray.new.freeze, NullArray)

    OK = T.let(SimpleString.new("OK"), SimpleString)
    PONG = T.let(SimpleString.new("PONG"), SimpleString)
    QUEUED = T.let(SimpleString.new("QUEUED"), SimpleString)
  end
end

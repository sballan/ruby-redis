# typed: strict
# frozen_string_literal: true

require_relative "types/list"
require_relative "types/hash"
require_relative "types/set"
require_relative "types/sorted_set"

module RedisRuby
  module Types
    extend T::Sig

    # The Redis type name for a stored value, as reported by the TYPE command
    # and used to filter SCAN results. The serialized value of each member is
    # exactly what goes on the wire.
    class ValueType < T::Enum
      enums do
        None = new("none")
        String = new("string")
        List = new("list")
        Set = new("set")
        ZSet = new("zset")
        Hash = new("hash")
        Unknown = new("unknown")
      end
    end

    # The OBJECT ENCODING name. We don't model the memory-optimized encodings
    # (listpack/intset/ziplist), so we only ever report the unconverted names.
    class ObjectEncoding < T::Enum
      enums do
        Int = new("int")
        Embstr = new("embstr")
        Raw = new("raw")
        Quicklist = new("quicklist")
        Hashtable = new("hashtable")
        Skiplist = new("skiplist")
      end
    end

    # The Redis type of a stored value, as reported by the TYPE command.
    sig { params(value: T.untyped).returns(ValueType) }
    def self.name_for(value)
      case value
      when nil then ValueType::None
      when String then ValueType::String
      when List then ValueType::List
      when Set then ValueType::Set
      when SortedSet then ValueType::ZSet
      when Hash then ValueType::Hash
      else ValueType::Unknown
      end
    end

    # The OBJECT ENCODING of a stored value.
    sig { params(value: T.untyped).returns(ObjectEncoding) }
    def self.encoding_for(value)
      case value
      when String then string_encoding(value)
      when List then ObjectEncoding::Quicklist
      when Set then ObjectEncoding::Hashtable
      when SortedSet then ObjectEncoding::Skiplist
      when Hash then ObjectEncoding::Hashtable
      else ObjectEncoding::Raw
      end
    end

    sig { params(value: String).returns(ObjectEncoding) }
    def self.string_encoding(value)
      if value.bytesize <= 20 && Util::INTEGER_RE.match?(value) &&
         value.to_i.between?(Util::INT64_MIN, Util::INT64_MAX)
        ObjectEncoding::Int
      elsif value.bytesize <= 44
        ObjectEncoding::Embstr
      else
        ObjectEncoding::Raw
      end
    end
  end
end

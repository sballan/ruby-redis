# typed: strict
# frozen_string_literal: true

require_relative "types/list"
require_relative "types/hash"
require_relative "types/set"
require_relative "types/sorted_set"
require_relative "types/stream"

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
        Stream = new("stream")
        Unknown = new("unknown")
      end
    end

    # The OBJECT ENCODING name. Unlike the rest of the data plane these are
    # derived from the *current* contents against the configured listpack/intset
    # thresholds, so a small collection reports its compact encoding
    # (intset/listpack) and a large one its full encoding (hashtable/skiplist/
    # quicklist), mirroring how Redis transitions. The conversion is computed on
    # demand rather than latched, so unlike Redis we don't stay "upgraded" after
    # the contents shrink back below the threshold.
    class ObjectEncoding < T::Enum
      enums do
        Int = new("int")
        Embstr = new("embstr")
        Raw = new("raw")
        Listpack = new("listpack")
        Quicklist = new("quicklist")
        Intset = new("intset")
        Hashtable = new("hashtable")
        Skiplist = new("skiplist")
        Stream = new("stream")
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
      when Stream then ValueType::Stream
      else ValueType::Unknown
      end
    end

    # The OBJECT ENCODING of a stored value, derived from its contents against
    # the listpack/intset thresholds in +config+ (defaults are used when nil).
    sig { params(value: T.untyped, config: T.nilable(Config)).returns(ObjectEncoding) }
    def self.encoding_for(value, config = nil)
      case value
      when String then string_encoding(value)
      when List then list_encoding(value, config)
      when Set then set_encoding(value, config)
      when SortedSet then zset_encoding(value, config)
      when Hash then hash_encoding(value, config)
      when Stream then ObjectEncoding::Stream
      else ObjectEncoding::Raw
      end
    end

    sig { params(value: String).returns(ObjectEncoding) }
    def self.string_encoding(value)
      if integer?(value)
        ObjectEncoding::Int
      elsif value.bytesize <= 44
        ObjectEncoding::Embstr
      else
        ObjectEncoding::Raw
      end
    end

    sig { params(list: List, config: T.nilable(Config)).returns(ObjectEncoding) }
    def self.list_encoding(list, config)
      max_size = threshold(config, "list-max-listpack-size", 128)
      max_entries = max_size.positive? ? max_size : 128
      if list.size <= max_entries && list.elements.all? { |element| element.bytesize <= 64 }
        ObjectEncoding::Listpack
      else
        ObjectEncoding::Quicklist
      end
    end

    sig { params(set: Set, config: T.nilable(Config)).returns(ObjectEncoding) }
    def self.set_encoding(set, config)
      members = set.members
      if members.all? { |member| integer?(member) }
        return ObjectEncoding::Intset if set.size <= threshold(config, "set-max-intset-entries", 512)
      end

      max_entries = threshold(config, "set-max-listpack-entries", 128)
      max_value = threshold(config, "set-max-listpack-value", 64)
      if set.size <= max_entries && members.all? { |member| member.bytesize <= max_value }
        ObjectEncoding::Listpack
      else
        ObjectEncoding::Hashtable
      end
    end

    sig { params(hash: Hash, config: T.nilable(Config)).returns(ObjectEncoding) }
    def self.hash_encoding(hash, config)
      max_entries = threshold(config, "hash-max-listpack-entries", 128)
      max_value = threshold(config, "hash-max-listpack-value", 64)
      small = hash.fields.all? { |field, value| field.bytesize <= max_value && value.bytesize <= max_value }
      hash.size <= max_entries && small ? ObjectEncoding::Listpack : ObjectEncoding::Hashtable
    end

    sig { params(zset: SortedSet, config: T.nilable(Config)).returns(ObjectEncoding) }
    def self.zset_encoding(zset, config)
      max_entries = threshold(config, "zset-max-listpack-entries", 128)
      max_value = threshold(config, "zset-max-listpack-value", 64)
      small = zset.sorted.all? { |member| member.bytesize <= max_value }
      zset.size <= max_entries && small ? ObjectEncoding::Listpack : ObjectEncoding::Skiplist
    end

    # True if +str+ is the canonical decimal form of an int64 (intset/int
    # encoding eligibility).
    sig { params(str: String).returns(T::Boolean) }
    def self.integer?(str)
      str.bytesize <= 20 && Util::INTEGER_RE.match?(str) && str.to_i.between?(Util::INT64_MIN, Util::INT64_MAX)
    end

    sig { params(config: T.nilable(Config), name: String, default: Integer).returns(Integer) }
    def self.threshold(config, name, default)
      raw = config&.get(name)
      raw.nil? || raw.empty? ? default : raw.to_i
    end
  end
end

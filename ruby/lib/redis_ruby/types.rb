# typed: strict
# frozen_string_literal: true

require_relative "types/list"
require_relative "types/hash"
require_relative "types/set"
require_relative "types/sorted_set"

module RedisRuby
  module Types
    extend T::Sig

    # The Redis type name for a stored value, as reported by the TYPE command.
    sig { params(value: T.untyped).returns(String) }
    def self.name_for(value)
      case value
      when nil then "none"
      when String then "string"
      when List then "list"
      when Set then "set"
      when SortedSet then "zset"
      when Hash then "hash"
      else "unknown"
      end
    end

    # The OBJECT ENCODING name. We don't model the memory-optimized encodings
    # (listpack/intset/ziplist) so we report the unconverted encoding names.
    sig { params(value: T.untyped).returns(String) }
    def self.encoding_for(value)
      case value
      when String then string_encoding(value)
      when List then "quicklist"
      when Set then "hashtable"
      when SortedSet then "skiplist"
      when Hash then "hashtable"
      else "raw"
      end
    end

    sig { params(value: String).returns(String) }
    def self.string_encoding(value)
      if value.bytesize <= 20 && Util::INTEGER_RE.match?(value) &&
         value.to_i.between?(Util::INT64_MIN, Util::INT64_MAX)
        "int"
      elsif value.bytesize <= 44
        "embstr"
      else
        "raw"
      end
    end
  end
end

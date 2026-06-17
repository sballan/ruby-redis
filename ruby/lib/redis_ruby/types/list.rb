# typed: strict
# frozen_string_literal: true

module RedisRuby
  module Types
    # A Redis list, backed by a Ruby Array of binary strings. Left operations
    # are O(n) on the underlying array, matching correctness rather than the
    # quicklist performance characteristics of upstream Redis.
    class List
      extend T::Sig

      sig { returns(T::Array[String]) }
      attr_reader :elements

      sig { params(elements: T::Array[String]).void }
      def initialize(elements = [])
        @elements = elements
      end

      sig { returns(Integer) }
      def size = @elements.size

      sig { returns(T::Boolean) }
      def empty? = @elements.empty?

      sig { params(values: T::Array[String]).void }
      def lpush(values)
        values.each { |value| @elements.unshift(value) }
      end

      sig { params(values: T::Array[String]).void }
      def rpush(values)
        @elements.concat(values)
      end

      sig { params(count: Integer).returns(T::Array[String]) }
      def lpop(count) = @elements.shift(count)

      sig { params(count: Integer).returns(T::Array[String]) }
      def rpop(count) = @elements.pop(count).reverse

      # Normalize a possibly-negative index to a concrete one, or nil if it
      # falls outside the list after clamping.
      sig { params(index: Integer).returns(T.nilable(Integer)) }
      def normalize_index(index)
        index += @elements.size if index.negative?
        return nil if index.negative? || index >= @elements.size

        index
      end
    end
  end
end

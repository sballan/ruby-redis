# typed: strict
# frozen_string_literal: true

module RedisRuby
  module Types
    # A Redis hash, backed by an insertion-ordered Ruby Hash mapping binary
    # field names to binary values.
    class Hash
      extend T::Sig

      sig { returns(T::Hash[String, String]) }
      attr_reader :fields

      sig { params(fields: T::Hash[String, String]).void }
      def initialize(fields = {})
        @fields = fields
      end

      sig { returns(Integer) }
      def size = @fields.size

      sig { returns(T::Boolean) }
      def empty? = @fields.empty?

      sig { params(field: String).returns(T.nilable(String)) }
      def get(field) = @fields[field]

      sig { params(field: String).returns(T::Boolean) }
      def include?(field) = @fields.key?(field)

      # Sets a field, returning true when the field did not previously exist.
      sig { params(field: String, value: String).returns(T::Boolean) }
      def set(field, value)
        existed = @fields.key?(field)
        @fields[field] = value
        !existed
      end

      sig { params(field: String).returns(T::Boolean) }
      def delete(field)
        return false unless @fields.key?(field)

        @fields.delete(field)
        true
      end
    end
  end
end

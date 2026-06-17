# typed: strict
# frozen_string_literal: true

module RedisRuby
  module Types
    # A Redis set, backed by a Ruby Hash used as an insertion-ordered set of
    # binary string members (values are always true).
    class Set
      extend T::Sig

      sig { params(members: T::Array[String]).void }
      def initialize(members = [])
        @members = T.let({}, T::Hash[String, TrueClass])
        members.each { |member| @members[member] = true }
      end

      sig { returns(Integer) }
      def size = @members.size

      sig { returns(T::Boolean) }
      def empty? = @members.empty?

      sig { params(member: String).returns(T::Boolean) }
      def include?(member) = @members.key?(member)

      # Adds a member, returning true when it was newly inserted.
      sig { params(member: String).returns(T::Boolean) }
      def add(member)
        return false if @members.key?(member)

        @members[member] = true
        true
      end

      sig { params(member: String).returns(T::Boolean) }
      def remove(member)
        return false unless @members.key?(member)

        @members.delete(member)
        true
      end

      sig { returns(T::Array[String]) }
      def members = @members.keys

      sig { params(count: Integer).returns(T::Array[String]) }
      def random_members(count) = T.cast(@members.keys.sample(count), T::Array[String])

      sig { returns(T.nilable(String)) }
      def random_member = T.cast(@members.keys.sample, T.nilable(String))
    end
  end
end

# typed: strict
# frozen_string_literal: true

module RedisRuby
  module Types
    # A Redis sorted set. Members map to float scores; iteration order is by
    # score ascending with bytewise member comparison breaking ties, exactly
    # as Redis orders its skiplist. The sorted view is cached and invalidated
    # on mutation.
    class SortedSet
      extend T::Sig

      sig { void }
      def initialize
        @scores = T.let({}, T::Hash[String, Float])
        @sorted = T.let(nil, T.nilable(T::Array[String]))
      end

      sig { returns(Integer) }
      def size = @scores.size

      sig { returns(T::Boolean) }
      def empty? = @scores.empty?

      sig { params(member: String).returns(T.nilable(Float)) }
      def score(member) = @scores[member]

      sig { params(member: String).returns(T::Boolean) }
      def include?(member) = @scores.key?(member)

      # Inserts or updates a member, returning true when newly inserted.
      sig { params(member: String, score: Float).returns(T::Boolean) }
      def add(member, score)
        is_new = !@scores.key?(member)
        @scores[member] = score
        @sorted = nil
        is_new
      end

      sig { params(member: String).returns(T::Boolean) }
      def remove(member)
        return false unless @scores.key?(member)

        @scores.delete(member)
        @sorted = nil
        true
      end

      # Members in sorted order (score asc, then member bytewise asc).
      sig { returns(T::Array[String]) }
      def sorted
        @sorted ||= @scores.keys.sort_by { |member| [T.must(@scores[member]), member] }
      end

      # [member, score] tuples in sorted order.
      sig { returns(T::Array[[String, Float]]) }
      def entries = sorted.map { |member| [member, T.must(@scores[member])] }

      sig { params(member: String).returns(T.nilable(Integer)) }
      def rank(member)
        return nil unless @scores.key?(member)

        sorted.index(member)
      end

      sig { params(member: String).returns(T.nilable(Integer)) }
      def revrank(member)
        rank = rank(member)
        rank.nil? ? nil : size - 1 - rank
      end
    end
  end
end

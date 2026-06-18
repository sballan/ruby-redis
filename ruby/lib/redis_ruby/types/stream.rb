# typed: strict
# frozen_string_literal: true

module RedisRuby
  module Types
    # A Redis stream: an append-only log of entries, each identified by a
    # monotonically increasing ID of the form <ms>-<seq> (two 64-bit unsigned
    # integers). IDs are modeled as [ms, seq] tuples, which compare
    # lexicographically exactly like Redis' streamID. Entries are kept in a
    # single array sorted by ID; since XADD only ever appends an ID greater than
    # every existing one, appends are O(1) and range/lookup use binary search.
    #
    # Consumer groups (XGROUP/XREADGROUP/...) hang off the stream: each group
    # tracks its last-delivered ID, a Pending Entries List (PEL) keyed by entry
    # ID, and the set of consumers that have read from it.
    class Stream
      extend T::Sig

      Id = T.type_alias { [Integer, Integer] }
      Entry = T.type_alias { [Id, T::Array[String]] }

      # The maximum value of a stream ID component (UINT64_MAX), used as the
      # implicit sequence/ms for the "+" range bound.
      MAX_SEQ = T.let((1 << 64) - 1, Integer)

      sig { returns(T::Array[Entry]) }
      attr_reader :entries

      sig { returns(Id) }
      attr_accessor :last_id

      sig { returns(Id) }
      attr_accessor :max_deleted_id

      sig { returns(Integer) }
      attr_accessor :entries_added

      sig { returns(T::Hash[String, StreamGroup]) }
      attr_reader :groups

      sig { void }
      def initialize
        @entries = T.let([], T::Array[Entry])
        @last_id = T.let([0, 0], Id)
        @max_deleted_id = T.let([0, 0], Id)
        @entries_added = T.let(0, Integer)
        @groups = T.let({}, T::Hash[String, StreamGroup])
      end

      sig { returns(Integer) }
      def length = @entries.size

      sig { returns(T::Boolean) }
      def empty? = @entries.empty?

      sig { returns(T.nilable(Entry)) }
      def first_entry = @entries.first

      sig { returns(T.nilable(Entry)) }
      def last_entry = @entries.last

      # Append a pre-validated entry whose ID is greater than {#last_id}.
      sig { params(id: Id, fields: T::Array[String]).void }
      def append(id, fields)
        @entries << [id, fields]
        @last_id = id
        @entries_added += 1
      end

      # Index of the first entry whose ID is >= +id+ (insertion point).
      sig { params(id: Id).returns(Integer) }
      def lower_bound(id)
        @entries.bsearch_index { |entry| (entry[0] <=> id) >= 0 } || @entries.size
      end

      sig { params(id: Id).returns(T.nilable(Entry)) }
      def find(id)
        index = lower_bound(id)
        entry = @entries[index]
        entry if entry && entry[0] == id
      end

      sig { params(id: Id).returns(T::Boolean) }
      def include?(id) = !find(id).nil?

      # Remove the entry with exactly this ID, returning true if present.
      sig { params(id: Id).returns(T::Boolean) }
      def delete(id)
        index = lower_bound(id)
        entry = @entries[index]
        return false unless entry && entry[0] == id

        @entries.delete_at(index)
        @max_deleted_id = id if (id <=> @max_deleted_id) > 0
        true
      end

      # Entries with start <= id <= stop (inclusive bounds already resolved),
      # in ascending order, optionally capped at +count+ (nil = unlimited).
      sig { params(start: Id, stop: Id, count: T.nilable(Integer)).returns(T::Array[Entry]) }
      def range(start, stop, count: nil)
        return [] if (start <=> stop) > 0

        result = T.let([], T::Array[Entry])
        index = lower_bound(start)
        while index < @entries.size
          entry = T.must(@entries[index])
          break if (entry[0] <=> stop) > 0

          result << entry
          break if count && result.size >= count

          index += 1
        end
        result
      end

      # Entries with start <= id <= stop in descending order (XREVRANGE).
      sig { params(start: Id, stop: Id, count: T.nilable(Integer)).returns(T::Array[Entry]) }
      def revrange(start, stop, count: nil)
        return [] if (start <=> stop) > 0

        result = T.let([], T::Array[Entry])
        index = lower_bound(stop)
        # lower_bound(stop) is the first entry >= stop; step back to the last
        # entry that is <= stop (unless we landed exactly on stop).
        index -= 1 unless index < @entries.size && T.must(@entries[index])[0] == stop
        while index >= 0
          entry = T.must(@entries[index])
          break if (entry[0] <=> start) < 0

          result << entry
          break if count && result.size >= count

          index -= 1
        end
        result
      end

      # Drop oldest entries until at most +count+ remain (XADD/XTRIM MAXLEN).
      # Returns the number removed.
      sig { params(count: Integer).returns(Integer) }
      def trim_maxlen(count)
        return 0 if count.negative?

        excess = @entries.size - count
        return 0 if excess <= 0

        removed = @entries.shift(excess)
        last = removed.last
        @max_deleted_id = last[0] if last && (last[0] <=> @max_deleted_id) > 0
        removed.size
      end

      # Drop entries whose ID is below +minid+ (XADD/XTRIM MINID). Returns the
      # number removed.
      sig { params(minid: Id).returns(Integer) }
      def trim_minid(minid)
        removed = 0
        while (entry = @entries.first) && (entry[0] <=> minid).negative?
          @entries.shift
          @max_deleted_id = entry[0] if (entry[0] <=> @max_deleted_id) > 0
          removed += 1
        end
        removed
      end

      # The smallest ID still stored (XINFO recorded-first-entry-id), or 0-0.
      sig { returns(Id) }
      def first_id
        entry = @entries.first
        entry ? entry[0] : [0, 0]
      end
    end

    # One consumer group attached to a stream.
    class StreamGroup
      extend T::Sig

      sig { returns(Stream::Id) }
      attr_accessor :last_delivered_id

      sig { returns(Integer) }
      attr_accessor :entries_read

      sig { returns(T::Hash[Stream::Id, StreamPending]) }
      attr_reader :pending

      sig { returns(T::Hash[String, StreamConsumer]) }
      attr_reader :consumers

      sig { params(last_delivered_id: Stream::Id, entries_read: Integer).void }
      def initialize(last_delivered_id, entries_read: 0)
        @last_delivered_id = last_delivered_id
        @entries_read = entries_read
        @pending = T.let({}, T::Hash[Stream::Id, StreamPending])
        @consumers = T.let({}, T::Hash[String, StreamConsumer])
      end

      sig { params(name: String, now: Integer).returns(StreamConsumer) }
      def consumer(name, now)
        @consumers[name] ||= StreamConsumer.new(name, now)
      end

      # PEL entries for one consumer, ascending by ID.
      sig { params(name: String).returns(T::Array[[Stream::Id, StreamPending]]) }
      def pending_for(name)
        @pending.select { |_id, pel| pel.consumer == name }.sort_by { |id, _| id }
      end

      sig { returns(T::Array[[Stream::Id, StreamPending]]) }
      def pending_sorted = @pending.sort_by { |id, _| id }
    end

    # One entry in a group's Pending Entries List (PEL): a message delivered to
    # a consumer but not yet acknowledged.
    class StreamPending
      extend T::Sig

      sig { returns(String) }
      attr_accessor :consumer

      sig { returns(Integer) }
      attr_accessor :delivery_time

      sig { returns(Integer) }
      attr_accessor :delivery_count

      sig { params(consumer: String, delivery_time: Integer, delivery_count: Integer).void }
      def initialize(consumer, delivery_time, delivery_count)
        @consumer = consumer
        @delivery_time = delivery_time
        @delivery_count = delivery_count
      end
    end

    # One consumer within a group. seen_time tracks the last interaction of any
    # kind; active_time tracks the last time the consumer was actually handed
    # data (XINFO reports both as idle/inactive).
    class StreamConsumer
      extend T::Sig

      sig { returns(String) }
      attr_reader :name

      sig { returns(Integer) }
      attr_accessor :seen_time

      sig { returns(Integer) }
      attr_accessor :active_time

      sig { params(name: String, now: Integer).void }
      def initialize(name, now)
        @name = name
        @seen_time = now
        @active_time = now
      end
    end
  end
end

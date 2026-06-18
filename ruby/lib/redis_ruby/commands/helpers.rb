# typed: strict
# frozen_string_literal: true

module RedisRuby
  module Commands
    # Helpers shared by every command module: argument parsing that mirrors
    # Redis' error messages, and the keyspace-change signal that drives WATCH
    # invalidation and persistence dirtiness.
    module Helpers
      extend T::Sig

      # Signal that a key changed: invalidate WATCHers, wake any clients blocked
      # on the key (BLPOP and friends), and bump the dirty counter so
      # snapshotting/save points and LASTSAVE behave correctly.
      sig { params(client: Client, key: String, changes: Integer).void }
      def self.touch(client, key, changes = 1)
        client.db.signal_modified(key)
        client.server.signal_key_ready(client.db_index, key)
        client.server.notify_dirty(changes)
        client.notify_keys << key
      end

      # Bump dirtiness without a specific key (FLUSHDB, etc.).
      sig { params(client: Client, changes: Integer).void }
      def self.dirty(client, changes = 1)
        client.server.notify_dirty(changes)
      end

      sig { params(str: String).returns(Integer) }
      def self.int(str) = Util.string_to_int(str)

      sig { params(str: String).returns(Float) }
      def self.float(str) = Util.string_to_float(str)

      # Parse a non-negative integer (e.g. a count), raising the Redis error.
      sig { params(str: String).returns(Integer) }
      def self.positive_int(str)
        value = Util.string_to_int(str)
        raise CommandError.generic("value is out of range, must be positive") if value.negative?

        value
      end

      # Lower-case ASCII compare for option tokens (EX, NX, ...).
      sig { params(str: String, token: String).returns(T::Boolean) }
      def self.eq?(str, token) = str.bytesize == token.bytesize && str.downcase == token

      # Parse a SCAN-style cursor (we use a plain offset into a key snapshot).
      sig { params(str: String).returns(Integer) }
      def self.parse_cursor(str)
        Integer(str, 10)
      rescue ArgumentError, TypeError
        raise CommandError.generic("invalid cursor")
      end

      # Return [next_cursor, slice] for a cursor-based scan over a snapshot.
      sig { params(items: T::Array[T.untyped], cursor: Integer, count: Integer).returns([Integer, T::Array[T.untyped]]) }
      def self.scan_window(items, cursor, count)
        slice = items[cursor, count] || []
        next_cursor = cursor + count >= items.length ? 0 : cursor + count
        [next_cursor, slice]
      end

      # Resolve start/stop arguments against a length, returning an inclusive
      # [start, stop] window already clamped to the collection, or nil if the
      # range is empty. Negative indices count from the end (Redis semantics).
      sig { params(start: Integer, stop: Integer, length: Integer).returns(T.nilable([Integer, Integer])) }
      def self.range(start, stop, length)
        start += length if start.negative?
        stop += length if stop.negative?
        start = 0 if start.negative?
        stop = length - 1 if stop >= length
        return nil if start > stop || length.zero? || start >= length

        [start, stop]
      end
    end
  end
end

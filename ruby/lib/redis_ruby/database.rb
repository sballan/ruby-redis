# typed: strict
# frozen_string_literal: true

module RedisRuby
  # A single logical keyspace (one of the numbered databases selected via
  # SELECT). Holds the key dictionary, the per-key expiration table, and the
  # WATCH bookkeeping used by transactions.
  class Database
    extend T::Sig

    sig { returns(Integer) }
    attr_reader :index

    sig { returns(T::Hash[String, T.untyped]) }
    attr_reader :dict

    sig { returns(T::Hash[String, Integer]) }
    attr_reader :expires

    # Shared empty result for keys with no blocked clients; never mutated.
    # (Typed untyped so the constant doesn't reference Client at load time,
    # before client.rb is required.)
    NO_WAITERS = T.let([].freeze, T::Array[T.untyped])

    sig { params(index: Integer, server: Server).void }
    def initialize(index, server)
      @index = index
      @server = server
      @dict = T.let({}, T::Hash[String, T.untyped])
      @expires = T.let({}, T::Hash[String, Integer])
      @watchers = T.let({}, T::Hash[String, T::Array[Client]])
      @blocked = T.let({}, T::Hash[String, T::Array[Client]])
    end

    # --- Reads -------------------------------------------------------------

    sig { params(key: String).returns(T.untyped) }
    def lookup(key)
      expire_if_needed(key)
      @dict[key]
    end

    sig { params(key: String).returns(T::Boolean) }
    def exists?(key)
      expire_if_needed(key)
      @dict.key?(key)
    end

    sig { returns(Integer) }
    def size = @dict.size

    # Typed lookups: fetch a value asserting it has the expected type, raising
    # WRONGTYPE otherwise. Return nil when the key is absent.

    sig { params(key: String).returns(T.nilable(String)) }
    def lookup_string(key) = T.cast(check(lookup(key), String), T.nilable(String))

    sig { params(key: String).returns(T.nilable(Types::List)) }
    def lookup_list(key) = T.cast(check(lookup(key), Types::List), T.nilable(Types::List))

    sig { params(key: String).returns(T.nilable(Types::Hash)) }
    def lookup_hash(key) = T.cast(check(lookup(key), Types::Hash), T.nilable(Types::Hash))

    sig { params(key: String).returns(T.nilable(Types::Set)) }
    def lookup_set(key) = T.cast(check(lookup(key), Types::Set), T.nilable(Types::Set))

    sig { params(key: String).returns(T.nilable(Types::SortedSet)) }
    def lookup_zset(key) = T.cast(check(lookup(key), Types::SortedSet), T.nilable(Types::SortedSet))

    sig { params(value: T.untyped, klass: T::Class[T.anything]).returns(T.untyped) }
    def check(value, klass)
      raise CommandError.wrong_type unless value.nil? || value.is_a?(klass)

      value
    end

    # --- Writes ------------------------------------------------------------

    sig { params(key: String, value: T.untyped).void }
    def set(key, value)
      @dict[key] = value
    end

    # Set a value and clear any TTL (used by SET, GETSET, etc.).
    sig { params(key: String, value: T.untyped).void }
    def set_fresh(key, value)
      @dict[key] = value
      @expires.delete(key)
    end

    sig { params(key: String).returns(T::Boolean) }
    def delete(key)
      @expires.delete(key)
      return false unless @dict.key?(key)

      @dict.delete(key)
      true
    end

    sig { void }
    def clear
      @dict.clear
      @expires.clear
    end

    # Exchange the contents of this database with another (SWAPDB), preserving
    # the object identity that connected clients already hold a reference to.
    sig { params(other: Database).void }
    def swap_with(other)
      @dict, other.dict_ref = other.dict_ref, @dict
      @expires, other.expires_ref = other.expires_ref, @expires
    end

    sig { returns(T::Hash[String, T.untyped]) }
    def dict_ref = @dict

    sig { params(value: T::Hash[String, T.untyped]).void }
    def dict_ref=(value)
      @dict = value
    end

    sig { returns(T::Hash[String, Integer]) }
    def expires_ref = @expires

    sig { params(value: T::Hash[String, Integer]).void }
    def expires_ref=(value)
      @expires = value
    end

    # --- Expiration --------------------------------------------------------

    sig { params(key: String, at_ms: Integer).void }
    def set_expire(key, at_ms)
      @expires[key] = at_ms
    end

    sig { params(key: String).returns(T.nilable(Integer)) }
    def expire_at(key) = @expires[key]

    sig { params(key: String).returns(T::Boolean) }
    def volatile?(key) = @expires.key?(key)

    sig { params(key: String).returns(T::Boolean) }
    def persist(key)
      return false unless @expires.key?(key)

      @expires.delete(key)
      true
    end

    # Lazily evict the key if its TTL has passed. Returns true if it expired.
    sig { params(key: String).returns(T::Boolean) }
    def expire_if_needed(key)
      at = @expires[key]
      return false if at.nil?
      return false if at > Util.now_ms

      @dict.delete(key)
      @expires.delete(key)
      signal_modified(key)
      @server.notify_keyspace_event(:expired, "expired", key, @index)
      @server.notify_dirty(1)
      true
    end

    # Remove a sample of expired volatile keys. Returns the number evicted.
    sig { params(sample: Integer).returns(Integer) }
    def active_expire_cycle(sample: 20)
      now = Util.now_ms
      evicted = 0
      @expires.keys.first(sample).each do |key|
        at = @expires[key]
        next if at.nil? || at > now

        @dict.delete(key)
        @expires.delete(key)
        signal_modified(key)
        @server.notify_keyspace_event(:expired, "expired", key, @index)
        evicted += 1
      end
      @server.notify_dirty(evicted) if evicted.positive?
      evicted
    end

    # --- WATCH bookkeeping -------------------------------------------------

    sig { params(client: Client, key: String).void }
    def watch(client, key)
      (@watchers[key] ||= []) << client unless @watchers[key]&.include?(client)
    end

    sig { params(client: Client, key: String).void }
    def unwatch(client, key)
      watchers = @watchers[key]
      return unless watchers

      watchers.delete(client)
      @watchers.delete(key) if watchers.empty?
    end

    # Flag every client WATCHing this key so their next EXEC aborts.
    sig { params(key: String).void }
    def signal_modified(key)
      watchers = @watchers[key]
      return unless watchers

      watchers.each { |client| client.cas_dirty = true }
    end

    # Used by FLUSHDB/SWAPDB: every watched key is considered touched.
    sig { void }
    def signal_flush
      @watchers.each_value { |clients| clients.each { |client| client.cas_dirty = true } }
    end

    # --- Blocking (BLPOP/BRPOP/...) ----------------------------------------
    #
    # Clients parked on a key are kept in arrival order so the reactor can
    # serve them first-come-first-served when the key is signaled ready.

    sig { params(key: String, client: Client).void }
    def add_blocked(key, client)
      (@blocked[key] ||= []) << client
    end

    sig { params(key: String, client: Client).void }
    def remove_blocked(key, client)
      waiters = @blocked[key]
      return if waiters.nil?

      waiters.delete(client)
      @blocked.delete(key) if waiters.empty?
    end

    sig { params(key: String).returns(T::Array[Client]) }
    def blocked_clients_on(key) = @blocked[key] || NO_WAITERS
  end
end

# typed: strict
# frozen_string_literal: true

module RedisRuby
  # Per-connection state: the socket, parse buffer, pending output, the
  # selected database, and the transaction / pub-sub / auth bookkeeping that
  # commands manipulate. One Client exists per connected socket.
  class Client
    extend T::Sig

    sig { returns(Integer) }
    attr_reader :id

    sig { returns(IO) }
    attr_reader :socket

    sig { returns(String) }
    attr_reader :addr

    sig { returns(Server) }
    attr_reader :server

    sig { returns(Protocol::Reader) }
    attr_reader :reader

    sig { returns(String) }
    attr_reader :out

    sig { returns(Integer) }
    attr_accessor :protocol

    sig { returns(Integer) }
    attr_accessor :db_index

    sig { returns(Database) }
    attr_accessor :db

    sig { returns(String) }
    attr_accessor :name

    sig { returns(T::Boolean) }
    attr_accessor :authenticated

    sig { returns(T::Boolean) }
    attr_accessor :closing

    # MULTI / transaction state.
    sig { returns(T::Boolean) }
    attr_accessor :in_multi

    sig { returns(T::Boolean) }
    attr_accessor :multi_error

    sig { returns(T::Array[T::Array[String]]) }
    attr_reader :multi_queue

    # WATCH state. cas_dirty is flipped by signal_modified when a watched key
    # changes, causing the next EXEC to abort.
    sig { returns(T::Boolean) }
    attr_accessor :cas_dirty

    sig { returns(T::Array[[Integer, String]]) }
    attr_reader :watched_keys

    # Subscription sets (channel/pattern/shard name => true).
    sig { returns(T::Hash[String, TrueClass]) }
    attr_reader :sub_channels

    sig { returns(T::Hash[String, TrueClass]) }
    attr_reader :sub_patterns

    sig { returns(T::Hash[String, TrueClass]) }
    attr_reader :sub_shard

    sig { returns(Symbol) }
    attr_accessor :reply_mode

    sig { returns(String) }
    attr_accessor :lib_name

    sig { returns(String) }
    attr_accessor :lib_ver

    sig { params(id: Integer, socket: IO, addr: String, server: Server).void }
    def initialize(id:, socket:, addr:, server:)
      @id = id
      @socket = socket
      @addr = addr
      @server = server
      @reader = T.let(Protocol::Reader.new, Protocol::Reader)
      @out = T.let(+"".b, String)
      @protocol = T.let(2, Integer)
      @db_index = T.let(0, Integer)
      @db = T.let(server.db(0), Database)
      @name = T.let("", String)
      @authenticated = T.let(server.config.requirepass.nil?, T::Boolean)
      @closing = T.let(false, T::Boolean)
      @created_at = T.let(Util.now_ms, Integer)

      @in_multi = T.let(false, T::Boolean)
      @multi_error = T.let(false, T::Boolean)
      @multi_queue = T.let([], T::Array[T::Array[String]])

      @cas_dirty = T.let(false, T::Boolean)
      @watched_keys = T.let([], T::Array[[Integer, String]])

      @sub_channels = T.let({}, T::Hash[String, TrueClass])
      @sub_patterns = T.let({}, T::Hash[String, TrueClass])
      @sub_shard = T.let({}, T::Hash[String, TrueClass])

      @reply_mode = T.let(:on, Symbol)
      @skip_reply = T.let(false, T::Boolean)
      @lib_name = T.let("", String)
      @lib_ver = T.let("", String)
    end

    # --- Output ------------------------------------------------------------

    # Encode a reply (or push) into the output buffer. Reply::NO_REPLY and the
    # CLIENT REPLY OFF/SKIP modes are honored here.
    sig { params(value: T.untyped).void }
    def queue_reply(value)
      return if value.equal?(Reply::NO_REPLY)
      return if @reply_mode == :off

      if @skip_reply
        @skip_reply = false
        return
      end

      Protocol.encode(@out, value, @protocol)
    end

    # Force output regardless of reply mode (used for pub/sub deliveries).
    sig { params(value: T.untyped).void }
    def deliver(value)
      Protocol.encode(@out, value, @protocol)
    end

    sig { void }
    def request_skip_reply = (@skip_reply = true)

    sig { returns(T::Boolean) }
    def pending_output? = !@out.empty?

    sig { params(count: Integer).void }
    def consume_output(count)
      @out = T.must(@out.byteslice(count, @out.bytesize - count))
    end

    # --- Subscriptions -----------------------------------------------------

    sig { returns(Integer) }
    def subscription_count = @sub_channels.size + @sub_patterns.size + @sub_shard.size

    # In RESP2 a subscribed client may only issue a restricted command set.
    sig { returns(T::Boolean) }
    def subscribe_mode? = @protocol == 2 && subscription_count.positive?

    # --- Transactions ------------------------------------------------------

    sig { void }
    def reset_multi
      @in_multi = false
      @multi_error = false
      @multi_queue = []
    end

    sig { void }
    def reset_state
      reset_multi
      @cas_dirty = false
      @watched_keys = []
    end

    sig { params(at: Integer).returns(Integer) }
    def created_before(at) = at - @created_at
  end
end

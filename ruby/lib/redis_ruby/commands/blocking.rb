# typed: strict
# frozen_string_literal: true

module RedisRuby
  module Commands
    # Blocking list/sorted-set commands and WAIT. These are the first commands
    # that don't reply synchronously: when the data they need isn't available
    # they park the client on its keys via {Client#block_on}, and the reactor
    # re-runs the attempt when one of those keys is signaled ready (or replies
    # with the timeout value once the deadline passes).
    #
    # Each command first runs its attempt eagerly, so an already-satisfiable
    # call returns immediately. Inside MULTI/EXEC (or any other deny-blocking
    # context) the commands never park: they behave like their non-blocking
    # counterparts and return their empty/timeout reply at once.
    module Blocking
      extend T::Sig

      # Returned by an attempt to mean "nothing to serve yet; stay blocked".
      WOULD_BLOCK = T.let(Object.new.freeze, Object)

      # --- BLPOP / BRPOP -----------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.blpop(client, argv) = bpop(client, argv, side: :left)

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.brpop(client, argv) = bpop(client, argv, side: :right)

      sig { params(client: Client, argv: T::Array[String], side: Symbol).returns(T.untyped) }
      def self.bpop(client, argv, side:)
        timeout = parse_timeout(T.must(argv.last))
        keys = T.must(argv[1...-1])
        result = try_bpop(client, keys, side)
        return result unless result.equal?(WOULD_BLOCK)
        return Reply::NULL_ARRAY if client.deny_blocking

        client.block_on(keys, timeout, Reply::NULL_ARRAY) { try_bpop(client, keys, side) }
        Reply::NO_REPLY
      end

      sig { params(client: Client, keys: T::Array[String], side: Symbol).returns(T.untyped) }
      def self.try_bpop(client, keys, side)
        keys.each do |key|
          list = client.db.lookup_list(key)
          next if list.nil? || list.empty?

          element = T.must((side == :left ? list.lpop(1) : list.rpop(1)).first)
          Lists.prune(client, key, list)
          Helpers.touch(client, key)
          return [key, element]
        end
        WOULD_BLOCK
      end

      # --- BLMOVE / BRPOPLPUSH ----------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.blmove(client, argv)
        from = T.must(argv[3]).downcase
        to = T.must(argv[4]).downcase
        raise CommandError.syntax unless %w[left right].include?(from) && %w[left right].include?(to)

        bmove(client, T.must(argv[1]), T.must(argv[2]), from.to_sym, to.to_sym, T.must(argv[5]))
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.brpoplpush(client, argv)
        bmove(client, T.must(argv[1]), T.must(argv[2]), :right, :left, T.must(argv[3]))
      end

      sig do
        params(client: Client, source: String, dest: String, from: Symbol, to: Symbol, timeout_arg: String)
          .returns(T.untyped)
      end
      def self.bmove(client, source, dest, from, to, timeout_arg)
        timeout = parse_timeout(timeout_arg)
        result = try_bmove(client, source, dest, from, to)
        return result unless result.equal?(WOULD_BLOCK)
        return nil if client.deny_blocking

        client.block_on([source], timeout, nil) { try_bmove(client, source, dest, from, to) }
        Reply::NO_REPLY
      end

      sig { params(client: Client, source: String, dest: String, from: Symbol, to: Symbol).returns(T.untyped) }
      def self.try_bmove(client, source, dest, from, to)
        element = Lists.move(client, source, dest, from, to)
        element.nil? ? WOULD_BLOCK : element
      end

      # --- BLMPOP / BZMPOP ---------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.blmpop(client, argv)
        timeout = parse_timeout(T.must(argv[1]))
        keys = mpop_keys(argv)
        rest = T.must(argv[2..])
        result = try_lmpop(client, rest)
        return result unless result.equal?(WOULD_BLOCK)
        return Reply::NULL_ARRAY if client.deny_blocking

        client.block_on(keys, timeout, Reply::NULL_ARRAY) { try_lmpop(client, rest) }
        Reply::NO_REPLY
      end

      sig { params(client: Client, rest: T::Array[String]).returns(T.untyped) }
      def self.try_lmpop(client, rest)
        result = Lists.lmpop(client, ["lmpop", *rest])
        result.nil? ? WOULD_BLOCK : result
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.bzmpop(client, argv)
        timeout = parse_timeout(T.must(argv[1]))
        keys = mpop_keys(argv)
        rest = T.must(argv[2..])
        result = try_zmpop(client, rest)
        return result unless result.equal?(WOULD_BLOCK)
        return Reply::NULL_ARRAY if client.deny_blocking

        client.block_on(keys, timeout, Reply::NULL_ARRAY) { try_zmpop(client, rest) }
        Reply::NO_REPLY
      end

      sig { params(client: Client, rest: T::Array[String]).returns(T.untyped) }
      def self.try_zmpop(client, rest)
        result = SortedSets.zmpop(client, ["zmpop", *rest])
        result.nil? ? WOULD_BLOCK : result
      end

      # The numkeys keys of a (B)LMPOP/(B)ZMPOP call begin at argv[3].
      sig { params(argv: T::Array[String]).returns(T::Array[String]) }
      def self.mpop_keys(argv)
        numkeys = Helpers.int(T.must(argv[2]))
        raise CommandError.generic("numkeys should be greater than 0") if numkeys <= 0

        T.must(argv[3, numkeys])
      end

      # --- BZPOPMIN / BZPOPMAX ----------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.bzpopmin(client, argv) = bzpop(client, argv, min: true)

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.bzpopmax(client, argv) = bzpop(client, argv, min: false)

      sig { params(client: Client, argv: T::Array[String], min: T::Boolean).returns(T.untyped) }
      def self.bzpop(client, argv, min:)
        timeout = parse_timeout(T.must(argv.last))
        keys = T.must(argv[1...-1])
        result = try_bzpop(client, keys, min)
        return result unless result.equal?(WOULD_BLOCK)
        return Reply::NULL_ARRAY if client.deny_blocking

        client.block_on(keys, timeout, Reply::NULL_ARRAY) { try_bzpop(client, keys, min) }
        Reply::NO_REPLY
      end

      sig { params(client: Client, keys: T::Array[String], min: T::Boolean).returns(T.untyped) }
      def self.try_bzpop(client, keys, min)
        keys.each do |key|
          zset = client.db.lookup_zset(key)
          next if zset.nil? || zset.empty?

          member, score = T.must(min ? zset.entries.first : zset.entries.last)
          zset.remove(member)
          client.db.delete(key) if zset.empty?
          Helpers.touch(client, key)
          score_reply = client.protocol >= 3 ? Reply::Double.new(score) : Util.format_double(score)
          return [key, member, score_reply]
        end
        WOULD_BLOCK
      end

      # --- WAIT --------------------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.wait(client, argv)
        numreplicas = Util.string_to_int(T.must(argv[1]))
        timeout_ms = Util.string_to_int(T.must(argv[2]))
        raise CommandError.generic("timeout is negative") if timeout_ms.negative?

        acked = client.server.connected_replicas
        return acked if numreplicas <= acked || client.deny_blocking

        # We can never gain replicas, so this only ever resolves on timeout,
        # returning the (zero) number that acknowledged.
        client.block_on([], timeout_ms / 1000.0, acked) { WOULD_BLOCK }
        Reply::NO_REPLY
      end

      # --- Shared ------------------------------------------------------------

      # Parse a BLPOP-style timeout: seconds as a (possibly fractional) finite
      # float, >= 0. 0 means wait forever.
      sig { params(str: String).returns(Float) }
      def self.parse_timeout(str)
        value =
          begin
            Util.string_to_float(str)
          rescue CommandError
            raise CommandError.generic("timeout is not a float or out of range")
          end
        raise CommandError.generic("timeout is not a float or out of range") if value.nan? || !value.finite?
        raise CommandError.generic("timeout is negative") if value.negative?

        value
      end

      sig { params(table: CommandTable).void }
      def self.install(table)
        table.add("blpop", -3, [CommandFlag::Write]) { |c, a| blpop(c, a) }
        table.add("brpop", -3, [CommandFlag::Write]) { |c, a| brpop(c, a) }
        table.add("blmove", 6, [CommandFlag::Write]) { |c, a| blmove(c, a) }
        table.add("brpoplpush", 4, [CommandFlag::Write]) { |c, a| brpoplpush(c, a) }
        table.add("blmpop", -5, [CommandFlag::Write]) { |c, a| blmpop(c, a) }
        table.add("bzmpop", -5, [CommandFlag::Write]) { |c, a| bzmpop(c, a) }
        table.add("bzpopmin", -3, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| bzpopmin(c, a) }
        table.add("bzpopmax", -3, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| bzpopmax(c, a) }
        table.add("wait", 3, []) { |c, a| wait(c, a) }
      end
    end
  end
end

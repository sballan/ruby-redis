# typed: strict
# frozen_string_literal: true

module RedisRuby
  module Commands
    # String commands: GET/SET and their many option variants, the counter
    # family (INCR/DECR/INCRBYFLOAT), range/append operations, and the bulk
    # M* variants.
    module Strings
      extend T::Sig

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.get(client, argv) = client.db.lookup_string(T.must(argv[1]))

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.getdel(client, argv)
        key = T.must(argv[1])
        value = client.db.lookup_string(key)
        return nil if value.nil?

        client.db.delete(key)
        Helpers.touch(client, key)
        value
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.getex(client, argv)
        key = T.must(argv[1])
        value = client.db.lookup_string(key)
        return nil if value.nil?

        persist = T.let(false, T::Boolean)
        expire_at = T.let(nil, T.nilable(Integer))
        index = 2
        while index < argv.length
          option = T.must(argv[index]).downcase
          case option
          when "persist" then persist = true; index += 1
          when "ex", "px", "exat", "pxat"
            raise CommandError.syntax if index + 1 >= argv.length

            expire_at = absolute_expire(option, T.must(argv[index + 1]), "getex")
            index += 2
          else raise CommandError.syntax
          end
        end

        if persist
          changed = client.db.persist(key)
          Helpers.touch(client, key) if changed
        elsif expire_at
          client.db.set_expire(key, expire_at)
          Helpers.touch(client, key)
        end
        value
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.set(client, argv)
        key = T.must(argv[1])
        value = T.must(argv[2])
        nx = xx = keepttl = want_get = T.let(false, T::Boolean)
        expire_at = T.let(nil, T.nilable(Integer))
        expire_seen = T.let(false, T::Boolean)

        index = 3
        while index < argv.length
          option = T.must(argv[index]).downcase
          case option
          when "nx" then nx = true; index += 1
          when "xx" then xx = true; index += 1
          when "keepttl" then keepttl = true; index += 1
          when "get" then want_get = true; index += 1
          when "ex", "px", "exat", "pxat"
            raise CommandError.syntax if expire_seen || index + 1 >= argv.length

            expire_at = absolute_expire(option, T.must(argv[index + 1]), "set")
            expire_seen = true
            index += 2
          else raise CommandError.syntax
          end
        end
        raise CommandError.syntax if (nx && xx) || (keepttl && expire_seen)

        existing = client.db.lookup(key)
        old_value = T.let(nil, T.nilable(String))
        if want_get
          raise CommandError.wrong_type unless existing.nil? || existing.is_a?(String)

          old_value = existing
        end

        if (nx && !existing.nil?) || (xx && existing.nil?)
          return want_get ? old_value : nil
        end

        if keepttl
          client.db.set(key, value)
        else
          client.db.set_fresh(key, value)
        end
        client.db.set_expire(key, expire_at) if expire_at
        Helpers.touch(client, key)

        want_get ? old_value : Reply::OK
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.setnx(client, argv)
        key = T.must(argv[1])
        return 0 unless client.db.lookup(key).nil?

        client.db.set_fresh(key, T.must(argv[2]))
        Helpers.touch(client, key)
        1
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.setex(client, argv) = set_with_ttl(client, argv, :seconds, "setex")

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.psetex(client, argv) = set_with_ttl(client, argv, :millis, "psetex")

      sig { params(client: Client, argv: T::Array[String], unit: Symbol, name: String).returns(T.untyped) }
      def self.set_with_ttl(client, argv, unit, name)
        key = T.must(argv[1])
        ttl = Helpers.int(T.must(argv[2]))
        raise CommandError.generic("invalid expire time in '#{name}' command") if ttl <= 0

        client.db.set_fresh(key, T.must(argv[3]))
        client.db.set_expire(key, Util.now_ms + (unit == :seconds ? ttl * 1000 : ttl))
        Helpers.touch(client, key)
        Reply::OK
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.getset(client, argv)
        key = T.must(argv[1])
        old = client.db.lookup_string(key)
        client.db.set_fresh(key, T.must(argv[2]))
        Helpers.touch(client, key)
        old
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.append(client, argv)
        key = T.must(argv[1])
        existing = client.db.lookup_string(key) || +"".b
        updated = existing.dup << T.must(argv[2])
        client.db.set(key, updated)
        Helpers.touch(client, key)
        updated.bytesize
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.strlen(client, argv) = client.db.lookup_string(T.must(argv[1]))&.bytesize || 0

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.mget(client, argv)
        (argv[1..] || []).map do |key|
          value = client.db.lookup(key)
          value.is_a?(String) ? value : nil
        end
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.mset(client, argv)
        pairs = argv[1..] || []
        raise CommandError.wrong_args("mset") if pairs.empty? || pairs.length.odd?

        pairs.each_slice(2) do |key, value|
          client.db.set_fresh(T.must(key), T.must(value))
          Helpers.touch(client, T.must(key))
        end
        Reply::OK
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.msetnx(client, argv)
        pairs = argv[1..] || []
        raise CommandError.wrong_args("msetnx") if pairs.empty? || pairs.length.odd?

        keys = pairs.each_slice(2).map { |key, _| T.must(key) }
        return 0 if keys.any? { |key| !client.db.lookup(key).nil? }

        pairs.each_slice(2) do |key, value|
          client.db.set_fresh(T.must(key), T.must(value))
          Helpers.touch(client, T.must(key))
        end
        1
      end

      # --- Counters ----------------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.incr(client, argv) = incr_by(client, T.must(argv[1]), 1)

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.decr(client, argv) = incr_by(client, T.must(argv[1]), -1)

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.incrby(client, argv) = incr_by(client, T.must(argv[1]), Helpers.int(T.must(argv[2])))

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.decrby(client, argv) = incr_by(client, T.must(argv[1]), -Helpers.int(T.must(argv[2])))

      sig { params(client: Client, key: String, delta: Integer).returns(Integer) }
      def self.incr_by(client, key, delta)
        current = client.db.lookup_string(key)
        value = current.nil? ? 0 : Util.string_to_int(current)
        result = value + delta
        if result < Util::INT64_MIN || result > Util::INT64_MAX
          raise CommandError.generic("increment or decrement would overflow")
        end

        client.db.set(key, result.to_s.b)
        Helpers.touch(client, key)
        result
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.incrbyfloat(client, argv)
        key = T.must(argv[1])
        increment = Helpers.float(T.must(argv[2]))
        current = client.db.lookup_string(key)
        value = current.nil? ? 0.0 : Util.string_to_float(current)
        result = value + increment
        raise CommandError.generic("increment would produce NaN or Infinity") if result.nan? || result.infinite?

        formatted = Util.format_double(result).b
        client.db.set(key, formatted)
        Helpers.touch(client, key)
        formatted
      end

      # --- Ranges ------------------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.getrange(client, argv)
        value = client.db.lookup_string(T.must(argv[1])) || +"".b
        start = Helpers.int(T.must(argv[2]))
        stop = Helpers.int(T.must(argv[3]))
        window = Helpers.range(start, stop, value.bytesize)
        return +"".b if window.nil?

        T.must(value.byteslice(window[0], window[1] - window[0] + 1))
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.setrange(client, argv)
        key = T.must(argv[1])
        offset = Helpers.int(T.must(argv[2]))
        raise CommandError.generic("offset is out of range") if offset.negative?

        patch = T.must(argv[3])
        existing = client.db.lookup_string(key) || +"".b
        return existing.bytesize if patch.empty?

        buffer = existing.dup
        buffer << ("\x00".b * (offset - buffer.bytesize)) if offset > buffer.bytesize
        buffer[offset, patch.bytesize] = patch
        client.db.set(key, buffer)
        Helpers.touch(client, key)
        buffer.bytesize
      end

      # Compute the absolute expiry timestamp in ms for an EX/PX/EXAT/PXAT pair.
      sig { params(option: String, raw: String, command: String).returns(Integer) }
      def self.absolute_expire(option, raw, command)
        amount = Helpers.int(raw)
        case option
        when "ex"
          raise CommandError.generic("invalid expire time in '#{command}' command") if amount <= 0
          Util.now_ms + (amount * 1000)
        when "px"
          raise CommandError.generic("invalid expire time in '#{command}' command") if amount <= 0
          Util.now_ms + amount
        when "exat" then amount * 1000
        else amount
        end
      end

      sig { params(table: CommandTable).void }
      def self.install(table)
        table.add("get", 2, %i[readonly fast]) { |c, a| get(c, a) }
        table.add("getdel", 2, %i[write fast]) { |c, a| getdel(c, a) }
        table.add("getex", -2, %i[write fast]) { |c, a| getex(c, a) }
        table.add("set", -3, %i[write]) { |c, a| set(c, a) }
        table.add("setnx", 3, %i[write fast]) { |c, a| setnx(c, a) }
        table.add("setex", 4, %i[write]) { |c, a| setex(c, a) }
        table.add("psetex", 4, %i[write]) { |c, a| psetex(c, a) }
        table.add("getset", 3, %i[write fast]) { |c, a| getset(c, a) }
        table.add("append", 3, %i[write fast]) { |c, a| append(c, a) }
        table.add("strlen", 2, %i[readonly fast]) { |c, a| strlen(c, a) }
        table.add("mget", -2, %i[readonly fast]) { |c, a| mget(c, a) }
        table.add("mset", -3, %i[write]) { |c, a| mset(c, a) }
        table.add("msetnx", -3, %i[write]) { |c, a| msetnx(c, a) }
        table.add("incr", 2, %i[write fast]) { |c, a| incr(c, a) }
        table.add("decr", 2, %i[write fast]) { |c, a| decr(c, a) }
        table.add("incrby", 3, %i[write fast]) { |c, a| incrby(c, a) }
        table.add("decrby", 3, %i[write fast]) { |c, a| decrby(c, a) }
        table.add("incrbyfloat", 3, %i[write fast]) { |c, a| incrbyfloat(c, a) }
        table.add("getrange", 4, %i[readonly]) { |c, a| getrange(c, a) }
        table.add("substr", 4, %i[readonly]) { |c, a| getrange(c, a) }
        table.add("setrange", 4, %i[write]) { |c, a| setrange(c, a) }
      end
    end
  end
end

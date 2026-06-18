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

      # --- LCS ---------------------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.lcs(client, argv)
        a = client.db.lookup_string(T.must(argv[1])) || +"".b
        b = client.db.lookup_string(T.must(argv[2])) || +"".b

        want_len = want_idx = with_match_len = T.let(false, T::Boolean)
        min_match_len = T.let(0, Integer)
        index = 3
        while index < argv.length
          option = T.must(argv[index]).downcase
          case option
          when "len" then want_len = true; index += 1
          when "idx" then want_idx = true; index += 1
          when "withmatchlen" then with_match_len = true; index += 1
          when "minmatchlen"
            raise CommandError.syntax if index + 1 >= argv.length

            min_match_len = Helpers.int(T.must(argv[index + 1]))
            index += 2
          else raise CommandError.syntax
          end
        end
        if want_len && want_idx
          raise CommandError.generic("If you want both the length and indexes, please just use IDX.")
        end

        dp = lcs_table(a, b)
        len_a = a.bytesize
        len_b = b.bytesize
        total = T.must(T.must(dp[len_a])[len_b])

        return total if want_len

        unless want_idx
          return lcs_backtrack_string(a, b, dp)
        end

        matches = lcs_backtrack_matches(a, b, dp, min_match_len, with_match_len)
        Reply::Map.new([["matches", matches], ["len", total]])
      end

      # Build the (A+1)x(B+1) LCS-length DP table over the bytes of a and b.
      sig { params(a: String, b: String).returns(T::Array[T::Array[Integer]]) }
      def self.lcs_table(a, b)
        len_a = a.bytesize
        len_b = b.bytesize
        dp = T.let(Array.new(len_a + 1) { Array.new(len_b + 1, 0) }, T::Array[T::Array[Integer]])
        (1..len_a).each do |i|
          row = T.must(dp[i])
          prev = T.must(dp[i - 1])
          (1..len_b).each do |j|
            row[j] =
              if a.getbyte(i - 1) == b.getbyte(j - 1)
                T.must(prev[j - 1]) + 1
              else
                [T.must(prev[j]), T.must(row[j - 1])].max
              end
          end
        end
        dp
      end

      # Backtrack the DP table to reconstruct the LCS string itself.
      sig { params(a: String, b: String, dp: T::Array[T::Array[Integer]]).returns(String) }
      def self.lcs_backtrack_string(a, b, dp)
        i = a.bytesize
        j = b.bytesize
        out = +"".b
        while i.positive? && j.positive?
          if a.getbyte(i - 1) == b.getbyte(j - 1)
            out << T.must(a.getbyte(i - 1))
            i -= 1
            j -= 1
          elsif T.must(T.must(dp[i - 1])[j]) >= T.must(T.must(dp[i])[j - 1])
            i -= 1
          else
            j -= 1
          end
        end
        out.reverse
      end

      # Backtrack the DP table collecting maximal contiguous diagonal matches,
      # highest indices first, applying MINMATCHLEN and WITHMATCHLEN.
      sig do
        params(
          a: String, b: String, dp: T::Array[T::Array[Integer]],
          min_match_len: Integer, with_match_len: T::Boolean
        ).returns(T::Array[T.untyped])
      end
      def self.lcs_backtrack_matches(a, b, dp, min_match_len, with_match_len)
        i = a.bytesize
        j = b.bytesize
        matches = T.let([], T::Array[T.untyped])
        arange_start = arange_end = brange_start = brange_end = 0
        in_run = T.let(false, T::Boolean)

        while i.positive? && j.positive?
          if a.getbyte(i - 1) == b.getbyte(j - 1)
            unless in_run
              arange_end = i - 1
              brange_end = j - 1
              in_run = true
            end
            arange_start = i - 1
            brange_start = j - 1
            i -= 1
            j -= 1
          else
            if in_run
              lcs_emit_match(matches, arange_start, arange_end, brange_start, brange_end, min_match_len, with_match_len)
              in_run = false
            end
            if T.must(T.must(dp[i - 1])[j]) >= T.must(T.must(dp[i])[j - 1])
              i -= 1
            else
              j -= 1
            end
          end
        end
        if in_run
          lcs_emit_match(matches, arange_start, arange_end, brange_start, brange_end, min_match_len, with_match_len)
        end
        matches
      end

      sig do
        params(
          matches: T::Array[T.untyped],
          arange_start: Integer, arange_end: Integer, brange_start: Integer, brange_end: Integer,
          min_match_len: Integer, with_match_len: T::Boolean
        ).void
      end
      def self.lcs_emit_match(matches, arange_start, arange_end, brange_start, brange_end, min_match_len, with_match_len)
        length = arange_end - arange_start + 1
        return if length < min_match_len

        entry = T.let([[arange_start, arange_end], [brange_start, brange_end]], T::Array[T.untyped])
        entry << length if with_match_len
        matches << entry
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
        table.add("get", 2, [CommandFlag::Readonly, CommandFlag::Fast]) { |c, a| get(c, a) }
        table.add("getdel", 2, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| getdel(c, a) }
        table.add("getex", -2, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| getex(c, a) }
        table.add("set", -3, [CommandFlag::Write]) { |c, a| set(c, a) }
        table.add("setnx", 3, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| setnx(c, a) }
        table.add("setex", 4, [CommandFlag::Write]) { |c, a| setex(c, a) }
        table.add("psetex", 4, [CommandFlag::Write]) { |c, a| psetex(c, a) }
        table.add("getset", 3, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| getset(c, a) }
        table.add("append", 3, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| append(c, a) }
        table.add("strlen", 2, [CommandFlag::Readonly, CommandFlag::Fast]) { |c, a| strlen(c, a) }
        table.add("mget", -2, [CommandFlag::Readonly, CommandFlag::Fast]) { |c, a| mget(c, a) }
        table.add("mset", -3, [CommandFlag::Write]) { |c, a| mset(c, a) }
        table.add("msetnx", -3, [CommandFlag::Write]) { |c, a| msetnx(c, a) }
        table.add("incr", 2, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| incr(c, a) }
        table.add("decr", 2, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| decr(c, a) }
        table.add("incrby", 3, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| incrby(c, a) }
        table.add("decrby", 3, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| decrby(c, a) }
        table.add("incrbyfloat", 3, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| incrbyfloat(c, a) }
        table.add("getrange", 4, [CommandFlag::Readonly]) { |c, a| getrange(c, a) }
        table.add("substr", 4, [CommandFlag::Readonly]) { |c, a| getrange(c, a) }
        table.add("setrange", 4, [CommandFlag::Write]) { |c, a| setrange(c, a) }
        table.add("lcs", -3, [CommandFlag::Readonly]) { |c, a| lcs(c, a) }
      end
    end
  end
end

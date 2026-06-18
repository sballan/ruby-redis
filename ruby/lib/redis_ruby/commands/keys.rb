# typed: strict
# frozen_string_literal: true

module RedisRuby
  module Commands
    # Generic key-space commands that work across every value type: deletion,
    # existence, the EXPIRE/TTL family, TYPE, KEYS/SCAN, RENAME, COPY, MOVE and
    # OBJECT introspection.
    module Keys
      extend T::Sig

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.del(client, argv)
        deleted = 0
        (argv[1..] || []).each do |key|
          next unless client.db.delete(key)

          Helpers.touch(client, key)
          deleted += 1
        end
        deleted
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.exists(client, argv)
        (argv[1..] || []).count { |key| client.db.exists?(key) }
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.touch(client, argv)
        (argv[1..] || []).count { |key| client.db.exists?(key) }
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.type(client, argv)
        Reply::SimpleString.new(Types.name_for(client.db.lookup(T.must(argv[1]))).serialize)
      end

      # --- Expiration --------------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.expire(client, argv)
        set_expiry(client, T.must(argv[1]), Util.now_ms + (Helpers.int(T.must(argv[2])) * 1000), argv[3..] || [])
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.pexpire(client, argv)
        set_expiry(client, T.must(argv[1]), Util.now_ms + Helpers.int(T.must(argv[2])), argv[3..] || [])
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.expireat(client, argv)
        set_expiry(client, T.must(argv[1]), Helpers.int(T.must(argv[2])) * 1000, argv[3..] || [])
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.pexpireat(client, argv)
        set_expiry(client, T.must(argv[1]), Helpers.int(T.must(argv[2])), argv[3..] || [])
      end

      sig { params(client: Client, key: String, when_ms: Integer, options: T::Array[String]).returns(Integer) }
      def self.set_expiry(client, key, when_ms, options)
        nx = xx = gt = lt = T.let(false, T::Boolean)
        options.each do |option|
          case option.downcase
          when "nx" then nx = true
          when "xx" then xx = true
          when "gt" then gt = true
          when "lt" then lt = true
          else raise CommandError.raw("ERR Unsupported option #{option}")
          end
        end
        if nx && (xx || gt || lt)
          raise CommandError.generic("NX and XX, GT or LT options at the same time are not compatible")
        end
        raise CommandError.generic("GT and LT options at the same time are not compatible") if gt && lt
        return 0 unless client.db.exists?(key)

        current = client.db.expire_at(key)
        return 0 if nx && current
        return 0 if xx && current.nil?
        return 0 if gt && (current.nil? || when_ms <= current)
        return 0 if lt && current && when_ms >= current

        if when_ms <= Util.now_ms
          client.db.delete(key)
        else
          client.db.set_expire(key, when_ms)
        end
        Helpers.touch(client, key)
        1
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.persist(client, argv)
        key = T.must(argv[1])
        return 0 unless client.db.exists?(key) && client.db.persist(key)

        Helpers.touch(client, key)
        1
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.ttl(client, argv) = remaining(client, T.must(argv[1]), millis: false)

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.pttl(client, argv) = remaining(client, T.must(argv[1]), millis: true)

      sig { params(client: Client, key: String, millis: T::Boolean).returns(Integer) }
      def self.remaining(client, key, millis:)
        return -2 unless client.db.exists?(key)

        at = client.db.expire_at(key)
        return -1 if at.nil?

        left = [at - Util.now_ms, 0].max
        millis ? left : (left + 500) / 1000
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.expiretime(client, argv) = expire_time(client, T.must(argv[1]), millis: false)

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.pexpiretime(client, argv) = expire_time(client, T.must(argv[1]), millis: true)

      sig { params(client: Client, key: String, millis: T::Boolean).returns(Integer) }
      def self.expire_time(client, key, millis:)
        return -2 unless client.db.exists?(key)

        at = client.db.expire_at(key)
        return -1 if at.nil?

        millis ? at : at / 1000
      end

      # --- Enumeration -------------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.keys(client, argv)
        pattern = T.must(argv[1])
        client.db.dict.keys.select { |key| client.db.exists?(key) && Util.glob_match?(pattern, key) }
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.randomkey(client, argv)
        keys = client.db.dict.keys.select { |key| client.db.exists?(key) }
        keys.sample
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.dbsize(client, argv) = client.db.size

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.scan(client, argv)
        cursor = parse_cursor(T.must(argv[1]))
        match = T.let(nil, T.nilable(String))
        type = T.let(nil, T.nilable(String))
        count = 10
        index = 2
        while index < argv.length
          case T.must(argv[index]).downcase
          when "match" then match = argv[index + 1]; index += 2
          when "count"
            count = Helpers.int(T.must(argv[index + 1]))
            raise CommandError.syntax if count < 1
            index += 2
          when "type" then type = T.must(argv[index + 1]).downcase; index += 2
          else raise CommandError.syntax
          end
        end

        all = client.db.dict.keys
        slice = all[cursor, count] || []
        next_cursor = cursor + count >= all.length ? 0 : cursor + count
        result = slice.select do |key|
          client.db.exists?(key) &&
            (match.nil? || Util.glob_match?(match, key)) &&
            (type.nil? || Types.name_for(client.db.lookup(key)).serialize == type)
        end
        [next_cursor.to_s, result]
      end

      sig { params(str: String).returns(Integer) }
      def self.parse_cursor(str)
        Integer(str, 10)
      rescue ArgumentError, TypeError
        raise CommandError.generic("invalid cursor")
      end

      # --- Renaming / moving / copying ---------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.rename(client, argv)
        source = T.must(argv[1])
        dest = T.must(argv[2])
        value = client.db.lookup(source)
        raise CommandError.generic("no such key") if value.nil?

        move_within_db(client, source, dest)
        Reply::OK
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.renamenx(client, argv)
        source = T.must(argv[1])
        dest = T.must(argv[2])
        raise CommandError.generic("no such key") if client.db.lookup(source).nil?
        return 0 if client.db.exists?(dest)

        move_within_db(client, source, dest)
        1
      end

      sig { params(client: Client, source: String, dest: String).void }
      def self.move_within_db(client, source, dest)
        value = client.db.lookup(source)
        ttl = client.db.expire_at(source)
        client.db.delete(source)
        client.db.set(dest, value)
        client.db.set_expire(dest, ttl) if ttl
        Helpers.touch(client, source)
        Helpers.touch(client, dest)
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.copy(client, argv)
        source = T.must(argv[1])
        dest = T.must(argv[2])
        dest_db = client.db
        replace = T.let(false, T::Boolean)
        index = 3
        while index < argv.length
          case T.must(argv[index]).downcase
          when "db"
            dest_db = client.server.db(Helpers.int(T.must(argv[index + 1])))
            index += 2
          when "replace" then replace = true; index += 1
          else raise CommandError.syntax
          end
        end

        value = client.db.lookup(source)
        return 0 if value.nil?
        raise CommandError.generic("source and destination objects are the same") if dest_db.equal?(client.db) && source == dest
        return 0 if dest_db.exists?(dest) && !replace

        dest_db.delete(dest)
        dest_db.set(dest, deep_copy(value))
        ttl = client.db.expire_at(source)
        dest_db.set_expire(dest, ttl) if ttl
        dest_db.signal_modified(dest)
        Helpers.dirty(client)
        1
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.move(client, argv)
        key = T.must(argv[1])
        target = client.server.db(Helpers.int(T.must(argv[2])))
        raise CommandError.generic("source and destination objects are the same") if target.equal?(client.db)

        value = client.db.lookup(key)
        return 0 if value.nil? || target.exists?(key)

        ttl = client.db.expire_at(key)
        client.db.delete(key)
        target.set(key, value)
        target.set_expire(key, ttl) if ttl
        Helpers.touch(client, key)
        target.signal_modified(key)
        1
      end

      # --- OBJECT ------------------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.object(client, argv)
        sub = T.must(argv[1]).downcase
        if sub == "help"
          return ["OBJECT <subcommand> [<arg> ...]", "ENCODING <key>", "REFCOUNT <key>", "IDLETIME <key>", "FREQ <key>"]
        end

        key = T.must(argv[2])
        value = client.db.lookup(key)
        raise CommandError.generic("no such key") if value.nil?

        case sub
        when "encoding" then Types.encoding_for(value, client.server.config).serialize
        when "refcount" then 1
        when "idletime" then 0
        when "freq" then 0
        else raise CommandError.generic("Unknown OBJECT subcommand or wrong number of arguments for '#{argv[1]}'")
        end
      end

      sig { params(value: T.untyped).returns(T.untyped) }
      def self.deep_copy(value)
        case value
        when String then value.dup
        when Types::List then Types::List.new(value.elements.dup)
        when Types::Hash then Types::Hash.new(value.fields.dup)
        when Types::Set then Types::Set.new(value.members)
        when Types::SortedSet
          copy = Types::SortedSet.new
          value.entries.each { |member, score| copy.add(member, score) }
          copy
        else value
        end
      end

      sig { params(table: CommandTable).void }
      def self.install(table)
        table.add("del", -2, [CommandFlag::Write]) { |c, a| del(c, a) }
        table.add("unlink", -2, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| del(c, a) }
        table.add("exists", -2, [CommandFlag::Readonly, CommandFlag::Fast]) { |c, a| exists(c, a) }
        table.add("touch", -2, [CommandFlag::Readonly, CommandFlag::Fast]) { |c, a| touch(c, a) }
        table.add("type", 2, [CommandFlag::Readonly, CommandFlag::Fast]) { |c, a| type(c, a) }
        table.add("expire", -3, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| expire(c, a) }
        table.add("pexpire", -3, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| pexpire(c, a) }
        table.add("expireat", -3, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| expireat(c, a) }
        table.add("pexpireat", -3, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| pexpireat(c, a) }
        table.add("persist", 2, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| persist(c, a) }
        table.add("ttl", 2, [CommandFlag::Readonly, CommandFlag::Fast]) { |c, a| ttl(c, a) }
        table.add("pttl", 2, [CommandFlag::Readonly, CommandFlag::Fast]) { |c, a| pttl(c, a) }
        table.add("expiretime", 2, [CommandFlag::Readonly, CommandFlag::Fast]) { |c, a| expiretime(c, a) }
        table.add("pexpiretime", 2, [CommandFlag::Readonly, CommandFlag::Fast]) { |c, a| pexpiretime(c, a) }
        table.add("keys", 2, [CommandFlag::Readonly]) { |c, a| keys(c, a) }
        table.add("randomkey", 1, [CommandFlag::Readonly]) { |c, a| randomkey(c, a) }
        table.add("dbsize", 1, [CommandFlag::Readonly, CommandFlag::Fast]) { |c, a| dbsize(c, a) }
        table.add("scan", -2, [CommandFlag::Readonly]) { |c, a| scan(c, a) }
        table.add("rename", 3, [CommandFlag::Write]) { |c, a| rename(c, a) }
        table.add("renamenx", 3, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| renamenx(c, a) }
        table.add("copy", -3, [CommandFlag::Write]) { |c, a| copy(c, a) }
        table.add("move", 3, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| move(c, a) }
        table.add("object", -2, [CommandFlag::Readonly]) { |c, a| object(c, a) }
      end
    end
  end
end

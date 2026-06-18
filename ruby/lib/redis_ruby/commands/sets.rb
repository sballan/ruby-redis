# typed: strict
# frozen_string_literal: true

module RedisRuby
  module Commands
    # Set commands, including the SINTER/SUNION/SDIFF algebra and their STORE
    # variants.
    module Sets
      extend T::Sig

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.sadd(client, argv)
        key = T.must(argv[1])
        set = client.db.lookup_set(key)
        if set.nil?
          set = Types::Set.new
          client.db.set(key, set)
        end
        added = (argv[2..] || []).count { |member| set.add(member) }
        Helpers.touch(client, key) if added.positive?
        added
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.srem(client, argv)
        key = T.must(argv[1])
        set = client.db.lookup_set(key)
        return 0 if set.nil?

        removed = (argv[2..] || []).count { |member| set.remove(member) }
        if removed.positive?
          client.db.delete(key) if set.empty?
          Helpers.touch(client, key)
        end
        removed
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.smembers(client, argv)
        Reply::Set.new(members(client, T.must(argv[1])))
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.sismember(client, argv)
        client.db.lookup_set(T.must(argv[1]))&.include?(T.must(argv[2])) ? 1 : 0
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.smismember(client, argv)
        set = client.db.lookup_set(T.must(argv[1]))
        (argv[2..] || []).map { |member| set&.include?(member) ? 1 : 0 }
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.scard(client, argv) = client.db.lookup_set(T.must(argv[1]))&.size || 0

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.spop(client, argv)
        key = T.must(argv[1])
        set = client.db.lookup_set(key)
        has_count = argv.length >= 3
        count = has_count ? Helpers.positive_int(T.must(argv[2])) : 1
        return has_count ? Reply::Set.new([]) : nil if set.nil?

        chosen = T.cast(set.members.sample(count), T::Array[String])
        chosen.each { |member| set.remove(member) }
        if chosen.any?
          client.db.delete(key) if set.empty?
          Helpers.touch(client, key)
        end
        has_count ? Reply::Set.new(chosen) : chosen.first
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.srandmember(client, argv)
        set = client.db.lookup_set(T.must(argv[1]))
        if argv.length == 2
          return nil if set.nil?

          return set.random_member
        end

        count = Helpers.int(T.must(argv[2]))
        return [] if set.nil?

        if count.negative?
          Array.new(count.abs) { set.random_member }.compact
        else
          set.members.sample(count)
        end
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.smove(client, argv)
        source = T.must(argv[1])
        dest = T.must(argv[2])
        member = T.must(argv[3])
        src_set = client.db.lookup_set(source)
        dest_set = client.db.lookup_set(dest)
        return 0 if src_set.nil? || !src_set.remove(member)

        if dest_set.nil?
          dest_set = Types::Set.new
          client.db.set(dest, dest_set)
        end
        dest_set.add(member)
        client.db.delete(source) if src_set.empty?
        Helpers.touch(client, source)
        Helpers.touch(client, dest)
        1
      end

      # --- Algebra -----------------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.sinter(client, argv) = Reply::Set.new(intersect(client, argv[1..] || []))

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.sunion(client, argv) = Reply::Set.new(union(client, argv[1..] || []))

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.sdiff(client, argv) = Reply::Set.new(difference(client, argv[1..] || []))

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.sinterstore(client, argv) = store(client, T.must(argv[1]), intersect(client, argv[2..] || []))

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.sunionstore(client, argv) = store(client, T.must(argv[1]), union(client, argv[2..] || []))

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.sdiffstore(client, argv) = store(client, T.must(argv[1]), difference(client, argv[2..] || []))

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.sintercard(client, argv)
        numkeys = Helpers.int(T.must(argv[1]))
        raise CommandError.generic("numkeys should be greater than 0") if numkeys <= 0

        keys = argv[2, numkeys] || []
        limit = 0
        rest = 2 + numkeys
        if argv[rest]
          raise CommandError.syntax unless T.must(argv[rest]).casecmp?("limit")

          limit = Helpers.int(T.must(argv[rest + 1]))
          raise CommandError.generic("LIMIT can't be negative") if limit.negative?
        end

        result = intersect(client, keys)
        limit.positive? ? [result.size, limit].min : result.size
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.sscan(client, argv)
        key = T.must(argv[1])
        cursor = Helpers.parse_cursor(T.must(argv[2]))
        match = T.let(nil, T.nilable(String))
        count = 10
        index = 3
        while index < argv.length
          case T.must(argv[index]).downcase
          when "match" then match = argv[index + 1]; index += 2
          when "count" then count = Helpers.int(T.must(argv[index + 1])); index += 2
          else raise CommandError.syntax
          end
        end

        set = client.db.lookup_set(key)
        return ["0", []] if set.nil?

        next_cursor, slice = Helpers.scan_window(set.members, cursor, count)
        slice = slice.select { |member| match.nil? || Util.glob_match?(match, member) }
        [next_cursor.to_s, slice]
      end

      # --- Internals ---------------------------------------------------------

      sig { params(client: Client, key: String).returns(T::Array[String]) }
      def self.members(client, key) = client.db.lookup_set(key)&.members || []

      sig { params(client: Client, keys: T::Array[String]).returns(T::Array[String]) }
      def self.intersect(client, keys)
        return [] if keys.empty?

        sets = keys.map { |key| client.db.lookup_set(key) }
        return [] if sets.any?(&:nil?)

        smallest = T.must(sets.min_by { |set| T.must(set).size })
        smallest.members.select { |member| sets.all? { |set| T.must(set).include?(member) } }
      end

      sig { params(client: Client, keys: T::Array[String]).returns(T::Array[String]) }
      def self.union(client, keys)
        result = T.let([], T::Array[String])
        seen = {}
        keys.each do |key|
          members(client, key).each do |member|
            next if seen[member]

            seen[member] = true
            result << member
          end
        end
        result
      end

      sig { params(client: Client, keys: T::Array[String]).returns(T::Array[String]) }
      def self.difference(client, keys)
        return [] if keys.empty?

        base = members(client, T.must(keys.first))
        others = (keys[1..] || []).flat_map { |key| members(client, key) }.to_h { |member| [member, true] }
        base.reject { |member| others[member] }
      end

      sig { params(client: Client, dest: String, result: T::Array[String]).returns(Integer) }
      def self.store(client, dest, result)
        if result.empty?
          client.db.delete(dest)
        else
          client.db.set(dest, Types::Set.new(result))
        end
        Helpers.touch(client, dest)
        result.size
      end

      sig { params(table: CommandTable).void }
      def self.install(table)
        table.add("sadd", -3, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| sadd(c, a) }
        table.add("srem", -3, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| srem(c, a) }
        table.add("smembers", 2, [CommandFlag::Readonly]) { |c, a| smembers(c, a) }
        table.add("sismember", 3, [CommandFlag::Readonly, CommandFlag::Fast]) { |c, a| sismember(c, a) }
        table.add("smismember", -3, [CommandFlag::Readonly, CommandFlag::Fast]) { |c, a| smismember(c, a) }
        table.add("scard", 2, [CommandFlag::Readonly, CommandFlag::Fast]) { |c, a| scard(c, a) }
        table.add("spop", -2, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| spop(c, a) }
        table.add("srandmember", -2, [CommandFlag::Readonly]) { |c, a| srandmember(c, a) }
        table.add("smove", 4, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| smove(c, a) }
        table.add("sinter", -2, [CommandFlag::Readonly]) { |c, a| sinter(c, a) }
        table.add("sunion", -2, [CommandFlag::Readonly]) { |c, a| sunion(c, a) }
        table.add("sdiff", -2, [CommandFlag::Readonly]) { |c, a| sdiff(c, a) }
        table.add("sinterstore", -3, [CommandFlag::Write]) { |c, a| sinterstore(c, a) }
        table.add("sunionstore", -3, [CommandFlag::Write]) { |c, a| sunionstore(c, a) }
        table.add("sdiffstore", -3, [CommandFlag::Write]) { |c, a| sdiffstore(c, a) }
        table.add("sintercard", -3, [CommandFlag::Readonly]) { |c, a| sintercard(c, a) }
        table.add("sscan", -3, [CommandFlag::Readonly]) { |c, a| sscan(c, a) }
      end
    end
  end
end

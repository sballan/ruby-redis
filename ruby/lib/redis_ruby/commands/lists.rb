# typed: strict
# frozen_string_literal: true

module RedisRuby
  module Commands
    # List commands. Blocking variants (BLPOP/BRPOP/...) are intentionally out
    # of scope for this pass; everything here is non-blocking.
    module Lists
      extend T::Sig

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.lpush(client, argv) = push(client, argv, side: :left, create: true)

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.rpush(client, argv) = push(client, argv, side: :right, create: true)

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.lpushx(client, argv) = push(client, argv, side: :left, create: false)

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.rpushx(client, argv) = push(client, argv, side: :right, create: false)

      sig { params(client: Client, argv: T::Array[String], side: Symbol, create: T::Boolean).returns(T.untyped) }
      def self.push(client, argv, side:, create:)
        key = T.must(argv[1])
        values = argv[2..] || []
        list = client.db.lookup_list(key)
        if list.nil?
          return 0 unless create

          list = Types::List.new
          client.db.set(key, list)
        end

        side == :left ? list.lpush(values) : list.rpush(values)
        Helpers.touch(client, key)
        list.size
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.lpop(client, argv) = pop(client, argv, :left)

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.rpop(client, argv) = pop(client, argv, :right)

      sig { params(client: Client, argv: T::Array[String], side: Symbol).returns(T.untyped) }
      def self.pop(client, argv, side)
        key = T.must(argv[1])
        has_count = argv.length >= 3
        count = T.let(nil, T.nilable(Integer))
        if has_count
          count = Helpers.int(T.must(argv[2]))
          raise CommandError.generic("value is out of range, must be positive") if count.negative?
        end

        list = client.db.lookup_list(key)
        return nil if list.nil?

        popped = side == :left ? list.lpop(count || 1) : list.rpop(count || 1)
        unless popped.empty?
          prune(client, key, list)
          Helpers.touch(client, key)
        end

        has_count ? popped : popped.first
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.llen(client, argv) = client.db.lookup_list(T.must(argv[1]))&.size || 0

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.lrange(client, argv)
        list = client.db.lookup_list(T.must(argv[1]))
        return [] if list.nil?

        window = Helpers.range(Helpers.int(T.must(argv[2])), Helpers.int(T.must(argv[3])), list.size)
        return [] if window.nil?

        list.elements[window[0]..window[1]] || []
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.lindex(client, argv)
        list = client.db.lookup_list(T.must(argv[1]))
        return nil if list.nil?

        index = list.normalize_index(Helpers.int(T.must(argv[2])))
        index.nil? ? nil : list.elements[index]
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.lset(client, argv)
        list = client.db.lookup_list(T.must(argv[1]))
        raise CommandError.generic("no such key") if list.nil?

        index = list.normalize_index(Helpers.int(T.must(argv[2])))
        raise CommandError.raw(CommandError::NEGATIVE_INDEX) if index.nil?

        list.elements[index] = T.must(argv[3])
        Helpers.touch(client, T.must(argv[1]))
        Reply::OK
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.linsert(client, argv)
        key = T.must(argv[1])
        where = T.must(argv[2]).downcase
        raise CommandError.syntax unless %w[before after].include?(where)

        list = client.db.lookup_list(key)
        return 0 if list.nil?

        pivot_index = list.elements.index(T.must(argv[3]))
        return -1 if pivot_index.nil?

        insert_at = where == "before" ? pivot_index : pivot_index + 1
        list.elements.insert(insert_at, T.must(argv[4]))
        Helpers.touch(client, key)
        list.size
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.lrem(client, argv)
        key = T.must(argv[1])
        count = Helpers.int(T.must(argv[2]))
        value = T.must(argv[3])
        list = client.db.lookup_list(key)
        return 0 if list.nil?

        removed = remove_occurrences(list, count, value)
        if removed.positive?
          prune(client, key, list)
          Helpers.touch(client, key)
        end
        removed
      end

      sig { params(list: Types::List, count: Integer, value: String).returns(Integer) }
      def self.remove_occurrences(list, count, value)
        elements = list.elements
        if count.zero?
          before = elements.size
          elements.reject! { |element| element == value }
          return before - elements.size
        end

        limit = count.abs
        indexes = (0...elements.size).to_a
        indexes.reverse! if count.negative?
        to_delete = T.let([], T::Array[Integer])
        indexes.each do |index|
          break if to_delete.size >= limit
          to_delete << index if elements[index] == value
        end
        to_delete.sort.reverse_each { |index| elements.delete_at(index) }
        to_delete.size
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.ltrim(client, argv)
        key = T.must(argv[1])
        list = client.db.lookup_list(key)
        return Reply::OK if list.nil?

        window = Helpers.range(Helpers.int(T.must(argv[2])), Helpers.int(T.must(argv[3])), list.size)
        list.elements.replace(window.nil? ? [] : (list.elements[window[0]..window[1]] || []))
        prune(client, key, list)
        Helpers.touch(client, key)
        Reply::OK
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.rpoplpush(client, argv)
        move(client, T.must(argv[1]), T.must(argv[2]), :right, :left)
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.lmove(client, argv)
        from = T.must(argv[3]).downcase
        to = T.must(argv[4]).downcase
        raise CommandError.syntax unless %w[left right].include?(from) && %w[left right].include?(to)

        move(client, T.must(argv[1]), T.must(argv[2]), from.to_sym, to.to_sym)
      end

      sig { params(client: Client, source: String, dest: String, from: Symbol, to: Symbol).returns(T.untyped) }
      def self.move(client, source, dest, from, to)
        src_list = client.db.lookup_list(source)
        return nil if src_list.nil?

        dest_list = client.db.lookup_list(dest)
        element = (from == :left ? src_list.lpop(1) : src_list.rpop(1)).first
        return nil if element.nil?

        if dest_list.nil?
          dest_list = Types::List.new
          client.db.set(dest, dest_list)
        end
        to == :left ? dest_list.lpush([element]) : dest_list.rpush([element])

        prune(client, source, src_list)
        Helpers.touch(client, source)
        Helpers.touch(client, dest)
        element
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.lpos(client, argv)
        key = T.must(argv[1])
        target = T.must(argv[2])
        rank = T.let(1, Integer)
        count = T.let(nil, T.nilable(Integer))
        maxlen = T.let(0, Integer)
        index = 3
        while index < argv.length
          case T.must(argv[index]).downcase
          when "rank"
            rank = Helpers.int(T.must(argv[index + 1]))
            raise CommandError.generic("RANK can't be zero") if rank.zero?
            index += 2
          when "count"
            count = Helpers.int(T.must(argv[index + 1]))
            raise CommandError.generic("COUNT can't be negative") if count.negative?
            index += 2
          when "maxlen"
            maxlen = Helpers.int(T.must(argv[index + 1]))
            raise CommandError.generic("MAXLEN can't be negative") if maxlen.negative?
            index += 2
          else raise CommandError.syntax
          end
        end

        list = client.db.lookup_list(key)
        return count.nil? ? nil : [] if list.nil?

        matches = find_positions(list.elements, target, rank, count, maxlen)
        count.nil? ? matches.first : matches
      end

      sig do
        params(elements: T::Array[String], target: String, rank: Integer, count: T.nilable(Integer), maxlen: Integer)
          .returns(T::Array[Integer])
      end
      def self.find_positions(elements, target, rank, count, maxlen)
        order = rank.negative? ? (elements.size - 1).downto(0).to_a : (0...elements.size).to_a
        skip = rank.abs - 1
        limit = count.nil? ? 1 : (count.zero? ? Float::INFINITY : count)
        scanned = 0
        results = T.let([], T::Array[Integer])
        order.each do |position|
          scanned += 1
          break if maxlen.positive? && scanned > maxlen
          next unless elements[position] == target

          if skip.positive?
            skip -= 1
            next
          end
          results << position
          break if results.size >= limit
        end
        results
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.lmpop(client, argv)
        numkeys = Helpers.int(T.must(argv[1]))
        raise CommandError.generic("numkeys should be greater than 0") if numkeys <= 0

        keys = (argv[2, numkeys] || [])
        rest_index = 2 + numkeys
        side = T.must(argv[rest_index]).downcase
        raise CommandError.syntax unless %w[left right].include?(side)

        count = 1
        if argv[rest_index + 1]
          raise CommandError.syntax unless T.must(argv[rest_index + 1]).casecmp?("count")

          count = Helpers.positive_int(T.must(argv[rest_index + 2]))
          raise CommandError.generic("count should be greater than 0") if count <= 0
        end

        keys.each do |key|
          list = client.db.lookup_list(key)
          next if list.nil? || list.empty?

          popped = side == "left" ? list.lpop(count) : list.rpop(count)
          prune(client, key, list)
          Helpers.touch(client, key)
          return [key, popped]
        end
        nil
      end

      sig { params(client: Client, key: String, list: Types::List).void }
      def self.prune(client, key, list)
        client.db.delete(key) if list.empty?
      end

      sig { params(table: CommandTable).void }
      def self.install(table)
        table.add("lpush", -3, %i[write fast]) { |c, a| lpush(c, a) }
        table.add("rpush", -3, %i[write fast]) { |c, a| rpush(c, a) }
        table.add("lpushx", -3, %i[write fast]) { |c, a| lpushx(c, a) }
        table.add("rpushx", -3, %i[write fast]) { |c, a| rpushx(c, a) }
        table.add("lpop", -2, %i[write fast]) { |c, a| lpop(c, a) }
        table.add("rpop", -2, %i[write fast]) { |c, a| rpop(c, a) }
        table.add("llen", 2, %i[readonly fast]) { |c, a| llen(c, a) }
        table.add("lrange", 4, %i[readonly]) { |c, a| lrange(c, a) }
        table.add("lindex", 3, %i[readonly]) { |c, a| lindex(c, a) }
        table.add("lset", 4, %i[write]) { |c, a| lset(c, a) }
        table.add("linsert", 5, %i[write]) { |c, a| linsert(c, a) }
        table.add("lrem", 4, %i[write]) { |c, a| lrem(c, a) }
        table.add("ltrim", 4, %i[write]) { |c, a| ltrim(c, a) }
        table.add("rpoplpush", 3, %i[write]) { |c, a| rpoplpush(c, a) }
        table.add("lmove", 5, %i[write]) { |c, a| lmove(c, a) }
        table.add("lpos", -3, %i[readonly]) { |c, a| lpos(c, a) }
        table.add("lmpop", -4, %i[write]) { |c, a| lmpop(c, a) }
      end
    end
  end
end

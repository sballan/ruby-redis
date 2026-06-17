# typed: strict
# frozen_string_literal: true

module RedisRuby
  module Commands
    # Hash commands.
    module Hashes
      extend T::Sig

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.hset(client, argv)
        pairs = argv[2..] || []
        raise CommandError.wrong_args("hset") if pairs.empty? || pairs.length.odd?

        hash = fetch_or_create(client, T.must(argv[1]))
        added = 0
        pairs.each_slice(2) { |field, value| added += 1 if hash.set(T.must(field), T.must(value)) }
        Helpers.touch(client, T.must(argv[1]))
        added
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.hmset(client, argv)
        pairs = argv[2..] || []
        raise CommandError.wrong_args("hmset") if pairs.empty? || pairs.length.odd?

        hash = fetch_or_create(client, T.must(argv[1]))
        pairs.each_slice(2) { |field, value| hash.set(T.must(field), T.must(value)) }
        Helpers.touch(client, T.must(argv[1]))
        Reply::OK
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.hsetnx(client, argv)
        key = T.must(argv[1])
        field = T.must(argv[2])
        hash = client.db.lookup_hash(key)
        return 0 if hash&.include?(field)

        hash ||= fetch_or_create(client, key)
        hash.set(field, T.must(argv[3]))
        Helpers.touch(client, key)
        1
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.hget(client, argv)
        client.db.lookup_hash(T.must(argv[1]))&.get(T.must(argv[2]))
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.hmget(client, argv)
        hash = client.db.lookup_hash(T.must(argv[1]))
        (argv[2..] || []).map { |field| hash&.get(field) }
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.hdel(client, argv)
        key = T.must(argv[1])
        hash = client.db.lookup_hash(key)
        return 0 if hash.nil?

        removed = (argv[2..] || []).count { |field| hash.delete(field) }
        if removed.positive?
          client.db.delete(key) if hash.empty?
          Helpers.touch(client, key)
        end
        removed
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.hlen(client, argv) = client.db.lookup_hash(T.must(argv[1]))&.size || 0

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.hexists(client, argv)
        client.db.lookup_hash(T.must(argv[1]))&.include?(T.must(argv[2])) ? 1 : 0
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.hstrlen(client, argv)
        client.db.lookup_hash(T.must(argv[1]))&.get(T.must(argv[2]))&.bytesize || 0
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.hkeys(client, argv) = client.db.lookup_hash(T.must(argv[1]))&.fields&.keys || []

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.hvals(client, argv) = client.db.lookup_hash(T.must(argv[1]))&.fields&.values || []

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.hgetall(client, argv)
        hash = client.db.lookup_hash(T.must(argv[1]))
        Reply::Map.new(hash.nil? ? [] : hash.fields.to_a)
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.hincrby(client, argv)
        key = T.must(argv[1])
        field = T.must(argv[2])
        delta = Helpers.int(T.must(argv[3]))
        hash = fetch_or_create(client, key)
        current = hash.get(field)
        base = current.nil? ? 0 : parse_hash_int(current)
        result = base + delta
        if result < Util::INT64_MIN || result > Util::INT64_MAX
          raise CommandError.generic("increment or decrement would overflow")
        end

        hash.set(field, result.to_s.b)
        Helpers.touch(client, key)
        result
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.hincrbyfloat(client, argv)
        key = T.must(argv[1])
        field = T.must(argv[2])
        increment = Helpers.float(T.must(argv[3]))
        hash = fetch_or_create(client, key)
        current = hash.get(field)
        base = current.nil? ? 0.0 : Util.string_to_float(current)
        result = base + increment
        raise CommandError.generic("increment would produce NaN or Infinity") if result.nan? || result.infinite?

        formatted = Util.format_double(result).b
        hash.set(field, formatted)
        Helpers.touch(client, key)
        formatted
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.hrandfield(client, argv)
        key = T.must(argv[1])
        hash = client.db.lookup_hash(key)
        if argv.length == 2
          return nil if hash.nil?

          return hash.fields.keys.sample
        end

        count = Helpers.int(T.must(argv[2]))
        with_values = argv[3] ? T.must(argv[3]).casecmp?("withvalues") : false
        raise CommandError.syntax if argv[3] && !with_values
        return with_values ? [] : [] if hash.nil?

        fields = sample_fields(hash.fields.keys, count)
        return fields unless with_values

        format_with_values(client, hash, fields)
      end

      sig { params(client: Client, hash: Types::Hash, fields: T::Array[String]).returns(T.untyped) }
      def self.format_with_values(client, hash, fields)
        if client.protocol >= 3
          fields.map { |field| [field, hash.get(field)] }
        else
          fields.flat_map { |field| [field, hash.get(field)] }
        end
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.hscan(client, argv)
        key = T.must(argv[1])
        cursor = Helpers.parse_cursor(T.must(argv[2]))
        match = T.let(nil, T.nilable(String))
        count = 10
        novalues = T.let(false, T::Boolean)
        index = 3
        while index < argv.length
          case T.must(argv[index]).downcase
          when "match" then match = argv[index + 1]; index += 2
          when "count" then count = Helpers.int(T.must(argv[index + 1])); index += 2
          when "novalues" then novalues = true; index += 1
          else raise CommandError.syntax
          end
        end

        hash = client.db.lookup_hash(key)
        return ["0", []] if hash.nil?

        next_cursor, slice = Helpers.scan_window(hash.fields.keys, cursor, count)
        slice = slice.select { |field| match.nil? || Util.glob_match?(match, field) }
        result = novalues ? slice : slice.flat_map { |field| [field, hash.get(field)] }
        [next_cursor.to_s, result]
      end

      sig { params(client: Client, key: String).returns(Types::Hash) }
      def self.fetch_or_create(client, key)
        hash = client.db.lookup_hash(key)
        return hash unless hash.nil?

        hash = Types::Hash.new
        client.db.set(key, hash)
        hash
      end

      sig { params(str: String).returns(Integer) }
      def self.parse_hash_int(str)
        Util.string_to_int(str)
      rescue CommandError
        raise CommandError.generic("hash value is not an integer")
      end

      sig { params(items: T::Array[String], count: Integer).returns(T::Array[String]) }
      def self.sample_fields(items, count)
        return T.cast(items.sample(count), T::Array[String]) unless count.negative?

        Array.new(count.abs) { items.sample }.compact
      end

      sig { params(table: CommandTable).void }
      def self.install(table)
        table.add("hset", -4, %i[write fast]) { |c, a| hset(c, a) }
        table.add("hmset", -4, %i[write fast]) { |c, a| hmset(c, a) }
        table.add("hsetnx", 4, %i[write fast]) { |c, a| hsetnx(c, a) }
        table.add("hget", 3, %i[readonly fast]) { |c, a| hget(c, a) }
        table.add("hmget", -3, %i[readonly fast]) { |c, a| hmget(c, a) }
        table.add("hdel", -3, %i[write fast]) { |c, a| hdel(c, a) }
        table.add("hlen", 2, %i[readonly fast]) { |c, a| hlen(c, a) }
        table.add("hexists", 3, %i[readonly fast]) { |c, a| hexists(c, a) }
        table.add("hstrlen", 3, %i[readonly fast]) { |c, a| hstrlen(c, a) }
        table.add("hkeys", 2, %i[readonly]) { |c, a| hkeys(c, a) }
        table.add("hvals", 2, %i[readonly]) { |c, a| hvals(c, a) }
        table.add("hgetall", 2, %i[readonly]) { |c, a| hgetall(c, a) }
        table.add("hincrby", 4, %i[write fast]) { |c, a| hincrby(c, a) }
        table.add("hincrbyfloat", 4, %i[write fast]) { |c, a| hincrbyfloat(c, a) }
        table.add("hrandfield", -2, %i[readonly]) { |c, a| hrandfield(c, a) }
        table.add("hscan", -3, %i[readonly]) { |c, a| hscan(c, a) }
      end
    end
  end
end

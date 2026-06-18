# typed: strict
# frozen_string_literal: true

module RedisRuby
  module Commands
    # Sorted-set commands: ZADD and its option matrix, the rank/score lookups,
    # the BYSCORE/BYLEX/REV range family, the set-algebra STORE variants and
    # the pop/scan helpers.
    module SortedSets
      extend T::Sig

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.zadd(client, argv)
        key = T.must(argv[1])
        nx = xx = gt = lt = ch = incr = T.let(false, T::Boolean)
        index = 2
        while index < argv.length
          case T.must(argv[index]).downcase
          when "nx" then nx = true
          when "xx" then xx = true
          when "gt" then gt = true
          when "lt" then lt = true
          when "ch" then ch = true
          when "incr" then incr = true
          else break
          end
          index += 1
        end

        pairs = argv[index..] || []
        raise CommandError.syntax if pairs.empty? || pairs.length.odd?
        raise CommandError.generic("GT, LT, and/or NX options at the same time are not compatible") if nx && (gt || lt)
        raise CommandError.generic("GT and LT options at the same time are not compatible") if gt && lt
        raise CommandError.generic("XX and NX options at the same time are not compatible") if nx && xx
        raise CommandError.generic("INCR option supports a single increment-element pair") if incr && pairs.length > 2

        parsed = pairs.each_slice(2).map { |score, member| [Util.string_to_float(T.must(score)), T.must(member)] }

        zset = client.db.lookup_zset(key)
        preexisting = !zset.nil?
        zset ||= Types::SortedSet.new
        added = changed = 0
        incr_result = T.let(nil, T.nilable(Float))

        parsed.each do |score, member|
          exists = zset.include?(member)
          current = zset.score(member)
          next if nx && exists
          next if xx && !exists

          if incr
            new_score = (current || 0.0) + score
            raise CommandError.generic("resulting score is not a number (NaN)") if new_score.nan?
            next if exists && gt && new_score <= T.must(current)
            next if exists && lt && new_score >= T.must(current)

            zset.add(member, new_score)
            added += 1 unless exists
            changed += 1
            incr_result = new_score
          elsif exists
            next if gt && score <= T.must(current)
            next if lt && score >= T.must(current)

            if score != current
              zset.add(member, score)
              changed += 1
            end
          else
            zset.add(member, score)
            added += 1
            changed += 1
          end
        end

        client.db.set(key, zset) if !preexisting && !zset.empty?
        Helpers.touch(client, key) if changed.positive?

        if incr
          return incr_result.nil? ? nil : Reply::Double.new(incr_result)
        end

        ch ? changed : added
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.zincrby(client, argv)
        key = T.must(argv[1])
        increment = Util.string_to_float(T.must(argv[2]))
        member = T.must(argv[3])
        zset = fetch_or_create(client, key)
        new_score = (zset.score(member) || 0.0) + increment
        raise CommandError.generic("resulting score is not a number (NaN)") if new_score.nan?

        zset.add(member, new_score)
        Helpers.touch(client, key)
        Reply::Double.new(new_score)
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.zscore(client, argv)
        score = client.db.lookup_zset(T.must(argv[1]))&.score(T.must(argv[2]))
        score.nil? ? nil : Reply::Double.new(score)
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.zmscore(client, argv)
        zset = client.db.lookup_zset(T.must(argv[1]))
        (argv[2..] || []).map do |member|
          score = zset&.score(member)
          score.nil? ? nil : Reply::Double.new(score)
        end
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.zcard(client, argv) = client.db.lookup_zset(T.must(argv[1]))&.size || 0

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.zrem(client, argv)
        key = T.must(argv[1])
        zset = client.db.lookup_zset(key)
        return 0 if zset.nil?

        removed = (argv[2..] || []).count { |member| zset.remove(member) }
        if removed.positive?
          client.db.delete(key) if zset.empty?
          Helpers.touch(client, key)
        end
        removed
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.zrank(client, argv) = rank(client, argv, reverse: false)

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.zrevrank(client, argv) = rank(client, argv, reverse: true)

      sig { params(client: Client, argv: T::Array[String], reverse: T::Boolean).returns(T.untyped) }
      def self.rank(client, argv, reverse:)
        with_score = argv[3] ? T.must(argv[3]).casecmp?("withscore") : false
        raise CommandError.syntax if argv[3] && !with_score

        zset = client.db.lookup_zset(T.must(argv[1]))
        return nil if zset.nil?

        position = reverse ? zset.revrank(T.must(argv[2])) : zset.rank(T.must(argv[2]))
        return nil if position.nil?

        with_score ? [position, Reply::Double.new(T.must(zset.score(T.must(argv[2]))))] : position
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.zcount(client, argv)
        zset = client.db.lookup_zset(T.must(argv[1]))
        return 0 if zset.nil?

        score_filter(zset, T.must(argv[2]), T.must(argv[3])).size
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.zlexcount(client, argv)
        zset = client.db.lookup_zset(T.must(argv[1]))
        return 0 if zset.nil?

        lex_filter(zset, T.must(argv[2]), T.must(argv[3])).size
      end

      # --- Ranges ------------------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.zrange(client, argv)
        zset = client.db.lookup_zset(T.must(argv[1]))
        return [] if zset.nil?

        entries, withscores = range_entries(zset, T.must(argv[2]), T.must(argv[3]), argv[4..] || [])
        emit_entries(client, entries, withscores)
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.zrevrange(client, argv)
        zset = client.db.lookup_zset(T.must(argv[1]))
        return [] if zset.nil?

        options = ["rev"]
        options << "withscores" if argv[4] && T.must(argv[4]).casecmp?("withscores")
        entries, withscores = range_entries(zset, T.must(argv[2]), T.must(argv[3]), options)
        emit_entries(client, entries, withscores)
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.zrangebyscore(client, argv) = by_score(client, argv, reverse: false)

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.zrevrangebyscore(client, argv) = by_score(client, argv, reverse: true)

      sig { params(client: Client, argv: T::Array[String], reverse: T::Boolean).returns(T.untyped) }
      def self.by_score(client, argv, reverse:)
        zset = client.db.lookup_zset(T.must(argv[1]))
        return [] if zset.nil?

        options = ["byscore"]
        options << "rev" if reverse
        legacy_tail(argv[4..] || [], options)
        entries, withscores = range_entries(zset, T.must(argv[2]), T.must(argv[3]), options)
        emit_entries(client, entries, withscores)
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.zrangebylex(client, argv) = by_lex(client, argv, reverse: false)

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.zrevrangebylex(client, argv) = by_lex(client, argv, reverse: true)

      sig { params(client: Client, argv: T::Array[String], reverse: T::Boolean).returns(T.untyped) }
      def self.by_lex(client, argv, reverse:)
        zset = client.db.lookup_zset(T.must(argv[1]))
        return [] if zset.nil?

        options = ["bylex"]
        options << "rev" if reverse
        legacy_tail(argv[4..] || [], options)
        entries, = range_entries(zset, T.must(argv[2]), T.must(argv[3]), options)
        emit_entries(client, entries, false)
      end

      # Translate the legacy "[WITHSCORES] [LIMIT off count]" tail into unified
      # ZRANGE option tokens.
      sig { params(tail: T::Array[String], options: T::Array[String]).void }
      def self.legacy_tail(tail, options)
        index = 0
        while index < tail.length
          case T.must(tail[index]).downcase
          when "withscores" then options << "withscores"; index += 1
          when "limit"
            options.push("limit", T.must(tail[index + 1]), T.must(tail[index + 2]))
            index += 3
          else raise CommandError.syntax
          end
        end
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.zrangestore(client, argv)
        dest = T.must(argv[1])
        zset = client.db.lookup_zset(T.must(argv[2]))
        entries = zset.nil? ? [] : range_entries(zset, T.must(argv[3]), T.must(argv[4]), argv[5..] || []).first

        if entries.empty?
          deleted = client.db.delete(dest)
          Helpers.touch(client, dest) if deleted
          return 0
        end

        result = Types::SortedSet.new
        entries.each { |member, score| result.add(member, score) }
        client.db.set(dest, result)
        Helpers.touch(client, dest)
        result.size
      end

      sig do
        params(zset: Types::SortedSet, spec1: String, spec2: String, options: T::Array[String])
          .returns([T::Array[[String, Float]], T::Boolean])
      end
      def self.range_entries(zset, spec1, spec2, options)
        byscore = bylex = rev = withscores = T.let(false, T::Boolean)
        has_limit = T.let(false, T::Boolean)
        offset = 0
        count = -1
        index = 0
        while index < options.length
          case T.must(options[index]).downcase
          when "byscore" then byscore = true; index += 1
          when "bylex" then bylex = true; index += 1
          when "rev" then rev = true; index += 1
          when "withscores" then withscores = true; index += 1
          when "limit"
            offset = Util.string_to_int(T.must(options[index + 1]))
            count = Util.string_to_int(T.must(options[index + 2]))
            has_limit = true
            index += 3
          else raise CommandError.syntax
          end
        end
        raise CommandError.syntax if byscore && bylex
        raise CommandError.generic("syntax error, LIMIT is only supported in combination with either BYSCORE or BYLEX") if has_limit && !(byscore || bylex)
        raise CommandError.generic("syntax error, WITHSCORES not supported in combination with BYLEX") if withscores && bylex

        entries =
          if bylex
            low, high = rev ? [spec2, spec1] : [spec1, spec2]
            result = lex_filter(zset, low, high)
            rev ? result.reverse : result
          elsif byscore
            low, high = rev ? [spec2, spec1] : [spec1, spec2]
            result = score_filter(zset, low, high)
            rev ? result.reverse : result
          else
            sequence = rev ? zset.entries.reverse : zset.entries
            window = Helpers.range(Util.string_to_int(spec1), Util.string_to_int(spec2), sequence.size)
            window.nil? ? [] : (sequence[window[0]..window[1]] || [])
          end

        entries = apply_limit(entries, offset, count) if has_limit
        [entries, withscores]
      end

      sig { params(entries: T::Array[[String, Float]], offset: Integer, count: Integer).returns(T::Array[[String, Float]]) }
      def self.apply_limit(entries, offset, count)
        return [] if offset.negative?

        count.negative? ? (entries[offset..] || []) : (entries[offset, count] || [])
      end

      # --- Pop / random ------------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.zpopmin(client, argv) = pop(client, argv, min: true)

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.zpopmax(client, argv) = pop(client, argv, min: false)

      sig { params(client: Client, argv: T::Array[String], min: T::Boolean).returns(T.untyped) }
      def self.pop(client, argv, min:)
        key = T.must(argv[1])
        count = argv[2] ? Helpers.positive_int(T.must(argv[2])) : 1
        zset = client.db.lookup_zset(key)
        return [] if zset.nil?

        entries = min ? zset.entries.first(count) : zset.entries.reverse.first(count)
        entries.each { |member, _| zset.remove(member) }
        if entries.any?
          client.db.delete(key) if zset.empty?
          Helpers.touch(client, key)
        end
        emit_entries(client, entries, true)
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.zmpop(client, argv)
        numkeys = Helpers.int(T.must(argv[1]))
        raise CommandError.generic("numkeys should be greater than 0") if numkeys <= 0

        keys = argv[2, numkeys] || []
        rest = 2 + numkeys
        where = T.must(argv[rest]).downcase
        raise CommandError.syntax unless %w[min max].include?(where)

        count = 1
        if argv[rest + 1]
          raise CommandError.syntax unless T.must(argv[rest + 1]).casecmp?("count")

          count = Helpers.positive_int(T.must(argv[rest + 2]))
        end

        keys.each do |key|
          zset = client.db.lookup_zset(key)
          next if zset.nil? || zset.empty?

          entries = where == "min" ? zset.entries.first(count) : zset.entries.reverse.first(count)
          entries.each { |member, _| zset.remove(member) }
          client.db.delete(key) if zset.empty?
          Helpers.touch(client, key)
          return [key, entries.map { |member, score| [member, Util.format_double(score)] }]
        end
        nil
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.zrandmember(client, argv)
        key = T.must(argv[1])
        zset = client.db.lookup_zset(key)
        if argv.length == 2
          return nil if zset.nil?

          return zset.sorted.sample
        end

        count = Helpers.int(T.must(argv[2]))
        with_scores = argv[3] ? T.must(argv[3]).casecmp?("withscores") : false
        raise CommandError.syntax if argv[3] && !with_scores
        return [] if zset.nil?

        members = count.negative? ? Array.new(count.abs) { zset.sorted.sample }.compact : T.cast(zset.sorted.sample(count), T::Array[String])
        entries = members.map { |member| [member, T.must(zset.score(member))] }
        emit_entries(client, entries, with_scores)
      end

      # --- Remove ranges -----------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.zremrangebyrank(client, argv)
        zset = client.db.lookup_zset(T.must(argv[1]))
        return 0 if zset.nil?

        window = Helpers.range(Helpers.int(T.must(argv[2])), Helpers.int(T.must(argv[3])), zset.size)
        targets = window.nil? ? [] : (zset.entries[window[0]..window[1]] || [])
        remove_entries(client, T.must(argv[1]), zset, targets)
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.zremrangebyscore(client, argv)
        zset = client.db.lookup_zset(T.must(argv[1]))
        return 0 if zset.nil?

        remove_entries(client, T.must(argv[1]), zset, score_filter(zset, T.must(argv[2]), T.must(argv[3])))
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.zremrangebylex(client, argv)
        zset = client.db.lookup_zset(T.must(argv[1]))
        return 0 if zset.nil?

        remove_entries(client, T.must(argv[1]), zset, lex_filter(zset, T.must(argv[2]), T.must(argv[3])))
      end

      sig { params(client: Client, key: String, zset: Types::SortedSet, targets: T::Array[[String, Float]]).returns(Integer) }
      def self.remove_entries(client, key, zset, targets)
        targets.each { |member, _| zset.remove(member) }
        if targets.any?
          client.db.delete(key) if zset.empty?
          Helpers.touch(client, key)
        end
        targets.size
      end

      # --- Set algebra -------------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.zunionstore(client, argv) = algebra_store(client, argv, :union)

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.zinterstore(client, argv) = algebra_store(client, argv, :inter)

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.zdiffstore(client, argv) = algebra_store(client, argv, :diff)

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.zunion(client, argv) = algebra_read(client, argv, :union)

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.zinter(client, argv) = algebra_read(client, argv, :inter)

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.zdiff(client, argv) = algebra_read(client, argv, :diff)

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.zintercard(client, argv)
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

        size = combine(client, keys, [], :sum, :inter).size
        limit.positive? ? [size, limit].min : size
      end

      sig { params(client: Client, argv: T::Array[String], op: Symbol).returns(T.untyped) }
      def self.algebra_store(client, argv, op)
        dest = T.must(argv[1])
        numkeys = Helpers.int(T.must(argv[2]))
        raise CommandError.generic("numkeys should be greater than 0") if numkeys <= 0

        keys = argv[3, numkeys] || []
        weights, aggregate = parse_weights(argv[(3 + numkeys)..] || [], numkeys, op)
        scores = combine(client, keys, weights, aggregate, op)

        if scores.empty?
          deleted = client.db.delete(dest)
          Helpers.touch(client, dest) if deleted
          return 0
        end

        result = Types::SortedSet.new
        scores.each { |member, score| result.add(member, score) }
        client.db.set(dest, result)
        Helpers.touch(client, dest)
        result.size
      end

      sig { params(client: Client, argv: T::Array[String], op: Symbol).returns(T.untyped) }
      def self.algebra_read(client, argv, op)
        numkeys = Helpers.int(T.must(argv[1]))
        raise CommandError.generic("numkeys should be greater than 0") if numkeys <= 0

        keys = argv[2, numkeys] || []
        tail = argv[(2 + numkeys)..] || []
        with_scores = tail.any? { |token| token.casecmp?("withscores") }
        tail = tail.reject { |token| token.casecmp?("withscores") }
        weights, aggregate = parse_weights(tail, numkeys, op)
        scores = combine(client, keys, weights, aggregate, op)
        entries = scores.to_a.sort_by { |member, score| [score, member] }
        emit_entries(client, entries, with_scores)
      end

      sig { params(tail: T::Array[String], numkeys: Integer, op: Symbol).returns([T::Array[Float], Symbol]) }
      def self.parse_weights(tail, numkeys, op)
        weights = Array.new(numkeys, 1.0)
        aggregate = T.let(:sum, Symbol)
        index = 0
        while index < tail.length
          case T.must(tail[index]).downcase
          when "weights"
            numkeys.times { |offset| weights[offset] = Util.string_to_float(T.must(tail[index + 1 + offset])) }
            index += 1 + numkeys
          when "aggregate"
            aggregate = T.must(tail[index + 1]).downcase.to_sym
            raise CommandError.syntax unless %i[sum min max].include?(aggregate)

            index += 2
          else raise CommandError.syntax
          end
        end
        [weights, aggregate]
      end

      sig { params(client: Client, keys: T::Array[String], weights: T::Array[Float], aggregate: Symbol, op: Symbol).returns(T::Hash[String, Float]) }
      def self.combine(client, keys, weights, aggregate, op)
        maps = keys.map { |key| weighted_scores(client, key) }
        case op
        when :union then combine_union(maps, weights, aggregate)
        when :inter then combine_inter(maps, weights, aggregate)
        else combine_diff(maps)
        end
      end

      sig { params(maps: T::Array[T::Hash[String, Float]], weights: T::Array[Float], aggregate: Symbol).returns(T::Hash[String, Float]) }
      def self.combine_union(maps, weights, aggregate)
        result = T.let({}, T::Hash[String, Float])
        maps.each_with_index do |map, position|
          weight = weights[position] || 1.0
          map.each do |member, score|
            term = normalize(score * weight)
            result[member] = result.key?(member) ? aggregate_scores(T.must(result[member]), term, aggregate) : term
          end
        end
        result
      end

      sig { params(maps: T::Array[T::Hash[String, Float]], weights: T::Array[Float], aggregate: Symbol).returns(T::Hash[String, Float]) }
      def self.combine_inter(maps, weights, aggregate)
        return {} if maps.empty? || maps.any?(&:empty?)

        smallest = T.must(maps.min_by(&:size))
        result = T.let({}, T::Hash[String, Float])
        smallest.each_key do |member|
          next unless maps.all? { |map| map.key?(member) }

          value = T.let(nil, T.nilable(Float))
          maps.each_with_index do |map, position|
            term = normalize(T.must(map[member]) * (weights[position] || 1.0))
            value = value.nil? ? term : aggregate_scores(value, term, aggregate)
          end
          result[member] = T.must(value)
        end
        result
      end

      sig { params(maps: T::Array[T::Hash[String, Float]]).returns(T::Hash[String, Float]) }
      def self.combine_diff(maps)
        return {} if maps.empty?

        base = T.must(maps.first).dup
        (maps[1..] || []).each { |map| map.each_key { |member| base.delete(member) } }
        base
      end

      sig { params(a: Float, b: Float, aggregate: Symbol).returns(Float) }
      def self.aggregate_scores(a, b, aggregate)
        case aggregate
        when :min then [a, b].min
        when :max then [a, b].max
        else normalize(a + b)
        end
      end

      sig { params(value: Float).returns(Float) }
      def self.normalize(value) = value.nan? ? 0.0 : value

      sig { params(client: Client, key: String).returns(T::Hash[String, Float]) }
      def self.weighted_scores(client, key)
        value = client.db.lookup(key)
        case value
        when nil then {}
        when Types::SortedSet then value.entries.to_h
        when Types::Set then value.members.to_h { |member| [member, 1.0] }
        else raise CommandError.wrong_type
        end
      end

      # --- Scan --------------------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.zscan(client, argv)
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

        zset = client.db.lookup_zset(key)
        return ["0", []] if zset.nil?

        next_cursor, slice = Helpers.scan_window(zset.sorted, cursor, count)
        slice = slice.select { |member| match.nil? || Util.glob_match?(match, member) }
        [next_cursor.to_s, slice.flat_map { |member| [member, Util.format_double(T.must(zset.score(member)))] }]
      end

      # --- Shared helpers ----------------------------------------------------

      sig { params(client: Client, key: String).returns(Types::SortedSet) }
      def self.fetch_or_create(client, key)
        zset = client.db.lookup_zset(key)
        return zset unless zset.nil?

        zset = Types::SortedSet.new
        client.db.set(key, zset)
        zset
      end

      sig { params(client: Client, entries: T::Array[[String, Float]], withscores: T::Boolean).returns(T.untyped) }
      def self.emit_entries(client, entries, withscores)
        return entries.map { |member, _| member } unless withscores

        if client.protocol >= 3
          entries.map { |member, score| [member, Reply::Double.new(score)] }
        else
          entries.flat_map { |member, score| [member, Util.format_double(score)] }
        end
      end

      sig { params(zset: Types::SortedSet, lo_spec: String, hi_spec: String).returns(T::Array[[String, Float]]) }
      def self.score_filter(zset, lo_spec, hi_spec)
        lo, lo_excl = parse_score_bound(lo_spec)
        hi, hi_excl = parse_score_bound(hi_spec)
        zset.entries.select do |_member, score|
          (lo_excl ? score > lo : score >= lo) && (hi_excl ? score < hi : score <= hi)
        end
      end

      sig { params(spec: String).returns([Float, T::Boolean]) }
      def self.parse_score_bound(spec)
        exclusive = spec.start_with?("(")
        body = exclusive ? T.must(spec[1..]) : spec
        [parse_range_float(body), exclusive]
      rescue CommandError
        raise CommandError.generic("min or max is not a float")
      end

      sig { params(body: String).returns(Float) }
      def self.parse_range_float(body) = Util.string_to_float(body)

      sig { params(zset: Types::SortedSet, lo_spec: String, hi_spec: String).returns(T::Array[[String, Float]]) }
      def self.lex_filter(zset, lo_spec, hi_spec)
        lo = parse_lex_bound(lo_spec)
        hi = parse_lex_bound(hi_spec)
        zset.entries.select { |member, _| lex_ge?(member, lo) && lex_le?(member, hi) }
      end

      sig { params(spec: String).returns([Symbol, String]) }
      def self.parse_lex_bound(spec)
        return [:neg, ""] if spec == "-"
        return [:pos, ""] if spec == "+"

        case spec.getbyte(0)
        when 91 then [:incl, T.must(spec.byteslice(1, spec.bytesize - 1))] # [
        when 40 then [:excl, T.must(spec.byteslice(1, spec.bytesize - 1))] # (
        else raise CommandError.generic("min or max not valid string range item")
        end
      end

      sig { params(member: String, bound: [Symbol, String]).returns(T::Boolean) }
      def self.lex_ge?(member, bound)
        case bound[0]
        when :neg then true
        when :pos then false
        when :incl then member >= bound[1]
        else member > bound[1]
        end
      end

      sig { params(member: String, bound: [Symbol, String]).returns(T::Boolean) }
      def self.lex_le?(member, bound)
        case bound[0]
        when :neg then false
        when :pos then true
        when :incl then member <= bound[1]
        else member < bound[1]
        end
      end

      sig { params(table: CommandTable).void }
      def self.install(table)
        table.add("zadd", -4, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| zadd(c, a) }
        table.add("zincrby", 4, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| zincrby(c, a) }
        table.add("zscore", 3, [CommandFlag::Readonly, CommandFlag::Fast]) { |c, a| zscore(c, a) }
        table.add("zmscore", -3, [CommandFlag::Readonly, CommandFlag::Fast]) { |c, a| zmscore(c, a) }
        table.add("zcard", 2, [CommandFlag::Readonly, CommandFlag::Fast]) { |c, a| zcard(c, a) }
        table.add("zrem", -3, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| zrem(c, a) }
        table.add("zrank", -3, [CommandFlag::Readonly, CommandFlag::Fast]) { |c, a| zrank(c, a) }
        table.add("zrevrank", -3, [CommandFlag::Readonly, CommandFlag::Fast]) { |c, a| zrevrank(c, a) }
        table.add("zcount", 4, [CommandFlag::Readonly, CommandFlag::Fast]) { |c, a| zcount(c, a) }
        table.add("zlexcount", 4, [CommandFlag::Readonly, CommandFlag::Fast]) { |c, a| zlexcount(c, a) }
        table.add("zrange", -4, [CommandFlag::Readonly]) { |c, a| zrange(c, a) }
        table.add("zrevrange", -4, [CommandFlag::Readonly]) { |c, a| zrevrange(c, a) }
        table.add("zrangebyscore", -4, [CommandFlag::Readonly]) { |c, a| zrangebyscore(c, a) }
        table.add("zrevrangebyscore", -4, [CommandFlag::Readonly]) { |c, a| zrevrangebyscore(c, a) }
        table.add("zrangebylex", -4, [CommandFlag::Readonly]) { |c, a| zrangebylex(c, a) }
        table.add("zrevrangebylex", -4, [CommandFlag::Readonly]) { |c, a| zrevrangebylex(c, a) }
        table.add("zrangestore", -5, [CommandFlag::Write]) { |c, a| zrangestore(c, a) }
        table.add("zpopmin", -2, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| zpopmin(c, a) }
        table.add("zpopmax", -2, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| zpopmax(c, a) }
        table.add("zmpop", -4, [CommandFlag::Write]) { |c, a| zmpop(c, a) }
        table.add("zrandmember", -2, [CommandFlag::Readonly]) { |c, a| zrandmember(c, a) }
        table.add("zremrangebyrank", 4, [CommandFlag::Write]) { |c, a| zremrangebyrank(c, a) }
        table.add("zremrangebyscore", 4, [CommandFlag::Write]) { |c, a| zremrangebyscore(c, a) }
        table.add("zremrangebylex", 4, [CommandFlag::Write]) { |c, a| zremrangebylex(c, a) }
        table.add("zunionstore", -4, [CommandFlag::Write]) { |c, a| zunionstore(c, a) }
        table.add("zinterstore", -4, [CommandFlag::Write]) { |c, a| zinterstore(c, a) }
        table.add("zdiffstore", -4, [CommandFlag::Write]) { |c, a| zdiffstore(c, a) }
        table.add("zunion", -3, [CommandFlag::Readonly]) { |c, a| zunion(c, a) }
        table.add("zinter", -3, [CommandFlag::Readonly]) { |c, a| zinter(c, a) }
        table.add("zdiff", -3, [CommandFlag::Readonly]) { |c, a| zdiff(c, a) }
        table.add("zintercard", -3, [CommandFlag::Readonly]) { |c, a| zintercard(c, a) }
        table.add("zscan", -3, [CommandFlag::Readonly]) { |c, a| zscan(c, a) }
      end
    end
  end
end

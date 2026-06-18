# typed: strict
# frozen_string_literal: true

module RedisRuby
  module Commands
    # Stream commands: the append-only log (XADD/XLEN/XRANGE/XREVRANGE/XDEL/
    # XTRIM/XREAD/XSETID/XINFO) plus the consumer-group machinery (XGROUP,
    # XREADGROUP, XACK, XPENDING, XCLAIM, XAUTOCLAIM). XREAD/XREADGROUP can park
    # the client on its keys via the same reactor blocking path the list/zset
    # blocking commands use; an XADD onto a watched key wakes them.
    module Streams
      extend T::Sig

      MAX = T.let(Types::Stream::MAX_SEQ, Integer)
      ZERO = T.let([0, 0], [Integer, Integer])
      TOP = T.let([Types::Stream::MAX_SEQ, Types::Stream::MAX_SEQ], [Integer, Integer])

      # --- Type access -------------------------------------------------------

      sig { params(client: Client, key: String).returns(T.nilable(Types::Stream)) }
      def self.lookup_stream(client, key)
        T.cast(client.db.check(client.db.lookup(key), Types::Stream), T.nilable(Types::Stream))
      end

      # --- ID parsing / formatting -------------------------------------------

      sig { params(id: [Integer, Integer]).returns(String) }
      def self.fmt(id) = "#{id[0]}-#{id[1]}"

      sig { returns(CommandError) }
      def self.invalid_id = CommandError.generic("Invalid stream ID specified as stream command argument")

      sig { params(str: String).returns(Integer) }
      def self.parse_uint(str)
        raise invalid_id unless str.match?(/\A\d+\z/)

        value = str.to_i
        raise invalid_id if value > MAX

        value
      end

      # Parse a full "ms-seq" (or bare "ms", whose sequence defaults to
      # +default_seq+) into an [ms, seq] tuple.
      sig { params(str: String, default_seq: Integer).returns([Integer, Integer]) }
      def self.parse_strict_id(str, default_seq: 0)
        raise invalid_id if str.empty?

        ms_str, seq_str = str.split("-", 2)
        ms = parse_uint(T.must(ms_str))
        seq = seq_str.nil? ? default_seq : parse_uint(seq_str)
        [ms, seq]
      end

      # Parse a range bound, honoring "-"/"+" and the "(" exclusive prefix.
      # Returns the resolved inclusive [ms, seq] tuple.
      sig { params(str: String, is_start: T::Boolean).returns([Integer, Integer]) }
      def self.parse_range(str, is_start:)
        exclusive = str.start_with?("(")
        body = exclusive ? T.must(str[1..]) : str
        id =
          case body
          when "-" then ZERO
          when "+" then TOP
          else parse_strict_id(body, default_seq: is_start ? 0 : MAX)
          end
        return id unless exclusive

        is_start ? id_next(id) : id_prev(id)
      end

      sig { params(id: [Integer, Integer]).returns([Integer, Integer]) }
      def self.id_next(id)
        ms, seq = id
        seq < MAX ? [ms, seq + 1] : [ms + 1, 0]
      end

      sig { params(id: [Integer, Integer]).returns([Integer, Integer]) }
      def self.id_prev(id)
        ms, seq = id
        if seq.positive? then [ms, seq - 1]
        elsif ms.positive? then [ms - 1, MAX]
        else ZERO
        end
      end

      # --- XADD --------------------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.xadd(client, argv)
        key = T.must(argv[1])
        index = 2
        nomkstream = T.let(false, T::Boolean)
        if T.must(argv[index]).casecmp?("nomkstream")
          nomkstream = true
          index += 1
        end

        trim = T.let(nil, T.nilable([Symbol, String]))
        token = argv[index]
        if token && (token.casecmp?("maxlen") || token.casecmp?("minid"))
          strategy, threshold, _limit, index = parse_trim(argv, index)
          trim = [strategy, threshold]
        end

        id_arg = T.must(argv[index])
        index += 1
        fields = argv[index..] || []
        raise CommandError.wrong_args("xadd") if fields.empty? || fields.length.odd?

        stream = lookup_stream(client, key)
        if stream.nil?
          return nil if nomkstream

          stream = Types::Stream.new
        end

        id = resolve_add_id(stream, id_arg)
        stream.append(id, fields)
        client.db.set(key, stream)
        apply_trim(stream, trim[0], trim[1]) if trim
        Helpers.touch(client, key)
        fmt(id)
      end

      sig { params(stream: Types::Stream, str: String).returns([Integer, Integer]) }
      def self.resolve_add_id(stream, str)
        return auto_id(stream) if str == "*"

        ms_str, seq_str = str.split("-", 2)
        ms = parse_uint(T.must(ms_str))
        return auto_seq(stream, ms) if seq_str.nil? || seq_str == "*"

        id = T.let([ms, parse_uint(seq_str)], [Integer, Integer])
        raise CommandError.generic("The ID specified in XADD must be greater than 0-0") if id == ZERO
        if (id <=> stream.last_id) <= 0
          raise CommandError.generic("The ID specified in XADD is equal or smaller than the target stream top item")
        end

        id
      end

      sig { params(stream: Types::Stream).returns([Integer, Integer]) }
      def self.auto_id(stream)
        now = Util.now_ms
        last = stream.last_id
        return [now, 0] if now > last[0]

        seq = last[1] + 1
        raise CommandError.generic("The stream has exhausted the last possible ID, unable to add more items") if seq > MAX

        [last[0], seq]
      end

      sig { params(stream: Types::Stream, ms: Integer).returns([Integer, Integer]) }
      def self.auto_seq(stream, ms)
        last = stream.last_id
        if ms < last[0]
          raise CommandError.generic("The ID specified in XADD is equal or smaller than the target stream top item")
        end
        return [ms, 0] if ms > last[0]

        seq = last[1] + 1
        raise CommandError.generic("The stream has exhausted the last possible ID, unable to add more items") if seq > MAX

        [ms, seq]
      end

      # --- Trimming ----------------------------------------------------------

      # Parse "MAXLEN|MINID [=|~] threshold [LIMIT n]" from argv[index].
      # Returns [strategy, threshold, limit, next_index].
      sig { params(argv: T::Array[String], index: Integer).returns([Symbol, String, T.nilable(Integer), Integer]) }
      def self.parse_trim(argv, index)
        strategy = T.must(argv[index]).casecmp?("maxlen") ? :maxlen : :minid
        index += 1
        approx = T.let(false, T::Boolean)
        token = argv[index]
        if token && (token == "~" || token == "=")
          approx = token == "~"
          index += 1
        end
        threshold = T.must(argv[index])
        index += 1
        limit = T.let(nil, T.nilable(Integer))
        if (tok = argv[index]) && tok.casecmp?("limit")
          unless approx
            raise CommandError.generic("syntax error, LIMIT cannot be used without the special ~ option")
          end

          limit = Helpers.int(T.must(argv[index + 1]))
          index += 2
        end
        [strategy, threshold, limit, index]
      end

      sig { params(stream: Types::Stream, strategy: Symbol, threshold: String).returns(Integer) }
      def self.apply_trim(stream, strategy, threshold)
        if strategy == :maxlen
          count = Helpers.int(threshold)
          raise CommandError.generic("value is out of range, must be positive") if count.negative?

          stream.trim_maxlen(count)
        else
          stream.trim_minid(parse_strict_id(threshold, default_seq: 0))
        end
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.xtrim(client, argv)
        key = T.must(argv[1])
        token = T.must(argv[2])
        unless token.casecmp?("maxlen") || token.casecmp?("minid")
          raise CommandError.syntax
        end

        strategy, threshold, = parse_trim(argv, 2)
        stream = lookup_stream(client, key)
        return 0 if stream.nil?

        removed = apply_trim(stream, strategy, threshold)
        Helpers.touch(client, key) if removed.positive?
        removed
      end

      # --- XLEN / XRANGE / XREVRANGE / XDEL ----------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.xlen(client, argv) = lookup_stream(client, T.must(argv[1]))&.length || 0

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.xrange(client, argv) = range_command(client, argv, reverse: false)

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.xrevrange(client, argv) = range_command(client, argv, reverse: true)

      sig { params(client: Client, argv: T::Array[String], reverse: T::Boolean).returns(T.untyped) }
      def self.range_command(client, argv, reverse:)
        # XRANGE key start end; XREVRANGE key end start.
        first = T.must(argv[2])
        second = T.must(argv[3])
        start = reverse ? parse_range(second, is_start: true) : parse_range(first, is_start: true)
        stop = reverse ? parse_range(first, is_start: false) : parse_range(second, is_start: false)

        count = T.let(nil, T.nilable(Integer))
        if (tok = argv[4])
          raise CommandError.syntax unless tok.casecmp?("count")

          count = Helpers.int(T.must(argv[5]))
        end

        stream = lookup_stream(client, T.must(argv[1]))
        return [] if stream.nil?

        entries = reverse ? stream.revrange(start, stop, count: count) : stream.range(start, stop, count: count)
        emit(entries)
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.xdel(client, argv)
        key = T.must(argv[1])
        stream = lookup_stream(client, key)
        return 0 if stream.nil?

        removed = (argv[2..] || []).count { |idstr| stream.delete(parse_strict_id(idstr, default_seq: 0)) }
        Helpers.touch(client, key) if removed.positive?
        removed
      end

      # --- XSETID ------------------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.xsetid(client, argv)
        key = T.must(argv[1])
        stream = lookup_stream(client, key)
        raise CommandError.generic("The XSETID command requires the key to exist.") if stream.nil?

        id = parse_strict_id(T.must(argv[2]), default_seq: 0)
        entries_added = T.let(nil, T.nilable(Integer))
        max_deleted = T.let(nil, T.nilable([Integer, Integer]))
        index = 3
        while index < argv.length
          case T.must(argv[index]).downcase
          when "entriesadded" then entries_added = Helpers.int(T.must(argv[index + 1])); index += 2
          when "maxdeletedid" then max_deleted = parse_strict_id(T.must(argv[index + 1]), default_seq: 0); index += 2
          else raise CommandError.syntax
          end
        end

        last = stream.last_entry
        if last && (id <=> last[0]).negative?
          raise CommandError.generic("The ID specified in XSETID is smaller than the target stream top item")
        end

        stream.last_id = id
        stream.entries_added = entries_added if entries_added
        stream.max_deleted_id = max_deleted if max_deleted
        Helpers.touch(client, key)
        Reply::OK
      end

      # --- XREAD -------------------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.xread(client, argv)
        count, block_ms, keys, ids = parse_read(argv, 1, group: false)
        pairs = keys.zip(ids).map do |key, idstr|
          [key, resolve_read_id(client, key, T.must(idstr))]
        end

        result = read_attempt(client, pairs, count)
        return result unless result.empty?
        return Reply::NULL_ARRAY if block_ms.nil? || client.deny_blocking

        client.block_on(keys, block_ms / 1000.0, Reply::NULL_ARRAY) do
          retry_result = read_attempt(client, pairs, count)
          retry_result.empty? ? Blocking::WOULD_BLOCK : retry_result
        end
        Reply::NO_REPLY
      end

      sig { params(client: Client, key: String, idstr: String).returns([Integer, Integer]) }
      def self.resolve_read_id(client, key, idstr)
        return lookup_stream(client, key)&.last_id || ZERO if idstr == "$"

        parse_strict_id(idstr, default_seq: 0)
      end

      sig do
        params(client: Client, pairs: T::Array[[String, [Integer, Integer]]], count: T.nilable(Integer))
          .returns(T::Array[[String, T::Array[T.untyped]]])
      end
      def self.read_attempt(client, pairs, count)
        result = T.let([], T::Array[[String, T::Array[T.untyped]]])
        pairs.each do |key, last_id|
          stream = lookup_stream(client, key)
          next if stream.nil?

          entries = stream.range(id_next(last_id), TOP, count: count)
          result << [key, emit(entries)] unless entries.empty?
        end
        result
      end

      # --- XGROUP ------------------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.xgroup(client, argv)
        sub = T.must(argv[1]).downcase
        case sub
        when "create" then xgroup_create(client, argv)
        when "setid" then xgroup_setid(client, argv)
        when "destroy" then xgroup_destroy(client, argv)
        when "createconsumer" then xgroup_createconsumer(client, argv)
        when "delconsumer" then xgroup_delconsumer(client, argv)
        when "help"
          ["XGROUP CREATE <key> <groupname> <id|$> [option]", "XGROUP SETID <key> <groupname> <id|$>",
           "XGROUP DESTROY <key> <groupname>", "XGROUP CREATECONSUMER <key> <groupname> <consumer>",
           "XGROUP DELCONSUMER <key> <groupname> <consumer>"]
        else raise CommandError.generic("Unknown XGROUP subcommand or wrong number of arguments for '#{argv[1]}'")
        end
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.xgroup_create(client, argv)
        key = T.must(argv[2])
        gname = T.must(argv[3])
        id_arg = T.must(argv[4])
        mkstream = T.let(false, T::Boolean)
        entries_read = T.let(0, Integer)
        index = 5
        while index < argv.length
          case T.must(argv[index]).downcase
          when "mkstream" then mkstream = true; index += 1
          when "entriesread" then entries_read = Helpers.int(T.must(argv[index + 1])); index += 2
          else raise CommandError.syntax
          end
        end

        stream = lookup_stream(client, key)
        if stream.nil?
          unless mkstream
            raise CommandError.generic(
              "The XGROUP subcommand requires the key to exist. Note that for CREATE you may want to use the " \
              "MKSTREAM option to create an empty stream automatically.",
            )
          end

          stream = Types::Stream.new
          client.db.set(key, stream)
          Helpers.touch(client, key)
        end

        raise CommandError.raw("BUSYGROUP Consumer Group name already exists") if stream.groups.key?(gname)

        last = id_arg == "$" ? stream.last_id : parse_strict_id(id_arg, default_seq: 0)
        stream.groups[gname] = Types::StreamGroup.new(last, entries_read: entries_read)
        Helpers.dirty(client)
        Reply::OK
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.xgroup_setid(client, argv)
        key = T.must(argv[2])
        gname = T.must(argv[3])
        stream, group = require_group(client, key, gname)
        last = T.must(argv[4]) == "$" ? stream.last_id : parse_strict_id(T.must(argv[4]), default_seq: 0)
        group.last_delivered_id = last
        Helpers.dirty(client)
        Reply::OK
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.xgroup_destroy(client, argv)
        stream = lookup_stream(client, T.must(argv[2]))
        return 0 if stream.nil?

        existed = stream.groups.delete(T.must(argv[3]))
        Helpers.dirty(client) if existed
        existed ? 1 : 0
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.xgroup_createconsumer(client, argv)
        _stream, group = require_group(client, T.must(argv[2]), T.must(argv[3]))
        cname = T.must(argv[4])
        return 0 if group.consumers.key?(cname)

        group.consumer(cname, Util.now_ms)
        Helpers.dirty(client)
        1
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.xgroup_delconsumer(client, argv)
        _stream, group = require_group(client, T.must(argv[2]), T.must(argv[3]))
        cname = T.must(argv[4])
        pending = group.pending.count { |_id, pel| pel.consumer == cname }
        group.pending.delete_if { |_id, pel| pel.consumer == cname }
        group.consumers.delete(cname)
        Helpers.dirty(client)
        pending
      end

      # --- XREADGROUP --------------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.xreadgroup(client, argv)
        raise CommandError.syntax unless T.must(argv[1]).casecmp?("group")

        gname = T.must(argv[2])
        cname = T.must(argv[3])
        count, block_ms, noack, keys, ids = parse_readgroup(argv, 4)
        pairs = keys.zip(ids).map { |key, idstr| [key, T.must(idstr)] }

        result, history = readgroup_attempt(client, gname, cname, pairs, count, noack)
        return result if history || !result.empty?
        return Reply::NULL_ARRAY if block_ms.nil? || client.deny_blocking

        client.block_on(keys, block_ms / 1000.0, Reply::NULL_ARRAY) do
          retry_result, = readgroup_attempt(client, gname, cname, pairs, count, noack)
          retry_result.empty? ? Blocking::WOULD_BLOCK : retry_result
        end
        Reply::NO_REPLY
      end

      sig do
        params(client: Client, gname: String, cname: String, pairs: T::Array[[String, String]],
               count: T.nilable(Integer), noack: T::Boolean)
          .returns([T::Array[[String, T::Array[T.untyped]]], T::Boolean])
      end
      def self.readgroup_attempt(client, gname, cname, pairs, count, noack)
        now = Util.now_ms
        result = T.let([], T::Array[[String, T::Array[T.untyped]]])
        history = T.let(false, T::Boolean)

        pairs.each do |key, idstr|
          stream, group = require_readgroup(client, key, gname)
          consumer = group.consumer(cname, now)
          consumer.seen_time = now

          if idstr == ">"
            entries = stream.range(id_next(group.last_delivered_id), TOP, count: count)
            unless entries.empty?
              consumer.active_time = now
              entries.each do |id, _fields|
                group.last_delivered_id = id
                group.entries_read += 1
                group.pending[id] = Types::StreamPending.new(cname, now, 1) unless noack
              end
              result << [key, emit(entries)]
            end
          else
            history = true
            from = parse_strict_id(idstr, default_seq: 0)
            pend = group.pending_for(cname).select { |id, _pel| (id <=> from) >= 0 }
            pend = pend.first(count) if count
            rows = pend.map do |id, _pel|
              entry = stream.find(id)
              [fmt(id), entry ? entry[1] : nil]
            end
            result << [key, rows]
          end
        end

        [result, history]
      end

      # --- XACK --------------------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.xack(client, argv)
        stream = lookup_stream(client, T.must(argv[1]))
        group = stream&.groups&.fetch(T.must(argv[2]), nil)
        return 0 if group.nil?

        acked = (argv[3..] || []).count { |idstr| !group.pending.delete(parse_strict_id(idstr, default_seq: 0)).nil? }
        Helpers.dirty(client) if acked.positive?
        acked
      end

      # --- XPENDING ----------------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.xpending(client, argv)
        key = T.must(argv[1])
        gname = T.must(argv[2])
        _stream, group = require_group(client, key, gname)
        return xpending_summary(group) if argv.length == 3

        xpending_extended(client, group, argv)
      end

      sig { params(group: Types::StreamGroup).returns(T.untyped) }
      def self.xpending_summary(group)
        return [0, nil, nil, Reply::NULL_ARRAY] if group.pending.empty?

        ids = group.pending.keys.sort
        per = T.let(Hash.new(0), T::Hash[String, Integer])
        group.pending.each_value { |pel| per[pel.consumer] = (per[pel.consumer] || 0) + 1 }
        consumers = per.map { |consumer, total| [consumer, total.to_s] }
        [group.pending.size, fmt(T.must(ids.first)), fmt(T.must(ids.last)), consumers]
      end

      sig { params(client: Client, group: Types::StreamGroup, argv: T::Array[String]).returns(T.untyped) }
      def self.xpending_extended(client, group, argv)
        index = 3
        idle = T.let(nil, T.nilable(Integer))
        if T.must(argv[index]).casecmp?("idle")
          idle = Helpers.int(T.must(argv[index + 1]))
          index += 2
        end
        start = parse_range(T.must(argv[index]), is_start: true)
        stop = parse_range(T.must(argv[index + 1]), is_start: false)
        count = Helpers.int(T.must(argv[index + 2]))
        consumer = argv[index + 3]
        now = Util.now_ms

        rows = group.pending_sorted.select do |id, pel|
          (id <=> start) >= 0 && (id <=> stop) <= 0 &&
            (consumer.nil? || pel.consumer == consumer) &&
            (idle.nil? || (now - pel.delivery_time) >= idle)
        end
        rows.first(count).map { |id, pel| [fmt(id), pel.consumer, now - pel.delivery_time, pel.delivery_count] }
      end

      # --- XCLAIM ------------------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.xclaim(client, argv)
        key = T.must(argv[1])
        gname = T.must(argv[2])
        cname = T.must(argv[3])
        min_idle = Helpers.int(T.must(argv[4]))
        stream, group = require_group(client, key, gname)

        ids = T.let([], T::Array[[Integer, Integer]])
        index = 5
        while index < argv.length && claim_id?(T.must(argv[index]))
          ids << parse_strict_id(T.must(argv[index]), default_seq: 0)
          index += 1
        end

        idle = T.let(nil, T.nilable(Integer))
        time = T.let(nil, T.nilable(Integer))
        retrycount = T.let(nil, T.nilable(Integer))
        force = justid = T.let(false, T::Boolean)
        while index < argv.length
          case T.must(argv[index]).downcase
          when "idle" then idle = Helpers.int(T.must(argv[index + 1])); index += 2
          when "time" then time = Helpers.int(T.must(argv[index + 1])); index += 2
          when "retrycount" then retrycount = Helpers.int(T.must(argv[index + 1])); index += 2
          when "force" then force = true; index += 1
          when "justid" then justid = true; index += 1
          when "lastid" then index += 2
          else raise CommandError.syntax
          end
        end

        now = Util.now_ms
        group.consumer(cname, now)
        result = T.let([], T::Array[T.untyped])
        ids.each do |id|
          pel = group.pending[id]
          created = T.let(false, T::Boolean)
          if pel.nil?
            next unless force && stream.include?(id)

            pel = Types::StreamPending.new(cname, now, 1)
            group.pending[id] = pel
            created = true
          elsif (now - pel.delivery_time) < min_idle
            next
          end

          entry = stream.find(id)
          if entry.nil?
            group.pending.delete(id)
            next
          end

          pel.consumer = cname
          pel.delivery_time = time || (idle ? now - idle : now)
          if retrycount
            pel.delivery_count = retrycount
          elsif !justid && !created
            pel.delivery_count += 1
          end
          result << (justid ? fmt(id) : [fmt(id), entry[1]])
        end
        Helpers.dirty(client)
        result
      end

      sig { params(str: String).returns(T::Boolean) }
      def self.claim_id?(str)
        first = str.getbyte(0)
        !first.nil? && first >= 48 && first <= 57 # starts with a digit
      end

      # --- XAUTOCLAIM --------------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.xautoclaim(client, argv)
        key = T.must(argv[1])
        gname = T.must(argv[2])
        cname = T.must(argv[3])
        min_idle = Helpers.int(T.must(argv[4]))
        start = parse_range(T.must(argv[5]), is_start: true)
        count = 100
        justid = T.let(false, T::Boolean)
        index = 6
        while index < argv.length
          case T.must(argv[index]).downcase
          when "count" then count = Helpers.int(T.must(argv[index + 1])); index += 2
          when "justid" then justid = true; index += 1
          else raise CommandError.syntax
          end
        end

        stream, group = require_group(client, key, gname)
        now = Util.now_ms
        group.consumer(cname, now)

        candidates = group.pending_sorted.select { |id, _pel| (id <=> start) >= 0 }
        claimed = T.let([], T::Array[T.untyped])
        deleted = T.let([], T::Array[String])
        cursor = T.let(ZERO, [Integer, Integer])

        candidates.each_with_index do |(id, pel), position|
          if claimed.size >= count
            cursor = id
            break
          end
          next if (now - pel.delivery_time) < min_idle

          entry = stream.find(id)
          if entry.nil?
            group.pending.delete(id)
            deleted << fmt(id)
            next
          end

          pel.consumer = cname
          pel.delivery_time = now
          pel.delivery_count += 1 unless justid
          claimed << (justid ? fmt(id) : [fmt(id), entry[1]])
        end

        Helpers.dirty(client)
        [fmt(cursor), claimed, deleted]
      end

      # --- XINFO -------------------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.xinfo(client, argv)
        sub = T.must(argv[1]).downcase
        case sub
        when "stream" then xinfo_stream(client, T.must(argv[2]))
        when "groups" then xinfo_groups(client, T.must(argv[2]))
        when "consumers" then xinfo_consumers(client, T.must(argv[2]), T.must(argv[3]))
        when "help" then ["XINFO STREAM <key>", "XINFO GROUPS <key>", "XINFO CONSUMERS <key> <group>"]
        else raise CommandError.generic("Unknown XINFO subcommand or wrong number of arguments for '#{argv[1]}'")
        end
      end

      sig { params(client: Client, key: String).returns(T.untyped) }
      def self.xinfo_stream(client, key)
        stream = require_stream(client, key)
        first = stream.first_entry
        last = stream.last_entry
        Reply::Map.new([
          ["length", stream.length],
          ["radix-tree-keys", 1],
          ["radix-tree-nodes", 2],
          ["last-generated-id", fmt(stream.last_id)],
          ["max-deleted-entry-id", fmt(stream.max_deleted_id)],
          ["entries-added", stream.entries_added],
          ["recorded-first-entry-id", fmt(stream.first_id)],
          ["groups", stream.groups.size],
          ["first-entry", first ? [fmt(first[0]), first[1]] : nil],
          ["last-entry", last ? [fmt(last[0]), last[1]] : nil],
        ])
      end

      sig { params(client: Client, key: String).returns(T.untyped) }
      def self.xinfo_groups(client, key)
        stream = require_stream(client, key)
        stream.groups.map do |name, group|
          lag = [stream.entries_added - group.entries_read, 0].max
          Reply::Map.new([
            ["name", name],
            ["consumers", group.consumers.size],
            ["pending", group.pending.size],
            ["last-delivered-id", fmt(group.last_delivered_id)],
            ["entries-read", group.entries_read],
            ["lag", lag],
          ])
        end
      end

      sig { params(client: Client, key: String, gname: String).returns(T.untyped) }
      def self.xinfo_consumers(client, key, gname)
        _stream, group = require_group(client, key, gname)
        now = Util.now_ms
        group.consumers.values.map do |consumer|
          pending = group.pending.count { |_id, pel| pel.consumer == consumer.name }
          Reply::Map.new([
            ["name", consumer.name],
            ["pending", pending],
            ["idle", now - consumer.seen_time],
            ["inactive", now - consumer.active_time],
          ])
        end
      end

      # --- Shared helpers ----------------------------------------------------

      sig { params(entries: T::Array[[[Integer, Integer], T::Array[String]]]).returns(T::Array[T.untyped]) }
      def self.emit(entries) = entries.map { |id, fields| [fmt(id), fields] }

      sig { params(client: Client, key: String).returns(Types::Stream) }
      def self.require_stream(client, key)
        stream = lookup_stream(client, key)
        raise CommandError.generic("no such key") if stream.nil?

        stream
      end

      sig { params(client: Client, key: String, gname: String).returns([Types::Stream, Types::StreamGroup]) }
      def self.require_group(client, key, gname)
        stream = lookup_stream(client, key)
        group = stream&.groups&.fetch(gname, nil)
        if stream.nil? || group.nil?
          raise CommandError.raw("NOGROUP No such key '#{key}' or consumer group '#{gname}'")
        end

        [stream, group]
      end

      sig { params(client: Client, key: String, gname: String).returns([Types::Stream, Types::StreamGroup]) }
      def self.require_readgroup(client, key, gname)
        stream = lookup_stream(client, key)
        group = stream&.groups&.fetch(gname, nil)
        if stream.nil? || group.nil?
          raise CommandError.raw(
            "NOGROUP No such key '#{key}' or consumer group '#{gname}' in XREADGROUP with GROUP option",
          )
        end

        [stream, group]
      end

      # Parse "[COUNT n] [BLOCK ms] STREAMS key... id..." → [count, block, keys, ids].
      sig do
        params(argv: T::Array[String], index: Integer, group: T::Boolean)
          .returns([T.nilable(Integer), T.nilable(Integer), T::Array[String], T::Array[String]])
      end
      def self.parse_read(argv, index, group:)
        count = T.let(nil, T.nilable(Integer))
        block = T.let(nil, T.nilable(Integer))
        loop do
          token = argv[index]
          raise CommandError.syntax if token.nil?

          case token.downcase
          when "count" then count = Helpers.int(T.must(argv[index + 1])); index += 2
          when "block"
            block = Helpers.int(T.must(argv[index + 1]))
            raise CommandError.generic("timeout is negative") if block.negative?

            index += 2
          when "streams" then index += 1; break
          else raise CommandError.syntax
          end
        end

        rest = argv[index..] || []
        if rest.empty? || rest.length.odd?
          raise CommandError.generic(
            "Unbalanced XREAD list of streams: for each stream key an ID or '$' must be specified.",
          )
        end

        half = rest.length / 2
        [count, block, T.must(rest[0, half]), T.must(rest[half..])]
      end

      # Like parse_read but also consumes NOACK (for XREADGROUP).
      sig do
        params(argv: T::Array[String], index: Integer)
          .returns([T.nilable(Integer), T.nilable(Integer), T::Boolean, T::Array[String], T::Array[String]])
      end
      def self.parse_readgroup(argv, index)
        count = T.let(nil, T.nilable(Integer))
        block = T.let(nil, T.nilable(Integer))
        noack = T.let(false, T::Boolean)
        loop do
          token = argv[index]
          raise CommandError.syntax if token.nil?

          case token.downcase
          when "count" then count = Helpers.int(T.must(argv[index + 1])); index += 2
          when "block"
            block = Helpers.int(T.must(argv[index + 1]))
            raise CommandError.generic("timeout is negative") if block.negative?

            index += 2
          when "noack" then noack = true; index += 1
          when "streams" then index += 1; break
          else raise CommandError.syntax
          end
        end

        rest = argv[index..] || []
        if rest.empty? || rest.length.odd?
          raise CommandError.generic(
            "Unbalanced XREADGROUP list of streams: for each stream key an ID or '>' must be specified.",
          )
        end

        half = rest.length / 2
        [count, block, noack, T.must(rest[0, half]), T.must(rest[half..])]
      end

      sig { params(table: CommandTable).void }
      def self.install(table)
        table.add("xadd", -5, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| xadd(c, a) }
        table.add("xlen", 2, [CommandFlag::Readonly, CommandFlag::Fast]) { |c, a| xlen(c, a) }
        table.add("xrange", -4, [CommandFlag::Readonly]) { |c, a| xrange(c, a) }
        table.add("xrevrange", -4, [CommandFlag::Readonly]) { |c, a| xrevrange(c, a) }
        table.add("xdel", -3, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| xdel(c, a) }
        table.add("xtrim", -4, [CommandFlag::Write]) { |c, a| xtrim(c, a) }
        table.add("xread", -4, [CommandFlag::Readonly]) { |c, a| xread(c, a) }
        table.add("xsetid", -3, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| xsetid(c, a) }
        table.add("xgroup", -2, [CommandFlag::Write]) { |c, a| xgroup(c, a) }
        table.add("xreadgroup", -7, [CommandFlag::Write]) { |c, a| xreadgroup(c, a) }
        table.add("xack", -4, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| xack(c, a) }
        table.add("xpending", -3, [CommandFlag::Readonly]) { |c, a| xpending(c, a) }
        table.add("xclaim", -6, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| xclaim(c, a) }
        table.add("xautoclaim", -6, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| xautoclaim(c, a) }
        table.add("xinfo", -2, [CommandFlag::Readonly]) { |c, a| xinfo(c, a) }
      end
    end
  end
end

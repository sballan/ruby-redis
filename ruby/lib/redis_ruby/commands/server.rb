# typed: strict
# frozen_string_literal: true

module RedisRuby
  module Commands
    # Server administration: FLUSHDB/FLUSHALL, INFO, CONFIG, TIME, DEBUG,
    # the snapshot commands (SAVE/BGSAVE/LASTSAVE) and SHUTDOWN.
    module ServerControl
      extend T::Sig

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.flushdb(client, argv)
        client.db.signal_flush
        changes = client.db.size
        client.db.clear
        Helpers.dirty(client, changes)
        Reply::OK
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.flushall(client, argv)
        changes = 0
        client.server.each_database do |database|
          database.signal_flush
          changes += database.size
          database.clear
        end
        Helpers.dirty(client, changes)
        Reply::OK
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.time(client, argv)
        now = Process.clock_gettime(Process::CLOCK_REALTIME, :microsecond)
        [(now / 1_000_000).to_s, (now % 1_000_000).to_s]
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.lastsave(client, argv) = client.server.last_save

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.save(client, argv)
        client.server.save_rdb
        Reply::OK
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.bgsave(client, argv)
        client.server.bgsave
        Reply::SimpleString.new("Background saving started")
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.bgrewriteaof(client, argv)
        Reply::SimpleString.new("Background append only file rewriting started")
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.shutdown(client, argv)
        nosave = (argv[1..] || []).any? { |arg| arg.casecmp?("nosave") }
        client.server.save_rdb if !nosave && !client.server.config.save_points.empty?
        client.server.request_shutdown
        Reply::NO_REPLY
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.lolwut(client, argv)
        "Redis ver. #{RedisRuby::REDIS_VERSION} (Ruby reimplementation)\n"
      end

      # --- CONFIG ------------------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.config(client, argv)
        sub = T.must(argv[1]).downcase
        case sub
        when "get"
          patterns = argv[2..] || []
          raise CommandError.wrong_args("config|get") if patterns.empty?

          seen = {}
          pairs = T.let([], T::Array[[T.untyped, T.untyped]])
          patterns.each do |pattern|
            client.server.config.matching(pattern).each do |name, value|
              next if seen[name]

              seen[name] = true
              pairs << [name, value]
            end
          end
          Reply::Map.new(pairs)
        when "set"
          settings = argv[2..] || []
          raise CommandError.wrong_args("config|set") if settings.empty? || settings.length.odd?

          settings.each_slice(2) { |name, value| client.server.config.set(T.must(name), T.must(value)) }
          Reply::OK
        when "resetstat", "rewrite" then Reply::OK
        else raise CommandError.generic("Unknown CONFIG subcommand or wrong number of arguments for '#{argv[1]}'")
        end
      end

      # --- DEBUG -------------------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.debug(client, argv)
        sub = T.must(argv[1]).downcase
        case sub
        when "sleep"
          sleep(Helpers.float(T.must(argv[2])))
          Reply::OK
        when "jmap", "set-active-expire", "quicklist-packed-threshold", "stringmatch-len",
             "change-repl-id", "debug", "mallocstats", "flushall"
          Reply::OK
        when "object" then debug_object(client, T.must(argv[2]))
        when "reload"
          client.server.save_rdb
          client.server.reload_rdb
          Reply::OK
        when "jmap" then Reply::OK
        else Reply::OK
        end
      end

      sig { params(client: Client, key: String).returns(T.untyped) }
      def self.debug_object(client, key)
        value = client.db.lookup(key)
        raise CommandError.generic("no such key") if value.nil?

        encoding = Types.encoding_for(value, client.server.config).serialize
        Reply::SimpleString.new("Value at:0x0 refcount:1 encoding:#{encoding} serializedlength:0 lru:0 lru_seconds_idle:0")
      end

      # --- INFO --------------------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.info(client, argv)
        section = argv[1]&.downcase
        Reply::Verbatim.new("txt", client.server.info_report(section))
      end

      sig { params(table: CommandTable).void }
      def self.install(table)
        table.add("flushdb", -1, [CommandFlag::Write]) { |c, a| flushdb(c, a) }
        table.add("flushall", -1, [CommandFlag::Write]) { |c, a| flushall(c, a) }
        table.add("time", 1, [CommandFlag::Loading, CommandFlag::Fast]) { |c, a| time(c, a) }
        table.add("lastsave", 1, [CommandFlag::Loading, CommandFlag::Fast]) { |c, a| lastsave(c, a) }
        table.add("save", 1, [CommandFlag::Admin]) { |c, a| save(c, a) }
        table.add("bgsave", -1, [CommandFlag::Admin]) { |c, a| bgsave(c, a) }
        table.add("bgrewriteaof", 1, [CommandFlag::Admin]) { |c, a| bgrewriteaof(c, a) }
        table.add("shutdown", -1, [CommandFlag::Admin, CommandFlag::Loading, CommandFlag::NoMulti]) { |c, a| shutdown(c, a) }
        table.add("lolwut", -1, [CommandFlag::Readonly, CommandFlag::Fast]) { |c, a| lolwut(c, a) }
        table.add("config", -2, [CommandFlag::Admin, CommandFlag::Loading]) { |c, a| config(c, a) }
        table.add("debug", -2, [CommandFlag::Admin, CommandFlag::Loading]) { |c, a| debug(c, a) }
        table.add("info", -1, [CommandFlag::Loading]) { |c, a| info(c, a) }
      end
    end
  end
end

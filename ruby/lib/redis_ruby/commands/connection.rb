# typed: strict
# frozen_string_literal: true

module RedisRuby
  module Commands
    # Connection and protocol negotiation: PING, ECHO, HELLO, AUTH, SELECT,
    # RESET, QUIT, plus the CLIENT and COMMAND introspection families.
    module Connection
      extend T::Sig

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.ping(client, argv)
        message = argv[1]
        if client.subscribe_mode?
          ["pong", message || ""]
        elsif message
          message
        else
          Reply::PONG
        end
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.echo(client, argv) = T.must(argv[1])

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.select(client, argv)
        index = Helpers.int(T.must(argv[1]))
        raise CommandError.generic("DB index is out of range") if index.negative? || index >= client.server.config.databases

        client.db_index = index
        client.db = client.server.db(index)
        Reply::OK
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.swapdb(client, argv)
        first = Helpers.int(T.must(argv[1]))
        second = Helpers.int(T.must(argv[2]))
        count = client.server.config.databases
        if [first, second].any? { |index| index.negative? || index >= count }
          raise CommandError.generic("DB index is out of range")
        end

        client.server.swap_databases(first, second)
        Reply::OK
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.auth(client, argv)
        username, password = argv.length == 2 ? ["default", T.must(argv[1])] : [T.must(argv[1]), T.must(argv[2])]
        authenticate(client, username, password)
        Reply::OK
      end

      sig { params(client: Client, username: String, password: String).void }
      def self.authenticate(client, username, password)
        required = client.server.config.requirepass
        if required.nil?
          raise CommandError.generic(
            "Client sent AUTH, but no password is set. Did you mean AUTH <username> <password>?",
          )
        end
        if username != "default" || password != required
          raise CommandError.raw("WRONGPASS invalid username-password pair or user is disabled.")
        end

        client.authenticated = true
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.hello(client, argv)
        index = 1
        if argv.length > 1
          proto = parse_protover(T.must(argv[1]))
          index = 2
          while index < argv.length
            option = T.must(argv[index]).downcase
            case option
            when "auth"
              raise CommandError.syntax if index + 2 >= argv.length

              authenticate(client, T.must(argv[index + 1]), T.must(argv[index + 2]))
              index += 3
            when "setname"
              raise CommandError.syntax if index + 1 >= argv.length

              client.name = T.must(argv[index + 1])
              index += 2
            else
              raise CommandError.syntax
            end
          end
          client.protocol = proto
        end

        unless client.authenticated
          raise CommandError.raw(
            "NOAUTH HELLO must be called with the client already authenticated, otherwise the HELLO " \
            "<proto> AUTH <user> <pass> option can be used to authenticate the client and select the " \
            "RESP protocol version at the same time",
          )
        end

        Reply::Map.new([
          ["server", "redis"],
          ["version", RedisRuby::REDIS_VERSION],
          ["proto", client.protocol],
          ["id", client.id],
          ["mode", "standalone"],
          ["role", "master"],
          ["modules", []],
        ])
      end

      sig { params(str: String).returns(Integer) }
      def self.parse_protover(str)
        proto = Integer(str, 10)
        raise CommandError.raw("NOPROTO unsupported protocol version") unless [2, 3].include?(proto)

        proto
      rescue ArgumentError, TypeError
        raise CommandError.raw("NOPROTO unsupported protocol version")
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.quit(client, argv)
        client.closing = true
        Reply::OK
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.reset(client, argv)
        client.server.reset_client(client)
        Reply::SimpleString.new("RESET")
      end

      # --- CLIENT ------------------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.client(client, argv)
        sub = T.must(argv[1]).downcase
        case sub
        when "id" then client.id
        when "getname" then client.name.empty? ? nil : client.name
        when "setname"
          name = T.must(argv[2])
          raise CommandError.generic("Client names cannot contain spaces, newlines or special characters.") if name.match?(/[\s\n]/)

          client.name = name
          Reply::OK
        when "setinfo"
          attr = T.must(argv[2]).downcase
          value = T.must(argv[3])
          case attr
          when "lib-name" then client.lib_name = value
          when "lib-ver" then client.lib_ver = value
          else raise CommandError.generic("Unrecognized option '#{argv[2]}'")
          end
          Reply::OK
        when "reply" then client_reply(client, T.must(argv[2]))
        when "info" then client.server.client_info_line(client)
        when "list" then "#{client.server.clients_info_lines}\n"
        when "no-evict", "no-touch", "unpause" then Reply::OK
        else raise CommandError.generic("Unknown CLIENT subcommand or wrong number of arguments for '#{argv[1]}'")
        end
      end

      sig { params(client: Client, mode: String).returns(T.untyped) }
      def self.client_reply(client, mode)
        case mode.downcase
        when "on"
          client.reply_mode = :on
          Reply::OK
        when "off"
          client.reply_mode = :off
          Reply::NO_REPLY
        when "skip"
          client.request_skip_reply if client.reply_mode == :on
          Reply::NO_REPLY
        else
          raise CommandError.syntax
        end
      end

      # --- COMMAND -----------------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.command(client, argv)
        table = client.server.command_table
        if argv.length == 1
          return table.names.sort.map { |name| info_entry(T.must(table.lookup(name))) }
        end

        case T.must(argv[1]).downcase
        when "count" then table.size
        when "docs" then Reply::Map.new([])
        when "info"
          names = argv[2..] || []
          names.empty? ? table.names.sort.map { |n| info_entry(T.must(table.lookup(n))) } : names.map { |n| (c = table.lookup(n)) ? info_entry(c) : nil }
        when "list" then table.names.sort
        else raise CommandError.generic("Unknown COMMAND subcommand or wrong number of arguments for '#{argv[1]}'")
        end
      end

      sig { params(command: Command).returns(T::Array[T.untyped]) }
      def self.info_entry(command)
        has_key = command.write? || command.readonly?
        [
          command.name.downcase,
          command.arity,
          command.flags.map { |flag| Reply::SimpleString.new(flag.to_s.tr("_", "")) },
          has_key ? 1 : 0,
          has_key ? 1 : 0,
          has_key ? 1 : 0,
          [],
          [],
          [],
          [],
        ]
      end

      sig { params(table: CommandTable).void }
      def self.install(table)
        table.add("ping", -1, %i[fast]) { |c, a| ping(c, a) }
        table.add("echo", 2, %i[fast]) { |c, a| echo(c, a) }
        table.add("select", 2, %i[fast loading]) { |c, a| select(c, a) }
        table.add("swapdb", 3, %i[write fast]) { |c, a| swapdb(c, a) }
        table.add("auth", -2, %i[fast loading no_multi]) { |c, a| auth(c, a) }
        table.add("hello", -1, %i[fast loading no_multi]) { |c, a| hello(c, a) }
        table.add("quit", -1, %i[fast loading pubsub]) { |c, a| quit(c, a) }
        table.add("reset", 1, %i[fast loading pubsub no_multi]) { |c, a| reset(c, a) }
        table.add("client", -2, %i[admin]) { |c, a| client(c, a) }
        table.add("command", -1, %i[loading]) { |c, a| command(c, a) }
      end
    end
  end
end

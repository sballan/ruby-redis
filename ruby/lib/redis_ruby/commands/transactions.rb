# typed: strict
# frozen_string_literal: true

module RedisRuby
  module Commands
    # MULTI/EXEC/DISCARD and the optimistic-locking WATCH/UNWATCH commands.
    # Command queueing itself happens in the dispatcher; these handlers manage
    # the transaction lifecycle and run the queued commands on EXEC.
    module Transactions
      extend T::Sig

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.multi(client, argv)
        raise CommandError.generic("MULTI calls can not be nested") if client.in_multi

        client.in_multi = true
        Reply::OK
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.discard(client, argv)
        raise CommandError.generic("DISCARD without MULTI") unless client.in_multi

        client.server.unwatch_all(client)
        client.reset_multi
        Reply::OK
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.exec(client, argv)
        raise CommandError.generic("EXEC without MULTI") unless client.in_multi

        if client.multi_error
          client.server.unwatch_all(client)
          client.reset_multi
          raise CommandError.raw("EXECABORT Transaction discarded because of previous errors.")
        end

        if client.cas_dirty
          client.server.unwatch_all(client)
          client.reset_multi
          return nil
        end

        queue = client.multi_queue
        client.reset_multi
        client.server.unwatch_all(client)
        queue.map { |command_argv| client.server.run_for_exec(client, command_argv) }
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.watch(client, argv)
        raise CommandError.generic("WATCH inside MULTI is not allowed") if client.in_multi

        (argv[1..] || []).each { |key| client.server.watch_key(client, key) }
        Reply::OK
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.unwatch(client, argv)
        client.server.unwatch_all(client)
        Reply::OK
      end

      sig { params(table: CommandTable).void }
      def self.install(table)
        table.add("multi", 1, [CommandFlag::Fast, CommandFlag::Loading, CommandFlag::NoMulti]) { |c, a| multi(c, a) }
        table.add("discard", 1, [CommandFlag::Fast, CommandFlag::Loading, CommandFlag::NoMulti]) { |c, a| discard(c, a) }
        table.add("exec", 1, [CommandFlag::Loading, CommandFlag::NoMulti]) { |c, a| exec(c, a) }
        table.add("watch", -2, [CommandFlag::Fast, CommandFlag::Loading, CommandFlag::NoMulti]) { |c, a| watch(c, a) }
        table.add("unwatch", 1, [CommandFlag::Fast, CommandFlag::Loading, CommandFlag::NoMulti]) { |c, a| unwatch(c, a) }
      end
    end
  end
end

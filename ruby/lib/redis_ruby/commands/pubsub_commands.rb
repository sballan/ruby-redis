# typed: strict
# frozen_string_literal: true

module RedisRuby
  module Commands
    # Publish/subscribe commands. Subscribe-family handlers push one
    # confirmation frame per channel/pattern directly to the client and return
    # NO_REPLY; PUBLISH/PUBSUB behave like ordinary commands.
    module PubSubCommands
      extend T::Sig

      sig { returns(Integer) }
      def self.regular_count_marker = 0

      sig { params(client: Client).returns(Integer) }
      def self.regular_count(client) = client.sub_channels.size + client.sub_patterns.size

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.subscribe(client, argv)
        (argv[1..] || []).each do |channel|
          client.server.pubsub.subscribe(client, channel)
          client.sub_channels[channel] = true
          client.deliver(Reply::Push.new(["subscribe", channel, regular_count(client)]))
        end
        Reply::NO_REPLY
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.unsubscribe(client, argv)
        channels = argv[1..] || []
        channels = client.sub_channels.keys if channels.empty?
        if channels.empty?
          client.deliver(Reply::Push.new(["unsubscribe", nil, regular_count(client)]))
          return Reply::NO_REPLY
        end

        channels.each do |channel|
          client.server.pubsub.unsubscribe(client, channel)
          client.sub_channels.delete(channel)
          client.deliver(Reply::Push.new(["unsubscribe", channel, regular_count(client)]))
        end
        Reply::NO_REPLY
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.psubscribe(client, argv)
        (argv[1..] || []).each do |pattern|
          client.server.pubsub.psubscribe(client, pattern)
          client.sub_patterns[pattern] = true
          client.deliver(Reply::Push.new(["psubscribe", pattern, regular_count(client)]))
        end
        Reply::NO_REPLY
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.punsubscribe(client, argv)
        patterns = argv[1..] || []
        patterns = client.sub_patterns.keys if patterns.empty?
        if patterns.empty?
          client.deliver(Reply::Push.new(["punsubscribe", nil, regular_count(client)]))
          return Reply::NO_REPLY
        end

        patterns.each do |pattern|
          client.server.pubsub.punsubscribe(client, pattern)
          client.sub_patterns.delete(pattern)
          client.deliver(Reply::Push.new(["punsubscribe", pattern, regular_count(client)]))
        end
        Reply::NO_REPLY
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.ssubscribe(client, argv)
        (argv[1..] || []).each do |channel|
          client.server.pubsub.ssubscribe(client, channel)
          client.sub_shard[channel] = true
          client.deliver(Reply::Push.new(["ssubscribe", channel, client.sub_shard.size]))
        end
        Reply::NO_REPLY
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.sunsubscribe(client, argv)
        channels = argv[1..] || []
        channels = client.sub_shard.keys if channels.empty?
        if channels.empty?
          client.deliver(Reply::Push.new(["sunsubscribe", nil, 0]))
          return Reply::NO_REPLY
        end

        channels.each do |channel|
          client.server.pubsub.sunsubscribe(client, channel)
          client.sub_shard.delete(channel)
          client.deliver(Reply::Push.new(["sunsubscribe", channel, client.sub_shard.size]))
        end
        Reply::NO_REPLY
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.publish(client, argv)
        client.server.pubsub.publish(T.must(argv[1]), T.must(argv[2]))
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.spublish(client, argv)
        client.server.pubsub.spublish(T.must(argv[1]), T.must(argv[2]))
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.pubsub(client, argv)
        hub = client.server.pubsub
        case T.must(argv[1]).downcase
        when "channels" then hub.channels(argv[2])
        when "numpat" then hub.pattern_count
        when "numsub"
          (argv[2..] || []).flat_map { |channel| [channel, hub.channel_subscribers(channel)] }
        when "shardchannels" then hub.shard_channels(argv[2])
        when "shardnumsub"
          (argv[2..] || []).flat_map { |channel| [channel, hub.shard_subscribers(channel)] }
        else raise CommandError.generic("Unknown PUBSUB subcommand or wrong number of arguments for '#{argv[1]}'")
        end
      end

      sig { params(table: CommandTable).void }
      def self.install(table)
        table.add("subscribe", -2, %i[pubsub fast loading]) { |c, a| subscribe(c, a) }
        table.add("unsubscribe", -1, %i[pubsub fast loading]) { |c, a| unsubscribe(c, a) }
        table.add("psubscribe", -2, %i[pubsub fast loading]) { |c, a| psubscribe(c, a) }
        table.add("punsubscribe", -1, %i[pubsub fast loading]) { |c, a| punsubscribe(c, a) }
        table.add("ssubscribe", -2, %i[pubsub fast loading]) { |c, a| ssubscribe(c, a) }
        table.add("sunsubscribe", -1, %i[pubsub fast loading]) { |c, a| sunsubscribe(c, a) }
        table.add("publish", 3, %i[pubsub fast loading]) { |c, a| publish(c, a) }
        table.add("spublish", 3, %i[pubsub fast loading]) { |c, a| spublish(c, a) }
        table.add("pubsub", -2, %i[pubsub loading]) { |c, a| pubsub(c, a) }
      end
    end
  end
end

# typed: strict
# frozen_string_literal: true

module RedisRuby
  # Server-wide publish/subscribe registry. Maintains the reverse mapping from
  # channels and patterns to subscribed clients; per-client subscription sets
  # are tracked on the {Client} itself.
  class PubSub
    extend T::Sig

    sig { void }
    def initialize
      @channels = T.let({}, T::Hash[String, T::Array[Client]])
      @patterns = T.let({}, T::Hash[String, T::Array[Client]])
      @shard = T.let({}, T::Hash[String, T::Array[Client]])
    end

    sig { params(client: Client, channel: String).void }
    def subscribe(client, channel) = register(@channels, channel, client)

    sig { params(client: Client, channel: String).void }
    def unsubscribe(client, channel) = deregister(@channels, channel, client)

    sig { params(client: Client, pattern: String).void }
    def psubscribe(client, pattern) = register(@patterns, pattern, client)

    sig { params(client: Client, pattern: String).void }
    def punsubscribe(client, pattern) = deregister(@patterns, pattern, client)

    sig { params(client: Client, channel: String).void }
    def ssubscribe(client, channel) = register(@shard, channel, client)

    sig { params(client: Client, channel: String).void }
    def sunsubscribe(client, channel) = deregister(@shard, channel, client)

    # Deliver to channel subscribers and matching pattern subscribers, then
    # return the number of clients reached.
    sig { params(channel: String, message: String).returns(Integer) }
    def publish(channel, message)
      receivers = 0

      (@channels[channel] || []).each do |client|
        client.queue_reply(Reply::Push.new(["message", channel, message]))
        receivers += 1
      end

      @patterns.each do |pattern, clients|
        next unless Util.glob_match?(pattern, channel)

        clients.each do |client|
          client.queue_reply(Reply::Push.new(["pmessage", pattern, channel, message]))
          receivers += 1
        end
      end

      receivers
    end

    sig { params(channel: String, message: String).returns(Integer) }
    def spublish(channel, message)
      receivers = 0
      (@shard[channel] || []).each do |client|
        client.queue_reply(Reply::Push.new(["smessage", channel, message]))
        receivers += 1
      end
      receivers
    end

    # Remove a disconnecting client from every registry.
    sig { params(client: Client).void }
    def drop(client)
      [@channels, @patterns, @shard].each do |registry|
        registry.keys.each do |key|
          list = registry[key]
          next unless list

          list.delete(client)
          registry.delete(key) if list.empty?
        end
      end
    end

    # PUBSUB CHANNELS [pattern]
    sig { params(pattern: T.nilable(String)).returns(T::Array[String]) }
    def channels(pattern)
      names = @channels.keys
      names = names.select { |name| Util.glob_match?(pattern, name) } if pattern
      names
    end

    sig { params(pattern: T.nilable(String)).returns(T::Array[String]) }
    def shard_channels(pattern)
      names = @shard.keys
      names = names.select { |name| Util.glob_match?(pattern, name) } if pattern
      names
    end

    sig { params(channel: String).returns(Integer) }
    def channel_subscribers(channel) = @channels[channel]&.size || 0

    sig { params(channel: String).returns(Integer) }
    def shard_subscribers(channel) = @shard[channel]&.size || 0

    sig { returns(Integer) }
    def pattern_count = @patterns.size

    private

    sig { params(registry: T::Hash[String, T::Array[Client]], key: String, client: Client).void }
    def register(registry, key, client)
      list = (registry[key] ||= [])
      list << client unless list.include?(client)
    end

    sig { params(registry: T::Hash[String, T::Array[Client]], key: String, client: Client).void }
    def deregister(registry, key, client)
      list = registry[key]
      return unless list

      list.delete(client)
      registry.delete(key) if list.empty?
    end
  end
end

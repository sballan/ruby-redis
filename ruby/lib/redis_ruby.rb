# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require "securerandom"

# RedisRuby is a from-scratch reimplementation of the Redis server in Ruby,
# typed with Sorbet. The entry points are {RedisRuby::Server} (the event loop)
# and {RedisRuby::Config}. See bin/redis-server-rb for the CLI wrapper.
module RedisRuby
  extend T::Sig

  # Redis-compatibility version advertised by INFO and HELLO. This is the
  # Redis API level we target, not the version of this Ruby project.
  REDIS_VERSION = "7.4.0"

  # Stable identifier for this server process, reported by INFO.
  RUN_ID = T.let(SecureRandom.hex(20), String)
end

require_relative "redis_ruby/version"
require_relative "redis_ruby/errors"
require_relative "redis_ruby/util"
require_relative "redis_ruby/reply"
require_relative "redis_ruby/protocol"
require_relative "redis_ruby/types"
require_relative "redis_ruby/config"
require_relative "redis_ruby/database"
require_relative "redis_ruby/pubsub"
require_relative "redis_ruby/command"
require_relative "redis_ruby/client"

require_relative "redis_ruby/commands/helpers"
require_relative "redis_ruby/commands/connection"
require_relative "redis_ruby/commands/server"
require_relative "redis_ruby/commands/keys"
require_relative "redis_ruby/commands/strings"
require_relative "redis_ruby/commands/bitmaps"
require_relative "redis_ruby/commands/lists"
require_relative "redis_ruby/commands/hashes"
require_relative "redis_ruby/commands/sets"
require_relative "redis_ruby/commands/sorted_sets"
require_relative "redis_ruby/commands/transactions"
require_relative "redis_ruby/commands/pubsub_commands"

require_relative "redis_ruby/persistence/rdb"
require_relative "redis_ruby/server"

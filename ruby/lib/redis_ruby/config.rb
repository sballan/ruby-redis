# typed: strict
# frozen_string_literal: true

module RedisRuby
  # Server configuration. Backs CONFIG GET/SET with a flat string map, while
  # exposing typed accessors for the settings the server actually consults.
  # Unknown parameters are accepted and stored so clients that blindly set
  # tuning knobs don't error out.
  class Config
    extend T::Sig

    DEFAULTS = T.let({
      "bind" => "127.0.0.1",
      "port" => "6379",
      "databases" => "16",
      "dir" => ".",
      "dbfilename" => "dump.rdb",
      "save" => "3600 1 300 100 60 10000",
      "requirepass" => "",
      "maxmemory" => "0",
      "maxmemory-policy" => "noeviction",
      "appendonly" => "no",
      "timeout" => "0",
      "tcp-keepalive" => "300",
      "tcp-backlog" => "511",
      "loglevel" => "notice",
      "logfile" => "",
      "maxclients" => "10000",
      "proto-max-bulk-len" => "536870912",
      "list-max-listpack-size" => "128",
      "list-max-ziplist-size" => "128",
      "hash-max-listpack-entries" => "128",
      "hash-max-listpack-value" => "64",
      "hash-max-ziplist-entries" => "128",
      "hash-max-ziplist-value" => "64",
      "set-max-intset-entries" => "512",
      "set-max-listpack-entries" => "128",
      "set-max-listpack-value" => "64",
      "zset-max-listpack-entries" => "128",
      "zset-max-listpack-value" => "64",
      "zset-max-ziplist-entries" => "128",
      "zset-max-ziplist-value" => "64",
      "stream-node-max-entries" => "100",
      "stream-node-max-bytes" => "4096",
      "notify-keyspace-events" => "",
    }.freeze, T::Hash[String, String])

    sig { void }
    def initialize
      @values = T.let(DEFAULTS.dup, T::Hash[String, String])
    end

    sig { params(name: String).returns(T.nilable(String)) }
    def get(name) = @values[name.downcase]

    sig { params(name: String, value: String).void }
    def set(name, value)
      @values[name.downcase] = value
    end

    sig { params(name: String).returns(T::Boolean) }
    def known?(name) = @values.key?(name.downcase)

    # All [name, value] pairs whose name matches the glob pattern.
    sig { params(pattern: String).returns(T::Array[[String, String]]) }
    def matching(pattern)
      @values.select { |name, _| Util.glob_match?(pattern, name, nocase: true) }.to_a
    end

    # --- Typed accessors ---------------------------------------------------

    sig { returns(Integer) }
    def port = (get("port") || "6379").to_i

    sig { returns(String) }
    def bind = get("bind") || "127.0.0.1"

    sig { returns(Integer) }
    def databases = [(get("databases") || "16").to_i, 1].max

    sig { returns(String) }
    def dir = get("dir") || "."

    sig { returns(String) }
    def dbfilename = get("dbfilename") || "dump.rdb"

    sig { returns(String) }
    def rdb_path = File.join(dir, dbfilename)

    sig { returns(T.nilable(String)) }
    def requirepass
      pass = get("requirepass")
      pass.nil? || pass.empty? ? nil : pass
    end

    # Parsed "save" points as [seconds, changes] pairs. An empty string
    # disables automatic snapshots.
    sig { returns(T::Array[[Integer, Integer]]) }
    def save_points
      raw = (get("save") || "").split
      points = T.let([], T::Array[[Integer, Integer]])
      raw.each_slice(2) do |seconds, changes|
        points << [seconds.to_i, changes.to_i] if seconds && changes
      end
      points
    end
  end
end

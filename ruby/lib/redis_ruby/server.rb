# typed: strict
# frozen_string_literal: true

require "socket"

module RedisRuby
  # The server: owns the databases, the command table, the pub/sub hub and the
  # single-threaded event loop. Command execution is serialized through this
  # one loop, which is what makes Redis' atomicity guarantees hold without
  # locking.
  class Server
    extend T::Sig

    CRON_INTERVAL = 0.1

    sig { returns(Config) }
    attr_reader :config

    sig { returns(CommandTable) }
    attr_reader :command_table

    sig { returns(PubSub) }
    attr_reader :pubsub

    sig { returns(Integer) }
    attr_reader :dirty

    sig { params(config: Config, verbose: T::Boolean).void }
    def initialize(config = Config.new, verbose: false)
      @config = config
      @verbose = verbose
      @command_table = T.let(CommandTable.new, CommandTable)
      @pubsub = T.let(PubSub.new, PubSub)
      @databases = T.let([], T::Array[Database])
      config.databases.times { |index| @databases << Database.new(index, self) }
      @clients = T.let({}, T::Hash[IO, Client])
      @listener = T.let(nil, T.nilable(TCPServer))
      @next_client_id = T.let(0, Integer)
      @dirty = T.let(0, Integer)
      @dirty_since_save = T.let(0, Integer)
      @last_save = T.let(Time.now.to_i, Integer)
      @start_time = T.let(Time.now.to_i, Integer)
      @running = T.let(false, T::Boolean)
      @bgsave_pid = T.let(nil, T.nilable(Integer))
      @commands_processed = T.let(0, Integer)
      @connections_received = T.let(0, Integer)
      install_commands
    end

    sig { void }
    def install_commands
      Commands::Connection.install(@command_table)
      Commands::ServerControl.install(@command_table)
      Commands::Keys.install(@command_table)
      Commands::Strings.install(@command_table)
      Commands::Lists.install(@command_table)
      Commands::Hashes.install(@command_table)
      Commands::Sets.install(@command_table)
      Commands::SortedSets.install(@command_table)
      Commands::Bitmaps.install(@command_table)
      Commands::Transactions.install(@command_table)
      Commands::PubSubCommands.install(@command_table)
    end

    # --- Database access ---------------------------------------------------

    sig { params(index: Integer).returns(Database) }
    def db(index)
      raise CommandError.generic("DB index is out of range") if index.negative? || index >= @databases.length

      T.must(@databases[index])
    end

    sig { params(block: T.proc.params(database: Database).void).void }
    def each_database(&block) = @databases.each(&block)

    sig { params(first: Integer, second: Integer).void }
    def swap_databases(first, second)
      return if first == second

      a = db(first)
      b = db(second)
      a.signal_flush
      b.signal_flush
      a.swap_with(b)
    end

    sig { params(changes: Integer).void }
    def notify_dirty(changes)
      @dirty += changes
      @dirty_since_save += changes
    end

    sig { returns(Integer) }
    def last_save = @last_save

    # --- Lifecycle ---------------------------------------------------------

    sig { params(host: T.nilable(String), port: T.nilable(Integer)).returns(Integer) }
    def listen(host: nil, port: nil)
      listener = TCPServer.new(host || @config.bind, port || @config.port)
      listener.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1)
      @listener = listener
      listener.addr[1]
    end

    sig { void }
    def run
      listen if @listener.nil?
      load_rdb
      @running = true
      log("Ready to accept connections on #{@config.bind}:#{bound_port}")
      serve_once while @running
    ensure
      teardown
    end

    sig { void }
    def stop = (@running = false)

    sig { void }
    def request_shutdown = (@running = false)

    sig { returns(Integer) }
    def bound_port = @listener&.addr&.fetch(1) || @config.port

    sig { void }
    def serve_once
      read_set = T.let([T.must(@listener), *@clients.keys], T::Array[IO])
      write_set = @clients.values.select(&:pending_output?).map(&:socket)
      ready = IO.select(read_set, write_set.empty? ? nil : write_set, nil, CRON_INTERVAL)

      ready&.fetch(0)&.each do |io|
        io.equal?(@listener) ? accept_client : handle_read(@clients[io])
      end

      @clients.values.each { |client| flush(client) if client.pending_output? }
      reap_closing
      cron
    end

    # --- Connection handling ----------------------------------------------

    sig { void }
    def accept_client
      socket = T.must(@listener).accept_nonblock
      configure_socket(socket)
      @next_client_id += 1
      @connections_received += 1
      addr = peer_address(socket)
      @clients[socket] = Client.new(id: @next_client_id, socket: socket, addr: addr, server: self)
    rescue IO::WaitReadable, Errno::ECONNABORTED, Errno::EMFILE
      nil
    end

    sig { params(socket: TCPSocket).void }
    def configure_socket(socket)
      socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
    rescue StandardError
      nil
    end

    sig { params(socket: TCPSocket).returns(String) }
    def peer_address(socket)
      family, port, _name, ip = socket.peeraddr(false)
      family == "AF_INET6" ? "[#{ip}]:#{port}" : "#{ip}:#{port}"
    rescue StandardError
      "?:0"
    end

    sig { params(client: T.nilable(Client)).void }
    def handle_read(client)
      return if client.nil?

      data = client.socket.read_nonblock(65_536)
      client.reader << data
      drain_commands(client)
    rescue IO::WaitReadable
      nil
    rescue EOFError, Errno::ECONNRESET, Errno::EPIPE, IOError
      close_client(client)
    end

    sig { params(client: Client).void }
    def drain_commands(client)
      loop do
        argv = client.reader.read_command
        break if argv.nil?
        next if argv.empty?

        dispatch(client, argv)
        break if client.closing
      end
    rescue ProtocolError => e
      client.queue_reply(Reply::Error.new(e.message))
      client.closing = true
    end

    sig { params(client: Client).void }
    def flush(client)
      written = client.socket.write_nonblock(client.out)
      client.consume_output(written)
    rescue IO::WaitWritable
      nil
    rescue Errno::EPIPE, Errno::ECONNRESET, IOError
      close_client(client)
    end

    sig { void }
    def reap_closing
      @clients.values.each do |client|
        close_client(client) if client.closing && !client.pending_output?
      end
    end

    sig { params(client: T.nilable(Client)).void }
    def close_client(client)
      return if client.nil?

      @pubsub.drop(client)
      unwatch_all(client)
      @clients.delete(client.socket)
      begin
        client.socket.close
      rescue StandardError
        nil
      end
    end

    # --- Command dispatch --------------------------------------------------

    AUTH_EXEMPT = T.let(%w[auth hello reset quit].freeze, T::Array[String])
    PUBSUB_ALLOWED = T.let(%w[ping quit reset].freeze, T::Array[String])
    TXN_CONTROL = T.let(%w[multi exec discard watch reset].freeze, T::Array[String])

    sig { params(client: Client, argv: T::Array[String]).void }
    def dispatch(client, argv)
      name = T.must(argv[0]).downcase
      command = @command_table.lookup(name)

      unless command
        return reject(client, "ERR unknown command '#{argv[0]}', with args beginning with: #{format_args(argv)}")
      end
      return reject(client, CommandError.wrong_args(name).message) unless command.arity_ok?(argv.length)

      if !client.authenticated && !AUTH_EXEMPT.include?(name)
        return client.queue_reply(Reply::Error.new("NOAUTH Authentication required."))
      end

      if client.subscribe_mode? && !command.pubsub_safe? && !PUBSUB_ALLOWED.include?(name)
        return client.queue_reply(Reply::Error.new(
          "ERR Can't execute '#{name}': only (P|S)SUBSCRIBE / (P|S)UNSUBSCRIBE / PING / QUIT / RESET are allowed in this context",
        ))
      end

      if client.in_multi && !TXN_CONTROL.include?(name)
        return queue_in_multi(client, command, argv, name)
      end

      @commands_processed += 1
      client.queue_reply(call_handler(client, command, argv))
    end

    sig { params(client: Client, command: Command, argv: T::Array[String], name: String).void }
    def queue_in_multi(client, command, argv, name)
      if command.no_multi?
        client.multi_error = true
        return client.queue_reply(Reply::Error.new("ERR #{name.upcase} is not allowed in transactions"))
      end

      client.multi_queue << argv
      client.queue_reply(Reply::QUEUED)
    end

    # Run a queued command during EXEC, returning its reply (or an error reply).
    sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
    def run_for_exec(client, argv)
      command = @command_table.lookup(T.must(argv[0]).downcase)
      return Reply::Error.new("ERR unknown command") unless command

      @commands_processed += 1
      call_handler(client, command, argv)
    end

    sig { params(client: Client, command: Command, argv: T::Array[String]).returns(T.untyped) }
    def call_handler(client, command, argv)
      command.handler.call(client, argv)
    rescue CommandError => e
      Reply::Error.new(e.message)
    rescue StandardError => e
      log("error running #{argv.first}: #{e.class}: #{e.message}")
      Reply::Error.new("ERR internal error")
    end

    sig { params(client: Client, message: String).void }
    def reject(client, message)
      client.multi_error = true if client.in_multi
      client.queue_reply(Reply::Error.new(message))
    end

    sig { params(argv: T::Array[String]).returns(String) }
    def format_args(argv)
      (argv[1..] || []).first(20).map { |arg| "'#{arg.byteslice(0, 128)}'" }.join(", ")
    end

    # --- WATCH / transactions ---------------------------------------------

    sig { params(client: Client, key: String).void }
    def watch_key(client, key)
      client.db.watch(client, key)
      entry = [client.db_index, key]
      client.watched_keys << entry unless client.watched_keys.include?(entry)
    end

    sig { params(client: Client).void }
    def unwatch_all(client)
      client.watched_keys.each { |index, key| db(index).unwatch(client, key) }
      client.watched_keys.clear
      client.cas_dirty = false
    end

    sig { params(client: Client).void }
    def reset_client(client)
      unwatch_all(client)
      client.reset_multi
      @pubsub.drop(client)
      client.sub_channels.clear
      client.sub_patterns.clear
      client.sub_shard.clear
      client.reply_mode = :on
      client.protocol = 2
      client.db_index = 0
      client.db = db(0)
      client.name = ""
      client.authenticated = @config.requirepass.nil?
    end

    # --- Cron --------------------------------------------------------------

    sig { void }
    def cron
      @databases.each(&:active_expire_cycle)
      reap_bgsave
      maybe_autosave
    end

    sig { void }
    def maybe_autosave
      return if @bgsave_pid
      return if @dirty_since_save.zero?

      elapsed = Time.now.to_i - @last_save
      triggered = @config.save_points.any? { |seconds, changes| elapsed >= seconds && @dirty_since_save >= changes }
      bgsave if triggered
    end

    # --- Persistence -------------------------------------------------------

    sig { void }
    def save_rdb
      write_rdb_file(@config.rdb_path)
      @last_save = Time.now.to_i
      @dirty_since_save = 0
    rescue SystemCallError => e
      raise CommandError.generic(e.message)
    end

    sig { void }
    def bgsave
      return save_rdb unless Process.respond_to?(:fork)
      return if @bgsave_pid

      pid = fork do
        begin
          write_rdb_file(@config.rdb_path)
          Process.exit!(0)
        rescue StandardError
          Process.exit!(1)
        end
      end
      @bgsave_pid = pid
    end

    sig { void }
    def reap_bgsave
      pid = @bgsave_pid
      return if pid.nil?

      reaped = Process.waitpid(pid, Process::WNOHANG)
      return if reaped.nil?

      @bgsave_pid = nil
      @last_save = Time.now.to_i
      @dirty_since_save = 0
    rescue Errno::ECHILD
      @bgsave_pid = nil
    end

    sig { params(path: String).void }
    def write_rdb_file(path)
      data = Persistence::RDB.dump(self)
      tmp = "#{path}.tmp-#{Process.pid}"
      File.binwrite(tmp, data)
      File.rename(tmp, path)
    end

    sig { void }
    def load_rdb
      path = @config.rdb_path
      return unless File.exist?(path)

      Persistence::RDB.load(self, File.binread(path))
      log("Loaded keyspace from #{path}")
    rescue StandardError => e
      log("failed to load RDB #{path}: #{e.message}")
    end

    sig { void }
    def reload_rdb
      @databases.each(&:clear)
      load_rdb
    end

    sig { void }
    def teardown
      @clients.values.each { |client| close_client(client) }
      begin
        @listener&.close
      rescue StandardError
        nil
      end
    end

    # --- Introspection -----------------------------------------------------

    sig { returns(T::Array[Client]) }
    def clients = @clients.values

    sig { params(client: Client).returns(String) }
    def client_info_line(client)
      "id=#{client.id} addr=#{client.addr} name=#{client.name} db=#{client.db_index} " \
        "resp=#{client.protocol} sub=#{client.sub_channels.size} psub=#{client.sub_patterns.size} " \
        "multi=#{client.in_multi ? client.multi_queue.size : -1} cmd=NULL lib-name=#{client.lib_name} lib-ver=#{client.lib_ver}"
    end

    sig { returns(String) }
    def clients_info_lines = @clients.values.map { |client| client_info_line(client) }.join("\n")

    sig { params(section: T.nilable(String)).returns(String) }
    def info_report(section)
      sections = {
        "server" => server_section,
        "clients" => clients_section,
        "memory" => memory_section,
        "persistence" => persistence_section,
        "stats" => stats_section,
        "replication" => replication_section,
        "keyspace" => keyspace_section,
      }
      chosen = section.nil? || section == "default" || section == "all" || section == "everything" ? sections.keys : [section]
      chosen.filter_map { |name| sections[name] }.join("\r\n")
    end

    sig { returns(String) }
    def server_section
      <<~TXT.chomp
        # Server
        redis_version:#{RedisRuby::REDIS_VERSION}
        redis_mode:standalone
        os:#{RUBY_PLATFORM}
        process_id:#{Process.pid}
        run_id:#{RedisRuby::RUN_ID}
        tcp_port:#{bound_port}
        uptime_in_seconds:#{Time.now.to_i - @start_time}
        executable:#{File.expand_path($PROGRAM_NAME)}
      TXT
    end

    sig { returns(String) }
    def clients_section
      "# Clients\r\nconnected_clients:#{@clients.size}\r\nblocked_clients:0\r\ncluster_connections:0"
    end

    sig { returns(String) }
    def memory_section
      "# Memory\r\nused_memory:0\r\nused_memory_human:0B\r\nmaxmemory:#{@config.get('maxmemory')}\r\nmaxmemory_policy:#{@config.get('maxmemory-policy')}"
    end

    sig { returns(String) }
    def persistence_section
      <<~TXT.chomp
        # Persistence
        loading:0
        rdb_changes_since_last_save:#{@dirty_since_save}
        rdb_bgsave_in_progress:#{@bgsave_pid ? 1 : 0}
        rdb_last_save_time:#{@last_save}
        aof_enabled:0
      TXT
    end

    sig { returns(String) }
    def stats_section
      <<~TXT.chomp
        # Stats
        total_connections_received:#{@connections_received}
        total_commands_processed:#{@commands_processed}
        instantaneous_ops_per_sec:0
        expired_keys:0
        keyspace_hits:0
        keyspace_misses:0
      TXT
    end

    sig { returns(String) }
    def replication_section
      "# Replication\r\nrole:master\r\nconnected_slaves:0\r\nmaster_failover_state:no-failover"
    end

    sig { returns(String) }
    def keyspace_section
      lines = ["# Keyspace"]
      @databases.each do |database|
        next if database.size.zero?

        lines << "db#{database.index}:keys=#{database.size},expires=#{database.expires.size},avg_ttl=0"
      end
      lines.join("\r\n")
    end

    sig { params(message: String).void }
    def log(message)
      return unless @verbose

      warn("#{Process.pid}:M #{Time.now.strftime('%d %b %Y %H:%M:%S')} * #{message}")
    end
  end
end

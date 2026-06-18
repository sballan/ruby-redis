# typed: strict
# frozen_string_literal: true

module RedisRuby
  # Behavioral flags attached to a command. They drive dispatch decisions
  # (write/readonly bookkeeping, what's permitted while subscribed, loading or
  # inside MULTI) and COMMAND introspection. The serialized value of each
  # member matches the flag name Redis exposes.
  class CommandFlag < T::Enum
    enums do
      Write = new("write")
      Readonly = new("readonly")
      Fast = new("fast")
      Loading = new("loading")
      Pubsub = new("pubsub")
      NoMulti = new("no_multi")
      Admin = new("admin")
    end
  end

  # A single command's metadata plus its handler. arity follows the Redis
  # convention: a positive value means exactly N arguments (including the
  # command name); a negative value means at least N.
  class Command
    extend T::Sig

    Handler = T.type_alias { T.proc.params(client: Client, argv: T::Array[String]).returns(T.untyped) }

    sig { returns(String) }
    attr_reader :name

    sig { returns(Integer) }
    attr_reader :arity

    sig { returns(T::Array[CommandFlag]) }
    attr_reader :flags

    sig { returns(Handler) }
    attr_reader :handler

    sig { params(name: String, arity: Integer, flags: T::Array[CommandFlag], handler: Handler).void }
    def initialize(name, arity, flags, handler)
      @name = name
      @arity = arity
      @flags = flags
      @handler = handler
    end

    sig { params(argc: Integer).returns(T::Boolean) }
    def arity_ok?(argc) = arity >= 0 ? argc == arity : argc >= -arity

    sig { returns(T::Boolean) }
    def write? = @flags.include?(CommandFlag::Write)

    sig { returns(T::Boolean) }
    def readonly? = @flags.include?(CommandFlag::Readonly)

    sig { returns(T::Boolean) }
    def pubsub_safe? = @flags.include?(CommandFlag::Pubsub)

    sig { returns(T::Boolean) }
    def no_multi? = @flags.include?(CommandFlag::NoMulti)

    sig { returns(T::Boolean) }
    def loading_safe? = @flags.include?(CommandFlag::Loading)
  end

  # Registry of all known commands, keyed by lowercased name.
  class CommandTable
    extend T::Sig

    sig { void }
    def initialize
      @commands = T.let({}, T::Hash[String, Command])
    end

    sig { params(name: String, arity: Integer, flags: T::Array[CommandFlag], handler: Command::Handler).void }
    def add(name, arity, flags = [], &handler)
      @commands[name.downcase] = Command.new(name, arity, flags, handler)
    end

    sig { params(name: String).returns(T.nilable(Command)) }
    def lookup(name) = @commands[name.downcase]

    sig { returns(Integer) }
    def size = @commands.size

    sig { returns(T::Array[String]) }
    def names = @commands.keys

    sig { params(block: T.proc.params(command: Command).void).void }
    def each(&block) = @commands.each_value(&block)
  end
end

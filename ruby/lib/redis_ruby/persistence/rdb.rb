# typed: strict
# frozen_string_literal: true

require "zlib"

module RedisRuby
  module Persistence
    # RDB-style point-in-time snapshot serializer. The on-disk layout follows
    # the same opcode-driven shape as Redis' own RDB format (magic header,
    # SELECTDB / EXPIRE opcodes, type-tagged key/value records, EOF + CRC) but
    # uses a self-consistent encoding for the value bodies rather than byte
    # reproducing every upstream object encoding.
    module RDB
      extend T::Sig

      MAGIC = T.let("REDISRB0001".b.freeze, String)

      OP_EOF = 0xFF
      OP_SELECTDB = 0xFE
      OP_EXPIRE_MS = 0xFC

      TYPE_STRING = 0
      TYPE_LIST = 1
      TYPE_SET = 2
      TYPE_ZSET = 3
      TYPE_HASH = 4
      TYPE_STREAM = 5

      # Serialize the entire server keyspace into a binary RDB blob.
      sig { params(server: Server).returns(String) }
      def self.dump(server)
        out = +"".b
        out << MAGIC
        server.each_database do |database|
          next if database.size.zero?

          out << OP_SELECTDB.chr
          write_length(out, database.index)
          database.dict.each do |key, value|
            expire = database.expire_at(key)
            if expire
              out << OP_EXPIRE_MS.chr << [expire].pack("Q<")
            end
            out << type_byte(value).chr
            write_string(out, key)
            write_value(out, value)
          end
        end
        out << OP_EOF.chr
        out << [Zlib.crc32(out)].pack("L<")
        out
      end

      # Populate the server keyspace from a binary RDB blob.
      sig { params(server: Server, data: String).void }
      def self.load(server, data)
        raise Error, "wrong RDB signature" unless data.byteslice(0, MAGIC.bytesize) == MAGIC

        cursor = T.let(MAGIC.bytesize, Integer)
        database = server.db(0)
        pending_expire = T.let(nil, T.nilable(Integer))

        loop do
          opcode = T.must(data.getbyte(cursor))
          cursor += 1
          case opcode
          when OP_EOF then break
          when OP_SELECTDB
            index, cursor = read_length(data, cursor)
            database = server.db(index)
          when OP_EXPIRE_MS
            pending_expire = T.must(data.byteslice(cursor, 8)).unpack1("Q<")
            cursor += 8
          when TYPE_STRING, TYPE_LIST, TYPE_SET, TYPE_ZSET, TYPE_HASH, TYPE_STREAM
            key, cursor = read_string(data, cursor)
            value, cursor = read_value(opcode, data, cursor)
            database.set(key, value)
            if pending_expire
              database.set_expire(key, pending_expire)
              pending_expire = nil
            end
          else
            raise Error, "unknown RDB opcode #{opcode}"
          end
        end
      end

      # --- Writers -----------------------------------------------------------

      sig { params(value: T.untyped).returns(Integer) }
      def self.type_byte(value)
        case value
        when String then TYPE_STRING
        when Types::List then TYPE_LIST
        when Types::Set then TYPE_SET
        when Types::SortedSet then TYPE_ZSET
        when Types::Hash then TYPE_HASH
        when Types::Stream then TYPE_STREAM
        else raise Error, "cannot serialize #{value.class}"
        end
      end

      sig { params(out: String, value: T.untyped).void }
      def self.write_value(out, value)
        case value
        when String then write_string(out, value)
        when Types::List
          write_length(out, value.size)
          value.elements.each { |element| write_string(out, element) }
        when Types::Set
          write_length(out, value.size)
          value.members.each { |member| write_string(out, member) }
        when Types::Hash
          write_length(out, value.size)
          value.fields.each do |field, field_value|
            write_string(out, field)
            write_string(out, field_value)
          end
        when Types::SortedSet
          write_length(out, value.size)
          value.entries.each do |member, score|
            write_string(out, member)
            out << [score].pack("E")
          end
        when Types::Stream then write_stream(out, value)
        end
      end

      sig { params(out: String, stream: Types::Stream).void }
      def self.write_stream(out, stream)
        write_id(out, stream.last_id)
        write_id(out, stream.max_deleted_id)
        write_length(out, stream.entries_added)
        write_length(out, stream.entries.size)
        stream.entries.each do |id, fields|
          write_id(out, id)
          write_length(out, fields.size)
          fields.each { |field| write_string(out, field) }
        end
        write_length(out, stream.groups.size)
        stream.groups.each do |name, group|
          write_string(out, name)
          write_id(out, group.last_delivered_id)
          write_length(out, group.entries_read)
          write_length(out, group.pending.size)
          group.pending.each do |id, pel|
            write_id(out, id)
            write_string(out, pel.consumer)
            write_length(out, pel.delivery_time)
            write_length(out, pel.delivery_count)
          end
          write_length(out, group.consumers.size)
          group.consumers.each do |cname, consumer|
            write_string(out, cname)
            write_length(out, consumer.seen_time)
            write_length(out, consumer.active_time)
          end
        end
      end

      sig { params(out: String, id: [Integer, Integer]).void }
      def self.write_id(out, id)
        write_length(out, id[0])
        write_length(out, id[1])
      end

      # Unsigned LEB128 varint.
      sig { params(out: String, value: Integer).void }
      def self.write_length(out, value)
        loop do
          byte = value & 0x7F
          value >>= 7
          if value.zero?
            out << byte.chr
            break
          end
          out << (byte | 0x80).chr
        end
      end

      sig { params(out: String, str: String).void }
      def self.write_string(out, str)
        write_length(out, str.bytesize)
        out << str
      end

      # --- Readers -----------------------------------------------------------

      sig { params(opcode: Integer, data: String, cursor: Integer).returns([T.untyped, Integer]) }
      def self.read_value(opcode, data, cursor)
        case opcode
        when TYPE_STRING then read_string(data, cursor)
        when TYPE_LIST
          count, cursor = read_length(data, cursor)
          elements = T.let([], T::Array[String])
          count.times do
            element, cursor = read_string(data, cursor)
            elements << element
          end
          [Types::List.new(elements), cursor]
        when TYPE_SET
          count, cursor = read_length(data, cursor)
          members = T.let([], T::Array[String])
          count.times do
            member, cursor = read_string(data, cursor)
            members << member
          end
          [Types::Set.new(members), cursor]
        when TYPE_HASH
          count, cursor = read_length(data, cursor)
          hash = Types::Hash.new
          count.times do
            field, cursor = read_string(data, cursor)
            field_value, cursor = read_string(data, cursor)
            hash.set(field, field_value)
          end
          [hash, cursor]
        when TYPE_ZSET
          count, cursor = read_length(data, cursor)
          zset = Types::SortedSet.new
          count.times do
            member, cursor = read_string(data, cursor)
            score = T.must(data.byteslice(cursor, 8)).unpack1("E")
            cursor += 8
            zset.add(member, score)
          end
          [zset, cursor]
        when TYPE_STREAM then read_stream(data, cursor)
        else raise Error, "unknown RDB type #{opcode}"
        end
      end

      sig { params(data: String, cursor: Integer).returns([Types::Stream, Integer]) }
      def self.read_stream(data, cursor)
        stream = Types::Stream.new
        last_id, cursor = read_id(data, cursor)
        max_deleted_id, cursor = read_id(data, cursor)
        entries_added, cursor = read_length(data, cursor)
        entry_count, cursor = read_length(data, cursor)
        entry_count.times do
          id, cursor = read_id(data, cursor)
          field_count, cursor = read_length(data, cursor)
          fields = T.let([], T::Array[String])
          field_count.times do
            field, cursor = read_string(data, cursor)
            fields << field
          end
          stream.append(id, fields)
        end
        stream.last_id = last_id
        stream.max_deleted_id = max_deleted_id
        stream.entries_added = entries_added

        group_count, cursor = read_length(data, cursor)
        group_count.times do
          name, cursor = read_string(data, cursor)
          last_delivered, cursor = read_id(data, cursor)
          entries_read, cursor = read_length(data, cursor)
          group = Types::StreamGroup.new(last_delivered, entries_read: entries_read)
          pending_count, cursor = read_length(data, cursor)
          pending_count.times do
            id, cursor = read_id(data, cursor)
            consumer, cursor = read_string(data, cursor)
            delivery_time, cursor = read_length(data, cursor)
            delivery_count, cursor = read_length(data, cursor)
            group.pending[id] = Types::StreamPending.new(consumer, delivery_time, delivery_count)
          end
          consumer_count, cursor = read_length(data, cursor)
          consumer_count.times do
            cname, cursor = read_string(data, cursor)
            seen_time, cursor = read_length(data, cursor)
            active_time, cursor = read_length(data, cursor)
            consumer = Types::StreamConsumer.new(cname, seen_time)
            consumer.active_time = active_time
            group.consumers[cname] = consumer
          end
          stream.groups[name] = group
        end
        [stream, cursor]
      end

      sig { params(data: String, cursor: Integer).returns([[Integer, Integer], Integer]) }
      def self.read_id(data, cursor)
        ms, cursor = read_length(data, cursor)
        seq, cursor = read_length(data, cursor)
        [[ms, seq], cursor]
      end

      sig { params(data: String, cursor: Integer).returns([Integer, Integer]) }
      def self.read_length(data, cursor)
        shift = 0
        result = 0
        loop do
          byte = T.must(data.getbyte(cursor))
          cursor += 1
          result |= (byte & 0x7F) << shift
          break if (byte & 0x80).zero?

          shift += 7
        end
        [result, cursor]
      end

      sig { params(data: String, cursor: Integer).returns([String, Integer]) }
      def self.read_string(data, cursor)
        length, cursor = read_length(data, cursor)
        [T.must(data.byteslice(cursor, length)), cursor + length]
      end
    end
  end
end

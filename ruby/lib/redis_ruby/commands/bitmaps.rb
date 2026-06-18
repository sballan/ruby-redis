# typed: strict
# frozen_string_literal: true

module RedisRuby
  module Commands
    # Bit-oriented string commands: SETBIT/GETBIT, BITCOUNT, BITPOS and BITOP.
    module Bitmaps
      extend T::Sig

      MAX_BIT_OFFSET = T.let((4 * 1024 * 1024 * 1024) - 1, Integer) # offsets must be < 2^32

      POPCOUNT = T.let((0..255).map { |byte| byte.to_s(2).count("1") }.freeze, T::Array[Integer])

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.setbit(client, argv)
        key = T.must(argv[1])
        offset = bit_offset(T.must(argv[2]))
        bit_value = T.must(argv[3])
        raise CommandError.generic("bit is not an integer or out of range") unless %w[0 1].include?(bit_value)

        byte_index = offset >> 3
        shift = 7 - (offset & 7)
        buffer = (client.db.lookup_string(key) || +"".b).dup
        buffer << ("\x00".b * (byte_index + 1 - buffer.bytesize)) if byte_index >= buffer.bytesize

        current = T.must(buffer.getbyte(byte_index))
        old = (current >> shift) & 1
        updated = bit_value == "1" ? (current | (1 << shift)) : (current & ~(1 << shift))
        buffer.setbyte(byte_index, updated)
        client.db.set(key, buffer)
        Helpers.touch(client, key)
        old
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.getbit(client, argv)
        offset = bit_offset(T.must(argv[2]))
        buffer = client.db.lookup_string(T.must(argv[1]))
        return 0 if buffer.nil?

        byte_index = offset >> 3
        return 0 if byte_index >= buffer.bytesize

        (T.must(buffer.getbyte(byte_index)) >> (7 - (offset & 7))) & 1
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.bitcount(client, argv)
        buffer = client.db.lookup_string(T.must(argv[1]))
        return 0 if buffer.nil? || buffer.empty?

        return buffer.each_byte.sum { |byte| T.must(POPCOUNT[byte]) } if argv.length == 2
        raise CommandError.syntax if argv.length < 4

        start = Helpers.int(T.must(argv[2]))
        stop = Helpers.int(T.must(argv[3]))
        unit = argv[4] ? T.must(argv[4]).downcase : "byte"
        raise CommandError.syntax unless %w[byte bit].include?(unit)

        if unit == "byte"
          window = Helpers.range(start, stop, buffer.bytesize)
          return 0 if window.nil?

          (window[0]..window[1]).sum { |index| T.must(POPCOUNT[T.must(buffer.getbyte(index))]) }
        else
          window = Helpers.range(start, stop, buffer.bytesize * 8)
          return 0 if window.nil?

          (window[0]..window[1]).count { |index| bit_at(buffer, index) == 1 }
        end
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.bitpos(client, argv)
        target = Helpers.int(T.must(argv[2]))
        raise CommandError.generic("The bit argument must be 1 or 0.") unless [0, 1].include?(target)

        buffer = client.db.lookup_string(T.must(argv[1]))
        return target.zero? ? 0 : -1 if buffer.nil? || buffer.empty?

        unit = argv[5] ? T.must(argv[5]).downcase : "byte"
        raise CommandError.syntax unless %w[byte bit].include?(unit)
        total_bits = buffer.bytesize * 8
        span = unit == "bit" ? total_bits : buffer.bytesize
        end_given = !argv[4].nil?

        start = argv[3] ? Helpers.int(T.must(argv[3])) : 0
        stop = argv[4] ? Helpers.int(T.must(argv[4])) : span - 1
        window = Helpers.range(start, stop, span)
        return -1 if window.nil?

        lo_bit, hi_bit = unit == "bit" ? [window[0], window[1]] : [window[0] * 8, (window[1] * 8) + 7]
        (lo_bit..hi_bit).each { |index| return index if bit_at(buffer, index) == target }

        target.zero? && !end_given ? total_bits : -1
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.bitop(client, argv)
        op = T.must(argv[1]).downcase
        dest = T.must(argv[2])
        sources = (argv[3..] || []).map { |key| client.db.lookup_string(key) || +"".b }
        raise CommandError.wrong_args("bitop") if sources.empty?

        result =
          if op == "not"
            raise CommandError.generic("BITOP NOT must be called with a single source key") unless sources.size == 1

            bit_not(T.must(sources.first))
          else
            raise CommandError.syntax unless %w[and or xor].include?(op)

            bit_combine(sources, op)
          end

        if result.empty?
          deleted = client.db.delete(dest)
          Helpers.touch(client, dest) if deleted
        else
          client.db.set(dest, result)
          Helpers.touch(client, dest)
        end
        result.bytesize
      end

      # --- Internals ---------------------------------------------------------

      sig { params(buffer: String, bit_index: Integer).returns(Integer) }
      def self.bit_at(buffer, bit_index)
        byte_index = bit_index >> 3
        return 0 if byte_index >= buffer.bytesize

        (T.must(buffer.getbyte(byte_index)) >> (7 - (bit_index & 7))) & 1
      end

      sig { params(str: String).returns(String) }
      def self.bit_not(str)
        out = +"".b
        str.each_byte { |byte| out << (~byte & 0xFF) }
        out
      end

      sig { params(sources: T::Array[String], op: String).returns(String) }
      def self.bit_combine(sources, op)
        length = sources.map(&:bytesize).max || 0
        out = +"".b
        length.times do |index|
          acc = T.must(sources.first).getbyte(index) || 0
          (sources[1..] || []).each do |source|
            byte = source.getbyte(index) || 0
            acc = case op
                  when "and" then acc & byte
                  when "or" then acc | byte
                  else acc ^ byte
                  end
          end
          out << (acc & 0xFF)
        end
        out
      end

      sig { params(str: String).returns(Integer) }
      def self.bit_offset(str)
        offset = Helpers.int(str)
        raise CommandError.generic("bit offset is not an integer or out of range") if offset.negative? || offset > MAX_BIT_OFFSET

        offset
      end

      sig { params(table: CommandTable).void }
      def self.install(table)
        table.add("setbit", 4, %i[write]) { |c, a| setbit(c, a) }
        table.add("getbit", 3, %i[readonly fast]) { |c, a| getbit(c, a) }
        table.add("bitcount", -2, %i[readonly]) { |c, a| bitcount(c, a) }
        table.add("bitpos", -3, %i[readonly]) { |c, a| bitpos(c, a) }
        table.add("bitop", -4, %i[write]) { |c, a| bitop(c, a) }
      end
    end
  end
end

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

      BITFIELD_MAX_BYTE = T.let((512 * 1024 * 1024) - 1, Integer) # last touched byte must be < 512MB

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.bitfield(client, argv) = bitfield_generic(client, argv, readonly: false)

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.bitfield_ro(client, argv) = bitfield_generic(client, argv, readonly: true)

      sig { params(client: Client, argv: T::Array[String], readonly: T::Boolean).returns(T.untyped) }
      def self.bitfield_generic(client, argv, readonly:)
        key = T.must(argv[1])
        buffer = (client.db.lookup_string(key) || +"".b).dup
        results = T.let([], T::Array[T.untyped])
        overflow = T.let(:wrap, Symbol)
        wrote = T.let(false, T::Boolean)

        index = 2
        while index < argv.length
          op = T.must(argv[index]).downcase
          case op
          when "get"
            raise CommandError.syntax if index + 2 >= argv.length

            bits, signed = parse_bitfield_type(T.must(argv[index + 1]))
            bitoffset = parse_bitfield_offset(T.must(argv[index + 2]), bits)
            results << bitfield_read(buffer, bitoffset, bits, signed)
            index += 3
          when "set"
            raise CommandError.generic("BITFIELD_RO only supports the GET subcommand") if readonly
            raise CommandError.syntax if index + 3 >= argv.length

            bits, signed = parse_bitfield_type(T.must(argv[index + 1]))
            bitoffset = parse_bitfield_offset(T.must(argv[index + 2]), bits)
            old = bitfield_read(buffer, bitoffset, bits, signed)
            value, ok = apply_overflow(Helpers.int(T.must(argv[index + 3])), bits, signed, overflow)
            if ok
              set_bits(buffer, bitoffset, bits, value)
              wrote = true
              results << old
            else
              results << nil
            end
            index += 4
          when "incrby"
            raise CommandError.generic("BITFIELD_RO only supports the GET subcommand") if readonly
            raise CommandError.syntax if index + 3 >= argv.length

            bits, signed = parse_bitfield_type(T.must(argv[index + 1]))
            bitoffset = parse_bitfield_offset(T.must(argv[index + 2]), bits)
            current = bitfield_read(buffer, bitoffset, bits, signed)
            incr = Helpers.int(T.must(argv[index + 3]))
            value, ok = apply_overflow(current + incr, bits, signed, overflow)
            if ok
              set_bits(buffer, bitoffset, bits, value)
              wrote = true
              results << value
            else
              results << nil
            end
            index += 4
          when "overflow"
            raise CommandError.generic("BITFIELD_RO only supports the GET subcommand") if readonly
            raise CommandError.syntax if index + 1 >= argv.length

            mode = T.must(argv[index + 1]).downcase
            case mode
            when "wrap" then overflow = :wrap
            when "sat" then overflow = :sat
            when "fail" then overflow = :fail
            else raise CommandError.generic("Invalid OVERFLOW type specified")
            end
            index += 2
          else
            raise CommandError.syntax
          end
        end

        if wrote
          client.db.set(key, buffer)
          Helpers.touch(client, key)
        end
        results
      end

      # Parse a bitfield type token like "u8" or "i16". Returns [bits, signed].
      sig { params(token: String).returns([Integer, T::Boolean]) }
      def self.parse_bitfield_type(token)
        error = CommandError.generic(
          "Invalid bitfield type. Use something like i16 u8. Note that u64 is not supported but i64 is."
        )
        raise error if token.length < 2

        sign = token[0]
        raise error unless %w[u i].include?(T.must(sign))

        width_str = T.must(token[1..])
        raise error unless width_str.match?(/\A\d+\z/)

        bits = width_str.to_i
        signed = sign == "i"
        if signed
          raise error unless bits >= 1 && bits <= 64
        else
          raise error unless bits >= 1 && bits <= 63
        end
        [bits, signed]
      end

      # Parse an offset token: a bit offset, or "#<n>" meaning n * bits.
      sig { params(token: String, bits: Integer).returns(Integer) }
      def self.parse_bitfield_offset(token, bits)
        offset =
          if token.start_with?("#")
            Helpers.int(T.must(token[1..])) * bits
          else
            Helpers.int(token)
          end
        out_of_range = CommandError.generic("bit offset is not an integer or out of range")
        raise out_of_range if offset.negative?
        raise out_of_range if ((offset + bits - 1) >> 3) > BITFIELD_MAX_BYTE

        offset
      end

      # Read a `bits`-wide integer at `bitoffset` (big-endian bit order). Bytes
      # past the buffer end read as 0. Sign-extends when `signed` and top bit set.
      sig { params(buffer: String, bitoffset: Integer, bits: Integer, signed: T::Boolean).returns(Integer) }
      def self.bitfield_read(buffer, bitoffset, bits, signed)
        value = get_unsigned(buffer, bitoffset, bits)
        value -= (1 << bits) if signed && (value & (1 << (bits - 1))) != 0
        value
      end

      # Read `bits` bits as an unsigned integer; bytes past the end read as 0.
      sig { params(buffer: String, bitoffset: Integer, bits: Integer).returns(Integer) }
      def self.get_unsigned(buffer, bitoffset, bits)
        value = 0
        bits.times { |k| value = (value << 1) | bit_at(buffer, bitoffset + k) }
        value
      end

      # Write the low `bits` bits of `value` at `bitoffset`, growing the buffer.
      sig { params(buffer: String, bitoffset: Integer, bits: Integer, value: Integer).void }
      def self.set_bits(buffer, bitoffset, bits, value)
        last_byte = (bitoffset + bits - 1) >> 3
        buffer << ("\x00".b * (last_byte + 1 - buffer.bytesize)) if last_byte >= buffer.bytesize

        bits.times do |k|
          bit = (value >> (bits - 1 - k)) & 1
          index = bitoffset + k
          byte_index = index >> 3
          shift = 7 - (index & 7)
          current = T.must(buffer.getbyte(byte_index))
          updated = bit == 1 ? (current | (1 << shift)) : (current & ~(1 << shift))
          buffer.setbyte(byte_index, updated)
        end
      end

      # Apply the overflow mode to `value` for a `bits`-wide field. Returns
      # [adjusted_value, ok]; ok is false only for :fail when out of range.
      sig { params(value: Integer, bits: Integer, signed: T::Boolean, mode: Symbol).returns([Integer, T::Boolean]) }
      def self.apply_overflow(value, bits, signed, mode)
        if signed
          lo = -(1 << (bits - 1))
          hi = (1 << (bits - 1)) - 1
        else
          lo = 0
          hi = (1 << bits) - 1
        end

        case mode
        when :sat
          return [lo, true] if value < lo
          return [hi, true] if value > hi

          [value, true]
        when :fail
          return [value, false] if value < lo || value > hi

          [value, true]
        else # :wrap
          if signed
            modulus = 1 << bits
            wrapped = value % modulus
            wrapped -= modulus if wrapped > hi
            [wrapped, true]
          else
            [value & hi, true]
          end
        end
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
        table.add("setbit", 4, [CommandFlag::Write]) { |c, a| setbit(c, a) }
        table.add("getbit", 3, [CommandFlag::Readonly, CommandFlag::Fast]) { |c, a| getbit(c, a) }
        table.add("bitcount", -2, [CommandFlag::Readonly]) { |c, a| bitcount(c, a) }
        table.add("bitpos", -3, [CommandFlag::Readonly]) { |c, a| bitpos(c, a) }
        table.add("bitop", -4, [CommandFlag::Write]) { |c, a| bitop(c, a) }
        table.add("bitfield", -2, [CommandFlag::Write]) { |c, a| bitfield(c, a) }
        table.add("bitfield_ro", -2, [CommandFlag::Readonly]) { |c, a| bitfield_ro(c, a) }
      end
    end
  end
end

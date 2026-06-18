# typed: strict
# frozen_string_literal: true

module RedisRuby
  module Commands
    # HyperLogLog commands: PFADD/PFCOUNT/PFMERGE. The sketch is stored as a
    # plain binary string in the keyspace (so TYPE reports "string"), using a
    # dense-only layout compatible in spirit with Redis' "HYLL" encoding.
    module HyperLogLog
      extend T::Sig

      MASK64 = T.let(0xFFFFFFFFFFFFFFFF, Integer)

      HLL_HDR_SIZE = 16        # "HYLL" magic + encoding + cached cardinality
      HLL_P = 14               # number of registers is 2^P
      HLL_REGISTERS = 16384    # 2^14
      HLL_BITS = 6             # bits per register
      HLL_REGISTER_MAX = 63    # (1 << HLL_BITS) - 1
      HLL_Q = 50               # 64 - HLL_P
      HLL_REGS_SIZE = 12288    # (HLL_REGISTERS * HLL_BITS + 7) / 8
      HLL_DENSE_SIZE = 12304   # HLL_HDR_SIZE + HLL_REGS_SIZE

      HLL_DENSE = 0            # dense encoding byte

      MURMUR_SEED = 0xadc83b19
      MURMUR_M = 0xc6a4a7935bd1e995
      MURMUR_R = 47

      HLL_ALPHA_INF = T.let(0.5 / Math.log(2), Float)

      # --- Dense register access ---------------------------------------------

      # Read a 6-bit register value from the registers region.
      sig { params(regs: String, regnum: Integer).returns(Integer) }
      def self.get_register(regs, regnum)
        bit = regnum * HLL_BITS
        byte = bit / 8
        fb = bit % 8
        fb8 = 8 - fb
        b0 = T.must(regs.getbyte(byte))
        b1 = regs.getbyte(byte + 1) || 0
        ((b0 >> fb) | (b1 << fb8)) & HLL_REGISTER_MAX
      end

      # Write a 6-bit register value into the registers region.
      sig { params(regs: String, regnum: Integer, val: Integer).void }
      def self.set_register(regs, regnum, val)
        bit = regnum * HLL_BITS
        byte = bit / 8
        fb = bit % 8
        fb8 = 8 - fb
        b0 = T.must(regs.getbyte(byte))
        regs.setbyte(byte, (b0 & ~(HLL_REGISTER_MAX << fb) & 0xff) | ((val << fb) & 0xff))
        if byte + 1 < regs.bytesize
          b1 = T.must(regs.getbyte(byte + 1))
          regs.setbyte(byte + 1, (b1 & (~(HLL_REGISTER_MAX >> fb8) & 0xff)) | (val >> fb8))
        end
      end

      # --- Hashing (MurmurHash64A) -------------------------------------------

      sig { params(data: String).returns(Integer) }
      def self.murmur64a(data)
        len = data.bytesize
        h = (MURMUR_SEED ^ ((len * MURMUR_M) & MASK64)) & MASK64

        blocks = len / 8
        blocks.times do |block|
          base = block * 8
          k = 0
          7.downto(0) { |i| k = ((k << 8) | T.must(data.getbyte(base + i))) & MASK64 }

          k = (k * MURMUR_M) & MASK64
          k ^= k >> MURMUR_R
          k = (k * MURMUR_M) & MASK64
          h ^= k
          h = (h * MURMUR_M) & MASK64
        end

        tail = blocks * 8
        rem = len - tail
        if rem.positive?
          k = 0
          (rem - 1).downto(0) { |i| k = (k | (T.must(data.getbyte(tail + i)) << (8 * i))) & MASK64 }
          h ^= k
          h = (h * MURMUR_M) & MASK64
        end

        h ^= h >> MURMUR_R
        h = (h * MURMUR_M) & MASK64
        h ^= h >> MURMUR_R
        h
      end

      # Compute the (index, pattern length) pair for an element, then bump the
      # target register if the new pattern length is larger. Returns true if the
      # register was updated.
      sig { params(regs: String, ele: String).returns(T::Boolean) }
      def self.add_element(regs, ele)
        hash = murmur64a(ele)
        index = hash & (HLL_REGISTERS - 1) # low 14 bits
        hash >>= HLL_P
        hash |= (1 << HLL_Q) # sentinel so the loop terminates (Q=50)
        count = 1
        bit = 1
        while (hash & bit).zero?
          count += 1
          bit <<= 1
        end

        old = get_register(regs, index)
        if count > old
          set_register(regs, index, count)
          true
        else
          false
        end
      end

      # --- HLL object helpers ------------------------------------------------

      # Allocate a fresh, all-zero dense HLL (with the cache-invalid bit set).
      sig { returns(String) }
      def self.create_dense
        buffer = +"HYLL".b
        buffer << ("\x00".b * (HLL_DENSE_SIZE - 4))
        buffer.setbyte(4, HLL_DENSE)
        set_cache_invalid(buffer)
        buffer
      end

      # Validate that a value is a dense HLL string, raising WRONGTYPE otherwise.
      sig { params(buffer: String).void }
      def self.validate!(buffer)
        valid = buffer.bytesize >= HLL_HDR_SIZE &&
                buffer.byteslice(0, 4) == "HYLL" &&
                buffer.getbyte(4) == HLL_DENSE
        return if valid

        raise CommandError.raw("WRONGTYPE Key is not a valid HyperLogLog string value.")
      end

      # The mutable registers region of a dense HLL buffer.
      sig { params(buffer: String).returns(String) }
      def self.registers(buffer) = T.must(buffer.byteslice(HLL_HDR_SIZE, HLL_REGS_SIZE))

      sig { params(buffer: String).returns(T::Boolean) }
      def self.cache_valid?(buffer) = (T.must(buffer.getbyte(15)) & 0x80).zero?

      sig { params(buffer: String).void }
      def self.set_cache_invalid(buffer)
        buffer.setbyte(15, T.must(buffer.getbyte(15)) | 0x80)
      end

      # Read the 8-byte little-endian cached cardinality (high flag bit masked).
      sig { params(buffer: String).returns(Integer) }
      def self.read_cache(buffer)
        value = 0
        7.downto(0) do |i|
          byte = T.must(buffer.getbyte(8 + i))
          byte &= 0x7f if i == 7
          value = (value << 8) | byte
        end
        value
      end

      # Write the cached cardinality into the header and clear the invalid bit.
      sig { params(buffer: String, value: Integer).void }
      def self.write_cache(buffer, value)
        8.times { |i| buffer.setbyte(8 + i, (value >> (8 * i)) & 0xff) }
        buffer.setbyte(15, T.must(buffer.getbyte(15)) & 0x7f)
      end

      # --- Estimator (Redis 7 / Ertl) ----------------------------------------

      sig { params(x: Float).returns(Float) }
      def self.hll_tau(x)
        return 0.0 if x.zero? || x == 1.0

        z_prime = 0.0
        y = 1.0
        z = 1.0 - x
        loop do
          x = Math.sqrt(x)
          z_prime = z
          y *= 0.5
          z -= ((1 - x)**2) * y
          break if z == z_prime
        end
        z / 3
      end

      sig { params(x: Float).returns(Float) }
      def self.hll_sigma(x)
        return Float::INFINITY if x == 1.0

        z_prime = 0.0
        y = 1.0
        z = x
        loop do
          x *= x
          z_prime = z
          z += x * y
          y += y
          break if z == z_prime
        end
        z
      end

      # Estimate the cardinality from a register-value histogram.
      sig { params(reghisto: T::Array[Integer]).returns(Integer) }
      def self.estimate(reghisto)
        m = HLL_REGISTERS.to_f
        z = m * hll_tau((m - T.must(reghisto[HLL_Q + 1]).to_f) / m)
        HLL_Q.downto(1) do |j|
          z += T.must(reghisto[j])
          z *= 0.5
        end
        z += m * hll_sigma(T.must(reghisto[0]).to_f / m)
        (HLL_ALPHA_INF * m * m / z).round
      end

      # Build a register-value histogram from a registers region.
      sig { params(regs: String).returns(T::Array[Integer]) }
      def self.histogram(regs)
        reghisto = T.let(Array.new(64, 0), T::Array[Integer])
        HLL_REGISTERS.times do |i|
          v = get_register(regs, i)
          reghisto[v] = T.must(reghisto[v]) + 1
        end
        reghisto
      end

      # Element-wise max of source registers into the (mutable) accumulator.
      sig { params(acc: String, regs: String).void }
      def self.merge_into(acc, regs)
        HLL_REGISTERS.times do |i|
          v = get_register(regs, i)
          set_register(acc, i, v) if v > get_register(acc, i)
        end
      end

      # --- Commands ----------------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.pfadd(client, argv)
        key = T.must(argv[1])
        existing = client.db.lookup_string(key)

        created = T.let(false, T::Boolean)
        buffer = if existing.nil?
          created = true
          create_dense
        else
          validate!(existing)
          existing.dup
        end

        regs = registers(buffer)
        updated = T.let(false, T::Boolean)
        (2...argv.length).each do |i|
          updated = true if add_element(regs, T.must(argv[i]))
        end

        if updated || created
          # Splice the (possibly mutated) registers region back into the buffer
          # and mark the cache stale.
          buffer[HLL_HDR_SIZE, HLL_REGS_SIZE] = regs
          set_cache_invalid(buffer)
          client.db.set(key, buffer)
          Helpers.touch(client, key)
          1
        else
          0
        end
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.pfcount(client, argv)
        if argv.length == 2
          key = T.must(argv[1])
          buffer = client.db.lookup_string(key)
          return 0 if buffer.nil?

          validate!(buffer)
          return read_cache(buffer) if cache_valid?(buffer)

          card = estimate(histogram(registers(buffer)))
          updated = buffer.dup
          write_cache(updated, card)
          client.db.set(key, updated) # cache write-back; no Helpers.touch
          return card
        end

        acc = registers(create_dense)
        (1...argv.length).each do |i|
          source = client.db.lookup_string(T.must(argv[i]))
          next if source.nil?

          validate!(source)
          merge_into(acc, registers(source))
        end
        estimate(histogram(acc))
      end

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.pfmerge(client, argv)
        destkey = T.must(argv[1])
        acc = registers(create_dense)

        dest = client.db.lookup_string(destkey)
        unless dest.nil?
          validate!(dest)
          merge_into(acc, registers(dest))
        end

        (2...argv.length).each do |i|
          source = client.db.lookup_string(T.must(argv[i]))
          next if source.nil?

          validate!(source)
          merge_into(acc, registers(source))
        end

        buffer = create_dense
        buffer[HLL_HDR_SIZE, HLL_REGS_SIZE] = acc
        set_cache_invalid(buffer)
        client.db.set(destkey, buffer)
        Helpers.touch(client, destkey)
        Reply::OK
      end

      sig { params(table: CommandTable).void }
      def self.install(table)
        table.add("pfadd", -2, [CommandFlag::Write, CommandFlag::Fast]) { |c, a| pfadd(c, a) }
        table.add("pfcount", -2, [CommandFlag::Readonly]) { |c, a| pfcount(c, a) }
        table.add("pfmerge", -2, [CommandFlag::Write]) { |c, a| pfmerge(c, a) }
      end
    end
  end
end

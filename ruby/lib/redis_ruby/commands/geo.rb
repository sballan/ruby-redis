# typed: strict
# frozen_string_literal: true

module RedisRuby
  module Commands
    # Geospatial commands. A geo key is just a sorted set whose members map to a
    # 52-bit interleaved geohash (stored as a Float score), so ZSCORE/ZRANGE/ZREM
    # all operate on geo keys transparently (their TYPE is "zset"). The encoding
    # and Haversine math is a direct port of Redis' geohash helpers; searches are
    # an honest O(n) brute force over every member rather than the geohash
    # neighbour optimisation.
    module Geo
      extend T::Sig

      GEO_STEP = 26
      GEO_LAT_MIN = -85.05112878
      GEO_LAT_MAX = 85.05112878
      GEO_LONG_MIN = -180.0
      GEO_LONG_MAX = 180.0
      EARTH_RADIUS_M = 6_372_797.560856
      DEG_TO_RAD = 0.017453292519943295

      GEOALPHA = "0123456789bcdefghjkmnpqrstuvwxyz"

      B = T.let(
        [0x5555555555555555, 0x3333333333333333, 0x0F0F0F0F0F0F0F0F, 0x00FF00FF00FF00FF, 0x0000FFFF0000FFFF],
        T::Array[Integer]
      )
      S = T.let([1, 2, 4, 8, 16], T::Array[Integer])

      UNITS = T.let(
        { "m" => 1.0, "km" => 1000.0, "mi" => 1609.34, "ft" => 0.3048 },
        T::Hash[String, Float]
      )

      # --- Morton (bit-interleaving) helpers ---------------------------------

      sig { params(v: Integer).returns(Integer) }
      def self.spread(v)
        v &= 0xffffffff
        v = (v | (v << T.must(S[4]))) & T.must(B[4])
        v = (v | (v << T.must(S[3]))) & T.must(B[3])
        v = (v | (v << T.must(S[2]))) & T.must(B[2])
        v = (v | (v << T.must(S[1]))) & T.must(B[1])
        (v | (v << T.must(S[0]))) & T.must(B[0])
      end

      sig { params(v: Integer).returns(Integer) }
      def self.squash(v)
        v &= T.must(B[0])
        v = (v | (v >> T.must(S[0]))) & T.must(B[1])
        v = (v | (v >> T.must(S[1]))) & T.must(B[2])
        v = (v | (v >> T.must(S[2]))) & T.must(B[3])
        v = (v | (v >> T.must(S[3]))) & T.must(B[4])
        (v | (v >> T.must(S[4]))) & 0xffffffff
      end

      sig { params(x: Integer, y: Integer).returns(Integer) }
      def self.interleave64(x, y) = spread(x) | (spread(y) << 1)

      sig { params(interleaved: Integer).returns([Integer, Integer]) }
      def self.deinterleave64(interleaved)
        [squash(interleaved), squash(interleaved >> 1)]
      end

      # --- Encode / decode ---------------------------------------------------

      sig { params(lon: Float, lat: Float).returns(Integer) }
      def self.encode(lon, lat)
        lat_offset = (lat - GEO_LAT_MIN) / (GEO_LAT_MAX - GEO_LAT_MIN)
        long_offset = (lon - GEO_LONG_MIN) / (GEO_LONG_MAX - GEO_LONG_MIN)
        ilat = (lat_offset * (1 << GEO_STEP)).to_i
        ilon = (long_offset * (1 << GEO_STEP)).to_i
        interleave64(ilat, ilon)
      end

      sig { params(score: Integer).returns([Float, Float]) }
      def self.decode(score)
        ilat, ilon = deinterleave64(score)
        lat_min = GEO_LAT_MIN + (ilat / 2.0**GEO_STEP) * (GEO_LAT_MAX - GEO_LAT_MIN)
        lat_max = GEO_LAT_MIN + ((ilat + 1) / 2.0**GEO_STEP) * (GEO_LAT_MAX - GEO_LAT_MIN)
        lon_min = GEO_LONG_MIN + (ilon / 2.0**GEO_STEP) * (GEO_LONG_MAX - GEO_LONG_MIN)
        lon_max = GEO_LONG_MIN + ((ilon + 1) / 2.0**GEO_STEP) * (GEO_LONG_MAX - GEO_LONG_MIN)
        [(lon_min + lon_max) / 2, (lat_min + lat_max) / 2]
      end

      sig { params(lon1: Float, lat1: Float, lon2: Float, lat2: Float).returns(Float) }
      def self.haversine(lon1, lat1, lon2, lat2)
        lat1r = lat1 * DEG_TO_RAD
        lon1r = lon1 * DEG_TO_RAD
        lat2r = lat2 * DEG_TO_RAD
        lon2r = lon2 * DEG_TO_RAD
        u = Math.sin((lat2r - lat1r) / 2)
        v = Math.sin((lon2r - lon1r) / 2)
        a = (u * u) + (Math.cos(lat1r) * Math.cos(lat2r) * v * v)
        2.0 * EARTH_RADIUS_M * Math.asin(Math.sqrt(a))
      end

      # Standard 11-char base32 geohash string for the GEOHASH command. Decodes
      # the stored score, then re-encodes against the standard [-90,90]/[-180,180]
      # ranges and emits 11 groups of 5 bits.
      sig { params(score: Integer).returns(String) }
      def self.geohash_string(score)
        lon, lat = decode(score)
        lat_off = (lat - (-90.0)) / 180.0
        lon_off = (lon - (-180.0)) / 360.0
        ilat = (lat_off * 2**GEO_STEP).to_i
        ilon = (lon_off * 2**GEO_STEP).to_i
        bits = interleave64(ilat, ilon)
        s = +""
        11.times do |i|
          idx = i == 10 ? 0 : ((bits >> (52 - ((i + 1) * 5))) & 0x1f)
          s << T.must(GEOALPHA[idx])
        end
        s
      end

      sig { params(unit: String).returns(Float) }
      def self.unit_multiplier(unit)
        multiplier = UNITS[unit.downcase]
        raise CommandError.generic("unsupported unit provided. please use M, KM, FT, MI") if multiplier.nil?

        multiplier
      end

      sig { params(value: Float).returns(String) }
      def self.fmt17(value) = format("%.17g", value).b

      # --- GEOADD ------------------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.geoadd(client, argv)
        key = T.must(argv[1])
        nx = xx = ch = T.let(false, T::Boolean)
        index = 2
        while index < argv.length
          case T.must(argv[index]).downcase
          when "nx" then nx = true
          when "xx" then xx = true
          when "ch" then ch = true
          else break
          end
          index += 1
        end

        rest = argv[index..] || []
        raise CommandError.syntax if rest.empty? || (rest.length % 3) != 0

        triplets = rest.each_slice(3).map do |lon_s, lat_s, member|
          lon = Util.string_to_float(T.must(lon_s))
          lat = Util.string_to_float(T.must(lat_s))
          if lon < GEO_LONG_MIN || lon > GEO_LONG_MAX || lat < GEO_LAT_MIN || lat > GEO_LAT_MAX
            raise CommandError.generic(format("invalid longitude,latitude pair %.6f,%.6f", lon, lat))
          end

          [T.must(member), encode(lon, lat).to_f]
        end

        zset = client.db.lookup_zset(key)
        preexisting = !zset.nil?
        zset ||= Types::SortedSet.new
        added = changed = 0

        triplets.each do |member, score|
          exists = zset.include?(member)
          next if nx && exists
          next if xx && !exists

          current = zset.score(member)
          if exists
            if score != current
              zset.add(member, score)
              changed += 1
            end
          else
            zset.add(member, score)
            added += 1
            changed += 1
          end
        end

        client.db.set(key, zset) if !preexisting && !zset.empty?
        Helpers.touch(client, key) if changed.positive?
        ch ? changed : added
      end

      # --- GEOPOS ------------------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.geopos(client, argv)
        zset = client.db.lookup_zset(T.must(argv[1]))
        (argv[2..] || []).map do |member|
          score = zset&.score(member)
          next nil if score.nil?

          lon, lat = decode(score.to_i)
          [fmt17(lon), fmt17(lat)]
        end
      end

      # --- GEODIST -----------------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.geodist(client, argv)
        unit = argv[4] ? T.must(argv[4]) : "m"
        multiplier = unit_multiplier(unit)
        zset = client.db.lookup_zset(T.must(argv[1]))
        score1 = zset&.score(T.must(argv[2]))
        score2 = zset&.score(T.must(argv[3]))
        return nil if score1.nil? || score2.nil?

        lon1, lat1 = decode(score1.to_i)
        lon2, lat2 = decode(score2.to_i)
        dist = haversine(lon1, lat1, lon2, lat2) / multiplier
        format("%.4f", dist)
      end

      # --- GEOHASH -----------------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.geohash(client, argv)
        zset = client.db.lookup_zset(T.must(argv[1]))
        (argv[2..] || []).map do |member|
          score = zset&.score(member)
          next nil if score.nil?

          geohash_string(score.to_i)
        end
      end

      # --- Core search -------------------------------------------------------

      # A shape is [:radius, radius_m] or [:box, width_m, height_m].
      sig do
        params(
          client: Client,
          key: String,
          center_lon: Float,
          center_lat: Float,
          shape: T::Array[T.untyped],
          opts: T::Hash[Symbol, T.untyped]
        ).returns(T::Array[T::Array[T.untyped]])
      end
      def self.search(client, key, center_lon, center_lat, shape, opts)
        zset = client.db.lookup_zset(key)
        results = T.let([], T::Array[T::Array[T.untyped]])
        unless zset.nil?
          zset.entries.each do |member, score|
            iscore = score.to_i
            lon, lat = decode(iscore)
            dist = haversine(center_lon, center_lat, lon, lat)
            next unless qualifies?(shape, center_lon, center_lat, lon, lat, dist)

            results << [member, dist, iscore, lon, lat]
          end
        end

        desc = opts[:desc]
        results.sort_by! { |row| [T.cast(row[1], Float), T.cast(row[0], String)] }
        results.reverse! if desc

        count = opts[:count]
        results = results.first(count) if count

        results
      end

      sig do
        params(
          shape: T::Array[T.untyped],
          center_lon: Float,
          center_lat: Float,
          lon: Float,
          lat: Float,
          dist: Float
        ).returns(T::Boolean)
      end
      def self.qualifies?(shape, center_lon, center_lat, lon, lat, dist)
        case shape[0]
        when :radius
          dist <= T.cast(shape[1], Float)
        else
          width = T.cast(shape[1], Float)
          height = T.cast(shape[2], Float)
          lat_dist = haversine(center_lon, center_lat, center_lon, lat)
          lon_dist = haversine(center_lon, center_lat, lon, center_lat)
          lat_dist <= height / 2 && lon_dist <= width / 2
        end
      end

      sig do
        params(
          results: T::Array[T::Array[T.untyped]],
          with_coord: T::Boolean,
          with_dist: T::Boolean,
          with_hash: T::Boolean,
          unit_multiplier: Float
        ).returns(T::Array[T.untyped])
      end
      def self.render(results, with_coord, with_dist, with_hash, unit_multiplier)
        return results.map { |row| row[0] } unless with_coord || with_dist || with_hash

        results.map do |row|
          member, dist, iscore, lon, lat = row
          element = T.let([member], T::Array[T.untyped])
          element << format("%.4f", T.cast(dist, Float) / unit_multiplier) if with_dist
          element << iscore if with_hash
          element << [fmt17(T.cast(lon, Float)), fmt17(T.cast(lat, Float))] if with_coord
          element
        end
      end

      # Determine the center (lon, lat) from FROMMEMBER / FROMLONLAT tokens
      # starting at +argv[index]+. Returns [lon, lat, next_index].
      sig { params(client: Client, key: String, argv: T::Array[String], index: Integer).returns([Float, Float, Integer]) }
      def self.parse_center(client, key, argv, index)
        case T.must(argv[index]).downcase
        when "frommember"
          member = T.must(argv[index + 1])
          score = client.db.lookup_zset(key)&.score(member)
          raise CommandError.generic("could not decode requested zset member") if score.nil?

          lon, lat = decode(score.to_i)
          [lon, lat, index + 2]
        when "fromlonlat"
          lon = Util.string_to_float(T.must(argv[index + 1]))
          lat = Util.string_to_float(T.must(argv[index + 2]))
          [lon, lat, index + 3]
        else raise CommandError.syntax
        end
      end

      # Parse a BYRADIUS / BYBOX clause starting at +argv[index]+. Returns
      # [shape, unit_multiplier, next_index].
      sig { params(argv: T::Array[String], index: Integer).returns([T::Array[T.untyped], Float, Integer]) }
      def self.parse_shape(argv, index)
        case T.must(argv[index]).downcase
        when "byradius"
          radius = Util.string_to_float(T.must(argv[index + 1]))
          multiplier = unit_multiplier(T.must(argv[index + 2]))
          [[:radius, radius * multiplier], multiplier, index + 3]
        when "bybox"
          width = Util.string_to_float(T.must(argv[index + 1]))
          height = Util.string_to_float(T.must(argv[index + 2]))
          multiplier = unit_multiplier(T.must(argv[index + 3]))
          [[:box, width * multiplier, height * multiplier], multiplier, index + 4]
        else raise CommandError.syntax
        end
      end

      # Parse the trailing [ASC|DESC] [COUNT n [ANY]] [WITHCOORD] [WITHDIST]
      # [WITHHASH] options of GEOSEARCH.
      sig { params(argv: T::Array[String], index: Integer).returns(T::Hash[Symbol, T.untyped]) }
      def self.parse_search_opts(argv, index)
        opts = T.let({ asc: false, desc: false, count: nil, with_coord: false, with_dist: false, with_hash: false }, T::Hash[Symbol, T.untyped])
        while index < argv.length
          case T.must(argv[index]).downcase
          when "asc" then opts[:asc] = true; index += 1
          when "desc" then opts[:desc] = true; index += 1
          when "count"
            opts[:count] = Helpers.positive_int(T.must(argv[index + 1]))
            index += 2
            if argv[index] && T.must(argv[index]).casecmp?("any")
              index += 1
            end
          when "withcoord" then opts[:with_coord] = true; index += 1
          when "withdist" then opts[:with_dist] = true; index += 1
          when "withhash" then opts[:with_hash] = true; index += 1
          else raise CommandError.syntax
          end
        end
        opts
      end

      # --- GEOSEARCH ---------------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.geosearch(client, argv)
        key = T.must(argv[1])
        lon, lat, index = parse_center(client, key, argv, 2)
        shape, multiplier, index = parse_shape(argv, index)
        opts = parse_search_opts(argv, index)
        results = search(client, key, lon, lat, shape, opts)
        render(results, T.cast(opts[:with_coord], T::Boolean), T.cast(opts[:with_dist], T::Boolean), T.cast(opts[:with_hash], T::Boolean), multiplier)
      end

      # --- GEOSEARCHSTORE ----------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.geosearchstore(client, argv)
        dest = T.must(argv[1])
        src = T.must(argv[2])
        lon, lat, index = parse_center(client, src, argv, 3)
        shape, _multiplier, index = parse_shape(argv, index)
        opts, storedist = parse_store_opts(argv, index)
        results = search(client, src, lon, lat, shape, opts)
        store_results(client, dest, results, storedist)
      end

      # Parse GEOSEARCHSTORE's trailing options: [ASC|DESC] [COUNT n [ANY]]
      # [STOREDIST]. Returns [search_opts, storedist?].
      sig { params(argv: T::Array[String], index: Integer).returns([T::Hash[Symbol, T.untyped], T::Boolean]) }
      def self.parse_store_opts(argv, index)
        opts = T.let({ asc: false, desc: false, count: nil, with_coord: false, with_dist: false, with_hash: false }, T::Hash[Symbol, T.untyped])
        storedist = T.let(false, T::Boolean)
        while index < argv.length
          case T.must(argv[index]).downcase
          when "asc" then opts[:asc] = true; index += 1
          when "desc" then opts[:desc] = true; index += 1
          when "count"
            opts[:count] = Helpers.positive_int(T.must(argv[index + 1]))
            index += 2
            index += 1 if argv[index] && T.must(argv[index]).casecmp?("any")
          when "storedist" then storedist = true; index += 1
          else raise CommandError.syntax
          end
        end
        [opts, storedist]
      end

      sig do
        params(client: Client, dest: String, results: T::Array[T::Array[T.untyped]], storedist: T::Boolean)
          .returns(Integer)
      end
      def self.store_results(client, dest, results, storedist)
        if results.empty?
          deleted = client.db.delete(dest)
          Helpers.touch(client, dest) if deleted
          return 0
        end

        result = Types::SortedSet.new
        results.each do |row|
          member = T.cast(row[0], String)
          score = storedist ? T.cast(row[1], Float) : T.cast(row[2], Integer).to_f
          result.add(member, score)
        end
        client.db.set(dest, result)
        Helpers.touch(client, dest)
        result.size
      end

      # --- GEORADIUS family --------------------------------------------------

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.georadius(client, argv) = radius(client, argv, by_member: false, store: true)

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.georadius_ro(client, argv) = radius(client, argv, by_member: false, store: false)

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.georadiusbymember(client, argv) = radius(client, argv, by_member: true, store: true)

      sig { params(client: Client, argv: T::Array[String]).returns(T.untyped) }
      def self.georadiusbymember_ro(client, argv) = radius(client, argv, by_member: true, store: false)

      sig { params(client: Client, argv: T::Array[String], by_member: T::Boolean, store: T::Boolean).returns(T.untyped) }
      def self.radius(client, argv, by_member:, store:)
        key = T.must(argv[1])
        if by_member
          member = T.must(argv[2])
          score = client.db.lookup_zset(key)&.score(member)
          raise CommandError.generic("could not decode requested zset member") if score.nil?

          lon, lat = decode(score.to_i)
          index = 3
        else
          lon = Util.string_to_float(T.must(argv[2]))
          lat = Util.string_to_float(T.must(argv[3]))
          index = 4
        end

        radius_value = Util.string_to_float(T.must(argv[index]))
        multiplier = unit_multiplier(T.must(argv[index + 1]))
        shape = T.let([:radius, radius_value * multiplier], T::Array[T.untyped])
        index += 2

        opts, store_key, storedist = parse_radius_opts(argv, index)
        raise CommandError.syntax if !store && store_key
        if store_key && (opts[:with_coord] || opts[:with_dist] || opts[:with_hash])
          raise CommandError.syntax
        end

        results = search(client, key, lon, lat, shape, opts)
        if store_key
          store_results(client, store_key, results, storedist)
        else
          render(results, T.cast(opts[:with_coord], T::Boolean), T.cast(opts[:with_dist], T::Boolean), T.cast(opts[:with_hash], T::Boolean), multiplier)
        end
      end

      # Parse the GEORADIUS option tail:
      # [WITHCOORD] [WITHDIST] [WITHHASH] [COUNT n [ANY]] [ASC|DESC]
      # [STORE key] [STOREDIST key]. Returns [search_opts, store_key, storedist?].
      sig { params(argv: T::Array[String], index: Integer).returns([T::Hash[Symbol, T.untyped], T.nilable(String), T::Boolean]) }
      def self.parse_radius_opts(argv, index)
        opts = T.let({ asc: false, desc: false, count: nil, with_coord: false, with_dist: false, with_hash: false }, T::Hash[Symbol, T.untyped])
        store_key = T.let(nil, T.nilable(String))
        storedist = T.let(false, T::Boolean)
        while index < argv.length
          case T.must(argv[index]).downcase
          when "withcoord" then opts[:with_coord] = true; index += 1
          when "withdist" then opts[:with_dist] = true; index += 1
          when "withhash" then opts[:with_hash] = true; index += 1
          when "asc" then opts[:asc] = true; index += 1
          when "desc" then opts[:desc] = true; index += 1
          when "count"
            opts[:count] = Helpers.positive_int(T.must(argv[index + 1]))
            index += 2
            index += 1 if argv[index] && T.must(argv[index]).casecmp?("any")
          when "store"
            store_key = T.must(argv[index + 1])
            storedist = false
            index += 2
          when "storedist"
            store_key = T.must(argv[index + 1])
            storedist = true
            index += 2
          else raise CommandError.syntax
          end
        end
        [opts, store_key, storedist]
      end

      # --- install -----------------------------------------------------------

      sig { params(table: CommandTable).void }
      def self.install(table)
        table.add("geoadd", -5, [CommandFlag::Write]) { |c, a| geoadd(c, a) }
        table.add("geopos", -2, [CommandFlag::Readonly]) { |c, a| geopos(c, a) }
        table.add("geodist", -4, [CommandFlag::Readonly]) { |c, a| geodist(c, a) }
        table.add("geohash", -2, [CommandFlag::Readonly]) { |c, a| geohash(c, a) }
        table.add("geosearch", -7, [CommandFlag::Readonly]) { |c, a| geosearch(c, a) }
        table.add("geosearchstore", -8, [CommandFlag::Write]) { |c, a| geosearchstore(c, a) }
        table.add("georadius", -6, [CommandFlag::Write]) { |c, a| georadius(c, a) }
        table.add("georadius_ro", -6, [CommandFlag::Readonly]) { |c, a| georadius_ro(c, a) }
        table.add("georadiusbymember", -5, [CommandFlag::Write]) { |c, a| georadiusbymember(c, a) }
        table.add("georadiusbymember_ro", -5, [CommandFlag::Readonly]) { |c, a| georadiusbymember_ro(c, a) }
      end
    end
  end
end

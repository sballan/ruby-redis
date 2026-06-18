# typed: strict
# frozen_string_literal: true

module RedisRuby
  # Small collection of binary-safe parsing and formatting helpers that mirror
  # the semantics of Redis' string2ll / getDoubleFromObject / d2string and the
  # glob style pattern matcher used by KEYS, SCAN and pub/sub patterns.
  module Util
    extend T::Sig

    INT64_MIN = -9_223_372_036_854_775_808
    INT64_MAX = 9_223_372_036_854_775_807

    INTEGER_RE = /\A-?(?:0|[1-9][0-9]*)\z/

    # Parse a base-10 64-bit signed integer exactly the way Redis' string2ll
    # does: no surrounding whitespace, no leading zeros, must fit in an int64.
    sig { params(str: String).returns(Integer) }
    def self.string_to_int(str)
      raise CommandError.not_integer unless INTEGER_RE.match?(str)

      value = str.to_i
      raise CommandError.not_integer if value < INT64_MIN || value > INT64_MAX

      value
    end

    # Parse a floating point value, accepting the inf/-inf spellings Redis
    # tolerates. Raises a CommandError on anything strtod would reject.
    sig { params(str: String).returns(Float) }
    def self.string_to_float(str)
      case str.downcase
      when "inf", "+inf", "infinity", "+infinity" then return Float::INFINITY
      when "-inf", "-infinity" then return -Float::INFINITY
      when "nan", "-nan", "+nan" then raise CommandError.not_float
      end

      begin
        Float(str)
      rescue ArgumentError, TypeError
        raise CommandError.not_float
      end
    end

    # Format a double for replies the way Redis' addReplyHumanLongDouble /
    # d2string does: integral values print without a decimal point, infinities
    # print as inf/-inf, everything else uses the shortest round-trip form.
    sig { params(value: Float).returns(String) }
    def self.format_double(value)
      return "inf" if value.infinite? == 1
      return "-inf" if value.infinite? == -1
      return "nan" if value.nan?

      # Ruby's Float#to_s already gives the shortest round-trip form; Redis
      # additionally drops the trailing ".0" so integral scores print bare.
      string = value.to_s
      string.end_with?(".0") ? string.delete_suffix(".0") : string
    end

    # Current time in milliseconds since the Unix epoch.
    sig { returns(Integer) }
    def self.now_ms = Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond).to_i

    # Monotonic milliseconds, used for timeouts that must not jump when the
    # wall clock is adjusted.
    sig { returns(Float) }
    def self.mono_ms = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond).to_f

    # Glob-style pattern match, a direct port of Redis' stringmatchlen.
    # Supports *, ?, [...] classes (with ranges and ^ negation) and \ escaping.
    sig { params(pattern: String, string: String, nocase: T::Boolean).returns(T::Boolean) }
    def self.glob_match?(pattern, string, nocase: false)
      match_len(pattern, 0, pattern.bytesize, string, 0, string.bytesize, nocase)
    end

    sig do
      params(pat: String, pi: Integer, pe: Integer, str: String, si: Integer, se: Integer, nocase: T::Boolean)
        .returns(T::Boolean)
    end
    def self.match_len(pat, pi, pe, str, si, se, nocase)
      while pi < pe && si <= se
        case pat.getbyte(pi)
        when 42 # '*'
          pi += 1 while pi + 1 < pe && pat.getbyte(pi + 1) == 42
          return true if pi + 1 >= pe # trailing star matches the rest

          while si <= se
            return true if match_len(pat, pi + 1, pe, str, si, se, nocase)

            si += 1
          end
          return false
        when 63 # '?'
          return false if si >= se

          si += 1
        when 91 # '['
          return false if si >= se

          pi += 1
          negate = pi < pe && pat.getbyte(pi) == 94 # '^'
          pi += 1 if negate
          matched = T.let(false, T::Boolean)
          while pi < pe && pat.getbyte(pi) != 93 # ']'
            if pat.getbyte(pi) == 92 && pi + 1 < pe # '\' escape
              pi += 1
              matched = true if byte_eq(pat.getbyte(pi), str.getbyte(si), nocase)
            elsif pi + 2 < pe && pat.getbyte(pi + 1) == 45 # range 'a-z'
              lo = T.must(pat.getbyte(pi))
              hi = T.must(pat.getbyte(pi + 2))
              lo, hi = hi, lo if lo > hi
              c = T.must(str.getbyte(si))
              if nocase
                lo = downcase_byte(lo); hi = downcase_byte(hi); c = downcase_byte(c)
              end
              matched = true if c >= lo && c <= hi
              pi += 2
            elsif byte_eq(pat.getbyte(pi), str.getbyte(si), nocase)
              matched = true
            end
            pi += 1
          end
          matched = !matched if negate
          return false unless matched

          si += 1
        when 92 # '\' escape outside a class
          pi += 1 if pi + 1 < pe
          return false if si >= se || !byte_eq(pat.getbyte(pi), str.getbyte(si), nocase)

          si += 1
        else
          return false if si >= se || !byte_eq(pat.getbyte(pi), str.getbyte(si), nocase)

          si += 1
        end
        pi += 1
        # Collapse trailing stars when the string is exhausted.
        if si >= se
          pi += 1 while pi < pe && pat.getbyte(pi) == 42
          break
        end
      end

      pi >= pe && si >= se
    end

    sig { params(a: T.nilable(Integer), b: T.nilable(Integer), nocase: T::Boolean).returns(T::Boolean) }
    def self.byte_eq(a, b, nocase)
      return false if a.nil? || b.nil?
      return a == b unless nocase

      downcase_byte(a) == downcase_byte(b)
    end

    sig { params(byte: Integer).returns(Integer) }
    def self.downcase_byte(byte)
      byte >= 65 && byte <= 90 ? byte + 32 : byte
    end

    private_class_method :match_len, :byte_eq, :downcase_byte
  end
end

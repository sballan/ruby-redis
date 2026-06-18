# typed: strict
# frozen_string_literal: true

module RedisRuby
  # RESP (REdis Serialization Protocol) encoding and decoding.
  #
  # {encode} serializes reply values into a binary buffer, honoring the
  # client's negotiated protocol version (2 or 3). {Reader} is a streaming,
  # binary-safe request parser that accepts both the multibulk protocol used
  # by real clients and the inline protocol used by telnet/debugging.
  module Protocol
    extend T::Sig

    CRLF = T.let("\r\n".b.freeze, String)
    LF = T.let("\n".b.freeze, String)

    # Protocol safety limits, matching Redis defaults.
    MAX_MULTIBULK = T.let(1024 * 1024, Integer)
    MAX_BULK_LEN = T.let(512 * 1024 * 1024, Integer)
    MAX_INLINE = T.let(64 * 1024, Integer)

    # --- Encoding ----------------------------------------------------------

    sig { params(out: String, value: T.untyped, protocol: Integer).void }
    def self.encode(out, value, protocol)
      case value
      when nil
        out << (protocol >= 3 ? "_\r\n" : "$-1\r\n")
      when Reply::NullArray
        out << (protocol >= 3 ? "_\r\n" : "*-1\r\n")
      when Integer
        out << ":" << value.to_s << "\r\n"
      when String
        encode_bulk(out, value)
      when Array
        out << "*" << value.length.to_s << "\r\n"
        value.each { |element| encode(out, element, protocol) }
      when true
        out << (protocol >= 3 ? "#t\r\n" : ":1\r\n")
      when false
        out << (protocol >= 3 ? "#f\r\n" : ":0\r\n")
      when Reply::SimpleString
        out << "+" << value.string << "\r\n"
      when Reply::Error
        out << "-" << value.message << "\r\n"
      when Reply::Double
        encode_double(out, value.value, protocol)
      when Reply::Boolean
        out << (protocol >= 3 ? (value.value ? "#t\r\n" : "#f\r\n") : (value.value ? ":1\r\n" : ":0\r\n"))
      when Reply::BigNumber
        protocol >= 3 ? (out << "(" << value.digits << "\r\n") : encode_bulk(out, value.digits)
      when Reply::Verbatim
        encode_verbatim(out, value, protocol)
      when Reply::Map
        encode_map(out, value.pairs, protocol)
      when Reply::Set
        out << (protocol >= 3 ? "~" : "*") << value.elements.length.to_s << "\r\n"
        value.elements.each { |element| encode(out, element, protocol) }
      when Reply::Push
        out << (protocol >= 3 ? ">" : "*") << value.elements.length.to_s << "\r\n"
        value.elements.each { |element| encode(out, element, protocol) }
      else
        raise Error, "cannot encode reply of type #{value.class}"
      end
    end

    sig { params(out: String, str: String).void }
    def self.encode_bulk(out, str)
      out << "$" << str.bytesize.to_s << CRLF << str << CRLF
    end

    sig { params(out: String, value: Float, protocol: Integer).void }
    def self.encode_double(out, value, protocol)
      formatted = Util.format_double(value)
      protocol >= 3 ? (out << "," << formatted << "\r\n") : encode_bulk(out, formatted)
    end

    sig { params(out: String, verbatim: Reply::Verbatim, protocol: Integer).void }
    def self.encode_verbatim(out, verbatim, protocol)
      if protocol >= 3
        body = verbatim.string
        out << "=" << (body.bytesize + 4).to_s << CRLF << verbatim.format << ":" << body << CRLF
      else
        encode_bulk(out, verbatim.string)
      end
    end

    sig { params(out: String, pairs: T::Array[[T.untyped, T.untyped]], protocol: Integer).void }
    def self.encode_map(out, pairs, protocol)
      if protocol >= 3
        out << "%" << pairs.length.to_s << CRLF
      else
        out << "*" << (pairs.length * 2).to_s << CRLF
      end
      pairs.each do |key, value|
        encode(out, key, protocol)
        encode(out, value, protocol)
      end
    end

    # --- Decoding ----------------------------------------------------------

    # Streaming request reader. Feed it bytes with {#<<} and pull complete
    # commands with {#read_command}; the latter returns nil when more bytes
    # are needed and raises ProtocolError on malformed input.
    class Reader
      extend T::Sig

      sig { void }
      def initialize
        @buf = T.let(+"".b, String)
      end

      sig { params(data: String).returns(Reader) }
      def <<(data)
        @buf << data
        self
      end

      sig { returns(T::Boolean) }
      def empty? = @buf.empty?

      # Returns the next command as an array of binary strings, an empty array
      # if a no-op frame (e.g. *0) was consumed, or nil if more data is needed.
      sig { returns(T.nilable(T::Array[String])) }
      def read_command
        return nil if @buf.empty?

        if @buf.getbyte(0) == 42 # '*'
          read_multibulk
        else
          read_inline
        end
      end

      private

      sig { returns(T.nilable(T::Array[String])) }
      def read_multibulk
        pos = 0
        line_end = @buf.index(CRLF, pos)
        return nil unless line_end

        count = parse_length(T.must(@buf.byteslice(pos + 1, line_end - pos - 1)), "invalid multibulk length")
        raise ProtocolError, "ERR Protocol error: invalid multibulk length" if count > MAX_MULTIBULK

        pos = line_end + 2
        if count <= 0
          @buf = T.must(@buf.byteslice(pos, @buf.bytesize - pos))
          return []
        end

        argv = T.let([], T::Array[String])
        count.times do
          return nil if pos >= @buf.bytesize
          raise ProtocolError, "ERR Protocol error: expected '$', got '#{@buf.byteslice(pos, 1)}'" unless @buf.getbyte(pos) == 36 # '$'

          bulk_line_end = @buf.index(CRLF, pos)
          return nil unless bulk_line_end

          len = parse_length(T.must(@buf.byteslice(pos + 1, bulk_line_end - pos - 1)), "invalid bulk length")
          raise ProtocolError, "ERR Protocol error: invalid bulk length" if len < 0 || len > MAX_BULK_LEN

          data_start = bulk_line_end + 2
          return nil if @buf.bytesize < data_start + len + 2

          argv << T.must(@buf.byteslice(data_start, len))
          pos = data_start + len + 2
        end

        @buf = T.must(@buf.byteslice(pos, @buf.bytesize - pos))
        argv
      end

      sig { returns(T.nilable(T::Array[String])) }
      def read_inline
        nl = @buf.index(LF, 0)
        unless nl
          raise ProtocolError, "ERR Protocol error: too big inline request" if @buf.bytesize > MAX_INLINE

          return nil
        end

        line = T.must(@buf.byteslice(0, nl))
        line = T.must(line.byteslice(0, line.bytesize - 1)) if line.end_with?("\r")
        @buf = T.must(@buf.byteslice(nl + 1, @buf.bytesize - nl - 1))

        args = split_inline(line)
        raise ProtocolError, "ERR Protocol error: unbalanced quotes in request" if args.nil?

        args
      end

      sig { params(str: String, what: String).returns(Integer) }
      def parse_length(str, what)
        Integer(str, 10)
      rescue ArgumentError, TypeError
        raise ProtocolError, "ERR Protocol error: #{what}"
      end

      # Port of Redis' sdssplitargs: whitespace separated tokens with single
      # and double quoting plus the usual escape sequences. Returns nil on an
      # unbalanced quote.
      sig { params(line: String).returns(T.nilable(T::Array[String])) }
      def split_inline(line)
        args = T.let([], T::Array[String])
        i = 0
        len = line.bytesize

        while i < len
          i += 1 while i < len && space?(T.must(line.getbyte(i)))
          break if i >= len

          current = +"".b
          in_quote = T.let(false, T::Boolean)
          in_single = T.let(false, T::Boolean)

          loop do
            if in_quote
              return nil if i >= len

              byte = T.must(line.getbyte(i))
              if byte == 92 && i + 1 < len # backslash escape
                i += 1
                current << unescape(line, i)
                i += 1
                i += 2 if hex_escape?(line, i - 1)
              elsif byte == 34 # closing double quote
                return nil if i + 1 < len && !space?(T.must(line.getbyte(i + 1)))

                i += 1
                break
              else
                current << byte
                i += 1
              end
            elsif in_single
              return nil if i >= len

              byte = T.must(line.getbyte(i))
              if byte == 92 && i + 1 < len && line.getbyte(i + 1) == 39 # \'
                current << 39
                i += 2
              elsif byte == 39 # closing single quote
                return nil if i + 1 < len && !space?(T.must(line.getbyte(i + 1)))

                i += 1
                break
              else
                current << byte
                i += 1
              end
            else
              break if i >= len

              byte = T.must(line.getbyte(i))
              case byte
              when 34 then in_quote = true; i += 1
              when 39 then in_single = true; i += 1
              when 32, 9, 10, 13, 11, 12 then break
              else current << byte; i += 1
              end
            end
          end

          args << current
        end

        args
      end

      sig { params(line: String, i: Integer).returns(Integer) }
      def unescape(line, i)
        byte = T.must(line.getbyte(i))
        case byte
        when 110 then 10 # \n
        when 114 then 13 # \r
        when 116 then 9  # \t
        when 98 then 8   # \b
        when 97 then 7   # \a
        when 120 # \xHH
          high = hex_value(line.getbyte(i + 1))
          low = hex_value(line.getbyte(i + 2))
          high && low ? (high * 16) + low : byte
        else byte
        end
      end

      sig { params(line: String, i: Integer).returns(T::Boolean) }
      def hex_escape?(line, i)
        line.getbyte(i) == 120 && !hex_value(line.getbyte(i + 1)).nil? && !hex_value(line.getbyte(i + 2)).nil?
      end

      sig { params(byte: T.nilable(Integer)).returns(T.nilable(Integer)) }
      def hex_value(byte)
        return nil if byte.nil?
        return byte - 48 if byte >= 48 && byte <= 57 # 0-9
        return byte - 87 if byte >= 97 && byte <= 102 # a-f
        return byte - 55 if byte >= 65 && byte <= 70 # A-F

        nil
      end

      sig { params(byte: Integer).returns(T::Boolean) }
      def space?(byte) = [32, 9, 10, 13, 11, 12].include?(byte)
    end
  end
end

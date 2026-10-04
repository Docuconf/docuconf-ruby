# frozen_string_literal: true

module Docuconf
  module Anyway
    # SPEC §4.3: patterns are RE2 and match anywhere in the value. Ruby's
    # Onigmo dialect differs in ways that change results, so a pattern is
    # checked for RE2-only syntax and translated before it is compiled:
    #
    # - lookaround, backreferences, atomic groups, possessive quantifiers and
    #   other non-RE2 constructs are rejected;
    # - `^` and `$` mean start and end of *text* in RE2 (unless the m flag is
    #   set) but start and end of *line* in Ruby, so they become \A and \z;
    # - RE2's s flag is Ruby's m flag; (?P<name>...) becomes (?<name>...);
    # - \Q...\E and \x{...} are translated; `[` and `&&` inside a character
    #   class are literal in RE2 and escaped for Ruby.
    module RE2
      class Unsupported < StandardError; end

      REJECT_ESCAPES = {
        "k" => "named backreference \\k", "g" => "subroutine call \\g", "G" => "\\G",
        "Z" => "\\Z (use \\z or $)", "R" => "\\R", "X" => "\\X", "K" => "\\K",
        "h" => "\\h (not hex digits in RE2)", "H" => "\\H", "C" => "\\C"
      }.freeze

      module_function

      # Returns a Ruby Regexp equivalent to the RE2 pattern, or raises
      # Unsupported naming the first feature RE2 lacks.
      def compile(pattern)
        Regexp.new(translate(pattern))
      rescue RegexpError => e
        raise Unsupported, "invalid pattern: #{e.message}"
      end

      # Returns nil if the pattern is valid RE2 we can match exactly, or a
      # description of the problem.
      def problem(pattern)
        compile(pattern)
        nil
      rescue Unsupported => e
        e.message
      end

      def translate(pattern)
        out = +""
        i = 0
        n = pattern.length
        multiline = [false] # flag stack, one entry per open group
        after_quantifier = false
        while i < n
          c = pattern[i]
          quantifier = false
          case c
          when "\\"
            i, piece = escape(pattern, i)
            out << piece
          when "["
            i, piece = char_class(pattern, i)
            out << piece
          when "("
            i, piece, state = group(pattern, i, multiline.last)
            out << piece
            case state
            when :set then multiline[-1] = true
            when :unset then multiline[-1] = false
            else multiline.push(state)
            end
          when ")"
            multiline.pop if multiline.size > 1
            out << ")"
            i += 1
          when "^"
            out << (multiline.last ? "^" : "\\A")
            i += 1
          when "$"
            out << (multiline.last ? "$" : "\\z")
            i += 1
          when "*", "+", "?"
            # A `+` after a quantifier is possessive in Ruby and an error in
            # RE2. (`?` after a quantifier is the lazy modifier, valid in both.)
            raise Unsupported, "possessive quantifier (#{pattern[i - 1]}+)" if c == "+" && after_quantifier

            out << c
            quantifier = true
            i += 1
          when "{"
            if (m = /\A\{([0-9]+)(,([0-9]*))?\}/.match(pattern[i..]))
              out << m[0]
              quantifier = true
              i += m[0].length
            else
              out << "\\{"
              i += 1
            end
          when "}"
            out << "\\}"
            i += 1
          else
            out << c
            i += 1
          end
          after_quantifier = quantifier
        end
        out
      end

      def escape(pattern, i)
        nxt = pattern[i + 1]
        raise Unsupported, "trailing backslash" if nxt.nil?
        raise Unsupported, "backreference \\#{nxt}" if nxt.match?(/[1-9]/)
        raise Unsupported, REJECT_ESCAPES[nxt] if REJECT_ESCAPES.key?(nxt)

        case nxt
        when "Q"
          stop = pattern.index("\\E", i + 2)
          literal = stop ? pattern[(i + 2)...stop] : pattern[(i + 2)..]
          [stop ? stop + 2 : pattern.length, Regexp.escape(literal)]
        when "x"
          if pattern[i + 2] == "{"
            stop = pattern.index("}", i + 3) or raise Unsupported, "unterminated \\x{"
            [stop + 1, "\\u{#{pattern[(i + 3)...stop]}}"]
          else
            [i + 4, pattern[i, 4]]
          end
        when "p", "P"
          if pattern[i + 2] == "{"
            stop = pattern.index("}", i + 3) or raise Unsupported, "unterminated \\p{"
            [stop + 1, pattern[i..stop]]
          else
            [i + 3, "\\#{nxt}{#{pattern[i + 2]}}"]
          end
        else
          [i + 2, pattern[i, 2]]
        end
      end

      def char_class(pattern, i)
        out = +"["
        j = i + 1
        if pattern[j] == "^"
          out << "^"
          j += 1
        end
        if pattern[j] == "]"
          out << "\\]"
          j += 1
        end
        loop do
          c = pattern[j]
          raise Unsupported, "unterminated character class" if c.nil?

          if c == "]"
            out << "]"
            return [j + 1, out]
          elsif c == "\\"
            j, piece = escape(pattern, j)
            out << piece
          elsif c == "[" && pattern[j + 1] == ":"
            stop = pattern.index(":]", j + 2) or raise Unsupported, "unterminated [: class"
            out << pattern[j..(stop + 1)]
            j = stop + 2
          elsif c == "["
            out << "\\["
            j += 1
          elsif c == "&" && pattern[j + 1] == "&"
            out << "\\&\\&"
            j += 2
          else
            out << c
            j += 1
          end
        end
      end

      # Returns [next index, translated text, multiline flag]. The flag is
      # the multiline state of a new group, :set/:unset for a bare flag group
      # that changes the enclosing group's state.
      def group(pattern, i, current)
        return [i + 1, "(", current] unless pattern[i + 1] == "?"

        rest = pattern[(i + 2)..] || ""
        case rest
        when /\A=/ then raise Unsupported, "lookahead (?=...)"
        when /\A!/ then raise Unsupported, "negative lookahead (?!...)"
        when /\A<=/ then raise Unsupported, "lookbehind (?<=...)"
        when /\A<!/ then raise Unsupported, "negative lookbehind (?<!...)"
        when /\A>/ then raise Unsupported, "atomic group (?>...)"
        when /\A~/ then raise Unsupported, "absence operator (?~...)"
        when /\A#/ then raise Unsupported, "comment group (?#...)"
        when /\AP=/ then raise Unsupported, "named backreference (?P=...)"
        when /\AP<([A-Za-z_][A-Za-z0-9_]*)>/, /\A<([A-Za-z_][A-Za-z0-9_]*)>/
          len = Regexp.last_match(0).length
          [i + 2 + len, "(?<#{Regexp.last_match(1)}>", current]
        when /\A:/
          [i + 3, "(?:", current]
        when /\A([imsU]*)(?:-([imsU]*))?([:)])/
          on = Regexp.last_match(1)
          off = Regexp.last_match(2) || ""
          term = Regexp.last_match(3)
          raise Unsupported, "ungreedy flag U" if (on + off).include?("U")

          ruby_on = on.tr("m", "").tr("s", "m")
          ruby_off = off.tr("m", "").tr("s", "m")
          flags = ruby_on + (ruby_off.empty? ? "" : "-#{ruby_off}")
          ml = if on.include?("m") then true
               elsif off.include?("m") then false
               else current
               end
          len = Regexp.last_match(0).length
          if term == ")"
            piece = flags.empty? || flags == "-" ? "" : "(?#{flags})"
            # A bare flag group opens no group: it changes the enclosing one.
            [i + 2 + len, piece, ml ? :set : :unset]
          else
            [i + 2 + len, flags.empty? ? "(?:" : "(?#{flags}:", ml]
          end
        else
          raise Unsupported, "unsupported group syntax (?#{rest[0]}"
        end
      end
    end
  end
end

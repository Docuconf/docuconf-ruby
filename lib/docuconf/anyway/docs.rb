# frozen_string_literal: true

module Docuconf
  module Anyway
    # Where an input's `details` come from (SPEC §4.2, §14.7): the
    # `details:` option of `describe` (or of a file macro), or else the YARD
    # comment written directly above the call:
    #
    #   # Behind the mesh, keep the default.
    #   #
    #   # Raise it only with {Ingress#port}.
    #   describe :port, "HTTP listen port", min: 1, max: 65_535
    #
    # The description is always `describe`'s. YARD and RDoc markup in the
    # comment become CommonMark: `{Foo#bar}` links and `+code+` become code
    # spans, `@example` blocks fenced code, `@note` and `@see` sentences, and
    # every other tag (`@param`, `@return`...) is dropped.
    module Docs
      # The most characters (Unicode code points) details may have.
      MAX_DETAILS = 4000

      LIB_DIR = File.expand_path("..", __dir__)
      private_constant :LIB_DIR

      @lines = {}
      @mutex = Mutex.new

      class << self
        # The file and line of the app's call to a docuconf macro, skipping
        # docuconf's own frames.
        def call_site
          loc = caller_locations(1).find { |l| !l.absolute_path.to_s.start_with?(LIB_DIR) }
          loc && loc.absolute_path && [loc.absolute_path, loc.lineno]
        end

        # The details for a declaration: the explicit option, or else the
        # comment above `site`, converted to Markdown. nil when there are none.
        def details(explicit, site)
          return explicit.to_s unless explicit.nil?
          return nil unless site

          md = to_markdown(comment_above(*site))
          md.empty? ? nil : md
        end

        # The `#` comment lines directly above line `lineno` of `path`, with
        # the `#` and one space removed. Magic comments and directives
        # (frozen_string_literal, rubocop:) are not documentation.
        def comment_above(path, lineno)
          lines = source_lines(path)
          return "" if lines.nil? || lineno < 2

          out = []
          i = lineno - 2
          while i >= 0 && (m = lines[i].match(/\A\s*#(?!\{)( ?)(.*)\z/))
            break if m[2].match?(/\A\s*(?:frozen_string_literal|encoding|rubocop:|-\*-|typed:)/)

            out.unshift(m[2].rstrip)
            i -= 1
          end
          out.join("\n").strip
        end

        # Converts a YARD/RDoc comment to CommonMark.
        def to_markdown(text)
          lines = text.to_s.lines.map(&:chomp)
          out = []
          i = 0
          fence = false
          while i < lines.size
            line = lines[i]
            if line.lstrip.start_with?("```")
              fence = !fence
              out << line
              i += 1
              next
            end
            if fence
              out << line
              i += 1
              next
            end
            if (m = line.match(/\A@(\w+)(?:\s+(.*))?\z/))
              i += 1
              rest = []
              while i < lines.size && (lines[i].start_with?(" ", "\t") || (lines[i].empty? && m[1] == "example" &&
                  lines[i + 1].to_s.start_with?(" ", "\t")))
                rest << lines[i]
                i += 1
              end
              out.concat(tag(m[1], m[2].to_s.strip, rest))
              next
            end
            if (m = line.match(/\A(=+)\s+(\S.*)\z/))
              out << "#{"#" * [m[1].size, 6].min} #{inline(m[2])}"
            else
              out << inline(line)
            end
            i += 1
          end
          out.join("\n").gsub(/\n{3,}/, "\n\n").strip
        end

        # Reports blank or too-long details (SPEC §4.2).
        def check(label, details, problems)
          return if details.nil?

          if details.strip.empty?
            problems << "#{label}: details must not be blank"
          elsif details.length > MAX_DETAILS
            problems << "#{label}: details are #{details.length} characters; at most #{MAX_DETAILS} are allowed"
          end
        end

        private

        def source_lines(path)
          @mutex.synchronize do
            return @lines[path] if @lines.key?(path)

            @lines[path] = begin
              File.readlines(path, chomp: true, encoding: "UTF-8")
            rescue SystemCallError, IOError
              nil
            end
          end
        end

        def tag(name, text, rest)
          body = rest.map { |l| l.sub(/\A\s+/, "") }
          case name
          when "note"
            ["", "**Note:** #{inline([text, *body].join(" ").strip)}", ""]
          when "deprecated"
            ["", "**Deprecated:** #{inline([text, *body].join(" ").strip)}", ""]
          when "see"
            target, title = text.split(/\s+/, 2)
            ref = target.to_s.match?(%r{\Ahttps?://}) ? "<#{target}>" : code(target.to_s.delete("{}"))
            ["", "See #{ref}#{" (#{inline(title)})" if title}.", ""]
          when "example"
            code_lines = rest
            indent = code_lines.reject(&:empty?).map { |l| l[/\A\s*/].size }.min || 0
            block = ["```ruby", *code_lines.map { |l| l[indent..].to_s }, "```"]
            text.empty? ? ["", *block, ""] : ["", "#{inline(text)}:", "", *block, ""]
          else
            [] # @param, @return, @api, @since, @!attribute...: API docs, not configuration docs
          end
        end

        # Converts YARD links and RDoc +code+ outside existing code spans.
        def inline(s)
          s.split(/(`[^`]*`)/).each_with_index.map { |part, i| i.odd? ? part : inline_part(part) }.join
        end

        def inline_part(s)
          s.gsub(/\{(\S+?)(?:\s+([^}]+))?\}/) do
            target, title = Regexp.last_match(1), Regexp.last_match(2)
            if target.match?(%r{\Ahttps?://})
              title ? "[#{title}](#{target})" : "<#{target}>"
            else
              code(title || target)
            end
          end.gsub(/(?<![\w+`])\+([\w.:#\/=-]+)\+(?![\w+`])/) { code(Regexp.last_match(1)) }
        end

        def code(s) = "`#{s}`"
      end
    end
  end
end

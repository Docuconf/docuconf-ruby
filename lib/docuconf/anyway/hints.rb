# frozen_string_literal: true

module Docuconf
  module Anyway
    # Warns about environment variables that look like a typo of a declared
    # one (DATABSE_URL for DATABASE_URL): a warning, never a violation, and
    # never with the value.
    module Hints
      # Variables every container or shell has; never typo candidates.
      SYSTEM = %w[
        HOME HOSTNAME PATH PWD OLDPWD USER LOGNAME SHELL LANG LANGUAGE TERM TZ TMPDIR SHLVL HOST
        RAILS_ENV RACK_ENV APP_ENV
      ].freeze

      module_function

      def warn_typos(klass, env)
        typos(klass, env).each do |set, declared|
          Docuconf::Anyway.warn("#{set} is set but not declared; did you mean #{declared}?")
        end
      end

      # [[set name, declared name], ...] for the class's variables.
      def typos(klass, env)
        decl = klass.docuconf_declaration
        names = decl.vars.map(&:name)
        return [] if names.empty?

        known = known_names
        prefix = klass.env_prefix.to_s
        prefix = prefix.empty? ? "" : "#{prefix}_"
        out = []
        env.each_key do |key|
          key = key.to_s
          next if known.include?(key) || SYSTEM.include?(key) || key.start_with?("DOCUCONF_")
          next unless key.start_with?(prefix)

          tail = key.delete_prefix(prefix)
          next if tail.length < 3

          best = nil
          names.each do |n|
            ntail = n.delete_prefix(prefix)
            max = [ntail.length, tail.length].min >= 8 ? 2 : 1
            next if (ntail.length - tail.length).abs > max

            d = distance(tail, ntail, max)
            best = [d, n] if d <= max && (best.nil? || d < best[0])
          end
          out << [key, best[1]] if best
        end
        out.sort
      end

      # Every name a loaded docuconf class declares (variables, path_env and
      # keystore password variables), so one class's variable is not a typo
      # for another's.
      def known_names
        out = Set.new
        Docuconf::Anyway.configs.each do |k|
          decl = k.instance_variable_get(:@docuconf_declaration)
          next unless decl

          decl.vars.each { |v| out << v.name }
          decl.files.each do |f|
            out << f.path_env if f.path_env
            out << f[:password_var].to_s if f[:password_var].is_a?(String)
          end
        end
        out
      end

      # Edit distance counting a swap of two adjacent letters as one edit
      # (optimal string alignment), giving up above max.
      def distance(a, b, max)
        a = a.chars
        b = b.chars
        rows = [(0..b.length).to_a]
        (1..a.length).each do |i|
          row = [i]
          (1..b.length).each do |j|
            cost = a[i - 1] == b[j - 1] ? 0 : 1
            d = [rows[i - 1][j] + 1, row[j - 1] + 1, rows[i - 1][j - 1] + cost].min
            d = [d, rows[i - 2][j - 2] + 1].min if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1]
            row << d
          end
          return max + 1 if row.min > max

          rows << row
        end
        rows.last.last
      end
    end
  end
end

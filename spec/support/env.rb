# frozen_string_literal: true

module EnvHelper
  # Runs the block with exactly these variables set (nil deletes one), then
  # restores ENV and anyway_config's env cache.
  def with_env(vars)
    saved = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    Anyway.env.clear
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    Anyway.env.clear
  end

  # Clears every variable with the prefix for the duration of the block.
  def without_prefix(prefix, &block)
    with_env(ENV.keys.select { |k| k.start_with?(prefix) }.to_h { |k| [k, nil] }, &block)
  end

  def write_file(root, path, content, mode: nil)
    full = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.binwrite(full, content)
    File.chmod(mode, full) if mode
    full
  end

  def codes(error)
    error.violations.map { |v| [v.input, v.code] }
  end
end

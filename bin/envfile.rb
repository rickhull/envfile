#!/usr/bin/env ruby

module EnvFile
  ERROR_NO_EQUALS                = "ERROR_NO_EQUALS"
  ERROR_EMPTY_KEY                = "ERROR_EMPTY_KEY"
  ERROR_KEY_LEADING_WHITESPACE   = "ERROR_KEY_LEADING_WHITESPACE"
  ERROR_KEY_TRAILING_WHITESPACE  = "ERROR_KEY_TRAILING_WHITESPACE"
  ERROR_VALUE_LEADING_WHITESPACE = "ERROR_VALUE_LEADING_WHITESPACE"
  ERROR_KEY_INVALID              = "ERROR_KEY_INVALID"
  ERROR_DOUBLE_QUOTE_UNTERMINATED = "ERROR_DOUBLE_QUOTE_UNTERMINATED"
  ERROR_SINGLE_QUOTE_UNTERMINATED = "ERROR_SINGLE_QUOTE_UNTERMINATED"
  ERROR_TRAILING_CONTENT         = "ERROR_TRAILING_CONTENT"
  ERROR_VALUE_INVALID_CHAR       = "ERROR_VALUE_INVALID_CHAR"

  FORMAT = ENV.fetch("ENVFILE_FORMAT", "shell")
  ACTION = ENV.fetch("ENVFILE_ACTION", "validate")

  NL    = "\n".b.freeze
  EQ    = "=".b.freeze
  HASH  = "#".b.freeze
  UNDER = "_".b.freeze

  NATIVE_KEY_RE = /\A[A-Z_][A-Z0-9_]*\z/n

  def self.valid_native_key?(key)
    return false if key.empty?
    b = key.getbyte(0)
    return false unless (65 <= b && b <= 90) || b == 95
    key.each_byte.all? { |c| (65 <= c && c <= 90) || (48 <= c && c <= 57) || c == 95 }
  end

  # Returns [checked, errors] and writes norm/diag as raw bytes.
  def self.native_scan(buf, tag, norm, diag, normalize:)
    checked = errors = 0
    n = 0
    start = 0

    buf.each_byte.with_index do |byte, i|
      next unless byte == 10  # \n
      n += 1
      line = buf.byteslice(start, i - start)
      start = i + 1

      if line.include?("\0")
        diag << "#{ERROR_VALUE_INVALID_CHAR}: #{tag}:#{n}\n"
        checked += 1
        errors += 1
        next
      end
      next if line.nil? || line.strip.empty?
      next if line.getbyte(0) == 35  # #
      checked += 1

      eq = line.index(EQ)
      unless eq
        diag << "#{ERROR_NO_EQUALS}: #{tag}:#{n}\n"
        errors += 1
        next
      end

      k = line.byteslice(0, eq)
      v = line.byteslice(eq + 1, line.bytesize - eq - 1)

      if k.empty?
        diag << "#{ERROR_EMPTY_KEY}: #{tag}:#{n}\n"
        errors += 1
        next
      end
      unless valid_native_key?(k)
        diag << "#{ERROR_KEY_INVALID}: #{tag}:#{n}\n"
        errors += 1
        next
      end

      norm << k << EQ << v << NL if normalize
    end

    # handle final line with no trailing newline
    if start < buf.bytesize
      n += 1
      line = buf.byteslice(start, buf.bytesize - start)
      if line.include?("\0")
        diag << "#{ERROR_VALUE_INVALID_CHAR}: #{tag}:#{n}\n"
        checked += 1
        errors += 1
        return [checked, errors]
      end
      unless line.nil? || line.strip.empty? || line.getbyte(0) == 35
        checked += 1
        eq = line.index(EQ)
        unless eq
          diag << "#{ERROR_NO_EQUALS}: #{tag}:#{n}\n"
          errors += 1
          return [checked, errors]
        end
        k = line.byteslice(0, eq)
        v = line.byteslice(eq + 1, line.bytesize - eq - 1)
        if k.empty?
          diag << "#{ERROR_EMPTY_KEY}: #{tag}:#{n}\n"
          errors += 1
        elsif !valid_native_key?(k)
          diag << "#{ERROR_KEY_INVALID}: #{tag}:#{n}\n"
          errors += 1
        else
          norm << k << EQ << v << NL if normalize
        end
      end
    end

    [checked, errors]
  end

  def self.lint_native(files)
    normalize = ACTION == "normalize"
    norm = "".b
    diag = "".b
    total_checked = total_errors = 0

    files.each do |f|
      buf = f == "-" ? $stdin.binmode.read : File.binread(f)
      checked, errors = native_scan(buf, f, norm, diag, normalize:)
      total_checked += checked
      total_errors  += errors
    end

    diag << "#{total_checked} checked, #{total_errors} errors\n"
    $stdout.binmode.write(norm) unless norm.empty?
    $stderr.binmode.write(diag)
    total_errors
  end

  def self.lint_shell(files, out: $stderr)
    files = ["-"] if files.empty?
    totals = Hash.new 0

    files.each do |f|
      r = ShellResult.new(f, out:).lint
      totals[:checked]  += r.checked
      totals[:errors]   += r.errors
    end
    out.puts format("%i checked, %i errors",
                    totals[:checked], totals[:errors])
    totals
  end

  def self.lint(files, out: $stderr)
    if FORMAT == "native"
      lint_native(files)
    else
      lint_shell(files, out:)
    end
  end

  class ShellResult
    attr_reader :path, :io, :checked, :errors

    def initialize path, out: $stderr
      @path = path
      @io = out
      @checked = 0
      @errors = 0
    end

    def lint
      each_line do |line, n|
        if line.include?("\0")
          error ERROR_VALUE_INVALID_CHAR, n
          @checked += 1
          next
        end
        next if line.strip.empty?
        next if line.start_with? "#"
        @checked += 1
        shell_line(line, n)
      end
      self
    end

    def each_line
      n = 0
      if @path == "-"
        $stdin.each_line(chomp: true) { |line| yield line.chomp("\r"), (n += 1) }
      else
        File.foreach(@path, chomp: true) { |line| yield line.chomp("\r"), (n += 1) }
      end
    end

    def shell_line line, n
      unless line.include? "="
        error ERROR_NO_EQUALS, n
        return
      end

      k, v = line.split("=", 2)

      if k.start_with? /\s/
        error ERROR_KEY_LEADING_WHITESPACE, n
        return
      end
      if k.end_with?(" ") || k.end_with?("\t")
        error ERROR_KEY_TRAILING_WHITESPACE, n
        return
      end
      if !v.empty? && (v.start_with?(" ") || v.start_with?("\t"))
        error ERROR_VALUE_LEADING_WHITESPACE, n
        return
      end
      if k.empty?
        error ERROR_EMPTY_KEY, n
        return
      end
      unless k.match? /\A[A-Za-z_][A-Za-z0-9_]*\z/
        error ERROR_KEY_INVALID, n
        return
      end

      return if v.empty?

      lead_char = v[0]
      if lead_char == '"'
        rest = v[1..]
        unless (pos = rest&.index('"'))
          error ERROR_DOUBLE_QUOTE_UNTERMINATED, n
          return
        end
        unless (rest[pos + 1..] || "").empty?
          error ERROR_TRAILING_CONTENT, n
          return
        end
      elsif lead_char == "'"
        rest = v[1..]
        unless (pos = rest&.index("'"))
          error ERROR_SINGLE_QUOTE_UNTERMINATED, n
          return
        end
        unless (rest[pos + 1..] || "").empty?
          error ERROR_TRAILING_CONTENT, n
          return
        end
      else
        if v.match? /[\s'"\\]/
          error ERROR_VALUE_INVALID_CHAR, n
          return
        end
      end
    end

    def error msg, n
      @errors += 1
      @io.puts "#{msg}: #{@path}:#{n}"
    end

  end
end

result = EnvFile.lint(ARGV.empty? ? ["-"] : ARGV)
exit 1 if (result.is_a?(Integer) ? result : result[:errors]) > 0

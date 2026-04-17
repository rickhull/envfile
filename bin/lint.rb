#!/usr/bin/env ruby

module EnvFile
  ERROR_NO_EQUALS                = "missing assignment (=)"
  ERROR_KEY_LEADING_WHITESPACE   = "leading whitespace before key"
  ERROR_KEY_TRAILING_WHITESPACE  = "whitespace before ="
  ERROR_VALUE_LEADING_WHITESPACE = "whitespace after ="
  ERROR_KEY_INVALID              = "invalid key"
  ERROR_DOUBLE_QUOTE_UNTERMINATED = "unterminated double quote"
  ERROR_SINGLE_QUOTE_UNTERMINATED = "unterminated single quote"
  ERROR_TRAILING_CONTENT         = "trailing content after closing quote"
  ERROR_VALUE_INVALID_CHAR       = "value contains whitespace, quote, or backslash"
  WARN_KEY_NOT_UPPERCASE         = "is not UPPERCASE (preferred)"

  def self.lint *files, out: $stderr
    totals = Hash.new 0

    files.each do |f|
      r = Result.new(f, out:).lint
      totals[:checked] += r.checked
      totals[:errors] += r.errors
      totals[:warnings] += r.warnings
    end
    out.puts format("%i checked, %i errors, %i warnings",
                    totals[:checked], totals[:errors], totals[:warnings])
    totals
  end

  class Result
    attr_reader :path, :io, :checked, :errors, :warnings

    def initialize path, out: $stderr
      @path = path
      @io = out
      @checked = 0
      @errors = 0
      @warnings = 0
    end

    def lint
      @cursor = 0
      File.foreach(@path, chomp: true) { |line|
        @cursor += 1
        next if line.strip.empty?
        next if line.start_with? "#"
        @checked += 1

        unless line.include? "="
          error ERROR_NO_EQUALS
          next
        end

        k, v = line.split("=", 2)

        if k.start_with? /\s/
          error ERROR_KEY_LEADING_WHITESPACE
          next
        end

        if (k.end_with? " ") or (k.end_with? "\t")
          error ERROR_KEY_TRAILING_WHITESPACE
          next
        end

        if !v.empty? and (v.start_with? " ") or (v.start_with? "\t")
          error ERROR_VALUE_LEADING_WHITESPACE
          next
        end

        unless k.match? /\A[A-Za-z_][A-Za-z0-9_]*\z/
          error "#{ERROR_KEY_INVALID} '#{k}'"
          next
        end

        warning "key '#{k}' #{WARN_KEY_NOT_UPPERCASE}" unless k == k.upcase

        next if v.empty?

        lead_char = v[0]

        if lead_char == '"'
          rest = v[1..]
          unless (pos = rest&.index '"')
            error ERROR_DOUBLE_QUOTE_UNTERMINATED
            next
          end
          unless (rest[pos + 1..] || "").empty?
            error ERROR_TRAILING_CONTENT
            next
          end
        elsif lead_char == "'"
          rest = v[1..]
          unless (pos = rest&.index "'")
            error ERROR_SINGLE_QUOTE_UNTERMINATED
            next
          end
          unless (rest[pos + 1..] || "").empty?
            error ERROR_TRAILING_CONTENT
            next
          end
        else
          if v.match? /[\s'"\\]/
            error ERROR_VALUE_INVALID_CHAR
            next
          end
        end
      }
      self
    end

    def error msg
      @errors += 1
      @io.puts format("ERROR: (%s:%i) %s", @path, @cursor, msg)
      #@io.puts format("%s:%i: %s", @path, @cursor, msg)
    end

    def warning msg
      @warnings += 1
      @io.puts format("WARNING: (%s:%i) %s", @path, @cursor, msg)
      #@io.puts format("%s:%i: %s", @path, @cursor, msg)
    end
  end
end

totals = EnvFile.lint(*ARGV)

exit 1 if totals[:errors] > 0

#!/usr/bin/env ruby

format = ENV.fetch("ENVFILE_FORMAT", "shell")
action = ENV.fetch("ENVFILE_ACTION", "validate")
bom = ENV["ENVFILE_BOM"] || (format == "native" ? "literal" : "strip")
crlf = ENV.fetch("ENVFILE_CRLF", "ignore")
nul = ENV.fetch("ENVFILE_NUL", "reject")
cont = ENV.fetch("ENVFILE_BACKSLASH_CONTINUATION", "ignore")

def fatal(code, detail)
  warn "#{code}: #{detail}"
  exit 1
end

fatal("FATAL_ERROR_BAD_ENVFILE_VALUE", "ENVFILE_BOM=#{bom}") unless %w[literal strip reject].include?(bom)
fatal("FATAL_ERROR_UNSUPPORTED", "format=native ENVFILE_BOM=#{bom}") if format == "native" && bom != "literal"

$checked = 0
$errors = 0
$env_map = {}

def diag(path, line, code)
  warn "#{code}: #{path}:#{line}"
  $errors += 1
end

def fdiag(path, code)
  warn "#{code}: #{path}"
  $errors += 1
end

def split_lines(buf)
  lines = buf.split("\n", -1)
  lines.pop if lines.last == ""
  lines
end

def continuation?(line)
  n = 0
  i = line.bytesize - 1
  while i >= 0 && line.getbyte(i) == 92
    n += 1
    i -= 1
  end
  (n % 2) == 1
end

def valid_shell_key?(k)
  !!(k =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/)
end

def unquote_shell_value(path, lineno, v)
  return v if v.empty?
  c = v[0]
  if c == '"' || c == "'"
    rest = v[1..]
    pos = rest.index(c)
    unless pos
      diag(path, lineno, c == '"' ? "LINE_ERROR_DOUBLE_QUOTE_UNTERMINATED" : "LINE_ERROR_SINGLE_QUOTE_UNTERMINATED")
      return nil
    end
    unless (rest[(pos + 1)..] || "").empty?
      diag(path, lineno, "LINE_ERROR_TRAILING_CONTENT")
      return nil
    end
    return rest[0...pos]
  end
  if v.match?(/[ \t'"\\]/)
    diag(path, lineno, "LINE_ERROR_VALUE_INVALID_CHAR")
    return nil
  end
  v
end

def seed_env_map
  ENV.each do |k, v|
    next if k.start_with?("ENVFILE_")
    $env_map[k] = v
  end
end

def subst_value(path, lineno, value)
  out = +""
  i = 0
  while i < value.bytesize
    pos = value.index("$", i)
    unless pos
      out << value[i..]
      break
    end
    out << value[i...pos]
    if pos + 1 >= value.bytesize
      out << "$"
      break
    end
    rest = value[(pos + 1)..]
    name = nil
    if rest.start_with?("{")
      close = rest.index("}", 1)
      unless close
        out << "$" << rest
        break
      end
      name = rest[1...close]
      i = pos + 1 + close + 1
    else
      m = rest.match(/\A([A-Za-z_][A-Za-z0-9_]*)/)
      unless m
        out << "$"
        i = pos + 1
        next
      end
      name = m[1]
      i = pos + 1 + name.bytesize
    end

    if $env_map.key?(name)
      out << $env_map[name]
    else
      warn "LINE_ERROR_UNBOUND_REF (#{name}): #{path}:#{lineno}"
      $errors += 1
    end
  end
  out
end

def handle_record(path, lineno, key, raw_value, value, format, action)
  if action == "dump"
    puts "#{key}=#{value}"
    return
  end
  return if action == "validate" || action == "normalize"

  resolved = value
  if format == "native" || !raw_value.start_with?("'")
    resolved = subst_value(path, lineno, resolved)
  end
  $env_map[key] = resolved
  puts "#{key}=#{resolved}" if action == "delta"
end

def process_file(path, data, format, action, bom, crlf, nul, cont)
  if nul == "reject" && data.include?("\0")
    fdiag(path, "FILE_ERROR_NUL")
    return
  end

  lines = split_lines(data)
  if !lines.empty? && lines[0].start_with?("\xEF\xBB\xBF".b)
    if bom == "reject"
      fdiag(path, "FILE_ERROR_BOM")
      return
    elsif bom == "strip"
      lines[0] = lines[0].byteslice(3, lines[0].bytesize - 3) || "".b
    end
  end

  if crlf == "strip"
    all_crlf = !lines.empty? && lines.all? { |l| l.end_with?("\r") }
    lines.map! { |l| l.byteslice(0, l.bytesize - 1) || "".b } if all_crlf
  end

  proc_lines = []
  proc_lineno = []
  if cont == "accept"
    i = 0
    while i < lines.length
      line = lines[i]
      lineno = i + 1
      i += 1
      while continuation?(line) && i < lines.length
        line = line[0...-1] + lines[i]
        lineno = i + 1
        i += 1
      end
      proc_lines << line
      proc_lineno << lineno
    end
  else
    lines.each_with_index do |line, i|
      proc_lines << line
      proc_lineno << i + 1
    end
  end

  proc_lines.each_with_index do |line, idx|
    lineno = proc_lineno[idx]
    trimmed = line.end_with?("\r") ? line[0...-1] : line
    next if trimmed.strip.empty?
    next if trimmed.start_with?("#")

    $checked += 1
    eq = line.index("=")
    unless eq
      diag(path, lineno, "LINE_ERROR_NO_EQUALS")
      next
    end
    raw_key = line[0...eq]
    raw_value = line[(eq + 1)..] || ""

    if action == "normalize"
      puts "#{raw_key}=#{raw_value}"
      next
    end

    work = format == "native" ? line : trimmed
    eq2 = work.index("=")
    unless eq2
      diag(path, lineno, "LINE_ERROR_NO_EQUALS")
      next
    end
    key = work[0...eq2]
    value = work[(eq2 + 1)..] || ""

    if format == "native"
      if key.empty?
        diag(path, lineno, "LINE_ERROR_EMPTY_KEY")
        next
      end
      handle_record(path, lineno, key, raw_value, value, format, action)
      next
    end

    if !key.empty? && [" ", "\t"].include?(key[0])
      diag(path, lineno, "LINE_ERROR_KEY_LEADING_WHITESPACE")
      next
    end
    if !key.empty? && [" ", "\t"].include?(key[-1])
      diag(path, lineno, "LINE_ERROR_KEY_TRAILING_WHITESPACE")
      next
    end
    if !value.empty? && [" ", "\t"].include?(value[0])
      diag(path, lineno, "LINE_ERROR_VALUE_LEADING_WHITESPACE")
      next
    end
    if key.empty?
      diag(path, lineno, "LINE_ERROR_EMPTY_KEY")
      next
    end
    unless valid_shell_key?(key)
      diag(path, lineno, "LINE_ERROR_KEY_INVALID")
      next
    end

    out_value = unquote_shell_value(path, lineno, value)
    next if out_value.nil?
    handle_record(path, lineno, key, raw_value, out_value, format, action)
  end
end

files = ARGV.empty? ? ["-"] : ARGV
seed_env_map if action == "delta" || action == "apply"

files.each do |path|
  begin
    data = path == "-" ? $stdin.read : File.binread(path)
  rescue StandardError
    fdiag(path, "FILE_ERROR_FILE_UNREADABLE")
    next
  end
  process_file(path, data, format, action, bom, crlf, nul, cont)
end

if action == "apply"
  $env_map.keys.reject { |k| k.start_with?("ENVFILE_") }.sort.each do |k|
    puts "#{k}=#{$env_map[k]}"
  end
end

warn "#{$checked} checked, #{$errors} errors"
exit($errors > 0 ? 1 : 0)

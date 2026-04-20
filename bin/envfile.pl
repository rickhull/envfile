#!/usr/bin/env perl
# envfile.pl — validate/normalize env files
# Config via ENVFILE_* env vars; see envfile.awk for full docs.
#
# Pipeline: slurp → check_nul → check_bom → strip_crlf → join_continuations → validate
use strict;
use warnings;

my $format = $ENV{ENVFILE_FORMAT}           // 'shell';
my $action = $ENV{ENVFILE_ACTION}           // 'validate';
my $bom    = exists $ENV{ENVFILE_BOM} ? $ENV{ENVFILE_BOM} : ($format eq 'native' ? 'literal' : 'strip');
my $crlf   = $ENV{ENVFILE_CRLF}             // 'ignore';
my $nul    = $ENV{ENVFILE_NUL}              // 'reject';
my $cont   = $ENV{ENVFILE_BACKSLASH_CONTINUATION} // 'ignore';

my ($checked, $errors) = (0, 0);
my %env;

if ($bom ne 'literal' && $bom ne 'strip' && $bom ne 'reject') {
    warn "FATAL_ERROR_BAD_ENVFILE_VALUE: ENVFILE_BOM=$bom\n";
    exit 1;
}
if ($format eq 'native' && $bom ne 'literal') {
    warn "FATAL_ERROR_UNSUPPORTED: format=native ENVFILE_BOM=$bom\n";
    exit 1;
}

sub diag  { my ($f, $n, $code) = @_; warn "$code: $f:$n\n";   $errors++; }
sub fdiag { my ($f, $code)    = @_; warn "$code: $f\n";        $errors++; }

# ---------------------------------------------------------------------------
# Key validation
# ---------------------------------------------------------------------------
sub valid_shell_key { $_[0] =~ /^[A-Za-z_][A-Za-z0-9_]*$/ }

# ---------------------------------------------------------------------------
# Stage 6: validate one line
# ---------------------------------------------------------------------------
sub validate_line {
    my ($display, $lineno, $line) = @_;

    # Strip trailing CR for blank/comment detection (all formats)
    my $trimmed = $line;
    $trimmed =~ s/\r$//;

    return if $trimmed =~ /^\s*$/;
    return if $trimmed =~ /^#/;

    $checked++;

    # Normalize: emit raw k=v from unmodified line
    if ($line =~ /=/) {
        my ($raw_k, $raw_v) = split /=/, $line, 2;
        if ($action eq 'normalize') {
            print "$raw_k=$raw_v\n";
            return;
        }
    }

    # Validation: use trimmed (CR-stripped) line
    my $work = $trimmed;
    if ($work !~ /=/) {
        diag($display, $lineno, "LINE_ERROR_NO_EQUALS");
        return;
    }
    my ($k, $v) = split /=/, $work, 2;

    if ($format eq 'native') {
        if ($k eq '') { diag($display, $lineno, "LINE_ERROR_EMPTY_KEY"); return; }
        do_dump($k, $v, $v, $display, $lineno);
        return;
    }

    # shell format
    if ($k =~ /^\s/)     { diag($display, $lineno, "LINE_ERROR_KEY_LEADING_WHITESPACE");   return; }
    if ($k =~ /\s$/)     { diag($display, $lineno, "LINE_ERROR_KEY_TRAILING_WHITESPACE");  return; }
    if ($v =~ /^\s/)     { diag($display, $lineno, "LINE_ERROR_VALUE_LEADING_WHITESPACE"); return; }
    if ($k eq '')        { diag($display, $lineno, "LINE_ERROR_EMPTY_KEY");                 return; }
    if (!valid_shell_key($k)) { diag($display, $lineno, "LINE_ERROR_KEY_INVALID");          return; }

    my $value = $v;
    if (length $value) {
        my $c = substr($value, 0, 1);
        if ($c eq '"' || $c eq "'") {
            my $rest = substr($value, 1);
            my $pos = index($rest, $c);
            if ($pos == -1) {
                diag($display, $lineno, $c eq '"'
                    ? "LINE_ERROR_DOUBLE_QUOTE_UNTERMINATED"
                    : "LINE_ERROR_SINGLE_QUOTE_UNTERMINATED");
                return;
            }
            if (length(substr($rest, $pos + 1)) > 0) {
                diag($display, $lineno, "LINE_ERROR_TRAILING_CONTENT");
                return;
            }
            $value = substr($rest, 0, $pos);
        } elsif ($v =~ /[ \t'"\\]/) {
            diag($display, $lineno, "LINE_ERROR_VALUE_INVALID_CHAR");
            return;
        }
    }

    do_dump($k, $v, $value, $display, $lineno);
}

# ---------------------------------------------------------------------------
# subst: walk value resolving $VAR and ${VAR} against %env
# ---------------------------------------------------------------------------
sub subst {
    my ($val, $path, $lineno) = @_;
    my $out = '';
    while (length $val > 0) {
        my $pos = index($val, '$');
        if ($pos == -1) { $out .= $val; last; }
        $out .= substr($val, 0, $pos);
        my $rest = substr($val, $pos + 1);
        if (substr($rest, 0, 1) eq '{') {
            my $after_brace = substr($rest, 1);
            my $brace = index($after_brace, '}');
            if ($brace == -1) { $out .= '$' . $rest; last; }
            my $name = substr($after_brace, 0, $brace);
            $val = substr($after_brace, $brace + 1);
            if (exists $env{$name}) { $out .= $env{$name} }
            else { diag($path, $lineno, "LINE_ERROR_UNBOUND_REF ($name)") }
        } else {
            if ($rest =~ /^([A-Za-z_][A-Za-z0-9_]*)/) {
                my $name = $1;
                $val = substr($rest, length($name));
                if (exists $env{$name}) { $out .= $env{$name} }
                else { diag($path, $lineno, "LINE_ERROR_UNBOUND_REF ($name)") }
            } else {
                $out .= '$';
                $val = $rest;
            }
        }
    }
    return $out;
}

# ---------------------------------------------------------------------------
# dump / delta / apply chain
# ---------------------------------------------------------------------------
sub do_dump {
    my ($k, $raw, $value, $path, $lineno) = @_;
    if ($action eq 'dump') { print "$k=$value\n"; return; }
    do_delta($k, $raw, $value, $path, $lineno);
}

sub do_delta {
    my ($k, $raw, $value, $path, $lineno) = @_;
    return if $action eq 'validate';
    # single-quoted shell values are literal; native always substitutes
    if ($format eq 'native' || substr($raw, 0, 1) ne "'") {
        $value = subst($value, $path, $lineno);
    }
    $env{$k} = $value;
    if ($action eq 'delta') { print "$k=$value\n" }
}

sub emit_env_sorted {
    my @keys = sort grep { substr($_, 0, 8) ne 'ENVFILE_' } keys %env;
    for my $k (@keys) { print "$k=$env{$k}\n" }
}

# ---------------------------------------------------------------------------
# Process one file through the pipeline
# ---------------------------------------------------------------------------
sub process_file {
    my ($display, $path) = @_;

    # Slurp
    my $buf;
    if ($path eq '-') {
        binmode STDIN;
        local $/;
        $buf = <STDIN>;
    } else {
        open my $fh, '<:raw', $path or do {
            fdiag($display, "FILE_ERROR_FILE_UNREADABLE");
            return;
        };
        local $/;
        $buf = <$fh>;
    }

    # NUL check (file-level)
    if ($nul eq 'reject' && index($buf, "\0") != -1) {
        fdiag($display, "FILE_ERROR_NUL");
        return;
    }

    # BOM check
    if (substr($buf, 0, 3) eq "\xef\xbb\xbf") {
        if ($bom eq 'reject') { fdiag($display, "FILE_ERROR_BOM"); return; }
        if ($bom eq 'strip')  { $buf = substr($buf, 3); }
    }

    # Split into lines (preserving CR)
    my @lines = split /\n/, $buf, -1;
    pop @lines if @lines && $lines[-1] eq '';

    # CRLF strip: only when every non-empty line ends with CR
    if ($crlf eq 'strip') {
        my $all_crlf = 1;
        for my $l (@lines) {
            next if $l eq '';
            if (substr($l, -1, 1) ne "\r") { $all_crlf = 0; last; }
        }
        if ($all_crlf) {
            for my $l (@lines) { $l =~ s/\r$// if length $l; }
        }
    }

    # Continuation joining
    if ($cont eq 'accept') {
        my @joined;
        my $hold;
        for my $l (@lines) {
            if (defined $hold) {
                $l = substr($hold, 0, length($hold) - 1) . $l;
                $hold = undef;
            }
            # Count trailing backslashes
            my $tmp = $l; my $bs = 0;
            while (length $tmp && substr($tmp, -1) eq '\\') {
                $tmp = substr($tmp, 0, length($tmp) - 1);
                $bs++;
            }
            if ($bs % 2 == 1) { $hold = $l; }
            else              { push @joined, $l; }
        }
        push @joined, $hold if defined $hold;
        @lines = @joined;
    }

    # Validate each line
    my $n = 0;
    for my $line (@lines) {
        $n++;
        validate_line($display, $n, $line);
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
my @files = @ARGV ? @ARGV : ('-');

if ($action eq 'delta' || $action eq 'apply') {
    for my $k (keys %ENV) {
        $env{$k} = $ENV{$k} if substr($k, 0, 8) ne 'ENVFILE_';
    }
}

for my $f (@files) {
    process_file($f, $f);
}

emit_env_sorted() if $action eq 'apply';

warn "$checked checked, $errors errors\n";
exit 1 if $errors;

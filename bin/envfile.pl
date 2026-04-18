#!/usr/bin/env perl
# envfile.pl — validate/normalize env files (see README.md)
use strict;
use warnings;

use constant ERROR_NO_EQUALS                 => "ERROR_NO_EQUALS";
use constant ERROR_EMPTY_KEY                 => "ERROR_EMPTY_KEY";
use constant ERROR_KEY_LEADING_WHITESPACE    => "ERROR_KEY_LEADING_WHITESPACE";
use constant ERROR_KEY_TRAILING_WHITESPACE   => "ERROR_KEY_TRAILING_WHITESPACE";
use constant ERROR_VALUE_LEADING_WHITESPACE  => "ERROR_VALUE_LEADING_WHITESPACE";
use constant ERROR_KEY_INVALID               => "ERROR_KEY_INVALID";
use constant ERROR_DOUBLE_QUOTE_UNTERMINATED => "ERROR_DOUBLE_QUOTE_UNTERMINATED";
use constant ERROR_SINGLE_QUOTE_UNTERMINATED => "ERROR_SINGLE_QUOTE_UNTERMINATED";
use constant ERROR_TRAILING_CONTENT          => "ERROR_TRAILING_CONTENT";
use constant ERROR_VALUE_INVALID_CHAR        => "ERROR_VALUE_INVALID_CHAR";

my $format = $ENV{ENVFILE_FORMAT} // 'strict';
my $action = $ENV{ENVFILE_ACTION} // 'validate';
my ($checked, $errors) = (0, 0);

sub error {
    my ($file, $line, $msg) = @_;
    warn "$msg: $file:$line\n";
    $errors++;
}

sub native_scan {
    my ($tag, $buf, $normalize, $norm_ref, $diag_ref) = @_;
    my ($lc, $ec) = (0, 0);
    my $pos = 0;
    my $len = length $buf;
    my $n   = 0;

    while ($pos <= $len) {
        my $nl = index($buf, "\n", $pos);
        my $end = $nl == -1 ? $len : $nl;
        my $line = substr($buf, $pos, $end - $pos);
        $pos = $end + 1;
        $n++;

        if (index($line, "\0") != -1) {
            $$diag_ref .= ERROR_VALUE_INVALID_CHAR . ": $tag:$n\n";
            $lc++;
            $ec++;
            last if $nl == -1;
            next;
        }
        next if $line =~ /^\s*$/;
        next if substr($line, 0, 1) eq '#';
        $lc++;

        my $eq = index($line, '=');
        if ($eq == -1) {
            $$diag_ref .= ERROR_NO_EQUALS . ": $tag:$n\n";
            $ec++;
            last if $nl == -1;
            next;
        }

        my $k = substr($line, 0, $eq);
        my $v = substr($line, $eq + 1);

        if ($k eq '') {
            $$diag_ref .= ERROR_EMPTY_KEY . ": $tag:$n\n";
            $ec++;
        } elsif ($k !~ /^[A-Z_][A-Z0-9_]*$/) {
            $$diag_ref .= ERROR_KEY_INVALID . ": $tag:$n\n";
            $ec++;
        } elsif ($normalize) {
            $$norm_ref .= "$k=$v\n";
        }

        last if $nl == -1;
    }

    return ($lc, $ec);
}

sub lint_native {
    my ($files, $normalize) = @_;
    my ($norm, $diag) = ('', '');

    for my $f (@$files) {
        my $buf;
        if ($f eq '-') {
            binmode STDIN;
            local $/;
            $buf = <STDIN>;
        } else {
            open my $fh, '<:raw', $f or do {
                $diag .= "lint: $f: $!\n";
                $errors++;
                next;
            };
            local $/;
            $buf = <$fh>;
        }
        my ($lc, $ec) = native_scan($f, $buf, $normalize, \$norm, \$diag);
        $checked += $lc;
        $errors  += $ec;
    }

    $diag .= "$checked checked, $errors errors\n";
    binmode STDOUT;
    print $norm if $norm;
    binmode STDERR;
    print STDERR $diag;
}

sub strict_parse {
    my ($file, $line_no, $line) = @_;

    return if $line =~ /^\s*$/;
    return if $line =~ /^#/;
    $checked++;

    if ($line !~ /=/) {
        error($file, $line_no, ERROR_NO_EQUALS);
        return;
    }

    my ($k, $v) = split /=/, $line, 2;

    if ($k =~ /^\s/) {
        error($file, $line_no, ERROR_KEY_LEADING_WHITESPACE);
        return;
    }
    if ($k =~ /\s$/) {
        error($file, $line_no, ERROR_KEY_TRAILING_WHITESPACE);
        return;
    }
    if ($v =~ /^\s/) {
        error($file, $line_no, ERROR_VALUE_LEADING_WHITESPACE);
        return;
    }
    if ($k !~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
        error($file, $line_no, ERROR_KEY_INVALID);
        return;
    }
    my $value = $v;
    if (length $value) {
        my $c = substr($value, 0, 1);
        if ($c eq '"') {
            my $rest = substr($value, 1);
            my $pos  = index($rest, '"');
            if ($pos == -1) {
                error($file, $line_no, ERROR_DOUBLE_QUOTE_UNTERMINATED);
                return;
            }
            if (length(substr($rest, $pos + 1)) > 0) {
                error($file, $line_no, ERROR_TRAILING_CONTENT);
                return;
            }
            $value = substr($rest, 0, $pos);
        } elsif ($c eq "'") {
            my $rest = substr($value, 1);
            my $pos  = index($rest, "'");
            if ($pos == -1) {
                error($file, $line_no, ERROR_SINGLE_QUOTE_UNTERMINATED);
                return;
            }
            if (length(substr($rest, $pos + 1)) > 0) {
                error($file, $line_no, ERROR_TRAILING_CONTENT);
                return;
            }
            $value = substr($rest, 0, $pos);
        } elsif ($value =~ /[\s'"\\]/) {
            error($file, $line_no, ERROR_VALUE_INVALID_CHAR);
            return;
        }
    }

    print "$k=$value\n" if $action eq 'normalize';
}

sub lint_strict {
    my ($files) = @_;

    for my $f (@$files) {
        my $fh;
        if ($f eq '-') {
            $fh = *STDIN{IO};
        } else {
            open $fh, '<', $f or do {
                warn "lint: $f: $!\n";
                $errors++;
                next;
            };
        }
        my $n = 0;
    while (my $line = <$fh>) {
            $n++;
            chomp $line;
            $line =~ s/\r$//;
            if (index($line, "\0") != -1) {
                error($f, $n, ERROR_VALUE_INVALID_CHAR);
                $checked++;
                next;
            }
            strict_parse($f, $n, $line);
        }
    }

    warn "$checked checked, $errors errors\n";
}

my @files = @ARGV ? @ARGV : ('-');

if ($format eq 'native') {
    lint_native(\@files, $action eq 'normalize');
} else {
    lint_strict(\@files);
}

exit 1 if $errors;

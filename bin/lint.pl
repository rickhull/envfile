#!/usr/bin/env perl
# lint.pl — validate env files (see README.md)
use strict;
use warnings;

use constant ERROR_NO_EQUALS               => "missing assignment (=)";
use constant ERROR_KEY_LEADING_WHITESPACE  => "leading whitespace before key";
use constant ERROR_KEY_TRAILING_WHITESPACE => "whitespace before =";
use constant ERROR_VALUE_LEADING_WHITESPACE => "whitespace after =";
use constant ERROR_KEY_INVALID             => "invalid key";
use constant ERROR_DOUBLE_QUOTE_UNTERMINATED => "unterminated double quote";
use constant ERROR_SINGLE_QUOTE_UNTERMINATED => "unterminated single quote";
use constant ERROR_TRAILING_CONTENT        => "trailing content after closing quote";
use constant ERROR_VALUE_INVALID_CHAR      => "value contains whitespace, quote, or backslash";
use constant WARN_KEY_NOT_UPPERCASE        => "is not UPPERCASE (preferred)";

my ($checked, $errors, $warnings) = (0, 0, 0);

sub error {
    my ($msg) = @_;
    warn "$ARGV:$.: $msg\n";
    $errors++;
}

sub warning {
    my ($msg) = @_;
    warn "$ARGV:$.: $msg\n";
    $warnings++;
}

while (<>) {
    chomp;
    s/\r$//;  # strip carriage return for \r\n (Windows) line endings
    next if /^\s*$/;
    next if /^#/;
    $checked++;

    if (!/=/) {
        error ERROR_NO_EQUALS; next;
    }

    my ($k, $v) = split /=/, $_, 2;

    if ($k =~ /^\s/) {
        error ERROR_KEY_LEADING_WHITESPACE; next;
    }
    if ($k =~ /\s$/) {
        error ERROR_KEY_TRAILING_WHITESPACE; next;
    }
    if ($v =~ /^\s/) {
        error ERROR_VALUE_LEADING_WHITESPACE; next;
    }
    if ($k !~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
        error ERROR_KEY_INVALID . " '$k'"; next;
    }
    if ($k ne uc $k) {
        warning "key '$k' " . WARN_KEY_NOT_UPPERCASE;
    }

    next unless length $v;

    my $c = substr($v, 0, 1);

    if ($c eq '"') {
        my $rest = substr($v, 1);
        my $pos  = index($rest, '"');
        if ($pos == -1) {
            error ERROR_DOUBLE_QUOTE_UNTERMINATED; next;
        }
        if (length(substr($rest, $pos + 1)) > 0) {
            error ERROR_TRAILING_CONTENT; next;
        }
    } elsif ($c eq "'") {
        my $rest = substr($v, 1);
        my $pos  = index($rest, "'");
        if ($pos == -1) {
            error ERROR_SINGLE_QUOTE_UNTERMINATED; next;
        }
        if (length(substr($rest, $pos + 1)) > 0) {
            error ERROR_TRAILING_CONTENT; next;
        }
    } else {
        if ($v =~ /[\s'"\\]/) {
            error ERROR_VALUE_INVALID_CHAR; next;
        }
    }
}

warn "$checked checked, $errors errors, $warnings warnings\n";
exit 1 if $errors;

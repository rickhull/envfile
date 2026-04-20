set shell := ["bash", "-cu"]

# Corpus mining workflow
mod corpus

# Benchmark helpers
mod bench

# Native format pipeline
mod native

# Shell format pieline
mod shell

# Compat format pipeline
mod compat

[private]
default:
  @just --list
  just --list corpus
  just --list bench
  just --list native
  just --list shell
  just --list compat

# Run the full test suite against the reference implementation.
test *args="awk":
  #!/usr/bin/env bash
  set -uo pipefail
  impls=()
  for arg in {{args}}; do
    if [[ -x "$arg" ]]; then
      impls+=("$arg")
    else
      path=$(bin/lang "$arg" envfile 2>/dev/null) || { echo "unknown impl: $arg"; exit 1; }
      impls+=("$path")
    fi
  done
  just shell::verify "${impls[@]}"
  just shell::verify-normalize "${impls[@]}"
  just shell::verify-dump "${impls[@]}"
  just native::verify "${impls[@]}"
  just native::verify-normalize "${impls[@]}"
  just native::verify-apply "${impls[@]}"

# Regenerate all golden files from the reference implementation
regen:
  just shell::regen
  just shell::regen-dump
  just native::regen
  just native::regen-apply

# Show availability of all language implementations.
impls:
  bin/lang status

# Makefile delegates (prefer: make all, make clean, etc.)
mod make

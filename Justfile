set shell := ["bash", "-cu"]
set export

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

bin_dir := justfile_directory() + "/bin"
# .envrc adds the same bin/ prefix for direnv users; Justfile exports it so
# `lang` and `envfile` work in recipes without requiring direnv.
export PATH := bin_dir + ":" + env_var_or_default("PATH", "")

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
  just shell::verify {{args}}
  just native::verify {{args}}

# Regenerate all golden files from the reference implementation
regen:
  just shell::regen
  just shell::regen-dump
  just native::regen
  just native::regen-apply

# Show availability of all language implementations.
impls:
  lang status

# Makefile delegates (prefer: make all, make clean, etc.)
mod make

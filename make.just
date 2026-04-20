set shell := ["bash", "-cu"]

# Thin delegates to Makefile targets.
#
# Exposed here so that `just` (default recipe) and `just --list-submodules`
# surface the available build targets alongside the rest of the workflow.
# For anything you know by name, go direct — `make <target>` is shorter:
#
#   make all       make c        make go       make rust
#   make now       make zig      make asm      make bench
#   make fast      make nullscan make clean    make fresh

# Build all compiled implementations.
all:
  make all

# Build quickly, slower runtime.
now:
  make now

# Build slower, faster runtime.
fast:
  make fast

# Remove build outputs.
clean:
  make clean

# Remove build outputs and restore symlink bootstrap.
fresh:
  make fresh

# Build bin/envfile.c
c:
  make c

# Build bin/envfile.go
go:
  make go

# Build bin/envfile.rs
rust:
  make rust

# Build bin/envfile.zig
zig:
  make zig

# Build bin/envfile.asm
asm:
  make asm

# Build bin/bench
bench:
  make bench

# Build bin/nullscan
nullscan:
  make nullscan

set shell := ["bash", "-cu"]

# Benchmark helpers for implementation outputs.
mod bench
# Shared implementation activation helpers.
mod impl
# Strict format workflow module.
mod strict
# Native format workflow module.
mod native
# Compat format workflow module.
mod compat
# Shared corpus mining workflow.
mod corpus

# Build every native implementation plus the benchmark binary.
make:
  make all

# Build the current mode without implying a mode change.
now:
  make now

# Build the default fast mode explicitly.
fast:
  make fast

# Clean outputs and restore the benchmark symlink bootstrap.
fresh:
  make fresh

# Remove generated build outputs.
clean:
  make clean

# List module recipes for the whole repo.
list:
  just --list --list-submodules

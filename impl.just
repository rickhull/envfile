set shell := ["bash", "-cu"]

# Show availability of all language tools.
status:
  bin/lang status

# Build the benchmark binary.
bench:
  make bench

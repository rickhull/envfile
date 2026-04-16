all: go zig c rust asm bench

bench:
  cc -O2 -o bin/bench impl/c/bench.c -lm

clean:
  rm -f bin/lint bin/lint.go bin/lint.zig bin/lint.c bin/lint.rs bin/lint.asm bin/bench

go:
  mise exec -- go build -C impl/go -o ../../bin/lint.go .

zig:
  mise exec -- zig build-exe impl/zig/main.zig -O ReleaseFast -femit-bin=bin/lint.zig

c:
  cc -O2 -o bin/lint.c impl/c/lint.c

rust:
  mise exec -- rustc -O -o bin/lint.rs impl/rust/lint.rs

asm:
  #!/usr/bin/env bash
  tmp=$(mktemp)
  trap "rm -f $tmp" EXIT
  nasm -f elf64 impl/asm/lint.asm -o "$tmp"
  ld "$tmp" -o bin/lint.asm

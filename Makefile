.PHONY: all now fast fresh bench c go rust zig asm nullscan clean status FORCE

MODE ?= fast
MODE_KEY = $(if $(filter now,$(MODE)),NOW,FAST)
STAMPDIR := .make

CC ?= cc
GO ?= go
RUSTC ?= rustc
ZIG ?= zig
NASM ?= nasm
LD ?= ld
ZIG_GLOBAL_CACHE_DIR ?= $(STAMPDIR)/zig-global
ZIG_LOCAL_CACHE_DIR ?= $(STAMPDIR)/zig-local

C_FAST_ARGS ?= -O2 -Wall -Wextra
C_NOW_ARGS ?= -O0 -Wall -Wextra

GO_FAST_ARGS ?= -trimpath -ldflags='-s -w'
GO_NOW_ARGS ?= -gcflags=all='-N -l'

RUST_FAST_ARGS ?= -O
RUST_NOW_ARGS ?= -C opt-level=0

ZIG_FAST_ARGS ?= -O ReleaseFast
ZIG_NOW_ARGS ?= -O Debug

ASM_FAST_ARGS ?=
ASM_NOW_ARGS ?= $(ASM_FAST_ARGS)

BENCH_FAST_ARGS ?= -O2
BENCH_NOW_ARGS ?= -O0

C_ARGS = $(C_$(MODE_KEY)_ARGS)
GO_ARGS = $(GO_$(MODE_KEY)_ARGS)
RUST_ARGS = $(RUST_$(MODE_KEY)_ARGS)
ZIG_ARGS = $(ZIG_$(MODE_KEY)_ARGS)
ASM_ARGS = $(ASM_$(MODE_KEY)_ARGS)
BENCH_ARGS = $(BENCH_$(MODE_KEY)_ARGS)

C_STAMP = $(STAMPDIR)/envfile.c.stamp
GO_STAMP = $(STAMPDIR)/envfile.go.stamp
RUST_STAMP = $(STAMPDIR)/envfile.rs.stamp
ZIG_STAMP = $(STAMPDIR)/envfile.zig.stamp
ASM_STAMP = $(STAMPDIR)/envfile.asm.stamp
BENCH_STAMP = $(STAMPDIR)/bench.stamp

all: go zig c rust asm bench nullscan

now: MODE = now
now: all

fast: MODE = fast
fast: all

bench: bin/bench

nullscan: bin/nullscan

c: bin/envfile.c

go: bin/envfile.go

rust: bin/envfile.rs

zig: bin/envfile.zig

asm: bin/envfile.asm

$(STAMPDIR):
	mkdir -p $@

$(STAMPDIR)/bench.stamp: Makefile FORCE | $(STAMPDIR)
	@tmp=$$(mktemp); \
	printf '%s\n%s\n' "BENCH_ARGS=$(BENCH_ARGS)" "CC=$(CC)" > $$tmp; \
	if test -f $@ && cmp -s $$tmp $@; then rm -f $$tmp; else mv $$tmp $@; fi

$(STAMPDIR)/envfile.c.stamp: Makefile FORCE | $(STAMPDIR)
	@tmp=$$(mktemp); \
	printf '%s\n%s\n' "C_ARGS=$(C_ARGS)" "CC=$(CC)" > $$tmp; \
	if test -f $@ && cmp -s $$tmp $@; then rm -f $$tmp; else mv $$tmp $@; fi

$(STAMPDIR)/envfile.go.stamp: Makefile FORCE | $(STAMPDIR)
	@tmp=$$(mktemp); \
	printf '%s\n%s\n' "GO_ARGS=$(GO_ARGS)" "GO=$(GO)" > $$tmp; \
	if test -f $@ && cmp -s $$tmp $@; then rm -f $$tmp; else mv $$tmp $@; fi

$(STAMPDIR)/envfile.rs.stamp: Makefile FORCE | $(STAMPDIR)
	@tmp=$$(mktemp); \
	printf '%s\n%s\n' "RUST_ARGS=$(RUST_ARGS)" "RUSTC=$(RUSTC)" > $$tmp; \
	if test -f $@ && cmp -s $$tmp $@; then rm -f $$tmp; else mv $$tmp $@; fi

$(STAMPDIR)/envfile.zig.stamp: Makefile FORCE | $(STAMPDIR)
	@tmp=$$(mktemp); \
	printf '%s\n%s\n' "ZIG_ARGS=$(ZIG_ARGS)" "ZIG=$(ZIG)" > $$tmp; \
	if test -f $@ && cmp -s $$tmp $@; then rm -f $$tmp; else mv $$tmp $@; fi

$(STAMPDIR)/envfile.asm.stamp: Makefile FORCE | $(STAMPDIR)
	@tmp=$$(mktemp); \
	printf '%s\n%s\n' "ASM_ARGS=$(ASM_ARGS)" "NASM=$(NASM)" > $$tmp; \
	if test -f $@ && cmp -s $$tmp $@; then rm -f $$tmp; else mv $$tmp $@; fi

bin/bench: src/c/bench.c $(BENCH_STAMP) Makefile
	$(CC) $(BENCH_ARGS) -o $@ $< -lm

bin/envfile.c: src/c/envfile.c src/c/backend.c src/c/envfile_backend.h $(C_STAMP) Makefile
	$(CC) $(C_ARGS) -o $@ src/c/envfile.c src/c/backend.c

bin/envfile.go: src/go/main.go src/go/go.mod $(GO_STAMP) Makefile
	$(GO) -C src/go build $(GO_ARGS) -o ../../$@ .

bin/envfile.rs: src/rust/main.rs $(RUST_STAMP) Makefile
	$(RUSTC) $(RUST_ARGS) -o $@ $<

bin/envfile.zig: src/zig/main.zig $(ZIG_STAMP) Makefile
	mkdir -p $(ZIG_GLOBAL_CACHE_DIR) $(ZIG_LOCAL_CACHE_DIR)
	ZIG_GLOBAL_CACHE_DIR=$(ZIG_GLOBAL_CACHE_DIR) ZIG_LOCAL_CACHE_DIR=$(ZIG_LOCAL_CACHE_DIR) $(ZIG) build-exe $< $(ZIG_ARGS) -femit-bin=$@

ASM_BACKEND_OBJ = $(STAMPDIR)/envfile-asm.o

$(ASM_BACKEND_OBJ): src/c/backend.asm $(ASM_STAMP) Makefile | $(STAMPDIR)
	$(NASM) -f elf64 $(ASM_ARGS) src/c/backend.asm -o $@

bin/envfile.asm: src/c/envfile.c $(ASM_BACKEND_OBJ) $(ASM_STAMP) Makefile
	$(CC) $(C_ARGS) -o $@ src/c/envfile.c $(ASM_BACKEND_OBJ)

bin/nullscan: src/c/nullscan.c $(C_STAMP) Makefile
	$(CC) $(C_ARGS) -o $@ $<

clean:
	rm -rf bin/envfile.go bin/envfile.zig bin/envfile.c bin/envfile.rs bin/envfile.asm bin/nullscan bin/bench $(STAMPDIR)

fresh: clean
	ln -sf pybench bin/bench

status:
	@bin/lang status

FORCE:

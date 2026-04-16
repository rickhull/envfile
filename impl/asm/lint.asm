; lint.asm — validate env files (see README.md)
; x86-64 Linux, NASM syntax, no libc (raw syscalls)
;
; Syscall ABI: rax=number, rdi/rsi/rdx/r10/r8/r9 = args, return in rax
; Callee-saved: rbx, rbp, r12–r15
; Caller-saved: rax, rcx, rdx, rsi, rdi, r8–r11

bits 64
default rel

; ── syscall numbers ──────────────────────────────────────────────────────────
SYS_read  equ 0
SYS_write equ 1
SYS_open  equ 2
SYS_close equ 3
SYS_exit  equ 60

O_RDONLY  equ 0
STDERR    equ 2

; ── character constants ───────────────────────────────────────────────────────
TAB equ 9
CR  equ 13
LF  equ 10

READ_BUF_SIZE equ 65536
LINE_BUF_SIZE equ 4096

; ── character classification macros ─────────────────────────────────────────
; Each macro tests %1 (byte register) and sets %2 (32-bit register) to 0 or 1.

%macro IS_ALPHA 2
    xor  %2, %2
    cmp  %1, 'A'
    jl   %%lo
    cmp  %1, 'Z'
    jle  %%yes
%%lo:
    cmp  %1, 'a'
    jl   %%done
    cmp  %1, 'z'
    jg   %%done
%%yes:
    mov  %2, 1
%%done:
%endmacro

%macro IS_DIGIT 2
    xor  %2, %2
    cmp  %1, '0'
    jl   %%done
    cmp  %1, '9'
    jg   %%done
    mov  %2, 1
%%done:
%endmacro

%macro IS_LOWER 2
    xor  %2, %2
    cmp  %1, 'a'
    jl   %%done
    cmp  %1, 'z'
    jg   %%done
    mov  %2, 1
%%done:
%endmacro

%macro IS_SPACE 2           ; space, tab, or CR
    xor  %2, %2
    cmp  %1, ' '
    je   %%yes
    cmp  %1, TAB
    je   %%yes
    cmp  %1, CR
    jne  %%done
%%yes:
    mov  %2, 1
%%done:
%endmacro

section .data

; diagnostics — all output goes to stderr
msg_no_files:       db "lint: no files specified", LF, 0
msg_open_fail:      db "lint: cannot open: ", 0
msg_colon:          db ":", 0
msg_colon_space:    db ": ", 0
msg_newline:        db LF, 0
msg_checked:        db " checked, ", 0
msg_errors_:        db " errors, ", 0
msg_warnings_:      db " warnings", 0

; error messages
msg_no_equals:      db "missing assignment (=)", 0
msg_key_lead_ws:    db "leading whitespace before key", 0
msg_key_trail_ws:   db "whitespace before =", 0
msg_val_lead_ws:    db "whitespace after =", 0
msg_invalid_key:    db "invalid key '", 0
msg_dquote_unterm:  db "unterminated double quote", 0
msg_squote_unterm:  db "unterminated single quote", 0
msg_trail_content:  db "trailing content after closing quote", 0
msg_bad_val_char:   db "value contains whitespace, quote, or backslash", 0

; warning messages
msg_key_prefix:     db "key '", 0      ; "key 'K' is not..."
msg_quote_close:    db "'", 0          ; closes invalid key: "invalid key 'K'"
msg_quote_close_sp: db "' ", 0         ; closes warning:    "key 'K' is not..."
msg_warn_upper:     db "is not UPPERCASE (preferred)", 0

section .bss

read_buf:  resb READ_BUF_SIZE
line_buf:  resb LINE_BUF_SIZE

; read buffer state (per file)
buf_pos:   resq 1           ; index of next byte to consume in read_buf
buf_end:   resq 1           ; number of valid bytes in read_buf

; current file state
cur_fd:    resq 1
cur_line:  resq 1
cur_path:  resq 1

; running totals across all files
total_checked:  resq 1
total_errors:   resq 1
total_warnings: resq 1

section .text
global _start

; ═══════════════════════════════════════════════════════════════════════════
; _start — entry point
;
; Stack on entry: [rsp]=argc, [rsp+8]=argv[0], [rsp+16]=argv[1], ...
; ═══════════════════════════════════════════════════════════════════════════
_start:
    mov  r12, [rsp]          ; r12 = argc
    lea  r13, [rsp + 8]      ; r13 = argv base

    cmp  r12, 2
    jge  .have_args

    mov  rsi, msg_no_files
    call print_str
    mov  rdi, 1
    jmp  do_exit

.have_args:
    mov  qword [total_checked],  0
    mov  qword [total_errors],   0
    mov  qword [total_warnings], 0

    mov  r14, 1              ; argv index, start at 1 (skip argv[0])

.file_loop:
    cmp  r14, r12
    jge  .done
    mov  rdi, [r13 + r14*8]
    call process_file
    inc  r14
    jmp  .file_loop

.done:
    ; print summary: "N checked, N errors, N warnings\n"
    mov  rax, [total_checked]
    call print_u64
    mov  rsi, msg_checked
    call print_str
    mov  rax, [total_errors]
    call print_u64
    mov  rsi, msg_errors_
    call print_str
    mov  rax, [total_warnings]
    call print_u64
    mov  rsi, msg_warnings_
    call print_str
    call print_newline

    xor  rdi, rdi
    cmp  qword [total_errors], 0
    je   do_exit
    mov  rdi, 1

do_exit:
    mov  rax, SYS_exit
    syscall

; ═══════════════════════════════════════════════════════════════════════════
; process_file(rdi = path)
;
; Registers across the line loop:
;   rbp = current line length
;   rbx = key length (= offset of '=')
;   r15 = value length
; ═══════════════════════════════════════════════════════════════════════════
process_file:
    push rbx
    push rbp
    push r15

    mov  [cur_path], rdi

    ; open(path, O_RDONLY)
    mov  rax, SYS_open
    mov  rsi, O_RDONLY
    xor  rdx, rdx
    syscall
    test rax, rax
    jns  .open_ok

    mov  rsi, msg_open_fail
    call print_str
    mov  rsi, [cur_path]
    call print_str
    call print_newline
    inc  qword [total_errors]
    jmp  .ret

.open_ok:
    mov  [cur_fd],        rax
    mov  qword [buf_pos],  0
    mov  qword [buf_end],  0
    mov  qword [cur_line], 0

.line_loop:
    call read_line           ; rax = line length, or -1 on EOF
    cmp  rax, -1
    je   .eof

    mov  rbp, rax            ; rbp = line length
    inc  qword [cur_line]

    ; skip empty lines
    test rbp, rbp
    jz   .line_loop

    ; skip whitespace-only lines
    mov  rsi, line_buf
    mov  rcx, rbp
.ws_check:
    movzx eax, byte [rsi]
    IS_SPACE al, edx
    test edx, edx
    jz   .not_blank
    inc  rsi
    dec  rcx
    jnz  .ws_check
    jmp  .line_loop

.not_blank:
    ; skip comment lines
    cmp  byte [line_buf], '#'
    je   .line_loop

    inc  qword [total_checked]

    ; ── locate '=' ────────────────────────────────────────────────────────
    mov  rdi, line_buf
    mov  rcx, rbp
.find_eq:
    cmp  byte [rdi], '='
    je   .has_eq
    inc  rdi
    dec  rcx
    jnz  .find_eq

    call emit_prefix
    mov  rsi, msg_no_equals
    call print_str
    call print_newline
    inc  qword [total_errors]
    jmp  .line_loop

.has_eq:
    ; rdi points at '='; key length = rdi - line_buf
    mov  rbx, rdi
    sub  rbx, line_buf       ; rbx = key length

    ; value starts at line_buf + rbx + 1, length = rbp - rbx - 1
    mov  r15, rbp
    sub  r15, rbx
    dec  r15                 ; r15 = value length

    ; ── key: leading whitespace ───────────────────────────────────────────
    test rbx, rbx
    jz   .check_key_trail    ; empty key — caught by key validation below
    movzx eax, byte [line_buf]
    IS_SPACE al, edx
    test edx, edx
    jz   .check_key_trail

    call emit_prefix
    mov  rsi, msg_key_lead_ws
    call print_str
    call print_newline
    inc  qword [total_errors]
    jmp  .line_loop

    ; ── key: trailing whitespace (char before '=') ────────────────────────
.check_key_trail:
    test rbx, rbx
    jz   .check_val_lead
    movzx eax, byte [line_buf + rbx - 1]
    IS_SPACE al, edx
    test edx, edx
    jz   .check_val_lead

    call emit_prefix
    mov  rsi, msg_key_trail_ws
    call print_str
    call print_newline
    inc  qword [total_errors]
    jmp  .line_loop

    ; ── value: leading whitespace (char after '=') ────────────────────────
.check_val_lead:
    test r15, r15
    jz   .validate_key
    movzx eax, byte [line_buf + rbx + 1]
    IS_SPACE al, edx
    test edx, edx
    jz   .validate_key

    call emit_prefix
    mov  rsi, msg_val_lead_ws
    call print_str
    call print_newline
    inc  qword [total_errors]
    jmp  .line_loop

    ; ── key validation: [A-Za-z_][A-Za-z0-9_]* ───────────────────────────
.validate_key:
    test rbx, rbx
    jz   .key_bad            ; empty key

    movzx eax, byte [line_buf]
    IS_ALPHA al, edx
    test edx, edx
    jnz  .key_rest
    cmp  al, '_'
    jne  .key_bad

.key_rest:
    mov  rsi, line_buf + 1
    mov  rcx, rbx
    dec  rcx
.key_rest_loop:
    test rcx, rcx
    jz   .key_ok
    movzx eax, byte [rsi]
    IS_ALPHA al, edx
    test edx, edx
    jnz  .key_rest_next
    IS_DIGIT al, edx
    test edx, edx
    jnz  .key_rest_next
    cmp  al, '_'
    jne  .key_bad
.key_rest_next:
    inc  rsi
    dec  rcx
    jmp  .key_rest_loop

.key_bad:
    call emit_prefix
    mov  rsi, msg_invalid_key   ; "invalid key '"
    call print_str
    mov  rsi, line_buf
    mov  rdx, rbx
    call write_n
    mov  rsi, msg_quote_close   ; "'"
    call print_str
    call print_newline
    inc  qword [total_errors]
    jmp  .line_loop

    ; ── case warning: key contains lowercase ─────────────────────────────
.key_ok:
    mov  rsi, line_buf
    mov  rcx, rbx
.upper_check:
    test rcx, rcx
    jz   .check_value
    movzx eax, byte [rsi]
    IS_LOWER al, edx
    test edx, edx
    jnz  .warn_case
    inc  rsi
    dec  rcx
    jmp  .upper_check

.warn_case:
    call emit_prefix
    mov  rsi, msg_key_prefix    ; "key '"
    call print_str
    mov  rsi, line_buf
    mov  rdx, rbx
    call write_n
    mov  rsi, msg_quote_close_sp ; "' "
    call print_str
    mov  rsi, msg_warn_upper
    call print_str
    call print_newline
    inc  qword [total_warnings]

    ; ── value checking ────────────────────────────────────────────────────
.check_value:
    test r15, r15
    jz   .line_loop

    ; rsi = pointer to value (line_buf + rbx + 1), length r15
    lea  rsi, [line_buf + rbx + 1]
    movzx eax, byte [rsi]

    cmp  al, '"'
    je   .quoted
    cmp  al, "'"
    je   .quoted

    ; unquoted: scan every char for whitespace, quotes, or backslash
    mov  rcx, r15
.unquoted_scan:
    movzx eax, byte [rsi]
    IS_SPACE al, edx
    test edx, edx
    jnz  .bad_val_char
    cmp  al, "'"
    je   .bad_val_char
    cmp  al, '"'
    je   .bad_val_char
    cmp  al, '\'
    je   .bad_val_char
    inc  rsi
    dec  rcx
    jnz  .unquoted_scan
    jmp  .line_loop

.bad_val_char:
    call emit_prefix
    mov  rsi, msg_bad_val_char
    call print_str
    call print_newline
    inc  qword [total_errors]
    jmp  .line_loop

    ; quoted value: find matching close quote, check nothing follows
.quoted:
    ; rbp (line length) is no longer needed — reuse it for the quote char
    movzx rbp, al            ; rbp = opening quote char ('"' or "'")
    inc  rsi                 ; skip opening quote
    dec  r15                 ; r15 = remaining chars to search

    mov  rdi, rsi
    mov  rcx, r15
.find_close:
    test rcx, rcx
    jz   .unterm
    cmp  [rdi], bpl          ; bpl = low byte of rbp = quote char
    je   .found_close
    inc  rdi
    dec  rcx
    jmp  .find_close

.unterm:
    call emit_prefix
    cmp  bpl, '"'
    je   .unterm_dq
    mov  rsi, msg_squote_unterm
    call print_str
    call print_newline
    inc  qword [total_errors]
    jmp  .line_loop
.unterm_dq:
    mov  rsi, msg_dquote_unterm
    call print_str
    call print_newline
    inc  qword [total_errors]
    jmp  .line_loop

.found_close:
    ; rcx = chars remaining from close quote onward (including close itself)
    ; chars after close = rcx - 1
    dec  rcx
    test rcx, rcx
    jz   .line_loop

    call emit_prefix
    mov  rsi, msg_trail_content
    call print_str
    call print_newline
    inc  qword [total_errors]
    jmp  .line_loop

.eof:
    mov  rax, SYS_close
    mov  rdi, [cur_fd]
    syscall

.ret:
    pop  r15
    pop  rbp
    pop  rbx
    ret

; ═══════════════════════════════════════════════════════════════════════════
; read_line — read next line from cur_fd into line_buf
;
; Uses a large read_buf, refilling via SYS_read as needed.
; Returns rax = line length (excluding newline), or -1 on EOF.
; Strips trailing CR for Windows CRLF line endings.
; ═══════════════════════════════════════════════════════════════════════════
read_line:
    push rbx
    push r12

    xor  rbx, rbx            ; rbx = write index into line_buf

.next_char:
    mov  r12, [buf_pos]
    cmp  r12, [buf_end]
    jl   .have_byte

    ; read_buf exhausted — refill from file
    mov  rax, SYS_read
    mov  rdi, [cur_fd]
    mov  rsi, read_buf
    mov  rdx, READ_BUF_SIZE
    syscall
    test rax, rax
    jle  .eof_check          ; 0 = EOF, negative = error

    mov  qword [buf_pos], 0
    mov  [buf_end], rax
    xor  r12, r12

.have_byte:
    movzx eax, byte [read_buf + r12]
    inc  r12
    mov  [buf_pos], r12

    cmp  al, LF
    je   .eol

    cmp  rbx, LINE_BUF_SIZE - 1
    jge  .next_char          ; silently truncate lines exceeding buffer

    mov  [line_buf + rbx], al
    inc  rbx
    jmp  .next_char

.eol:
    ; strip trailing CR (Windows CRLF)
    test rbx, rbx
    jz   .done
    cmp  byte [line_buf + rbx - 1], CR
    jne  .done
    dec  rbx

.done:
    mov  rax, rbx
    jmp  .ret

.eof_check:
    ; if we buffered chars before hitting EOF, return them as a final line
    test rbx, rbx
    jnz  .done
    mov  rax, -1             ; true EOF — no more lines

.ret:
    pop  r12
    pop  rbx
    ret

; ═══════════════════════════════════════════════════════════════════════════
; emit_prefix — print "path:linenum: " to stderr
; Preserves rax.
; ═══════════════════════════════════════════════════════════════════════════
emit_prefix:
    push rax
    mov  rsi, [cur_path]
    call print_str
    mov  rsi, msg_colon
    call print_str
    mov  rax, [cur_line]
    call print_u64
    mov  rsi, msg_colon_space
    call print_str
    pop  rax
    ret

; ═══════════════════════════════════════════════════════════════════════════
; print_str(rsi = null-terminated string) — write to stderr
; ═══════════════════════════════════════════════════════════════════════════
print_str:
    push rsi
    push rcx
    xor  rcx, rcx
.len_loop:
    cmp  byte [rsi + rcx], 0
    je   .len_done
    inc  rcx
    jmp  .len_loop
.len_done:
    mov  rdx, rcx
    pop  rcx
    pop  rsi
    ; fall through to write_n

; ── write_n(rsi=buf, rdx=len) — write rdx bytes to stderr ────────────────
write_n:
    mov  rax, SYS_write
    mov  rdi, STDERR
    syscall
    ret

; ── print_newline — write LF to stderr ───────────────────────────────────
print_newline:
    mov  rsi, msg_newline
    mov  rdx, 1
    jmp  write_n

; ═══════════════════════════════════════════════════════════════════════════
; print_u64(rax = value) — write decimal representation to stderr
;
; Builds digits right-to-left in a stack buffer, then writes in one syscall.
; ═══════════════════════════════════════════════════════════════════════════
print_u64:
    push rbx
    sub  rsp, 24             ; 20 digits max + null + alignment
    lea  rbx, [rsp + 20]    ; rbx = one past end of digit area
    mov  byte [rbx], 0
    mov  ecx, 10

.digit_loop:
    xor  edx, edx
    div  ecx                 ; rax = quotient, rdx = remainder
    dec  rbx
    add  dl, '0'
    mov  [rbx], dl
    test rax, rax
    jnz  .digit_loop

    ; rbx points to first digit; length = (rsp+20) - rbx
    mov  rsi, rbx
    lea  rdx, [rsp + 20]
    sub  rdx, rbx

    mov  rax, SYS_write
    mov  rdi, STDERR
    syscall

    add  rsp, 24
    pop  rbx
    ret

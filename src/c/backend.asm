; backend.asm - optional asm parser backend for envfile
;
; Exports:
;   envfile_parse_strict(line, len, out)  → status
;   envfile_parse_native(line, len, out)  → status
;
; SysV AMD64:
;   rdi = line pointer
;   rsi = line length
;   rdx = EnvfileRecord*
;   rax = EnvfileStatus
;
; Status codes:
;   0  ENVFILE_SKIP
;   1  ENVFILE_OK
;  10  ENVFILE_ERR_NO_EQUALS
;  11  ENVFILE_ERR_EMPTY_KEY
;  12  ENVFILE_ERR_KEY_INVALID
;  13  ENVFILE_ERR_KEY_LEADING_WHITESPACE
;  14  ENVFILE_ERR_KEY_TRAILING_WHITESPACE
;  15  ENVFILE_ERR_VALUE_LEADING_WHITESPACE
;  16  ENVFILE_ERR_VALUE_INVALID_CHAR
;  17  ENVFILE_ERR_SINGLE_QUOTE_UNTERMINATED
;  18  ENVFILE_ERR_DOUBLE_QUOTE_UNTERMINATED
;  19  ENVFILE_ERR_TRAILING_CONTENT

bits 64
default rel

ENVFILE_SKIP                           equ 0
ENVFILE_OK                             equ 1
ENVFILE_ERR_NO_EQUALS                  equ 10
ENVFILE_ERR_EMPTY_KEY                  equ 11
ENVFILE_ERR_KEY_INVALID                equ 12
ENVFILE_ERR_KEY_LEADING_WHITESPACE     equ 13
ENVFILE_ERR_KEY_TRAILING_WHITESPACE    equ 14
ENVFILE_ERR_VALUE_LEADING_WHITESPACE   equ 15
ENVFILE_ERR_VALUE_INVALID_CHAR         equ 16
ENVFILE_ERR_SINGLE_QUOTE_UNTERMINATED   equ 17
ENVFILE_ERR_DOUBLE_QUOTE_UNTERMINATED   equ 18
ENVFILE_ERR_TRAILING_CONTENT           equ 19

%macro JIF_SPACE 1
    cmp  al, ' '
    je   %1
    cmp  al, 9
    je   %1
    cmp  al, 13
    je   %1
    cmp  al, 11
    je   %1
    cmp  al, 12
    je   %1
%endmacro

%macro JIF_UPPER 1
    cmp  al, 'A'
    jb   %%no
    cmp  al, 'Z'
    jbe  %1
%%no:
%endmacro

%macro JIF_LOWER 1
    cmp  al, 'a'
    jb   %%no
    cmp  al, 'z'
    jbe  %1
%%no:
%endmacro

%macro JIF_DIGIT 1
    cmp  al, '0'
    jb   %%no
    cmp  al, '9'
    jbe  %1
%%no:
%endmacro

%macro JIF_ALPHA 1
    JIF_UPPER %1
    JIF_LOWER %1
%endmacro

%macro JIF_ALNUM 1
    JIF_ALPHA %1
    JIF_DIGIT %1
%endmacro

%macro JIF_UPPER_DIGIT_UNDER 1
    JIF_UPPER %1
    JIF_DIGIT %1
    cmp  al, '_'
    je   %1
%endmacro

section .text

global envfile_parse_strict
global envfile_parse_native

envfile_parse_strict:
    push rbx
    push r12
    push r13
    mov  r8, rdx                ; out

    test rsi, rsi
    jz   .skip

    mov  rcx, rsi
    mov  rdx, rdi
.blank_loop:
    movzx eax, byte [rdx]
    JIF_SPACE .blank_next
    jmp  .not_blank
.blank_next:
    inc  rdx
    dec  rcx
    jnz  .blank_loop
    jmp  .skip
.not_blank:

    movzx eax, byte [rdi]
    cmp  al, '#'
    je   .skip

    cmp  byte [rdi + rsi - 1], 13
    jne  .scan_eq
    dec  rsi

.scan_eq:
    mov  rcx, rsi
    mov  rdx, rdi
.find_eq:
    cmp  byte [rdx], '='
    je   .found_eq
    inc  rdx
    dec  rcx
    jnz  .find_eq
    mov  eax, ENVFILE_ERR_NO_EQUALS
    jmp  .ret

.found_eq:
    mov  rbx, rdx
    sub  rbx, rdi               ; key len
    mov  r13, rsi
    sub  r13, rbx
    dec  r13                    ; value len
    lea  r12, [rdx + 1]         ; value ptr

    test rbx, rbx
    jz   .check_key_trail
    movzx eax, byte [rdi]
    JIF_SPACE .key_lead_ws
    jmp  .check_key_trail
.key_lead_ws:
    mov  eax, ENVFILE_ERR_KEY_LEADING_WHITESPACE
    jmp  .ret

.check_key_trail:
    test rbx, rbx
    jz   .check_val_lead
    movzx eax, byte [rdi + rbx - 1]
    JIF_SPACE .key_trail_ws
    jmp  .check_val_lead
.key_trail_ws:
    mov  eax, ENVFILE_ERR_KEY_TRAILING_WHITESPACE
    jmp  .ret

.check_val_lead:
    test r13, r13
    jz   .validate_key
    movzx eax, byte [r12]
    JIF_SPACE .val_lead_ws
    jmp  .validate_key
.val_lead_ws:
    mov  eax, ENVFILE_ERR_VALUE_LEADING_WHITESPACE
    jmp  .ret

.validate_key:
    test rbx, rbx
    jz   .key_invalid
    movzx eax, byte [rdi]
    JIF_ALPHA .key_first_ok
    cmp  al, '_'
    jne  .key_invalid
.key_first_ok:
    mov  rcx, rbx
    dec  rcx
    mov  rdx, rdi
    inc  rdx
.key_rest_loop:
    test rcx, rcx
    jz   .value_check
    movzx eax, byte [rdx]
    JIF_ALNUM .key_rest_ok
    cmp  al, '_'
    jne  .key_invalid
.key_rest_ok:
    inc  rdx
    dec  rcx
    jmp  .key_rest_loop

.key_invalid:
    mov  eax, ENVFILE_ERR_KEY_INVALID
    jmp  .ret

.value_check:
    test r13, r13
    jz   .ok

    movzx eax, byte [r12]
    cmp  al, '"'
    je   .quoted
    cmp  al, "'"
    je   .quoted

    mov  rcx, r13
    mov  rdx, r12
.unquoted_scan:
    movzx eax, byte [rdx]
    test al, al
    jz   .bad_value
    JIF_SPACE .bad_value
    cmp  al, "'"
    je   .bad_value
    cmp  al, '"'
    je   .bad_value
    cmp  al, '\'
    je   .bad_value
    inc  rdx
    dec  rcx
    jnz  .unquoted_scan
    jmp  .ok
.bad_value:
    mov  eax, ENVFILE_ERR_VALUE_INVALID_CHAR
    jmp  .ret

.quoted:
    movzx ebx, al
    mov  rcx, r13
    dec  rcx
    mov  rdx, r12
    inc  rdx
.find_close:
    test rcx, rcx
    jz   .unterm
    cmp  [rdx], bl
    je   .found_close
    inc  rdx
    dec  rcx
    jmp  .find_close
.unterm:
    cmp  bl, '"'
    je   .unterm_dq
    mov  eax, ENVFILE_ERR_SINGLE_QUOTE_UNTERMINATED
    jmp  .ret
.unterm_dq:
    mov  eax, ENVFILE_ERR_DOUBLE_QUOTE_UNTERMINATED
    jmp  .ret
.found_close:
    dec  rcx
    test rcx, rcx
    jnz  .trailing
    lea  r12, [r12 + 1]
    mov  r13, rdx
    sub  r13, r12
    jmp  .ok
.trailing:
    mov  eax, ENVFILE_ERR_TRAILING_CONTENT
    jmp  .ret

.ok:
    mov  [r8 + 0], rdi
    mov  [r8 + 8], rbx
    mov  [r8 + 16], r12
    mov  [r8 + 24], r13
    mov  eax, ENVFILE_OK
    jmp  .ret

.skip:
    mov  eax, ENVFILE_SKIP
.ret:
    pop  r13
    pop  r12
    pop  rbx
    ret

envfile_parse_native:
    push rbx
    push r12
    push r13
    mov  r8, rdx                ; out

    test rsi, rsi
    jz   .skip_n

    mov  rcx, rsi
    mov  rdx, rdi
.blank_loop_n:
    movzx eax, byte [rdx]
    JIF_SPACE .blank_next_n
    jmp  .not_blank_n
.blank_next_n:
    inc  rdx
    dec  rcx
    jnz  .blank_loop_n
    jmp  .skip_n
.not_blank_n:

    movzx eax, byte [rdi]
    cmp  al, '#'
    je   .skip_n

    mov  rcx, rsi
    mov  rdx, rdi
.find_eq_n:
    cmp  byte [rdx], '='
    je   .found_eq_n
    inc  rdx
    dec  rcx
    jnz  .find_eq_n
    mov  eax, ENVFILE_ERR_NO_EQUALS
    jmp  .ret_n

.found_eq_n:
    mov  rbx, rdx
    sub  rbx, rdi               ; key len
    test rbx, rbx
    jz   .empty_key_n
    movzx ecx, byte [rdi]
    cmp  cl, '_'
    je   .key_rest_n
    cmp  cl, 'A'
    jb   .key_invalid_n
    cmp  cl, 'Z'
    ja   .key_invalid_n

.key_rest_n:
    mov  rcx, rbx
    dec  rcx
    mov  rdx, rdi
    inc  rdx
.key_loop_n:
    test rcx, rcx
    jz   .ok_n
    movzx eax, byte [rdx]
    JIF_UPPER_DIGIT_UNDER .key_next_n
    jmp  .key_invalid_n
.key_next_n:
    inc  rdx
    dec  rcx
    jmp  .key_loop_n

.ok_n:
    lea  r12, [rdi + rbx + 1]
    mov  r13, rsi
    sub  r13, rbx
    dec  r13
    test r13, r13
    jz   .write_n
    mov  rcx, r13
    mov  rdx, r12
.scan_n:
    movzx eax, byte [rdx]
    test al, al
    jz   .bad_value_n
    inc  rdx
    dec  rcx
    jnz  .scan_n

.write_n:
    mov  [r8 + 0], rdi
    mov  [r8 + 8], rbx
    mov  [r8 + 16], r12
    mov  [r8 + 24], r13
    mov  eax, ENVFILE_OK
    jmp  .ret_n

.empty_key_n:
    mov  eax, ENVFILE_ERR_EMPTY_KEY
    jmp  .ret_n

.key_invalid_n:
    mov  eax, ENVFILE_ERR_KEY_INVALID
    jmp  .ret_n

.bad_value_n:
    mov  eax, ENVFILE_ERR_VALUE_INVALID_CHAR
    jmp  .ret_n

.skip_n:
    mov  eax, ENVFILE_SKIP
.ret_n:
    pop  r13
    pop  r12
    pop  rbx
    ret

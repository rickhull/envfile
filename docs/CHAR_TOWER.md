# CHAR_TOWER

## Premise

This document constructs a universe of symbols by enumeration, beginning from the empty set and expanding outward. Each level is a strict superset of the previous. Each symbol is admitted when its semantic justification is established, not before.

The process is enumeration. The structure that emerges — sets, inclusions, morphisms, algebraic properties — is a consequence of the enumeration, not its goal. Set theory and category theory provide analytical tools where useful; they are not the motivation.

Each level beyond the alphanumeric introduces a qualitatively distinct expressive capability: the ability to organize, compute, reason, or self-reference. These transitions are noted where they occur.

The target is not ASCII or Unicode. The order of admission is the argument.

---

## Rationale

### Genesis

At first there was nothing. Then there was something.

### Glyph borrowing

The tower draws glyphs from existing symbol inventories. Familiar shapes reduce cognitive overhead. Borrowing a glyph does not inherit its prior meaning.

Every interpretation in this document is a formal choice made within this system. Other systems assign different meanings to the same glyphs without conflict. `:` denotes ratio in mathematics, label separator in many programming languages, time delimiter in ISO 8601. The tower assigns one interpretation per glyph per context and commits to it. Where a glyph carries more than one assigned role within this system, all roles are listed. This is documentation, not a defect.

### Sufficiency of binary

Binary is sufficient. Every number, character, document, and program that has ever existed is representable in binary to arbitrary precision. Nothing above Level 2 adds expressive power. Every level above Level 2 reduces cognitive load for human readers and writers. The tower is a translation project, not a construction of new expressive capacity.

### Cultural contingency

The tower as constructed privileges the Latin alphabet, decimal notation, and ASCII-era computing conventions. These are historical deposits, not mathematical necessities. A tower constructed under different conditions would be equally rigorous. The math is universal; the symbols are local.

---

## Foundations

### ∅ — The Empty Universe

∅ is not a character in the system. It is a statement about the system: an empty universe is possible and well-defined. In category-theoretic terms, ∅ is the initial object — there is exactly one morphism from nothing to any universe. Every level of the tower has a unique relationship back to this ground.

Distinguishing "no value" from "the value zero" is noted here explicitly, as conflating the two is a persistent source of error in symbol systems that omit this step.

---

## The Tower

### Level 0 — Nothing

**Universe:** { }

The empty set. No symbols exist.

---

### Level 1 — Unary

**Universe:** { 0 }

One symbol. Two states: the symbol present, the symbol absent. This is the complete expressive capacity of a unary system. It encodes a single binary distinction and nothing further.

---

### Level 2 — Binary

**Universe:** { 0, 1 }

Two symbols. With two distinct symbols and the ability to form sequences, the expressive universe is unbounded. Every finite string over any alphabet is encodable as a sequence over { 0, 1 }. This is not an incremental step from Level 1 — it is a phase transition. Unary encodes two states. Binary encodes infinite states. The difference is sequence.

The computational spine (base-2 → base-16 → base-64, powers of 2, bit-aligned) follows from here without further elaboration.

---

### Level 3 — Decimal

**Universe:** { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 }

Base-10. Bases 3–9 are mathematically valid but not culturally load-bearing. Decimal is a historical deposit — base-10 derives from ten fingers, not from mathematical necessity. It is admitted because the tower tracks human convention alongside formal structure.

---

### Level 4 — Hexadecimal

**Universe:** { 0–9, A, B, C, D, E, F }

Base-16. Six letters added; no case distinction at this level. 16 = 2⁴, so each hex digit maps onto exactly four bits. Two hex digits represent 256 values, corresponding precisely to one byte. The mapping is lossless and mechanical.

This is the first level where the tower performs notation rather than enumeration — choosing a representation for what binary already expressed.

---

### Level 5 — Full Latin Alphabet (no case)

**Universe:** { 0–9, A–Z }

Base-36: the union of decimal digits and the Latin alphabet. Every symbol is flat — one glyph, one value, no case.

**On base-32.** Base-32 (2⁵) is used in practice: bit-aligned, compact, case-insensitive. Its deficiency is that it requires omitting four symbols from the natural set with no principled basis for which four. The result is that base-32 has no canonical alphabet. Competing standards include RFC 4648 (A–Z plus 2–7), Crockford (0–9 plus A–Z minus I, L, O, U with aliasing), z-base-32 (ergonomic reordering), and Geohash (its own subset). Each scheme carries its alphabet as external metadata. There is no base-32 — there are several base-32s, disagreeing at the level of which symbols exist.

Base-36 has one canonical alphabet: 0–9 then A–Z, in order, no omissions, no aliasing. The alphabet is the system. It is self-describing.

**On marginal slack.** The four symbols of margin over base-32 provide capacity for: message framing (reserved symbols delimiting transmissions without appearing in payloads), error correction (symbols carrying checksums without consuming payload space), escape sequences (symbols signaling structural rather than content interpretation), and versioning or metadata. A system with no slack cannot frame its own output. The four extra symbols carry no forced meaning — their use remains open.

**On binary alignment.** Base-36 is not bit-aligned: 36 = 2² × 3². This tradeoff is accepted. The tower acknowledges two distinct lineages — the computational spine (base-2, base-16, base-64) and the human spine (base-10, base-26, base-36). Base-36 belongs to the human spine.

---

### Level 6 — The Linker and the Separator

**Universe:** { 0–9, A–Z, `_` ` ` }

Two symbols admitted as a pair: underscore and space. They are opposite in function.

`_` is a linker. It joins adjacent units while preserving their distinctness. It is visually unambiguous and carries no secondary role.

` ` (space) is a separator. It marks boundaries between words and units. It is the most frequently used character in written language. Space is structurally ambiguous — it functions simultaneously as a symbol and as the absence of a symbol — but deferral is not warranted. It is admitted with that ambiguity documented.

Hyphen was considered in place of space but rejected: hyphen and underscore are too similar in role, and the distinction between them is insufficiently stable to justify separate admission. Underscore and space are categorically distinct — one pulls together, one pushes apart.

---

### Level 7 — Case Distinction

**Universe:** { 0–9, `_` ` `, A–Z, a–z }

Lowercase introduced. Every uppercase letter acquires a lowercase twin, semantically related but distinct. The transformation applies to the alpha subset only; digits, underscore, and space are invariant.

**Total symbols at this level:** 64.

64 = 2⁶. This is a consequence of the enumeration, not a target.

---

### Level 8 — Structure

**Universe:** { previous, `,` `.` `:` `=` }

Four symbols: comma, period, colon, equals. These organize meaning rather than compute it. A complete structured document — labels, lists, sentences, assignments — is expressible with these four without arithmetic.

- `,` — enumeration and clause separation
- `.` — unit termination
- `:` — introduction; soft binding; "what follows elaborates what preceded"
- `=` — hard binding; equality or assignment

With `:` and `=`, the tower can express labeled assignments. This is the boundary at which the symbol set becomes a notation system.

**Total symbols at this level:** 68

---

### Level 9 — Arithmetic

**Universe:** { previous, `+` `-` `*` `/` }

Four arithmetic operators. Together with `=` from Level 8, these yield a complete arithmetic.

`-` is admitted on arithmetic grounds. Its secondary role as a linguistic linker (hyphen) is a consequence of glyph availability, not the justification for admission. Minus is an operator first; hyphen is a secondary assignment.

`/` carries multiple assigned roles: division here; path separator, date separator, and logical alternation in other systems.

**Total symbols at this level:** 72

---

### Level 10 — Expression

**Universe:** { previous, `(` `)` `<` `>` }

**Grouping:** `( )` — directed wrapper pair. Overrides operator precedence, delimits arguments, introduces nesting. Grouping implies depth; depth implies a stack; a stack implies stateful parsing.

**Comparison:** `<` `>` — less-than and greater-than. Together with `=` these yield a complete ordering relation. The or-equal variants (`≤` `≥`) are deferred.

Together these complete an expression language. The symbol set is now sufficient to describe the tower itself: `level_10 > level_3` is a valid expression.

`<` and `>` carry multiple assigned roles: comparison here; markup delimiters and quotation marks in other systems.

**Total symbols at this level:** 76

---

### Level 11 — Quoting

**Universe:** { previous, `"` `'` }

Two symbols: double-quote and single-quote.

`( )` wrap structure. Quotes wrap content — they reframe what is inside as reported, literal, or referenced rather than evaluated. This is the use/mention distinction. Quoting allows a system to reference its own symbols without consuming them.

`( )` are directed: open and close are visually distinct. Quotes are undirected: the same glyph serves both roles; direction is inferred from position.

`"` is the default by convention. `'` is its peer — two flavors of the same concept, alpha and alpha-prime. The justification for two is mutual embedding: each can appear unambiguously inside the other.

Users will employ these glyphs for other purposes — apostrophe, foot marks, inch marks. The tower does not restrict this. It states their primary function and nothing further. The tower is not a grammar.

Typographic directed variants (`"` `"` `'` `'`) exist and resolve the undirected ambiguity. They are not admitted here; they are noted as extensions.

**Total symbols at this level:** 78

---

### Level 12 — Interrobang and Semicolon

**Universe:** { previous, `?` `!` `;` }

**`?` `!`** — terminal marks with force. Period terminates neutrally. `?` terminates with interrogative force; `!` with exclamatory force. Both are unary postfix operators extending the terminal family. The combination `?!` expresses simultaneous interrogative and exclamatory force within the existing symbol set.

**`;`** — semi-terminator. Stronger than comma, weaker than period. Separates syntactically independent clauses held together semantically. Its role is distinct from any existing symbol. Secondary role in computing contexts: statement terminator.

**Total symbols at this level:** 81

---

### Level 13 — Domain Symbols

**Universe:** { previous, `@` `#` `$` `%` `&` }

Five sigils with pre-existing domain origins, conscripted into general use. They mark or qualify — pointing at, categorizing, or signaling the type of a thing.

- `@` — from commercial "at the rate of"; addressing, location, mention
- `#` — from the pound/number sign; tagging, numbering, hashing
- `$` — from currency; variable sigil in computing; value retrieval rather than literal name
- `%` — from per centum; ratio, modulo, encoding escape
- `&` — from Latin *et*; conjunction, reference, entity escape

**Total symbols at this level:** 86

---

### Level 14 — Extended Grouping

**Universe:** { previous, `[` `]` `{` `}` }

Two additional directed wrapper pairs.

**`[ ]`** — array indexing, optional elements, editorial insertions, list literals.

**`{ }`** — blocks, sets, dictionaries, scope delimiters.

The three directed wrapper pairs form a conventional visual hierarchy: `( )` for fine grouping, `[ ]` for collections and indexing, `{ }` for blocks and scope. The hierarchy is conventional, not mandated.

**Total symbols at this level:** 90

---

### Level 15 — Escape and Meta

**Universe:** { previous, `` ` `` `\` `|` `^` `~` }

Five computing-native symbols. None carry significant pre-computing human meanings.

- `` ` `` — backtick; raw or literal content, code spans, command substitution
- `\` — backslash; escape character; modifies interpretation of the following character
- `|` — pipe; composition and alternation; passes output of one expression as input to another
- `^` — caret; exponentiation, bitwise XOR, line-start anchor; among the most heavily reassigned symbols in the tower
- `~` — tilde; approximation, bitwise NOT, home directory convention, logical negation

**Total symbols at this level:** 95

---

### ASCII Complete

All 95 printable ASCII characters (U+0020 through U+007E) have been admitted. The order of admission is the argument.

Extension beyond ASCII is a distinct decision, not resolved here.

---

### Under Consideration — Beyond ASCII

- **Extended arithmetic** — `≤` `≥` `≠` `≈` and Unicode mathematical relations
- **Directed quotes** — `"` `"` `'` `'`; typographic resolution of the undirected quote problem
- **Unicode planes** — non-Latin scripts, mathematical symbols, emoji
- **The empty string** — distinct from ∅; a universe that produced nothing

---

## Symbol Taxonomy

Every symbol is classified on two independent axes.

### Axis 1 — Role

- **atom** — carries a value or identity; no operation performed
- **operator** — acts on operands; stateless; produces a result or relationship
- **wrapper** — opens a context requiring a matching close; stateful; introduces nesting depth

### Axis 2 — Arity (operators and wrappers only)

- **unary** — one operand or one enclosed unit
- **binary** — two operands, or a relationship between two things

`is_binary` has different semantic weight in each branch: for operators, argument count; for wrappers, whether the enclosed content is a single unit or a relationship between two things.

### Classification Table

| Symbol | Role | Arity | Our interpretation |
|--------|------|-------|--------------------|
| `0–9` | atom | — | numeric digits |
| `A–Z` `a–z` | atom | — | alphabetic identifiers |
| `_` | atom | — | linker |
| ` ` | atom | — | word boundary |
| `@` | atom | — | sigil; addressing and mention |
| `#` | atom | — | sigil; tagging and numbering |
| `$` | atom | — | sigil; value retrieval; currency |
| `%` | atom | — | sigil; ratio, modulo, encoding escape |
| `&` | atom | — | sigil; conjunction and reference |
| `+` | operator | binary | addition |
| `-` | operator | binary | subtraction; hyphen (secondary) |
| `*` | operator | binary | multiplication |
| `/` | operator | binary | division; path and date separator (secondary) |
| `=` | operator | binary | binding — equality or assignment |
| `<` | operator | binary | less-than; markup delimiter (secondary) |
| `>` | operator | binary | greater-than; markup delimiter (secondary) |
| `.` | operator | unary | postfix terminator |
| `,` | operator | unary | postfix separator |
| `;` | operator | unary | postfix semi-terminator |
| `:` | operator | binary | introduction; soft binding |
| `?` | operator | unary | postfix; interrogative force |
| `!` | operator | unary | postfix; exclamatory force; negation (secondary) |
| `` ` `` | operator | unary | prefix; raw or literal content |
| `\` | operator | unary | prefix; escape |
| `\|` | operator | binary | pipe; composition or alternation |
| `^` | operator | binary | exponentiation; XOR, anchor (secondary) |
| `~` | operator | unary | prefix; approximation, bitwise NOT |
| `(` `)` | wrapper | binary | directed; structural grouping |
| `[` `]` | wrapper | binary | directed; collections, indexing |
| `{` `}` | wrapper | binary | directed; blocks, sets, scope |
| `"` | wrapper | unary | undirected; primary quote |
| `'` | wrapper | unary | undirected; secondary quote |

Where a symbol carries more than one assigned role, secondary roles are noted parenthetically. See Rationale.

---

## Open Questions

- Is ∅ a foundational axiom below the tower, or a member of every universe within it?
- Is the tower about symbols, or about strings — sequences over a universe — which is a different and larger object?
- The empty string is distinct from ∅: ∅ is no universe; the empty string is a universe that produced nothing.
- Several glyphs carry two assigned roles within this system. Whether a single glyph should carry two roles within one system, rather than across systems, remains an open design question.

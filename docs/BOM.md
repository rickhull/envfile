# BOM Notes

This note collects the BOM details that matter to `envfile`.

It is not a general Unicode or UTF-8 reference. It only records the BOM
behavior we currently rely on in this repo.

References:

- [bin/envfile.awk](/home/rwh/git/envfile/bin/envfile.awk)
- [bin/envfile](/home/rwh/git/envfile/bin/envfile)
- [src/c/envfile.c](/home/rwh/git/envfile/src/c/envfile.c)
- [docs/PIPELINE.md](/home/rwh/git/envfile/docs/PIPELINE.md)
- [shell/normalize/bom.env](/home/rwh/git/envfile/shell/normalize/bom.env)
- [shell/normalize/bom.BOM=literal.err](/home/rwh/git/envfile/shell/normalize/bom.BOM=literal.err)
- [shell/normalize/bom.BOM=reject.err](/home/rwh/git/envfile/shell/normalize/bom.BOM=reject.err)

## What We Mean By BOM

In this project, BOM means the UTF-8 byte-order mark:

```text
EF BB BF
```

It is a byte-level file prefix, not a character we want to preserve in the
parsed content.

## Current Contract

For the reference path:

- `ENVFILE_BOM=literal` leaves a BOM at byte 0 unchanged
- `ENVFILE_BOM=strip` strips the BOM silently
- `ENVFILE_BOM=reject` treats a leading BOM as a file-fatal prepass failure

That behavior applies to `shell` and `compat`.

For `native`:

- only `ENVFILE_BOM=literal` is supported at dispatch time
- the file is treated literally
- the native parser does not do BOM preprocessing

## Warning Model

BOM handling is currently warning-free. The mode controls only normalize-stage
behavior (`literal`, `strip`, `reject`). Any future warning-stage policy should
be added separately from BOM mode selection.

## Why This Matters

A BOM at the start of a file can otherwise show up as part of the first key.
That is usually not what we want for a line-oriented environment-file format.

The repo therefore treats BOM as a prepass concern for shell-oriented formats
instead of a normal record byte.

## Awk Locale Detail

One practical lesson from the reference implementation:

- `bin/envfile.awk` uses `#!/usr/bin/env -S LC_ALL=C awk -f`
- that locale pinning was important for reliable BOM handling

Without forcing `LC_ALL=C`, awk can behave in more locale-sensitive ways than
we want for byte-oriented parsing. In practice, the BOM was easier to reason
about once awk was running in the `C` locale, because the first three bytes
stayed visible as raw input instead of being affected by multibyte/locale
behavior.

That choice is deliberate:

- BOM should be detected explicitly
- BOM should not be silently swallowed by locale behavior
- byte-oriented parsing should stay byte-oriented

## Implementation Notes

The dispatcher and C implementation both treat BOM as a whole-file prepass.

The BOM branch is intentionally separate from line parsing because:

- it only applies to byte 0 of the file
- it should happen before validate/dump/delta/apply
- it is a file-level policy decision, not a record-level one

## Practical Summary

If you are working on BOM support in this repo:

- keep it byte-oriented
- keep it as a prepass
- keep `LC_ALL=C` on the awk reference path
- keep native literal and BOM-agnostic

# Errors

This note describes the current error posture in `envfile`.

The short version:

- the dispatcher fails fast on obvious garbage and bad routing/config
- the backend may reject an entire file when it cannot be processed safely
- otherwise, the backend tries to keep going line by line and report what it
  cannot process

## Scope

There are three useful scopes for error reporting:

- **invoke** - the whole command invocation
- **file** - one input file
- **line** - one record or line

## Current behavior

### Invoke

The dispatcher handles setup and selection errors before any implementation
runs. These are plain setup failures and exit immediately.

Examples:

- `FATAL_ERROR_BAD_ARG`
  - invalid `format=`
  - invalid `action=`
  - invalid `language=`
  - unsupported `setting=`
- `FATAL_ERROR_BAD_ENVFILE_VALUE`
  - unsupported `ENVFILE_BOM` value
  - unsupported `ENVFILE_CRLF` value
  - unsupported `ENVFILE_NUL` value
  - unsupported `ENVFILE_BACKSLASH_CONTINUATION` value
- `FATAL_ERROR_NOT_FOUND`
  - missing `config=`
  - missing `env=`
  - config file not found
  - env file not found
- `FATAL_ERROR_UNSUPPORTED`
  - unsupported `format`
  - format-gating failures
  - unavailable implementation

### File

The backend may reject an entire file when the file itself is not usable.

Current file-error cases include:

- unreadable file
- rejected BOM
- rejected NUL

These stop that file, but the run may continue with later files.

The current warning case is `WARNING_BOM` when BOM handling is set to warn.
It strips the BOM, reports the warning, and keeps going.

### Line

Most other problems are line-oriented `LINE_ERROR_*` diagnostics.

The backend reports a diagnostic for the line, counts the line error, and
usually continues with the next record.

Examples:

- missing `=`
- invalid key
- invalid shell value
- unterminated quotes
- unbound substitution reference

## Output shape

Diagnostics are written to stderr.

Most line-level diagnostics include `path:lineno`, which makes it possible to
reconstruct per-file breakdowns after the fact.

At the end of the run, the reference implementation prints a summary:

```text
N checked, M errors
```

That summary is invocation-wide, not per-file.

## Direction

The intended direction is:

- keep going whenever the data is still usable
- reject whole files only when necessary
- keep the runtime simple until a stricter severity model is clearly worth it

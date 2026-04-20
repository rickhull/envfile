# POSIX Notes

This note collects the POSIX details that matter to `envfile/native`.

It is not a full POSIX reference. It only captures the environment-model
rules that shape the native format contract.

References:

- [POSIX Environment Variables](https://pubs.opengroup.org/onlinepubs/9799919799/basedefs/V1_chap08.html)
- [Rationale for Base Definitions](https://pubs.opengroup.org/onlinepubs/9799919799/xrat/V4_xbd_chap01.html)

## Environment Model

POSIX environment entries are `name=value` strings.

From the Base Definitions page:

- the value of an environment variable is an arbitrary sequence of bytes,
  except for NUL
- names shall not contain `=`
- there is no meaning associated with the order of strings in the environment
- if more than one string has the same name, the consequences are undefined

For `envfile/native`, that means:

- the file is a line-oriented serialization of environment entries
- the parser should preserve the name and value bytes as written
- lowercase names are not inherently invalid at the environment-model level
- duplicate names should be treated as a format policy choice, not as a POSIX
  naming violation

## Shell vs Application Names

POSIX distinguishes between:

- the general environment model
- the stricter name subset used by shell utilities

The shell-utility subset is the one that says names consist solely of uppercase
letters, digits, and underscore, and do not begin with a digit.

The rationale page is explicit that this restriction exists so applications can
use lowercase names without conflicting with conforming shell utilities.
Applications shall tolerate the presence of such names.

For `envfile/native`, that means:

- the shell-utility uppercase rule is not the native validation rule
- lowercase names should be accepted
- leading digits and other non-`=` punctuation are not automatically invalid
- the native format should follow the environment-model rule, not the shell-
  utility naming subset

## Native Format Implications

The native format should reflect the environment block as directly as
possible:

- accept `name=value` records as environment entries
- reject empty keys
- reject `=` in the name
- reject NUL and newline in the file representation
- preserve bytes rather than interpret them

This keeps native aligned with the POSIX environment model instead of shell
syntax.

## C `environ`

For C programs, POSIX exposes the process environment through `environ`
(`extern char **environ;` in practice).

That matters because `envfile/native` is intended to behave like a serialized
environment block:

- environment blocks are not ordered data structures
- the representation is a sequence of strings
- the native file should be a textual stand-in for that sequence

## Practical Reading

If you are deciding whether something belongs in `native` or `shell`:

- `native` follows the environment model
- `shell` follows shell-utility naming and syntax discipline

That split is deliberate. It keeps native close to the process environment and
keeps shell-specific policy out of the native format.

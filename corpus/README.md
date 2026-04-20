# corpus

Real-world env files collected from local machines, sanitized, normalized, and
checked into git as a shared regression corpus for the validator.

The corpus is not a snapshot of one host. It is an accumulating dataset built
from many hosts over time. New contributors can run discovery in their own
environment, merge in newly accepted files, and re-collapse the tree into the
same compact layout.

## Mental model

There are two different kinds of artifacts in this directory:

- `files/` is the durable product. It is checked in, shared, and expected to
  survive across machines and users.
- `explored.txt` and `filtered.txt` are staging artifacts. They are inspectable
  and useful for debugging, but they represent one local generation run, not
  durable corpus state.

That distinction matters:

- `files/` is a persistent merged corpus.
- `explored.txt` is accumulated input to one filtering pass.
- `filtered.txt` is the accepted subset for one collect pass.

The pipeline is intentionally designed so the final committed corpus can grow
even when contributors discover files from very different absolute paths.

## Primary workflow

Run the full pipeline:

```sh
just corpus::generate
```

This does:

1. `clean`
2. `explore_all`
3. `filter`
4. `collect`
5. `collapse`

`generate` starts from a clean staging state and a clean corpus output
directory, then rebuilds the local result in one invocation graph.

## Pipeline stages

### 1. Explore

Explore recipes discover candidate env-like files and accumulate them into
`corpus/explored.txt`.

Current explore strategies:

- `explore_home` scans `$HOME`
- `explore_root` scans `/`
- `explore_systemd` walks systemd unit files and follows `EnvironmentFile=`
  references
- `explore_shellconf` searches for shell config filenames matching
  `*conf*.sh` case-insensitively

The generic explore pass uses `rg --files` with:

- a maximum file size of `5K`
- a broad filename blacklist to skip obviously irrelevant formats
- `rg -l '='` to retain text files containing at least one assignment

Each explore recipe appends into the same `explored.txt` and deduplicates as it
goes. This is deliberate: exploration is now an accumulation phase, not a
series of isolated pipelines.

Useful commands:

```sh
just corpus::explore_home
just corpus::explore_root
just corpus::explore_systemd
just corpus::explore_shellconf
just corpus::explore_all
```

If you want to clear only staged explore/filter state without deleting the
corpus tree, use:

```sh
just corpus::clean-state
```

## 2. Filter

`filter` reads `explored.txt`, runs the current shell acceptance validator,
and writes accepted
paths to `filtered.txt`.

The filter is intentionally permissive for messy real-world input. It accepts a
file when both its error rate and warning rate stay under the size-tiered
thresholds below.

### Acceptance thresholds

| Size     | Max error rate | Max warning rate |
|----------|----------------|------------------|
| < 100B   | 10%            | 10%              |
| < 500B   | 25%            | 25%              |
| < 1KB    | 50%            | 50%              |
| >= 1KB   | 75%            | 75%              |

`filter` also deduplicates overlay-backed paths by logical path, so the same
underlying file is not counted repeatedly just because it appeared through
different overlay mount paths.

## 3. Collect

`collect` reads `filtered.txt`, sanitizes sensitive-looking content, and copies
accepted files into `corpus/files/` using a chroot-style mirror of the source
path.

Important details:

- source paths under `/home/<user>/...` are normalized to `/home/user/...`
  before being copied, so the committed corpus does not depend on a specific
  local username
- suspicious keys and values are rewritten using NATO-style replacement words
- suspicious values are also distorted by mirroring the first half of the value
- collection skips destination paths that already exist in `corpus/files/`

That last point is important. `collect` is merge-oriented, not rebuild-from-
scratch by default. In the full `generate` flow this is fine because `clean`
runs first. In ad hoc manual flows, existing files in `corpus/files/` are
treated as already collected corpus content.

## 4. Collapse

`collapse` is the normalization step that makes the shared corpus practical.

The collected tree begins as a chroot mirror of source paths, which can be very
deep and host-specific. `collapse` moves each file to the shallowest position
possible without overwriting another file.

Candidate order for a file at `a/b/c/foo` is:

1. `foo`
2. `c/foo`
3. `b/c/foo`
4. stay at `a/b/c/foo`

Constraints:

- a file may only use suffixes of its own ancestor path
- no new directory names are invented
- no existing file is overwritten
- deeper files are processed first

This lets the committed corpus converge toward a compact shared layout while
still accepting files from very different machines.

### Why collapse is central to the shared-corpus model

Assume the repo already contains a committed collapsed corpus from machine A.
Now a contributor on machine B runs `generate` and discovers new files under
different absolute paths. The new files are first collected into their mirrored
pre-collapse locations, then `collapse` re-normalizes the entire tree.

That gives a robust multi-contributor workflow:

- existing committed files remain in the corpus
- newly discovered files are merged in
- the whole corpus is compressed back toward minimal path depth
- host-specific path depth does not permanently bloat the tree

In other words, the corpus grows by union, then normalizes by collapse.

## Directory scoring

`collapse` also writes `corpus/scores.txt`.

The scores are generated from the final collapsed corpus layout, not from a
single explore strategy. This is preferable because collapse already walks the
entire corpus tree, and the resulting score file reflects the committed
post-normalization corpus rather than a transient pre-collapse source view.

## Files

- `files/` — sanitized corpus files, checked in
- `scores.txt` — counts of files per directory in the final collapsed corpus
- `explored.txt` — accumulated discovery state for one local run
- `filtered.txt` — accepted paths for one local run

## Working with `just`

One subtlety matters here: `just` de-duplicates recipe execution within a
single invocation graph.

That means:

- recipe dependencies like `generate: clean explore_all filter collect collapse`
  are executed at most once in that invocation
- a recipe body that shells out to `just ...` starts a new invocation, so its
  dependencies may run again

This repository treats that behavior seriously. The main generation flow is
expressed through recipe dependencies rather than nested `just` subprocesses so
that side-effectful steps do not silently re-run.

## Developer guidance

When changing this pipeline, preserve these invariants:

- `generate` should remain deterministic from a clean checkout
- `explored.txt` and `filtered.txt` should remain easy to inspect for debugging
- `files/` should remain the only durable corpus artifact
- collapse must remain overwrite-free
- collapse must try the shallowest valid suffix first
- cross-machine contributions should not depend on a specific username or exact
  source root depth

Questions to ask when making changes:

- Is this file a transient staging artifact or durable corpus state?
- Does this step append, overwrite, or merge? Is that obvious from the recipe?
- Would this still behave sensibly if run from a different machine with a
  partially populated committed corpus?
- Does the final tree get smaller or more host-specific over time?

## Suggested manual workflows

Inspect discovery only:

```sh
just corpus::clean-state
just corpus::explore_all
sed -n '1,120p' corpus/explored.txt
```

Inspect accepted files before collection:

```sh
just corpus::filter
sed -n '1,120p' corpus/filtered.txt
```

Run the whole pipeline:

```sh
just corpus::generate
```

Reset everything:

```sh
just corpus::clean
```

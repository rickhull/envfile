# Data gathering — env files from the wild

The goal is a large, diverse corpus of real env files for testing validator
correctness, measuring real-world error rates, and discovering edge cases
that synthetic fixtures miss.

## File discovery heuristics

### Filename patterns

The strongest signal is the filename itself:

- `.env`, `.env.example`, `.env.sample`, `.env.template`
- `.env.local`, `.env.production`, `.env.test`, `.env.development`
- `*.env` (e.g. `database.env`, `app.env`)

Prefer `.env.example` and `.env.sample` — they are intentionally public,
unlikely to contain real secrets, and common in open-source repos.

### Path context

Env files appear most often at the repo root, and less commonly under
`config/`, `docker/`, or `deploy/`. Repo root is the highest-signal
location.

### Adjacent signals

The presence of certain files in the same repo raises confidence that
env files will be present and meaningful:

| File | Ecosystem |
|---|---|
| `Dockerfile`, `docker-compose.yml` | containers |
| `Procfile` | Heroku / 12-factor |
| `package.json` with `dotenv` dep | Node |
| `requirements.txt` / `pyproject.toml` with `python-dotenv` | Python |
| `.ruby-version`, `Gemfile` with `dotenv` | Rails |
| `app.json` | Heroku |
| `*.service` (systemd unit files) | systemd |

## Ecosystem-specific sources

### Docker / Compose

`docker-compose.yml` files contain `env_file:` directives that name env
files explicitly — a machine-parseable pointer to exactly the right file.

```yaml
env_file:
  - .env
  - config/app.env
```

Search Compose files for `env_file:`, extract the paths, fetch the files.

### systemd

Unit files use `EnvironmentFile=` with an explicit path:

```ini
EnvironmentFile=/etc/myapp/env
EnvironmentFile=-/etc/myapp/env.local
```

Distributions ship unit files in packages; these can be extracted from
package archives (`.deb`, `.rpm`) without running anything.

### Heroku / 12-factor apps

`app.json` declares required env var names (but not values) in its `env`
block — useful for key name corpora even without values. Repos with a
`Procfile` at root almost always have a `.env.example`.

### Rails

`dotenv-rails` in `Gemfile` is a reliable signal. Rails projects
conventionally keep `.env.example` in version control and `.env` in
`.gitignore`.

### Kubernetes / Podman

`--env-file` flags in shell scripts and `envFrom` / `env` blocks in
manifests point to env files. ConfigMaps with `env:` entries are a rich
source of real-world key names, though values are often templated.

### Ansible / Terraform

Both use environment variable patterns in their configs. Ansible `environment:`
blocks and Terraform `.tfvars` files follow similar key=value conventions
and are worth examining for overlap and divergence.

## Public code search

### GitHub code search

GitHub's code search supports filename filters:

```
filename:.env.example
filename:.env.sample
```

The GitHub API allows programmatic search and download. Rate limits apply;
authenticated requests get higher limits.

### BigQuery (GitHub public dataset)

The `githubarchive` public dataset on BigQuery contains file contents for
many public repos. A query for files named `.env.example` at repo root
can return a large corpus without per-repo API calls.

### Sourcegraph / grep.app

Both index public code and support filename and content search. Useful for
spot-checking patterns before committing to bulk download.

### Software Heritage

Archives public source code at scale, with stable identifiers. Slower to
query but comprehensive.

## Quality signals

When ranking or filtering collected files:

- **Prefer example/sample files** over `.env` — lower secret risk, higher
  sharing intent
- **Repo popularity** (stars, forks) correlates with code quality and
  careful env file conventions
- **Multiple env files per repo** — richer variety of keys and value forms
- **File size** — very large files may be generated or unusual; very small
  files (1-2 lines) may not be representative
- **Deduplication** — forked repos often copy env files verbatim; deduplicate
  by content hash

## Synthetic augmentation

Real corpora may underrepresent certain edge cases. Supplement with
synthetic files generated from:

- Key names mined from real sources (Docker Hub image docs, Heroku
  buildpack configs, popular framework documentation)
- Systematic coverage of all value forms: empty, unquoted, single-quoted,
  double-quoted, with embedded `=`, with unicode
- Deliberate invalid cases: each error condition from the spec, in
  isolation and in combination

## Benchmarking use

The current benchmark invokes each validator once per file per iteration,
which means startup cost dominates — especially for Ruby, Python, and
Nushell where runtime initialization is significant. The numbers reflect
"how fast can you run this tool" more than "how fast is the parsing".

A large corpus changes this: passing hundreds or thousands of files in a
single invocation amortises startup to near zero, and the benchmark
measures actual parsing throughput. This is the more meaningful number
for comparing algorithmic and I/O efficiency across implementations.

Target corpus size: enough files that the slowest impl (Ruby, ~20
iter/s on a single file) spends at least several seconds on one
invocation — a few hundred files is sufficient; a few thousand is better.

The bench script should be updated to support a corpus mode:

```sh
python3 bin/bench --corpus corpus/files/
```

which collects all candidate files under the corpus directory and passes
them all to a single validator invocation per iteration.

## Privacy and legal

- Never collect files that appear to contain real secrets (long random
  strings as values, keys named `*_KEY`, `*_SECRET`, `*_TOKEN` with
  non-placeholder values)
- Respect repo licenses — data gathered for testing/research is generally
  covered by fair use, but be conservative
- Prefer files explicitly committed to public repos over anything scraped
  from deployed systems

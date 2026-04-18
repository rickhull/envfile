# Corpus

`corpus/files/` is the durable artifact — real-world `.env` files collected
from multiple machines and public sources, checked into the repo as a chroot
mirror of their source paths.

## Pipeline

```
clean → explore → filter → collect
```

Run the full pipeline:

```sh
just corpus::generate
```

Or individual stages:

```sh
just corpus::explore_all   # discovery only
just corpus::clean         # reset staging state
```

Staging files (`explored.txt`, `filtered.txt`) are transient. Only
`corpus/files/` is committed.

## Sanitization

Values are replaced with NATO-alphabet placeholders; usernames are
normalized. No real secrets are retained.

## Directory scoring

```sh
just corpus::score
```

Counts files per source directory across the full corpus tree. Run
on-demand; nothing is persisted.

## Layout

```
corpus/
  files/        # durable corpus (committed)
  explored.txt  # staging: discovery results
  filtered.txt  # staging: post-filter candidates
```

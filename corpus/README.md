# corpus

Real-world env files collected from the local filesystem, used to validate linter behaviour against diverse inputs.

## Pipeline

```
just -f corpus.just generate
```

Runs two explore strategies, each feeding the same filter → collect stages:

1. **explore_systemd** — walks `/` for `.service`/`.timer`/`.socket`/`.mount` files, chases `EnvironmentFile=` references to find explicitly declared env files
2. **explore** — uses `rg --files` to find candidate files under `/` by size (≤1K) and filename blacklist, then `xargs rg -l '='` to keep text files containing at least one assignment

Each strategy writes `explored.txt`, then:

- **filter** — lints each path, applies size-tiered acceptance thresholds for both error and warning rates; writes `filtered.txt`
- **collect** — sanitizes sensitive lines (bad-word substitution + value halving), copies to `corpus/files/`

### Acceptance thresholds

| Size     | Max error rate | Max warning rate |
|----------|---------------|-----------------|
| < 100B   | 10%           | 10%             |
| < 300B   | 25%           | 25%             |
| ≥ 300B   | 50%           | 50%             |

## Files

- `files/` — sanitized corpus files (checked in)
- `scores.txt` — directory scores from the root explore (accepted files per dir)
- `systemd_scores.txt` — directory scores from the systemd explore
- `explored.txt`, `filtered.txt` — intermediate pipeline state (not checked in)

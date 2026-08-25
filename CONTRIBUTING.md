# Contributing

## Version bump checklist

When cutting a new release (e.g. `v1.2.0`), update the version string in these files:

| File | What to change | Example |
|------|---------------|---------|
| `scripts/setup.sh` | `NUTWATCH_REF` default (line ~36) | `NUTWATCH_REF="${NUTWATCH_REF:-v1.2.0}"` |
| `vm/nut-vm.sh` | `NUTWATCH_REF` default (line ~175) | `readonly NUTWATCH_REF="${NUTWATCH_REF:-v1.2.0}"` |
| `src/frontend/package.json` | `version` field | `"version": "1.2.0"` |
| `src/frontend/src/constants/index.ts` | `APP_VERSION` constant (line ~99) | `export const APP_VERSION = 'v1.2.0';` |
| `README.md` | `NUTWATCH_REF` in both env tables (lines ~375, ~451) | `\| \`NUTWATCH_REF\` \| \`v1.2.0\` \| ...` |
| `README.md` | Docker image tag table in the Docker section | `\| \`1.2.0\`, \`1.2\`, \`1\` \| Specific release ... \|` |

Also check `scripts/setup.sh` for version strings in the header comment (line ~14) and the help output (line ~715).

`vm/nut-vm.sh` has a separate `SCRIPT_VERSION` constant (line ~174) that is independent of `NUTWATCH_REF` — bump it only if the VM script itself has changed.

## Git tags and releases

- Tags use the format `v*.*.*` (e.g. `v1.1.0`).
- The GitHub Release tag triggers the `.github/workflows/release.yml` workflow, which builds and publishes the NutWatch tarball.
- **Tags must be ancestors of `origin/main`.** The CI workflow (`check-tag-branch` job) enforces this before any downstream jobs run. If a tag is pushed from a feature branch, the release is rejected.
- The `NUTWATCH_REF` variable in the scripts points to the Git tag, which maps to the release download URL at `https://github.com/JuanCF/nutwatch/releases/download/<tag>/nutwatch.tar.gz`.
- The same tag also triggers `.github/workflows/docker-publish.yml`, which pushes the multi-arch image to `ghcr.io/juancf/nutwatch` as `:<version>`, `:<major>.<minor>`, `:<major>`, and `:latest`. Pushes to `main` publish `:main`. Both use the built-in `GITHUB_TOKEN`; no registry secrets are needed.

## Commit conventions

The version bump is typically done in two commits:

1. **Version bump commit** — updates the version number itself (`package.json`, `constants/index.ts`).
2. **NUTWATCH_REF bump commit** — updates all references to the old tag across `vm/nut-vm.sh`, `scripts/setup.sh`, and `README.md`.

This pattern ensures the new version is self-referencing before the release tag is created.

## CI

```bash
make check   # full suite: shellcheck + shfmt + Python lint + pytest + tsc-check + frontend lint + frontend tests
```

See `AGENTS.md` for the full list of developer commands.
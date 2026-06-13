# ops

Single source of truth for the **salt-mountain repo baseline** — the security &
DevOps foundation every repo starts from and stays aligned to.

## What's here

| Path | Role |
| --- | --- |
| `.github/workflows/verify.yml` | The **reusable CI** every repo calls — build, format, typecheck, test, dependency-review |
| `baseline/` | The **config files** seeded into each repo (Dependabot, Prettier, EditorConfig, `.vscode`, CODEOWNERS) |
| `bootstrap.sh` | Creates or syncs a repo and applies the **settings** files can't carry: branch protection, merge hygiene, security toggles, hardened Actions permissions |

## Using it

```sh
./bootstrap.sh my-new-site --create --public   # new repo, fully hardened
./bootstrap.sh mogarmory --private             # re-apply to an existing repo (opens a PR)
```

`bootstrap.sh` is idempotent — the same command bootstraps a new repo or
re-asserts the standard on an existing one (the drift-fixer). New repos get the
baseline on their default branch and protected; existing protected repos get it
as a PR. It also reports any required CI scripts missing from the target's
`package.json`. Flags: `--create`, `--public`/`--private`, `--owner <login>`,
`--no-files`, `--no-settings`.

A consumer ends up with the seeded configs plus a thin CI caller pinned to this
repo's reusable workflow:

```yaml
jobs:
  verify:
    uses: salt-mountain/ops/.github/workflows/verify.yml@<sha> # v1
    with:
      dependency_review: true # public repos only; private repos have no `with:`
```

Every repo runs the **same** checks — `format:check`, `check`, `test`, `build` —
so they are **not** toggleable; a repo missing one of those scripts fails CI by
design (the standard being enforced). Test-less repos define a no-op `test`, and
`bootstrap.sh` flags any missing scripts when you baseline a repo. The only
inputs are `bun_version` (the fleet's CI Bun version — single source, bump in
`verify.yml`), `dependency_review` (public-only, set by visibility), and
`extra_scripts` (additive — runs *on top of* the standard set). Bun steps are
gated on a `package.json` existing, so a project-less repo stays green.

## How pins stay current (no hand-bumping)

Every pinned action lives only in `.github/workflows/` here, so this repo's
Dependabot keeps the whole fleet's pins fresh in one PR. Consumers pin the
reusable workflow by SHA with a `# v1` comment, so their own Dependabot bumps it
when this repo cuts a new release. Roll out a baseline change by tagging a
release; consumers update via a reviewed Dependabot PR. (The CI Bun version lives
in `verify.yml`, so it rides this same flow.)

## Notes

- A reusable-workflow check reports as `verify / verify` — the single required
  status context for every repo.
- `ops` is public so private repos can call its reusable workflow without
  per-repo Actions-access configuration.

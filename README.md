# ops

Single source of truth for the **salt-mountain repo baseline** — the security &
DevOps foundation every repo starts from and stays aligned to. The goal: version
updates and CVE fixes merge and deploy themselves when CI is green, and a human
is only needed when something genuinely breaks.

## What's here

| Path                           | Role                                                                                                                                                                                                                                      |
| ------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `.github/workflows/verify.yml` | The **reusable CI** every repo calls on PRs and on `main` — Bun pin check, install, format, typecheck, build, test, Docker image build, dependency-review, failure alerts                                                                 |
| `baseline/`                    | The **config files** seeded into each repo: `common/` for every repo (Dependabot, Renovate, the Dependabot auto-merge workflow, Prettier ignores, EditorConfig) plus one framework layer, `astro/` or `vue/` (Prettier config, `.vscode`) |
| `bootstrap.sh`                 | Creates or syncs a repo and applies the **settings** files can't carry: branch protection, auto-merge, merge hygiene, security toggles, hardened Actions permissions. `--dry-run` previews without changing anything                      |
| `set-automerge-secrets.sh`     | Stores the auto-merge app's credentials as Dependabot secrets on one or more repos                                                                                                                                                        |

## Using it

```sh
./bootstrap.sh my-new-site --create --public --framework astro   # new repo, fully hardened
./bootstrap.sh mogarmory --private --dry-run                      # preview: changes nothing
./bootstrap.sh mogarmory --private                                # re-apply to an existing repo (opens a PR)
```

`bootstrap.sh` is idempotent — the same command bootstraps a new repo or
re-asserts the standard on an existing one. Settings are re-applied on every
run. Files are **only added where missing, never overwritten**: repos
legitimately customise them (extra Dependabot directories, Renovate rules,
Prettier ignores, a CI caller with `extra_scripts`), so any existing file that
differs from the baseline is listed as `kept` for you to reconcile by hand. An
existing `ci.yml` that doesn't call `verify.yml` yet is kept too — migrate it
manually. Until it does, the repo keeps its current required checks and its
"require up to date" setting, auto-merge stays off, and `automerge.yml` /
`renovate.json` are **held** (listed, not added): bot PRs mustn't start merging
on an old CI that doesn't gate deploys. The framework
layer is detected from `package.json` (`astro`, else `vue`); override with
`--framework astro|vue|none`, e.g. for a brand-new repo with no `package.json`
yet.

**Always dry-run first** (`--dry-run`). It clones into a temp dir and only reads
from GitHub: it lists the files it would add (full diff saved to a file), shows
every setting as current -> planned (`~` marks a change), and warns about
anything a real run would remove — the branch-protection update replaces the
whole rule, so hand-set extras like required linear history or signed commits
would be dropped.

New repos get the baseline on their default branch and protected; existing
protected repos get it as a PR. It also reports missing required CI scripts and
missing auto-merge secrets. Flags: `--create`, `--public`/`--private`,
`--owner <login>`, `--framework <f>`, `--no-files`, `--no-settings`,
`--dry-run`. Requires `gh`, `git` and `jq`.

A consumer ends up with the seeded configs plus a thin CI caller pinned to a
release of this repo's reusable workflow:

```yaml
on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read
  issues: write # failure alert issue
  pull-requests: write # public repos only: dependency-review comment

jobs:
  verify:
    uses: salt-mountain/ops/.github/workflows/verify.yml@<sha> # v1.1.1
    with:
      dependency_review: true # public repos only

  deploy: # repos that deploy: only after verify passes on main
    needs: verify
    if: github.event_name == 'push'
    # ...
```

Every repo runs the **same** checks — `format:check`, `check`, `build`, `test`,
in that order — so they are **not** toggleable; a repo missing one of those
scripts fails CI by design. `build` runs before `test` so tests can check the
built output (e.g. smoke tests over `dist/`). Prefer real smoke tests over a
no-op `test`: bot updates auto-merge and deploy on green, so "it built" should
mean "the site works". Beyond those, `verify.yml`:

- **Checks the Bun pins agree.** `package.json` `packageManager` is the repo's
  one Bun version (setup-bun and deploy workflows read it); `.bun-version` and
  any `oven/bun:<version>` Dockerfile tag must match it.
- **Installs every committed `bun.lock`** with `--frozen-lockfile` (e.g. a CDK
  app in `infra/`), not just the root.
- **Builds the Docker image** (no push) if the repo has a root `Dockerfile`.
- **Scans the build output for secrets** right after the build: fails if
  `output_dir` (default `dist/`) contains secret-looking files (`.env*`,
  `.dev.vars`, keys, `.git/`, `cdk-outputs.json`, …) or anything
  [betterleaks](https://github.com/betterleaks/betterleaks) (the gitleaks
  author's successor) recognises as a credential
  (redacted in the log). Deploys need verify, so a leaked key never reaches the
  live site. This covers what GitHub secret scanning can't: keys baked into
  bundles at build time never touch git. A false positive goes in a
  `.betterleaksignore` (or `.gitleaksignore`) at the repo root (one finding
  fingerprint per line). The betterleaks version and checksum are pinned in
  `verify.yml`; this repo's own `renovate.json` bumps both together (and
  verify's `node_version` default).
- **Alerts on `main`.** A failed run on `main` opens (or comments on) a
  `ci-failure` issue assigned to the owner; the next green run closes it. Merges
  are mostly bots, and GitHub only emails the actor about failed runs.
- **Reports failed bot PRs.** When verify fails on a Dependabot or Renovate
  PR, it posts one comment that @mentions the owner, with the failed step, the
  last lines of its output and a link to the run, so the single email already
  says what broke. Later failures edit that comment (no new email); a later
  green run marks it resolved. The `ci-failure` issue on `main` carries the same
  summary. With repos watched as "Participating and @mentions", these are the
  only bot emails you get. The baseline has no CODEOWNERS for the same reason
  (every review request emails); add one by hand to repos that take outside
  contributions.

Inputs: `node_version` (default `24`, the current Active LTS; match your deploy
workflow),
`dependency_review` (public-only, set by visibility), `extra_scripts`
(additive — runs _on top of_ the standard set), `build_env` (non-secret
`KEY=VALUE` lines exported for install/build/test, e.g. placeholder `VITE_*`
values: a bundler that bakes in a missing value can tree-shake the whole app
away and still "build"), and `output_dir` (the deployed build output that gets
secret-scanned; default `dist`). Bun steps are gated on a `package.json`
existing, so a project-less repo stays green.

## How updates flow

| Who                         | What                                                                                                                                      | Auto-merges   |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- | ------------- |
| Dependabot security updates | CVE fixes in packages (no cooldown)                                                                                                       | patch + minor |
| Dependabot version updates  | packages and GitHub Actions pins, grouped into one PR per run, after a 7-day cooldown (30 for majors)                                     | patch + minor |
| Renovate (Mend app)         | version strings Dependabot can't see — Bun pins by default, plus whatever a repo adds to its `renovate.json` — after the same release age | Bun patches   |

Majors (and Bun minors) always wait for a human. Auto-merge only ever merges a
green PR, so a breaking update becomes a red PR to look at, never a broken
`main`.

Branch protection requires `verify / verify` but **not** up-to-date branches:
with several bot PRs auto-merging, strict mode would stall every PR behind each
merge, and merge queues aren't available on personal accounts. The trade-off is
that two individually green PRs can break `main` together. `verify` on `main`
catches that before any deploy runs, and opens the alert issue; open PRs' CI
then fails until `main` is fixed, so auto-merge pauses rather than piling on.

Each repo owns its `renovate.json` (seeded from `baseline/common/`), so
baseline changes to it don't propagate — re-run `bootstrap.sh` to see which
repos differ, and reconcile by hand.

Action pins in `verify.yml` are kept current by this repo's Dependabot.
Consumers pin `verify.yml` by SHA with a `# vX.Y.Z` comment, which their
Dependabot bumps when this repo tags a release. Roll out a `verify.yml` change
by tagging a release.

## One-time setup

**Mend Renovate app.** Install https://github.com/apps/renovate on the repos
that should get Renovate PRs ("Only select repositories"), including `ops`
itself, whose `renovate.json` tracks the betterleaks pin and the `node_version`
default in `verify.yml` (never auto-merged: review, merge, then tag). Do it after the
repo's `renovate.json` is on `main`; otherwise Mend opens an onboarding PR with
its own defaults — close that unmerged.

**Auto-merge GitHub App** (Dependabot can't merge its own PRs, and a merge
enabled with `GITHUB_TOKEN` doesn't trigger the push workflows that verify and
deploy `main`):

1. https://github.com/settings/apps/new — any name (e.g.
   `salt-mountain-automerge`), any homepage URL, **uncheck** Webhook "Active".
2. Repository permissions: **Contents**, **Pull requests** and **Workflows**:
   read and write. Nothing else. "Only on this account".
3. Create it, note the **Client ID**, and generate a **private key** (`.pem`).
4. Install it on the same repos ("Only select repositories").
5. Store both as **Dependabot** secrets on each repo (Dependabot-triggered
   workflows can't read Actions secrets). `set-automerge-secrets.sh` first
   checks the credentials and that the app is installed on each repo, and skips
   repos it isn't installed on:

   ```sh
   export AUTOMERGE_APP_CLIENT_ID=Iv23...
   export AUTOMERGE_APP_PRIVATE_KEY_PATH=~/secure/automerge.private-key.pem
   ./set-automerge-secrets.sh --dry-run osim.dev blackcatlandmanagement   # check only
   ./set-automerge-secrets.sh osim.dev blackcatlandmanagement             # or: --all
   ```

   Re-run it for every repo after rotating the app's private key.

Without the secrets, `automerge.yml` warns and does nothing.

## Notes

- A reusable-workflow check reports as `verify / verify` — the single required
  status context for every repo.
- `ops` is public so private repos can call its reusable workflow without
  per-repo Actions-access configuration.

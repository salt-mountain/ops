#!/usr/bin/env bash
#
# bootstrap.sh — apply the salt-mountain repo baseline to a repo.
#
# Seeds the canonical config files (baseline/) and applies the repo *settings* a
# template can't carry: branch protection, auto-merge, merge hygiene, security
# toggles, and hardened Actions permissions. Every step is idempotent. Settings are
# re-asserted on every run; files are only added where missing. A file that
# already exists but differs from the baseline is reported, never overwritten —
# repos legitimately customise them (extra Dependabot directories, Prettier
# ignores, a CI caller with extra_scripts).
#
# Baseline files come in layers: baseline/common/ for every repo, plus
# baseline/<framework>/ (astro or vue), auto-detected from package.json.
#
# Usage:
#   ./bootstrap.sh <repo> [options]
#
# Options:
#   --create        Create the GitHub repo first (gh repo create).
#   --public        Public repo: enables dependency-review + CodeQL + secret scanning.
#   --private       Private repo (default).
#   --owner <login> GitHub owner (default: salt-mountain).
#   --framework <f> astro | vue | none (default: detect from package.json).
#   --no-files      Only apply settings; don't seed baseline files.
#   --no-settings   Only seed files; don't touch gh-api settings.
#   --dry-run       Change nothing: show which files would be added (full diff
#                   saved to a file) and each setting as current -> planned,
#                   including branch-protection settings the run would remove.
#   -h, --help      Show this help.
#
# Every repo runs the same CI checks (format:check, check, test, build); this
# script reports any of those scripts missing from the target's package.json.
#
# Examples:
#   ./bootstrap.sh my-new-site --create --public --framework astro
#   ./bootstrap.sh mogarmory --private --dry-run   # preview first
#   ./bootstrap.sh mogarmory --private             # then apply
#
set -euo pipefail

OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASELINE="$OPS_DIR/baseline"
OPS_OWNER="salt-mountain"
OPS_SLUG="salt-mountain/ops" # where verify.yml lives; consumers reference it

# ---- args -------------------------------------------------------------------
OWNER="$OPS_OWNER"
REPO=""
VISIBILITY="private"
CREATE=false
DO_FILES=true
DO_SETTINGS=true
DRY_RUN=false
FRAMEWORK="" # empty = detect from package.json
SYNC_BRANCH="chore/baseline-sync"

# Repo merge settings, as `key=value` pairs. Used both to apply them and to
# show current -> planned in a dry run, so the two can't disagree. Auto-merge
# is only switched on once the repo's CI calls verify.yml (see on_verify).
REPO_SETTINGS="allow_squash_merge=true allow_merge_commit=false allow_rebase_merge=false delete_branch_on_merge=true"
repo_settings() {
  if on_verify; then echo "$REPO_SETTINGS allow_auto_merge=true"; else echo "$REPO_SETTINGS"; fi
}

# Print the header comment block (line 2 up to the first non-comment line).
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --create) CREATE=true ;;
    --public) VISIBILITY="public" ;;
    --private) VISIBILITY="private" ;;
    --owner) OWNER="$2"; shift ;;
    --framework) FRAMEWORK="${2:-}"; shift ;;
    --no-files) DO_FILES=false ;;
    --no-settings) DO_SETTINGS=false ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) REPO="$1" ;;
  esac
  shift
done

[ -n "$REPO" ] || { echo "error: repo name required" >&2; usage; exit 2; }
case "$FRAMEWORK" in
  "" | astro | vue | none) ;;
  *) echo "error: --framework must be astro, vue or none (got '$FRAMEWORK')" >&2; exit 2 ;;
esac
SLUG="$OWNER/$REPO"

# ---- preflight --------------------------------------------------------------
command -v gh >/dev/null || { echo "error: gh CLI required" >&2; exit 1; }
command -v git >/dev/null || { echo "error: git required" >&2; exit 1; }
command -v jq >/dev/null || { echo "error: jq required" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "error: run 'gh auth login' first" >&2; exit 1; }

if $DRY_RUN; then
  echo "▸ DRY RUN for $SLUG  (visibility=$VISIBILITY create=$CREATE) — nothing will be changed"
else
  echo "▸ bootstrapping $SLUG  (visibility=$VISIBILITY create=$CREATE)"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---- create -----------------------------------------------------------------
if $CREATE; then
  if $DRY_RUN; then
    if gh repo view "$SLUG" >/dev/null 2>&1; then
      echo "error: $SLUG already exists; drop --create" >&2
      exit 1
    fi
    # Nothing to clone yet: seed into an empty local repo to show the files.
    echo "  • would create $SLUG ($VISIBILITY), commit the baseline to main, then apply settings"
    git init -q -b main "$WORK"
  else
    echo "  • creating repo"
    gh repo create "$SLUG" "--$VISIBILITY" --disable-wiki >/dev/null
  fi
fi

if [ ! -d "$WORK/.git" ]; then
  gh repo clone "$SLUG" "$WORK" -- --quiet 2>/dev/null || git clone --quiet "https://github.com/$SLUG.git" "$WORK"
fi
cd "$WORK"
DEFAULT_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo main)"

# Has this repo's CI moved onto ops verify.yml? (A repo without a ci.yml gets
# a generated caller, so it counts.) Until it has, auto-merge stays off and the
# files that drive it are held back: bot PRs would otherwise merge on the old
# CI, which may not test what deploys (e.g. a Docker image).
on_verify() {
  [ ! -e .github/workflows/ci.yml ] ||
    grep -q "$OPS_SLUG/.github/workflows/verify.yml@" .github/workflows/ci.yml
}
# Baseline files that only make sense once verify.yml is the required check.
AUTOMERGE_FILES=".github/workflows/automerge.yml renovate.json"

# ---- generate the CI caller (the one file that's templated, not copied) -----
gen_ci_yaml() {
  local ops_ref="$1" ops_tag="${2:-}"
  # The "# <tag>" comment is what lets the consumer's Dependabot bump this ref.
  local ref_line="@$ops_ref"
  [ -n "$ops_tag" ] && ref_line="@$ops_ref # $ops_tag"
  # Public repos also grant pull-requests: write so verify.yml's dependency-review
  # step can post its findings as a PR comment.
  local pr_perm=""
  [ "$VISIBILITY" = "public" ] && pr_perm=$'\n  pull-requests: write # dependency-review comment'
  mkdir -p .github/workflows
  {
    cat <<YAML
name: CI

# verify runs on PRs (the required check, so bot PRs only auto-merge on green)
# and again on main, where it gates deploys: put deploy jobs in this workflow
# with \`needs: verify\` and \`if: github.event_name == 'push'\`.
on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read
  issues: write # verify opens/closes an alert issue when main fails/recovers$pr_perm

# Cancel superseded PR runs, but never a run on main: that would cancel an
# in-flight deploy. Main runs queue instead.
concurrency:
  group: ci-\${{ github.workflow }}-\${{ github.ref }}
  cancel-in-progress: \${{ github.event_name == 'pull_request' }}

jobs:
  verify:
    uses: $OPS_SLUG/.github/workflows/verify.yml$ref_line
YAML
    # Only public repos need a `with:` block (dependency_review is public-only).
    if [ "$VISIBILITY" = "public" ]; then
      echo "    with:"
      echo "      dependency_review: true"
    fi
  } >.github/workflows/ci.yml
  return 0 # the conditional echo above can short-circuit falsy; don't trip `set -e`
}

# ---- seed files -------------------------------------------------------------
SEED_REPORT="" # one line per added/kept file; also used as the PR body

report() {
  SEED_REPORT+="$1"$'\n'
  echo "    $1"
}

# Pick the framework layer: --framework wins, else detect from package.json.
detect_framework() {
  [ -n "$FRAMEWORK" ] && return 0
  if [ ! -f package.json ]; then
    FRAMEWORK="none"
    return 0
  fi
  FRAMEWORK="$(jq -r '((.dependencies // {}) + (.devDependencies // {})) as $d
    | if ($d | has("astro")) then "astro" elif ($d | has("vue")) then "vue" else "none" end' \
    package.json 2>/dev/null || echo none)"
}

# Copy baseline/<layer>/ files that are missing. Never overwrite: a file that
# exists but differs is reported so a human can decide whether to reconcile.
seed_layer() {
  local layer="$1" src rel
  [ -d "$BASELINE/$layer" ] || return 0
  while IFS= read -r src; do
    rel="${src#"$BASELINE/$layer/"}"
    if [ ! -e "$rel" ]; then
      case " $AUTOMERGE_FILES " in
        *" $rel "*)
          if ! on_verify; then
            report "held   $rel (added once ci.yml calls verify.yml — enables auto-merge)"
            continue
          fi
          ;;
      esac
      mkdir -p "$(dirname "$rel")"
      cp "$src" "$rel"
      report "added  $rel"
    elif ! cmp -s "$src" "$rel"; then
      report "kept   $rel (differs from baseline/$layer/ — review by hand)"
    fi
  done < <(find "$BASELINE/$layer" -type f | sort)
}

# Generate the CI caller only if the repo has none. An existing caller keeps its
# inputs (extra_scripts etc.); its ops ref is bumped by the repo's Dependabot.
seed_ci() {
  local ci=".github/workflows/ci.yml"
  if [ ! -e "$ci" ]; then
    gen_ci_yaml "$1" "$2"
    report "added  $ci"
  elif ! grep -q "$OPS_SLUG/.github/workflows/verify.yml@" "$ci"; then
    report "kept   $ci (doesn't call $OPS_SLUG verify.yml — migrate by hand)"
  fi
}

seed_files() {
  local ops_ref ops_tag head
  # Pin consumers to the latest release tag's commit, labelled with that tag,
  # so the SHA and the "# vX" comment Dependabot reads always agree.
  head="$(git -C "$OPS_DIR" rev-parse HEAD 2>/dev/null || echo main)"
  ops_tag="$(git -C "$OPS_DIR" describe --tags --abbrev=0 2>/dev/null || true)"
  if [ -n "$ops_tag" ]; then
    ops_ref="$(git -C "$OPS_DIR" rev-list -n 1 "$ops_tag")"
    if [ "$ops_ref" != "$head" ]; then
      echo "  ⚠ ops has commits after $ops_tag; new CI callers pin $ops_tag. Tag a release to roll those out."
    fi
  else
    ops_ref="$head"
  fi

  detect_framework
  echo "  • seeding baseline files (framework: $FRAMEWORK)"
  if [ "$FRAMEWORK" = "none" ]; then
    echo "    no astro/vue dependency found — pass --framework to seed Prettier/editor configs"
  fi

  seed_layer common
  if [ "$FRAMEWORK" != "none" ]; then
    seed_layer "$FRAMEWORK"
  fi
  seed_ci "$ops_ref" "$ops_tag"

  git add -A
  if git diff --cached --quiet; then
    echo "  • no missing baseline files"
    return 1 # nothing to commit
  fi
  return 0
}

commit_and_push() {
  if $DRY_RUN; then
    local diff_file
    diff_file="${TMPDIR:-/tmp}/bootstrap-${REPO}-$(date +%Y%m%d-%H%M%S).diff"
    git -P diff --cached >"$diff_file"
    echo "  • would add these files:"
    git -P diff --cached --stat | sed 's/^/      /'
    echo "    full diff: $diff_file"
    if $CREATE; then
      echo "  • would commit them to $DEFAULT_BRANCH and push"
    else
      echo "  • would push branch $SYNC_BRANCH and open a PR into $DEFAULT_BRANCH"
      if git ls-remote --exit-code --heads origin "$SYNC_BRANCH" >/dev/null 2>&1; then
        echo "  ⚠ $SYNC_BRANCH already exists on origin — a real run would stop. Merge or delete it first."
      fi
    fi
    return 0
  fi
  if $CREATE; then
    git commit -q -m "chore: apply salt-mountain repo baseline"
    git push -q -u origin "$DEFAULT_BRANCH"
    echo "  ✓ baseline committed to $DEFAULT_BRANCH"
  else
    local b="$SYNC_BRANCH" fence='```' body
    if git ls-remote --exit-code --heads origin "$b" >/dev/null 2>&1; then
      echo "error: $b already exists on origin (an earlier baseline PR?). Merge or delete it, then re-run." >&2
      exit 1
    fi
    body="$(printf 'Adds missing salt-mountain baseline files (framework: %s). Existing files are never overwritten; any that differ from the baseline are listed as **kept** for review.\n\n%s\n%s%s\n' \
      "$FRAMEWORK" "$fence" "$SEED_REPORT" "$fence")"
    git checkout -q -b "$b"
    git commit -q -m "chore: sync salt-mountain repo baseline"
    git push -q -u origin "$b"
    gh pr create --repo "$SLUG" --base "$DEFAULT_BRANCH" --head "$b" \
      --title "chore: sync repo baseline" --body "$body" >/dev/null
    echo "  ✓ baseline opened as a PR (existing repo, main is protected)"
  fi
}

# ---- settings (the part a template repo can't carry) ------------------------

# Required status checks to set, as a JSON array of {context, app_id}. The
# reusable-workflow check reports as "verify / verify" and is pinned to GitHub
# Actions (app 15368), so no other app or token can satisfy it by posting a
# status with the same name. A repo whose ci.yml doesn't call verify.yml yet
# keeps its current required checks (and their app pins), so open PRs aren't
# blocked waiting for a check that never reports.
GITHUB_ACTIONS_APP_ID=15368
CHECKS="[{\"context\":\"verify / verify\",\"app_id\":$GITHUB_ACTIONS_APP_ID}]"
CHECKS_NOTE=""
# "Require up to date" goes off only once verify also runs on main and gates
# deploys; until then it's the only thing testing exactly what lands.
STRICT=false
compute_checks() {
  local existing
  if ! on_verify; then
    STRICT="$(gh api "repos/$SLUG/branches/$DEFAULT_BRANCH/protection/required_status_checks" \
      --jq '.strict' 2>/dev/null || echo true)"
  fi
  if [ -e .github/workflows/ci.yml ] &&
    ! grep -q "$OPS_SLUG/.github/workflows/verify.yml@" .github/workflows/ci.yml; then
    existing="$(gh api "repos/$SLUG/branches/$DEFAULT_BRANCH/protection/required_status_checks" \
      --jq '[.checks[] | if .app_id == null then {context} else {context, app_id} end]' 2>/dev/null || true)"
    if [ -n "$existing" ] && [ "$existing" != "[]" ]; then
      CHECKS="$existing"
      CHECKS_NOTE="keeping current required checks until ci.yml calls verify.yml"
    fi
  fi
}

# "verify / verify (GitHub Actions)" etc. for a checks array.
describe_checks() {
  jq -r --argjson gha "$GITHUB_ACTIONS_APP_ID" '
    if length == 0 then "none" else
      [.[] | "\(.context) (\(
        if .app_id == $gha then "GitHub Actions"
        elif .app_id == null or .app_id == -1 then "any app"
        else "app \(.app_id)" end))"] | join(", ")
    end'
}

# One "current -> planned" line; `~` marks a change.
show() {
  if [ "$2" = "$3" ]; then
    printf '      %-34s %s\n' "$1" "$2"
  else
    printf '    ~ %-34s %s -> %s\n' "$1" "$2" "$3"
  fi
}

preview_settings() {
  echo "  • repo settings (current -> planned; ~ = would change):"
  local repo key want have pair
  repo="$(gh api "repos/$SLUG")"
  for pair in $(repo_settings); do
    key="${pair%%=*}" want="${pair#*=}"
    have="$(jq -r ".$key" <<<"$repo")"
    show "$key" "$have" "$want"
  done
  if ! on_verify; then
    printf '      %-34s %s (switched on once ci.yml calls verify.yml)\n' \
      "allow_auto_merge" "$(jq -r .allow_auto_merge <<<"$repo")"
  fi

  local wf
  wf="$(gh api "repos/$SLUG/actions/permissions/workflow" 2>/dev/null || echo '{}')"
  show "Actions default token" "$(jq -r '.default_workflow_permissions // "?"' <<<"$wf")" "read"
  show "Actions can approve PRs" "$(jq -r 'if has("can_approve_pull_request_reviews") then .can_approve_pull_request_reviews | tostring else "?" end' <<<"$wf")" "false"

  if gh api --silent "repos/$SLUG/vulnerability-alerts" >/dev/null 2>&1; then have=enabled; else have=disabled; fi
  show "Dependabot alerts" "$have" "enabled"
  have="$(gh api "repos/$SLUG/automated-security-fixes" --jq 'if .enabled then "enabled" else "disabled" end' 2>/dev/null || echo disabled)"
  show "Dependabot security updates" "$have" "enabled"

  if [ "$VISIBILITY" = "public" ]; then
    show "secret scanning" "$(jq -r '.security_and_analysis.secret_scanning.status // "disabled"' <<<"$repo")" "enabled"
    show "secret scanning push protection" "$(jq -r '.security_and_analysis.secret_scanning_push_protection.status // "disabled"' <<<"$repo")" "enabled"
  fi
  local visibility
  visibility="$(jq -r .visibility <<<"$repo")"
  if [ "$visibility" != "$VISIBILITY" ]; then
    echo "    ⚠ repo is $visibility on GitHub but you passed --$VISIBILITY (this script never changes visibility)"
  fi

  compute_checks
  echo "  • branch protection on $DEFAULT_BRANCH (current -> planned):"
  [ -n "$CHECKS_NOTE" ] && echo "      ($CHECKS_NOTE)"
  local prot
  if ! prot="$(gh api "repos/$SLUG/branches/$DEFAULT_BRANCH/protection" 2>/dev/null)"; then
    echo "      (currently unprotected)"
    prot='{}'
  fi
  show "required checks" \
    "$(jq '[.required_status_checks.checks[]?]' <<<"$prot" | describe_checks)" \
    "$(describe_checks <<<"$CHECKS")"
  show "require up to date (strict)" \
    "$(jq -r 'if .required_status_checks then .required_status_checks.strict | tostring else "n/a" end' <<<"$prot")" "$STRICT"
  show "PRs required" \
    "$(jq -r 'if .required_pull_request_reviews then "yes, \(.required_pull_request_reviews.required_approving_review_count) approvals" else "no" end' <<<"$prot")" \
    "yes, 0 approvals"
  show "enforce for admins" "$(jq -r '.enforce_admins.enabled // false' <<<"$prot")" "false"
  show "force pushes" "$(jq -r 'if .allow_force_pushes.enabled == false then "blocked" else "allowed" end' <<<"$prot")" "blocked"
  show "branch deletion" "$(jq -r 'if .allow_deletions.enabled == false then "blocked" else "allowed" end' <<<"$prot")" "blocked"

  # The protection PUT replaces the whole rule, so anything else set by hand is
  # reset. Call those out explicitly.
  local removed
  removed="$(jq -r '[
      (select(.required_linear_history.enabled) | "require linear history"),
      (select(.required_signatures.enabled) | "require signed commits"),
      (select(.required_conversation_resolution.enabled) | "require conversation resolution"),
      (select(.lock_branch.enabled) | "lock branch"),
      (select(.block_creations.enabled) | "block creations"),
      (select(.required_pull_request_reviews.dismiss_stale_reviews) | "dismiss stale reviews"),
      (select(.required_pull_request_reviews.require_code_owner_reviews) | "require code owner reviews"),
      (select(.required_pull_request_reviews.require_last_push_approval) | "require approval of last push"),
      (select(.restrictions != null and .restrictions != {}) | "push restrictions (users/teams/apps)")
    ] | .[]' <<<"$prot")"
  if [ -n "$removed" ]; then
    echo "    ⚠ a real run would REMOVE these protections (set them again by hand afterwards if you want them):"
    printf '%s\n' "$removed" | sed 's/^/        - /'
  fi
}

apply_settings() {
  if $DRY_RUN; then
    if $CREATE; then
      echo "  • would apply the standard settings and branch protection to the new repo"
    else
      preview_settings
    fi
    return 0
  fi
  echo "  • applying repo settings"

  # Merge hygiene: squash-only, auto-delete branches, no merge/rebase commits.
  # Auto-merge on: bot PRs (Dependabot via automerge.yml, Renovate natively)
  # merge themselves once the required checks pass.
  local args=() pair
  for pair in $(repo_settings); do args+=(-F "$pair"); done
  gh api -X PATCH "repos/$SLUG" "${args[@]}" >/dev/null
  on_verify || echo "    auto-merge left as-is until ci.yml calls verify.yml"

  # Harden Actions: read-only default GITHUB_TOKEN; workflows can't approve PRs.
  gh api -X PUT "repos/$SLUG/actions/permissions/workflow" \
    -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false >/dev/null || true

  # Dependabot vulnerability alerts + automated security-update PRs.
  gh api --silent -X PUT "repos/$SLUG/vulnerability-alerts" >/dev/null || true
  gh api --silent -X PUT "repos/$SLUG/automated-security-fixes" >/dev/null || true

  # Secret scanning + push protection (free on public; needs GHAS on private).
  if [ "$VISIBILITY" = "public" ]; then
    gh api -X PATCH "repos/$SLUG" \
      -f 'security_and_analysis[secret_scanning][status]=enabled' \
      -f 'security_and_analysis[secret_scanning_push_protection][status]=enabled' >/dev/null || true
  fi

  # Branch protection (see compute_checks for the required checks).
  compute_checks
  [ -n "$CHECKS_NOTE" ] && echo "    $CHECKS_NOTE"
  # strict=false once on verify.yml: PRs needn't be up to date with main to
  # merge. With several bot PRs auto-merging, strict mode stalls every PR
  # behind each merge (no merge queue on personal accounts). The trade-off —
  # two green PRs that break main together — is caught by verify on main,
  # which gates deploys and opens an alert issue. Before that, the repo's
  # current strict setting is kept (see compute_checks).
  gh api -X PUT "repos/$SLUG/branches/$DEFAULT_BRANCH/protection" --input - >/dev/null <<JSON
{
  "required_status_checks": { "strict": $STRICT, "checks": $CHECKS },
  "enforce_admins": false,
  "required_pull_request_reviews": { "required_approving_review_count": 0 },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
  echo "  ✓ branch protection on $DEFAULT_BRANCH (required: $(describe_checks <<<"$CHECKS"))"
}

setup_codeql() {
  if [ "$VISIBILITY" != "public" ]; then
    echo "  • CodeQL: skipped (private repo needs GitHub Advanced Security)"
    return
  fi
  # Reading the state works with the plain `repo` scope; changing it needs
  # `security_events`, so only try (and only warn) when it's actually off.
  local state
  if ! state="$(gh api "repos/$SLUG/code-scanning/default-setup" --jq .state 2>/dev/null)"; then
    state=""
  fi
  if [ "$state" = "configured" ]; then
    echo "  ✓ CodeQL default setup already enabled"
  elif $DRY_RUN; then
    echo "  • CodeQL default setup is ${state:-off/unknown}; a real run would try to enable it"
  elif gh api --silent -X PUT "repos/$SLUG/code-scanning/default-setup" \
      -f state=configured >/dev/null 2>&1; then
    echo "  ✓ CodeQL default setup enabled"
  else
    echo "  ⚠ CodeQL default setup is off and couldn't be enabled (token likely lacks"
    echo "    'security_events' scope). Enable it in the UI:"
    echo "      https://github.com/$SLUG/settings/security_analysis"
  fi
}

# ---- conformance: the standard CI scripts must exist (CI always runs them) ----
check_scripts() {
  if [ ! -f package.json ]; then
    echo "  • no package.json yet — CI stays green until a real project lands"
    return 0
  fi
  local missing
  missing="$(jq -r '(.scripts // {}) as $s | ["format:check", "check", "test", "build"]
    | map(select($s[.] == null)) | join(" ")' package.json 2>/dev/null || echo "?")"
  if [ "$missing" = "?" ]; then
    echo "  • couldn't read package.json scripts — verify by hand: format:check, check, test, build"
  elif [ -n "$missing" ]; then
    echo "  ⚠ package.json is MISSING required scripts: $missing"
    echo "    CI will stay red until they exist. Test-less repos can use:"
    echo '      "test": "echo no tests"   (or "vitest run --passWithNoTests" if vitest is installed)'
  else
    echo "  ✓ package.json defines all required scripts (format:check, check, test, build)"
  fi
  return 0
}

# ---- automation prerequisites the script can't create for you ----------------
check_automation() {
  local names
  names="$(gh secret list --app dependabot --repo "$SLUG" --json name --jq '.[].name' 2>/dev/null || echo "?")"
  if [ "$names" = "?" ]; then
    echo "  • couldn't list Dependabot secrets — check AUTOMERGE_APP_CLIENT_ID / AUTOMERGE_APP_PRIVATE_KEY by hand"
  elif printf '%s\n' "$names" | grep -qx AUTOMERGE_APP_CLIENT_ID &&
    printf '%s\n' "$names" | grep -qx AUTOMERGE_APP_PRIVATE_KEY; then
    echo "  ✓ Dependabot auto-merge secrets present"
  else
    echo "  ⚠ Dependabot auto-merge is a no-op until these Dependabot secrets exist."
    echo "    Set them with: AUTOMERGE_APP_CLIENT_ID=... AUTOMERGE_APP_PRIVATE_KEY_PATH=... \\"
    echo "      $OPS_DIR/set-automerge-secrets.sh $REPO"
    echo "    (the auto-merge GitHub App must also be installed on this repo; see ops README)."
  fi
  echo "  • Renovate: once renovate.json is on $DEFAULT_BRANCH, make sure the Mend Renovate"
  echo "    app is installed on $SLUG (https://github.com/apps/renovate). Installing it"
  echo "    before renovate.json lands gets you an onboarding PR — close it unmerged."
  return 0
}

# ---- run --------------------------------------------------------------------
if $DO_FILES; then
  if seed_files; then commit_and_push; fi
fi

check_scripts

if $DO_SETTINGS; then
  apply_settings
  setup_codeql
fi

check_automation

if $DRY_RUN; then
  echo "▸ dry run complete — nothing was changed on $SLUG"
else
  echo "▸ done: https://github.com/$SLUG"
fi

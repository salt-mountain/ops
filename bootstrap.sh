#!/usr/bin/env bash
#
# bootstrap.sh — apply the salt-mountain repo baseline to a repo.
#
# Seeds the canonical config files (baseline/) and applies the repo *settings* a
# template can't carry: branch protection, merge hygiene, security toggles, and
# hardened Actions permissions. Every step is idempotent, so this doubles as a
# drift-fixer — re-run it on an existing repo to bring it back to standard.
#
# Usage:
#   ./bootstrap.sh <repo> [options]
#
# Options:
#   --create        Create the GitHub repo first (gh repo create).
#   --public        Public repo: enables dependency-review + CodeQL + secret scanning.
#   --private       Private repo (default).
#   --owner <login> GitHub owner (default: salt-mountain).
#   --no-files      Only apply settings; don't seed/sync baseline files.
#   --no-settings   Only seed files; don't touch gh-api settings.
#   -h, --help      Show this help.
#
# Every repo runs the same CI checks (format:check, check, test, build); this
# script reports any of those scripts missing from the target's package.json.
#
# Examples:
#   ./bootstrap.sh my-new-site --create --public
#   ./bootstrap.sh mogarmory --private      # re-apply baseline to an existing repo
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

usage() { sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --create) CREATE=true ;;
    --public) VISIBILITY="public" ;;
    --private) VISIBILITY="private" ;;
    --owner) OWNER="$2"; shift ;;
    --no-files) DO_FILES=false ;;
    --no-settings) DO_SETTINGS=false ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) REPO="$1" ;;
  esac
  shift
done

[ -n "$REPO" ] || { echo "error: repo name required" >&2; usage; exit 2; }
SLUG="$OWNER/$REPO"

# ---- preflight --------------------------------------------------------------
command -v gh >/dev/null || { echo "error: gh CLI required" >&2; exit 1; }
command -v git >/dev/null || { echo "error: git required" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "error: run 'gh auth login' first" >&2; exit 1; }

echo "▸ bootstrapping $SLUG  (visibility=$VISIBILITY create=$CREATE)"

# ---- create -----------------------------------------------------------------
if $CREATE; then
  echo "  • creating repo"
  gh repo create "$SLUG" "--$VISIBILITY" --disable-wiki >/dev/null
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
gh repo clone "$SLUG" "$WORK" -- --quiet 2>/dev/null || git clone --quiet "https://github.com/$SLUG.git" "$WORK"
cd "$WORK"
DEFAULT_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo main)"

# ---- generate the CI caller (the one file that's templated, not copied) -----
gen_ci_yaml() {
  local ops_ref="$1" ops_tag="${2:-}"
  # The "# <tag>" comment is what lets the consumer's Dependabot bump this ref.
  local ref_line="@$ops_ref"
  [ -n "$ops_tag" ] && ref_line="@$ops_ref # $ops_tag"
  mkdir -p .github/workflows
  {
    cat <<YAML
name: CI

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

concurrency:
  group: ci-\${{ github.workflow }}-\${{ github.ref }}
  cancel-in-progress: true

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
seed_files() {
  local ops_ref ops_tag
  ops_ref="$(git -C "$OPS_DIR" rev-parse HEAD 2>/dev/null || echo main)"
  ops_tag="$(git -C "$OPS_DIR" describe --tags --abbrev=0 2>/dev/null || true)"

  cp -R "$BASELINE/." .
  gen_ci_yaml "$ops_ref" "$ops_tag"

  git add -A
  if git diff --cached --quiet; then
    echo "  • files already up to date"
    return 1 # nothing to commit
  fi
  return 0
}

commit_and_push() {
  if $CREATE; then
    git commit -q -m "chore: apply salt-mountain repo baseline"
    git push -q -u origin "$DEFAULT_BRANCH"
    echo "  ✓ baseline committed to $DEFAULT_BRANCH"
  else
    local b="chore/baseline-sync"
    git checkout -q -b "$b"
    git commit -q -m "chore: sync salt-mountain repo baseline"
    git push -q -u origin "$b"
    gh pr create --repo "$SLUG" --base "$DEFAULT_BRANCH" --head "$b" \
      --title "chore: sync repo baseline" \
      --body "Re-applies the current salt-mountain baseline (configs + CI caller)." >/dev/null
    echo "  ✓ baseline opened as a PR (existing repo, main is protected)"
  fi
}

# ---- settings (the part a template repo can't carry) ------------------------
apply_settings() {
  echo "  • applying repo settings"

  # Merge hygiene: squash-only, auto-delete branches, no merge/rebase commits.
  gh api -X PATCH "repos/$SLUG" \
    -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false \
    -F delete_branch_on_merge=true -F allow_auto_merge=false >/dev/null

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

  # Branch protection. The reusable-workflow check reports as "verify / verify".
  local contexts='"verify / verify"'
  gh api -X PUT "repos/$SLUG/branches/$DEFAULT_BRANCH/protection" --input - >/dev/null <<JSON
{
  "required_status_checks": { "strict": true, "contexts": [ $contexts ] },
  "enforce_admins": false,
  "required_pull_request_reviews": { "required_approving_review_count": 0 },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
  echo "  ✓ branch protection on $DEFAULT_BRANCH (contexts: $contexts)"
}

setup_codeql() {
  if [ "$VISIBILITY" != "public" ]; then
    echo "  • CodeQL: skipped (private repo needs GitHub Advanced Security)"
    return
  fi
  if gh api --silent -X PUT "repos/$SLUG/code-scanning/default-setup" \
      -f state=configured >/dev/null 2>&1; then
    echo "  ✓ CodeQL default setup enabled"
  else
    echo "  • CodeQL: enable via UI (token likely lacks 'security_events' scope):"
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
  missing="$(node -e 'const s=(require("./package.json").scripts)||{}; process.stdout.write(["format:check","check","test","build"].filter(k=>!s[k]).join(" "))' 2>/dev/null || echo "?")"
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

# ---- run --------------------------------------------------------------------
if $DO_FILES; then
  if seed_files; then commit_and_push; fi
fi

check_scripts

if $DO_SETTINGS; then
  apply_settings
  setup_codeql
fi

echo "▸ done: https://github.com/$SLUG"

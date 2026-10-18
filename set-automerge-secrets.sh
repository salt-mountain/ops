#!/usr/bin/env bash
#
# set-automerge-secrets.sh — store the auto-merge GitHub App's credentials as
# Dependabot secrets on one or more repos.
#
# The baseline automerge.yml mints a token from AUTOMERGE_APP_CLIENT_ID and
# AUTOMERGE_APP_PRIVATE_KEY. They must be *Dependabot* secrets: workflows that
# Dependabot triggers can't read Actions secrets.
#
# Before setting anything, it signs a JWT with the key and asks GitHub whether
# the app is installed on each repo. That proves the client ID and key belong
# together, and skips repos the app can't act on (secrets there would make
# automerge.yml fail at the token step instead of quietly doing nothing).
#
# Usage:
#   export AUTOMERGE_APP_CLIENT_ID=Iv23...
#   export AUTOMERGE_APP_PRIVATE_KEY_PATH=~/secure/automerge.private-key.pem
#   ./set-automerge-secrets.sh [options] <repo>...
#   ./set-automerge-secrets.sh [options] --all
#
# Options:
#   --all           Every non-archived, non-fork repo you own under --owner.
#   --owner <login> GitHub owner (default: salt-mountain).
#   --dry-run       Check credentials and installations; set nothing.
#   -h, --help      Show this help.
#
# Requires gh (logged in), jq, openssl and curl.
#
set -euo pipefail

OWNER="salt-mountain"
ALL=false
DRY_RUN=false
REPOS=()

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --all) ALL=true ;;
    --owner) OWNER="${2:?--owner needs a value}"; shift ;;
    --dry-run) DRY_RUN=true ;;
    -h | --help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) REPOS+=("$1") ;;
  esac
  shift
done

for cmd in gh jq openssl curl; do
  command -v "$cmd" >/dev/null || { echo "error: $cmd is required" >&2; exit 1; }
done
gh auth status >/dev/null 2>&1 || { echo "error: run 'gh auth login' first" >&2; exit 1; }

CLIENT_ID="${AUTOMERGE_APP_CLIENT_ID:-}"
KEY_PATH="${AUTOMERGE_APP_PRIVATE_KEY_PATH:-}"
KEY_PATH="${KEY_PATH/#\~/$HOME}"
[ -n "$CLIENT_ID" ] || { echo "error: set AUTOMERGE_APP_CLIENT_ID (the app's Client ID, Iv...)" >&2; exit 2; }
[ -n "$KEY_PATH" ] || { echo "error: set AUTOMERGE_APP_PRIVATE_KEY_PATH (path to the app's .pem)" >&2; exit 2; }
[ -r "$KEY_PATH" ] || { echo "error: can't read private key at $KEY_PATH" >&2; exit 2; }
grep -q -- "-----BEGIN .*PRIVATE KEY-----" "$KEY_PATH" ||
  { echo "error: $KEY_PATH doesn't look like a PEM private key" >&2; exit 2; }

if $ALL; then
  [ ${#REPOS[@]} -eq 0 ] || { echo "error: pass repo names or --all, not both" >&2; exit 2; }
  while IFS= read -r name; do REPOS+=("$name"); done < <(
    gh repo list "$OWNER" --no-archived --source --limit 200 --json name --jq '.[].name' | sort
  )
fi
[ ${#REPOS[@]} -gt 0 ] || { echo "error: name at least one repo, or pass --all" >&2; usage; exit 2; }

# ---- app JWT (RS256), valid for a few minutes ----------------------------------
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
make_jwt() {
  local now header payload unsigned
  now="$(date +%s)"
  header="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
  # iat backdated 60s for clock skew; GitHub allows at most 10 minutes.
  payload="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "$CLIENT_ID" | b64url)"
  unsigned="$header.$payload"
  printf '%s.%s' "$unsigned" "$(printf '%s' "$unsigned" | openssl dgst -sha256 -sign "$KEY_PATH" -binary | b64url)"
}
JWT="$(make_jwt)"

# HTTP status of an app-authenticated GET (body discarded).
app_get() {
  curl -sS -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $JWT" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com$1"
}

status="$(app_get /app)"
if [ "$status" != 200 ]; then
  echo "error: GitHub rejected the app credentials (GET /app -> HTTP $status)." >&2
  echo "       Check that AUTOMERGE_APP_CLIENT_ID matches the app the .pem was generated for." >&2
  exit 1
fi

if $DRY_RUN; then
  echo "▸ DRY RUN — credentials OK; checking ${#REPOS[@]} repo(s), setting nothing"
else
  echo "▸ credentials OK; setting Dependabot secrets on ${#REPOS[@]} repo(s)"
fi

set_count=0
skipped=()
for repo in "${REPOS[@]}"; do
  slug="$OWNER/$repo"
  status="$(app_get "/repos/$slug/installation")"
  if [ "$status" != 200 ]; then
    echo "  - $slug: app not installed (HTTP $status) — skipped"
    skipped+=("$repo")
    continue
  fi
  if $DRY_RUN; then
    echo "  ✓ $slug: app installed; would set AUTOMERGE_APP_CLIENT_ID and AUTOMERGE_APP_PRIVATE_KEY"
    continue
  fi
  gh secret set AUTOMERGE_APP_CLIENT_ID --app dependabot --repo "$slug" --body "$CLIENT_ID" >/dev/null
  gh secret set AUTOMERGE_APP_PRIVATE_KEY --app dependabot --repo "$slug" <"$KEY_PATH" >/dev/null
  echo "  ✓ $slug: secrets set"
  set_count=$((set_count + 1))
done

if [ ${#skipped[@]} -gt 0 ]; then
  echo "▸ ${#skipped[@]} repo(s) skipped. Add them to the app's installation"
  echo "  (https://github.com/settings/installations -> the app -> Configure), then re-run for:"
  echo "    ${skipped[*]}"
fi
$DRY_RUN || echo "▸ done: secrets set on $set_count repo(s)"

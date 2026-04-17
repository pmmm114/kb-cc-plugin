#!/bin/bash
# unit_resolve_repo.sh
#
# Unit tests for _resolve_repo_from_cwd URL-variant parsing.
# Added in Phase 0 (PR #25) after review flagged ssh://host:PORT misparse.
#
# Covers:
#   - https:// (with and without .git)
#   - git@ shorthand
#   - ssh:// (with and without port)
#   - non-github host rejection (gitlab, bitbucket)
#   - GitHub Enterprise acceptance
#   - nested-path rejection (gitlab-style groups)
#   - missing remote / not-a-git-repo

set +e
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/error-reporter/scripts/report.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

# Load helpers from report.sh without triggering main path.
HELPERS_TMP=$(mktemp)
trap 'rm -f "$HELPERS_TMP"' EXIT
awk '
  /^# === Self-test mode/ { exit }
  { print }
' "$SCRIPT" > "$HELPERS_TMP"
# shellcheck disable=SC1090
source "$HELPERS_TMP"
type _resolve_repo_from_cwd >/dev/null 2>&1 || { echo "FATAL: _resolve_repo_from_cwd not loaded" >&2; exit 1; }

printf 'unit_resolve_repo.sh\n'
printf '====================\n\n'

# Helper: initialize a temp git repo with the given remote URL, then run the parser.
expect_url() {
  local url="$1" expected="$2" label="$3"
  local td
  td=$(mktemp -d "/tmp/er-url-XXXXXX")
  ( cd "$td" && git init -q && git remote add origin "$url" ) 2>/dev/null
  local actual
  actual=$(_resolve_repo_from_cwd "$td" 2>/dev/null)
  if [ "$actual" = "$expected" ]; then
    pass "$label ($url → ${actual:-<empty>})"
  else
    fail "$label ($url): got '$actual', expected '$expected'"
  fi
  rm -rf "$td"
}

printf 'GitHub URL variants (should resolve):\n'
expect_url "https://github.com/owner/repo"              "owner/repo" "https no-git"
expect_url "https://github.com/owner/repo.git"          "owner/repo" "https .git"
expect_url "http://github.com/owner/repo.git"           "owner/repo" "http (non-TLS) accepted"
expect_url "git@github.com:owner/repo.git"              "owner/repo" "git@ shorthand"
expect_url "git@github.com:owner/repo"                  "owner/repo" "git@ shorthand no-.git"
expect_url "ssh://git@github.com/owner/repo.git"        "owner/repo" "ssh:// no-port"
expect_url "ssh://git@github.com/owner/repo"            "owner/repo" "ssh:// no-port no-.git"
expect_url "ssh://git@github.com:22/owner/repo.git"     "owner/repo" "ssh:// with port (PR #25 review fix)"
expect_url "https://github.enterprise.corp/owner/repo"  "owner/repo" "GitHub Enterprise"
expect_url "https://github.com/owner/repo.git/"         "owner/repo" ".git/ trailing slash (R3 fix)"
expect_url "https://github.com/owner/repo/"             "owner/repo" "bare trailing slash"
expect_url "https://GITHUB.com/owner/repo"              "owner/repo" "case-insensitive host (R3 fix)"
expect_url "https://GitHub.COM/owner/repo"              "owner/repo" "mixed-case host"

printf '\nNon-GitHub hosts (should reject):\n'
expect_url "https://gitlab.com/owner/repo.git"          "" "gitlab"
expect_url "https://bitbucket.org/owner/repo.git"       "" "bitbucket"
expect_url "https://git.example.com/owner/repo.git"     "" "generic self-hosted"
expect_url "https://user:pass@github.com/owner/repo"    "" "userinfo in URL rejected (host capture includes user:pass)"

printf '\nMalformed / unsupported (should reject):\n'
expect_url "https://github.com/group/sub/repo.git"      "" "nested-path rejected"
expect_url "ssh://git@github.com:owner/repo.git"        "" "malformed ssh:// (host:path without slash)"
expect_url "file:///local/path/repo.git"                "" "file:// rejected"

printf '\nEnvironmental edges:\n'
# No remote
TD=$(mktemp -d "/tmp/er-url-XXXXXX")
( cd "$TD" && git init -q ) 2>/dev/null
actual=$(_resolve_repo_from_cwd "$TD" 2>/dev/null); rc=$?
{ [ -z "$actual" ] && [ "$rc" -eq 1 ]; } && pass "no remote → empty + rc=1" || fail "no remote → got='$actual' rc=$rc"
rm -rf "$TD"

# Not a git repo
TD=$(mktemp -d "/tmp/er-url-XXXXXX")
actual=$(_resolve_repo_from_cwd "$TD" 2>/dev/null); rc=$?
{ [ -z "$actual" ] && [ "$rc" -eq 1 ]; } && pass "not-git-repo → empty + rc=1" || fail "not-git-repo → got='$actual' rc=$rc"
rm -rf "$TD"

# Non-existent dir
actual=$(_resolve_repo_from_cwd "/tmp/nonexistent-$$" 2>/dev/null); rc=$?
{ [ -z "$actual" ] && [ "$rc" -eq 1 ]; } && pass "nonexistent dir → empty + rc=1" || fail "nonexistent dir → got='$actual' rc=$rc"

# Empty arg
actual=$(_resolve_repo_from_cwd "" 2>/dev/null); rc=$?
{ [ -z "$actual" ] && [ "$rc" -eq 1 ]; } && pass "empty arg → empty + rc=1" || fail "empty arg → got='$actual' rc=$rc"

printf '\nSummary: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

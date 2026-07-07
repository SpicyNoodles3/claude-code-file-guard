#!/usr/bin/env bash
# run_tests.sh — self-contained test harness for file-guard.sh (no framework).
# Creates an isolated temp sandbox, runs each case, prints PASS/FAIL per case,
# and exits non-zero if any case fails.
set -u

HERE=$(cd -P "$(dirname "$0")" && pwd -P)
HOOK="$HERE/../hooks/file-guard.sh"
FIXTURES="$HERE/fixtures"

# Bash used to run the hook in every case (override with TEST_BASH=/bin/bash to
# pin macOS system bash 3.2). Absolute path so the jq-missing case can strip PATH.
BASH_BIN=${TEST_BASH:-$(command -v bash)}

[ -f "$HOOK" ] || { echo "cannot find hook at $HOOK" >&2; exit 3; }

# Isolated sandbox. We deliberately do NOT touch the real $HOME.
SB=$(mktemp -d 2>/dev/null) || { echo "mktemp failed" >&2; exit 3; }
FAKE_HOME="$SB/home"
mkdir -p "$FAKE_HOME/.claude"
cleanup() { rm -rf "$SB"; }
trap cleanup EXIT

# Sandbox layout.
mkdir -p "$SB/protected" "$SB/allowed" "$SB/allowed/deploy" "$SB/real_secret"
printf 'top secret\n' >"$SB/protected/secret.txt"
printf 'notes\n'      >"$SB/allowed/notes.txt"
# Symlink whose target is a protected directory (case 5).
ln -s "$SB/real_secret" "$SB/link_to_protected"
# Symlink FILE whose target is a protected file (case 21).
ln -s "$SB/protected/secret.txt" "$SB/allowed/report.txt"
# An EXISTING file inside the protected dir, reachable through the symlink
# (case 31 — the existing-leaf branch of symlinked-parent resolution).
printf 'db\n' >"$SB/real_secret/db.txt"

# Test config. Patterns exercise: dir glob, basename glob, and the symlink
# target dir. Written into the sandbox project's .claude/.
mkdir -p "$SB/proj/.claude"
CONF="$SB/proj/.claude/file-guard.conf"
{
  echo "# test config"
  echo "$SB/protected/*"
  echo "$SB/real_secret/*"
  echo "*.pem"
  # Literal tilde on purpose: the HOOK expands ~/ at config load (case 25).
  # shellcheck disable=SC2088
  echo "~/secrets/*"
  # Relative slash-pattern: matches at any depth (case 30, the README's
  # self-protection recommendation).
  echo ".claude/settings.json"
} >"$CONF"

# Env the hook sees for every case (unless a case overrides).
export CLAUDE_PROJECT_DIR="$SB/proj"
export HOME="$FAKE_HOME"

PASS=0
FAIL=0

# esc <string> — escape for safe use as a sed replacement string.
# Sandbox paths from mktemp never contain newlines, so only \, /, & matter.
esc() {
  printf '%s' "$1" | sed -e 's/[\\/&]/\\&/g'
}

# render <fixture> — substitute __SB__ and __DASH__, print to stdout.
render() {
  local f="$FIXTURES/$1"
  local sb_e; sb_e=$(esc "$SB")
  sed -e "s/__SB__/$sb_e/g" -e "s/__DASH__/--/g" "$f"
}

# check <name> <fixture> <expect_exit> [env-assignment ...]
# Pipes the rendered fixture into the hook; asserts exit code, and for a
# block (exit 2) that stderr carries the "file-guard:" prefix.
check() {
  local name="$1"; shift
  local fixture="$1"; shift
  local want="$1"; shift
  local err_file="$SB/stderr.$$"
  local got

  # Remaining args are VAR=VAL overrides for this single invocation.
  render "$fixture" | env "$@" "$BASH_BIN" "$HOOK" 2>"$err_file"
  got=$?

  local ok=1
  [ "$got" = "$want" ] || ok=0
  if [ "$want" = "2" ]; then
    grep -q 'file-guard:' "$err_file" || ok=0
  fi

  if [ "$ok" = "1" ]; then
    printf 'PASS  %-42s (exit %s)\n' "$name" "$got"
    PASS=$((PASS + 1))
  else
    printf 'FAIL  %-42s (want %s, got %s)\n' "$name" "$want" "$got"
    [ -s "$err_file" ] && printf '        stderr: %s\n' "$(head -1 "$err_file")"
    FAIL=$((FAIL + 1))
  fi
  rm -f "$err_file"
}

echo "file-guard test harness"
echo "sandbox: $SB"
echo "-------------------------------------------------------------"

# 1. Write to protected path -> block
check "1  write protected"            write_protected.json    2

# 2. Write to allowed path -> allow
check "2  write allowed"              write_allowed.json      0

# 3. ../ traversal reaching protected -> block
check "3  edit ../ traversal"         edit_traversal.json     2

# 4. relative file_path + cwd into protected -> block
check "4  relative cwd into protected" relative_cwd.json      2

# 5. write through symlinked-parent whose target is protected -> block
check "5  symlink parent"             symlink_parent.json     2

# 6. case-variant of protected pattern -> block (default insensitive)
check "6a case-variant default"       case_variant.json       2
#    same case-variant with case-sensitivity ON -> allow
check "6b case-variant sensitive"     case_variant.json       0  FILE_GUARD_CASE_SENSITIVE=1

# 7. path with spaces, protected -> block ; allowed -> allow
check "7a spaces protected"           spaces_protected.json   2
check "7b spaces allowed"             spaces_allowed.json     0

# 8. NotebookEdit notebook_path protected -> block
check "8  notebook protected"         notebook_protected.json 2

# 9. unknown tool carrying file_path to protected -> block
check "9  unknown tool file_path"     unknown_tool.json       2

# 10. malformed JSON -> block ; empty stdin -> block
check "10a malformed json"            malformed.json          2
printf '' | "$BASH_BIN" "$HOOK" 2>"$SB/e10b"; g=$?
if [ "$g" = "2" ] && grep -q 'file-guard:' "$SB/e10b"; then
  printf 'PASS  %-42s (exit %s)\n' "10b empty stdin" "$g"; PASS=$((PASS + 1))
else
  printf 'FAIL  %-42s (want 2, got %s)\n' "10b empty stdin" "$g"; FAIL=$((FAIL + 1))
fi
rm -f "$SB/e10b"

# 11. no config anywhere -> block, both searched paths named
#     Point CLAUDE_PROJECT_DIR and HOME at empty dirs so no config is found.
EMPTY="$SB/empty"; mkdir -p "$EMPTY/proj" "$EMPTY/home"
render write_protected.json | \
  env -u FILE_GUARD_CONFIG CLAUDE_PROJECT_DIR="$EMPTY/proj" HOME="$EMPTY/home" \
  "$BASH_BIN" "$HOOK" 2>"$SB/e11"; g=$?
if [ "$g" = "2" ] \
   && grep -q "$EMPTY/proj/.claude/file-guard.conf" "$SB/e11" \
   && grep -q "$EMPTY/home/.claude/file-guard.conf" "$SB/e11"; then
  printf 'PASS  %-42s (exit %s)\n' "11 no config, both paths named" "$g"; PASS=$((PASS + 1))
else
  printf 'FAIL  %-42s (want 2 + both paths, got %s)\n' "11 no config" "$g"
  head -2 "$SB/e11"; FAIL=$((FAIL + 1))
fi
rm -f "$SB/e11"

# 12. jq missing -> block. Strip PATH so `command -v jq` fails; we invoke bash
#     by absolute path since PATH lookup can't find it. bash builtins still work.
render write_protected.json | PATH="/nonexistent" "$BASH_BIN" "$HOOK" 2>"$SB/e12"; g=$?
if [ "$g" = "2" ] && grep -qi 'jq' "$SB/e12"; then
  printf 'PASS  %-42s (exit %s)\n' "12 jq missing" "$g"; PASS=$((PASS + 1))
else
  printf 'FAIL  %-42s (want 2, got %s)\n' "12 jq missing" "$g"
  head -1 "$SB/e12"; FAIL=$((FAIL + 1))
fi
rm -f "$SB/e12"

# 13-15. Bash write indicators.
check "13 bash redirect >"            bash_redirect.json      2
check "14 bash tee"                   bash_tee.json           2
check "15 bash cat (read only)"       bash_cat_read.json      0

# 16. git lane.
check "16a git push --force"          git_force.json          2
check "16b git push --force-with-lease" git_force_lease.json  0
check "16c git commit -m reset --hard" git_commit_msg.json    0
check "16d git reset --hard"          git_reset_hard.json     2
check "16e FILE_GUARD_GIT=0 push -f"  git_push_f.json         0  FILE_GUARD_GIT=0
#     and push -f blocks when the git lane is on:
check "16f git push -f (default on)"  git_push_f.json         2

# 17. bash mv of protected -> block
check "17 bash mv protected"          bash_mv.json            2

# 18. newline-smuggled path -> block (control-char)
check "18 newline-smuggled path"      newline_path.json       2

# 19. FILE_GUARD_LOG: a block appends a line; an allow appends nothing.
LOG="$SB/guard.log"
: >"$LOG"
render write_protected.json | env FILE_GUARD_LOG="$LOG" "$BASH_BIN" "$HOOK" >/dev/null 2>&1
render write_allowed.json   | env FILE_GUARD_LOG="$LOG" "$BASH_BIN" "$HOOK" >/dev/null 2>&1
lines=$(grep -c . "$LOG" 2>/dev/null || echo 0)
if [ "$lines" = "1" ] && grep -q 'BLOCK' "$LOG"; then
  printf 'PASS  %-42s (1 block line)\n' "19 logging block-only"; PASS=$((PASS + 1))
else
  printf 'FAIL  %-42s (expected 1 line, got %s)\n' "19 logging block-only" "$lines"
  cat "$LOG"; FAIL=$((FAIL + 1))
fi

# 20. basename pattern (*.pem) blocks a .pem write anywhere
check "20 *.pem basename anywhere"    pem_anywhere.json       2

# 21. symlink FILE pointing at a protected target -> block (leaf resolution)
check "21 symlink file to protected"  symlink_file.json       2

# 22. glob metacharacters in file_path stay LITERAL (no pathname expansion
#     against the hook's cwd). Run from $SB, where `prot*cted` would expand to
#     `protected/` if globbing leaked — the literal path is not protected.
( cd "$SB" && render glob_path.json | "$BASH_BIN" "$HOOK" 2>"$SB/e22" ); g=$?
if [ "$g" = "0" ]; then
  printf 'PASS  %-42s (exit %s)\n' "22 glob path stays literal" "$g"; PASS=$((PASS + 1))
else
  printf 'FAIL  %-42s (want 0, got %s)\n' "22 glob path stays literal" "$g"
  head -1 "$SB/e22"; FAIL=$((FAIL + 1))
fi
rm -f "$SB/e22"

# 23. quoted force flag cannot hide: git push "--force" -> block
check "23 git push quoted --force"    git_force_quoted.json   2

# 24. fd-redirect with no space (2>path) into protected -> block
check "24 bash 2>redirect protected"  bash_fd_redirect.json   2

# 25. literal $HOME/ token resolving into a protected ~ pattern -> block
check "25 bash \$HOME var protected"  bash_home_var.json      2

# 26. config with only comments -> fail-closed block (and no bash 3.2 crash)
ONLYC="$SB/onlycomments"; mkdir -p "$ONLYC/.claude"
printf '# nothing here\n\n' >"$ONLYC/.claude/file-guard.conf"
render write_allowed.json | env CLAUDE_PROJECT_DIR="$ONLYC" "$BASH_BIN" "$HOOK" 2>"$SB/e26"; g=$?
if [ "$g" = "2" ] && grep -q 'no patterns' "$SB/e26"; then
  printf 'PASS  %-42s (exit %s)\n' "26 empty config fail-closed" "$g"; PASS=$((PASS + 1))
else
  printf 'FAIL  %-42s (want 2 + message, got %s)\n' "26 empty config fail-closed" "$g"
  head -1 "$SB/e26"; FAIL=$((FAIL + 1))
fi
rm -f "$SB/e26"

# 27. file_path "/" -> allow, and no set -u crash on bash 3.2 (exit 0, not 1)
check "27 root path no crash"         slash_root.json         0

# 28. tail -f after git push in another segment is NOT a force-push -> allow
check "28 git push && tail -f"        git_push_tail_f.json    0

# 29. carriage-return-smuggled path -> block (control-char)
check "29 CR-smuggled path"           cr_path.json            2

# 30. relative slash-pattern (.claude/settings.json) matches at any depth —
#     the README's self-protection recommendation must actually block.
check "30 relative pattern any depth" settings_selfprotect.json 2

# 31. EXISTING file through a symlinked parent dir -> block. Regression pin:
#     the first cut resolved symlinked parents only for non-existing leaves,
#     so overwriting an existing protected file through the symlink passed.
check "31 symlink parent, existing leaf" symlink_parent_existing.json 2

echo "-------------------------------------------------------------"
printf 'TOTAL: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]

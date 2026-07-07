#!/usr/bin/env bash
# shellcheck disable=SC2088
# (SC2088: the `"~/"*` case patterns match a literal leading ~/ in the input
#  string; expansion is done by hand via $HOME, so quoting them is correct.)
#
# file-guard.sh — a Claude Code PreToolUse hook that blocks the agent from
# writing to files you declare protected.
#
# Reads a PreToolUse JSON payload on stdin. Exit 0 = allow, exit 2 = block
# (stderr is fed back to the model). It never exits 1 on a handled path.
#
# Dependency: jq (the only external JSON parser). Bash 3.2 compatible.
# See README.md for what this does and — just as important — what it does NOT.

set -u
# Not `set -e`: we manage exit codes explicitly (0 allow / 2 block) and a
# non-zero from a probe (grep, cd) must not abort the script mid-decision.

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# block <reason> <detail-for-log>
# Prints a one-line actionable message to stderr, logs (best-effort), exits 2.
block() {
  echo "file-guard: $1" >&2
  log_decision "$2"
  exit 2
}

# log_decision <path-or-command> — only called on a block. Best-effort; a
# logging failure must never change the decision.
log_decision() {
  [ -n "${FILE_GUARD_LOG:-}" ] || return 0
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || ts="-"
  detail=$(printf '%.120s' "$1")
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$ts" "BLOCK" "${tool_name:-?}" "${block_reason:-?}" "$detail" \
    >>"$FILE_GUARD_LOG" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Dependency + config resolution (all fail-closed)
# ---------------------------------------------------------------------------

command -v jq >/dev/null 2>&1 || {
  echo "file-guard: jq not found on PATH. Install jq, or remove this hook from settings.json." >&2
  exit 2
}

# Locate config: first found wins, no merging.
config=""
if [ -n "${FILE_GUARD_CONFIG:-}" ]; then
  config="$FILE_GUARD_CONFIG"
else
  proj_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
  proj_conf="$proj_dir/.claude/file-guard.conf"
  home_conf="$HOME/.claude/file-guard.conf"
  if [ -f "$proj_conf" ]; then
    config="$proj_conf"
  elif [ -f "$home_conf" ]; then
    config="$home_conf"
  else
    echo "file-guard: no config found. Looked in: $proj_conf and $home_conf" >&2
    echo "file-guard: create one, e.g. cp file-guard.conf.example .claude/file-guard.conf" >&2
    exit 2
  fi
fi
[ -f "$config" ] || {
  echo "file-guard: config not found: $config" >&2
  exit 2
}
[ -r "$config" ] || {
  echo "file-guard: config exists but is unreadable: $config" >&2
  exit 2
}

# Load patterns: strip comments/blank lines, trim whitespace, expand ~/.
patterns=()
while IFS= read -r line || [ -n "$line" ]; do
  line="${line#"${line%%[![:space:]]*}"}"   # ltrim
  line="${line%"${line##*[![:space:]]}"}"   # rtrim
  case "$line" in
    ''|\#*) continue ;;
    "~/"*)  line="$HOME/${line#"~/"}" ;;
  esac
  # A slash-containing pattern that is not absolute matches at any depth:
  # prepend */ so `.claude/settings.json` guards that file in any project.
  # (Payload paths are always absolute by the time they are matched.)
  case "$line" in
    /*)  : ;;
    */*) line="*/$line" ;;
  esac
  patterns+=("$line")
  # For an absolute glob, also register a variant with its leading literal
  # directory physically resolved — so a symlinked ancestor of the pattern's
  # own root (e.g. macOS /var -> /private/var) still matches the resolved path.
  case "$line" in
    /*[*?[]*)
      lit="${line%%[*?[]*}"       # leading text before first glob metachar
      dir="${lit%/*}"             # its directory
      if [ -n "$dir" ] && [ -d "$dir" ]; then
        rdir=$(cd -P "$dir" 2>/dev/null && pwd -P) || rdir=""
        if [ -n "$rdir" ] && [ "$rdir" != "$dir" ]; then
          patterns+=("$rdir/${line#"$dir/"}")
        fi
      fi ;;
  esac
done <"$config"

# An empty pattern list is almost certainly a mistake (and expanding an empty
# array under `set -u` errors on bash 3.2) — fail closed, say how to fix it.
[ "${#patterns[@]}" -gt 0 ] || {
  echo "file-guard: config $config contains no patterns — nothing to guard (fail-closed). Add patterns or remove the hook." >&2
  exit 2
}

# ---------------------------------------------------------------------------
# Read the payload — exactly one jq invocation.
# @tsv escapes embedded tabs/newlines/backslashes as \t \n \\ (neutralizes
# newline injection and preserves the raw bytes for us to inspect).
# ---------------------------------------------------------------------------

input=$(cat)
# Empty stdin is not a valid payload — fail closed (jq exits 0 on empty input,
# so we must reject it ourselves before trusting the parse).
case "$input" in
  '') echo "file-guard: empty stdin — expected a PreToolUse JSON payload." >&2; exit 2 ;;
esac
tsv=$(printf '%s' "$input" | jq -r \
  '[.tool_name // "", .tool_input.file_path // .tool_input.notebook_path // "", .tool_input.command // "", .cwd // ""] | @tsv') || {
  echo "file-guard: stdin is not valid JSON (jq failed to parse the payload)." >&2
  exit 2
}

# Split the TSV into exactly 4 fields. jq's @tsv on a 4-element array always
# emits exactly 3 tab separators, and it escaped any embedded tabs — so we can
# split by hand with parameter expansion. We do NOT use `IFS=$'\t' read`
# because a whitespace IFS collapses empty fields (an absent file_path would
# shift the command into the path slot).
TAB=$(printf '\t')
_rest="$tsv"
tool_name="${_rest%%"$TAB"*}";  _rest="${_rest#*"$TAB"}"
raw_path="${_rest%%"$TAB"*}";   _rest="${_rest#*"$TAB"}"
cmd="${_rest%%"$TAB"*}";        _rest="${_rest#*"$TAB"}"
payload_cwd="$_rest"
block_reason=""

# Case-insensitive matching by default (macOS filesystems are case-insensitive).
if [ "${FILE_GUARD_CASE_SENSITIVE:-0}" = "1" ]; then
  shopt -u nocasematch
else
  shopt -s nocasematch
fi

# ---------------------------------------------------------------------------
# Path lane — runs for ANY tool whose payload carried a file_path/notebook_path.
# ---------------------------------------------------------------------------

if [ -n "$raw_path" ]; then
  # A residual \t, \n, or \r escape in the path means the original bytes were
  # real control characters — treat as an injection attempt. (A filename with a
  # literal backslash-t also trips this; erring closed is the documented posture.)
  case "$raw_path" in
    *'\t'*|*'\n'*|*'\r'*)
      block_reason="control-char"
      block "path contains control characters — refusing." "$raw_path" ;;
  esac
  # Un-escape backslash-escaped backslashes back to a single backslash.
  path="${raw_path//\\\\/\\}"

  # 1. Expand leading ~/ ; if still relative, anchor to payload cwd (or $PWD).
  case "$path" in
    "~/"*) path="$HOME/${path#"~/"}" ;;
  esac
  case "$path" in
    /*) : ;;
    *)  base_cwd="${payload_cwd:-$PWD}"; path="$base_cwd/$path" ;;
  esac

  # 2. Lexical normalization: resolve . and .. without touching the disk.
  #    set -f: the split words are unquoted, and without noglob a crafted path
  #    containing * ? [ would be pathname-expanded against the filesystem here.
  norm_stack=()
  set -f
  oldIFS="$IFS"; IFS='/'
  for seg in $path; do
    case "$seg" in
      ''|.) : ;;
      ..)   [ "${#norm_stack[@]}" -gt 0 ] && unset 'norm_stack[${#norm_stack[@]}-1]' ;;
      *)    norm_stack+=("$seg") ;;
    esac
  done
  IFS="$oldIFS"
  set +f
  # ${arr[*]+...}: expanding an empty array bare under `set -u` errors on
  # bash 3.2 (file_path "/" leaves the stack empty). [*] is deliberate: the
  # subshell IFS=/ joins the segments back into a path.
  # shellcheck disable=SC2048
  norm_path="/$(IFS='/'; printf '%s' ${norm_stack[*]+"${norm_stack[*]}"})"
  [ "$norm_path" = "/" ] || norm_path="${norm_path%/}"

  # 3. Physical resolution of the PARENT: walk from the dirname (never the
  #    leaf) up to the nearest existing directory, resolve it with pwd -P
  #    (following symlinks), then re-append the remainder and the leaf.
  #    Starting at the dirname unconditionally is load-bearing: an EXISTING
  #    file reached through a symlinked directory must still resolve to its
  #    real location. (Starting at the full path and stopping at the first
  #    thing that exists let `symlinked-dir/existing-file` through unresolved.)
  leaf="${norm_path##*/}"
  parent_path="${norm_path%/*}"
  [ -n "$parent_path" ] || parent_path="/"
  phys_path="$norm_path"
  ancestor="$parent_path"
  remainder=""
  while [ ! -d "$ancestor" ] && [ "$ancestor" != "/" ]; do
    remainder="${ancestor##*/}${remainder:+/}$remainder"
    parent="${ancestor%/*}"
    [ -n "$parent" ] || parent="/"
    ancestor="$parent"
  done
  if [ -d "$ancestor" ]; then
    resolved=$(cd -P "$ancestor" 2>/dev/null && pwd -P) || resolved=""
    if [ -n "$resolved" ]; then
      [ "$resolved" = "/" ] && resolved=""
      if [ -n "$remainder" ]; then
        phys_path="$resolved/$remainder${leaf:+/}$leaf"
      else
        phys_path="$resolved${leaf:+/}$leaf"
      fi
      [ -n "$phys_path" ] || phys_path="/"
    fi
  fi

  # 3b. If the final component itself is a symlink, follow the chain (capped)
  #     so a symlink FILE pointing at a protected target can't evade the match.
  #     Symlinked parents were handled above; this handles the leaf.
  hops=0
  while [ -L "$phys_path" ] && [ "$hops" -lt 8 ]; do
    target=$(readlink "$phys_path" 2>/dev/null) || break
    [ -n "$target" ] || break
    case "$target" in
      /*) phys_path="$target" ;;
      *)  phys_path="${phys_path%/*}/$target" ;;
    esac
    # Re-anchor: the target may contain .. or symlinked dirs of its own.
    tdir=$(cd -P "${phys_path%/*}" 2>/dev/null && pwd -P) || break
    phys_path="$tdir/${phys_path##*/}"
    hops=$((hops + 1))
  done

  base="${norm_path##*/}"
  phys_base="${phys_path##*/}"
  for pat in "${patterns[@]}"; do
    case "$pat" in
      */*)
        # Pattern has a slash: match full normalized AND physical path.
        # RHS is an intentional glob (config pattern), so it must stay unquoted.
        # shellcheck disable=SC2053
        if [[ "$norm_path" == $pat ]] || [[ "$phys_path" == $pat ]]; then
          block_reason="path"
          block "blocked write to protected path (matched pattern: $pat)" "$norm_path"
        fi ;;
      *)
        # No slash: match the basename — of the path as given AND as resolved.
        # shellcheck disable=SC2053
        if [[ "$base" == $pat ]] || [[ "$phys_base" == $pat ]]; then
          block_reason="path"
          block "blocked write to protected file (matched pattern: $pat)" "$norm_path"
        fi ;;
    esac
  done
fi

# ---------------------------------------------------------------------------
# Bash command lane — only for the Bash tool with a non-empty command.
# ---------------------------------------------------------------------------

if [ "$tool_name" = "Bash" ] && [ -n "$cmd" ]; then

  # (a) Destructive git blocklist (heuristic; FILE_GUARD_GIT=0 disables).
  #     Quote handling, in two passes: DEQUOTE whitespace-free quoted strings
  #     (so `git push "--force"` cannot hide a flag inside quotes), then STRIP
  #     quoted strings containing whitespace (so a commit message like
  #     -m "use reset --hard" cannot trip the subcommand rules). Then only
  #     inspect text that follows a `git` command word (start-of-line, or after
  #     ; && || | $( ` or newline) — never a substring inside another word —
  #     and keep each subcommand rule inside one pipeline segment ([^;&|]*) so
  #     `git push origin && tail -f log` does not read as a force-push.
  git_block() {   # git_block <subcommand-name>
    block_reason="git"
    block "destructive git $1. Run it yourself if you mean it (or set FILE_GUARD_GIT=0)." "$cmd"
  }
  if [ "${FILE_GUARD_GIT:-1}" != "0" ]; then
    unquoted=$(printf '%s' "$cmd" | sed \
      -e 's/"\([^"[:space:]]*\)"/\1/g' \
      -e "s/'\([^'[:space:]]*\)'/\1/g" \
      -e 's/"[^"]*"//g' \
      -e "s/'[^']*'//g")
    if printf '%s' "$unquoted" | grep -Eq '(^|[;&|`]|\$\()[[:space:]]*git([[:space:]]|$)'; then
      # push --force / push -f (bare). --force-with-lease and --force-if-includes
      # do NOT match: the pattern requires --force followed by space, =, or EOL.
      if printf '%s' "$unquoted" | grep -Eq 'git[[:space:]][^;&|]*\bpush\b[^;&|]*--force([[:space:]=]|$)'; then
        git_block "push --force"
      fi
      if printf '%s' "$unquoted" | grep -Eq 'git[[:space:]][^;&|]*\bpush\b[^;&|]*[[:space:]]-f([[:space:]]|$)'; then
        git_block "push -f"
      fi
      if printf '%s' "$unquoted" | grep -Eq 'git[[:space:]][^;&|]*\breset\b[[:space:]]+--hard\b'; then
        git_block "reset --hard"
      fi
      if printf '%s' "$unquoted" | grep -Eq 'git[[:space:]][^;&|]*\bfilter-(branch|repo)\b'; then
        git_block "filter-branch/filter-repo"
      fi
    fi
  fi

  # (b) Protected-path write heuristic (on the RAW command string).
  #     If any word looks like a protected path AND a write indicator is
  #     present, block. Reading a protected file is fine.
  # Any literal '>' counts as a write indicator (covers `> f`, `>>f`, `2>f`,
  # `&>f`, and no-space forms — deliberately coarse, erring toward blocking);
  # plus known writing commands as words, plus sed -i / --in-place.
  word_re='(^|[[:space:]])(tee|mv|cp|rm|dd|truncate|rsync|install|ln|touch|chmod|chown)([[:space:]]|$)'
  sed_i_re='(^|[[:space:]])sed([[:space:]]+-[a-zA-Z]*i|[[:space:]]+--in-place)'
  has_write=0
  case "$cmd" in *'>'*) has_write=1 ;; esac
  if [ "$has_write" = "0" ] && printf '%s' "$cmd" | grep -Eq "$word_re"; then has_write=1; fi
  if [ "$has_write" = "0" ] && printf '%s' "$cmd" | grep -Eq "$sed_i_re"; then has_write=1; fi

  if [ "$has_write" = "1" ]; then
    # Tokenize on whitespace, '=' (catches of=/--output= forms), and '>' (so a
    # no-space redirect like `2>/path/f` or `>>file` still yields the path).
    tokens=$(printf '%s' "$cmd" | tr '=>' '  ')
    set -f   # tokens are expanded unquoted below; never glob them against the FS
    for tok in $tokens; do
      # Strip surrounding quotes.
      tok="${tok#\"}"; tok="${tok%\"}"
      tok="${tok#\'}"; tok="${tok%\'}"
      [ -n "$tok" ] || continue
      # Resolve the common indirections literally (data substitution, no eval):
      # ~/, $HOME/, ${HOME}/. Other variables cannot be resolved — documented.
      # The single-quoted '$HOME' patterns are LITERAL on purpose: we match the
      # unexpanded text of the command and substitute our own $HOME — no eval.
      # shellcheck disable=SC2016
      case "$tok" in
        "~/"*)       tok="$HOME/${tok#"~/"}" ;;
        '$HOME/'*)   tok="$HOME/${tok#'$HOME/'}" ;;
        '${HOME}/'*) tok="$HOME/${tok#'${HOME}/'}" ;;
      esac
      case "$tok" in
        /*) rtok="$tok" ;;
        */*) rtok="${payload_cwd:-$PWD}/$tok" ;;
        *)  rtok="$tok" ;;   # bare word: test as basename only
      esac
      tbase="${rtok##*/}"
      for pat in "${patterns[@]}"; do
        case "$pat" in
          */*)
            # shellcheck disable=SC2053
            if [[ "$rtok" == $pat ]]; then
              block_reason="bash-write"
              block "command writes to a protected path (matched pattern: $pat). Run it yourself if intended." "$cmd"
            fi ;;
          *)
            # shellcheck disable=SC2053
            if [[ "$tbase" == $pat ]]; then
              block_reason="bash-write"
              block "command writes to a protected file (matched pattern: $pat). Run it yourself if intended." "$cmd"
            fi ;;
        esac
      done
    done
    set +f
  fi
fi

# Default: allow.
exit 0

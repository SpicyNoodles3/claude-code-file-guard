# file-guard

Protect your files from your own agent — one auditable bash script. `file-guard`
is a Claude Code [PreToolUse hook](https://docs.claude.com/en/docs/claude-code/hooks)
that blocks the agent from writing to paths you declare protected. It is one
readable script, `jq` is the only dependency, it fails closed, and it is honest
about what it cannot stop.

## Why

An agent with shell and file-write access can clobber a config, overwrite a data
file, or scribble into a dotfile — usually by accident, in the middle of an
otherwise-correct task. Claude Code exposes hooks as the enforcement point:
a `PreToolUse` hook runs before a tool executes and can veto it. That is the
right place to draw a line around files that should never be touched
automatically. Hook quality is now something people (and automated scanners)
actually audit, so the hook you install should be readable in five minutes.
This one is.

## What it does

- Blocks writes to any path matching your config, for:
  - the built-in `Edit`, `Write`, and `NotebookEdit` tools, and
  - **any** tool whose payload carries a `file_path` or `notebook_path`
    (custom and MCP tools get checked for free).
- Inspects `Bash` commands with two clearly-labelled heuristics:
  - a destructive-git blocklist (`push --force`/`-f`, `reset --hard`,
    `filter-branch`, `filter-repo`), and
  - a protected-path write detector (a token that matches a protected pattern
    plus a write indicator — any `>` in the command, or a write command word
    like `tee`, `mv`, `rm`, `dd`, `sed -i`, …). Tokens spelled `~/…`, `$HOME/…`,
    or `${HOME}/…` are resolved literally (no eval) before matching.
- Fails closed: if `jq` is missing, the config is missing or unreadable, or the
  input is not valid JSON (including empty input), the call is **blocked**, not
  allowed.
- Matches case-insensitively by default (macOS filesystems are
  case-insensitive), with an opt-out.
- Normalizes paths before matching: it expands `~/`, resolves `.` and `..`
  lexically, and follows symlinks — both symlinked parent directories and a
  symlink as the final component — so `../` traversal and symlink tricks
  resolve to the real target before the patterns are tested. Glob characters
  in a payload path are treated as literal filename characters, never expanded.

Blocked calls exit with code 2 and print a one-line `file-guard:` message to
stderr, which Claude Code feeds back to the model so it can adjust.

## What it does NOT do

Read this section before you rely on the tool.

`file-guard` prevents **cooperative accidents**. It is not a sandbox and it is
not a security boundary against a determined adversary. The hook sees only the
tool payload — a `file_path`, or the text of a `Bash` command — and it cannot
see inside an interpreter. A motivated agent (or a prompt-injected one) can get
around it in ways that are easy to enumerate:

- Write through an interpreter the hook can't read into: `python -c "open(...)"`,
  `node -e`, `perl -e`, a `<<'EOF'` heredoc, `printf | tee` via a subshell.
- Obfuscate the target: build the path from variables, base64-decode it, or
  assemble it at runtime so no literal token matches a pattern.
- Use a write tool or syscall the heuristics don't enumerate.

The Bash heuristics are heuristics on purpose. They err toward blocking (false
positives are acceptable; a false negative is the failure that matters), but
they will miss obfuscated writes. **If you need real containment, use an
OS-level mechanism** — `sandbox-exec` on macOS, a container, or running the
agent as a separate user with filesystem permissions that deny the writes
outright. `file-guard` complements those; it does not replace them.

**The guard can be disarmed by editing its own wiring.** The agent could edit
`.claude/settings.json` to remove the hook, or edit `.claude/file-guard.conf`
to delete a pattern. The recommended mitigation is to protect those files with
the guard itself — add these lines to your config:

```
.claude/file-guard.conf
.claude/settings.json
~/.claude/file-guard.conf
```

This makes disarming a **blocked, visible** action rather than a silent one. It
is not a hard lock: the same interpreter-level bypasses above still apply, and
the git-history/OS routes are out of scope. Treat it as a speed bump that turns
a quiet edit into a noisy one, not as a vault.

## Install

Two files, then a hook entry.

1. Copy the hook into your project (or your home `~/.claude/hooks/`):

   ```sh
   mkdir -p .claude/hooks
   cp hooks/file-guard.sh .claude/hooks/file-guard.sh
   chmod +x .claude/hooks/file-guard.sh
   ```

2. Create a config **before** enabling the hook — with no config found, the
   hook blocks everything (that is the fail-closed posture, and it will halt
   your agent until a config exists):

   ```sh
   cp file-guard.conf.example .claude/file-guard.conf
   # then edit .claude/file-guard.conf for your project
   ```

3. Register it as a `PreToolUse` hook in `.claude/settings.json`. The matcher
   covers the file-write tools plus Bash; the quoting matters if
   `$CLAUDE_PROJECT_DIR` contains spaces:

   ```json
   {
     "hooks": {
       "PreToolUse": [
         {
           "matcher": "Edit|Write|NotebookEdit|Bash",
           "hooks": [
             {
               "type": "command",
               "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/file-guard.sh\""
             }
           ]
         }
       ]
     }
   }
   ```

`jq` must be on `PATH` (`brew install jq` / `apt-get install jq`). If it is not,
every matched call is blocked with a message telling you to install it.

## Configuration

One glob pattern per line; `#` comments and blank lines are ignored; leading and
trailing whitespace is trimmed; `~/` expands to `$HOME`. The first config found
wins — there is no merging. Search order:

1. `$FILE_GUARD_CONFIG` (if set),
2. `$CLAUDE_PROJECT_DIR/.claude/file-guard.conf` (falls back to
   `$PWD/.claude/file-guard.conf` when `CLAUDE_PROJECT_DIR` is unset),
3. `$HOME/.claude/file-guard.conf`.

| Pattern                | Matches                                                        |
|------------------------|----------------------------------------------------------------|
| `.env`                 | any file named `.env`, in any directory (basename match)       |
| `*.pem`                | any `.pem` file anywhere (basename match)                      |
| `secrets/*`            | anything under a `secrets/` directory, at any depth            |
| `~/journal/*`          | anything under that absolute directory                         |
| `/etc/hosts`           | that exact absolute path                                       |

A pattern **containing a slash** is matched against the full normalized absolute
path (and the symlink-resolved physical path); if it is relative (no leading `/`
or `~/`), it matches at **any depth** — `.claude/settings.json` guards that file
in any project. A pattern **without a slash** is matched against the basename
only. Because `*` in a bash glob crosses `/` boundaries, `secrets/*` already
matches `secrets/prod/db.pem` — you do not need `secrets/**`.

## Options

Set these as environment variables (e.g. inside the hook `command`, or in your
shell before launching Claude Code):

| Variable                     | Default | Effect                                              |
|------------------------------|---------|-----------------------------------------------------|
| `FILE_GUARD_CASE_SENSITIVE`  | `0`     | `1` makes pattern matching case-sensitive.          |
| `FILE_GUARD_GIT`             | `1`     | `0` disables the destructive-git blocklist.         |
| `FILE_GUARD_LOG`             | unset   | Path to append one line per **blocked** decision.   |
| `FILE_GUARD_CONFIG`          | unset   | Explicit config path (overrides the search order).  |

The log line is tab-separated: ISO-8601 UTC timestamp, `BLOCK`, tool name,
reason, and the first 120 characters of the path or command. A logging failure
never changes the decision.

## Testing

```sh
bash tests/run_tests.sh
```

The harness creates an isolated temp sandbox (its own `HOME` and
`CLAUDE_PROJECT_DIR`), runs each case, prints a `PASS`/`FAIL` line per case with
a final tally, and exits non-zero if anything fails. CI runs it on
`ubuntu-latest` and `macos-latest`, plus a `shellcheck` job.

## Limitations

- Cooperative-accident prevention, not a sandbox — see
  [What it does NOT do](#what-it-does-not-do).
- The Bash lane is heuristic and errs toward blocking. Expect occasional false
  positives (a command that mentions a protected path near a write verb but
  isn't actually writing it); when that happens, run the command yourself or
  narrow the pattern. A false positive is a minor annoyance; a false negative is
  the failure this tool exists to avoid, so the bias is deliberate.
- The Bash lane tokenizes on whitespace: a protected path **containing spaces**
  is only reliably guarded on the tool lane (`Edit`/`Write`/…), not inside
  `Bash` command strings.
- Variable indirection in Bash commands is resolved only for literal `~/`,
  `$HOME/`, and `${HOME}/` prefixes. A path smuggled through any other variable
  (`$DIR/secret`) is not resolved — that falls under the obfuscation bullet
  above.
- It cannot see inside interpreters, heredocs, or obfuscated commands.

## License

MIT — see [LICENSE](LICENSE).

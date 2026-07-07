# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-07-07

Initial release.

### Added
- `hooks/file-guard.sh` — a Claude Code PreToolUse hook that blocks writes to
  files matched by a gitignore-style config. Covers Edit/Write/NotebookEdit and
  any tool payload carrying a `file_path`/`notebook_path`, plus two documented
  Bash heuristics (destructive-git blocklist and a protected-path write
  detector). Fail-closed on a missing dependency, missing/unreadable config,
  or malformed input. Bash 3.2 compatible; jq is the only dependency.
- `file-guard.conf.example` — commented example configuration.
- `README.md` — usage, an honest threat model, and configuration reference.
- `tests/run_tests.sh` — a self-contained test harness with fixture payloads.
- `.github/workflows/test.yml` — CI running the harness on Ubuntu and macOS,
  plus a shellcheck job.

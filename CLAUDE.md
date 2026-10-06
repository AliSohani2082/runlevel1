# llm-kit: working conventions

Read first: `docs/PRD.md` (the spec), `docs/contracts.md` (frozen
interfaces between the scripts), `docs/decisions.md` (where we deviate from
the PRD and why).

## Shell rules (both shipped scripts)

- **bash 3.2.** No `mapfile`/`readarray`, associative arrays, `${v,,}`/`${v^^}`,
  `[[ -v ]]`, `|&`, `&>>`, `;;&`, `coproc`, `wait -n`, negative array
  indexes, `declare -g`/`-n`, or `printf '%(…)T'`. `tests/lib/check-bash32.sh`
  catches most of these. `make test-bash32` is the real check.
- **bash 3.2 parser bug:** inside `$( … )`, write case patterns with a
  leading parenthesis, `case $x in (foo) …;; esac`, or the `)` ends the
  command substitution early.
- **`llm-kit.sh` uses only bash builtins and coreutils.** No grep, sed, awk,
  curl, jq, python or sudo. Read the manifest with the line-JSON helpers
  (reference: `tests/lib/linejson.sh`). Speak HTTP to llama-server over
  `/dev/tcp`. Stay under ~600 lines.
- **`setup.sh` uses only** bash, curl, lsblk/diskutil, sha256sum (or `shasum -a
  256`), tar, unzip and coreutils. grep and sed are fine (workstation). No jq,
  python or GNU-only flags where macOS differs.
- Every fatal path calls `die WHAT STATE NEXT CODE` (three readable lines,
  exit codes per contracts §8). Never `set -e`. Check statuses explicitly.
- Both scripts define `LLMKIT_VERSION="<contents of VERSION>"`. A test enforces it.
- Downloaded binaries, archives and models never go in the repo (D3).

## Tests

- `make check` before every commit; it must pass. `make test` runs
  `tests/run.sh`, which discovers `tests/**/*_test.sh`. Each file defines
  `test_*` functions plus optional `setup`/`teardown`. Every test runs in a
  fresh `$TEST_TMP`, as the current directory, inside its own subshell.
  Assertions are in `tests/lib/assert.sh` (`run`, `assert_eq`,
  `assert_contains`, `assert_status`, `skip`, `require_cmd`, …).
- Tests under `tests/contracts/` and `tests/llm-kit/` also run under bash 3.2
  + busybox with no jq (`make test-bash32`). Guard dev-only tools with
  `require_cmd`.
- A test must never touch a real block device, the network (unless it is
  explicitly an online test that skips by default), or anything outside
  `$TEST_TMP` and the dev cache.

## Dev cache: `~/.cache/llm-kit-dev/` (outside the repo)

```
downloads/   upstream release archives (llama.cpp, zot, Ventoy)
models/      GGUF files (e.g. stories260K.gguf for plumbing tests, qwen2.5-0.5b for real tool calls)
bin/linux-x86_64/  llama-server + libs (symlink-free, as on exFAT) and zot
queue.tsv    download queue processed by the fetch daemon (see its README.txt)
status.tsv   download progress
locks/       flock files shared by parallel agents
tools/bin/   shellcheck
```

The network is slow (tens of KB/s through a proxy). Never re-download what
the cache has. To fetch something large, append a line to `queue.tsv` and
check `status.tsv` later. Files in the cache are read-only for everyone
except whoever created them: copy or hardlink them into `$TEST_TMP` before
modifying anything.

## Working in parallel (agents)

Each milestone agent works in its own git worktree and branch and commits
only there. Integration happens on `dev`. To avoid stepping on each other:

- **Own your files.** Edit only the files your brief assigns you. If a
  contract (`docs/contracts.md`, fixtures, `models/catalog.json` schema) has to
  change, don't edit it. Write the proposed change in your final report.
- **Ports.** llama-server and other listeners bind 127.0.0.1 only, on your
  assigned port range: M1/integration 8080–8089, M2 18080–18099,
  M3 38080–38099, M4 28080–28099, M5 48080–48099, M6 58080–58099.
- **Inference lock.** This machine has 4 cores and about 8 GB of free RAM.
  Any process that runs a model must hold the shared lock for the whole
  time it computes. Wrap the command or test in
  `flock ~/.cache/llm-kit-dev/locks/inference.lock <cmd>`. Hold it per test
  case or per prompt, not for hours. Never run two ≥3B models at once.
- **Processes.** Kill only PIDs you started (record them in pid files).
  Never use `pkill`, `killall` or a pattern-based kill. Patterns match other
  agents' processes, and your own shell.
- **Config dirs.** Always set `ZOT_HOME` and `HOME` (for zot runs) to
  directories under your `$TEST_TMP` or scratch area. Never use the real
  `~/.local/state/zot`.
- **Containers.** podman containers must be `--rm`, with unique names
  prefixed by your milestone (e.g. `m4-…`).
- **Devices.** Never write to or format `/dev/sd*`, `/dev/nvme*`,
  `/dev/mmcblk*` or anything under `/run/media`. Ventoy installation is
  tested only on loop devices backed by image files you created, and only
  after checking `/sys/block/loopN/loop/backing_file` points at your file.

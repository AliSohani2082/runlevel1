# M2: model evaluation (tool calling, tokens/sec)

Goal (PRD M2, R1, D9): run a fixed set of DevOps prompts that need tool use
against each candidate model, record the tool-call success rate and CPU
tokens/sec, then set `tool_calling` in `models/catalog.json` and choose the
default model.

Reproduce: `eval/run-eval.sh MODEL_ID GGUF` (one model) or `eval/run-all.sh`
(every candidate in `eval/candidates.tsv` whose GGUF is in the dev cache).
Per-case results are in `eval/results/<id>.tsv`, one summary line per run in
`eval/results/runs.tsv`. Raw transcripts and server logs stay in
`~/.cache/llm-kit-dev/work/m2/`.

## Method

**Stack, exactly as llm-kit.sh will run it.** llama.cpp **b11429** router
mode with the contracts §7 command line (`--models-dir`, `--models-max 1`,
`--parallel 1`, `--jinja`, `-c <ctx_size>`, per-session API key). zot
**v0.4.17** with its `llama.cpp` provider and a `ZOT_HOME` rendered from
`config/` (our `AGENTS.md` included), `--json --no-session --max-steps 8`.
No sampling flags: the model gets the server's defaults, as users will.
The ZOT_HOME is re-rendered before every case, as llm-kit.sh does per launch.

**Isolation.** Each run is inside bubblewrap: no network (loopback only),
its own PID namespace, and the whole machine read-only except the run's work
directory. zot's json mode executes tool calls without asking, so this is
what keeps a confused model's `bash` calls away from real files. Each case
holds the shared inference lock while it computes.

**The suite** (`eval/cases.sh`): 20 tasks on a small "server snapshot"
(etc/, logs/, k8s/, diag/, a Dockerfile, a deploy script), fresh for every
case, always at the same path so zot's system prompt and the server's prompt
cache stay identical between cases.

| kind | cases |
|---|---|
| read a file and answer | nginx_port, oom_victim, fstab_var, ss_listener, disk_full |
| edit a file in place | k8s_replicas, sshd_root, cron_add, dockerfile_base, json_fix, k8s_env, hosts_entry |
| write a new file | write_motd, systemd_unit |
| find files | list_units |
| run a command | count_500, chmod_deploy, restore_backup, tar_etc |
| several steps | most_errors (count per file, then write the winner) |

Answers are not guessable from general knowledge: port 5432 belongs to
pgbouncer (postgres moved to 5433), the OOM log names the process that
*invoked* the killer (postgres) next to the victim (java), /var is xfs.

**Scoring.** A case **passes** when the model made at least one native tool
call (a `tool_use_start` event; a call printed as text does not count,
spike-m1 finding 15) **and** the outcome check passes: the file on disk is
right and the rest of it is intact, or the final reply contains the fact.
`tests/eval/eval_test.sh` proves every check fails on the untouched fixture
and passes after a reference solution, and rejects typical wrong outcomes.

Also recorded per case: tool names, tool errors (bad arguments, failed edit
matches), whether the model printed a tool call as text, steps, wall time,
prompt and generation tokens and tokens/sec from the server's own timing
lines, reasoning tokens.

## Criteria

`tool_calling` in the catalog, from one 20-case run:

| value | rule |
|---|---|
| `verified` | native tool calls in ≥ 90% of cases (18/20) **and** ≥ 75% of cases passed (15/20) |
| `broken` | native tool calls in < 50% of cases (fewer than 10/20), **or** < 25% of cases passed (fewer than 5/20): calls with nonsense arguments are as useless as no calls |
| `unverified` | anything in between: it calls tools, but not reliably enough to rely on |

The default becomes the `verified` model with the most passed cases; ties go
to the faster one on CPU (R8), then to the smaller download.

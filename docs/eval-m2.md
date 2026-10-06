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

Prompts write every workspace path as `./etc/hosts`, `./logs/kern.log`.
Suite 1 wrote `etc/hosts`, and models "corrected" that to the host's
`/etc/hosts` (Qwen3-4B did on its second case), which tests path guessing
rather than tool calling. Suite 2 is the one reported here; `runs.tsv`
records the suite version of every run.

`tar_etc` accepts the etc tree with or without its `etc/` prefix
(`tar -czf … etc` and `tar -czf … -C etc .` both archive the directory).
That check was loosened after Qwen3-4B's run; its archive was rescored from
the saved workspace, and no earlier run had created an archive at all.

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

## Results (suite 2)

Machine: 4 cores, about 8 GB free RAM, shared with other agents' builds and
tests (only model runs take the inference lock), so tokens/sec is a floor.
tok/s are totals over the run (all prompt or generated tokens / their time).

| model | native calls | passed | text-only calls | tool errors | prompt tok/s | gen tok/s | load | median case | verdict |
|---|---|---|---|---|---|---|---|---|---|
| Qwen2.5-0.5B-Instruct (baseline) | 19/20 | 3/20 | 0 | 53 | 94.4 | 19.3 | 2 s | 7 s | broken |
| Qwen2.5-Coder-7B-Instruct (current default) | 0/20 | 0/20 | 13 | 0 | 12.4 | 4.1 | 17 s | 24 s | broken |
| Qwen3-4B-Instruct-2507 | 20/20 | 14/20 | 0 | 8 | 15.8 | 3.4 | 12 s | 48 s | unverified |

**Qwen2.5-Coder-7B** confirms D9 on the full suite: not one native call; in
13 cases it printed the call as text, which zot does not run.

**Qwen2.5-0.5B** calls tools natively almost every time but with arguments
that rarely work (53 tool errors): wrong paths, edits whose `oldText` is not
in the file, invented commands.

**Qwen3-4B-Instruct-2507** calls tools natively in every case, and its calls
are well formed. Its six failures:

- In 4 cases (`fstab_var`, `sshd_root`, `cron_add`, `hosts_entry`) it turned
  the prompt's `./etc/…` into the host's `/etc/…` and read or tried to edit
  the real file. The sandbox kept the host read-only, so the edits failed,
  but on a real machine this edits system files the user did not name.
  A config repo with its own `etc/` is common in DevOps work, so this counts
  as the model's failure, not the suite's.
- `json_fix`: read the file twice and declared the JSON valid (it has a
  trailing comma).
- `most_errors`: counted correctly (11, billing) with bash, then wrote the
  first file name it had read (`logs/app-api.log`) into answer.txt.

## R2: the three DevOps models, checked against their repos (2026-10-06)

| id | repo (corrected) | GGUF file | size | licence | findings |
|---|---|---|---|---|---|
| `ulysses-7b` | `jalpan04/Ulysses` | `devops_model_q4_k_m.gguf` | 4,683,073,312 | apache-2.0 | **Gated** (auto-approved after accepting terms; downloads need an HF token with access). Base is Qwen2.5-Coder-7B (the base model, not Instruct). Fine-tuned in two QLoRA phases (continued pre-training on docs, then 8,076 ChatML Q&A pairs generated with the Gemini API and Ollama). No tool-use data. |
| `qweble-sol-4b` | `ukuwzi/Qweble-Sol-4B-GGUF` (the PRD's `-MLX` repo has only safetensors) | `Qweble-Sol-4B-Q4_K_M.gguf` | 2,708,804,064 | apache-2.0 | Qwen3.5-4B fine-tune. Keeps Qwen3.5's thinking mode (thinks by default). |
| `phi3-sysadmin` | `lalatendu/phi3-sysadmin-lalatendu` (`lalatendu/phi3-sysadmin` redirects there) | `phi3-sysadmin-Q4_K_M.gguf` | 2,318,919,552 | mit | Phi-3-mini-4k fine-tune on 1,026 Q&A pairs. **4,096-token context**: zot's system prompt and tool schemas take about 1,600 of it before the user speaks (spike-m1 #7). The author warns it may hallucinate commands. |

All three have a usable Q4_K_M GGUF and a licence that allows redistribution,
so none is dropped on R2 grounds.

## Download cap: no file over 3 GB

The owner capped every download for this project at 3 GB (2026-10-06): over
the dev machine's proxy a 4.7 GB file takes hours. Two candidates have no
file under the cap, so they are not evaluated here:

| id | smallest GGUF | other files |
|---|---|---|
| `ulysses-7b` | Q4_K_M, 4,683,073,312 bytes | F16 (15.2 GB); no smaller quant in the repo |
| `qwen2.5-7b-instruct` | Q4_K_M, 4,683,074,240 bytes | (a Q2/IQ2 quant would fit but would not say how the Q4_K_M ships) |

Qwen2.5-Coder-7B (4.68 GB) is evaluated only because it was already in the
dev cache from M1. `qweble-sol-4b` has a single GGUF (Q4_K_M, 2.71 GB) and no
third-party quants, which is under the cap.

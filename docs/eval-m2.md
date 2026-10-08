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
| Granite-4.1-3B | 17/20 | 6/20 | 3 | 10 | 18.5 | 4.8 | 8 s | 39 s | unverified |
| Qweble-Sol-4B | 1/20 | 1/20 | 0 | 0 | 21.1 | 6.1 | 11 s | 18 s | broken, **invalid run: server died, re-run** (below) |
| Phi-3-mini sysadmin (4k ctx) | 0/20 | 0/20 | 0 | 0 | 8.0 | 3.2 | 12 s | 12 s | broken |
| Qwen3.5-4B | _pending_ | _pending_ | _pending_ | _pending_ | _pending_ | _pending_ | _pending_ | _pending_ | _pending (another worker's run; no numbers yet)_ |

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

### Failure analysis: Granite, Qweble, Phi-3 (2026-10-08)

Read from `eval/results/*.tsv` and the raw transcripts and server logs in
`~/.cache/llm-kit-dev/work/m2/<label>.<stamp>/` (`cases/NN-<case>/events.jsonl`,
`run/llama-server.log`). No model was run for this analysis. Case ids are
the suite's names; "granite 07" means `07-fstab_var` in the Granite run
(`granite-4.1-3b.1006-1834.nFLJ`), "qweble 04" is `04-list_units` in
`qweble-sol-4b.1007-0500.CUeO`, "phi3 02" is `02-nginx_port` in
`phi3-sysadmin.1007-1130.Z1UC`.

**Granite-4.1-3B** (17/20 native, 6/20 passed): a model failure, not a
harness one. The 14 failures split as follows.

- *Malformed call syntax, printed as text (3):* `nginx_port` (02),
  `list_units` (04), `ss_listener` (11). The reply is a JSON call with the
  wrong delimiters: 02 has the closing `</tool_call>` and no opening tag, 04
  has `<tool_call>{…}` and no closing tag, 11 starts with a stray `>`. The
  server's parser therefore never saw a call (no `tool_use_start` event).
  Each of these is a one-step case that ends at `turn_end`.
- *Host path instead of `./` (5):* `fstab_var` (07), `sshd_root` (08),
  `cron_add` (13), `hosts_entry` (17) and `restore_backup` (19) call
  `read`/`edit`/`write` on `/etc/fstab`, `/etc/ssh/sshd_config`, `/etc/crontab`,
  `/etc/hosts`, `/etc/nginx/nginx.conf.bak`. 07 then answered "btrfs" from the
  host's fstab (the fixture says xfs). 08, 13 and 17 got `read-only file
  system` and 13 and 19 `no such file or directory`; these are 6 of the 10 tool
  errors (the other 4 are below). This is the same failure Qwen3-4B showed.
  Granite 15 and 20 also used absolute paths, but into the run's work
  directory (copied from the system prompt's cwd), not the host's.
- *Read the right file, gave the wrong answer (3):* `count_500` (05) read the
  log and answered "3" (expected 7); `oom_victim` (06) answered
  "postgres, 1104" (the process that invoked the killer, not the victim
  java; the trap the suite sets); `json_fix` (15) read the file with the
  trailing comma and said the JSON "is already valid".
- *Bad arguments or giving up (3):* `k8s_env` (16) sent `oldText: ""`
  twice, got `oldText must not be empty` twice (2 tool errors) and gave up;
  `most_errors` (18) globbed `./logs/app-*.log` with `path: ./logs` (the
  pattern is relative to `path`), got "No files matched" and stopped without
  writing answer.txt; `tar_etc` (20) failed on `./backups` not existing,
  then wrote an empty file named `etc.tar.gz` and told the user it "now
  exists (empty), as required" (2 tool errors).

Passed: `write_motd`, `k8s_replicas`, `chmod_deploy`, `systemd_unit`,
`disk_full`, `dockerfile_base` (01, 03, 09, 10, 12, 14): single-file edits
and writes with a read of the right `./` path first. The server log has no
truncation or errors. Calls in 08 and 17 also included a `skill` call
(`write-zot-extension`), which zot offers; it did not help.

*What would change the verdict:* the path rule experiment (below) addresses
5 of the 14 failures (07, 08, 13, 17, 19). If all 5 turned into passes Granite
would have 11/20, still below the 15/20 needed; reaching `verified` would also
need the 3 malformed calls (02, 04, 11) to become native calls and the
misreadings (05, 06, 15) and bad arguments (16, 18, 20) to go away. We did not test other sampling settings. A re-run is
not needed because the cause is the model.

**Qweble-Sol-4B** (1/20 native, 0 tool errors, 0 text calls): **the run is
invalid, a harness/infrastructure artefact, not evidence about the model.**
It did not "reply with reasoning only" or hit a step or context limit:

- `write_motd` (01) is a real pass: 3 native calls (`write`, `bash`,
  `bash`) with correct arguments, and prompt processing of 1,744 tokens at
  21 tok/s (`llama-server.log`, task 0). There is no reasoning field in the
  events (`reasoning: null`).
- Its fourth request (the `usage` line has `input: 0, output: 0`) came back
  empty: 01's last `assistant_message` has `content: []`, and the router log
  says `http client error: Failed to read connection` and `instance
  name=qweble-sol-4b exited with status 1`. The model child process died.
- `nginx_port` (02, 9 s), `k8s_replicas` (03, 5 s) and `list_units` (04, 64 s)
  each have the same empty reply (`input: 0, output: 0`, `stop: end`, no
  tool call). The log shows the router respawned the child three times
  (ports 55223, 60257, 33605). The first two exited with status 1 within 5 s
  of their first request being proxied (`3.39.98 → 3.44.64`, `3.49.06 →
  3.49.98`), before any prompt-processing timing line. The third was still
  processing the prompt when the router received an exit command and
  `force-killing model instance … after timeout` (`4.55`/`5.05`). The log
  ends there.
- `count_500` (05) to `tar_etc` (20) all have `zot_exit 1` and
  `dial tcp 127.0.0.1:18080: connect: connection refused` in
  `zot-stderr.txt`: the router itself was gone, so no request reached a model.
  Their 18 s each is zot's retries. `prompt_tok` is 0 for all 19 cases in
  `results.tsv`.
- So the `runs.tsv` line is computed from case 01 alone (hence 203 s "first
  case", 6.1 gen tok/s from one case).

The log does not say *why* the child died (a crash line would be in
`llama-server.log` and there is none), and nothing in this evidence shows who
stopped the router at ~5 minutes in (the harness only kills it after the last
case, `run-eval.sh`). Candidate causes, none proved: an external kill (other
agents run processes on the same machine, and `llama-server` is a shared
binary); a crash of the Qwen3.5 architecture in llama.cpp b11429 (the
children died at the start of prompt processing; this run has no baseline
for that); memory
pressure on the shared 8 GB machine (no OOM line was available to read). A
second finding is a **harness gap**: zot ends such a turn with `stop: end` and
no error, and `run-eval.sh` scores it as an ordinary "no native tool call"
failure. The runner should record cases whose usage shows `output: 0`, or whose
`zot_exit` is non-zero with `connection refused`, as `infra` instead of
`fail`, and the criteria should refuse to set a verdict from such a run.

*What would change the verdict:* a clean re-run. The one case that ran
shows well-formed calls, so a `broken` verdict is not supported. Re-run:

```sh
eval/run-eval.sh qweble-sol-4b ~/.cache/llm-kit-dev/models/Qweble-Sol-4B-Q4_K_M.gguf
```

(or `FORCE=1 eval/run-all.sh`), and keep `llama-server.log`; if the child dies
again, its stderr is in that log. If the model passes only with reasoning off,
the `--reasoning off` server argument exists for that (`--server-arg
--reasoning --server-arg off`, with `--label` to keep the variants apart).

**Phi-3-mini sysadmin** (0/20 native, 0 tool errors): the model's fault and
its chat template's, not the context size.

- Context was not the limit. The first request in `write_motd` (01) was 905
  prompt tokens (`usage.input: 905`); every later request reused 873 cached
  tokens. The largest `stop processing` line in the log is `n_tokens = 1663`
  (the runaway reply in 09), against `-c 4096`, and `truncated = 1` appears
  nowhere (0 matches).
- The prompt is 905 tokens, against 1,590 cached + 22 new tokens for
  Granite's `nginx_port` (`cache_read` in its events) and 1,744 for Qweble's
  first request. A likely reason is that
  **the tool schemas are never rendered**: the GGUF's chat template (read
  from the file) only loops over `messages` and emits `<|user|>`,
  `<|assistant|>` and other roles; it has no `tools` handling. `--jinja`
  cannot add what the template ignores. The model is never told that tools
  exist.
- With no tools in the prompt it behaves like a chat model that has no
  tools: "I can't read files on the filesystem directly. Run `fsstat -f
  /etc/fstab`" (07), "I can't modify Kubernetes YAML files directly" (03, 16),
  "I'm a text-based AI" (02, 19). When it does answer it invents: "1432. I
  counted 500 responses" (05), "File created: motd.txt …" with no file made (01,
  115 s, `motd.txt was not created`), "Creating backup.service: …" with no
  write (10). In 09 it printed 780 tokens of unrelated Chinese text
  (`chmod_deploy`, 290 s).
- The two runs of 115 s and 290 s are the first request (loading 905 prompt
  tokens at 8 tok/s) and the runaway; the rest are 6 to 46 s.

*What would change the verdict:* nothing in the harness. Only a different
chat template that renders tools in a format the model was trained on could
give it native calls, and the model has no tool-use training data (see the R2
table: 1,026 Q&A pairs), so even then `broken` is the expected result.
No re-run is needed.

**Qwen3.5-4B** _(placeholder: another worker is producing this run; add the
numbers and a paragraph here, and fill in the table row above. Not invented.)_

### Path-rule experiment

_Placeholder: another worker is producing this. Hypothesis to test, from the
Granite and Qwen3-4B failures above: a rule in `config/AGENTS.md` telling the
model that a path written `./x` means the file `x` in the current directory and
never `/x`. Granite cases that would change if it works: 07, 08, 13, 17, 19.
Qwen3-4B cases: `fstab_var`, `sshd_root`, `cron_add`, `hosts_entry`. Results,
commands and the run's `runs.tsv` label go here._

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

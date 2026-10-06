# M1 spike: router mode, offline load, one tool call

Goal (PRD M1): with the network cut, start `llama-server` in router mode with
a GGUF already in `--models-dir`, load it, and get zot to complete one tool
call. This settles R3 and R4 before any script is written.

Reproduce: `spike/m1-router-offline.sh BIN_DIR MODEL.gguf [MODEL_ID]`. It
re-executes itself under `unshare -rn` (new user + network namespace, so
only loopback exists, with no route and no DNS) and checks each step.

Tested on 2026-10-05/06, linux-x86_64 (i7-8550U, 4C/8T, 15 GiB RAM), with
**llama.cpp b11429** (`llama-server --version`: `0.6.0-dev (build 11429,
commit d81235049)`) and **zot v0.4.17**.

## Results

| check | result |
|---|---|
| Network really cut (no outbound TCP, no DNS) | pass |
| `llama-server` router mode: no `-m`, `--models-dir`, `--models-max 1`, `--parallel 1`, `--jinja` | pass, `/health` 200 in about 1 s |
| Router names a `--models-dir` entry by **file stem** (`stories260k.gguf` → `stories260k`) | pass; confirms D7 |
| `POST /models/load` over bash `/dev/tcp` (HTTP/1.0) → `status.value` = `loaded` | pass, about 1 s for a tiny model |
| Router runs each model as a child `llama-server` on a random 127.0.0.1 port and proxies to it | observed |
| Per-session API key: `/health` public, `/models` and `/models/load` return 401 without it | pass |
| zot with only a rendered `ZOT_HOME` (`config.json`, `auth.json`, `models.json`, `AGENTS.md`) plus `LLAMA_API_KEY` runs a turn fully offline | pass (exit 0) |
| `zot --list-models` shows `llama.cpp/<id>` with `source=user` from our `models.json` | pass |
| SIGTERM to the router stops its child instances ("unload_all … exited with status 0") | pass |
| **One tool call**, Qwen2.5-0.5B-Instruct Q4_K_M | **pass**: native `write` call, `hello.txt` = `hello from llm-kit`, 20 s end to end |
| **One tool call**, Qwen2.5-Coder-7B-Instruct Q4_K_M (the PRD default) | **fail, 0 of 3**: the model prints the call as text in a code block (```` ```json {"name": "write", …} ``` ````) instead of a native `<tool_call>`, so llama.cpp returns plain content and zot executes nothing. An AGENTS.md instruction did not change this. `--chat-template chatml` dropped the tool schemas entirely. |

**M1 verdict: the architecture holds.** A native tool call works end to
end, offline, through router mode. **But R1 now applies to the default
model** (see D9): Qwen2.5-Coder-7B-Instruct does not emit native tool calls
in this stack, so M2 must pick and verify a replacement default first.

**R3 resolved** for the current latest build: b11429 supports router mode
as zot expects. **R4 resolved**: a GGUF dropped into `--models-dir` is
listed and loadable with no network, and zot reaches it through its
`llama.cpp` provider. The `-m` single-model fallback is not needed.

## Findings that bind the scripts

1. **Minimal llama-server payload (linux-x86_64): 22 files, 41 MB.** The
   release archive is flat but uses symlink chains
   (`libllama.so -> libllama.so.0 -> libllama.so.0.6.0`), which exFAT
   cannot hold. Ship each library once, **under the name the loader
   asks for** (the SONAME; `cp -L`), and drop the dev symlinks:
   `llama-server` (a 17 KB stub), `libllama-server-impl.so`,
   `libllama-common.so.0`, `libmtmd.so.0`, `libllama.so.0`, `libggml.so.0`,
   `libggml-base.so.0`, `libggml-rpc.so`, and every `libggml-cpu-*.so`
   (CPU variants, picked at runtime). `RUNPATH=$ORIGIN`, so libraries are
   found next to the binary. None of the other tools in the archive
   (llama-cli, llama-bench, …) are needed.
2. **Host requirements of the llama.cpp Linux build:** glibc ≥ 2.34,
   `libstdc++.so.6`, `libgcc_s.so.1` and **OpenSSL 3** (`libssl.so.3`,
   `libcrypto.so.3`). That means Ubuntu 22.04+, Debian 12+, Fedora 35+,
   current Arch/SystemRescue. Not Alpine (musl) and not Ubuntu 20.04 /
   Debian 11 (OpenSSL 1.1). llm-kit.sh should run `llama-server
   --version` first and turn a loader error ("error while loading shared
   libraries: libssl.so.3") into a readable failure (R5).
3. **zot is a static binary** (Go, about 25 MB). It runs anywhere, musl included.
4. **HTTP over `/dev/tcp` works**, using HTTP/1.0 (so no chunked responses),
   `Content-Length` and reading headers up to the blank line. To silence
   "connection refused" while polling, wrap the open:
   `{ exec 3<>/dev/tcp/127.0.0.1/$port; } 2>/dev/null`. A `2>/dev/null` on
   the `exec` itself is too late.
5. **The router's JSON is compact** (`"id":"x"`, `"status":{"value":"loaded"`).
   A model's status can be read with two parameter expansions:
   strip through `"id":"<id>"`, then through `"status":{"value":"`.
6. **Per-session API key.** The router warns that CORS allows all origins,
   so any web page in a local browser could drive it. Generate a key per
   launch (`od -An -tx1 -N16 /dev/urandom`, then remove non-hex characters
   with `${k//[!0-9a-f]/}`) and pass it via the **environment**:
   `LLAMA_ARG_API_KEY` for llama-server (keeps it out of `ps`) and
   `LLAMA_API_KEY` for zot. `/health` stays unauthenticated, so readiness
   polling needs no key. Management calls send `Authorization: Bearer`.
7. **Context budget.** zot's first request is about **2,000 prompt tokens**
   (system prompt + tool schemas + our AGENTS.md) before the user says
   anything. With `-c 2048` the prompt was truncated. Use ≥ 8192; 16384
   for 7B models. A 4k-context model (phi3) is marginal (M2 to judge).
8. **`--parallel 1`** is accepted in router mode and passed to the
   children. One slot keeps zot's prompt prefix cached and the KV memory
   predictable.
9. **zot print/json modes read piped stdin to EOF.** In tests or scripts
   that are not on a TTY, run zot with `</dev/null` or it waits forever.
   Interactive launches from llm-kit.sh are unaffected.
10. **`zot --list-models` does not query the router.** It shows the
    catalog, the discovery cache and `models.json`. The interactive `/model`
    picker does refresh from the router. Registering the model in
    `models.json` (as the template does) makes it visible either way, with
    our context size.
11. A stale `models-cache.json` in `ZOT_HOME` (6 h TTL) can hide live
    models. llm-kit.sh should render a fresh `ZOT_HOME` config on every
    launch and may delete `models-cache.json`.
12. **Version naming.** llama.cpp tags builds `bNNNNN`, but on 2026-10-05
    it also published a `v0.6.0` release **with no binaries**. setup.sh's
    "latest" must mean the newest release that carries the needed asset
    (D1).
13. The web UI is enabled by default on the router port (127.0.0.1 only).
    It is harmless and protected by the same key. `--no-webui` is
    available if we want less surface.
14. **Throughput on this CPU (i7-8550U, 4 threads, Q4_K_M), router + `--parallel 1`:**

    | model | prompt eval | generation | first zot turn (≈1,550 prompt tokens) |
    |---|---|---|---|
    | Qwen2.5-0.5B-Instruct | 115 tok/s | 21 tok/s | ≈ 16 s |
    | Qwen2.5-Coder-7B-Instruct | 11.7 tok/s | 3.0 tok/s | ≈ 140 s |

    The model loads in 2 s (0.5B) and 23 s (7B, cold page cache). The prompt
    cache works: zot's second turn processed only the 93 new tokens. A 7B
    model is usable but slow on a laptop CPU: every fresh conversation
    waits about 2 minutes for its first answer (R8). 3–4B models with native
    tool calling deserve a serious look in M2.
15. **Tool-call format is a property of the model, not of zot or the
    router.** The general Qwen2.5 Instruct line (0.5B) emits native
    `<tool_call>` blocks that llama.cpp parses. The Coder 7B variant prints
    a JSON code block. M2's harness must count only real `tool_use_start`
    events. A tool name in assistant text is not a tool call (the first
    version of this spike made exactly that mistake).
16. Forcing `--chat-template chatml` is **not** a workaround. With it,
    llama.cpp b11429 sends no tool schemas (prompt fell from 1,552 to 800
    tokens) and the model improvises shell commands in text.

# Contracts

This file defines the interfaces between `setup.sh` (the stick builder) and
`llm-kit.sh` (the host installer). It also defines the formats of the files
they share. Both scripts are developed in parallel, so treat everything here
as frozen. A change needs a matching change to `tests/contracts/` and to the
fixtures in `tests/fixtures/`, made in the same commit.

## 1. Canonical JSON ("line JSON")

`llm-kit.sh` has to read `manifest.json` on hosts that have only bash 3.2
and coreutils: no `jq`, `python`, `awk`, `sed` or `grep` can be assumed.
`setup.sh` must also avoid `jq` (PRD: curl, lsblk/diskutil, sha256sum, tar
and unzip only). So the files we own are valid JSON written in a
line-oriented canonical form that a few lines of bash can parse with `[[ =~ ]]`:

1. UTF-8, LF line endings, 2-space indent, no tabs, final newline.
2. One top-level object. Each top-level scalar sits on its own line:
   `  "key": value,`
3. A top-level array of records is written as `  "name": [`, then one
   record per line, then `  ],`. **Each record is a single-line object
   whose first member is `"type": "<record type>"`.** This lets a parser
   find records by type without tracking nesting.
4. A top-level object value, such as `"provider"`, is written on one line.
5. Member separator `, ` and key separator `": "`. Readers should
   still accept any amount of space around `:` and `,`.
6. String values never contain `"`, `\`, or control characters. Writers
   must reject or sanitise such input. This is what lets readers match
   strings with `"key": *"([^"]*)"`.
7. Numbers are non-negative integers. No floats and no exponents. Sizes
   are bytes; RAM figures are MiB.
8. Booleans are `true` or `false`. There is no `null`: an absent value is an
   empty string `""` or `0`.
9. Key order inside a record is fixed by the schemas below. Readers must
   not rely on it, apart from `type` coming first.

`tests/contracts/` validates every fixture and file we ship against these
rules using `jq` (dev-only dependency).

### Reading it from bash 3.2 (reference)

```bash
# json_str LINE KEY  -> prints the string value of KEY in LINE, or nothing
json_str() {
  local re="\"$2\"[[:space:]]*:[[:space:]]*\"([^\"]*)\""
  [[ $1 =~ $re ]] && printf '%s\n' "${BASH_REMATCH[1]}"
}
# json_num LINE KEY  -> prints the integer/boolean value of KEY in LINE
json_num() {
  local re="\"$2\"[[:space:]]*:[[:space:]]*([0-9]+|true|false)"
  [[ $1 =~ $re ]] && printf '%s\n' "${BASH_REMATCH[1]}"
}
# Iterate records of one type:
while IFS= read -r line; do
  case $line in *'"type": "file"'*) ;; *) continue ;; esac
  path=$(json_str "$line" path)
done < manifest.json
```

The regex lives in a variable because bash 3.2 and 4+ quote `=~`
operands differently.

## 2. Identifiers

### Platforms

| id              | `uname -s` | `uname -m`       | zot asset            | llama.cpp asset                 |
|-----------------|------------|------------------|----------------------|---------------------------------|
| `linux-x86_64`  | Linux      | x86_64, amd64    | `linux_amd64.tar.gz` | `bin-ubuntu-x64.tar.gz`         |
| `linux-aarch64` | Linux      | aarch64, arm64   | `linux_arm64.tar.gz` | `bin-ubuntu-arm64.tar.gz`       |
| `darwin-arm64`  | Darwin     | arm64, aarch64   | `darwin_arm64.tar.gz`| `bin-macos-arm64.tar.gz`        |
| `darwin-x86_64` | Darwin     | x86_64           | `darwin_amd64.tar.gz`| `bin-macos-x64.tar.gz`          |

Full upstream names: `zot_<ver>_<os>_<arch>.tar.gz` (plus `checksums.txt`) and
`llama-<tag>-bin-<flavour>.tar.gz`. The llama.cpp CPU build is always the
baseline. GPU builds are out of scope for v1.

### Backends

`local` (llama.cpp + bundled model, works offline), `online` (zot only,
cloud provider) and `both` (local is the default, the cloud provider is a
fallback). Stored in the manifest as `backend`. `llm-kit.sh` branches on
this value and never infers the backend from which files exist.

### Providers (online / both)

| choice      | zot provider id | key env var          | base URL default                              |
|-------------|-----------------|----------------------|-----------------------------------------------|
| Anthropic   | `anthropic`     | `ANTHROPIC_API_KEY`  | (zot built-in)                                |
| OpenAI      | `openai`        | `OPENAI_API_KEY`     | (zot built-in)                                |
| Gemini      | `google`        | `GEMINI_API_KEY`     | (zot built-in)                                |
| OpenRouter  | `openrouter`    | `OPENROUTER_API_KEY` | (zot built-in)                                |
| Custom      | `custom`        | `CUSTOM_API_KEY`     | user-supplied, OpenAI-compatible `.../v1`     |
| Decide later| (empty)         | (none)               | user runs `/login` in zot                     |

The local provider is zot's `llama.cpp` provider. It is configured through the
`LLAMA_BASE_URL` environment variable (router URL without `/v1`) and needs
no key.

### Model ids

Lowercase `[a-z0-9._-]+`. On the stick a model is always stored as
`models/<id>.gguf`, whatever the upstream file is called. The router
derives its model name from the file name, so the catalog id, the stick file
name and the router model name stay the same. M1 confirms this.

## 3. `models/catalog.json` (repo, read by `setup.sh`)

```json
{
  "schema": 1,
  "default": "qwen2.5-coder-7b-instruct",
  "models": [
    {"type": "model", "id": "…", "menu": "…", "params": "7B", "repo": "org/name", "file": "x.gguf", "revision": "main", "approx_bytes": 0, "min_ram_mb": 0, "ctx_size": 16384, "chat_template": "embedded", "license": "apache-2.0", "redistributable": "yes", "tool_calling": "unverified", "status": "available", "notes": "…"}
  ]
}
```

| field             | meaning |
|-------------------|---------|
| `id`              | Model id (see above). Unique. |
| `menu`            | The menu line after the id column, exactly as shown in the PRD's Menu text (size, base, caveat, RAM). |
| `params`          | Display string, e.g. `7B`, `3.8B`. |
| `repo`, `file`    | Hugging Face repo and the GGUF file inside it. `file` may be `""` only when `status` is not `available`. |
| `revision`        | Branch, tag or commit to download. `main` by default: setup.sh takes the **latest** revision (decision D2). |
| `approx_bytes`    | Approximate size, used for menus and space warnings before anything is resolved. The exact size and sha256 come from the HF API at build time. |
| `min_ram_mb`      | Rough RAM requirement. llm-kit.sh warns below it. |
| `ctx_size`        | Context size llm-kit.sh passes to llama-server for this model. |
| `chat_template`   | `embedded` (use the GGUF's template with `--jinja`) or a llama.cpp built-in template name to force. |
| `license`         | SPDX-ish id from the model card, or `unknown`. |
| `redistributable` | `yes`, `no` or `unknown`. setup.sh refuses `no` and warns on `unknown` (R9). |
| `tool_calling`    | `verified`, `unverified` or `broken`, set by M2's evaluation. |
| `status`          | `available` (repo and file checked), `unverified` (not yet checked; hidden unless `--allow-unverified`) or `dropped` (never offered; `notes` says why). |
| `notes`           | Free text, for example why a model was dropped. |

Menu rendering (both scripts), one line per model:

```
<n>) <id padded to 26>  <params>, <menu>[  [default]]
```

## 4. `llm-kit/manifest.json` (stick, written by `setup.sh`, read by `llm-kit.sh`)

```json
{
  "schema": 1,
  "llmkit_version": "0.1.0-dev",
  "created_at": "2026-10-05T20:00:00Z",
  "backend": "local",
  "default_model": "qwen2.5-coder-7b-instruct",
  "provider": {"id": "", "base_url": "", "model": "", "key_env": "", "key_embedded": false},
  "server": {"port": 8080, "host": "127.0.0.1"},
  "platforms": [
    {"type": "platform", "id": "linux-x86_64", "zot_version": "v0.4.17", "llama_version": "b11429"}
  ],
  "models": [
    {"type": "model", "id": "qwen2.5-coder-7b-instruct", "file": "models/qwen2.5-coder-7b-instruct.gguf", "params": "7B", "menu": "…", "size": 4683073536, "sha256": "…", "min_ram_mb": 8192, "ctx_size": 16384, "chat_template": "embedded", "license": "apache-2.0", "tool_calling": "unverified"}
  ],
  "artifacts": [
    {"type": "artifact", "component": "zot", "platform": "linux-x86_64", "version": "v0.4.17", "url": "https://…", "size": 0, "sha256": "…"}
  ],
  "files": [
    {"type": "file", "path": "bin/linux-x86_64/zot", "size": 0, "sha256": "…", "mode": "exec", "platform": "linux-x86_64", "component": "zot"}
  ]
}
```

Rules:

- `schema` is the format version. llm-kit.sh refuses a schema it does not
  know. `llmkit_version` must equal the `LLMKIT_VERSION` baked into
  llm-kit.sh. On a mismatch it refuses, with a clear message (H1).
- `backend` is one of `local`, `online` or `both`. With `online`, `models` is
  empty and no `llama-server` files exist.
- `provider.id` is empty for `local` and for "decide later".
  `provider.key_embedded` is `true` only with `--embed-key`; the key then
  lives in `config/api-key` (one line, no newline needed). That file is never
  listed under `files` (its hash would just be a second copy of the
  secret).
- `default_model` is a `models[].id`, or `""` when `backend` is `online`.
- `artifacts` records **what was downloaded**: the upstream URL, the resolved
  version or revision, size and sha256 of the downloaded archive or GGUF.
  These are the provenance records (S7).
- `files` records **every file under `llm-kit/` on the stick** except
  `manifest.json` itself and `config/api-key`. Each has a path relative to
  `llm-kit/`, a size and a sha256. `mode` is `exec` for anything that
  must be `chmod +x` on the host (exFAT has no permission bits) and `data`
  otherwise. `platform` is `""` for platform-independent files.
  `component` is one of `zot`, `llama`, `model`, `config`, `doc` or
  `installer`.
- Shared libraries that llama-server needs sit next to it in
  `bin/<platform>/`, flattened. exFAT has no symlinks, so each library is
  stored **once, under the name the loader asks for** (its SONAME, e.g.
  `libllama.so.0`, copied with `cp -L`), and the dev symlinks (`libllama.so`)
  and fully versioned names (`libllama.so.0.6.0`) are dropped. Only
  `llama-server`, its libraries and the `libggml-*` backends are shipped;
  the other tools in the archive are not. The list for linux-x86_64 is in
  docs/spike-m1.md, finding 1.
- llm-kit.sh trusts nothing outside `files`. Before using a file it checks
  size and sha256 against the manifest. A mismatch aborts, with no warn-only
  mode (Integrity NFR).

## 5. Stick layout

As in the PRD, plus the naming rules above:

```
llm-kit/
├── llm-kit.sh        # copied last, together with docs/README.txt
├── manifest.json
├── VERSION
├── bin/<platform>/   # zot, llama-server, lib*.so / *.dylib, ggml backends
├── models/<id>.gguf
├── config/zot-config.json   config/models.json   config/AGENTS.md   [config/api-key]
└── docs/README.txt
```

## 6. Host install layout (`llm-kit.sh`)

```
<dest>/                       # default $HOME/.llm-kit, else /tmp/llm-kit
├── bin/                      # copied from bin/<platform>/, chmod +x
├── models/<id>.gguf          # unless "run from stick" was chosen
├── zot-home/                 # ZOT_HOME: config.json, models.json, AGENTS.md
├── run/                      # llama-server.pid, llama-server.log
└── .llm-kit-install          # marker: version, platform, model, so --uninstall is safe
```

`--uninstall` removes `<dest>` only if it holds the `.llm-kit-install`
marker, and it never touches the stick.

## 7. Process contract (launch, H6). Verified in M1 (docs/spike-m1.md)

```
LLAMA_ARG_API_KEY=<session key> \
llama-server --host 127.0.0.1 --port <port> --models-dir <models dir> \
  --models-max 1 --parallel 1 --jinja -c <ctx_size> [--chat-template <t>]   # router mode: no -m
```

- **Session key.** For each launch, generate 16 random bytes as hex from
  `/dev/urandom` (`od -An -tx1 -N16`, then remove non-hex characters). Pass
  it to the server in the environment (`LLAMA_ARG_API_KEY`, never on the
  command line) and to zot as `LLAMA_API_KEY`. Never write it to disk.
- **Preflight.** Run `bin/llama-server --version` first. If it fails, map
  the loader error (missing `libssl.so.3`, too-old glibc) to a readable
  failure (exit 3).
- **Readiness.** Poll `GET /health` (unauthenticated) until HTTP 200, or
  time out with a readable error that includes the tail of the server log.
  Then `POST /models/load {"model":"<id>"}` with `Authorization: Bearer
  <key>`, and poll `GET /models` until that model's `status.value` is
  `loaded`, or `"failed":true` appears.
- HTTP goes over bash's `/dev/tcp` using HTTP/1.0. The router's JSON is
  compact (`"id":"x"`).
- **zot.** zot runs with `ZOT_HOME=<dest>/zot-home`,
  `LLAMA_API_KEY=<key>`, cwd = the user's current directory, and
  `--no-yolo` (R10: permission prompts on by default). `ZOT_HOME` is
  rendered on every launch from `config/` templates:
  `config.json`, `auth.json` (router URL only, mode 600), `models.json` and
  `AGENTS.md`. Delete `models-cache.json` before launch.
- **Exit.** On exit, llm-kit.sh stops only the llama-server PID it
  started. The router then stops its child instances. It never kills
  anything by name.

### Template placeholders (`config/*.json`)

| placeholder | value |
|---|---|
| `@PROVIDER@` | `llama.cpp` for local/both, else the manifest's `provider.id` |
| `@MODEL_ID@` | chosen model id (local/both), else `provider.model` (may be empty) |
| `@MODEL_NAME@` | display name, e.g. `<id> (local)` |
| `@CTX_SIZE@` | the model's `ctx_size` (also passed to llama-server `-c`) |
| `@MAX_TOKENS@` | max output tokens: `4096`, or `ctx_size/4` if that is smaller |
| `@LLAMA_URL@` | `http://127.0.0.1:<port>` |

Substitute with bash `${s//@X@/value}`. Values never contain `@`.

## 8. CLI conventions (both scripts)

- Every interactive prompt also has a flag. `--yes` accepts every default,
  `--non-interactive` fails instead of prompting, and `-h/--help` and
  `--version` behave as usual.
- `-` is never a prompt answer. Defaults are shown in `[brackets]`, and
  Enter accepts them.
- Messages go to stderr with a `llm-kit:` or `setup:` prefix. Only
  requested data goes to stdout.

### Exit codes

| code | meaning |
|------|---------|
| 0 | success |
| 1 | unexpected internal error |
| 2 | usage error (bad flag or value) |
| 3 | precondition not met (unsupported platform, missing tool, no matching payload) |
| 4 | integrity failure (manifest invalid, version mismatch, checksum mismatch) |
| 5 | aborted by the user |
| 6 | network or download failure (setup.sh) |
| 7 | resources (disk space, RAM, port in use) |

### Readable failure

Every fatal error prints three lines and exits with one of the codes above:

```
llm-kit: error: <what failed>
llm-kit:   state: <what state the system is in now>
llm-kit:   next:  <what the user should do>
```

## 9. Environment variables

| variable | used by | meaning |
|----------|---------|---------|
| `LLMKIT_CACHE_DIR` | setup.sh | Download cache. Default `${XDG_CACHE_HOME:-$HOME/.cache}/llm-kit`. Re-runs reuse verified files. |
| `HTTPS_PROXY`, `ALL_PROXY` | setup.sh | Honoured. `--proxy URL` overrides them. |
| `GITHUB_TOKEN` | setup.sh | Optional, to avoid GitHub API rate limits. |
| `LLMKIT_GITHUB_API`, `LLMKIT_HF_BASE` | setup.sh | Test-only base-URL overrides (default `https://api.github.com`, `https://huggingface.co`). |
| `LLMKIT_PORT` | llm-kit.sh | llama-server port (default from the manifest, 8080). `--port` overrides it. |
| `LLMKIT_DEST` | llm-kit.sh | Destination directory. `--dest` overrides it. |

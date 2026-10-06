# llm-kit — PRD

A portable, offline DevOps/SRE assistant on a Ventoy USB stick

Oct 5, 2026 · @Ali Sohani

## Summary

llm-kit turns a Ventoy USB stick into a self-contained, offline DevOps assistant: a bootable multi-ISO rescue drive that also carries a coding-agent harness (zot), an inference server (llama.cpp) and an open-weight model tuned for systems work. Boot any machine, run one script, and get a working agent with no network and no package manager.

The problem it solves: an engineer at a broken or air-gapped machine has rescue media but no assistant. Cloud agents need internet and send machine details to a third party. Installing a local stack by hand on a live session means fetching gigabytes over a connection that may be slow, filtered or absent.

Local inference is the default rather than the only option. The stick can also be built as zot alone, pre-configured for a cloud provider, for users who have a connection and would rather spend megabytes than gigabytes.

The project is two shell scripts. `setup.sh` runs once on a prepared workstation with internet and builds the stick. `llm-kit.sh` runs on the host machine after boot and stages the right binaries and model into a working directory.

## Goals and non-goals

**Goals**

- One command on a prepared workstation produces a ready stick.
- One command on a booted host produces a running agent. With the local backend that happens with no network access at any point.
- The stick stays a normal Ventoy drive: ISOs can still be dropped on it and booted.
- Support at least Linux x86\_64, Linux arm64 and macOS arm64 as host targets.
- The user chooses the backend, the model and the target platforms at build time, and the model again at install time. Local inference is opt-out: someone who only wants zot pointed at a cloud provider gets a stick measured in megabytes.
- Everything is verifiable: checksums recorded at build time, checked at install time.

**Non-goals**

- No GPU driver installation. llm-kit uses whatever the host already has, and falls back to CPU.
- No model training, quantisation or conversion. Models are downloaded as prepared GGUF files.
- No Windows host support in v1. See Risks.
- No modification of the host system outside one working directory, unless the user explicitly opts in.
- No attempt to make the agent safe to run unattended. Permission gating is zot's concern, not this project's.

## How this fits Ventoy

llm-kit cannot be a Ventoy plugin in the strict sense, and the design has to account for that.

Ventoy's plugin framework is configured through `/ventoy/ventoy.json` on the data partition. The closest plugin to what this project needs is the **injection plugin**, which decompresses an archive into the runtime environment after boot. Per Ventoy's documentation, that environment is the initramfs for Linux and WinPE for Windows, and Ventoy does nothing with the files beyond extracting them. It is described as an injection framework only. That makes it unsuitable as the delivery mechanism for a multi-gigabyte model and a set of binaries: initramfs lives in RAM, and the archive is extracted on every boot of the matching ISO.

The workable design uses the data partition instead. Ventoy exposes the bulk of the disk as a normal filesystem where ISOs are dropped, and any live system that boots from the stick can mount that same partition and read a directory on it. So:

- **Payload** (binaries, models, `llm-kit.sh`) lives in a top-level `/llm-kit/` directory on the Ventoy data partition. It is inert; Ventoy ignores it.
- **Optional injection entry** is written into `ventoy.json` only to inject a few kilobytes: a notice file and a symlink-style pointer telling the user where `llm-kit.sh` is. This is a convenience, not the delivery path, and it is off by default.
- **Invocation** is manual: the user mounts the stick in the booted system and runs `/path/to/llm-kit/llm-kit.sh`.

One consequence worth stating early: the Ventoy data partition is exFAT by default, which does not carry Unix permission bits. Binaries on the stick will not be executable in place. `llm-kit.sh` must copy them to a real filesystem and `chmod +x` them, which it does anyway.

## On-disk layout

Everything lives under one directory on the Ventoy data partition, so a user can delete `llm-kit/` and be left with a clean Ventoy drive.

```
<ventoy-data-partition>/
├── ventoy/
│   └── ventoy.json          # untouched unless the optional notice is enabled
├── <user's ISOs>.iso
└── llm-kit/
    ├── llm-kit.sh           # the host-side installer
    ├── manifest.json        # what was downloaded, versions, sizes, sha256
    ├── VERSION              # llm-kit release that built this stick
    ├── bin/
    │   ├── linux-x86_64/    # zot, llama-server (+ its shared libs)
    │   ├── linux-aarch64/
    │   ├── darwin-arm64/
    │   └── darwin-x86_64/
    ├── models/
    │   ├── ulysses-7b-q4_k_m.gguf
    │   └── phi3-sysadmin-q4_k_m.gguf
    ├── config/
    │   ├── zot-config.json  # ZOT_HOME template, llama.cpp provider pre-registered
    │   └── models.json      # model metadata overrides for zot
    └── docs/
        └── README.txt       # plain-text, readable from a TTY with no pager
```

`manifest.json` is the contract between the two scripts. `setup.sh` writes it; `llm-kit.sh` reads it to know which platforms and models are present rather than globbing directories.

## setup.sh — build the stick

Runs on a workstation with internet. POSIX-ish bash, no dependencies beyond `curl`, `lsblk`/`diskutil`, `sha256sum`, `tar` and `unzip`. Interactive by default; every prompt also settable by flag for scripted runs.

### S1. Find the USB stick

- Enumerate removable block devices (`lsblk -o NAME,SIZE,TRAN,RM,MODEL` on Linux; `diskutil list external` on macOS).
- Present them as a numbered list with model, size and current partition labels. Never auto-select, even when only one candidate exists.
- Require the user to retype the device node (`/dev/sdb`) to confirm. Refuse anything that is not removable unless `--force` is passed, and refuse the device holding `/` outright.

### S2. Detect Ventoy

- Treat the device as Ventoy-formatted if it has a partition labelled `Ventoy` plus a small second partition labelled `VTOYEFI`.
- If present, read the installed version (Ventoy writes a version file on the data partition; confirm the exact path during implementation) and report it.
- If absent, state plainly that installing Ventoy **erases the entire device**, show the device again, and require an explicit `yes` typed in full.

### S3. Install or update Ventoy

- Fetch the latest release from the official GitHub repository (`ventoy/Ventoy`) via the releases API, not a scraped page.
- Verify the download against the checksum published with the release before extracting.
- Run Ventoy's own installer (`Ventoy2Disk.sh -i /dev/sdX`) rather than reimplementing partitioning. Pass `-u` to upgrade in place when Ventoy is already installed, which preserves data.
- On macOS, Ventoy has no native installer. Detect this and tell the user to prepare the stick on a Linux machine. Do not attempt a workaround.

### S4. Choose the backend

Local inference is not what every user wants. Someone with a working connection and an API key may want zot alone, which makes the stick a few megabytes instead of several gigabytes. Ask before downloading anything heavy.

```
How should the agent get its model?
1) Local only    llama.cpp + a bundled model. Works offline. ~5GB.          [default]
2) Online only   zot alone, pointed at a cloud provider. Needs internet on the host. ~20MB.
3) Both          Bundle local inference, and pre-register a provider as a fallback.
```

- Options 2 and 3 then ask which provider to pre-register: Anthropic, OpenAI, Gemini, OpenRouter, a custom OpenAI-compatible base URL, or "decide later". The last writes no provider config and leaves the user to run `/login` on the host.
- **No API key is written to the stick by default.** Record the provider id and base URL in the config; prompt for the key at install time or read it from the environment. `--embed-key` overrides this and prints a warning first: a USB stick is a portable, losable, unencrypted object, and zot's own docs warn against treating its config as a credential store.
- Option 2 skips S5 entirely and downloads no llama.cpp build. S6 still applies, because zot itself is per-platform.
- Option 3 writes both providers and marks the local one as default, so the host works offline and falls back to the network only when asked.
- The answer is recorded in the manifest as `backend`, and `llm-kit.sh` branches on it rather than inferring from which files happen to be present.

### S5. Choose the model

Single-select menu, one line per option with size and the main caveat. See Model catalog for the full text and the default.

### S6. Choose target platforms

Multi-select menu over the target matrix. Default to the architecture of the machine running `setup.sh` plus `linux-x86_64`. Warn on total size before downloading.

### S7. Download

- Fetch zot from its GitHub releases, llama.cpp from `ggml-org/llama.cpp` releases, and the chosen GGUF from Hugging Face. On the online-only backend, skip the latter two entirely.
- Resume partial downloads (`curl -C -`). Retry three times with backoff.
- Record every artefact in `manifest.json` with URL, version, byte size and sha256.
- Honour `HTTPS_PROXY` and `ALL_PROXY` from the environment, and accept `--proxy`, since the build machine may be behind a filtered connection.

### S8. Stage and verify

- Write into `llm-kit/` on the data partition, then re-read every file and compare against the manifest. A stick that passes this check is the acceptance gate for `setup.sh`.
- Copy `llm-kit.sh` and `README.txt` last, so their presence signals a complete build.
- Print the total size, the free space remaining for ISOs, and the exact command to run after booting.

## llm-kit.sh — install on the host

Runs on the booted machine, from the stick. On the local backend it needs no network at any point; on the online backend it needs one only to reach the provider. Must work in a minimal live environment: assume bash, coreutils and nothing else. No `curl`, no package manager, no sudo unless asked for.

### H1. Locate itself and the payload

- Resolve its own directory from `$0` and treat the parent as the payload root, so it works wherever the stick is mounted.
- Read and validate `manifest.json`. Refuse to continue on a version mismatch with a clear message rather than guessing.

### H2. Detect the host

- OS from `uname -s`, architecture from `uname -m`, normalised (`x86_64|amd64` → `x86_64`, `aarch64|arm64` → the platform's name).
- Match against the platforms present on the stick. If none match, list what is available and exit non-zero.
- Report detected RAM and CPU count, and warn when RAM is below the chosen model's rough requirement.

### H3. Choose the model

- Skipped entirely on the online-only backend; the script goes straight to H4. Otherwise list only models actually present on the stick, same one-line format as `setup.sh`.
- Pre-select the one the manifest marks as default. Allow `--model <id>` to skip the prompt.

### H4. Choose the destination

- Default to `$HOME/.llm-kit` when `$HOME` is writable, otherwise `/tmp/llm-kit`. Offer both plus a custom path.
- Warn when the destination is tmpfs and the model will be held in RAM, which on a live ISO can exhaust memory.
- Offer to run the model directly from the stick instead, trading startup speed for RAM. Binaries still get copied; only the GGUF stays put.

### H5. Install

- Copy the matching `bin/<platform>/` contents and the chosen GGUF, verifying sha256 against the manifest as it goes.
- `chmod +x` every binary, since exFAT carried no permission bits.
- Write a `ZOT_HOME` under the destination containing the pre-built config: for the local backend, the llama.cpp provider registered against `http://127.0.0.1:8080`, plus `models.json` metadata for the bundled model.

### H6. Launch

- On the online backend, skip to starting zot: prompt once for the API key if the config names a provider but holds no key, and never write that key back to the stick. Otherwise start `llama-server` in router mode against the models directory, bound to `127.0.0.1` only, with a sensible context size and `--jinja`.
- Poll `/health` until ready or time out with a readable error.
- Load the chosen model through the router, then start `zot` with `ZOT_HOME` pointed at the staged config.
- On exit, stop the server it started. Leave anything it did not start alone.

### H7. Clean up

- `llm-kit.sh --uninstall` removes the destination directory and nothing else. It never touches the stick.

## Model catalog

The three candidates below are the ones supplied for this spec. None of them has been verified by me against its repository, and none has a published tool-calling evaluation. That matters more than their DevOps knowledge, and is covered under the table.

| id | Params | GGUF size (Q4\_K\_M) | Base | Repo | Known weakness |
| --- | --- | --- | --- | --- | --- |
| `ulysses-7b` | 7B | \~4.4 GB (verify) | Qwen2.5-Coder-7B | `jalpan04/Ulysses` | Two-phase QLoRA; broadest coverage of the three, but no published benchmark |
| `qweble-sol-4b` | 4B | \~2.5 GB (verify) | Qwen3.5-4B | `ukuwzi/Qweble-Sol-4B-MLX` | Author's own sysadmin score is listed as TBD, so untested; GGUF build needs confirming |
| `phi3-sysadmin` | 3.8B | \~2.3 GB | Phi-3 | `lalatendu/phi3-sysadmin` | Fine-tuned on 1,026 examples; author warns it may hallucinate commands |

### Menu text

The `setup.sh` and `llm-kit.sh` prompts render one line each, in this order:

```
1) ulysses-7b      7B, ~4.4GB  Qwen2.5-Coder base, DevOps/SRE tuned. Best coverage. Needs ~8GB RAM.
2) qweble-sol-4b   4B, ~2.5GB  Qwen3.5 base, sysadmin tuned. Untested by its author. Needs ~5GB RAM.
3) phi3-sysadmin   3.8B, ~2.3GB  Small and fast. Author warns it may invent commands. Needs ~5GB RAM.
4) qwen2.5-coder-7b-instruct   7B, ~4.4GB  Not DevOps-tuned, but known-good tool calling. [default]
```

### Why option 4 exists

zot drives the model through tool calls: `read`, `write`, `edit`, `glob`, `bash`. If the model cannot emit well-formed tool calls reliably, the harness is unusable regardless of how much systems knowledge the weights hold. Narrow fine-tunes are a known risk here: training on a small instruction set can degrade or break the base model's tool-calling behaviour and chat template, and none of the three candidates documents tool-call support.

So the catalog ships an un-tuned instruct model with established tool calling as the default, and the DevOps fine-tunes as opt-in. If evaluation (M2) shows one of them calls tools reliably, the default moves to it.

### Model entry schema

Models are not hardcoded in the script. Each is a JSON entry in `models/catalog.json` with id, display line, repo, file, sha256, byte size, minimum RAM, prompt template and a `tool_calling` field of `verified` / `unverified` / `broken`. Adding a model means adding an entry, not editing script logic.

## Target matrix

| Platform | zot | llama.cpp | v1 | Notes |
| --- | --- | --- | --- | --- |
| `linux-x86_64` | release binary | release build | Yes | The default. Covers nearly every live ISO. |
| `linux-aarch64` | release binary | release build | Yes | Raspberry Pi, Ampere, ARM servers. |
| `darwin-arm64` | release binary | release build | Yes | Apple Silicon; Metal acceleration if the release build carries it. |
| `darwin-x86_64` | release binary | release build | Optional | Intel Macs; offered but not default. |
| `windows-x86_64` | release binary | release build | No | Deferred. See Risks. |

The CPU-only llama.cpp build is the baseline for every platform, because the host's GPU and drivers are unknown at build time. A second, optional CUDA build per platform is a stretch goal; it roughly doubles the binary footprint and only helps when the live environment already has the NVIDIA driver loaded.

Size budget, one model plus two Linux platforms: roughly 5 GB. A 32 GB stick leaves ample room for ISOs. The script warns if the selection exceeds 60% of free space.

## Non-functional requirements

**Offline.** `llm-kit.sh` must complete with the network interface down. Any code path that would reach out fails the build. Note that zot's `/llama` model browser searches Hugging Face and will not work offline; the README must say so, and the pre-written config should steer the user to `/model` instead.

**Integrity.** Every artefact has a sha256 in the manifest, written at build time and checked at install time. A mismatch aborts rather than warns, because a truncated GGUF fails in confusing ways.

**Least privilege.** `llm-kit.sh` requires no root. `setup.sh` requires root only for the Ventoy install step, and asks for it at that point rather than demanding it upfront.

**Idempotent.** Re-running `setup.sh` on an existing stick updates in place: it skips artefacts already present with a matching hash, and never reformats a drive that already has Ventoy on it.

**Readable failure.** Every exit path prints what failed, what state the system is in, and what to do. A live-ISO user has no browser to search the error in.

**Footprint.** `llm-kit.sh` stays under roughly 600 lines of bash. Beyond that it should be a program, not a script.

**Shell compatibility.** Target bash 3.2, since macOS ships it and some minimal images are old. No `mapfile`, no associative arrays, no `${var,,}`.

## Risks and open questions

| # | Risk or question | Impact | How to resolve |
| --- | --- | --- | --- |
| R1 | None of the three DevOps models is verified for tool calling. If all three fail, the DevOps angle of the product does not work. | High | M2: run a fixed tool-call test suite against each before shipping. Default stays on a known-good instruct model until one passes. |
| R2 | The three model repos are unverified: sizes, GGUF availability and licences all come from the model cards, not from inspection. | High | Check each repo, record licence and exact file names in `catalog.json`. Drop any that lacks a usable GGUF or a redistributable licence. |
| R3 | zot's llama.cpp provider targets router mode and requires a recent `llama-server` started with `--models-dir` and no `-m`. Older release builds may not support it. | High | Pin a known-working llama.cpp release in the manifest rather than always taking latest. |
| R4 | zot docs say `/model` lists only loaded models, and `/llama` manages them via Hugging Face. Whether a model dropped into `--models-dir` can be loaded fully offline is untested. | High | Test early. If it cannot, fall back to starting `llama-server` with `-m <file>` as a single-model server and registering it as a generic OpenAI-compatible endpoint via `--base-url`. |
| R5 | Live ISOs vary enormously. Some have tiny tmpfs roots, some lack bash, some mount USB read-only. | Medium | Test against a fixed set: Ubuntu live, Fedora live, SystemRescue, Alpine. Document which work. |
| R6 | Ventoy's data partition is exFAT; some minimal live images lack exFAT support. | Medium | Detect and tell the user to install `exfatprogs`, or document which test images need it. |
| R7 | Windows hosts need a different install path, different binaries, and PowerShell rather than bash. | Medium | Deferred to v2. Ventoy's injection plugin has a `VentoyAutoRun.bat` hook for WinPE that may help. |
| R8 | Running a 7B model on CPU in a live session may be unusably slow, making the product technically correct and practically useless. | Medium | Measure tokens/sec on representative hardware in M3. If it is too slow, reposition around the 4B models. |
| R9 | Model licences may not permit redistribution on a stick handed to someone else. | Medium | Record each licence; display it at install time; refuse to bundle anything non-redistributable. |
| R10 | Downloading and running an agent with `bash` access on a stranger's machine is a real security surface. | Medium | README states it plainly. Default zot config enables permission prompts rather than auto-approval. |
| R11 | zot describes itself as "in beta forever" and its config format may move. | Low | Pin the zot version in the manifest; regenerate configs on upgrade. |

**Open question for the owner:** should `setup.sh` also offer Ollama as an alternative backend? It is heavier and its releases are archives rather than single binaries, but its model management is friendlier offline. Current answer in this spec is no.

## Milestones and acceptance criteria

**M1 — Spike (resolve R3 and R4 before writing anything else).** By hand, on one Linux machine: download a llama.cpp release, start `llama-server` in router mode with a GGUF already in `--models-dir`, cut the network, and get zot to load it and complete one tool call. If this fails, the architecture changes before any script is written.

**M2 — Model evaluation.** Run a fixed set of \~20 DevOps prompts requiring tool use against each candidate. Record tool-call success rate and tokens/sec on CPU. Outcome: the `tool_calling` field in `catalog.json` and the choice of default.

**M3 — setup.sh v1.** Builds a stick for `linux-x86_64` with one model. Acceptance: on a blank 32 GB stick, one run produces a Ventoy drive that boots, and every file verifies against the manifest.

**M4 — llm-kit.sh v1.** Acceptance: boot Ubuntu live with networking disabled, run the script, and reach a zot prompt that successfully edits a file on disk. Under 10 minutes from boot to prompt.

**M5 — Multi-platform.** Add `linux-aarch64` and `darwin-arm64`. Acceptance: the same test passes on each.

**M6 — Polish.** Idempotent re-runs, `--uninstall`, non-interactive flags, README, and the optional Ventoy notice injection.

The release gate across all of them is M1's test repeated on each supported platform with the network physically disconnected, not merely configured down.

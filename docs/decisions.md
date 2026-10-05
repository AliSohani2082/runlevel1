# Decisions

Short records of choices that change or sharpen the PRD. Newest last.

## D1. Upstream binaries: latest release at build time, not pinned (owner decision)

The owner asked that `setup.sh` download the **latest** zot and llama.cpp
releases. This replaces the PRD's R3/R11 mitigation ("pin a known-working
release in the manifest").

What still protects the build:
- The exact resolved versions are recorded in `manifest.json`
  (`platforms[].zot_version`, `platforms[].llama_version`, `artifacts[]`),
  so every stick says what it carries.
- "Latest" means the newest release **that has the asset we need**, not
  whatever `releases/latest` points at. llama.cpp has published releases
  with no binaries attached (for example a `v0.6.0` tag on 2026-10-05), and
  setup.sh must skip those.
- After downloading, setup.sh smoke-checks the build-host platform's
  llama-server for router mode (`--help` mentions `--models-dir`). If the
  check fails it stops with a readable error instead of producing a stick
  that cannot start.
- `--zot-version TAG` and `--llama-version TAG` remain as escape hatches
  when the newest release breaks.

## D2. Models: latest revision from Hugging Face, verified against HF's own hash

`models/catalog.json` names a repo, a file and a revision (`main` by
default). It does not pin a sha256. At build time setup.sh asks the HF API
for the file's current LFS sha256 and size, downloads it, verifies it and
records both in the manifest. The PRD's integrity requirement (hash written
at build time, checked at install time) still holds end to end.

## D3. Downloaded artefacts never live in the repo

Binaries, archives and models are never committed or stored in the working
tree. `setup.sh` caches downloads in `LLMKIT_CACHE_DIR`
(`~/.cache/llm-kit` by default). Development and test artefacts live in
`~/.cache/llm-kit-dev/` (see CLAUDE.md).

## D4. Line-oriented canonical JSON

`manifest.json` and `catalog.json` are valid JSON with one record per line
and no quotes or backslashes inside string values. llm-kit.sh can then
parse them in pure bash 3.2 with no jq, sed, awk or grep, and setup.sh can
write them with `printf`. The rules are in `docs/contracts.md` §1.

## D5. HTTP from llm-kit.sh goes over bash `/dev/tcp`

Hosts have no curl. Health polling and the router's `/models/load` call use
bash's built-in `/dev/tcp/127.0.0.1/<port>` with HTTP/1.1 and
`Connection: close`. Verified on bash 3.2.57 (Alpine container) during M0.

## D6. Permission prompts on by default

zot auto-approves tool calls unless started with `--no-yolo`. There is no
config key for this, so llm-kit.sh always passes `--no-yolo` (R10).
`--yolo` on llm-kit.sh is the explicit opt-out.

## D7. Model files on the stick are named `<catalog id>.gguf`

This keeps the catalog id, the stick file name and the llama.cpp router's
model name identical. M1 verifies that the router names `--models-dir`
entries by file stem.

## D8. Names

The GitHub repository is `runlevel1`. The artefacts keep the PRD's names
(`llm-kit/`, `llm-kit.sh`, `setup.sh`), so the spec and the code agree.
Renaming is a separate, mechanical change if the owner wants it.

# runlevel1

**llm-kit**: a portable, offline DevOps/SRE assistant on a Ventoy USB stick.

Boot any machine from the stick (or plug it into a running one), run one
script, and get a coding agent ([zot](https://github.com/patriceckhart/zot))
backed by a local model served by [llama.cpp](https://github.com/ggml-org/llama.cpp),
with no network and no package manager. The stick stays a normal Ventoy
drive: drop ISOs on it as usual.

The project is two shell scripts:

| script | runs on | does |
|---|---|---|
| `setup.sh` | a workstation with internet | builds or updates the stick: Ventoy, latest zot + llama.cpp, a model, `manifest.json` |
| `llm-kit.sh` | the booted host, from the stick | verifies and stages the right binaries + model into a working directory, starts llama-server on 127.0.0.1, opens zot |

Full spec: [docs/PRD.md](docs/PRD.md). The interfaces between the two scripts
are in [docs/contracts.md](docs/contracts.md); deviations from the PRD are in
[docs/decisions.md](docs/decisions.md).

## Status

| milestone | scope | state |
|---|---|---|
| M0 | Foundation: repo layout, contracts, catalog, test + lint harness | done |
| M1 | Spike: llama.cpp router mode + offline model load + one zot tool call | done: architecture verified offline; the default model fails tool calls, see [docs/spike-m1.md](docs/spike-m1.md) and D9 |
| M2 | Model evaluation (tool-call success, tokens/sec); **first: pick a new default (D9)** | next |
| M3 | `setup.sh` v1 (linux-x86_64, one model) | planned |
| M4 | `llm-kit.sh` v1 (offline Ubuntu live → zot edits a file) | planned |
| M5 | Multi-platform (linux-aarch64, darwin-arm64) | planned |
| M6 | Polish (idempotency, `--uninstall`, flags, README, Ventoy notice) | planned |

## Layout

```
setup.sh, llm-kit.sh      the two shipped scripts (bash 3.2 compatible)
models/catalog.json       model catalog (canonical line-JSON, see contracts §3)
config/                   ZOT_HOME templates copied to the stick
docs/                     PRD, contracts, decisions, spike notes, stick README.txt
tests/                    test runner, assertions, fixtures, contract tests
spike/                    reproducible M1 spike script (dev tool)
```

## Development

```sh
make check          # lint + test + test-bash32
make lint           # shellcheck, bash-3.2 construct scan, `bash -n` under bash 3.2
make test           # tests/run.sh with the system bash
make test-bash32    # host-side tests inside the bash:3.2 (Alpine/busybox) container
```

Requirements on the dev machine: bash, jq (tests only), podman (bash 3.2
container), shellcheck (on `PATH`, or at `~/.cache/llm-kit-dev/tools/bin`).

Downloaded binaries and models are never stored in this repository.
`setup.sh` caches its downloads in `~/.cache/llm-kit` (`LLMKIT_CACHE_DIR`);
development and test artefacts live in `~/.cache/llm-kit-dev/`.

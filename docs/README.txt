llm-kit - an offline DevOps/SRE assistant on this USB stick
===========================================================

This directory holds a coding agent (zot), an inference server (llama.cpp)
and a language model. Nothing here is installed on the computer until you
run the installer. Deleting this llm-kit/ directory leaves a normal Ventoy
stick.

QUICK START (after booting any machine from this stick, or on any Linux/macOS)

  1. Find where the stick is mounted. Its data partition is labelled
     "Ventoy". For example:
        lsblk -o NAME,LABEL,MOUNTPOINT
     If it is not mounted:
        mkdir -p /tmp/ventoy && mount /dev/sdX1 /tmp/ventoy    (as root)
  2. Run the installer from the stick (no root needed):
        bash /path/to/stick/llm-kit/llm-kit.sh
  3. Answer the prompts, or press Enter to accept the defaults.

The installer copies the programs (and usually the model) to $HOME/.llm-kit
or /tmp/llm-kit, checks every file against manifest.json, starts the local
model server on 127.0.0.1 only, and opens the agent. Leaving the agent stops
the server again.

  bash llm-kit.sh --help         all options
  bash llm-kit.sh --uninstall    remove the installed copy (never the stick)

OFFLINE NOTES

  * With the local model, nothing needs a network at any point.
  * In the agent, use /model to pick a model. Do NOT use /llama: it searches
    and downloads from Hugging Face and will not work offline.
  * The stick's filesystem (exFAT) cannot store "executable" flags, so the
    installer copies programs to a real filesystem before running them.

SECURITY - READ THIS

  The agent can run shell commands on this machine. By default it asks
  before every tool call; read each request before you approve it. Do not
  run it unattended. A USB stick is easy to lose: llm-kit stores no API
  keys on it unless it was built with --embed-key.

IF SOMETHING FAILS

  Every error says what failed, what state the machine is in, and what to do
  next. Common fixes:
    * "no build for this platform": the stick was built for other machines;
      the message lists what is available.
    * not enough RAM: choose a smaller model, or run the model directly from
      the stick (the installer offers this).
    * the stick does not mount: the live system may lack exFAT support
      (install exfatprogs, or use another live image).

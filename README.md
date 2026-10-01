# opencode-switcher

A simple Ruby script to switch between different [OpenCode](https://opencode.ai) configuration profiles, manage provider API keys per profile, and run connectivity tests and token-generation benchmarks.

## Overview

OpenCode stores its active configuration in `~/.config/opencode/opencode.json`. When working across multiple providers (e.g., OpenRouter, local Ollama/vLLM endpoints, cloud APIs, or private clusters), updating credentials and JSON configurations manually can be repetitive.

`opencode-switcher` provides:
- Profile isolation under `~/.config/opencode-switcher/<number>/` (containing `config.json` and `API_key.sh`).
- A single wrapper command `oc` to run OpenCode using any profile.
- A subcommand `oc conf` to inspect, switch, test, and benchmark profiles.
- Command alias `opencode-switcher` for direct profile management.

---

## Requirements

- Ruby 3.0+ (standard library only; no external gems required)
- OpenCode (`opencode` binary in `PATH` or `~/.opencode/bin/opencode`)
- `bash` (used internally to safely source `API_key.sh` scripts)

---

## Installation

### Quick Installation

Run `./oc install` from this repository to automatically copy `oc` to `~/bin` (or another directory in your `PATH`), make it executable, and create the `opencode-switcher` symlink:

```bash
./oc install
```

You can also specify a custom target directory:
```bash
./oc install ~/bin
# or
./oc install ~/.local/bin
```

### Manual Installation

Copy `oc` to a directory in your `PATH` (such as `~/bin`) and make it executable:

```bash
mkdir -p ~/bin
cp oc ~/bin/oc
chmod +x ~/bin/oc
ln -sf oc ~/bin/opencode-switcher
```

Ensure `~/bin` is in your shell `PATH`:

```bash
export PATH="$HOME/bin:$PATH"
```


---

## Profile Directory Structure

Profiles are stored in `~/.config/opencode-switcher/`:

```
~/.config/opencode-switcher/
├── default.json          # Tracks active default profile number (e.g. {"default": "01"})
├── 01/
│   ├── config.json       # OpenCode JSON configuration for Profile 01
│   └── API_key.sh        # Environment export script (e.g. export OPENROUTER_API_KEY="...")
├── 02/
│   ├── config.json
│   └── API_key.sh
└── 03/
    ├── config.json
    └── API_key.sh
```

When you invoke `oc [profile]`, the script:
1. Sources `API_key.sh` for the selected profile and exports the variables to the execution environment.
2. Copies `config.json` to `~/.config/opencode/opencode.json` (and cleans up any conflicting `opencode.jsonc`).
3. Forwards the profile's default model (via `-m <model>`) if none is explicitly provided.
4. Executes the `opencode` binary with any supplied arguments.

---

## Usage Examples

### 1. Running OpenCode

#### Run with the active default profile
```bash
oc
```

#### Run with a specific profile
```bash
# Run profile 02 in interactive mode
oc 02

# Run profile 01 and pass a prompt
oc 01 "Write a binary search implementation in Ruby"

# Run profile 03 with additional flags
oc 03 -m anthropic/claude-3-7-sonnet
```

#### Pass raw arguments directly to OpenCode
Use `--` to prevent `oc` from interpreting arguments:
```bash
oc -- --version
oc 02 -- -m custom/model -f main.rb
```

---

### 2. Managing Profiles (`oc conf`)

#### List all profiles
```bash
oc conf
# or
oc conf list
```

Example output:
```
OpenCode Profiles (~/.config/opencode-switcher/):
    01           "OpenRouter DeepSeek direct" — Provider: openrouter [OPENROUTER_API_KEY: SET]
       Model: openrouter/deepseek/deepseek-v4-flash | URL: https://openrouter.ai/api/v1

  * 02 [default] "Lumen Remote Qwen 3.6 coder" — Provider: remote-coder [REMOTE_CODER_API_KEY: SET]
       Model: remote-coder/qwen3.6-35b-a3b | URL: https://lumen.ncsa.illinois.edu/v1
```

#### Change the active default profile
```bash
oc conf 02
# or
oc conf set_default 02
```

#### Inspect profile details
Display full provider settings, base URLs, configured models, and API key status:
```bash
# Inspect profile 01
oc conf info 01

# Inspect all profiles
oc conf info all
```

#### Set the default model for a profile
```bash
# Set model for profile 02
oc conf set_model 02 anthropic/claude-3-7-sonnet
# or
oc conf 02 set_model anthropic/claude-3-7-sonnet

# Set model for the current default profile
oc conf set_model anthropic/claude-3-7-sonnet
```

#### Set a profile description
```bash
oc conf set_desc 02 "Primary coding profile with local LLM"
# or
oc conf 02 set_desc "Primary coding profile with local LLM"
```

#### Set an API key
```bash
oc conf set_api 02 "sk-your-api-key-here"
# or
oc conf 02 set_api "sk-your-api-key-here"
```

#### Create a new profile from a JSON config
```bash
oc conf create path/to/my-config.json
```
This allocates the next available numeric directory (e.g. `04`), copies the JSON file, replaces literal API keys with `{env:...}` placeholders, and creates the corresponding `API_key.sh` file.

---

### 3. Diagnostics & Benchmarking

#### Test profile connectivity
Sends a short request to verify API keys, access points, and model responses:
```bash
# Test profile 01
oc conf test 01

# Test all profiles
oc conf test all
```

#### Benchmark token generation speed across profiles
Measures latency and output tokens per second across multiple endpoints:
```bash
# Benchmark current default profile
oc conf bench

# Compare profile 01 and profile 02
oc conf bench 01 02

# Benchmark all profiles and display a speed summary
oc conf bench all
```

#### Speed test all models configured in a profile
Runs generation benchmarks for every model listed in a profile's configuration:
```bash
oc conf test_models 01
```

---

### 4. Help Triggers

The full usage reference can be triggered with any of the following standard help flags:

```bash
oc help
oc -h
oc -H
oc -?
oc /?
oc /h
oc /H
oc --help
```

---

### 5. Remote Sync (`oc ssh`)

Copy `oc` to a remote machine's `~/bin/` directory, sync the switcher configuration, and optionally sync `~/.config/opencode/AGENTS.md`:

```bash
# Copy oc to remote ~/bin/ and sync switcher config
oc ssh user@remote-host

# Also sync ~/.config/opencode/AGENTS.md (with automatic versioned remote backup)
oc ssh user@remote-host -all
```

What `oc ssh <remote>` does:
1. Ensures `~/bin/` and `~/.config/opencode-switcher/` exist on the remote.
2. Copies `oc` to `<remote>:~/bin/oc`, makes it executable, and creates the `opencode-switcher -> oc` symlink.
3. Rsyncs `~/.config/opencode-switcher/` to the remote.
4. By default, `AGENTS.md` is **not** copied. Pass `-all` to also sync it.

When `-all` is used, any existing remote `~/.config/opencode/AGENTS.md` is first backed up to `AGENTS.md.bak.NNN` (e.g. `.bak.001`, `.bak.002`, ...) using the lowest unused counter, so old configurations are never overwritten.

The same command is available under the config namespace: `oc conf ssh <remote> [-all]`.

---

## License

MIT

# Code Review: opencode-switcher

- **Reviewer:** Deepseek V4 Pro
- **Date:** 2026-10-01
- **Scope:** Full repository — `oc` (main program, 1970 lines), `opencode-switcher` (identical copy), and `tools/{bump,release,snapshot}.rb`.
- **Verification:** `ruby -c` passes on all four scripts; `oc` and `opencode-switcher` are byte-identical (`diff -q`). The two High-severity bugs below were reproduced with isolated test cases.

---

## Summary

The program is a Ruby CLI that isolates OpenCode profiles, injects provider API keys
from `API_key.sh`, compiles an effective `opencode.json` from a `base.jsonc` + per-profile
delta, and offers subcommands for listing, switching, testing, and benchmarking profiles.
Overall structure is clear and readable. The most important issues are a JSONC parser
that can corrupt string values, and an env-var injection path that can write a config
referencing the wrong environment variable.

---

## High

### 1. `parse_jsonc` corrupts string contents containing `, }` or `, ]`

**Location:** `oc:98`

```ruby
cleaned = cleaned.gsub(/,\s*([\]}])/, '\1')
```

The trailing-comma strip runs on the *entire* document and does **not** protect quoted
strings (unlike the comment-stripping pass on line 94, which does). Reproduced:

```
parse_jsonc('{ "prompt": "say, } hello" }')  # => {"prompt"=>"say} hello"}
```

Because this function is used to *read* every profile config (`load_profile_raw_config`,
`load_base_config`), and those hashes are subsequently re-written by `set_model`,
`set_desc`, `set_api`, `migrate`, and `create`, any config whose value legitimately
contains `, }` or `, ]` will be silently corrupted on disk.

A regex-only JSONC parser cannot reliably strip trailing commas. It needs a
character-scanning approach that tracks whether the cursor is inside a double-quoted
string (and honors `\` escapes).

### 2. `set_api_key` injects the wrong env-var name for non-conventional keys

**Location:** `oc:646` (call site) + `oc:342` (lookup)

```ruby
# oc:646
inject_env_placeholders!(json_data, { nil => var_name })

# oc:342
var = env_var_map[provider_name] || "#{provider_name.to_s.upcase.gsub(/[^A-Z0-9]/, '_')}_API_KEY"
```

`inject_env_placeholders!` looks the map up by **provider name**, but `set_api_key`
passes a map keyed by `nil`. The map is therefore never consulted and it always falls
back to `<PROVIDER>_API_KEY`. Reproduced:

```
inject_env_placeholders!(
  {'provider'=>{'openrouter'=>{'options'=>{'apiKey'=>'sk-literal'}}}},
  {nil=>'MY_CUSTOM_KEY'}
)
# => {env:OPENROUTER_API_KEY}   (expected {env:MY_CUSTOM_KEY})
```

If a profile uses a non-standard key name (e.g. `export MY_KEY=...` in `API_key.sh`) and
its config holds a literal `apiKey`, `set_api` writes the key into `MY_KEY` but rewrites
the config to reference `OPENROUTER_API_KEY` — the key is then silently not found at
runtime. It only *appears* to work in the common case because the fallback name coincides
with the conventional name.

**Fix direction:** pass a map keyed by provider name, or make the lookup fall back to
`env_var_map[nil]`.

---

## Medium

### 3. `get_default_profile` can return `nil` instead of falling back

**Location:** `oc:77-87`

```ruby
return format_num(data['default']) if data['default']
```

An empty string is truthy in Ruby. If `default.json` ever contains `{"default": ""}`
(corrupt or manually edited), `format_num("")` → `nil` is returned directly, bypassing
the `available_profile_nums.first` fallback. Downstream `File.join(SWITCH_DIR, nil.to_s)`
then resolves to the profile root rather than a real profile.

### 4. Non-atomic config write (comment is misleading)

**Location:** `oc:268-271`

```ruby
# Remove shadowing files and atomically write compiled opencode.json
FileUtils.rm_f(TARGET_JSONC)
FileUtils.rm_f(TARGET_CFG)
File.write(TARGET_CFG, JSON.pretty_generate(final_cfg))
```

`File.write` is not atomic, and there is a window between `rm_f(TARGET_CFG)` and the
write where `opencode.json` does not exist. An interrupted run leaves no active config.
Should write to a temp file in the same directory and `File.rename` it into place.

### 5. `test_all_profiles` aborts the whole run on the first bad profile

**Location:** `oc:914-933` (calls `test_profile`), with `exit 1` at `oc:851-854`
(missing config) and `oc:870-873` (missing model).

A single profile with no model/config kills the "test all" loop and never prints the
summary. When called in the all-profiles context these should `return false` rather than
`exit`.

### 6. `--` does not actually prevent `-m` interception (README/behavior mismatch)

**Location:** `oc:1897` (strips `--` after a profile number) vs `oc:1937`
(`extract_model_override!` still runs).

`oc 02 -- -m custom/model -f main.rb` (documented at `README:113` as "pass raw arguments")
silently consumes `-m custom/model` as a model override and forwards only `-f main.rb`.
Only the `oc -- …` form (`oc:1881`) is true passthrough.

### 7. API keys are written to `API_key.sh` without shell escaping

**Location:** `oc:402`, `oc:588`, `oc:637`

```ruby
export #{primary_var}="#{key_to_set}"
```

A key containing `"`, `$`, backtick, or a newline breaks the sourced script (worst case:
command injection when the profile is next loaded via `source`). Keys should be emitted
with shell-safe quoting.

---

## Low / Minor

- **`available_profile_nums` sorts lexicographically** (`oc:73`): with >99 profiles (or
  non-zero-padded names), `100` sorts before `11`, producing a misleading `list` / `info
  all` order. `create_profile` allocates numerically (`max + 1`), so this only affects
  ordering, not correctness.
- **`tokens_in` is computed but never used** (`oc:1008`) — dead code.
- **`test_profile` invokes literal `'opencode'`** (`oc:890`) instead of
  `locate_opencode_bin`, so connectivity tests fail if `opencode` lives only in
  `~/.opencode/bin` and isn't on `PATH`, even though the main path finds it.
- **`run_has_message?` hardcodes an incomplete flag list** (`oc:227-230`); any new
  opencode flag that takes a value will be misclassified as a message argument, causing
  `run` not to be stripped / a model flag to be injected at the wrong position.
- **`deep_merge` concatenates arrays** (`oc:113-115`): a profile can only *append* to base
  `instructions`/`plugin`, never override or remove an entry. Documented in the comment,
  but likely surprising for `instructions`.
- **`nil =~ /regex/` reliance** (e.g. `oc:1693`, `oc:1701`): works because `Object#=~`
  returns `nil`, but it is deprecated in newer Rubies and fragile; `args.shift` results
  should be nil-checked explicitly.
- **`tools/release.rb:116` uses `gh tag create`** — not a standard GitHub CLI subcommand in
  the versions verified (releases are made with `gh release create`); worth confirming
  against the local `gh` version, otherwise tagging fails silently *after* the push.

---

## Recommended fix order

1. Replace the trailing-comma `gsub` with string-aware parsing (High #1).
2. Correct the `set_api_key` map keying (High #2).
3. Make the active-config write atomic (Medium #4).
4. Switch `test_profile` to return a status instead of `exit` in the all-profiles context
   (Medium #5).
5. Escape API key values written to `API_key.sh` (Medium #7).

# Harness adapter verification

Audience: maintainer verification.

This record holds reusable version-scoped evidence gathered while verifying a harness adapter, whether or not firstmate depends on that evidence operationally.
The operating contract for every adapter - busy state, exit, interrupt, skill invocation, resume, and quirks - is owned by [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md), and the launch mechanics by `bin/fm-spawn.sh`.
Each section below records the exact version, commands, and raw output an adapter claim rests on, so the claim itself can stay one concise line in its owner.
Task chronology, temporary profile paths, and delivery transcripts stay in private reports or PR evidence.

## codex reasoning effort is per model (2026-08-10, codex-cli 0.147.0)

The launch-profile table in the adapter skill owns the concise claim; this section is the evidence it rests on, and `bin/fm-spawn.sh` depends on it to decide whether to emit `-c 'model_reasoning_effort="max"'`.

Installed version:

```
$ codex --version
codex-cli 0.147.0
```

Codex advertises reasoning levels per model rather than per harness, so `max` is not a harness-level capability.
`codex debug models` returns a per-model `supported_reasoning_levels` array:

```
$ codex debug models | jq -r '.models[] | "\(.slug): \([.supported_reasoning_levels[].effort] | join(","))"'
gpt-5.6-sol: low,medium,high,xhigh,max,ultra
gpt-5.6-sol-wm: low,medium,high,xhigh,max,ultra
gpt-5.6-terra: low,medium,high,xhigh,max,ultra
gpt-5.6-luna: low,medium,high,xhigh,max
gpt-5.5: low,medium,high,xhigh
gpt-5.4: low,medium,high,xhigh
gpt-5.4-mini: low,medium,high,xhigh
gpt-5.3-codex-spark: low,medium,high,xhigh
codex-auto-review: low,medium,high,xhigh,max
```

Every catalog model accepts `low,medium,high,xhigh`; only those five add `max`.
`ultra` sits outside firstmate's shared low..max axis, so firstmate never emits it.

The catalog matches live acceptance. Both probes ran:

```
$ printf 'Do not use tools. Reply OK.\n' | codex exec --ephemeral --ignore-user-config \
    --skip-git-repo-check --model <model> -c 'model_reasoning_effort="max"'
```

With `--model gpt-5.6-luna` the session ran to completion, reporting `reasoning effort: max` and replying `OK`.
With `--model gpt-5.5` every turn failed with HTTP 400 `invalid_request_error/unsupported_value`:

```
'max' is not supported with the 'gpt-5.5-codex-1p-codexswic-ev3' model. Supported values are: 'none', 'low', 'medium', 'high', and 'xhigh'.
```

Two weaker readings this supersedes: a model-unqualified probe returning `rc=0` only exercised the configured default model (`gpt-5.6-sol`), and the client-side enum message that lists `max` is a config parse check rather than per-model support.
Neither establishes support for an arbitrary model.

A spawn that pins no model reads its identity from `codex doctor --json` at `.checks["config.load"].details.model`, which is codex's own config resolver and therefore follows `CODEX_HOME` and config precedence instead of a firstmate-side guess.

## omp registry/Pi-extension compatibility (2026-08-06, omp 17.2.10)

Firstmate neither wires nor dispatches on any pi.dev registry extension, so nothing in the adapter depends on this.
It is recorded because it establishes how far omp's Pi compatibility actually reaches for a third-party registry package.

`@narumitw/pi-goal` 0.49.5 installs via `omp plugin install @narumitw/pi-goal` (an npm spec) into the profile's `plugins/node_modules/`, declares its extension through the `pi.extensions: ['./src/index.ts']` manifest field, and loads and executes in omp without import or parse errors - the `@earendil-works/pi-coding-agent` scope is shimmed to omp's `ExtensionAPI`.

Its `/goal` command does not register:

```
Extension command 'goal' ... conflicts with built-in commands. Skipping.
```

omp ships its own built-in `goal` command, so a registry package's command can be shadowed by an omp built-in of the same name even when the extension itself loads cleanly.

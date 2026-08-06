# Harness adapter verification

Audience: maintainer verification.

This record holds reusable version-scoped evidence gathered while verifying a harness adapter that firstmate does not depend on operationally.
The operating contract for every adapter - busy state, exit, interrupt, skill invocation, resume, and quirks - is owned by [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md), and the launch mechanics by `bin/fm-spawn.sh`.
Task chronology, temporary profile paths, and delivery transcripts stay in private reports or PR evidence.

## omp registry/Pi-extension compatibility (2026-08-06, omp 17.2.10)

Firstmate neither wires nor dispatches on any pi.dev registry extension, so nothing in the adapter depends on this.
It is recorded because it establishes how far omp's Pi compatibility actually reaches for a third-party registry package.

`@narumitw/pi-goal` 0.49.5 installs via `omp plugin install @narumitw/pi-goal` (an npm spec) into the profile's `plugins/node_modules/`, declares its extension through the `pi.extensions: ['./src/index.ts']` manifest field, and loads and executes in omp without import or parse errors - the `@earendil-works/pi-coding-agent` scope is shimmed to omp's `ExtensionAPI`.

Its `/goal` command does not register:

```
Extension command 'goal' ... conflicts with built-in commands. Skipping.
```

omp ships its own built-in `goal` command, so a registry package's command can be shadowed by an omp built-in of the same name even when the extension itself loads cleanly.

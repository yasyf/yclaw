## Debug CLI

`yclaw` is the fleet debug CLI, invoked as `uv run yclaw ...` from the repo root. `machines.json` is its source of truth for machines, services, ports, and log paths — never hardcode a node fact the manifest already carries. All remote execution funnels through `yclaw/remote.py` (one command string per `tailscale ssh`, check-wall detection, bounded timeouts).

| Command | Does |
|---------|------|
| `yclaw status [machine]` | Tailnet, service, health, and share state for the fleet |
| `yclaw doctor [machine] [--live]` | Status plus host-vantage hardening checks |
| `yclaw ssh <machine> [cmd...]` | Shell or one-shot command over `tailscale ssh` |
| `yclaw logs <machine> [service] [-f]` | Tail a service's logs; no service lists what's available |
| `yclaw wait <http\|port\|service\|share\|ssh> ...` | Block until an endpoint or service is up |
| `yclaw restart <machine> <service>` | Kick a service in place, then wait for its health check |
| `yclaw bounce <machine> <service>` | Full launchd unload/reload (darwin only) |
| `yclaw vm <list\|ip\|ssh\|console> ...` | Manage the Tart guests pre-tailnet |
| `yclaw secret <list\|read\|sops> ...` | Read keychain secrets, decrypt per-host sops bundles |

Exit codes: 0 clean, 1 FAIL, 2 usage, 4 Tailscale check-wall (the approval URL is printed), 5 timeout.

## Style

@STYLEGUIDE.md

## General Rules

**Minimal changes.** Stay within scope; fix the issue, then stop.

**Match surrounding code.** Follow the conventions of the file you're in, then the module.

**No defensive coding.** No fallbacks, shims, or backwards-compat layers; no guards against impossible states. If unused, delete it. Crash on the unexpected.

**Search before writing.** Before creating a helper, query the codebase via `ccx code search` (intent or symbol queries both work). Sibling modules and base classes win over re-implementation.

**Code stewardship.** When you touch a file, fix nearby bugs, style violations, and broken tests; don't wave them off as pre-existing or out of scope.

**Observe, don't infer.** Inspect actual data — read fixtures, dump objects, run the code — before reasoning from assumption.

**Don't use external failures as an excuse to stop.** API quota, rate-limit, and outage errors rarely block the whole task; trace the catch sites and confirm a failure actually stops you before claiming it does.

**Verify before asserting.** Don't report something as working, fixed, blocked, or impossible until you've checked — run it, read the output, reproduce the failure. "It should work" is not "it works."

**Reproduce before fixing.** When something breaks, isolate the smallest failing case before editing or re-running. Re-running the whole command while changing code between runs hides the root cause; narrow to the one failing call, payload, or test first.

**Research after repeated failure.** After ~2 failed approaches, stop guessing and gather evidence — search the web, read the docs and source — before a third attempt.

**Get a second opinion on a plateau.** On a debugging plateau (2 failed attempts before a 3rd), a non-trivial architectural decision, or algorithmic/security-sensitive code, get an outside check (e.g. `/codex`) before committing to the approach.

**Don't contort code to satisfy a checker.** The type checker and linter serve the code, not the other way around. Don't reshape a data model, widen a type, or bolt on a `cast(...)` / narrowing-only `assert isinstance(...)` / blanket ignore just to silence a diagnostic. If a clean fix isn't obvious, leave the diagnostic — a visible diagnostic is preferable to scar tissue. (Most checker noise isn't worth acting on at all; act only when it flags a real bug.)

**Mechanical linting.** CI and hooks handle formatting and import order; fix only what needs human judgment. When reviewing code, don't flag mechanical lint violations (line length, whitespace, import order, trailing commas).

**Testing.** The Python suite lives in `tests/` and covers the `yclaw` CLI. The exact commands:

```sh
uv sync --extra dev    # once, to install pytest + ruff
uv run pytest          # the test suite
uv run ruff check .    # lint
uvx ty check yclaw     # typecheck (diagnostics are warnings, not gates)
```

Tests mock the boundaries (the `tailscale ssh` subprocess seam, keychain calls, HTTP probes, the clock) and leave the function under test real — see STYLEGUIDE.md `## Testing` for the full convention.

**Writing docs.** When writing or revising docs, a README, a tutorial, a how-to, or reference, use the `writing-docs` skill (Diataxis modes, voice rules, and runnable code-sample rules) and run `slop-cop check <file> --lang=markdown` before you finish.

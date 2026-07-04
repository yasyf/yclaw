# yclaw Style Guide

The concrete style rules for this repository.

The stack: Python 3.14 (the `yclaw` debug CLI — uv, click, anyio, loguru; flat
package at the repo root), bash 3.2 (`scripts/` and the `scripts/lib/` shared
library), and Nix (`darwin/`, `nixos/`, `pkgs/`, `flake.nix`).

## Core Principles

Python idioms first, then the language-agnostic principles they instantiate.

1. **Frozen dataclasses over dicts.** A shaped value gets a
   `@dataclass(frozen=True, slots=True)`; a dict return hides the schema and
   invites typos.

   ```python
   # Good — yclaw/remote.py
   @dataclass(frozen=True, slots=True)
   class RemoteResult:
       returncode: int
       stdout: str
       stderr: str

   # Bad
   def run(...) -> dict:
       return {"returncode": rc, "stdout": out, "stderr": err}
   ```

2. **Dedicated exception types over sentinels and `None` returns.** Each module
   owns a small exception hierarchy carrying the facts the caller needs; a
   `None` return collapses every failure into one indistinguishable value.

   ```python
   # Good — yclaw/remote.py
   class CheckWallError(RemoteError):
       def __init__(self, url: str) -> None:
           super().__init__(f"tailscale check-mode login required: {url}")
           self.url = url

   # Bad
   def run(...) -> str | None:
       ...
       return None  # timeout? check wall? the caller can't tell
   ```

3. **anyio structured concurrency with bounded timeouts.** Concurrent work runs
   in a task group under `anyio.fail_after`; shared resources get a
   `CapacityLimiter`. No bare threads, no unbounded awaits.

   ```python
   # Good
   with anyio.fail_after(timeout):
       async with anyio.create_task_group() as tg:
           for machine in machines:
               tg.start_soon(probe, machine)

   # Bad
   threading.Thread(target=probe, daemon=True).start()  # unjoined, unbounded
   ```

4. **Module order.** Imports, constants, type aliases, exceptions, helpers,
   classes, then functions. Constants (`EXIT_CLEAN = 0`, compiled regexes) sit
   immediately after the imports, never inline in a function body.

5. **Export control via `__init__` re-exports.** A package's `__init__`
   re-exports its public surface; everything not re-exported is internal.
   Consumers import from the package, not from a sibling module's guts.

   ```python
   # Good — the package __init__ names what is public
   from .remote import CheckWallError, RemoteResult, run

   # Bad — a consumer reaching past the public surface
   from somepkg.remote import _parse_check_wall
   ```

6. **ruff and ty serve the code.** Never widen a type, bolt on a `cast(...)`,
   or reshape a data model to silence a diagnostic — a visible warning beats
   scar tissue. `[tool.ty.rules] all = "warn"` is deliberate: diagnostics are
   reports, not gates.

7. **Fail fast, fail loud.** No defensive coding: no fallbacks, shims, or
   backwards-compat layers, and no guards against impossible states. No sentinel
   values, no silent defaults. If unused, delete it. Crash on the unexpected.
8. **Make invalid states unrepresentable.** Branded/newtype primitives, immutable
   data structures, required fields over optionals.
9. **Minimal changes.** Stay within scope. Make the test pass, then stop. Improve
   only the code you touch.
10. **Match surrounding code.** Follow this guide first, then the file you're in,
    then the module. If surrounding code violates this guide, fix it.

## Error Handling

Keep `try` blocks minimal: only the operation that can fail belongs inside. No
catch-all handlers that swallow everything; raise the module's dedicated
exception types (`RemoteError` and its subclasses in `yclaw/remote.py` are the
model). Map failure classes to the shared exit-code constants in
`yclaw/output.py` (0 clean, 1 FAIL, 2 usage, 4 check-wall, 5 timeout) — never a
bare magic `sys.exit(3)`. Read required configuration eagerly so a missing key
fails at startup: `manifest.py` loads `machines.json` whole and a missing field
raises, and `scripts/lib/manifest.sh` dies loudly when `jq` or a key is absent.
No sentinel return values; raise, or return a typed result.

## Code Organization

Python modules follow the order in Core Principle 4. The `yclaw` package is
flat at the repo root (`module-root = ""` in `pyproject.toml`); one module per
concern (`remote.py`, `manifest.py`, `status.py`, ...), with `remote.py` as the
sole module allowed to build `tailscale ssh` argv.

The bash library under `scripts/lib/` has its own conventions:

- **bash 3.2 compatible** — macOS ships `/bin/bash` 3.2 and guests run piped
  scripts under it. No associative arrays, no `${var,,}`, no `mapfile`.
- **Functions only.** Sourcing a lib file defines functions (and at most a
  constant); it never executes work at source time.
- **`wait.sh` is self-contained by design.** It is sourced on the host,
  embedded verbatim into nix launchd wrappers (`darwin/metal.nix`), shipped
  into images (`/usr/local/lib/yclaw/wait.sh`), and piped into guests over
  `tailscale ssh` — so it sources nothing and carries its own logging. Never
  add a dependency to it; never hand-roll a polling loop outside it.
- **One remote command, one string.** `ts_run` takes exactly one command
  string; `tailscale ssh` re-parses remote args in the login shell, so a
  compound command split across argv silently breaks.
- Each script declares its tool dependencies up front with `need` and reads
  fleet facts through `manifest_get`/`manifest_list`, never a hardcoded literal
  that duplicates `machines.json`.

## Comments & Docstrings

Code documents itself through names, types, and organization. No comments except
TODOs, non-obvious workarounds, or disabled code. Document the public API only;
a doc comment that restates the signature is clutter to delete.

## Testing

The suite lives in `tests/` and runs with `uv run pytest` (deps via
`uv sync --extra dev`). Write strict assertions against specific expected
values; a test that can't fail uncovers nothing. Mock the boundaries the CLI
talks to — the `tailscale ssh` subprocess seam in `remote.py`, the `security`
keychain calls, HTTP probes, and the clock — and leave the function under test
real. A database (or any stateful service) is not a mock boundary: when a test
needs one, start a real ephemeral instance with testcontainers rather than
mocking the driver or using an in-memory fake. Parameterize repeated test
bodies with `pytest.mark.parametrize`, giving each case a descriptive id and
its own expected values.

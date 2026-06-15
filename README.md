# yclaw

![yclaw banner](docs/assets/readme-banner.webp)

A personal project — a clean starting point I can build on without re-deciding conventions every time. The repo ships with agent docs, a style guide, Claude Code settings, and code search wired up, so the first real feature lands on a maintained foundation instead of a blank directory.

## Getting started

```bash
git clone https://github.com/yasyf/yclaw.git
cd yclaw
```

There's no runnable entrypoint yet — the repo currently holds project conventions and tooling. Once the first feature lands, this section gets the one command that runs it.

## What's here

- **`AGENTS.md` / `CLAUDE.md`** — how an agent should work in this repo: when to ask, how to plan, how to search code, and the general rules.
- **`STYLEGUIDE.md`** — the concrete style rules; language-specific sections get added when a stack is chosen.
- **`.claude/`** — Claude Code settings and guard hooks that keep edits and commits disciplined.
- **`.mcp.json`** — semble code search, fetched on demand via `uvx`.

## What problems does this solve?

- **No blank-page tax.** Conventions, agent docs, and tooling are already in place, so new work starts on a maintained foundation instead of a directory I have to set up by hand each time.
- **Consistent agent behavior.** `AGENTS.md` and the `.claude/` hooks encode how I want an agent to plan, search, and edit — the same way across every session.
- **Code search from day one.** `.mcp.json` wires up semantic search before there's much code to search, so it scales as the repo grows.

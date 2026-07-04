"""Plain-column table rendering, status styling, and the CLI exit-code policy.

Exit codes are load-bearing for scripting the CLI: ``0`` clean, ``1`` any FAIL, ``2`` usage,
``4`` a Tailscale check-mode wall, ``5`` a remote timeout.
"""

from collections.abc import Iterable, Sequence

import click

from .probes import ProbeResult, Status

EXIT_CLEAN = 0
EXIT_FAIL = 1
EXIT_USAGE = 2
EXIT_CHECK_WALL = 4
EXIT_TIMEOUT = 5


def ok(text: str) -> str:
    return click.style(text, fg="green", bold=True)


def fail(text: str) -> str:
    return click.style(text, fg="red", bold=True)


def warn(text: str) -> str:
    return click.style(text, fg="yellow", bold=True)


def manual(text: str) -> str:
    return click.style(text, fg="cyan")


_STATUS_LABEL = {
    Status.PASS: ("ok", ok),
    Status.FAIL: ("fail", fail),
    Status.MANUAL: ("manual", manual),
}


def exit_code_for(results: Iterable[ProbeResult]) -> int:
    return EXIT_FAIL if any(r.status is Status.FAIL for r in results) else EXIT_CLEAN


def style_status(status: Status) -> str:
    label, styler = _STATUS_LABEL[status]
    return styler(label)


def render_table(headers: Sequence[str], rows: Sequence[Sequence[str]]) -> str:
    widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(cell))
    fmt = "  ".join(f"{{:<{w}}}" for w in widths)
    lines = [fmt.format(*headers), fmt.format(*("-" * w for w in widths))]
    lines.extend(fmt.format(*row) for row in rows)
    return "\n".join(lines)

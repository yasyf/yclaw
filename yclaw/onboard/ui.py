"""Terminal chrome for the onboard flow: a braille spinner and flush-left status helpers.

The spinner is an async context manager animated by a single anyio task — no threads, no rich. On a
non-tty stream (or under ``-v``, where DEBUG logs would collide with the animation) it degrades to
printing its message once as a plain, escape-free line; the caller scopes the ``async with`` so the
spinner is never live while a child owns the terminal or a ``click`` prompt blocks. The ``hdr`` /
``note`` / ``ok`` / ``fail`` / ``warn`` helpers reuse ``output.py``'s styling so the onboard flow
reads like the rest of the CLI.

Verbosity is a module-level toggle: ``set_verbose(True)`` (called once from the command) disables
every subsequent spinner's animation, mirroring how ``cli.py`` sets the logger level globally.
"""

import subprocess
import sys
from types import TracebackType
from typing import Self, TextIO

import anyio
import click
from anyio.abc import TaskGroup

from .. import output

SPINNER_FRAMES = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
SPINNER_CADENCE = 0.1
ERASE_LINE = "\r\x1b[2K"

_VERBOSE = False


def set_verbose(value: bool) -> None:
    global _VERBOSE
    _VERBOSE = value


def open_url(url: str) -> None:
    """Best-effort ``open <url>`` on this Mac; a launch failure never aborts the caller."""
    try:
        subprocess.run(["open", url], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        pass


def hdr(text: str) -> None:
    click.echo()
    click.echo(click.style(text, bold=True))


def note(text: str) -> None:
    click.echo(click.style(f"  {text}", dim=True))


def ok(text: str) -> None:
    click.echo(f"  {output.ok('✓')} {text}")


def fail(text: str) -> None:
    click.echo(f"  {output.fail('✗')} {text}", err=True)


def warn(text: str) -> None:
    click.echo(f"  {output.warn('!')} {text}", err=True)


class Spinner:
    """An async-context-manager braille spinner with an optional final ✓/✗ line.

    Call ``ok`` / ``fail`` inside the ``async with`` body to queue a final glyph line; on exit the
    animated line is erased and replaced with it. On a non-tty stream or under ``set_verbose(True)``
    the spinner prints its message once as a plain, escape-free line and never animates.
    """

    def __init__(self, message: str, *, stream: TextIO | None = None) -> None:
        self._message = message
        self._stream = stream if stream is not None else sys.stdout
        self._active = False
        self._final: str | None = None
        self._task_group: TaskGroup | None = None

    def ok(self, text: str | None = None) -> None:
        self._final = f"  {output.ok('✓')} {text if text is not None else self._message}"

    def fail(self, text: str | None = None) -> None:
        self._final = f"  {output.fail('✗')} {text if text is not None else self._message}"

    async def _animate(self) -> None:
        i = 0
        while True:
            frame = SPINNER_FRAMES[i % len(SPINNER_FRAMES)]
            self._stream.write(f"\r  {frame} {self._message}")
            self._stream.flush()
            i += 1
            await anyio.sleep(SPINNER_CADENCE)

    async def __aenter__(self) -> Self:
        self._active = self._stream.isatty() and not _VERBOSE
        if not self._active:
            self._stream.write(f"  {self._message}\n")
            self._stream.flush()
            return self
        self._task_group = anyio.create_task_group()
        await self._task_group.__aenter__()
        self._task_group.start_soon(self._animate)
        return self

    async def __aexit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        tb: TracebackType | None,
    ) -> bool:
        if not self._active:
            return False
        self._task_group.cancel_scope.cancel()
        await self._task_group.__aexit__(None, None, None)
        self._stream.write(ERASE_LINE)
        if self._final is not None:
            self._stream.write(self._final + "\n")
        self._stream.flush()
        return False

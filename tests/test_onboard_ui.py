import io

import anyio
import pytest

from yclaw.onboard import ui

pytestmark = pytest.mark.anyio


class FakeStream(io.StringIO):
    def __init__(self, *, tty: bool) -> None:
        super().__init__()
        self._tty = tty

    def isatty(self) -> bool:
        return self._tty


@pytest.fixture(autouse=True)
def _reset_verbose():
    ui.set_verbose(False)
    yield
    ui.set_verbose(False)


async def test_spinner_non_tty_prints_message_once_without_escapes():
    stream = FakeStream(tty=False)
    async with ui.Spinner("waiting for token", stream=stream) as spin:
        spin.ok("token written")
        await anyio.sleep(0.05)
    out = stream.getvalue()
    assert out == "  waiting for token\n"
    assert "\x1b" not in out
    assert "\r" not in out


async def test_spinner_tty_animates_erases_and_swaps_final_glyph():
    stream = FakeStream(tty=True)
    async with ui.Spinner("loading", stream=stream) as spin:
        await anyio.sleep(0.25)
        spin.ok("loaded")
    out = stream.getvalue()
    assert any(frame in out for frame in ui.SPINNER_FRAMES)
    assert "\r" in out
    assert ui.ERASE_LINE in out
    assert "✓" in out
    assert "loaded" in out


async def test_spinner_tty_erases_line_without_final_glyph():
    stream = FakeStream(tty=True)
    async with ui.Spinner("loading", stream=stream):
        await anyio.sleep(0.15)
    out = stream.getvalue()
    assert ui.ERASE_LINE in out
    assert out.endswith(ui.ERASE_LINE)
    assert "✓" not in out
    assert "✗" not in out


async def test_spinner_tty_fail_glyph_on_explicit_fail():
    stream = FakeStream(tty=True)
    async with ui.Spinner("connecting", stream=stream) as spin:
        await anyio.sleep(0.12)
        spin.fail("no route")
    out = stream.getvalue()
    assert ui.ERASE_LINE in out
    assert "✗" in out
    assert "no route" in out


async def test_spinner_verbose_disables_animation_even_on_tty():
    ui.set_verbose(True)
    stream = FakeStream(tty=True)
    async with ui.Spinner("loading", stream=stream) as spin:
        spin.ok("done")
        await anyio.sleep(0.05)
    out = stream.getvalue()
    assert out == "  loading\n"
    assert "\x1b" not in out
    assert "\r" not in out


def test_ok_prints_check_glyph_to_stdout(capsys):
    ui.ok("all good")
    captured = capsys.readouterr()
    assert "✓" in captured.out
    assert "all good" in captured.out
    assert captured.err == ""


def test_fail_prints_cross_glyph_to_stderr(capsys):
    ui.fail("it broke")
    captured = capsys.readouterr()
    assert "✗" in captured.err
    assert "it broke" in captured.err
    assert captured.out == ""


def test_warn_prints_bang_glyph_to_stderr(capsys):
    ui.warn("careful")
    captured = capsys.readouterr()
    assert "!" in captured.err
    assert "careful" in captured.err
    assert captured.out == ""


def test_hdr_and_note_go_to_stdout(capsys):
    ui.hdr("Gate B — Codex login")
    ui.note("open the URL below")
    out = capsys.readouterr().out
    assert "Gate B — Codex login" in out
    assert "open the URL below" in out

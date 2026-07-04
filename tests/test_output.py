import pytest

from yclaw import output
from yclaw.probes import ProbeResult, Status


def _result(status: Status) -> ProbeResult:
    return ProbeResult("x", status, "d")


def test_exit_code_constants():
    assert output.EXIT_CLEAN == 0
    assert output.EXIT_FAIL == 1
    assert output.EXIT_USAGE == 2
    assert output.EXIT_CHECK_WALL == 4
    assert output.EXIT_TIMEOUT == 5


@pytest.mark.parametrize(
    ("statuses", "expected"),
    [
        ([], output.EXIT_CLEAN),
        ([Status.PASS], output.EXIT_CLEAN),
        ([Status.MANUAL], output.EXIT_CLEAN),
        ([Status.PASS, Status.MANUAL], output.EXIT_CLEAN),
        ([Status.FAIL], output.EXIT_FAIL),
        ([Status.PASS, Status.FAIL, Status.MANUAL], output.EXIT_FAIL),
    ],
    ids=["empty", "pass", "manual", "pass+manual", "fail", "mixed-with-fail"],
)
def test_exit_code_for(statuses, expected):
    assert output.exit_code_for([_result(s) for s in statuses]) == expected


@pytest.mark.parametrize(
    ("status", "label"),
    [(Status.PASS, "ok"), (Status.FAIL, "fail"), (Status.MANUAL, "manual")],
    ids=["pass", "fail", "manual"],
)
def test_style_status_contains_label(status, label):
    assert label in output.style_status(status)


def test_render_table_exact():
    rendered = output.render_table(["NODE", "STATUS"], [["metal", "ok"], ["hermes", "fail"]])
    assert rendered == "NODE    STATUS\n------  ------\nmetal   ok    \nhermes  fail  "

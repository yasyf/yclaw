import click
import pytest

from yclaw.onboard import gates
from yclaw.onboard.gates import Gate, GateResult, GateStatus, UnknownGateError


def _reject(title: str) -> bool:
    raise AssertionError(f"confirm_retry should not be called (title={title!r})")


def _scripted_gate(key: str, outcomes):
    calls = {"body": 0}
    iterator = iter(outcomes)

    def body() -> GateResult:
        calls["body"] += 1
        outcome = next(iterator)
        if isinstance(outcome, BaseException):
            raise outcome
        return outcome

    return Gate(key=key, title=f"Gate {key}", body=body), calls


def _const_gate(key: str, status: GateStatus, order: list[str]) -> Gate:
    def body() -> GateResult:
        order.append(key)
        return GateResult(status, detail=key)

    return Gate(key, f"Gate {key}", body)


def test_gates_run_in_order_and_results_collected():
    order: list[str] = []
    fleet = [
        _const_gate("a", GateStatus.DONE, order),
        _const_gate("b", GateStatus.DONE, order),
        _const_gate("c", GateStatus.DONE, order),
    ]
    results = gates.drive(fleet, confirm_retry=_reject)
    assert order == ["a", "b", "c"]
    assert [g.key for g, _ in results] == ["a", "b", "c"]
    assert [r.status for _, r in results] == [GateStatus.DONE, GateStatus.DONE, GateStatus.DONE]
    assert [r.detail for _, r in results] == ["a", "b", "c"]


def test_only_runs_single_named_gate():
    order: list[str] = []
    fleet = [
        _const_gate("a", GateStatus.DONE, order),
        _const_gate("b", GateStatus.DONE, order),
        _const_gate("c", GateStatus.DONE, order),
    ]
    results = gates.drive(fleet, only="b", confirm_retry=_reject)
    assert order == ["b"]
    assert [g.key for g, _ in results] == ["b"]


def test_unknown_only_key_raises_with_known_keys():
    order: list[str] = []
    fleet = [_const_gate("a", GateStatus.DONE, order), _const_gate("b", GateStatus.DONE, order)]
    with pytest.raises(UnknownGateError) as excinfo:
        gates.drive(fleet, only="nope", confirm_retry=_reject)
    assert excinfo.value.key == "nope"
    assert excinfo.value.known == ("a", "b")
    assert order == []


@pytest.mark.parametrize("status", [GateStatus.DONE, GateStatus.SKIPPED], ids=["done", "skipped"])
def test_non_failed_body_result_returned_without_confirm(status):
    gate, calls = _scripted_gate("x", [GateResult(status, detail="d")])
    ((_, result),) = gates.drive([gate], confirm_retry=_reject)
    assert result.status is status
    assert result.detail == "d"
    assert calls["body"] == 1


def test_failed_gate_retries_while_confirm_true_then_stops_on_false():
    gate, calls = _scripted_gate(
        "x",
        [
            GateResult(GateStatus.FAILED, "boom-1", "uv run yclaw onboard --gate x"),
            GateResult(GateStatus.FAILED, "boom-2", "uv run yclaw onboard --gate x"),
        ],
    )
    confirmed = iter([True, False])
    titles: list[str] = []

    def confirm_retry(title: str) -> bool:
        titles.append(title)
        return next(confirmed)

    ((_, result),) = gates.drive([gate], confirm_retry=confirm_retry)
    assert calls["body"] == 2
    assert titles == ["Gate x", "Gate x"]
    assert result.status is GateStatus.FAILED
    assert result.detail == "boom-2"
    assert result.retry_command == "uv run yclaw onboard --gate x"


def test_failed_gate_retries_until_success():
    gate, calls = _scripted_gate(
        "x",
        [GateResult(GateStatus.FAILED, "boom"), GateResult(GateStatus.DONE, "recovered")],
    )
    titles: list[str] = []

    def confirm_retry(title: str) -> bool:
        titles.append(title)
        return True

    ((_, result),) = gates.drive([gate], confirm_retry=confirm_retry)
    assert calls["body"] == 2
    assert titles == ["Gate x"]
    assert result.status is GateStatus.DONE
    assert result.detail == "recovered"


def test_ctrl_c_in_body_skips_gate_without_confirm():
    gate, calls = _scripted_gate("x", [KeyboardInterrupt()])

    def confirm_retry(title: str) -> bool:
        raise AssertionError("confirm_retry must not run when the body is interrupted")

    ((_, result),) = gates.drive([gate], confirm_retry=confirm_retry)
    assert result.status is GateStatus.SKIPPED
    assert result.detail == "skipped by user (ctrl-c)"
    assert calls["body"] == 1


def test_click_abort_in_body_skips_gate_without_confirm():
    # click.prompt raises click.Abort (not KeyboardInterrupt) on ctrl-c; the engine must skip it too.
    gate, calls = _scripted_gate("x", [click.Abort()])

    def confirm_retry(title: str) -> bool:
        raise AssertionError("confirm_retry must not run when the body aborts")

    ((_, result),) = gates.drive([gate], confirm_retry=confirm_retry)
    assert result.status is GateStatus.SKIPPED
    assert result.detail == "skipped by user (ctrl-c)"
    assert calls["body"] == 1


def test_ctrl_c_in_confirm_aborts_as_failed_without_retry():
    gate, calls = _scripted_gate("x", [GateResult(GateStatus.FAILED, "boom", "retry-cmd")])

    def confirm_retry(title: str) -> bool:
        raise KeyboardInterrupt

    ((_, result),) = gates.drive([gate], confirm_retry=confirm_retry)
    assert result.status is GateStatus.FAILED
    assert result.detail == "boom"
    assert result.retry_command == "retry-cmd"
    assert calls["body"] == 1


def test_failed_gate_does_not_halt_later_gates():
    order: list[str] = []
    fleet = [
        _const_gate("a", GateStatus.DONE, order),
        _const_gate("b", GateStatus.FAILED, order),
        _const_gate("c", GateStatus.DONE, order),
    ]
    results = gates.drive(fleet, confirm_retry=lambda title: False)
    assert order == ["a", "b", "c"]
    assert [r.status for _, r in results] == [GateStatus.DONE, GateStatus.FAILED, GateStatus.DONE]


def test_gate_result_defaults_are_empty_strings():
    result = GateResult(GateStatus.DONE)
    assert result.detail == ""
    assert result.retry_command == ""

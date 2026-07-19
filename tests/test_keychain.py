import getpass
import subprocess

import pytest

from yclaw import keychain
from yclaw.keychain import KeychainError


class _FakeSecurity:
    """Records every ``security`` argv and returns a canned result per subcommand."""

    def __init__(self, service_returncode: int, service_stdout: str) -> None:
        self.calls: list[list[str]] = []
        self._service_returncode = service_returncode
        self._service_stdout = service_stdout

    def __call__(self, argv, **kwargs):
        self.calls.append(argv)
        sub = argv[1]
        if sub == "find-generic-password" and "yclaw-keychain-password" in argv:
            return subprocess.CompletedProcess(argv, 0, stdout="unlock-pw\n", stderr="")
        if sub == "find-generic-password":
            return subprocess.CompletedProcess(argv, self._service_returncode, stdout=self._service_stdout, stderr="")
        return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")


@pytest.fixture
def present_keychain(tmp_path, monkeypatch):
    path = tmp_path / "yclaw.keychain-db"
    path.write_text("")
    monkeypatch.setattr(keychain, "KEYCHAIN_PATH", path)
    return path


def test_read_unlock_read_lock_order(present_keychain, monkeypatch):
    fake = _FakeSecurity(service_returncode=0, service_stdout="the-secret\n")
    monkeypatch.setattr(keychain.subprocess, "run", fake)

    value = keychain.read("yclaw-metal-admin-pass")

    assert value == "the-secret"
    user = getpass.getuser()
    path = str(present_keychain)
    assert fake.calls == [
        ["security", "find-generic-password", "-a", user, "-s", "yclaw-keychain-password", "-w"],
        ["security", "unlock-keychain", "-p", "unlock-pw", path],
        ["security", "find-generic-password", "-a", user, "-s", "yclaw-metal-admin-pass", "-w", path],
        ["security", "lock-keychain", path],
    ]


def test_read_locks_even_on_missing_item(present_keychain, monkeypatch):
    fake = _FakeSecurity(service_returncode=44, service_stdout="")
    monkeypatch.setattr(keychain.subprocess, "run", fake)

    with pytest.raises(KeychainError, match="not found"):
        keychain.read("yclaw-metal-admin-pass")

    assert [c[1] for c in fake.calls] == [
        "find-generic-password",
        "unlock-keychain",
        "find-generic-password",
        "lock-keychain",
    ]
    assert fake.calls[-1] == ["security", "lock-keychain", str(present_keychain)]


def test_missing_keychain_file_raises(tmp_path, monkeypatch):
    monkeypatch.setattr(keychain, "KEYCHAIN_PATH", tmp_path / "absent.keychain-db")
    called = False

    def fake_run(*args, **kwargs):
        nonlocal called
        called = True
        return subprocess.CompletedProcess(args, 0, stdout="", stderr="")

    monkeypatch.setattr(keychain.subprocess, "run", fake_run)
    with pytest.raises(KeychainError, match="not found"):
        keychain.read("yclaw-metal-admin-pass")
    assert called is False


def test_ensure_seeds_login_password_before_creating_the_keychain(tmp_path, monkeypatch):
    path = tmp_path / "yclaw.keychain-db"  # absent → ensure() proceeds
    monkeypatch.setattr(keychain, "KEYCHAIN_PATH", path)
    calls = []

    def fake_run(argv, **kwargs):
        calls.append(argv)
        return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

    monkeypatch.setattr(keychain.subprocess, "run", fake_run)
    keychain.ensure()

    subs = [c[1] for c in calls]
    assert subs[0] == "add-generic-password"  # the login-keychain write happens FIRST
    assert "yclaw-keychain-password" in calls[0]
    assert str(path) not in calls[0]  # ...to the login keychain, not the dedicated one
    assert subs.index("add-generic-password") < subs.index("create-keychain")


def test_ensure_login_write_failure_aborts_before_create(tmp_path, monkeypatch):
    path = tmp_path / "yclaw.keychain-db"
    monkeypatch.setattr(keychain, "KEYCHAIN_PATH", path)
    calls = []

    def fake_run(argv, **kwargs):
        calls.append(argv)
        rc = 1 if argv[1] == "add-generic-password" else 0  # background session: login write rejected
        return subprocess.CompletedProcess(argv, rc, stdout="", stderr="")

    monkeypatch.setattr(keychain.subprocess, "run", fake_run)
    with pytest.raises(KeychainError, match="Terminal.app"):
        keychain.ensure()

    assert "create-keychain" not in [c[1] for c in calls]  # never created
    assert not path.exists()

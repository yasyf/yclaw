import subprocess

import pytest

from yclaw import sops
from yclaw.sops import SopsError


class _FakeRun:
    """Records every argv/env handed to the sops/age subprocess, returning a canned result."""

    def __init__(self, *, returncode=0, stdout="", stderr="") -> None:
        self.calls: list[dict] = []
        self._returncode = returncode
        self._stdout = stdout
        self._stderr = stderr

    def __call__(self, argv, **kwargs):
        self.calls.append({"argv": argv, "env": kwargs.get("env")})
        return subprocess.CompletedProcess(argv, self._returncode, stdout=self._stdout, stderr=self._stderr)


def test_encrypt_uses_yaml_args_and_writes_plaintext_to_a_tempfile(tmp_path, monkeypatch):
    fake = _FakeRun(stdout="CIPHERTEXT")
    monkeypatch.setattr(sops.subprocess, "run", fake)

    assert sops.encrypt("SECRET-PLAINTEXT", "age1recipient") == "CIPHERTEXT"

    argv = fake.calls[0]["argv"]
    assert argv[:2] == ["sops", "--encrypt"]
    for flag in ("--config", "/dev/null", "--input-type", "yaml", "--output-type", "yaml"):
        assert flag in argv
    assert argv[argv.index("--age") + 1] == "age1recipient"
    assert "SECRET-PLAINTEXT" not in argv  # the value travels via the temp file, never argv


def test_nonzero_exit_raises_sopserror_without_leaking_the_value(monkeypatch):
    fake = _FakeRun(returncode=1, stderr="age: no identity matched")
    monkeypatch.setattr(sops.subprocess, "run", fake)

    with pytest.raises(SopsError) as excinfo:
        sops.encrypt("SUPER-SECRET-VALUE", "age1recipient")

    assert "exited 1" in str(excinfo.value)
    assert "age: no identity matched" in str(excinfo.value)
    assert "SUPER-SECRET-VALUE" not in str(excinfo.value)


def test_pubkey_rejects_output_that_is_not_an_age_key(tmp_path, monkeypatch):
    monkeypatch.setattr(sops.subprocess, "run", _FakeRun(stdout="not-a-key\n"))
    with pytest.raises(SopsError, match="could not derive an age public key"):
        sops.pubkey(tmp_path / "key.txt")


def test_pubkey_returns_the_stripped_age_key(tmp_path, monkeypatch):
    monkeypatch.setattr(sops.subprocess, "run", _FakeRun(stdout="age1validpubkey\n"))
    assert sops.pubkey(tmp_path / "key.txt") == "age1validpubkey"


def test_extract_targets_the_leaf_and_sets_the_age_key_env(tmp_path, monkeypatch):
    fake = _FakeRun(stdout="leaf-value\n")
    monkeypatch.setattr(sops.subprocess, "run", fake)
    bundle, key = tmp_path / "b.sops.yaml", tmp_path / "key.txt"

    assert sops.extract(bundle, key, '["cliproxy"]["api-key"]') == "leaf-value\n"

    call = fake.calls[0]
    argv = call["argv"]
    assert argv[argv.index("--extract") + 1] == '["cliproxy"]["api-key"]'
    assert str(bundle) == argv[-1]
    assert call["env"]["SOPS_AGE_KEY_FILE"] == str(key)


def test_decrypt_sets_the_age_key_env(tmp_path, monkeypatch):
    fake = _FakeRun(stdout="plaintext")
    monkeypatch.setattr(sops.subprocess, "run", fake)
    bundle, key = tmp_path / "b.sops.yaml", tmp_path / "key.txt"

    assert sops.decrypt(bundle, key) == "plaintext"
    assert fake.calls[0]["argv"][:2] == ["sops", "--decrypt"]
    assert fake.calls[0]["env"]["SOPS_AGE_KEY_FILE"] == str(key)


def test_keygen_shells_out_to_age_keygen_output_flag(tmp_path, monkeypatch):
    fake = _FakeRun()
    monkeypatch.setattr(sops.subprocess, "run", fake)
    path = tmp_path / "key.txt"

    sops.keygen(path)
    assert fake.calls[0]["argv"] == ["age-keygen", "-o", str(path)]

"""``yclaw logs`` — tail a service's logs on a fleet node.

darwin nodes stream their launchd stdout/stderr log files through ``tail`` (whose native ``==>``
headers separate the two files); hermes streams its systemd journal through ``journalctl``.
BlueBubbles keeps its logs inside the app, so there is nothing to tail over ssh.
"""

import shlex

import click

from . import output, remote
from .dispatch import resolve_machine, resolve_service, run
from .manifest import Machine, Service, load_manifest


def _log_command(machine: Machine, service: Service, lines: int, follow: bool) -> str:
    if machine.name == "bluebubbles":
        raise click.UsageError("bluebubbles logs are app-internal; use the VNC console")
    if service.systemd is not None:
        return f"journalctl -u {service.systemd} -n {lines}{' -f' if follow else ''}"
    if service.logs:
        flag = "-F " if follow else ""
        paths = " ".join(shlex.quote(p) for p in service.logs)
        return f"tail -n {lines} {flag}{paths}"
    raise click.UsageError(f"service {service.name!r} on {machine.name} has no logs to tail")


def _list_services(machine: Machine) -> None:
    rows = []
    for svc in machine.services.values():
        if svc.systemd is not None:
            where = f"journalctl -u {svc.systemd}"
        elif svc.logs:
            where = " ".join(svc.logs)
        else:
            where = "(app-internal)"
        rows.append([svc.name, where])
    click.echo(output.render_table(["SERVICE", "LOGS"], rows))


@click.command("logs")
@click.argument("machine")
@click.argument("service", required=False)
@click.option("-f", "--follow", is_flag=True, help="Stream new lines as they arrive (Ctrl-C to stop).")
@click.option("-n", "--lines", type=int, default=50, show_default=True, help="Number of trailing lines to show.")
def logs(machine: str, service: str | None, follow: bool, lines: int) -> None:
    """Tail SERVICE's logs on MACHINE; with no SERVICE, list what MACHINE exposes."""
    target = resolve_machine(load_manifest(), machine)
    if service is None:
        _list_services(target)
        return
    svc = resolve_service(target, service)
    command = _log_command(target, svc, lines, follow)
    if follow:
        remote.stream(target, command)
    result = run(lambda: remote.run(target, command))
    click.echo(result.stdout, nl=False)
    click.echo(result.stderr, nl=False, err=True)
    raise SystemExit(result.returncode)

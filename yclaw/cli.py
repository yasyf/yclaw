"""The ``yclaw`` command group: global logging + version, with every subcommand registered here."""

import sys

import click
from loguru import logger

from .doctor import doctor
from .logs import logs
from .restart import bounce, restart
from .secret import secret
from .ssh import ssh
from .status import status
from .vm import vm
from .wait import wait


@click.group()
@click.version_option(package_name="yclaw")
@click.option("-v", "--verbose", is_flag=True, help="Enable DEBUG logging.")
def main(verbose: bool) -> None:
    logger.remove()
    logger.add(sys.stderr, level="DEBUG" if verbose else "INFO")


main.add_command(ssh)
main.add_command(wait)
main.add_command(logs)
main.add_command(status)
main.add_command(doctor)
main.add_command(restart)
main.add_command(bounce)
main.add_command(vm)
main.add_command(secret)

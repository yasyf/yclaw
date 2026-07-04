"""The ``yclaw`` command group. Subcommands land in stage 2; this stage wires logging + version."""

import sys

import click
from loguru import logger


@click.group()
@click.version_option(package_name="yclaw")
@click.option("-v", "--verbose", is_flag=True, help="Enable DEBUG logging.")
def main(verbose: bool) -> None:
    logger.remove()
    logger.add(sys.stderr, level="DEBUG" if verbose else "INFO")

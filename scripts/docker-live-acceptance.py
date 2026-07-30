#!/usr/bin/env python3
"""Compatibility entry point for the renamed Docker E2E suite."""

from docker_e2e.runner import main


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, ValueError) as error:
        print(f"error: {error}", file=__import__("sys").stderr)
        raise SystemExit(2)

"""Classify captured gcloud metadata failures without exposing their content."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


_FAILURE_CLASSES = (
    (
        "PERMISSION_DENIED",
        re.compile(r"permission[ _-]?denied|does not have permission", re.IGNORECASE),
    ),
    (
        "RESOURCE_NOT_FOUND",
        re.compile(r"not[ _-]?found|was not found|could not be found", re.IGNORECASE),
    ),
    (
        "API_UNAVAILABLE",
        re.compile(
            r"unavailable|deadline exceeded|timed out|temporarily unavailable|network is unreachable",
            re.IGNORECASE,
        ),
    ),
)


def classify_gcloud_metadata_failure(message: str) -> str:
    """Map a private provider error to one stable public category."""

    for failure_class, pattern in _FAILURE_CLASSES:
        if pattern.search(message):
            return failure_class
    return "UNKNOWN"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    args = parser.parse_args(argv)
    message = args.input.read_text(encoding="utf-8", errors="replace")
    print(
        "GATEWAY_VM_DIAGNOSTIC_FAILURE_CLASS="
        f"{classify_gcloud_metadata_failure(message)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

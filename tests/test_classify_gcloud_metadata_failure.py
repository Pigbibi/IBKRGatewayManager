from __future__ import annotations

import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "classify_gcloud_metadata_failure.py"


def _classify(tmp_path: Path, message: str) -> str:
    diagnostic = tmp_path / "diagnostic.txt"
    diagnostic.write_text(message, encoding="utf-8")
    completed = subprocess.run(
        [sys.executable, str(SCRIPT), "--input", str(diagnostic)],
        check=True,
        capture_output=True,
        text=True,
    )
    assert message not in completed.stdout + completed.stderr
    return completed.stdout.strip()


def test_classifies_only_sanitized_metadata_failure_categories(tmp_path: Path) -> None:
    assert _classify(tmp_path, "PERMISSION_DENIED: missing compute.instances.get") == (
        "GATEWAY_VM_DIAGNOSTIC_FAILURE_CLASS=PERMISSION_DENIED"
    )
    assert _classify(tmp_path, "The resource was not found") == (
        "GATEWAY_VM_DIAGNOSTIC_FAILURE_CLASS=RESOURCE_NOT_FOUND"
    )
    assert _classify(tmp_path, "UNAVAILABLE: upstream temporarily unavailable") == (
        "GATEWAY_VM_DIAGNOSTIC_FAILURE_CLASS=API_UNAVAILABLE"
    )
    assert _classify(tmp_path, "unrecognized provider response: sensitive-value") == (
        "GATEWAY_VM_DIAGNOSTIC_FAILURE_CLASS=UNKNOWN"
    )

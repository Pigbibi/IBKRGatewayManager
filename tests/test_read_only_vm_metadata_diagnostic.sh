#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
workflow_file="$repo_dir/.github/workflows/read-only-vm-metadata-diagnostic.yml"

test -f "$workflow_file"
grep -Fq 'name: Read-Only Gateway VM Metadata Diagnostic' "$workflow_file"
grep -Fq 'workflow_dispatch:' "$workflow_file"
! grep -Fq 'schedule:' "$workflow_file"
! grep -Fq 'push:' "$workflow_file"
grep -Fq 'One gateway target from IB_GATEWAY_TARGETS_JSON' "$workflow_file"
grep -Fq 'target_index' "$workflow_file"
grep -Fq 'target_digest' "$workflow_file"
grep -Fq 'Resolved gateway target changed between jobs' "$workflow_file"
grep -Fq 'gcloud compute instances describe' "$workflow_file"
grep -Fq 'uses: actions/checkout@v6' "$workflow_file"
grep -Fq 'persist-credentials: false' "$workflow_file"
grep -Fq 'GATEWAY_VM_DIAGNOSTIC_STATUS=VM_RUNNING' "$workflow_file"
grep -Fq 'scripts/classify_gcloud_metadata_failure.py' "$workflow_file"
grep -Fq 'GATEWAY_VM_DIAGNOSTIC_FAILURE_CLASS=' "$repo_dir/scripts/classify_gcloud_metadata_failure.py"
grep -Fq 'GATEWAY_VM_DIAGNOSTIC_LIMIT=NO_GATEWAY_OR_CONTAINER_HEALTH_ASSERTION' "$workflow_file"
for forbidden in \
  'gcloud compute ssh' \
  'gcloud compute scp' \
  'gcloud secrets versions' \
  'gcloud compute instances reset' \
  'docker ' \
  'systemctl ' \
  '2fa' \
  'order' \
  'curl '
do
  if grep -Fqi "$forbidden" "$workflow_file"; then
    echo "Read-only VM metadata workflow contains forbidden operation: $forbidden" >&2
    exit 1
  fi
done

grep -Fq 'GCP_PROJECT_ID: ${{ steps.metadata.outputs.gcp_project_id }}' "$workflow_file"

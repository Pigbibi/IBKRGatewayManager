#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
workflow_file="$repo_dir/.github/workflows/read-only-scheduler-diagnostic.yml"

test -f "$workflow_file"
grep -Fq 'name: Read-Only Gateway Scheduler Diagnostic' "$workflow_file"
grep -Fq 'workflow_dispatch:' "$workflow_file"
! grep -Fq '  push:' "$workflow_file"
! grep -Fq '  schedule:' "$workflow_file"
grep -Fq 'IB_GATEWAY_TARGETS_JSON is required' "$workflow_file"
grep -Fq 'Gateway scheduler mapping is incomplete' "$workflow_file"
grep -Fq 'target.cloud_scheduler' "$workflow_file"
grep -Fq 'target["location"]' "$workflow_file"
grep -Fq 'target["jobs"]' "$workflow_file"
grep -Fq 'gcloud scheduler jobs describe "${job}"' "$workflow_file"
grep -Fq -- '--location "${location}"' "$workflow_file"
grep -Fq 'GATEWAY_SCHEDULER_DIAGNOSTIC_STATUS=ALL_CONFIGURED_JOBS_ENABLED' "$workflow_file"
grep -Fq 'GATEWAY_SCHEDULER_DIAGNOSTIC_STATUS=METADATA_UNAVAILABLE' "$workflow_file"
grep -Fq 'GATEWAY_SCHEDULER_DIAGNOSTIC_STATUS=JOB_NOT_ENABLED' "$workflow_file"
grep -Fq 'GATEWAY_SCHEDULER_DIAGNOSTIC_STATUS=JOB_STATE_UNAVAILABLE' "$workflow_file"
grep -Fq 'id-token: write' "$workflow_file"
! grep -Fq 'actions/checkout' "$workflow_file"
! grep -Fq 'contents: read' "$workflow_file"

for forbidden in \
  'gcloud scheduler jobs create' \
  'gcloud scheduler jobs delete' \
  'gcloud scheduler jobs pause' \
  'gcloud scheduler jobs resume' \
  'gcloud scheduler jobs run' \
  'gcloud scheduler jobs update' \
  'gcloud compute ssh' \
  'gcloud secrets' \
  'docker ' \
  'curl ' \
  'wget '
do
  if grep -Fq "$forbidden" "$workflow_file"; then
    echo "Read-only scheduler workflow contains forbidden operation: $forbidden" >&2
    exit 1
  fi
done

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
python3 - "$workflow_file" "$tmp_dir/read_states.sh" <<'PY'
from pathlib import Path
import sys
import textwrap

workflow = Path(sys.argv[1]).read_text(encoding="utf-8")
section = workflow.split("      - name: Read configured scheduler job states\n", 1)[1]
script = section.split("        run: |\n", 1)[1]
Path(sys.argv[2]).write_text(textwrap.dedent(script), encoding="utf-8")
PY
mkdir "$tmp_dir/bin"
cat > "$tmp_dir/bin/gcloud" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *' enabled-job '*) printf '%s\n' ENABLED ;;
  *' paused-job '*) printf '%s\n' PAUSED ;;
  *) exit 1 ;;
esac
SH
chmod +x "$tmp_dir/bin/gcloud"

PATH="$tmp_dir/bin:$PATH" \
  SCHEDULER_TARGETS_JSON='[{"location":"region-a","jobs":["enabled-job"]},{"location":"region-b","jobs":["enabled-job"]}]' \
  GCP_PROJECT_ID='test-project' \
  bash "$tmp_dir/read_states.sh" > "$tmp_dir/enabled.out"
grep -Fq 'GATEWAY_SCHEDULER_DIAGNOSTIC_STATUS=ALL_CONFIGURED_JOBS_ENABLED' "$tmp_dir/enabled.out"
grep -Fq 'GATEWAY_SCHEDULER_DIAGNOSTIC_COUNTS=checked:2' "$tmp_dir/enabled.out"

if PATH="$tmp_dir/bin:$PATH" \
  SCHEDULER_TARGETS_JSON='[{"location":"region-a","jobs":["paused-job"]}]' \
  GCP_PROJECT_ID='test-project' \
  bash "$tmp_dir/read_states.sh" > "$tmp_dir/paused.out" 2>&1; then
  echo "Paused scheduler job unexpectedly passed" >&2
  exit 1
fi
grep -Fq 'GATEWAY_SCHEDULER_DIAGNOSTIC_STATUS=JOB_NOT_ENABLED' "$tmp_dir/paused.out"

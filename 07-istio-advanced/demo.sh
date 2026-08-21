#!/usr/bin/env bash
# Runs the five acts in order, pausing between beats.
# NONINTERACTIVE=1 to skip pauses. ACTS="1 3" to run a subset.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

ACTS="${ACTS:-1 2 3 4 5}"
declare -A ACT_DIR=(
  [1]=act1-gateway [2]=act2-waypoint [3]=act3-multicluster
  [4]=act4-ai-gateway [5]=act5-observability
)
declare -A ACT_NAME=(
  [1]="North-south Gateway API"
  [2]="Waypoints: L7 without sidecars"
  [3]="Two clusters, one mesh"
  [4]="AI gateway"
  [5]="Observability"
)

banner "Istio ${ISTIO_VERSION} — five acts"
for a in $ACTS; do detail "Act ${a}: ${ACT_NAME[$a]}"; done

for a in $ACTS; do
  echo ""
  banner "ACT ${a} — ${ACT_NAME[$a]}"
  pause
  bash "${ADV_ROOT}/${ACT_DIR[$a]}/run.sh"
done

echo ""
banner "All acts complete — running verification"
bash "${ADV_ROOT}/verify.sh"

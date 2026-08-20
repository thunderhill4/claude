#!/usr/bin/env bash
# `helm install sympozium` has been observed to silently drop a subset of the
# chart's built-in SkillPack resources (kind: SkillPack, labeled
# sympozium.ai/builtin=true — e.g. web-endpoint, k8s-ops) from a clean install,
# even though `helm get manifest` shows them as part of the release and the
# release itself reports Deployed. SympoziumPolicy and other kinds in the same
# chart were not observed to be affected — this looks specific to SkillPack.
# Symptom: an Agent referencing skillPackRef: web-endpoint gets an AgentRun
# stuck Failed with "no sidecar with requiresServer=true found", and any other
# missing built-in SkillPack (k8s-ops, etc.) silently breaks whatever
# references it (e.g. the skills-webhook's INJECT_SKILL_MAP).
#
# Fix: re-apply every builtin-labeled SkillPack from the release's own tracked
# manifest. Safe to re-run — a no-op once all builtins are present.
set -euo pipefail

SYMPOZIUM_NS="${SYMPOZIUM_NAMESPACE:-sympozium-system}"

python3 - "$SYMPOZIUM_NS" <<'PYEOF'
import subprocess, sys, yaml

ns = sys.argv[1]
manifest = subprocess.run(
    ["helm", "get", "manifest", "sympozium", "-n", ns],
    capture_output=True, text=True, check=True,
).stdout

docs = [d for d in yaml.safe_load_all(manifest) if d]
builtin_skillpacks = [
    d for d in docs
    if d.get("kind") == "SkillPack"
    and d.get("metadata", {}).get("labels", {}).get("sympozium.ai/builtin") == "true"
]

if not builtin_skillpacks:
    print("No builtin SkillPacks found in the release manifest — nothing to check.")
    sys.exit(0)

existing = subprocess.run(
    ["kubectl", "get", "skillpacks", "-n", ns, "-o", "name"],
    capture_output=True, text=True, check=True,
).stdout
existing_names = {line.split("/", 1)[1] for line in existing.splitlines() if line}

missing = [d for d in builtin_skillpacks if d["metadata"]["name"] not in existing_names]

if not missing:
    print(f"All {len(builtin_skillpacks)} builtin SkillPacks already present — nothing to do.")
    sys.exit(0)

names = ", ".join(d["metadata"]["name"] for d in missing)
print(f"Re-applying {len(missing)} missing builtin SkillPack(s): {names}")

payload = yaml.safe_dump_all(missing)
subprocess.run(["kubectl", "apply", "-f", "-"], input=payload, text=True, check=True)
PYEOF

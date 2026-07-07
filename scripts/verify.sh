#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# role: tool
#
# scripts/verify.sh — snelle functionele verificatie (pre-push gate).
#
# Parseert alle YAML (waardes én manifests) en valideert de Kubernetes-
# manifests (argo/, fuse-device-plugin/, seccomp-profiles/, storage/,
# cert-manager/) met kubeconform. Helm-values zijn vrije vorm en worden
# alleen op parseerbaarheid gecontroleerd. Dry-run only.
#
# Writes: read-only (kubeconform cachet schemas in $HOME)
# Idempotent: yes
# Requires: python3, kubectl, kubeconform
#
# Usage:
#   ./scripts/verify.sh

set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'EOF'
import pathlib
import sys
import yaml

bad = []
count = 0
for f in sorted(pathlib.Path(".").rglob("*.yaml")):
    if any(p in {".git", ".venv", "node_modules"} for p in f.parts):
        continue
    count += 1
    try:
        list(yaml.safe_load_all(f.read_text()))
    except yaml.YAMLError as e:
        bad.append(f"{f}: {e}")
for b in bad:
    print(b)
print(f"yaml-parse: {count} bestanden, {len(bad)} fouten")
sys.exit(1 if bad else 0)
EOF

readonly CRD_SCHEMAS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

# seccomp-profiles heeft een kustomization; de rest zijn kale manifests.
kubectl kustomize seccomp-profiles | kubeconform -strict \
  -schema-location default -schema-location "$CRD_SCHEMAS" - \
  || { echo "verify FAALT: seccomp-profiles" >&2; exit 1; }

kubeconform -strict -ignore-filename-pattern 'values\.yaml' \
  -schema-location default -schema-location "$CRD_SCHEMAS" \
  -summary argo/ fuse-device-plugin/ storage/ cert-manager/

echo "verify: OK"

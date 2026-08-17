#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# role: tool
#
# scripts/verify.sh — snelle functionele verificatie (pre-push gate).
#
# Parseert alle YAML (waardes én manifests) en valideert de Kubernetes-
# manifests (argo/, fuse-device-plugin/, seccomp-profiles/, storage/,
# cert-manager/, envoy-gateway/) met kubeconform. Helm-values zijn vrije vorm
# en worden alleen op parseerbaarheid gecontroleerd. Dry-run only.
#
# Writes: alleen de kubeconform-schemacache (zie KUBECONFORM_CACHE hieronder);
#         verder read-only
# Idempotent: yes
# Requires: python3, kubectl, kubeconform
#
# Usage:
#   ./scripts/verify.sh
#   KUBECONFORM_CACHE=/tmp/kc ./scripts/verify.sh   # eigen cachelocatie
#   KUBECONFORM_CACHE= ./scripts/verify.sh          # leeg = geen cache

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

# kubeconform cachet NIET uit zichzelf: zonder -cache haalt elke run élk
# CRD-schema opnieuw op bij raw.githubusercontent.com. Een handvol volledige
# runs op één dag is genoeg om daar een anonieme rate limit (HTTP 429) te
# raken, en dan hangt de pre-push gate minutenlang op backoff — aangetoond
# 2026-08-17. Met de cache heeft alleen de eerste run het netwerk nodig.
# Leeg zetten schakelt de cache uit (bijv. om een schema-update te forceren).
kubeconform_cache_args=()
if [[ -n "${KUBECONFORM_CACHE-${HOME}/.cache/kubeconform}" ]]; then
  readonly KC_CACHE="${KUBECONFORM_CACHE-${HOME}/.cache/kubeconform}"
  mkdir -p "$KC_CACHE"
  kubeconform_cache_args=(-cache "$KC_CACHE")
fi
readonly kubeconform_cache_args

# seccomp-profiles heeft een kustomization; de rest zijn kale manifests.
kubectl kustomize seccomp-profiles | kubeconform -strict "${kubeconform_cache_args[@]}" \
  -schema-location default -schema-location "$CRD_SCHEMAS" - \
  || { echo "verify FAALT: seccomp-profiles" >&2; exit 1; }

# argocd/ (zelfbeheer): render de kustomization (vendored upstream + delta).
# CRD-definities zelf hebben geen schema in de catalog — expliciet geskipt;
# alle overige objecten valideren strikt.
kubectl kustomize argocd | kubeconform -strict "${kubeconform_cache_args[@]}" \
  -schema-location default -schema-location "$CRD_SCHEMAS" \
  -skip CustomResourceDefinition - \
  || { echo "verify FAALT: argocd" >&2; exit 1; }

# gateway-api/crds/ staat hier bewust NIET bij: dat zijn gevendorde
# CRD-definities uit de chart, die valideren we niet opnieuw (zelfde reden als
# de -skip bij argocd). De YAML-parse hierboven dekt ze wel.
kubeconform -strict -ignore-filename-pattern 'values\.yaml' \
  "${kubeconform_cache_args[@]}" \
  -schema-location default -schema-location "$CRD_SCHEMAS" \
  -summary argo/ fuse-device-plugin/ storage/ cert-manager/ envoy-gateway/

# Doc-assertion (docs-claims): het componentenoverzicht in docs/index.md
# dekt precies de Argo Applications — geen spookrijen, geen gaten.
python3 - <<'PYEOF'
import pathlib
import sys

apps = {p.stem for p in pathlib.Path("argo/applications").glob("*.yaml")}
index = pathlib.Path("docs/index.md").read_text(errors="replace")
missing = sorted(a for a in apps if a not in index)
if missing:
    print("doc-assertion FAALT: Applications zonder rij in docs/index.md: "
          + ", ".join(missing), file=sys.stderr)
    sys.exit(1)
print(f"doc-assertion OK ({len(apps)} Applications gedekt in de index)")
PYEOF

echo "verify: OK"
